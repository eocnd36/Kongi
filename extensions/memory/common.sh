#!/bin/sh
# 메모리 확장 공통: 관리자 권한 없이 읽는 값만 씁니다 (vm_stat, sysctl, memory_pressure 수준, top, ioreg, df).

# 화면에 보이는 글 (Kongi가 넘겨주는 앱 언어)
T_TITLE="Memory"; T_NORMAL="Normal"; T_WARN="Warning"; T_CRIT="Critical"
T_SWAP="Swap"; T_LOW_TITLE="Memory is running low"; T_LOW_BODY="Swap %s. Using the most: %s"
T_USED="Used"; T_APP="App memory"; T_WIRED="Wired"; T_COMP="Compressed"; T_CACHED="Cached files"
T_SWAPDISK="Swap (on disk)"; T_DISKFREE="Free disk space"; T_GPU="GPU (unified memory)"; T_PRESSURE="Memory pressure"
T_TOP="Using the most"; T_PROCS="%d processes"
case "${KONGI_LANGUAGE:-en}" in
  ko*) T_TITLE="메모리"; T_NORMAL="정상"; T_WARN="주의"; T_CRIT="위험"; T_SWAP="스왑"
       T_LOW_TITLE="메모리가 부족해요"; T_LOW_BODY="스왑 %s. 가장 많이 쓰는 앱: %s"
       T_USED="사용 중"; T_APP="앱 메모리"; T_WIRED="고정 메모리"; T_COMP="압축됨"; T_CACHED="캐시된 파일"
       T_SWAPDISK="스왑 (저장공간)"; T_DISKFREE="남은 저장공간"; T_GPU="GPU (통합 메모리)"; T_PRESSURE="메모리 압박"
       T_TOP="많이 쓰는 앱"; T_PROCS="프로세스 %d개" ;;
  ja*) T_TITLE="メモリ"; T_NORMAL="正常"; T_WARN="注意"; T_CRIT="危険"; T_SWAP="スワップ"
       T_LOW_TITLE="メモリが不足しています"; T_LOW_BODY="スワップ %s。最も使っているアプリ：%s"
       T_USED="使用中"; T_APP="アプリメモリ"; T_WIRED="確保されているメモリ"; T_COMP="圧縮"; T_CACHED="キャッシュされたファイル"
       T_SWAPDISK="スワップ（ストレージ）"; T_DISKFREE="空きストレージ"; T_GPU="GPU（ユニファイドメモリ）"; T_PRESSURE="メモリプレッシャー"
       T_TOP="使用量の多いアプリ"; T_PROCS="%d個のプロセス" ;;
  zh-Hant*) T_TITLE="記憶體"; T_NORMAL="正常"; T_WARN="注意"; T_CRIT="危險"; T_SWAP="交換"
       T_LOW_TITLE="記憶體不足"; T_LOW_BODY="交換 %s。用量最多：%s"
       T_USED="已使用"; T_APP="App 記憶體"; T_WIRED="固定記憶體"; T_COMP="已壓縮"; T_CACHED="快取的檔案"
       T_SWAPDISK="交換（儲存空間）"; T_DISKFREE="可用儲存空間"; T_GPU="GPU（統一記憶體）"; T_PRESSURE="記憶體壓力"
       T_TOP="用量最多的 App"; T_PROCS="%d 個程序" ;;
  zh*) T_TITLE="内存"; T_NORMAL="正常"; T_WARN="注意"; T_CRIT="危险"; T_SWAP="交换"
       T_LOW_TITLE="内存不足"; T_LOW_BODY="交换 %s。用量最多：%s"
       T_USED="已使用"; T_APP="App 内存"; T_WIRED="联动内存"; T_COMP="已压缩"; T_CACHED="缓存的文件"
       T_SWAPDISK="交换（存储空间）"; T_DISKFREE="可用存储空间"; T_GPU="GPU（统一内存）"; T_PRESSURE="内存压力"
       T_TOP="用量最多的 App"; T_PROCS="%d 个进程" ;;
  es*) T_TITLE="Memoria"; T_NORMAL="Normal"; T_WARN="Atención"; T_CRIT="Crítica"; T_SWAP="Intercambio"
       T_LOW_TITLE="Queda poca memoria"; T_LOW_BODY="Intercambio %s. La que más usa: %s"
       T_USED="En uso"; T_APP="Memoria de apps"; T_WIRED="Memoria fija"; T_COMP="Comprimida"; T_CACHED="Archivos en caché"
       T_SWAPDISK="Intercambio (en disco)"; T_DISKFREE="Espacio libre"; T_GPU="GPU (memoria unificada)"; T_PRESSURE="Presión de memoria"
       T_TOP="Las que más usan"; T_PROCS="%d procesos" ;;
  fr*) T_TITLE="Mémoire"; T_NORMAL="Normale"; T_WARN="Attention"; T_CRIT="Critique"; T_SWAP="Swap"
       T_LOW_TITLE="La mémoire est presque pleine"; T_LOW_BODY="Swap %s. La plus gourmande : %s"
       T_USED="Utilisée"; T_APP="Mémoire des apps"; T_WIRED="Mémoire résidente"; T_COMP="Compressée"; T_CACHED="Fichiers en cache"
       T_SWAPDISK="Swap (sur disque)"; T_DISKFREE="Espace libre"; T_GPU="GPU (mémoire unifiée)"; T_PRESSURE="Pression mémoire"
       T_TOP="Les plus gourmandes"; T_PROCS="%d processus" ;;
  de*) T_TITLE="Speicher"; T_NORMAL="Normal"; T_WARN="Warnung"; T_CRIT="Kritisch"; T_SWAP="Swap"
       T_LOW_TITLE="Der Arbeitsspeicher wird knapp"; T_LOW_BODY="Swap %s. Am meisten nutzt: %s"
       T_USED="Belegt"; T_APP="App-Speicher"; T_WIRED="Fest belegt"; T_COMP="Komprimiert"; T_CACHED="Zwischengespeicherte Dateien"
       T_SWAPDISK="Swap (auf dem Speicher)"; T_DISKFREE="Freier Speicherplatz"; T_GPU="GPU (gemeinsamer Speicher)"; T_PRESSURE="Speicherdruck"
       T_TOP="Am meisten belegt"; T_PROCS="%d Prozesse" ;;
  it*) T_TITLE="Memoria"; T_NORMAL="Normale"; T_WARN="Attenzione"; T_CRIT="Critica"; T_SWAP="Swap"
       T_LOW_TITLE="La memoria sta finendo"; T_LOW_BODY="Swap %s. Usa di più: %s"
       T_USED="In uso"; T_APP="Memoria app"; T_WIRED="Memoria wired"; T_COMP="Compressa"; T_CACHED="File in cache"
       T_SWAPDISK="Swap (su disco)"; T_DISKFREE="Spazio libero"; T_GPU="GPU (memoria unificata)"; T_PRESSURE="Pressione memoria"
       T_TOP="Usano di più"; T_PROCS="%d processi" ;;
  pt*) T_TITLE="Memória"; T_NORMAL="Normal"; T_WARN="Atenção"; T_CRIT="Crítica"; T_SWAP="Swap"
       T_LOW_TITLE="A memória está acabando"; T_LOW_BODY="Swap %s. Quem mais usa: %s"
       T_USED="Em uso"; T_APP="Memória de apps"; T_WIRED="Memória fixa"; T_COMP="Comprimida"; T_CACHED="Arquivos em cache"
       T_SWAPDISK="Swap (no disco)"; T_DISKFREE="Espaço livre"; T_GPU="GPU (memória unificada)"; T_PRESSURE="Pressão de memória"
       T_TOP="Quem mais usa"; T_PROCS="%d processos" ;;
  ru*) T_TITLE="Память"; T_NORMAL="Норма"; T_WARN="Внимание"; T_CRIT="Критично"; T_SWAP="Своп"
       T_LOW_TITLE="Память заканчивается"; T_LOW_BODY="Своп %s. Больше всего использует: %s"
       T_USED="Занято"; T_APP="Память приложений"; T_WIRED="Зарезервировано"; T_COMP="Сжато"; T_CACHED="Кэш файлов"
       T_SWAPDISK="Своп (на диске)"; T_DISKFREE="Свободно на диске"; T_GPU="GPU (общая память)"; T_PRESSURE="Нагрузка на память"
       T_TOP="Больше всего используют"; T_PROCS="%d процессов" ;;
