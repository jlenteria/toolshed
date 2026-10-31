FLUTTER ?= flutter
UNIT ?=
DEVICE ?=
FAND ?= build/fanctl/toolshed-fand
LOCKD ?= build/lockd/toolshed-lockd
APP ?= toolshed
STAGED ?= build/macos/Build/Products/Release/$(APP).app

# Only dispatch to a platform this machine can actually build for. Same rule as
# openwrt-flasher: a broken compile is a failure, not "not available".
IS_MAC := $(filter Darwin,$(shell uname -s))
IS_LINUX := $(filter Linux,$(shell uname -s))
IS_WINDOWS := $(filter Windows_NT MINGW64_NT% MSYS_NT% CYGWIN_NT%,$(OS) $(shell uname -s))
RUN_TARGET := $(strip $(if $(IS_MAC),run-macos,$(if $(IS_LINUX),run-linux,$(if $(IS_WINDOWS),run-windows,))))

# Linux desktop integration. Defaults to a per-user install; use
# `sudo make install-linux PREFIX=/usr/local` for a system-wide one.
PREFIX ?= $(HOME)/.local
APP_ID := com.bling.toolshed
LINUX_APP_DIR := $(PREFIX)/lib/$(APP)
LINUX_DESKTOP_FILE := $(PREFIX)/share/applications/$(APP_ID).desktop
LINUX_ICON_FILE := $(PREFIX)/share/icons/hicolor/256x256/apps/$(APP_ID).png
# Desktop environments pick up changes without these; they just make it faster.
LINUX_REFRESH_CACHES := \
	if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database -q "$(PREFIX)/share/applications" || true; fi; \
	if command -v gtk-update-icon-cache >/dev/null 2>&1; then gtk-update-icon-cache -q -f -t "$(PREFIX)/share/icons/hicolor" || true; fi

.PHONY: help setup upgrade run run-macos run-windows run-linux run-all build build-macos install-macos install-linux uninstall-linux build-android build-linux fanctl lockd test analyze format format-check clean check doctor logo

help:
	@echo "setup         flutter pub get"
	@echo "upgrade       flutter pub upgrade --major-versions"
	@echo "run           flutter run (add DEVICE=<id> to target a device)"
	@echo "run-macos     flutter run -d macos"
	@echo "run-windows   flutter run -d windows"
	@echo "run-linux     flutter run -d linux"
	@echo "run-all       flutter run on this machine's desktop platform"
	@echo "build         flutter build macos --release"
	@echo "install-macos build, then replace and relaunch /Applications/$(APP).app"
	@echo "install-linux install the Linux release build with menu entry and icon (PREFIX=$(PREFIX))"
	@echo "uninstall-linux remove what install-linux added"
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

run-macos:
	$(FLUTTER) run -d macos

run-windows:
	$(FLUTTER) run -d windows

run-linux:
	$(FLUTTER) run -d linux

run-all:
ifeq ($(RUN_TARGET),)
	@echo "No Flutter desktop target for $(shell uname -s)." && exit 1
else
	@$(MAKE) $(RUN_TARGET)
endif

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

# The .desktop file's Exec is rewritten to the absolute install path so the
# menu entry works without the app being on PATH.
install-linux:
	@bundle=$$(ls -d build/linux/*/release/bundle 2>/dev/null | head -n 1); \
	if [ -z "$$bundle" ]; then echo "No Linux release build found. Run 'make build-linux' first."; exit 1; fi; \
	echo "Installing $$bundle to $(LINUX_APP_DIR)..."; \
	rm -rf "$(LINUX_APP_DIR)" && \
	mkdir -p "$(LINUX_APP_DIR)" && \
	cp -R "$$bundle/." "$(LINUX_APP_DIR)/" && \
	mkdir -p "$(dir $(LINUX_ICON_FILE))" && \
	install -m 644 linux/runner/resources/app_icon.png "$(LINUX_ICON_FILE)" && \
	mkdir -p "$(dir $(LINUX_DESKTOP_FILE))" && \
	sed "s|^Exec=.*|Exec=$(LINUX_APP_DIR)/$(APP)|" \
		linux/packaging/$(APP_ID).desktop > "$(LINUX_DESKTOP_FILE)" && \
	chmod 644 "$(LINUX_DESKTOP_FILE)"
	@$(LINUX_REFRESH_CACHES)
	@echo "Installed. toolshed is now in your application menu."

uninstall-linux:
	rm -rf "$(LINUX_APP_DIR)"
	rm -f "$(LINUX_DESKTOP_FILE)" "$(LINUX_ICON_FILE)"
	@$(LINUX_REFRESH_CACHES)
	@echo "Uninstalled."

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
	@sips -z 256 256 build/logo/logo.svg.png \
		--out linux/runner/resources/app_icon.png >/dev/null
	@python3 -c "from PIL import Image; Image.open('build/logo/logo.svg.png').convert('RGBA').save('windows/runner/resources/app_icon.ico', format='ICO', sizes=[(16,16),(32,32),(48,48),(256,256)])"
	@rm -rf build/logo
	@echo "logo: assets/logo.png and the macOS/Android/Windows icons re-rendered from assets/logo.svg"
