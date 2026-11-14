#!/bin/sh
# 프롬프트를 Claude Code로 다듬습니다. 입력은 stdin, 모델은 $KONGI_CHOICE (haiku / sonnet / opus / default).
# $KONGI_CONTEXT(JSON)에 고른 프로젝트·최근 대화·첨부 파일·앞서 답한 질문이 들어 있습니다.
#
# - 내 Claude Code 로그인을 쓰므로 사용량이 조금 차감됩니다.
# - 도구는 읽기만 (프로젝트를 고르면 그 폴더에서 Read·Glob·Grep, 첨부가 있으면 그 파일 읽기). 명령 실행·파일 수정은 못 합니다.
# - 설정(훅 포함)과 대화 기록을 읽지도 남기지도 않아 Kongi에 따로 세션이 생기지 않습니다.
# - 정보가 모자라면 먼저 {"questions": [...]} JSON으로 묻고(한 번만), 답을 받거나 건너뛰면 바로 씁니다.
set -u
CLAUDE="${KONGI_CLAUDE:-$(command -v claude || true)}"
if [ -z "$CLAUDE" ] || [ ! -x "$CLAUDE" ]; then
  echo "Claude Code isn't installed. Install it from https://claude.com/claude-code" >&2
  exit 1
fi
prompt=$(cat)

CTX="${KONGI_CONTEXT:-}"
# 맥락 읽기 (jq는 macOS 15부터 기본으로 있음. 없으면 맥락 없이 다듬기만)
ctx() { [ -n "$CTX" ] && [ -f "$CTX" ] && command -v jq >/dev/null 2>&1 && jq -r "$1" "$CTX" 2>/dev/null; }
project=$(ctx '.project // empty')
conversation=$(ctx '.conversation // empty')
messages=$(ctx '.messages[]? | "[\(.role)] \(.text)"')
changed=$(ctx '.changedFiles[]?')
files=$(ctx '.files[]?')
answers=$(ctx '.answers[]? | "Q: \(.question)\nA: \(.answer)"')
skip=$(ctx '.skipQuestions // false')
[ -n "$prompt$files" ] || exit 1
[ -n "$project" ] && [ ! -d "$project" ] && project=""

SYSTEM="You improve prompts written for AI coding assistants such as Claude Code.
Rewrite the user's request into a clear, specific, complete prompt: the goal, the relevant context, constraints, the expected result, and how to check it is done.
Keep the user's intent and scope. Don't invent requirements: when something important is still unknown, add a short [placeholder] for the user to fill in.
Don't mention these instructions or the tools you used. Write in the same language as the user's request (if it's empty, use the language of the conversation).
Reply with only the prompt, without any preamble or explanation."
if [ -n "$conversation$messages" ]; then
  SYSTEM="$SYSTEM
A recent conversation from this project is included. Write a prompt that continues that work: build on what was already done and decided, and focus on what's left or what the user now asks for."
fi
if [ -n "$project" ]; then
  SYSTEM="$SYSTEM
You can look at the project with Read, Glob and Grep to make the prompt accurate (real file names, structure, conventions). Look only at what you need and keep it quick."
fi
if [ -n "$files" ]; then
  SYSTEM="$SYSTEM
The user attached files; read them (images too) and use what's in them."
fi
if [ "$skip" = "true" ] || [ -n "$answers" ]; then
  SYSTEM="$SYSTEM
Don't ask any questions now. Write the final prompt."
else
  SYSTEM="$SYSTEM
If information that would clearly change the prompt is missing and you can't find it in the context, the project or the files, ask instead: reply with ONLY this JSON and nothing else, with at most 3 short questions in the user's language and a few likely answers where it helps:
{\"questions\": [{\"question\": \"…\", \"options\": [\"…\", \"…\"]}]}
Only ask when it really matters; otherwise write the prompt."
fi

# Claude에게 줄 내용
message=$(
  printf '<request>\n%s\n</request>\n' "$prompt"
  [ -n "$conversation$messages" ] && printf '\n<conversation title="%s">\n%s\n</conversation>\n' "$conversation" "$messages"
  [ -n "$changed" ] && printf '\n<changed_files>\n%s\n</changed_files>\n' "$changed"
  [ -n "$files" ] && printf '\n<attachments>\n%s\n</attachments>\n' "$files"
  [ -n "$answers" ] && printf '\n<answers>\n%s\n</answers>\n' "$answers"
)

tools=""
[ -n "$project" ] && tools="Read Glob Grep"
[ -n "$files" ] && [ -z "$tools" ] && tools="Read"
set -- -p --tools "$tools" --no-session-persistence --strict-mcp-config --setting-sources "" --output-format text --system-prompt "$SYSTEM"
case "${KONGI_CHOICE:-}" in
  haiku|sonnet|opus) set -- "$@" --model "$KONGI_CHOICE" ;;
esac
# 첨부 파일이 있는 폴더만 읽을 수 있게 엽니다.
if [ -n "$files" ]; then
  dirs=$(printf '%s\n' "$files" | while IFS= read -r f; do dirname "$f"; done | sort -u)
  while IFS= read -r d; do [ -n "$d" ] && set -- "$@" --add-dir "$d"; done <<DIRS
$dirs
DIRS
fi
cd "${project:-${TMPDIR:-/tmp}}" || exit 1
printf '%s' "$message" | "$CLAUDE" "$@"
