#!/bin/bash
# 0816-escapement の観測係。
#
#   tools/probe.sh check          自己検査（M/E/W/R/C/T/L 系）を走らせて表を出す
#   tools/probe.sh input          stdin へ台本どおりの入力を流して I 系まで判定する
#   tools/probe.sh shots          3 面を一巡して 1 枚ずつ書き出す
#   tools/probe.sh frames [dir]   GIF 用の連番 PNG を書き出す（既定 .probe-out/frames）
#   tools/probe.sh soak [秒] [CSV] 無人稼働。既定 1800 秒
#   tools/probe.sh trap <名前>     落ちうる呼び出しを 1 つだけ踏む
#   tools/probe.sh stop           走っているスケッチを止める
#
# 判定は標準出力にも frame.json の `custom`（`check.<ID>`）にも出る。
# 「self-check 完了」の行が出たら全部そろっている。
set -euo pipefail

cd "$(dirname "$0")/.."

binary_name="Sketch0816Escapement"
out_dir=".probe-out"

stop() {
    pkill -f "$binary_name" 2>/dev/null || true
}

# 「self-check 完了」が出るまで待って止める。
#
# 出力はログへ落としてから流す。パイプで読みながら pkill すると、bash が
# 「Terminated: 15」とパイプラインの中身を判定表の後ろに吐いて読みにくい。
run_until_done() {
    mkdir -p "$out_dir"
    local log="$out_dir/check.log"
    : > "$log"
    swift run > "$log" 2>&1 &
    local pid=$!
    for _ in $(seq 1 120); do
        grep -q "self-check 完了" "$log" 2>/dev/null && break
        sleep 0.5
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    cat "$log"
    grep -q "self-check 完了" "$log" || { echo "!! self-check が完了しなかった"; return 1; }
}

case "${1:-check}" in
check)
    stop
    sleep 1
    # M/E/W/R/C 系は setup() で、T 系はフレーム 140 で、L 系は起動から約 8.3 秒で出る
    run_until_done
    ;;

input)
    stop
    sleep 1
    mkdir -p "$out_dir"
    log="$out_dir/input.log"
    fifo="$out_dir/stdin.fifo"
    rm -f "$fifo" "$log"
    mkfifo "$fifo"

    # 入力注入プラグインを SketchConfig.plugins 経由で明示登録させる
    # （headless でなくても stdin を読むはず、という仮説の検証）
    ESCAPEMENT_INJECT=1 swift run < "$fifo" > "$log" 2>&1 &
    sketch_pid=$!
    # fifo を開いたままにしておかないと、1 行流すたびに EOF になる
    exec 3> "$fifo"
    trap 'exec 3>&-; kill $sketch_pid 2>/dev/null || true; rm -f "$fifo"' EXIT

    echo "==> READY-INPUT を待つ（L 系まで終わるのに約 9 秒）"
    for _ in $(seq 1 90); do
        grep -q "READY-INPUT" "$log" 2>/dev/null && break
        sleep 1
    done
    grep -q "READY-INPUT" "$log" || { echo "!! READY-INPUT が出なかった"; tail -20 "$log"; exit 1; }

    # 台本。App 側の I 系はこの順番と値を前提に判定する
    send() { printf '%s\n' "$1" >&3; sleep 0.35; }
    echo "==> 台本を流す"
    send '{"t":"mouseMove","x":300,"y":200}'
    send '{"t":"mouseMove","x":500,"y":400}'
    send '{"t":"mouseDown","x":500,"y":400,"button":0}'
    send '{"t":"mouseUp","x":500,"y":400,"button":0}'
    send '{"t":"keyDown","code":126,"chars":"^","repeat":false}'
    send '{"t":"keyDown","code":126,"chars":"^","repeat":true}'
    send '{"t":"keyUp","code":126}'
    send '{"t":"scroll","dx":0,"dy":3}'

    for _ in $(seq 1 20); do
        grep -q "self-check 完了" "$log" 2>/dev/null && break
        sleep 0.5
    done
    exec 3>&-
    stop
    trap - EXIT
    rm -f "$fifo"
    cat "$log"
    ;;

