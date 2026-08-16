#!/bin/bash
# 0816-sounding の観測係。
#
#   tools/probe.sh check          自己検査だけを走らせて表を出す（起動 → 判定 → 停止）
#   tools/probe.sh shots          4 枚を ~/Desktop へ書き出す
#   tools/probe.sh frames [秒]     GIF 用の連番 PNG を .probe-out/frames へ書き出す
#   tools/probe.sh soak [秒] [CSV] 無人稼働。既定 1800 秒（音は鳴らさない）
#   tools/probe.sh trap [名前]     頼んだときだけ既知の穴を踏む
#   tools/probe.sh stop           走っているスケッチを止める
#
# 自己検査は起動時に標準出力へ出るので、frame.json を待たずに読める
# （frame.json の `custom` にも `check.<ID>` として同じ内容が載る）。
set -euo pipefail

cd "$(dirname "$0")/.."

binary_name="Sketch0816Sounding"

stop() {
    pkill -f "$binary_name" 2>/dev/null || true
}

case "${1:-check}" in
check)
    stop
    sleep 1
    # 自己検査は setup() で出そろう。「self-check 完了」を見たら止めてよい。
    SOUNDING_MUTE=1 swift run 2>&1 | while IFS= read -r line; do
        printf '%s\n' "$line"
        case "$line" in
        *"self-check 完了"*)
            stop
            break
            ;;
        esac
    done
    ;;

shots)
    stop
    sleep 1
    rm -f "$HOME/Desktop/sounding-"{1,2,3,4}.png
    SOUNDING_MUTE=1 SOUNDING_SHOTS=1 swift run 2>&1 | while IFS= read -r line; do
        printf '%s\n' "$line"
        case "$line" in
        *"[shot] sounding-4.png"*)
            sleep 2
            stop
            break
            ;;
        esac
    done
    echo "==> ~/Desktop/sounding-{1,2,3,4}.png"
    ;;

frames)
    duration="${2:-12}"
    directory="$(pwd)/.probe-out/frames"
    stop
    sleep 1
    rm -rf "$directory"
    mkdir -p "$directory"
    # GIF は動きが判定材料なので release で撮る（debug は PNG 書き出しでコマ落ちする）。
    swift build -c release > /dev/null
    # beginFrameRecord(directory:) は絶対パスを尊重する（saveFrame は ~/Desktop 前置）。
    SOUNDING_MUTE=1 SOUNDING_FRAMES="$directory" \
        .build/release/"$binary_name" > "$directory/../frames.log" 2>&1 &
    sketch_pid=$!
    sleep "$duration"
    kill "$sketch_pid" 2>/dev/null || true
    stop
    echo "==> $(ls "$directory" | wc -l | tr -d ' ') 枚 → $directory"
    echo "    GIF 化: ffmpeg -framerate 20 -i $directory/frame_%05d.png -vf scale=640:-1 out.gif"
    ;;

soak)
    duration="${2:-1800}"
    csv="${3:-.probe-out/soak-$(date +%Y%m%d-%H%M%S).csv}"
    mkdir -p "$(dirname "$csv")"
    stop
    sleep 1

    echo "==> release ビルド"
    swift build -c release > /dev/null

    echo "==> $duration 秒のソーク → $csv"
    SOUNDING_MUTE=1 .build/release/"$binary_name" > "${csv%.csv}.log" 2>&1 &
    sketch_pid=$!
    trap 'kill $sketch_pid 2>/dev/null || true' EXIT

    echo "elapsed,rssMB,cpuPercent" > "$csv"
    start=$(date +%s)
    while kill -0 "$sketch_pid" 2>/dev/null; do
        now=$(date +%s)
        elapsed=$((now - start))
        [ "$elapsed" -ge "$duration" ] && break
        # rss は KB で出るので MB へ直す
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
    delta = second - first
    print(f"  {key:12} 前半 {first:8.1f}{unit}  後半 {second:8.1f}{unit}  差 {delta:+.1f}{unit}")
print(f"  サンプル数 {len(rows)}、計測時間 {rows[-1]['elapsed']} 秒")
PY
    ;;

trap)
    name="${2:-grid}"
    stop
    sleep 1
    echo "==> SOUNDING_TRAP=$name"
    # 診断は setup() の中で走るので、終わったころに止める。
    # パイプへ繋いだまま head で切ると、スケッチが生き残って戻ってこない。
    log=".probe-out/trap-$name.log"
    mkdir -p .probe-out
    SOUNDING_MUTE=1 SOUNDING_TRAP="$name" swift run > "$log" 2>&1 &
    sketch_pid=$!
    trap 'kill $sketch_pid 2>/dev/null || true' EXIT
    for _ in $(seq 1 120); do
        grep -q "self-check 完了" "$log" 2>/dev/null && break
        sleep 1
    done
    sleep 2
    kill "$sketch_pid" 2>/dev/null || true
    trap - EXIT
    stop
    grep "\[trap\]" "$log" || echo "!! [trap] の行が出なかった。$log を読むこと"
    ;;

stop)
    stop
    echo "==> 停止した"
    ;;

*)
    sed -n '2,13p' "$0"
    exit 1
    ;;
esac
