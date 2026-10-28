#!/bin/bash
# Builds Keelson.app into ./build and signs it locally.
# Set SIGN_IDENTITY to a Developer ID to sign for distribution; default is ad-hoc ("-").
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Keelson"

APP="build/Keelson.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Keelson"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "${SIGN_IDENTITY:--}" --entitlements Resources/Keelson.entitlements "$APP"
codesign --verify --verbose=1 "$APP"
echo "Built $(pwd)/$APP"
