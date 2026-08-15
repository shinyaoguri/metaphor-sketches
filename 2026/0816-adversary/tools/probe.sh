#!/usr/bin/env bash
# 検査盤を起動して Probe で観測するための 1 本のスクリプト。
#
#   tools/probe.sh start        ビルドして起動 (Probe 有効)
#   tools/probe.sh snap [key]   1 フレーム撮って frame.json を出す (key を渡すとキー入力を送ってから)
#   tools/probe.sh checks       撮ったフレームから check.* / summary.* だけを抜く
#   tools/probe.sh stop         停止
#   tools/probe.sh cycle        stop → start → 全面が判定済みになるまで待って checks
#
# frame.json が一次証拠。画像は FAIL の裏取りにだけ使う。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BIN=".build/debug/Sketch0816Adversary"
PROBE=".metaphor/probe"
PIDFILE=".metaphor/adversary.pid"
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
  METAPHOR_PROBE=1 ADVERSARY_PLANE="${ADVERSARY_PLANE:-}" "$ROOT/$BIN" >"$LOG" 2>&1 &
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

# frame.json から検査結果だけを抜く (jq があれば整形、無ければ grep)。
checks() {
  local f="$PROBE/current/frame.json"
  [ -f "$f" ] || { echo "frame.json が無い。先に snap してください" >&2; exit 1; }
  if command -v jq >/dev/null; then
    jq -r '
      (.custom | to_entries
        | map(select(.key | startswith("summary.")))
        | sort_by(.key)[] | "\(.key)\t\(.value)"),
      "",
      (.custom | to_entries
        | map(select(.key | startswith("check.")))
        | sort_by(.key)[] | "\(.key)\t\(.value)")
    ' "$f"
  else
    grep -o '"check\.[^"]*":"[^"]*"' "$f" | tr -d '"' | tr ':' '\t'
  fi
}

# 起動しなおして全面が判定済みになるまで待ち、結果を出す。
cycle() {
  stop >/dev/null 2>&1 || true
  start
  # 起動 (cold start) を待ってから、全面が判定済みになるまでポーリング
  local i=0
  while [ $i -lt 40 ]; do
    sleep 1
    if snap >/dev/null 2>&1; then
      local judged planes
      judged=$(jq -r '.custom["summary.planesJudged"] // 0' "$PROBE/current/frame.json" 2>/dev/null || echo 0)
      planes=$(jq -r '.custom["summary.planeCount"] // 0' "$PROBE/current/frame.json" 2>/dev/null || echo 0)
      if [ "$judged" != "0" ] && [ "$judged" = "$planes" ]; then
        checks
        return 0
      fi
    fi
    i=$((i + 1))
  done
  echo "全面の判定が終わらなかった。最後のフレーム:" >&2
  checks
  return 1
}

# 指定した面を表示させた状態で PNG を撮り、必要ならセルを切り出す。
#   tools/probe.sh shot F [cell-index]
shot() {
  local plane="${2:-A}"
  local cell="${3:-}"
  stop >/dev/null 2>&1 || true
  ADVERSARY_PLANE="$plane" start
  local i=0
  while [ $i -lt 40 ]; do
    sleep 1
    if snap >/dev/null 2>&1; then
      local judged planes
      judged=$(jq -r '.custom["summary.planesJudged"] // 0' "$PROBE/current/frame.json" 2>/dev/null || echo 0)
      planes=$(jq -r '.custom["summary.planeCount"] // 0' "$PROBE/current/frame.json" 2>/dev/null || echo 0)
      if [ "$judged" = "$planes" ] && [ "$judged" != "0" ]; then
        snap >/dev/null
        local out=".metaphor/shot-$plane.png"
        cp "$PROBE/current/frame.png" "$out"
        if [ -n "$cell" ]; then
          # レイアウト (App.swift と同じ計算) からセル矩形を出して切り出す
          local total cols rows margin top gap cw ch cx cy col row
          total=$(jq -r '.custom["summary.cellCount"] // 9' "$PROBE/current/frame.json")
          cols=3; margin=20; top=62; gap=12
          rows=$(( (total + cols - 1) / cols ))
          col=$(( cell % cols ))
          row=$(( cell / cols ))
          cw=$(echo "(1280 - $margin*2 - $gap*($cols-1)) / $cols" | bc -l)
          ch=$(echo "(720 - $top - $margin - $gap*($rows-1)) / $rows" | bc -l)
          cx=$(echo "$margin + $col * ($cw + $gap)" | bc -l)
          cy=$(echo "$top + $row * ($ch + $gap)" | bc -l)
          out=".metaphor/shot-$plane-$cell.png"
          ffmpeg -y -loglevel error -i "$PROBE/current/frame.png" \
            -vf "crop=$(printf '%.0f:%.0f:%.0f:%.0f' "$cw" "$ch" "$cx" "$cy")" "$out"
        fi
        echo "$out"
        return 0
      fi
    fi
    i=$((i + 1))
  done
  echo "面 $plane の表示待ちでタイムアウト" >&2
  return 1
}

case "${1:-}" in
  start) start ;;
  shot) shot "$@" ;;
  stop) stop ;;
  snap) snap ;;
  checks) checks ;;
  cycle) cycle ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
