#!/bin/sh
# Compiles the Swift helpers into the app bundle.
#
# They are built by a phase rather than copied from `build/`, because Xcode signs
# the bundle after the build phases run, and a binary dropped into a signed
# `Contents/Resources` afterwards breaks the seal — the app would then fail to
# launch with a signature error nobody asked for.
#
# The alternative was leaving the app to find its helpers in
# `~/Project/toolshed/build/...`, which works exactly on the machine that
# compiled them. An installed toolshed has to work where it was installed.
set -eu

res="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources"
tmp="${TARGET_TEMP_DIR%/}/toolshed-helpers"
rm -rf "$tmp"
mkdir -p "$res" "$tmp"

embed() {
	name=$1
	src=$2
	shift 2
	if [ "$#" -eq 0 ]; then
		echo "embed_helpers: no frameworks named for $name" >&2
		exit 2
	fi
	for arch in $ARCHS; do
		xcrun swiftc -O "$src" \
			-target "$arch-apple-macosx$MACOSX_DEPLOYMENT_TARGET" \
			-o "$tmp/$name-$arch" "$@"
		# The decision table both helpers carry is pure computation, so a bundle
		# must not be able to ship a helper that fails its own check. Only the
		# slice this machine can execute is run: the foreign arch of a universal
		# build is a `Bad CPU type`, not a broken helper.
		if [ "$arch" = "$NATIVE_ARCH_ACTUAL" ]; then
			"$tmp/$name-$arch" selfcheck >/dev/null
		fi
	done
	# One file or several: `lipo -create` thins or fattens either way.
	lipo -create "$tmp"/"$name"-* -output "$res/$name"
	chmod 755 "$res/$name"
	echo "embedded $name for: $ARCHS"
}

embed toolshed-fand "$PROJECT_DIR/fanctl/main.swift" \
	-framework Foundation -framework IOKit
embed toolshed-lockd "$PROJECT_DIR/lockd/main.swift" \
	-framework AppKit -framework CryptoKit -framework Foundation

# mem_reaper.py is run by python3 rather than compiled, but it is still a
# helper the app installs: carrying it here is what lets an installed bundle
# point an agent at its own copy instead of at a checkout.
cp "$PROJECT_DIR/../scripts/mem_reaper.py" "$res/mem_reaper.py"
chmod 644 "$res/mem_reaper.py"
echo "embedded mem_reaper.py"