esac

# 바이트 → "12.3 GB" / "812 MB"
human() { awk -v b="$1" 'BEGIN { if (b >= 1073741824) printf "%.1f GB", b / 1073741824; else printf "%.0f MB", b / 1048576 }'; }

# 전체 메모리 구성 (바이트): TOTAL APP WIRED COMP CACHED USED SWAP_USED SWAP_TOTAL PRESSURE(1 정상 / 2 주의 / 4 위험)
read_memory() {
  TOTAL=$(sysctl -n hw.memsize)
  eval "$(vm_stat | awk -v ps="$(sysctl -n hw.pagesize)" '
    /^Pages wired down/ {w=$4} /^Pages purgeable/ {p=$3} /^File-backed pages/ {f=$3}
    /^Anonymous pages/ {a=$3} /^Pages occupied by compressor/ {c=$5}
    END { gsub(/\./, "", w); gsub(/\./, "", p); gsub(/\./, "", f); gsub(/\./, "", a); gsub(/\./, "", c)
          app = (a - p) * ps; if (app < 0) app = 0
          printf "APP=%.0f WIRED=%.0f COMP=%.0f CACHED=%.0f\n", app, w * ps, c * ps, (f + p) * ps }')"
  # 활성 상태 보기의 "사용된 메모리" = 앱 메모리 + 고정 + 압축
  USED=$(awk -v a="$APP" -v w="$WIRED" -v c="$COMP" 'BEGIN { printf "%.0f", a + w + c }')
  eval "$(sysctl -n vm.swapusage | awk '{ for (i = 1; i <= NF; i++) { if ($i == "total") t = $(i + 2); if ($i == "used") u = $(i + 2) } }
    function bytes(v) { n = v + 0; if (v ~ /G/) n *= 1024; return n * 1048576 }
    END { printf "SWAP_TOTAL=%.0f SWAP_USED=%.0f\n", bytes(t), bytes(u) }')"
  PRESSURE=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 1)
}

