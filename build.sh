#!/bin/bash
# Builds Islandly.app into ./build — no Xcode project needed, just the Command Line Tools.
#
#   ./build.sh                 universal app (Apple Silicon + Intel)
#   ARCHS=arm64 ./build.sh     faster, this Mac's architecture only
#
# Signing: set ISLANDLY_SIGN_IDENTITY to the name of your code-signing certificate
# (see README → "Keep permissions across rebuilds"). Default: "Islandly Dev".
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Islandly.app"
ARCHS="${ARCHS:-arm64 x86_64}"
MIN_OS="26.0"
FRAMEWORKS=(-framework IOKit -framework EventKit -framework ScreenCaptureKit -framework Speech -framework AVFoundation)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" build/obj

slices=()
for arch in $ARCHS; do
    echo "→ compiling for $arch"
    swiftc -O -target "$arch-apple-macos$MIN_OS" Sources/*.swift -o "build/obj/Islandly-$arch" "${FRAMEWORKS[@]}"
    slices+=("build/obj/Islandly-$arch")
done
lipo -create "${slices[@]}" -output "$APP/Contents/MacOS/Islandly"
cp Info.plist "$APP/Contents/Info.plist"

# A stable signing identity lets macOS remember granted permissions (Screen Recording, Automation…)
# across rebuilds. Ad-hoc signatures change every build, so permissions would reset each time.
IDENTITY="${ISLANDLY_SIGN_IDENTITY:-Islandly Dev}"
if ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    # Backwards compatibility with the certificate name used before the rename.
    if security find-identity -p codesigning | grep -q '"DynamicIsland Dev"'; then IDENTITY="DynamicIsland Dev"; else IDENTITY=""; fi
fi
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with \"$IDENTITY\""
else
    codesign --force --sign - "$APP"
    echo "warning: no \"Islandly Dev\" certificate found — ad-hoc signed (permissions reset on every rebuild; see README)"
fi

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Islandly"))"
