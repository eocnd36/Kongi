#!/usr/bin/env bash
# 앱 안의 콩이 캐릭터를 그대로 그려 아이콘을 만듭니다 (디버그 빌드의 --render-icon 사용).
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
.build/debug/ClaudeUsageBar --render-icon "$TMP/icon.png"
mkdir -p "$TMP/AppIcon.iconset"
for b in 16 32 128 256 512; do
  sips -z $b $b "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${b}x${b}.png" >/dev/null
  sips -z $((b * 2)) $((b * 2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${b}x${b}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
sips -z 256 256 "$TMP/icon.png" --out docs/icon.png >/dev/null
cp docs/icon.png site/icon.png
sips -z 64 64 "$TMP/icon.png" --out site/favicon.png >/dev/null
rm -rf "$TMP"
echo "✓ Resources/AppIcon.icns"
