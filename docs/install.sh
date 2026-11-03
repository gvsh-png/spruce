#!/bin/bash
# Installs or updates Spruce, the screenshot renamer for macOS.
#
#   curl -fsSL https://gvsh-png.github.io/spruce/install.sh | bash
#
# Downloads the latest release from GitHub, puts Spruce.app in /Applications (or ~/Applications
# if /Applications isn't writable), and opens it. After that, Spruce updates itself.
set -euo pipefail

REPO="gvsh-png/spruce"
URL="https://github.com/$REPO/releases/latest/download/Spruce.zip"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "Spruce runs on macOS only."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || fail "Spruce needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."

DEST="/Applications"
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say "Downloading Spruce…"
curl -fL --progress-bar "$URL" -o "$TMP/Spruce.zip" || fail "Download failed. Check your connection, or get it from https://github.com/$REPO/releases"
ditto -x -k "$TMP/Spruce.zip" "$TMP"
[[ -d "$TMP/Spruce.app" ]] || fail "The download didn't contain Spruce.app."

if pgrep -xq Spruce; then
  say "Quitting the running copy…"
  osascript -e 'quit app "Spruce"' >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -xq Spruce || break; sleep 0.25; done
  pkill -x Spruce 2>/dev/null || true
fi

say "Installing to ${DEST}…"
# Copy next to the old app first, so a failed copy never leaves you with no Spruce at all.
rm -rf "$DEST/.Spruce.app.new"
ditto "$TMP/Spruce.app" "$DEST/.Spruce.app.new"
rm -rf "$DEST/Spruce.app"
mv "$DEST/.Spruce.app.new" "$DEST/Spruce.app"

open "$DEST/Spruce.app"
say "Spruce is installed. Look for the viewfinder icon in your menu bar."
