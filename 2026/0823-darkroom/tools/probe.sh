#!/usr/bin/env bash
# 暗室を起動して観測するための 1 本のスクリプト。
#
#   tools/probe.sh start           ビルドして起動 (Probe 有効)
#   tools/probe.sh snap            1 フレーム撮って frame.json を出す
#   tools/probe.sh checks          撮ったフレームから check.* と probe 値を抜く
#   tools/probe.sh cycle           stop → start → 検査が出るまで待って checks
#   tools/probe.sh stop            停止
#   tools/probe.sh trace [秒]      3 槽の publish 回数・クロック差を標準出力で追う (既定 20 秒)
#   tools/probe.sh env [名前]      METAPHOR_SYPHON_NAME を当てて起動 (D3。既定 "darkroom - ENV")
#   tools/probe.sh anon            DARKROOM_ANON=1 で起動し、3 本が何を名乗るか見る (D4)
#   tools/probe.sh occlude [秒]    起動 N 秒後にアプリを隠し、publish が続くか (D7。既定 28 秒)
#   tools/probe.sh term            SIGTERM で落として、サーバーが後始末されるか (D9)
#   tools/probe.sh stoptest        宣言 + 環境変数で 2 本立てて stopSyphonServer() を 1 回 (D11)
#   tools/probe.sh shots           3 枚を output/ へ書き出す
#   tools/probe.sh frames [dir]    GIF 用の連番 PNG を 3 枚ぶん書き出す
#   tools/probe.sh soak <秒>       release ビルドで無人稼働し RSS / CPU の傾向を見る
#
# 判定は標準出力にも frame.json にも出る。**外から 3 本を読むのは tools/syphon-read.sh**。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BIN=".build/debug/Sketch0823Darkroom"
RELBIN=".build/release/Sketch0823Darkroom"
PROBE=".metaphor/probe"
PIDFILE=".metaphor/darkroom.pid"
LOG=".metaphor/run.log"

build() {
  swift build 2>&1 | grep -E "error|Build complete" || true
  [ -x "$BIN" ] || { echo "ビルド成果物が無い: $BIN" >&2; exit 1; }
}

is_running() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

start() {
  build
  if is_running; then echo "既に起動中 (pid $(cat "$PIDFILE"))"; return 0; fi
  mkdir -p .metaphor
  rm -f "$PROBE/current/frame.json"
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
        | sort_by(.key)[]
        | "\(.value | sub(" .*"; ""))\t\(.key | sub("^check\\."; ""))\t\(.value | sub("^(PASS|FAIL|LOOK|N/A) +"; ""))"),
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
  while [ $i -lt 60 ]; do
    sleep 1
    if snap >/dev/null 2>&1; then
      if grep -q '"check\.D8' "$PROBE/current/frame.json" 2>/dev/null; then
        checks
        return 0
      fi
    fi
    i=$((i + 1))
  done
  echo "検査が frame.json に現れなかった。ログ:" >&2
  tail -30 "$LOG" >&2
  return 1
}

# 3 槽の publish 回数とクロック差を時系列で追う。
trace() {
  local secs="${2:-20}"
  build
  mkdir -p .metaphor
  DARKROOM_TRACE=1 "$ROOT/$BIN" >".metaphor/trace.log" 2>&1 &
  local pid=$!
  sleep "$secs"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -E "^\[(trace|工程|窓|occlude)\]|^(PASS|FAIL|LOOK|N/A) " ".metaphor/trace.log" | head -60
}

# D3 — 環境変数はプライマリにしか効かないはず。
env_scope() {
  local name="${2:-darkroom - ENV}"
  build
  mkdir -p .metaphor
  METAPHOR_SYPHON_NAME="$name" DARKROOM_TRACE=1 "$ROOT/$BIN" >".metaphor/env.log" 2>&1 &
  local pid=$!
  # サーバーの一覧は起動しきってから撮る（Syphon のディレクトリは非同期に埋まる）。
  sleep 8
  echo "=== 立っているサーバー ==="
  tools/syphon-servers.sh || true
  sleep 14
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo "=== 判定 ==="
  grep -E "^(PASS|FAIL|LOOK|N/A) D" ".metaphor/env.log" || tail -20 ".metaphor/env.log"
}

# D4 — 名前を省略すると 3 窓とも同じ名前を名乗る。外から何本見えるか。
anon() {
  build
  mkdir -p .metaphor
  DARKROOM_ANON=1 DARKROOM_TRACE=1 "$ROOT/$BIN" >".metaphor/anon.log" 2>&1 &
  local pid=$!
  sleep 8
  echo "=== 立っているサーバー（DARKROOM_ANON=1）==="
  tools/syphon-servers.sh || true
  sleep 14
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo "=== 判定 ==="
  grep -E "^(PASS|FAIL|LOOK|N/A) D" ".metaphor/anon.log" || tail -20 ".metaphor/anon.log"
}

