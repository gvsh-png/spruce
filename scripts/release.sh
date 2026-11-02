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
NOTES=${2:-"Spruce $VERSION"}
REPO=gvsh-png/spruce
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit or stash your changes first." >&2; exit 1
fi

BUILD=$(( $(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml) + 1 ))
sed -i '' -e "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" \
          -e "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
echo "Building Spruce $VERSION ($BUILD)…"
xcodegen generate >/dev/null
xcodebuild -scheme ScreenshotRenamer -configuration Release -derivedDataPath build build -quiet

OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT" docs
# Always named Spruce.zip, so .../releases/latest/download/Spruce.zip (used by docs/install.sh) works.
ditto -c -k --keepParent build/Build/Products/Release/Spruce.app "$OUT/Spruce.zip"

# Signs with the private key that generate_keys stored in your Keychain.
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  -o docs/appcast.xml "$OUT"

git add project.yml docs/appcast.xml
git commit -q -m "Release $VERSION${COMMIT_TRAILER:+

$COMMIT_TRAILER}"
git tag "v$VERSION"
git push -q && git push -q --tags
gh release create "v$VERSION" "$OUT/Spruce.zip" --repo "$REPO" --title "Spruce $VERSION" --notes "$NOTES"
echo "Released Spruce $VERSION."
