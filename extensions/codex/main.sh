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

# 화면에 보이는 글: Kongi가 넘겨주는 앱 언어(KONGI_LANGUAGE)로. 날짜·요일도 그 언어로 씁니다.
T_5H="Codex · 5 hours"; T_WEEK="Codex · weekly"; T_RESET="Reset"; T_RESETS="Resets %s"
T_SIGNIN="Sign in"; T_SIGNIN_DETAIL="Click to sign in with your ChatGPT account"
T_CONNECTED="Codex is connected"; T_TRUST="Open Codex and run /hooks once to trust Kongi."; LOC=en_US.UTF-8
case "${KONGI_LANGUAGE:-en}" in
  ko*) T_5H="Codex · 5시간"; T_WEEK="Codex · 주간"; T_RESET="초기화됨"; T_RESETS="%s 초기화"
       T_SIGNIN="로그인"; T_SIGNIN_DETAIL="눌러서 ChatGPT 계정으로 로그인"
       T_CONNECTED="Codex 연결됨"; T_TRUST="Codex를 열고 /hooks를 한 번 실행해 Kongi를 신뢰해 주세요."; LOC=ko_KR.UTF-8 ;;
  ja*) T_5H="Codex · 5時間"; T_WEEK="Codex · 週間"; T_RESET="リセット済み"; T_RESETS="%s にリセット"
       T_SIGNIN="サインイン"; T_SIGNIN_DETAIL="クリックしてChatGPTアカウントでサインイン"
       T_CONNECTED="Codexに接続しました"; T_TRUST="Codexを開いて /hooks を一度実行し、Kongiを信頼してください。"; LOC=ja_JP.UTF-8 ;;
  zh-Hant*) T_5H="Codex · 5 小時"; T_WEEK="Codex · 每週"; T_RESET="已重置"; T_RESETS="%s 重置"
       T_SIGNIN="登入"; T_SIGNIN_DETAIL="點一下以 ChatGPT 帳號登入"
       T_CONNECTED="已連線 Codex"; T_TRUST="打開 Codex 並執行一次 /hooks 以信任 Kongi。"; LOC=zh_TW.UTF-8 ;;
  zh*) T_5H="Codex · 5 小时"; T_WEEK="Codex · 每周"; T_RESET="已重置"; T_RESETS="%s 重置"
       T_SIGNIN="登录"; T_SIGNIN_DETAIL="点按以使用 ChatGPT 账户登录"
       T_CONNECTED="已连接 Codex"; T_TRUST="打开 Codex 并运行一次 /hooks 以信任 Kongi。"; LOC=zh_CN.UTF-8 ;;
  es*) T_5H="Codex · 5 horas"; T_WEEK="Codex · semanal"; T_RESET="Restablecido"; T_RESETS="Se restablece %s"
       T_SIGNIN="Iniciar sesión"; T_SIGNIN_DETAIL="Haz clic para iniciar sesión con tu cuenta de ChatGPT"
       T_CONNECTED="Codex está conectado"; T_TRUST="Abre Codex y ejecuta /hooks una vez para confiar en Kongi."; LOC=es_ES.UTF-8 ;;
  fr*) T_5H="Codex · 5 heures"; T_WEEK="Codex · hebdomadaire"; T_RESET="Réinitialisé"; T_RESETS="Réinitialisation %s"
       T_SIGNIN="Se connecter"; T_SIGNIN_DETAIL="Cliquez pour vous connecter avec votre compte ChatGPT"
       T_CONNECTED="Codex est connecté"; T_TRUST="Ouvrez Codex et lancez /hooks une fois pour faire confiance à Kongi."; LOC=fr_FR.UTF-8 ;;
  de*) T_5H="Codex · 5 Stunden"; T_WEEK="Codex · wöchentlich"; T_RESET="Zurückgesetzt"; T_RESETS="Neu ab %s"
       T_SIGNIN="Anmelden"; T_SIGNIN_DETAIL="Klicken, um dich mit deinem ChatGPT-Konto anzumelden"
       T_CONNECTED="Codex ist verbunden"; T_TRUST="Öffne Codex und führe einmal /hooks aus, um Kongi zu vertrauen."; LOC=de_DE.UTF-8 ;;
  it*) T_5H="Codex · 5 ore"; T_WEEK="Codex · settimanale"; T_RESET="Ripristinato"; T_RESETS="Si ripristina %s"
       T_SIGNIN="Accedi"; T_SIGNIN_DETAIL="Fai clic per accedere con il tuo account ChatGPT"
       T_CONNECTED="Codex è connesso"; T_TRUST="Apri Codex ed esegui /hooks una volta per considerare attendibile Kongi."; LOC=it_IT.UTF-8 ;;
  pt*) T_5H="Codex · 5 horas"; T_WEEK="Codex · semanal"; T_RESET="Reiniciado"; T_RESETS="Reinicia %s"
       T_SIGNIN="Entrar"; T_SIGNIN_DETAIL="Clique para entrar com sua conta do ChatGPT"
       T_CONNECTED="O Codex está conectado"; T_TRUST="Abra o Codex e execute /hooks uma vez para confiar no Kongi."; LOC=pt_BR.UTF-8 ;;
  ru*) T_5H="Codex · 5 часов"; T_WEEK="Codex · неделя"; T_RESET="Сброшено"; T_RESETS="Сброс %s"
       T_SIGNIN="Войти"; T_SIGNIN_DETAIL="Нажмите, чтобы войти через аккаунт ChatGPT"
       T_CONNECTED="Codex подключён"; T_TRUST="Откройте Codex и один раз выполните /hooks, чтобы доверять Kongi."; LOC=ru_RU.UTF-8 ;;
esac

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
  "$KONGI" notify "$T_CONNECTED" "$T_TRUST" --symbol checkmark.circle.fill --seconds 10
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

# 위젯 하나: id 제목 한도(primary/secondary) 날짜형식 (요일·시각은 앱 언어로)
show_limit() {
  used=$(printf '%s' "$limits" | jq -r ".payload.rate_limits.$3.used_percent // empty")
  resets=$(printf '%s' "$limits" | jq -r ".payload.rate_limits.$3.resets_at // empty")
  if [ -z "$used" ]; then "$KONGI" widget "$1" --remove; return; fi
  now=$(date +%s)
  detail=""
  if [ -n "$resets" ]; then
    resets=${resets%.*}
    # shellcheck disable=SC2059
    if [ "$resets" -le "$now" ]; then used=0; detail="$T_RESET"; else detail=$(printf "$T_RESETS" "$(LC_ALL=$LOC date -r "$resets" "$4")"); fi
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
    "$KONGI" widget codex-login --title "Codex" --value "$T_SIGNIN" --detail "$T_SIGNIN_DETAIL" --symbol person.crop.circle.badge.plus --url "$url"
    return
  fi
  "$KONGI" widget codex-login --remove
  limits=$(latest_limits)
  [ -n "$limits" ] || return
  show_limit codex-5h "$T_5H" primary "+%H:%M"
  show_limit codex-week "$T_WEEK" secondary "+%a %H:%M"
}

connect
while :; do
  update
  [ -n "${KONGI_CODEX_ONCE:-}" ] && exit 0
  sleep 60
done