# D7 — 隠しても publish が続くか（.externalRenderLoop の promotion がセカンダリで効くか）。
# **開閉検査（D6）が終わってから隠す。** 早すぎると、閉じている最中の窓が
# 「止まった」ではなく「対象外」として判定から落ちる（実際 8 秒で C が抜けた）。
occlude() {
  local at="${2:-28}"
  build
  mkdir -p .metaphor
  # **フォアグラウンドで走らせない。** 作品は自分で終了しないので、待つと戻ってこない。
  DARKROOM_HIDE_AT="$at" "$ROOT/$BIN" >".metaphor/occlude.log" 2>&1 &
  local pid=$!
  sleep $((at + 12))
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -E "^\[occlude\]|^(PASS|FAIL) D7" ".metaphor/occlude.log"
}

# D9 — SIGTERM で落としたあと、Syphon サーバーが directory に残らないか。
term() {
  build
  mkdir -p .metaphor
  "$ROOT/$BIN" >".metaphor/term.log" 2>&1 &
  local pid=$!
  sleep 8
  echo "=== 落とす前 ==="
  tools/syphon-servers.sh || true
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  sleep 2
  echo "=== SIGTERM の後（darkroom の行が残っていれば FAIL）==="
  tools/syphon-servers.sh || true
}

# D11 — 宣言 .syphon(name:) と METAPHOR_SYPHON_NAME を両方立ててから 1 回止める。
# 同じ pluginID が 2 つ並ぶので、facade は片方にしか届かないはず。
stoptest() {
  local name="${2:-darkroom - ENV}"
  build
  mkdir -p .metaphor
  METAPHOR_SYPHON_NAME="$name" DARKROOM_STOPTEST=1 "$ROOT/$BIN" >".metaphor/stoptest.log" 2>&1 &
  local pid=$!
  sleep 6
  echo "=== 止める前（4 本立っているはず）==="
  tools/syphon-servers.sh || true
  sleep 6
  echo "=== stopSyphonServer() を 1 回呼んだ後 ==="
  tools/syphon-servers.sh || true
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo "=== 判定 ==="
  grep -E "^(PASS|FAIL|LOOK|N/A) D11|^\[metaphor\].*already registered|addPlugin" ".metaphor/stoptest.log" || true
}

shots() {
  build
  mkdir -p .metaphor
  DARKROOM_SHOTS=1 "$ROOT/$BIN" >".metaphor/shots.log" 2>&1 &
  local pid=$!
  sleep 26
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -E "^\[shots\]" ".metaphor/shots.log" || true
  ls -1 output/*.png 2>/dev/null || echo "output/ に PNG が無い"
}

frames() {
  local dir="${2:-.probe-out/frames}"
  build
  mkdir -p "$dir" .metaphor
  DARKROOM_FRAMES="$dir" "$ROOT/$BIN" >".metaphor/frames.log" 2>&1 &
  local pid=$!
  sleep 24
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  for d in A B C; do
    echo "$dir/$d: $(ls -1 "$dir/$d" 2>/dev/null | wc -l | tr -d ' ') 枚"
  done
}

# 無人稼働で RSS / CPU の傾向を見る。前半平均と後半平均を比べる。
#
# **1 巡 60 秒**（露光 → 現像 → 停止 → 定着）なので、2 巡を確保するなら 180 秒以上。
soak() {
  local secs="${2:-180}"
  swift build -c release 2>&1 | grep -E "error|Build complete" || true
  [ -x "$RELBIN" ] || { echo "release ビルドが無い: $RELBIN" >&2; exit 1; }
  mkdir -p .probe-out .metaphor
  local csv=".probe-out/soak-$(date +%Y%m%d-%H%M%S).csv"
  "$ROOT/$RELBIN" >".metaphor/soak.log" 2>&1 &
  local pid=$!
  echo "t,rss_mb,cpu_pct" >"$csv"
  # 起動前に ps を打つと RSS=0 を拾い、前半平均が下がって「増えた」ように見える。
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
  env) env_scope "$@" ;;
  anon) anon ;;
  occlude) occlude "$@" ;;
  term) term ;;
  stoptest) stoptest "$@" ;;
  shots) shots ;;
  frames) frames "$@" ;;
  soak) soak "$@" ;;
  *) sed -n '2,20p' "$0" ; exit 1 ;;
esac
