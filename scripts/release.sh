#!/bin/bash
# Builds a universal Islandly.app and zips it for a GitHub Release: dist/Islandly-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
mkdir -p dist
ZIP="dist/Islandly-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Islandly.app "$ZIP"
echo "Created $ZIP"
shasum -a 256 "$ZIP"
