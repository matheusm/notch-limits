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
APP="$DEST/Notch Limits.app"
pkill -x NotchLimits 2>/dev/null || true
rm -rf "$APP" "$DEST/NotchLimits.app"   # NotchLimits.app = nome usado até a v1.0.0
ditto -x -k "$TMP/NotchLimits.zip" "$DEST"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

open "$APP"
echo "✓ Installed to $APP — look at your notch."