shots)
    stop
    sleep 1
    mkdir -p "$out_dir"
    rm -f "$HOME/Desktop/escapement-"{dial,regulator,oscillogram}.png
    ESCAPEMENT_SHOTS=1 swift run 2>&1 | while IFS= read -r line; do
        printf '%s\n' "$line"
        case "$line" in
        *"[shot] escapement-oscillogram.png"*)
            sleep 2
            stop
            break
            ;;
        esac
    done
    # saveFrame(_:) は渡した名前へ無条件で ~/Desktop/ を前置する（metaphor#757。
    # main では修正済みだが v0.9.0 では未リリース）ので、ここで引き取る
    for name in dial regulator oscillogram; do
        [ -f "$HOME/Desktop/escapement-$name.png" ] && mv "$HOME/Desktop/escapement-$name.png" "$out_dir/"
    done
    echo "==> $out_dir/escapement-{dial,regulator,oscillogram}.png"
    ;;

frames)
    stop
    sleep 1
    dir="${2:-$PWD/$out_dir/frames}"
    rm -rf "$dir"
    mkdir -p "$dir"
    echo "==> $dir へ連番 PNG（10 秒ぶん）"
    ESCAPEMENT_FRAMES="$dir" swift run > "$out_dir/frames.log" 2>&1 &
    sleep 20
    stop
    sleep 1
    echo "==> $(ls "$dir" | wc -l | tr -d ' ') 枚"
    ;;

soak)
    duration="${2:-1800}"
    csv="${3:-$out_dir/soak-$(date +%Y%m%d-%H%M%S).csv}"
    mkdir -p "$(dirname "$csv")"
    stop
    sleep 1

    echo "==> release ビルド"
    swift build -c release > /dev/null

    echo "==> $duration 秒のソーク → $csv"
    .build/release/"$binary_name" > "${csv%.csv}.log" 2>&1 &
    sketch_pid=$!
    trap 'kill $sketch_pid 2>/dev/null || true' EXIT

    echo "elapsed,rssMB,cpuPercent" > "$csv"
    start=$(date +%s)
    while kill -0 "$sketch_pid" 2>/dev/null; do
        now=$(date +%s)
        elapsed=$((now - start))
        [ "$elapsed" -ge "$duration" ] && break
        read -r rss cpu <<< "$(ps -o rss=,pcpu= -p "$sketch_pid" | tr -s ' ')"
        echo "$elapsed,$(echo "scale=1; $rss/1024" | bc),$cpu" >> "$csv"
        sleep 10
    done

    kill "$sketch_pid" 2>/dev/null || true
    trap - EXIT

    echo "==> 前半平均 / 後半平均（リークと劣化の判定）"
    python3 - "$csv" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
if len(rows) < 4:
    print("サンプルが足りない"); sys.exit(0)
half = len(rows) // 2
def avg(sl, key): return sum(float(r[key]) for r in sl) / len(sl)
for key, unit in (("rssMB", "MB"), ("cpuPercent", "%")):
    first, second = avg(rows[:half], key), avg(rows[half:], key)
    print(f"  {key:12} 前半 {first:8.1f}{unit}  後半 {second:8.1f}{unit}  差 {second - first:+.1f}{unit}")
print(f"  サンプル数 {len(rows)}、計測時間 {rows[-1]['elapsed']} 秒")
PY
    ;;

trap)
    stop
    sleep 1
    name="${2:-}"
    [ -z "$name" ] && { echo "使い方: tools/probe.sh trap <名前>"; name="list"; }
    echo "==> ESCAPEMENT_TRAP=$name"
    ESCAPEMENT_TRAP="$name" swift run 2>&1 | head -25 || true
    stop
    ;;

stop)
    stop
    echo "==> 停止した"
    ;;

*)
    sed -n '2,14p' "$0"
    exit 1
    ;;
esac
