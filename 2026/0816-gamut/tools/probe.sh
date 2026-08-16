#!/bin/bash
# 0816-gamut の観測係。
#
#   tools/probe.sh check          自己検査（B/A/L/P/G/R 系）を走らせて表を出す
#   tools/probe.sh determinism    check を 2 回走らせて出力が同一かを見る
#   tools/probe.sh shots          3 つの表示を 1 枚ずつ書き出す
#   tools/probe.sh frames [dir]   GIF 用の連番 PNG（既定 .probe-out/frames）
#   tools/probe.sh trace          重なりの実測を流し続ける
#   tools/probe.sh soak [秒] [CSV] 無人稼働。既定 1800 秒
#   tools/probe.sh stop           走っているスケッチを止める
#
# 判定は標準出力にも frame.json の `custom`（`check.<ID>`）にも出る。
# 「self-check 完了」の行が出たら全部そろっている。
set -euo pipefail

cd "$(dirname "$0")/.."

binary_name="Sketch0816Gamut"
out_dir=".probe-out"

stop() {
    pkill -f "$binary_name" 2>/dev/null || true
}

# 「self-check 完了」が出るまで待って止める。
#
# 出力はログへ落としてから流す。パイプで読みながら pkill すると、bash が
# 「Terminated: 15」をパイプラインの中身として判定表の後ろに吐いて読みにくい。
run_until_done() {
    local log="$1"
    mkdir -p "$out_dir"
    : > "$log"
    swift run > "$log" 2>&1 &
    local pid=$!
    for _ in $(seq 1 120); do
        grep -q "self-check 完了" "$log" 2>/dev/null && break
        sleep 0.5
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    grep -q "self-check 完了" "$log" || { echo "!! self-check が完了しなかった"; tail -20 "$log"; return 1; }
}

case "${1:-check}" in
check)
    stop
    sleep 1
    run_until_done "$out_dir/check.log"
    grep -E "^(PASS|FAIL)|^self-check" "$out_dir/check.log"
    ;;

determinism)
    # 検査は描画も実時計も使わないので、何度走らせても同じ数値が出るはず。
    stop
    sleep 1
    run_until_done "$out_dir/check-1.log"
    grep -E "^(PASS|FAIL)" "$out_dir/check-1.log" > "$out_dir/run-1.txt"
    stop
    sleep 1
    run_until_done "$out_dir/check-2.log"
    grep -E "^(PASS|FAIL)" "$out_dir/check-2.log" > "$out_dir/run-2.txt"
    if diff -u "$out_dir/run-1.txt" "$out_dir/run-2.txt" > "$out_dir/determinism.diff"; then
        echo "==> 2 回の出力は完全に一致した（$(wc -l < "$out_dir/run-1.txt" | tr -d ' ') 件）"
    else
        echo "!! 2 回の出力が食い違った。決定論が壊れている:"
        cat "$out_dir/determinism.diff"
        exit 1
    fi
    ;;

shots)
    stop
    sleep 1
    mkdir -p "$out_dir"
    rm -f "$HOME/Desktop/gamut-"{compare,light,pigment}.png
    GAMUT_SHOTS=1 swift run > "$out_dir/shots.log" 2>&1 || true
    # saveFrame(_:) は渡した名前へ無条件で ~/Desktop/ を前置する（metaphor#757。
    # main では修正済みだが v0.9.0 では未リリース）ので、ここで引き取る
    for name in compare light pigment; do
        [ -f "$HOME/Desktop/gamut-$name.png" ] && mv "$HOME/Desktop/gamut-$name.png" "$out_dir/"
    done
    echo "==> $out_dir/gamut-{compare,light,pigment}.png"
    ;;

frames)
    stop
    sleep 1
    dir="${2:-$PWD/$out_dir/frames}"
    rm -rf "$dir"
    mkdir -p "$dir"
    echo "==> $dir へ連番 PNG"
    GAMUT_FRAMES="$dir" swift run > "$out_dir/frames.log" 2>&1 &
    sleep "${3:-14}"
    stop
    sleep 1
    echo "==> $(ls "$dir" | wc -l | tr -d ' ') 枚"
    ;;

trace)
    stop
    sleep 1
    mkdir -p "$out_dir"
    GAMUT_TRACE=1 swift run 2>&1 | grep --line-buffered -E "^\[trace\]|^self-check"
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

stop)
    stop
    echo "==> 停止した"
    ;;

*)
    sed -n '2,14p' "$0"
    exit 1
    ;;
esac
