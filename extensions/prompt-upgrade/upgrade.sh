#!/bin/sh
# 프롬프트(또는 상황 설명)를 Claude Code로 다듬습니다. 입력은 stdin.
# 만드는 모델은 $KONGI_CHOICE (haiku / sonnet / opus), 실행할 모델은 $KONGI_CHOICE_TARGET (haiku / sonnet / opus / fable).
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
The user's input is either a draft prompt or a description of their situation in their own words, such as what they want to do, what they tried, or what goes wrong.
Either way, turn it into the prompt they should send: a clear, specific, complete prompt with the goal, the relevant context, constraints, the expected result, and how to check it is done.
When it's a description, work out the actual task from it, write it as instructions to the assistant, and keep the useful details (symptoms, error messages, what was tried) as context.
Keep the user's intent and scope. Don't invent requirements: when something important is still unknown, add a short [placeholder] for the user to fill in.
Don't mention these instructions or the tools you used. Write in the same language as the user's request (if it's empty, use the language of the conversation).
Reply with only the prompt, without any preamble or explanation."
# 이 프롬프트를 실행할 모델("사용할 모델" 줄, $KONGI_CHOICE_TARGET)의 공식 가이드에 맞춥니다.
# 그 줄을 모르는 예전 Kongi에서는 만드는 모델($KONGI_CHOICE)을 실행할 모델로 봅니다.
TARGET="${KONGI_CHOICE_TARGET:-${KONGI_CHOICE:-}}"
# Anthropic: platform.claude.com/docs/en/build-with-claude/prompt-engineering (모델별 페이지)
case "$TARGET" in
  haiku) GUIDE="The prompt will be run by Claude Haiku in Claude Code. Following Anthropic's guidance for Haiku 5.5:
spell out every step and the expected result explicitly; tell it to keep working until everything asked is done and only stop when it can't go on without the user or before a risky step;
and tell it to run a real check that exercises the change (the project's tests, type-checker or build) before reporting it done, saying which check it couldn't run and why." ;;
  sonnet) GUIDE="The prompt will be run by Claude Sonnet in Claude Code. Following Anthropic's guidance for Sonnet 5.5:
tell it to carry the work through without stopping to check in, and when the work is done and checked, to stop and report without adding features, tests, files, docs or refactors that weren't asked for (suggest them at the end instead);
if the user wants ideas or a plan, say to give that and not start building; ask for a real check (tests or build) before it reports done." ;;
  opus) GUIDE="The prompt will be run by Claude Opus in Claude Code. Following Anthropic's guidance for Opus 5.5:
tell it to look through the relevant files first, including ones the request doesn't mention, before changing anything;
for long or multi-part work, give an explicit completion condition and a checklist of parts; for frontend work, name specific styles to avoid rather than asking it to avoid a generic look." ;;
  fable) GUIDE="The prompt will be run by Claude Fable in Claude Code. Following Anthropic's guidance for Fable 5.2:
tell it to finish the whole task without stopping while work is still owed, to diagnose ordinary obstacles such as errors, timeouts or failing commands and work through them, and to leave deliberate blockers alone and report them;
name exactly which actions need the user's approval instead of a vague rule; write each restriction with its scope and reason rather than a bare never, because it treats never as absolute;
say who owns the code: if the user wants changes kept small, say it is the user's code and to change only what the task needs;
and ask for a final report a reader without context can follow: key points first, plain words, what was found, what was done, what's next." ;;
  *) GUIDE="The prompt will be run by Claude in Claude Code." ;;  # 예전에 고른 값(기본·Codex)이 남아 있을 때
esac
SYSTEM="$SYSTEM
$GUIDE
For all Claude Code prompts also follow Anthropic's general guidance: be clear and direct, give the reason behind constraints, separate parts with XML tags when the prompt mixes instructions, context and examples,
say what to do rather than what not to do, tell it not to speculate about code it hasn't opened, keep changes to what was asked, and ask for a general solution rather than one that only makes the tests pass.
Before you reply, check that no two instructions conflict (for example, telling it never to stop and ask while also telling it to ask the user about something); if the task really needs the user's input, say exactly when to ask and what to do meanwhile.
Keep the prompt only as long as the task needs: for big multi-part work, end with a checklist of the parts and how each is checked."

if [ -n "$conversation$messages" ]; then
  SYSTEM="$SYSTEM
