#!/bin/bash
# 0816-encore の観測係。
#
#   tools/probe.sh check           自己検査（T/M/I 系）を走らせて判定表を出す
#   tools/probe.sh twice           check を 2 回走らせて差分を取る（決定論の確認）
#   tools/probe.sh trace [秒]      進行表を stdout へ流しながら回す（既定 40 秒 = 2 公演）
#   tools/probe.sh shots           1 公演目とアンコールの要所を 1 枚ずつ書き出す
#   tools/probe.sh frames [dir]    GIF 用の連番 PNG（既定 .probe-out/frames）
#   tools/probe.sh soak [秒] [CSV] 無人稼働。既定 180 秒（≒ 10 公演）
#   tools/probe.sh stop            走っているスケッチを止める
#
# 判定は標準出力にも frame.json の `custom`（`check.<ID>`）にも出る。
# 「self-check 完了」の行が出たら全部そろっている。
set -euo pipefail

cd "$(dirname "$0")/.."

binary_name="Sketch0816Encore"
out_dir=".probe-out"

stop() {
    pkill -f "$binary_name" 2>/dev/null || true
}

# 「self-check 完了」が出るまで待って止める。
#
# 出力はログへ落としてから流す。パイプで読みながら pkill すると、bash が
# 「Terminated: 15」をパイプラインの中身として判定表の後ろに吐いて読みにくい。
run_until_done() {
    mkdir -p "$out_dir"
    local log="$1"
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
    # T/M/I 系は setup() で、M8〜M10 は起動から 2 秒で出る
    run_until_done "$out_dir/check.log"
    grep -E "^(PASS|FAIL)|^FAIL 一覧|^self-check" "$out_dir/check.log"
    ;;

twice)
    # 同じ判定が 2 回とも 1 バイトも違わないことを見る。
    # 描画も時計も使っていない検査なので、ここが揺れたら検査の書き方が悪い。
    stop
    sleep 1
    run_until_done "$out_dir/check-a.log"
    stop
    sleep 1
    run_until_done "$out_dir/check-b.log"
    # 比べるのは setup() の決定論的な検査（T / M1〜M7 / I 系）だけ。
    # M8〜M10 はフレームループ側の観測で、detail に実時計（time）が入るので当然揺れる。
    for f in a b; do
        grep -E "^(PASS|FAIL) (T|I|M[1-7]\.)" "$out_dir/check-$f.log" > "$out_dir/verdicts-$f.txt"
    done
    if diff -u "$out_dir/verdicts-a.txt" "$out_dir/verdicts-b.txt"; then
        echo "==> 決定論的な検査は 2 回とも同一（$(wc -l < "$out_dir/verdicts-a.txt" | tr -d ' ') 件）"
        echo "    M8〜M10 は実時計を含むので比較から外している"
    else
        echo "!! 実行のたびに判定が変わっている"
        exit 1
    fi
    ;;

trace)
    stop
    sleep 1
    mkdir -p "$out_dir"
    duration="${2:-40}"
    log="$out_dir/trace.log"
    echo "==> $duration 秒ぶん進行表を流す（1 公演 ≒ 17.2 秒）"
    ENCORE_TRACE=1 swift run > "$log" 2>&1 &
    pid=$!
    trap 'kill $pid 2>/dev/null || true' EXIT
    sleep "$duration"
    kill "$pid" 2>/dev/null || true
    trap - EXIT
    grep -E "^\[trace\]|^self-check 完了" "$log"
    ;;

