#!/usr/bin/env bash
# 交換台を起動して観測するための 1 本のスクリプト。
#
#   tools/probe.sh start           ビルドして起動 (Probe 有効)
#   tools/probe.sh snap            1 フレーム撮って frame.json を出す
#   tools/probe.sh checks          撮ったフレームから check.* / outlets.* / wiring を抜く
#   tools/probe.sh cycle           stop → start → 検査が出るまで待って checks
#   tools/probe.sh stop            停止
#   tools/probe.sh trace [秒]      post() の到着順を標準出力で見る (既定 5 秒)
#   tools/probe.sh solo <id>       provider を 1 本だけにして起動 (aperture|syphon|none)
#   tools/probe.sh occlude [秒]    ウィンドウを隠してもフレームが進むか (レンダーループの実測)
#   tools/probe.sh soak <秒>       release ビルドで無人稼働し RSS / CPU の傾向を見る
#
# frame.json が一次証拠。画像は裏取りにだけ使う。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BIN=".build/debug/Sketch0823Switchboard"
RELBIN=".build/release/Sketch0823Switchboard"
PROBE=".metaphor/probe"
PIDFILE=".metaphor/switchboard.pid"
LOG=".metaphor/run.log"

is_running() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

start() {
  swift build 2>&1 | grep -E "error|Build complete" || true
  [ -x "$BIN" ] || { echo "ビルド成果物が無い: $BIN" >&2; exit 1; }
  if is_running; then echo "既に起動中 (pid $(cat "$PIDFILE"))"; return 0; fi
  mkdir -p .metaphor
  rm -f "$PROBE/current/frame.json"
  # 空の env を注入しない（SWITCHBOARD_SOLO="" は「1 本だけ」の指定として読まれうる）。
  METAPHOR_PROBE=1 "$ROOT/$BIN" >"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
  echo "起動 pid $(cat "$PIDFILE")"
}

stop() {
  if is_running; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$PIDFILE"
  pkill -f "$BIN" 2>/dev/null || true
  echo "停止"
}

# 1 フレーム要求して、その id が frame.json に現れるまで待つ。
snap() {
  local id="s$(date +%s)$RANDOM"
  mkdir -p "$PROBE"
  printf '{"id":"%s","scale":1}' "$id" >"$PROBE/request.json.tmp"
  mv "$PROBE/request.json.tmp" "$PROBE/request.json"
  local i=0
  while [ $i -lt 300 ]; do
    if [ -f "$PROBE/current/frame.json" ] && grep -q "\"$id\"" "$PROBE/current/frame.json" 2>/dev/null; then
      cat "$PROBE/current/frame.json"
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  echo "snapshot がタイムアウトした。ログ:" >&2
  tail -20 "$LOG" >&2
  return 1
}

checks() {
  local f="$PROBE/current/frame.json"
  [ -f "$f" ] || { echo "frame.json が無い。先に snap してください" >&2; exit 1; }
  if command -v jq >/dev/null; then
    jq -r '
      (.custom | to_entries
        | map(select(.key | startswith("check.")))
        | sort_by(.key)[] | "\(.value | sub(" .*"; ""))\t\(.key | sub("^check\\."; ""))\t\(.value | sub("^(PASS|FAIL) "; ""))"),
      "",
      (.custom | to_entries
        | map(select(.key | startswith("check.") | not))
        | sort_by(.key)[] | "\(.key)\t\(.value)")
    ' "$f"
  else
    grep -o '"check\.[^"]*":"[^"]*"' "$f" | tr -d '"' | tr ':' '\t'
  fi
}

cycle() {
  stop >/dev/null 2>&1 || true
  start
  local i=0
  while [ $i -lt 40 ]; do
    sleep 1
    if snap >/dev/null 2>&1; then
      if grep -q '"check\.' "$PROBE/current/frame.json" 2>/dev/null; then
        checks
        return 0
      fi
    fi
    i=$((i + 1))
  done
  echo "検査が frame.json に現れなかった。ログ:" >&2
  tail -20 "$LOG" >&2
  return 1
}

