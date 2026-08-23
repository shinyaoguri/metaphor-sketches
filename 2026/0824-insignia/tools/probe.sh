#!/bin/bash
# 0824-insignia の観測係。
#
#   tools/probe.sh check           自己検査だけを走らせて表を出す（起動 → 判定 → 停止）
#   tools/probe.sh shots           4 プリセットを output/ へ 1 枚ずつ書き出す
#   tools/probe.sh contrast        影の対照実験。worldScale 120 / 1 を影と床つきで撮り比べる
#   tools/probe.sh frames [出力先]  自動回転 1 周ぶんの連番 PNG（アニメーション WebP のもと）
#   tools/probe.sh soak [秒] [CSV] 無人稼働。既定 180 秒。影オンで走らせる（後述）
#   tools/probe.sh stop            走っているスケッチを止める
#
# ソークを影オンで走らせるのは、`dynamicMesh()` が影オンのときだけ
# `makeSnapshotMesh()` の記録経路に入り、**静的なメッシュでも毎フレーム Mesh を作り直す**ため。
# 27k 頂点ぶんの GPU バッファが毎フレーム生まれる経路なので、RSS の傾向はここで見る意味がある。
set -euo pipefail

cd "$(dirname "$0")/.."

binary_name="Sketch0824Insignia"

stop() {
    pkill -f "$binary_name" 2>/dev/null || true
}

case "${1:-check}" in
check)
    stop
    sleep 1
    # 自己検査は setup() で走るので、最初の数行に全部出る
    swift run 2>&1 | while IFS= read -r line; do
        printf '%s\n' "$line"
        case "$line" in
        *"PASS ──"*)
            stop
            break
            ;;
        esac
    done
    ;;

shots)
    stop
    sleep 1
    INSIGNIA_SHOTS=1 swift run 2>&1 | grep -E "^\[shot\]|PASS|FAIL" || true
    echo "==> output/insignia-{m,iso,top,axis}.png"
    ;;

contrast)
    stop
    sleep 1
    echo "==> worldScale=120（既定）影オン + 床"
    INSIGNIA_SHOTS=1 INSIGNIA_FLOOR=1 swift run 2>&1 | grep -E "S1\.|^\[shot\]" || true
    echo "==> worldScale=1（仕様どおりの論理単位）影オン + 床"
    INSIGNIA_SHOTS=1 INSIGNIA_FLOOR=1 INSIGNIA_SCALE=1 swift run 2>&1 | grep -E "S1\.|^\[shot\]" || true
    echo "==> 影の焼き付け範囲は作品側から指定できない（sceneRadius が 500 固定）ので、"
    echo "    小さい単位系では影がマップ上で数十 px に潰れる。2 枚を並べて見る"
    ;;

frames)
    stop
    sleep 1
    out="${2:-.probe-out/frames}"
    rm -rf "$out"
    mkdir -p "$out"
    INSIGNIA_FRAMES="$out" swift run 2>&1 | grep -E "^\[frames\]" || true
    echo "==> $(ls "$out" | wc -l | tr -d ' ') 枚。アニメーション WebP は次の 2 手で組む"
    echo "    ffmpeg -i $out/frame_%05d.png -vf \"select='not(mod(n\\,4))',scale=720:-1:flags=lanczos\" -fps_mode passthrough .probe-out/small/f_%04d.png"
    echo "    img2webp -loop 0 -mixed -d 67 .probe-out/small/f_*.png -o .probe-out/insignia-spin.webp"
    ;;

soak)
    duration="${2:-180}"
    csv="${3:-.probe-out/soak-$(date +%Y%m%d-%H%M%S).csv}"
    mkdir -p "$(dirname "$csv")"
    stop
    sleep 1

    echo "==> release ビルド"
    swift build -c release > /dev/null

    shadows="${INSIGNIA_SHADOWS:-1}"
    echo "==> $duration 秒のソーク（影 $shadows・自動回転）→ $csv"
    INSIGNIA_SHADOWS="$shadows" INSIGNIA_SPIN=1 .build/release/"$binary_name" > "${csv%.csv}.log" 2>&1 &
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
        # 起動直後は ps が空を返すことがある。0MB のサンプルを混ぜると平均が濁るので捨てる
        if [ -n "${rss:-}" ] && [ "$rss" -gt 0 ] 2>/dev/null; then
            echo "$elapsed,$(echo "scale=1; $rss/1024" | bc),$cpu" >> "$csv"
        fi
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
    sed -n '2,13p' "$0"
    exit 1
    ;;
esac
