#!/bin/sh
# 이 확장이 hooks.json에 넣은 훅("--agent codex")만 뺍니다. Codex 앱이 가져온 훅이나 다른 훅은 그대로.
CODEX="${CODEX_HOME:-$HOME/.codex}"
HOOKS="$CODEX/hooks.json"
grep -qs -- '--agent codex' "$HOOKS" || exit 0
command -v jq >/dev/null 2>&1 || exit 0
cp "$HOOKS" "$HOOKS.kongi-backup"
tmp=$(mktemp)
jq '.hooks |= (with_entries(.value |= map(select([.hooks[]?.command] | any(contains("--agent codex")) | not))) | with_entries(select(.value | length > 0)))' "$HOOKS" > "$tmp" && cat "$tmp" > "$HOOKS"
rm -f "$tmp"
echo "Removed Kongi's Codex hooks."
