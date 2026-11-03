#!/bin/zsh
# Ships a new version of Spruce to everyone running it.
#
#   scripts/release.sh 0.2.0 "What changed in this version"
#
# 1. Bumps the version in project.yml (build number +1, which is what Sparkle compares).
# 2. Builds Spruce.app in Release and zips it.
# 3. Signs the zip with the EdDSA key in your login Keychain and writes docs/appcast.xml
#    (GitHub Pages serves it at https://gvsh-png.github.io/spruce/appcast.xml).
# 4. Commits, tags, pushes, and uploads the zip to a GitHub Release.
# Running copies of Spruce find the update within a day, or at once via Check for Updates.
set -euo pipefail

VERSION=${1:?usage: scripts/release.sh <version> [notes]}
[[ $VERSION =~ '^[0-9]+(\.[0-9]+)*$' ]] || { echo "Version must look like 1.2.3" >&2; exit 1; }
NOTES=${2:-"Spruce $VERSION"}
REPO=gvsh-png/spruce
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit or stash your changes first." >&2; exit 1
fi
[[ "$(git branch --show-current)" == main ]] || { echo "Release from main (GitHub Pages serves the feed from it)." >&2; exit 1; }

CURRENT=$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml)
[[ -n $CURRENT ]] || { echo "Couldn't read CURRENT_PROJECT_VERSION from project.yml." >&2; exit 1; }
BUILD=$(( CURRENT + 1 ))
# A failed build must not leave project.yml bumped.
trap 'git checkout -q project.yml docs/appcast.xml' ERR
sed -i '' -e "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" \
          -e "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
echo "Building Spruce $VERSION ($BUILD)…"
xcodegen generate >/dev/null
xcodebuild -scheme ScreenshotRenamer -configuration Release -derivedDataPath build build -quiet

OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT" docs
# Always named Spruce.zip, so .../releases/latest/download/Spruce.zip (used by docs/install.sh) works.
ditto -c -k --keepParent build/Build/Products/Release/Spruce.app "$OUT/Spruce.zip"
# generate_appcast embeds an HTML file named like the archive, so the update dialog shows the notes.
ESCAPED=${NOTES//&/&amp;}; ESCAPED=${ESCAPED//</&lt;}; ESCAPED=${ESCAPED//>/&gt;}
print -r -- "<p>$ESCAPED</p>" > "$OUT/Spruce.html"

# Signs with the private key that generate_keys stored in your Keychain.
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  -o docs/appcast.xml "$OUT"

git add project.yml docs/appcast.xml
git commit -q -m "Release $VERSION${COMMIT_TRAILER:+

$COMMIT_TRAILER}"
trap - ERR
git tag "v$VERSION"
git push -q origin "v$VERSION"
# Upload the zip before the feed goes live, so no running copy is ever offered a missing download.
gh release create "v$VERSION" "$OUT/Spruce.zip" --repo "$REPO" --title "Spruce $VERSION" --notes "$NOTES" --verify-tag
git push -q
echo "Released Spruce $VERSION."
