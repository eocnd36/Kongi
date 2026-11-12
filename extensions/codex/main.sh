#!/bin/sh
# Codex를 Claude Code처럼: Codex 훅을 Kongi에 연결하고(세션·승인이 아일랜드에), 사용 한도를 위젯으로 보여 줍니다.
# Codex 훅 입력은 Claude Code와 같은 형식이라 Kongi의 훅 도우미가 그대로 받습니다.
set -u
CODEX="${CODEX_HOME:-$HOME/.codex}"
HOOKS="$CODEX/hooks.json"
CONFIG="$CODEX/config.toml"
# Claude Code 연결이 쓰는 고정 경로가 있으면 그것을 (Kongi를 옮겨도 Codex가 다시 묻지 않게)
HELPER="$HOME/Library/Application Support/ClaudeUsageBar/bin/claude-usage-hook"
[ -x "$HELPER" ] || HELPER="$KONGI"
COMMAND="\"$HELPER\" --agent codex"

if ! command -v jq >/dev/null 2>&1; then
  echo "This extension needs jq (built into macOS 15 and later)."
  exit 1
fi

backup() { [ -f "$1" ] && cp "$1" "$1.kongi-backup"; }

connect() {
  mkdir -p "$CODEX"
  # 예전 버전(1.0)이 넣은 notify 한 줄은 훅이 대신하므로 뺍니다.
  if [ -f "$CONFIG" ] && grep -Eq '^notify = \[".*claude-usage-hook", "codex"\]$' "$CONFIG"; then
    backup "$CONFIG"
    tmp=$(mktemp)
    grep -Ev '^notify = \[".*claude-usage-hook", "codex"\]$' "$CONFIG" > "$tmp" && cat "$tmp" > "$CONFIG"
    rm -f "$tmp"
  fi
  # 이미 연결돼 있으면 (Codex 앱이 Claude Code 훅을 가져온 경우 포함) 그대로 둡니다.
  if grep -qsF "$HELPER" "$HOOKS" || grep -qs "claude-usage-hook" "$HOOKS" || grep -Eqs "^command = .*claude-usage-hook" "$CONFIG"; then
    echo "Codex hooks already reach Kongi."
    return
  fi
  backup "$HOOKS"
  [ -s "$HOOKS" ] || echo '{}' > "$HOOKS"
  tmp=$(mktemp)
  jq --arg cmd "$COMMAND" '
    def add(event; tools; seconds):
      .hooks[event] = ((.hooks[event] // []) + [
        ({hooks: [{type: "command", command: $cmd, timeout: seconds}]} + (if tools then {matcher: "*"} else {} end))
      ]);
    .hooks //= {}
    | add("SessionStart"; false; 10) | add("SessionEnd"; false; 3) | add("UserPromptSubmit"; false; 10)
    | add("PreToolUse"; true; 3600) | add("PostToolUse"; true; 10) | add("PermissionRequest"; true; 3600)
    | add("Stop"; false; 10)
  ' "$HOOKS" > "$tmp" && cat "$tmp" > "$HOOKS"
  rm -f "$tmp"
  echo "Added Kongi to $HOOKS"
  "$KONGI" notify "Codex is connected" "Open Codex and run /hooks once to trust Kongi." --symbol checkmark.circle.fill --seconds 10
}

# 가장 최근 Codex 대화 기록의 사용 한도 한 줄
latest_limits() {
  find "$CODEX/sessions/" -name 'rollout-*.jsonl' -mtime -8 2>/dev/null \
    | while IFS= read -r file; do printf '%s\t%s\n' "$(stat -f %m "$file")" "$file"; done \
    | sort -rn | head -6 | cut -f2- \
    | while IFS= read -r file; do
        line=$(grep '"primary":{' "$file" | tail -1)
        if [ -n "$line" ]; then printf '%s\n' "$line"; break; fi
      done
}

# 위젯 하나: id 제목 한도(primary/secondary) 날짜형식
show_limit() {
  used=$(printf '%s' "$limits" | jq -r ".payload.rate_limits.$3.used_percent // empty")
  resets=$(printf '%s' "$limits" | jq -r ".payload.rate_limits.$3.resets_at // empty")
  if [ -z "$used" ]; then "$KONGI" widget "$1" --remove; return; fi
  now=$(date +%s)
  detail=""
  if [ -n "$resets" ]; then
    resets=${resets%.*}
    if [ "$resets" -le "$now" ]; then used=0; detail="Reset"; else detail="Resets $(date -r "$resets" "$4")"; fi
  fi
  used=${used%.*}
  "$KONGI" widget "$1" --title "$2" --value "$used%" --detail "$detail" --progress "$used%" \
    --symbol gauge.with.dots.needle.50percent --url "https://chatgpt.com/codex/settings/usage"
}

update() {
  if [ ! -f "$CODEX/auth.json" ]; then
    # Codex의 로그인 (ChatGPT 계정). 누르면 터미널에서 codex login을 실행합니다.
    printf '#!/bin/sh\nif command -v codex >/dev/null 2>&1; then codex login; else echo "Install Codex first."; open "https://developers.openai.com/codex"; fi\n' > login.command
    chmod +x login.command
    url="file://$(pwd | sed 's/ /%20/g')/login.command"
    "$KONGI" widget codex-login --title "Codex" --value "Sign in" --detail "Click to sign in with your ChatGPT account" --symbol person.crop.circle.badge.plus --url "$url"
    return
  fi
  "$KONGI" widget codex-login --remove
  limits=$(latest_limits)
  [ -n "$limits" ] || return
  show_limit codex-5h "Codex · 5 hours" primary "+%H:%M"
  show_limit codex-week "Codex · weekly" secondary "+%a %H:%M"
}

connect
while :; do
  update
  [ -n "${KONGI_CODEX_ONCE:-}" ] && exit 0
  sleep 60
done
