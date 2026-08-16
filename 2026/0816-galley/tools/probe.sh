#!/bin/bash
# 0816-galley の観測係。
#
#   tools/probe.sh check           自己検査だけ走らせて判定表を出す（起動 → 5 面を巡回 → 停止）
#   tools/probe.sh shots           5 面を一巡して ~/Desktop へ 1 枚ずつ書き出す
#   tools/probe.sh sweep           textSize 掃引の CSV を出す（描画を待たない）
#   tools/probe.sh frames [dir]    GIF 用の連番 PNG を書き出す（既定 .probe-out/frames）
#   tools/probe.sh trap <名前>     落ちうる入力を再現する（zero / negative / huge / atlas）
#   tools/probe.sh soak [秒] [CSV] 無人稼働。既定 1800 秒
#   tools/probe.sh stop            走っているスケッチを止める
#
# 判定は起動直後（計量 G 群）と各面の組み上がり（P 群）で標準出力に出るので、
# frame.json を待たずに読める。frame.json の `custom` にも `check.<ID>` として同じ内容が載る。
set -euo pipefail

cd "$(dirname "$0")/.."

binary_name="Sketch0816Galley"
out_dir=".probe-out"

stop() {
    pkill -f "$binary_name" 2>/dev/null || true
}

# 「self-check 完了」が出たら全面の判定がそろっているので止めてよい。
#
# 止める前に少し待つのは saveFrame(_:) のため。書き出しはフレームの終わりに回されるので、
# 合図を見た直後に kill すると最後の面の PNG が落ちる (実際に 5 枚目だけ出なかった)。
run_until_done() {
    local grace="${1:-3}"
    swift run 2>&1 | while IFS= read -r line; do
        printf '%s\n' "$line"
        case "$line" in
        *"self-check 完了"*)
            sleep "$grace"
            stop
            break
            ;;
        esac
    done
}

case "${1:-check}" in
check)
    stop
    sleep 1
    swift build >/dev/null
    run_until_done
    ;;

shots)
    stop
    sleep 1
    swift build >/dev/null
    GALLEY_SHOTS=1 run_until_done
    echo "→ ~/Desktop/galley-1.png … galley-5.png"
    ;;

sweep)
    stop
    sleep 1
    swift build >/dev/null
    # 掃引は setup() で出し切るので、最初の面の判定まで待てば十分。
    GALLEY_SWEEP=1 swift run 2>&1 | while IFS= read -r line; do
        printf '%s\n' "$line"
        case "$line" in
        *"[P9."*) stop; break ;;
        esac
    done
    ;;

frames)
    stop
    sleep 1
    swift build >/dev/null
    dir="${2:-$PWD/$out_dir/frames}"
    mkdir -p "$dir"
    echo "連番 PNG → $dir"
    GALLEY_FRAMES="$dir" swift run 2>&1 | while IFS= read -r line; do
        printf '%s\n' "$line"
        case "$line" in
        *"self-check 完了"*) ;;   # 完了後も巡回を続けて GIF 用のフレームを溜める
        esac
    done
    ;;

trap)
    name="${2:-}"
    if [ -z "$name" ]; then
        echo "使い方: tools/probe.sh trap <zero|negative|huge|atlas>" >&2
        exit 2
    fi
    stop
    sleep 1
    swift build >/dev/null
    # 落ちるかどうかを見るので、終了コードもそのまま見せる。
    set +e
    GALLEY_TRAP="$name" swift run 2>&1 | head -60
    code=${PIPESTATUS[0]}
    set -e
    stop
    echo "exit=$code"
    ;;

soak)
    seconds="${2:-1800}"
    csv="${3:-$out_dir/soak.csv}"
    stop
    sleep 1
    mkdir -p "$(dirname "$csv")"
    swift build -c release >/dev/null
    ./.build/release/"$binary_name" >/dev/null 2>&1 &
    pid=$!
    echo "t_sec,rss_mb,cpu_pct" >"$csv"
    start=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
        now=$(date +%s)
        t=$((now - start))
        [ "$t" -ge "$seconds" ] && break
        read -r rss cpu <<<"$(ps -o rss=,%cpu= -p "$pid" | tr -s ' ')" || true
        [ -n "${rss:-}" ] && echo "$t,$((rss / 1024)),$cpu" >>"$csv"
        sleep 10
    done
    kill "$pid" 2>/dev/null || true
    echo "→ $csv"
    awk -F, 'NR>1{n++;r[n]=$2}END{
        h=int(n/2); a=0; b=0
        for(i=1;i<=h;i++) a+=r[i]
        for(i=h+1;i<=n;i++) b+=r[i]
        if(h>0 && n-h>0) printf "RSS 前半平均 %.1fMB → 後半平均 %.1fMB (差 %+.1fMB)\n", a/h, b/(n-h), b/(n-h)-a/h
    }' "$csv"
    ;;

stop)
    stop
    ;;

*)
    sed -n '2,12p' "$0"
    exit 2
    ;;
esac
