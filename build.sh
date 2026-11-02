#!/bin/zsh
# Compila e empacota o NotchLimits.app
#   ./build.sh          → instala em ~/Applications e abre
#   ./build.sh --dist   → gera dist/NotchLimits.dmg e dist/NotchLimits.zip (universal: Apple Silicon + Intel)
set -e
cd "$(dirname "$0")"

VERSION="$(git describe --tags --abbrev=0 2>/dev/null || true)"
VERSION="${VERSION#v}"
VERSION="${VERSION:-1.0.0}"

# monta o .app a partir de um binário: make_bundle <binário> <destino.app>
make_bundle() {
  local bin="$1" app="$2"
  rm -rf "$app" && mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$bin" "$app/Contents/MacOS/NotchLimits"

  # ícone do app a partir de assets/logo.png
  local iconset="$(mktemp -d)/AppIcon.iconset" && mkdir -p "$iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s assets/logo.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) assets/logo.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.martins.notchlimits</string>
  <key>CFBundleName</key><string>Notch Limits</string>
  <key>CFBundleExecutable</key><string>NotchLimits</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
  codesign --force -s - "$app"
}

if [[ "$1" == "--dist" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  rm -rf dist && mkdir -p dist
  make_bundle .build/apple/Products/Release/NotchLimits "dist/Notch Limits.app"

  ditto -c -k --keepParent "dist/Notch Limits.app" dist/NotchLimits.zip
  # DMG com fundo, ícones posicionados e atalho para Applications (dmgbuild escreve o layout sem automatizar o Finder)
  uvx dmgbuild -s assets/dmg/settings.py -D app="dist/Notch Limits.app" \
    -D volicon="dist/Notch Limits.app/Contents/Resources/AppIcon.icns" "Notch Limits" dist/NotchLimits.dmg >/dev/null
  shasum -a 256 dist/NotchLimits.zip dist/NotchLimits.dmg
  echo "v$VERSION pronto em dist/"
  exit 0
fi

swift build -c release
APP="$HOME/Applications/Notch Limits.app"
pkill -x NotchLimits 2>/dev/null || true
rm -rf "$HOME/Applications/NotchLimits.app"   # nome antigo, antes do espaço
make_bundle .build/release/NotchLimits "$APP"
open "$APP"
echo "Instalado em $APP"
