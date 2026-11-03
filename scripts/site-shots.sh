#!/bin/zsh
# Renderiza as telas do app que o site mostra (suíte SiteShots), em inglês, e grava WebP em site/shots/.
# Rode de novo sempre que a UI mudar: os prints do site saem do código, não de captura de tela.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swift build --build-tests >/dev/null
HELPER="$(dirname "$(xcrun --find swift)")/../libexec/swift/pm/swiftpm-testing-helper"
BUNDLE="$(swift build --show-bin-path)/NotchLimitsPackageTests.xctest/Contents/MacOS/NotchLimitsPackageTests"
PLATFORM="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"

# O idioma do app vem de Locale.preferredLanguages, fixado na partida do processo: -AppleLanguages força inglês só aqui,
# sem mexer no idioma do sistema. O swift test não repassa argumentos, por isso o helper é chamado direto.
SNAPSHOT_DIR="$OUT" DYLD_FRAMEWORK_PATH="$PLATFORM/Library/Frameworks" DYLD_LIBRARY_PATH="$PLATFORM/usr/lib" \
  "$HELPER" --test-bundle-path "$BUNDLE" --testing-library swift-testing --filter SiteShots -AppleLanguages '(en)' >/dev/null

mkdir -p site/shots
for png in "$OUT"/site-*.png; do
  name=${${png:t:r}#site-}
  cwebp -quiet -q 86 "$png" -o "site/shots/$name.webp"
  size=$(sips -g pixelWidth -g pixelHeight "$png" | awk '/pixel/ { printf "%s ", $2 }')
  echo "site/shots/$name.webp  ${size}px  $(( $(stat -f %z "site/shots/$name.webp") / 1024 )) KB"
done
