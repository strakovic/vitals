#!/bin/bash
# Installs the latest Vitals and opens it.
#   curl -fsSL https://raw.githubusercontent.com/strakovic/vitals/main/install.sh | bash
set -euo pipefail

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Vitals needs a Mac with Apple silicon (M1 or newer)." >&2
  exit 1
fi

URL="https://github.com/strakovic/vitals/releases/latest/download/Vitals.zip"
DEST="/Applications"
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Vitals..."
curl -fsSL "$URL" -o "$TMP/Vitals.zip"
ditto -x -k "$TMP/Vitals.zip" "$TMP"

pkill -x Vitals 2>/dev/null || true
rm -rf "$DEST/Vitals.app"
ditto "$TMP/Vitals.app" "$DEST/Vitals.app"
# Downloaded with curl, so macOS adds no quarantine flag; clear one just in case.
xattr -dr com.apple.quarantine "$DEST/Vitals.app" 2>/dev/null || true

open "$DEST/Vitals.app"
echo "Done. Vitals is in your menu bar and opens at login (System Settings > General > Login Items)."