shots)
    stop
    sleep 1
    mkdir -p "$out_dir"
    rm -f "$HOME/Desktop/encore-"{act1,bow,encore}.png
    echo "==> 2 公演ぶん回して 3 枚（act1 / bow / encore）"
    ENCORE_SHOTS=1 swift run > "$out_dir/shots.log" 2>&1 &
    pid=$!
    trap 'kill $pid 2>/dev/null || true' EXIT
    for _ in $(seq 1 120); do
        grep -q "self-check 完了(shots)" "$out_dir/shots.log" 2>/dev/null && break
        sleep 0.5
    done
    sleep 2
    kill "$pid" 2>/dev/null || true
    trap - EXIT
    # saveFrame(_:) は渡した名前へ無条件で ~/Desktop/ を前置する（metaphor#757。
    # main では修正済みだが v0.9.0 では未リリース）ので、ここで引き取る
    for name in act1 bow encore; do
        [ -f "$HOME/Desktop/encore-$name.png" ] && mv "$HOME/Desktop/encore-$name.png" "$out_dir/"
    done
    ls -1 "$out_dir"/encore-*.png 2>/dev/null || echo "!! 書き出されなかった"
    ;;

frames)
    stop
    sleep 1
    dir="${2:-$PWD/$out_dir/frames}"
    secs="${3:-40}"
    rm -rf "$dir"
    mkdir -p "$dir"
    echo "==> $dir へ連番 PNG（$secs 秒ぶん）"
    # beginFrameRecord(directory:) は絶対パスを尊重する（saveFrame と違う）
    ENCORE_FRAMES="$dir" swift run > "$out_dir/frames.log" 2>&1 &
    pid=$!
    trap 'kill $pid 2>/dev/null || true' EXIT
    sleep "$secs"
    kill "$pid" 2>/dev/null || true
    trap - EXIT
    sleep 1
    echo "==> $(ls "$dir" | wc -l | tr -d ' ') 枚"
    ;;

soak)
    duration="${2:-180}"
    csv="${3:-$out_dir/soak-$(date +%Y%m%d-%H%M%S).csv}"
    mkdir -p "$(dirname "$csv")"
    stop
    sleep 1

    echo "==> release ビルド"
    swift build -c release > /dev/null

    echo "==> $duration 秒のソーク → $csv"
    # 進行表も一緒に吐かせて、tweenManager.count を CSV に混ぜる。
    # 未 start の Tween が溜まるなら、ここが単調増加として出る（M3 / M10 の実地版）。
    ENCORE_TRACE=1 .build/release/"$binary_name" > "${csv%.csv}.log" 2>&1 &
    sketch_pid=$!
    trap 'kill $sketch_pid 2>/dev/null || true' EXIT

    # 進行表からいまの値を拾う。**起動直後はログが空で grep が空振りする**ので、
    # set -euo pipefail のもとでは `|| true` で受けないとスクリプトごと落ちる（実際に踏んだ）。
    last_value() {
        (grep -o "$1" "${csv%.csv}.log" 2>/dev/null || true) | tail -1 | tr -dc '0-9'
    }

    echo "elapsed,rssMB,cpuPercent,tweens,performance" > "$csv"
    start=$(date +%s)
    while kill -0 "$sketch_pid" 2>/dev/null; do
        now=$(date +%s)
        elapsed=$((now - start))
        [ "$elapsed" -ge "$duration" ] && break
        read -r rss cpu <<< "$(ps -o rss=,pcpu= -p "$sketch_pid" | tr -s ' ')" || true
        tweens=$(last_value 'count=[0-9]*')
        perf=$(last_value '公演[0-9]*')
        echo "$elapsed,$(echo "scale=1; $rss/1024" | bc),$cpu,${tweens:-0},${perf:-0}" >> "$csv"
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
for key, unit in (("rssMB", "MB"), ("cpuPercent", "%"), ("tweens", " 本")):
    first, second = avg(rows[:half], key), avg(rows[half:], key)
    print(f"  {key:12} 前半 {first:8.1f}{unit}  後半 {second:8.1f}{unit}  差 {second - first:+.1f}{unit}")
print(f"  tweens  最小 {min(int(r['tweens']) for r in rows)} / 最大 {max(int(r['tweens']) for r in rows)}"
      f"（溜まるなら単調増加するはず）")
print(f"  公演数 {rows[-1]['performance']}、サンプル数 {len(rows)}、計測時間 {rows[-1]['elapsed']} 秒")
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
