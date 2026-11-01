#!/bin/bash
# Sets Keelson's version for the next release.
#
#   scripts/bump-version.sh patch|minor|major     1.1.0 -> 1.1.1 / 1.2.0 / 2.0.0
#   scripts/bump-version.sh 1.4.2                 an explicit version
#
# Updates CFBundleShortVersionString (and increments CFBundleVersion) in Resources/Info.plist, and turns the
# "## Unreleased" section of CHANGELOG.md into "## <version> — <date>" (leaving a fresh, empty
# "## Unreleased" above it). Prints the new version.
# The "Bump version" GitHub workflow runs this, commits, tags and publishes the release.
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST=Resources/Info.plist
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
IFS=. read -r MAJOR MINOR PATCH <<< "${CURRENT%%-*}"

case "${1:-}" in
  patch) NEW="$MAJOR.$MINOR.$((PATCH + 1))" ;;
  minor) NEW="$MAJOR.$((MINOR + 1)).0" ;;
  major) NEW="$((MAJOR + 1)).0.0" ;;
  [0-9]*.[0-9]*.[0-9]*) NEW="$1" ;;
  *) echo "usage: $0 patch|minor|major|<x.y.z>" >&2; exit 2 ;;
esac
[ "$NEW" != "$CURRENT" ] || { echo "Already at $CURRENT" >&2; exit 1; }

if ! grep -q '^## Unreleased' CHANGELOG.md; then
  echo "CHANGELOG.md has no '## Unreleased' section describing this release." >&2
  exit 1
fi
if ! awk '/^## Unreleased/ { f = 1; next } f && /^## / { exit } f && /[^[:space:]]/ { found = 1 } END { exit !found }' CHANGELOG.md; then
  echo "The '## Unreleased' section of CHANGELOG.md is empty." >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD + 1))" "$PLIST"
DATE=$(date +%Y-%m-%d)
# Keep an empty "## Unreleased" on top for the next round of notes.
awk -v line="## $NEW — $DATE" '!done && /^## Unreleased/ { print "## Unreleased"; print ""; print line; done = 1; next } { print }' CHANGELOG.md > CHANGELOG.md.tmp
mv CHANGELOG.md.tmp CHANGELOG.md
echo "$NEW"
