#!/bin/zsh
# Compila, empacota como .app (sem ícone no Dock) e instala em ~/Applications
set -e
cd "$(dirname "$0")"
swift build -c release
APP="$HOME/Applications/NotchLimits.app"
pkill -x NotchLimits 2>/dev/null || true
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NotchLimits "$APP/Contents/MacOS/"

# ícone do app a partir de assets/logo.png
ICONSET="$(mktemp -d)/AppIcon.iconset" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/logo.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) assets/logo.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.martins.notchlimits</string>
  <key>CFBundleName</key><string>Notch Limits</string>
  <key>CFBundleExecutable</key><string>NotchLimits</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force -s - "$APP"
open "$APP"
echo "Instalado em $APP"
