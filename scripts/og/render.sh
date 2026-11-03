#!/bin/bash
# Gera os cards sociais em site/og/ (D-028). Rode de novo depois de mudar um título ou adicionar um guia.
# Precisa do Google Chrome instalado e de rede: a Geist vem do Google Fonts, como no site.
#   scripts/og/render.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
OUT="$ROOT/site/og"
W=1200
H=630
MAX_BYTES=153600 # 150 KB
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# arquivo|kicker|título|tamanho do título em px (vazio = 64; menor só se o título passar de 3 linhas)
# O título é o do card (≤ 60 caracteres), escrito pelo marketing; pode ser mais curto que o H1.
CARDS=(
  "guides|Guides|Claude Code and Codex usage limits, explained|"
  "check-claude-code-usage-limits-mac|Guide|How to check Claude Code usage limits on a Mac|"
  "claude-code-usage-limit-reached|Guide|Hit the Claude Code usage limit? What to do|"
  "codex-usage-limits|Guide|How to check Codex usage limits on a ChatGPT plan|"
  "multiple-claude-code-accounts|Guide|Use multiple Claude Code accounts with CLAUDE_CONFIG_DIR|"
  "changelog|Changelog|What changed in each version|"
)

fail() { echo "error: $*" >&2; exit 1; }

# percent-encoding byte a byte (LC_ALL=C), para a query string do file:// URL
urlencode() {
  local LC_ALL=C s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9._~-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# perfil temporário: não mexe no Chrome do usuário, mesmo se ele estiver aberto
chrome() {
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --window-size="$W,$H" --virtual-time-budget=10000 --user-data-dir="$TMP/profile" \
    --no-first-run --no-default-browser-check "$@" 2>/dev/null
}

to_jpeg() { sips -s format jpeg -s formatOptions 80 "$1" --out "$2" >/dev/null; }

# tamanho exato e teto de bytes (D-028): falha em vez de publicar um card fora do padrão
check() {
  local f="$1" w h bytes
  w=$(sips -g pixelWidth "$f" | awk '/pixelWidth/ { print $2 }')
  h=$(sips -g pixelHeight "$f" | awk '/pixelHeight/ { print $2 }')
  bytes=$(stat -f %z "$f")
  [[ "$w" == "$W" && "$h" == "$H" ]] || fail "${f#"$ROOT"/} is ${w}x${h}, expected ${W}x${H}"
  ((bytes <= MAX_BYTES)) || fail "${f#"$ROOT"/} is $bytes bytes, over $MAX_BYTES"
  echo "ok  ${f#"$ROOT"/}  ${w}x${h}  $((bytes / 1024)) KB"
}

[[ -x "$CHROME" ]] || fail "Google Chrome not found at $CHROME (set CHROME=...)"
mkdir -p "$OUT"

# home: o banner fixado pelo usuário, escalado para 630 px de altura e cortado no centro, sem geração
sips --resampleHeight "$H" "$ROOT/assets/banner.png" --out "$TMP/home.png" >/dev/null
sips --cropToHeightWidth "$H" "$W" "$TMP/home.png" >/dev/null
to_jpeg "$TMP/home.png" "$OUT/home.jpg"
check "$OUT/home.jpg"

page="$(urlencode "$ROOT/scripts/og/card.html")"
page="file://${page//%2F//}"

for card in "${CARDS[@]}"; do
  IFS='|' read -r name kicker title size <<<"$card"
  url="$page?kicker=$(urlencode "$kicker")&title=$(urlencode "$title")&size=${size:-64}"

  # o modelo marca no DOM se a Geist carregou e quantas linhas o título ocupa
  dom="$(chrome --dump-dom "$url")"
  grep -q 'data-fonts="geist"' <<<"$dom" || fail "Geist did not load for $name (network?)"
  lines="$(sed -n 's/.*data-lines="\([0-9]*\)".*/\1/p' <<<"$dom" | head -n 1)"
  ((${lines:-99} <= 3)) || fail "$name: the title takes ${lines:-?} lines; give it a smaller size"

  chrome --screenshot="$TMP/$name.png" "$url" >/dev/null
  to_jpeg "$TMP/$name.png" "$OUT/$name.jpg"
  check "$OUT/$name.jpg"
done
