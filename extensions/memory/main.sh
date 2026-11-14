#!/bin/sh
# 메뉴 막대 창 위젯: 30초마다 가벼운 값만 읽습니다 (앱별 사용량은 메모리가 부족해질 때만).
set -u
. "$(dirname "$0")/common.sh"
warned=1
while :; do
  read_memory
  percent=$(awk -v u="$USED" -v t="$TOTAL" 'BEGIN { printf "%.0f", u * 100 / t }')
  "$KONGI" widget memory --title "$T_TITLE" --value "$(human "$USED") / $(human "$TOTAL")" \
    --detail "$T_SWAP $(human "$SWAP_USED") · $(pressure_label "$PRESSURE")" --progress "$percent%" --symbol memorychip
  # 압박이 주의·위험으로 올라갈 때 한 번 알립니다 (가장 많이 쓰는 앱 이름과 함께).
  if [ "$PRESSURE" -gt 1 ] && [ "$warned" -le 1 ]; then
    heaviest=$(top_apps 40 | head -1 | awk -F'\t' '{ print $3 }')
    # shellcheck disable=SC2059
    "$KONGI" notify "$T_LOW_TITLE" "$(printf "$T_LOW_BODY" "$(human "$SWAP_USED")" "${heaviest:-?}")" --symbol memorychip --seconds 8
  fi
  warned=$PRESSURE
  [ -n "${KONGI_MEMORY_ONCE:-}" ] && exit 0
  sleep 30
done