# post() の到着順をそのまま流す。出力フェーズが最後に来ているかを目で追う。
trace() {
  local secs="${2:-5}"
  mkdir -p .metaphor
  swift build 2>&1 | grep -E "error|Build complete" || true
  SWITCHBOARD_TRACE=1 "$ROOT/$BIN" >".metaphor/trace.log" 2>&1 &
  local pid=$!
  sleep "$secs"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -E "^(trace|jack|wiring)" ".metaphor/trace.log" | head -40
}

# provider を 1 本だけにした対照実験。
solo() {
  local which="${2:-none}"
  mkdir -p .metaphor
  stop >/dev/null 2>&1 || true
  swift build 2>&1 | grep -E "error|Build complete" || true
  SWITCHBOARD_SOLO="$which" SWITCHBOARD_TRACE=1 "$ROOT/$BIN" >".metaphor/solo-$which.log" 2>&1 &
  local pid=$!
  sleep 4
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo "=== SWITCHBOARD_SOLO=$which ==="
  grep -E "^(jack|wiring|trace)|Warning|warning" ".metaphor/solo-$which.log" | head -20
}

# 自分のアプリを隠してもフレームが進むか（レンダーループの実測）。
# .displayLink 駆動なら止まり、.timer(fps:) 駆動なら回り続ける。
#   tools/probe.sh occlude            Syphon あり（externalRenderLoop が効くはず）
#   SWITCHBOARD_SOLO=aperture tools/probe.sh occlude   Syphon 無し（対照）
occlude() {
  mkdir -p .metaphor
  swift build 2>&1 | grep -E "error|Build complete" || true
  local tag="${SWITCHBOARD_SOLO:-all}"
  SWITCHBOARD_HIDE_AT=120 "$ROOT/$BIN" >".metaphor/occlude-$tag.log" 2>&1
  grep -E "^(wiring|occlude)" ".metaphor/occlude-$tag.log"
}

# 無人稼働で RSS / CPU の傾向を見る。前半平均と後半平均を比べる。
soak() {
  local secs="${2:-180}"
  swift build -c release 2>&1 | grep -E "error|Build complete" || true
  [ -x "$RELBIN" ] || { echo "release ビルドが無い: $RELBIN" >&2; exit 1; }
  mkdir -p .probe-out .metaphor
  local csv=".probe-out/soak-$(date +%Y%m%d-%H%M%S).csv"
  "$ROOT/$RELBIN" >".metaphor/soak.log" 2>&1 &
  local pid=$!
  echo "t,rss_mb,cpu_pct" >"$csv"
  # 起動前に ps を打つと RSS=0 を拾い、前半平均が下がって「増えた」ように見える（一度これで誤読した）。
  sleep 3
  local t=0
  while [ "$t" -lt "$secs" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "プロセスが $t 秒で落ちた。ログ:" >&2
      tail -20 ".metaphor/soak.log" >&2
      return 1
    fi
    local line
    line=$(ps -o rss=,%cpu= -p "$pid" | awk '{printf "%.1f,%s", $1/1024, $2}')
    case "$line" in 0.0,*) ;; *) echo "$t,$line" >>"$csv" ;; esac
    sleep 10
    t=$((t + 10))
  done
  kill "$pid" 2>/dev/null || true
  awk -F, 'NR>1 && $2+0 > 0 {n++; rss[n]=$2; cpu[n]=$3}
    END {
      h = int(n/2)
      for (i=1; i<=h; i++) { a+=rss[i]; ac+=cpu[i] }
      for (i=h+1; i<=n; i++) { b+=rss[i]; bc+=cpu[i] }
      printf "サンプル数=%d\n前半 RSS 平均=%.1fMB CPU 平均=%.1f%%\n後半 RSS 平均=%.1fMB CPU 平均=%.1f%%\n差分 RSS=%+.1fMB\n",
        n, a/h, ac/h, b/(n-h), bc/(n-h), b/(n-h)-a/h
    }' "$csv"
  echo "CSV: $csv"
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  snap) snap ;;
  checks) checks ;;
  cycle) cycle ;;
  trace) trace "$@" ;;
  solo) solo "$@" ;;
  occlude) occlude "$@" ;;
  soak) soak "$@" ;;
  *) sed -n '2,20p' "$0" ; exit 1 ;;
esac
