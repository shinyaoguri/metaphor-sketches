#!/bin/bash
# 0816-marionette の観測係。
#
#   tools/probe.sh check          自己検査だけを走らせて表を出す（起動 → 判定 → 停止）
#   tools/probe.sh shots          4 場面を一巡して ~/Desktop へ 1 枚ずつ書き出す
#   tools/probe.sh soak [秒] [CSV] 無人稼働。既定 1800 秒
#   tools/probe.sh trap           負の iterations でプロセスが落ちるのを再現する
#   tools/probe.sh stop           走っているスケッチを止める
#
# 自己検査は起動時に標準出力へ出るので、frame.json を待たずに読める
# （frame.json の `custom` にも `check.<ID>` として同じ内容が載る）。
set -euo pipefail

cd "$(dirname "$0")/.."

binary_name="Sketch0816Marionette"

stop() {
    pkill -f "$binary_name" 2>/dev/null || true
}

case "${1:-check}" in
check)
    stop
    sleep 1
    # 静的な検査は setup() で、書き出し系はフレーム 90 で判定が出る。
    # 「self-check 完了」の行が出たら全部そろっているので止めてよい
    swift run 2>&1 | while IFS= read -r line; do
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
    rm -f "$HOME/Desktop/marionette-"{chain,cloth,pit,swarm}.png
    MARIONETTE_SHOTS=1 swift run 2>&1 | while IFS= read -r line; do
        printf '%s\n' "$line"
        case "$line" in
        *"[shot] swarm"*)
            sleep 2
            stop
            break
            ;;
        esac
    done
    echo "==> ~/Desktop/marionette-{chain,cloth,pit,swarm}.png"
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
    .build/release/"$binary_name" > "${csv%.csv}.log" 2>&1 &
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
    stop
    sleep 1
    echo "==> MARIONETTE_TRAP=iterations（v0.9.0 では fatalError で落ちるのが期待）"
    MARIONETTE_TRAP=iterations swift run 2>&1 | head -20 || true
    ;;

stop)
    stop
    echo "==> 停止した"
    ;;

*)
    sed -n '2,12p' "$0"
    exit 1
    ;;
esac
