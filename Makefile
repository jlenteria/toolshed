FLUTTER ?= flutter
UNIT ?=
DEVICE ?=
FAND ?= build/fanctl/toolshed-fand
LOCKD ?= build/lockd/toolshed-lockd
APP ?= toolshed
STAGED ?= build/macos/Build/Products/Release/$(APP).app

.PHONY: help setup upgrade run build build-macos install-macos build-android build-linux fanctl lockd test analyze format format-check clean check doctor logo

help:
	@echo "setup         flutter pub get"
	@echo "upgrade       flutter pub upgrade --major-versions"
	@echo "run           flutter run (add DEVICE=<id> to target a device)"
	@echo "build         flutter build macos --release"
	@echo "install-macos build, then replace and relaunch /Applications/$(APP).app"
	@echo "build-android flutter build apk --release"
	@echo "build-linux   flutter build linux --release"
	@echo "fanctl        compile the macOS fan helper and run its selfcheck"
	@echo "lockd         compile the macOS app-lock helper and run its selfcheck"
	@echo "test          flutter test (add UNIT=<path> for one file)"
	@echo "analyze       flutter analyze"
	@echo "format        dart format lib test"
	@echo "format-check  dart format --output=none --set-exit-if-changed lib test"
	@echo "check         analyze + format-check + test"
	@echo "clean         remove build artifacts and .dart_tool"
	@echo "logo          re-render assets/logo.png and the app icons from assets/logo.svg"
	@echo "doctor        flutter doctor"

setup:
	$(FLUTTER) pub get

upgrade:
	$(FLUTTER) pub upgrade --major-versions

run:
	$(FLUTTER) run $(if $(DEVICE),-d $(DEVICE),)

build: build-macos

build-macos:
	$(FLUTTER) build macos --release

# The app is meant to run from /Applications, and now it can: the Embed Helpers
# build phase compiles both Swift helpers into Contents/Resources before Xcode
# signs the bundle, so an installed toolshed needs nothing from this checkout.
# `make build` only leaves the bundle under build/; this puts it where it belongs
# and relaunches it, and keeps the bundle it replaced as a timestamped copy in
# /tmp instead of deleting it.
install-macos: build-macos
	@test -d $(STAGED) || { echo "no bundle at $(STAGED)"; exit 1; }
	-pkill -f "/Applications/$(APP).app/Contents/MacOS/$(APP)"
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		pgrep -f "/Applications/$(APP).app/Contents/MacOS/$(APP)" >/dev/null \
			|| break; sleep 0.5; done
	@if [ -d /Applications/$(APP).app ]; then \
		kept=/tmp/$(APP).app.$$(date +%Y%m%dT%H%M%S); \
		mv /Applications/$(APP).app $$kept; \
		echo "the bundle it replaced is at $$kept"; fi
	cp -R $(STAGED) /Applications/$(APP).app
	@open -g /Applications/$(APP).app
	@echo "installed /Applications/$(APP).app, with its helpers inside it"

build-android:
	$(FLUTTER) build apk --release

build-linux:
	$(FLUTTER) build linux --release

# The helper is one Swift file with no dependencies beyond Foundation and IOKit,
# so it builds with swiftc alone. Its selfcheck runs the policy decision table
# with no hardware, which is the soundness gate the installer insists on before
# anything becomes a LaunchDaemon.
fanctl:
	@mkdir -p $(dir $(FAND))
	swiftc -O macos/fanctl/main.swift -o $(FAND) -framework Foundation -framework IOKit
	@$(FAND) selfcheck

# The lock helper is also a single Swift file, needing only AppKit (to talk to
# the running apps) and CryptoKit (for the PBKDF2 that keeps the passphrase out
# of Dart). Its selfcheck hashes a known passphrase and replays the window
# arithmetic with no apps and no GUI, so a broken lock fails here rather than
# silently leaving an app open. `make check` runs it before the tests, which
# means the protocol suite exercises the real binary instead of skipping it.
lockd:
	@mkdir -p $(dir $(LOCKD))
	swiftc -O macos/lockd/main.swift -o $(LOCKD) \
		-framework AppKit -framework CryptoKit -framework Foundation
	@$(LOCKD) selfcheck

test: lockd
	$(FLUTTER) test $(UNIT)

analyze:
	$(FLUTTER) analyze

format:
	dart format lib test

format-check:
	dart format --output=none --set-exit-if-changed lib test

check: analyze format-check test

clean:
	$(FLUTTER) clean
	rm -rf .dart_tool build

doctor:
	$(FLUTTER) doctor

# The mark is authored in assets/logo.svg so it stays editable in text; it is
# rasterised once at 1024 and resampled into every bundled PNG and app icon.
# assets/logo_mark.svg is the same mark without its tile, sized for the safe
# zone of an Android adaptive icon.
logo:
	@mkdir -p build/logo
	@qlmanage -t -s 1024 -o build/logo assets/logo.svg >/dev/null
	@qlmanage -t -s 1024 -o build/logo assets/logo_mark.svg >/dev/null
	@sips -z 512 512 build/logo/logo.svg.png --out assets/logo.png >/dev/null
	@for s in 16 32 64 128 256 512 1024; do \
		sips -z $$s $$s build/logo/logo.svg.png \
			--out macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$$s.png >/dev/null; done
	@for e in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do \
		sips -z $${e##*:} $${e##*:} build/logo/logo.svg.png \
			--out android/app/src/main/res/mipmap-$${e%%:*}/ic_launcher.png >/dev/null; \
		sips -z $${e##*:} $${e##*:} build/logo/logo.svg.png \
			--out android/app/src/main/res/mipmap-$${e%%:*}/ic_launcher_round.png >/dev/null; \
		f=$${e##*:}; f=$$((f * 108 / 48)); \
		sips -z $$f $$f build/logo/logo_mark.svg.png \
			--out android/app/src/main/res/mipmap-$${e%%:*}/ic_launcher_foreground.png >/dev/null; done
	@python3 -c "from PIL import Image; Image.open('build/logo/logo.svg.png').convert('RGBA').save('windows/runner/resources/app_icon.ico', format='ICO', sizes=[(16,16),(32,32),(48,48),(256,256)])"
	@rm -rf build/logo
	@echo "logo: assets/logo.png and the macOS/Android/Windows icons re-rendered from assets/logo.svg"
