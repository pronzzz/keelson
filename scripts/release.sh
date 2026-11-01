#!/bin/bash
# Builds a Keelson release into dist/:
#   Keelson-<version>.dmg        drag-to-Applications installer
#   Keelson-<version>.zip        what the in-app updater downloads
#   Keelson-<version>.zip.sig    Ed25519 signature of the zip (checked by the updater)
#   SHA256SUMS.txt
#
#   scripts/release.sh             build only
#   scripts/release.sh --publish   build, then create (or refresh) the GitHub release v<version>,
#                                  with notes from that version's CHANGELOG.md section
#
# The version comes from Resources/Info.plist (set it with scripts/bump-version.sh).
# Needs: Xcode/Swift, create-dmg (brew install create-dmg), gh for --publish, and the update signing key
# (~/.config/keelson/update_signing_key or $KEELSON_UPDATE_PRIVATE_KEY; see scripts/update_keys.swift).
# Set KEELSON_SKIP_SELFTEST=1 where VMs can't run (GitHub's macOS runners have no nested virtualization).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
NAME="Keelson-$VERSION"
APP="build/Keelson.app"
DIST="$ROOT/dist"

step() { printf "\n\033[1m==> %s\033[0m\n" "$1"; }

step "Keelson $VERSION"
swift scripts/update_keys.swift public >/dev/null || { echo "No update signing key; see scripts/update_keys.swift" >&2; exit 1; }
PLIST_KEY=$(/usr/libexec/PlistBuddy -c "Print :KSUpdatePublicKey" Resources/Info.plist)
[ "$(swift scripts/update_keys.swift public)" = "$PLIST_KEY" ] || {
  echo "The signing key doesn't match KSUpdatePublicKey in Info.plist; installed apps would reject this update." >&2
  exit 1
}

if [ "$PUBLISH" = 1 ]; then
  NOTES=$(mktemp)
  trap 'rm -f "$NOTES"' EXIT
  # The section of CHANGELOG.md for this version, without its heading.
  awk -v v="$VERSION" '
    index($0, "## " v " ") == 1 || $0 == "## " v { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' CHANGELOG.md > "$NOTES"
  grep -q '[^[:space:]]' "$NOTES" || { echo "No CHANGELOG.md section for $VERSION" >&2; exit 1; }
fi

step "Building"
./scripts/build-app.sh
BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[ "$BUILT" = "$VERSION" ] || { echo "Built version $BUILT != $VERSION" >&2; exit 1; }

if [ "${KEELSON_SKIP_SELFTEST:-0}" != 1 ]; then
  step "Self-test"
  "$APP/Contents/MacOS/Keelson" --selftest
fi

rm -rf "$DIST"
mkdir -p "$DIST"

step "Packaging update zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$NAME.zip"
swift scripts/update_keys.swift sign "$DIST/$NAME.zip" > "$DIST/$NAME.zip.sig"

step "Building DMG"
./scripts/build-dmg.sh
mv "build/$NAME.dmg" "$DIST/$NAME.dmg"

(cd "$DIST" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)

step "Artifacts"
ls -lh "$DIST"
cat "$DIST/SHA256SUMS.txt"

if [ "$PUBLISH" = 1 ]; then
  step "Publishing v$VERSION to GitHub"
  {
    echo
    echo "### SHA-256"
    echo '```'
    cat "$DIST/SHA256SUMS.txt"
    echo '```'
  } >> "$NOTES"
  ASSETS=("$DIST/$NAME.dmg" "$DIST/$NAME.zip" "$DIST/$NAME.zip.sig" "$DIST/SHA256SUMS.txt")
  if gh release view "v$VERSION" >/dev/null 2>&1; then
    # Already published (for example by CI): refresh the files and notes.
    gh release upload "v$VERSION" "${ASSETS[@]}" --clobber
    gh release edit "v$VERSION" --notes-file "$NOTES"
  else
    gh release create "v$VERSION" --title "Keelson $VERSION" --notes-file "$NOTES" --verify-tag "${ASSETS[@]}" \
      || gh release create "v$VERSION" --title "Keelson $VERSION" --notes-file "$NOTES" "${ASSETS[@]}"
  fi
fi