pressure_label() {
  case "$1" in 4) echo "$T_CRIT" ;; 2) echo "$T_WARN" ;; *) echo "$T_NORMAL" ;; esac
}

# 앱별 사용량: 같은 앱의 도우미 프로세스는 .app 이름으로 묶습니다. 출력: "바이트<TAB>개수<TAB>이름" (많은 순)
top_apps() {
  # 임시 파일은 mktemp로 (예측 가능한 이름은 공용 /tmp에서 다른 사용자가 미리 링크를 걸 수 있음)
  sizes=$(mktemp "${TMPDIR:-/tmp}/kongi-mem.XXXXXX") || return
  top -l 1 -o mem -n "${1:-80}" -stats pid,mem 2>/dev/null | awk '
    /^PID/ { body = 1; next } body && NF >= 2 {
      m = $2; gsub(/[+-]$/, "", m); n = m + 0
      if (m ~ /G$/) n *= 1073741824; else if (m ~ /M$/) n *= 1048576; else if (m ~ /K$/) n *= 1024
      print $1, n }' > "$sizes"
  pids=$(awk '{print $1}' "$sizes" | paste -sd, -)
  [ -n "$pids" ] || { rm -f "$sizes"; return; }
  ps -o pid=,comm= -p "$pids" 2>/dev/null | awk -v sizes="$sizes" '
    BEGIN { while ((getline line < sizes) > 0) { split(line, f, " "); size[f[1]] = f[2] } }
    { pid = $1; $1 = ""; path = substr($0, 2)
      if (match(path, /\/[^\/]+\.app\//)) { name = substr(path, RSTART + 1, RLENGTH - 6) }
      else { n = split(path, parts, "/"); name = parts[n] }
      total[name] += size[pid]; count[name]++ }
    END { for (name in total) printf "%.0f\t%d\t%s\n", total[name], count[name], name }' | sort -rn
  rm -f "$sizes"
}

# GPU가 통합 메모리에서 쓰는 양 (Apple 실리콘, 없으면 빈칸)
gpu_memory() {
  ioreg -r -d 1 -w 0 -c AGXAccelerator 2>/dev/null | grep -o '"In use system memory"=[0-9]*' | head -1 | cut -d= -f2
}

# 스왑 파일이 있는 볼륨의 남은 공간 (바이트)
disk_free() {
  df -k /System/Volumes/VM 2>/dev/null | awk 'NR == 2 { printf "%.0f", $4 * 1024 }'
}
