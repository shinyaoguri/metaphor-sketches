#!/usr/bin/env bash
# 二重奏を起動して観測するための 1 本のスクリプト。
#
#   tools/probe.sh check              起動して検査（G*）が出そろうまで待ち、結果だけ出す
#   tools/probe.sh run [楽章]         楽章を固定して起動（tuning/unison/oddBars/canon/copy）
#   tools/probe.sh trace [秒]         食い違いの推移を標準出力で追う（既定 30 秒）
#   tools/probe.sh trap <名前>        落ちうる口を頼んで走らせる（oob / alloc / index）
#   tools/probe.sh frames <dir> [秒]  連番 PNG を書き出す（GIF / WebP の材料。既定 8 秒）
#   tools/probe.sh shots              楽章ごとに 1 枚ずつ ~/Desktop へ書き出す
#   tools/probe.sh soak <秒>          release ビルドで無人稼働し RSS / CPU の傾向を見る
#   tools/probe.sh stop               停止
#
# 判定は標準出力にも frame.json（probe の check.*）にも出る。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BIN=".build/debug/Sketch0824Duet"
RELBIN=".build/release/Sketch0824Duet"
LOG=".metaphor/run.log"
PIDFILE=".metaphor/duet.pid"
OUT=".probe-out"

build() {
  swift build 2>&1 | grep -E "error|Build complete" || true
  [ -x "$BIN" ] || { echo "ビルド成果物が無い: $BIN" >&2; exit 1; }
}

stop() {
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$PIDFILE"
  pkill -f "Sketch0824Duet" 2>/dev/null || true
  echo "停止"
}

launch() {  # launch <ログ先> [env...]
  local log="$1"; shift
  mkdir -p "$(dirname "$log")"
  env "$@" "$ROOT/$BIN" >"$log" 2>&1 &
  echo $! >"$PIDFILE"
}

# 検査は 1 フレーム目でエンコードし、GPU の着地を待って読み戻す。
# 最後に出るのは G11（描画フェーズでしか測れない）。
wait_for_checks() {
  local log="$1" i=0
  while [ $i -lt 40 ]; do
    grep -q "G11.circlesCount" "$log" 2>/dev/null && return 0
    sleep 1; i=$((i + 1))
  done
  return 1
}

cmd="${1:-check}"
case "$cmd" in
  check)
    build; stop >/dev/null
    launch "$LOG"
    if wait_for_checks "$LOG"; then
      grep -E "^(PASS|FAIL|LOOK|N/A) " "$LOG"
      echo "---"
      echo "PASS $(grep -cE '^PASS ' "$LOG") / FAIL $(grep -cE '^FAIL ' "$LOG") / LOOK $(grep -cE '^LOOK ' "$LOG")"
    else
      echo "検査が出そろわなかった。ログ: $LOG" >&2
      tail -20 "$LOG" >&2
    fi
    stop >/dev/null
    ;;

  run)
    build; stop >/dev/null
    launch "$LOG" "DUET_MOVEMENT=${2:-unison}"
    echo "起動 pid $(cat "$PIDFILE") / 楽章 ${2:-unison} / ログ $LOG"
    ;;

  trace)
    build; stop >/dev/null
    launch "$LOG" DUET_TRACE=1
    sleep "${2:-30}"
    grep "\[duet\]" "$LOG" || true
    stop >/dev/null
    ;;

  trap)
    [ -n "${2:-}" ] || { echo "使い方: tools/probe.sh trap <oob|alloc|index>" >&2; exit 2; }
    build; stop >/dev/null
    launch "$LOG" "DUET_TRAP=$2"
    sleep 8
    echo "--- ログ ---"; tail -30 "$LOG"
    if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then echo "--- 生きている ---"; else echo "--- 落ちた ---"; fi
    stop >/dev/null
    ;;

  frames)
    [ -n "${2:-}" ] || { echo "使い方: tools/probe.sh frames <dir> [秒]" >&2; exit 2; }
    build; stop >/dev/null
    mkdir -p "$2"
    launch "$LOG" "DUET_FRAMES=$2"
    sleep "${3:-8}"
    stop >/dev/null
    echo "$(ls "$2" | wc -l | tr -d ' ') 枚を $2 へ"
    ;;

  shots)
    build; stop >/dev/null
    launch "$LOG" DUET_SHOTS=1
    sleep 60   # 4 楽章 + 調弦を 1 巡ぶん
    stop >/dev/null
    grep "撮影" "$LOG" || echo "撮れていない"
    ;;

  soak)
    secs="${2:-180}"
    swift build -c release 2>&1 | grep -E "error|Build complete" || true
    [ -x "$RELBIN" ] || { echo "release ビルドが無い" >&2; exit 1; }
    stop >/dev/null
    mkdir -p "$OUT"
    csv="$OUT/soak-$(date +%Y%m%d-%H%M%S).csv"
    "$ROOT/$RELBIN" >"$OUT/soak.log" 2>&1 &
    pid=$!
    echo "$pid" >"$PIDFILE"
    echo "t_sec,rss_mb,cpu_pct" >"$csv"
    sleep 2   # 起動直後は ps がまだ 0 を返す。混ぜると前半平均が下がって偽の増加に見える
    t=0
    while [ "$t" -lt "$secs" ]; do
      if ! kill -0 "$pid" 2>/dev/null; then echo "落ちた（t=${t}s）" >&2; break; fi
      line=$(ps -o rss=,pcpu= -p "$pid" | tr -s ' ')
      rss=$(echo "$line" | awk '{printf "%.1f", $1/1024}')
      cpu=$(echo "$line" | awk '{print $2}')
      echo "$t,$rss,$cpu" >>"$csv"
      sleep 10; t=$((t + 10))
    done
    stop >/dev/null
    echo "--- $csv ---"
    awk -F, 'NR>1 && $2>0 {n++; a[n]=$2; c[n]=$3}
      END{
        h=int(n/2);
        for(i=1;i<=h;i++){s1+=a[i]; p1+=c[i]}
        for(i=h+1;i<=n;i++){s2+=a[i]; p2+=c[i]}
        printf "サンプル %d / RSS 前半 %.1fMB → 後半 %.1fMB / CPU 前半 %.1f%% → 後半 %.1f%%\n",
          n, s1/h, s2/(n-h), p1/h, p2/(n-h)
      }' "$csv"
    ;;

  stop) stop ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
