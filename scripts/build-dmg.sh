#!/bin/bash
# Builds build/Keelson-<version>.dmg: a drag-to-Applications installer.
# Uses create-dmg (brew install create-dmg) for the styled window if available,
# otherwise falls back to a plain hdiutil image.
# Run scripts/build-app.sh first, or pass --build to do it here.
set -euo pipefail
cd "$(dirname "$0")/.."

[ "${1:-}" = "--build" ] && ./scripts/build-app.sh

APP="build/Keelson.app"
[ -d "$APP" ] || { echo "error: $APP not found. Run scripts/build-app.sh first." >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Keelson-$VERSION.dmg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir "$WORK/src"
ditto "$APP" "$WORK/src/Keelson.app"
rm -f "$DMG"

if command -v create-dmg >/dev/null; then
    # Background: 1x + 2x combined into one HiDPI TIFF.
    swift scripts/dmg-background.swift "$WORK/bg.png" 1
    swift scripts/dmg-background.swift "$WORK/bg@2x.png" 2
    tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/background.tiff" 2>/dev/null

    # create-dmg returns 2 when only the cosmetic Finder step fails (e.g. no automation access).
    set +e
    create-dmg \
        --volname "Keelson $VERSION" \
        --volicon Resources/AppIcon.icns \
        --background "$WORK/background.tiff" \
        --window-pos 200 120 \
        --window-size 660 428 \
        --icon-size 112 \
        --text-size 13 \
        --icon "Keelson.app" 170 190 \
        --hide-extension "Keelson.app" \
        --app-drop-link 490 190 \
        --no-internet-enable \
        --hdiutil-quiet \
        "$DMG" "$WORK/src"
    status=$?
    set -e
    [ $status -eq 0 ] || [ $status -eq 2 ] || exit $status
else
    ln -s /Applications "$WORK/src/Applications"
    hdiutil create -volname "Keelson $VERSION" -srcfolder "$WORK/src" \
        -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
fi

# Sign the image itself so its contents can't be swapped without notice.
codesign --force --sign "${SIGN_IDENTITY:--}" "$DMG"
hdiutil verify -quiet "$DMG"
echo "Built $(pwd)/$DMG"
shasum -a 256 "$DMG"