A recent conversation from this project is included. Write a prompt that continues that work: build on what was already done and decided, and focus on what's left or what the user now asks for."
fi
# 같은 프로젝트에서 다시 만들 때 처음부터 다시 훑지 않게, 지난번에 본 프로젝트 요약을 씁니다 (토큰·시간 절약).
# 요약은 구조·규칙처럼 잘 안 바뀌는 것만 담고, 최근 대화와 바뀐 파일은 매번 새로 넘기므로 앞뒤 작업 맥락은 그대로입니다.
# 커밋이 바뀌었거나 6시간이 지나면 다시 만듭니다. 이 Mac에만 저장 (~/Library/Caches/Kongi/prompt-upgrade, 나만 읽기).
BRIEF_MARK="===KONGI PROJECT BRIEF==="
brief=""
brief_file=""
head=""
if [ -n "$project" ] && command -v jq >/dev/null 2>&1; then
  cache_dir="$HOME/Library/Caches/Kongi/prompt-upgrade"
  mkdir -p "$cache_dir" && chmod 700 "$cache_dir"
  brief_file="$cache_dir/$(printf '%s' "$project" | shasum | cut -c1-16).json"
  head=$(git -C "$project" rev-parse HEAD 2>/dev/null || echo none)
  saved_at=$(jq -r '.savedAt // 0' "$brief_file" 2>/dev/null)
  # 망가진 캐시는 없는 것으로 (숫자가 아니면 계산이 깨져 스크립트가 멈춤)
  case "$saved_at" in ''|*[!0-9]*) saved_at=0 ;; esac
  if [ -f "$brief_file" ] && [ "$(jq -r '.head // ""' "$brief_file" 2>/dev/null)" = "$head" ] \
     && [ $(( $(date +%s) - saved_at )) -lt 21600 ]; then
    brief=$(jq -r '.brief // ""' "$brief_file" 2>/dev/null)
  fi
fi
if [ -n "$project" ]; then
  if [ -n "$brief" ]; then
    SYSTEM="$SYSTEM
A brief of this project from an earlier look is in <project_brief>. Rely on it for the layout, key files and conventions, and open files with Read, Glob and Grep only to check details this request depends on."
  else
    SYSTEM="$SYSTEM
You can look at the project with Read, Glob and Grep to make the prompt accurate (real file names, structure, conventions). Look only at what you need and keep it quick."
    [ -n "$brief_file" ] && SYSTEM="$SYSTEM
When you write the prompt (not when you reply with the questions JSON), add after it a line with only $BRIEF_MARK and then a compact brief of the project for reuse in later requests, under 200 words: what it is, the layout and key files, how to build and test, and its conventions. Only facts you saw; the user doesn't see this part."
  fi
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
  [ -n "$brief" ] && printf '\n<project_brief>\n%s\n</project_brief>\n' "$brief"
  [ -n "$files" ] && printf '\n<attachments>\n%s\n</attachments>\n' "$files"
  [ -n "$answers" ] && printf '\n<answers>\n%s\n</answers>\n' "$answers"
)

tools=""
[ -n "$project" ] && tools="Read Glob Grep"
[ -n "$files" ] && [ -z "$tools" ] && tools="Read"
# 결과와 함께 실제로 쓴 모델을 받습니다 (별칭 haiku·sonnet·opus는 Claude Code가 그때의 최신 모델로 바꿈).
format=text
command -v jq >/dev/null 2>&1 && format=json
set -- -p --tools "$tools" --no-session-persistence --strict-mcp-config --setting-sources "" --output-format "$format" --system-prompt "$SYSTEM"
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
case "${KONGI_LANGUAGE:-en}" in
  ko*) T_MODEL="모델" ;; ja*) T_MODEL="モデル" ;; zh*) T_MODEL="模型" ;; es*|pt*) T_MODEL="Modelo" ;;
  fr*) T_MODEL="Modèle" ;; de*) T_MODEL="Modell" ;; it*) T_MODEL="Modello" ;; ru*) T_MODEL="Модель" ;; *) T_MODEL="Model" ;;
esac
cd "${project:-${TMPDIR:-/tmp}}" || exit 1
if [ "$format" = "text" ]; then
  printf '%s' "$message" | "$CLAUDE" "$@"
  exit $?
fi
out=$(printf '%s' "$message" | "$CLAUDE" "$@") || { printf '%s\n' "$out" >&2; exit 1; }
if [ "$(printf '%s' "$out" | jq -r '.is_error // false')" = "true" ]; then
  printf '%s' "$out" | jq -r '.result // "Claude Code failed."' >&2
  exit 1
fi
# 실제로 글을 쓴 모델 = 출력이 가장 많은 모델 (Claude Code는 보조 작업에 Haiku도 함께 씀). claude-haiku-5-5 → Claude Haiku 5.5
WRITER='.modelUsage // {} | to_entries | map(select(.key | startswith("claude-"))) | max_by(.value.outputTokens // 0) | .key // empty'
model=$(printf '%s' "$out" | jq -r "$WRITER" \
  | sed -E 's/^claude-//; s/-([0-9]+)-([0-9]+)(-.*)?$/ \1.\2/' | awk '{ $1 = toupper(substr($1, 1, 1)) substr($1, 2); print "Claude " $0 }')
text=$(printf '%s' "$out" | jq -r '.result // ""')
# 프로젝트 요약이 붙어 왔으면 떼어 저장하고, 사용자에게는 프롬프트만
case "$text" in
  *"$BRIEF_MARK"*)
    new_brief=${text#*"$BRIEF_MARK"}
    text=${text%%"$BRIEF_MARK"*}
    if [ -n "$brief_file" ] && [ -n "$(printf '%s' "$new_brief" | tr -d '[:space:]')" ]; then
      jq -n --arg head "$head" --arg brief "$new_brief" --argjson at "$(date +%s)" '{head: $head, savedAt: $at, brief: $brief}' > "$brief_file.tmp" \
        && chmod 600 "$brief_file.tmp" && mv "$brief_file.tmp" "$brief_file"
    fi ;;
esac
jq -n --arg result "$text" --arg note "${model:+$T_MODEL: $model}" '{result: ($result | sub("\\s+$"; "")), note: $note}'
