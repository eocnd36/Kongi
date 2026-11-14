#!/bin/sh
# 아일랜드 "메모리 자세히": 전체 구성과 많이 쓰는 앱 (고정폭 글꼴로 보임)
set -u
. "$(dirname "$0")/common.sh"
read_memory
# 숫자를 앞에 (한글·일본어처럼 폭이 다른 글자도 줄이 맞게: printf는 글자 폭이 아니라 바이트로 칸을 셈)
row() { printf '%19s  %s\n' "$2" "$1"; }
row "$T_USED" "$(human "$USED") / $(human "$TOTAL")"
row "  $T_APP" "$(human "$APP")"
row "  $T_WIRED" "$(human "$WIRED")"
row "  $T_COMP" "$(human "$COMP")"
row "$T_CACHED" "$(human "$CACHED")"
row "$T_SWAPDISK" "$(human "$SWAP_USED") / $(human "$SWAP_TOTAL")"
free=$(disk_free); [ -n "$free" ] && row "$T_DISKFREE" "$(human "$free")"
gpu=$(gpu_memory); [ -n "$gpu" ] && row "$T_GPU" "$(human "$gpu")"
printf '\n%s: %s\n\n%s\n' "$T_PRESSURE" "$(pressure_label "$PRESSURE")" "$T_TOP"
top_apps 120 | head -12 | while IFS="$(printf '\t')" read -r bytes count name; do
  label=$name
  # shellcheck disable=SC2059
  [ "$count" -gt 1 ] && label="$name ($(printf "$T_PROCS" "$count"))"
  printf '%19s  %s\n' "$(human "$bytes")" "$label"
done
