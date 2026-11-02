#!/bin/bash
# notch-limits installer: downloads the latest release into ~/Applications and opens it.
# curl -fsSL https://raw.githubusercontent.com/matheusm/notch-limits/main/install.sh | bash
set -euo pipefail

URL="https://github.com/matheusm/notch-limits/releases/latest/download/NotchLimits.zip"
DEST="$HOME/Applications"

if [[ "$(uname)" != "Darwin" ]] || [[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 14 ]]; then
  echo "notch-limits requires macOS 14 (Sonoma) or later." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ Downloading Notch Limits…"
curl -fsSL "$URL" -o "$TMP/NotchLimits.zip"

mkdir -p "$DEST"
pkill -x NotchLimits 2>/dev/null || true
rm -rf "$DEST/NotchLimits.app"
ditto -x -k "$TMP/NotchLimits.zip" "$DEST"
xattr -dr com.apple.quarantine "$DEST/NotchLimits.app" 2>/dev/null || true

open "$DEST/NotchLimits.app"
echo "✓ Installed to $DEST/NotchLimits.app — look at your notch."
