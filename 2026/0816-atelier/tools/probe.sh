#!/bin/bash
# 0816-atelier の観測係。
#
#   tools/probe.sh check           採寸だけを 5 場面ぶん回して判定表を出す（素描は畳む）
#   tools/probe.sh watch           素描込みで一巡させ、判定が出そろったところで止める
#   tools/probe.sh stage <1-5>     1 場面に固定して走らせる（止めるまで回り続ける）
#   tools/probe.sh shots           場面ごとに 1 枚ずつ ~/Desktop へ書き出す
#   tools/probe.sh frames [dir]    GIF 用の連番 PNG を書き出す（既定 .probe-out/frames）
#   tools/probe.sh trap <名前>     落ちうる口を再現する（引数なしで一覧）
#   tools/probe.sh soak [秒] [CSV] 無人稼働。既定 180 秒（skill §7: まず短く、怪しければ延ばす）
#   tools/probe.sh stop            走っているスケッチを止める
#
# 判定は標準出力に `[<ID>] PASS|FAIL|LOOK 本文` の形で出るので frame.json を待たずに読める。
# 同じ内容が frame.json の `custom` にも `check.<ID>` として載る。
set -euo pipefail

cd "$(dirname "$0")/.."

binary_name="Sketch0816Atelier"
out_dir=".probe-out"

stop() {
    pkill -f "$binary_name" 2>/dev/null || true
}

# 「self-check 完了」が出たら 5 場面ぶんの判定がそろっている。
#
# 止める前に少し待つのは saveFrame(_:) のため。書き出しはフレームの終わりに回されるので、
# 合図を見た直後に kill すると最後の場面の PNG が落ちる。
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
    ATELIER_FAST=1 run_until_done 1
    ;;

watch)
    stop
    sleep 1
    swift build >/dev/null
    run_until_done 3
    ;;

stage)
    n="${2:-}"
    if [ -z "$n" ]; then
        echo "使い方: tools/probe.sh stage <1=形 2=明暗 3=奥行き 4=影 5=手>" >&2
        exit 2
    fi
    stop
    sleep 1
    swift build >/dev/null
    ATELIER_STAGE="$n" swift run
    ;;

shots)
    stop
    sleep 1
    swift build >/dev/null
    ATELIER_SHOTS=1 run_until_done 9
    echo "→ ~/Desktop/atelier-1.png … atelier-5.png"
    ;;

frames)
    stop
    sleep 1
    swift build >/dev/null
    dir="${2:-$PWD/$out_dir/frames}"
    mkdir -p "$dir"
    echo "連番 PNG → $dir"
    # 判定が出そろったあとも一巡ぶん回し続けたいので、ここでは止めない。
    ATELIER_FRAMES="$dir" swift run
    ;;

trap)
    name="${2:-}"
    if [ -z "$name" ]; then
        echo "使い方: tools/probe.sh trap <名前>" >&2
        echo "  detailNegative   sphere(detail: -8) / torus(detail: -3)" >&2
        echo "  detailZero       cylinder(detail: 0) / cone(detail: 0)" >&2
        echo "  zeroSize         plane(0,0) / box(0) / sphere(0) / torus(0,0)" >&2
        echo "  negativeSize     box(-120) / sphere(-80) / cylinder(-50,-50)" >&2
        echo "  meshZero         createBoxMesh(0) など生成側の退化寸法" >&2
        echo "  shadowZero       enableShadows(resolution: 0)" >&2
        echo "  shadowNegative   enableShadows(resolution: -1)" >&2
        echo "  orthoDegenerate  ortho(left:100, right:100, …) 幅ゼロの視体積" >&2
        echo "  cameraDegenerate camera(eye: p, center: p)" >&2
        echo "  materialBadSource createMaterial に通らない MSL" >&2
        exit 2
    fi
    stop
    sleep 1
    swift build >/dev/null
    # 落ちるかどうかを見るので、終了コードもそのまま見せる。
    set +e
    ATELIER_TRAP="$name" swift run 2>&1 | head -60
    code=${PIPESTATUS[0]}
    set -e
    stop
    echo "exit=$code"
    ;;

soak)
    seconds="${2:-180}"
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
    awk -F, 'NR>1{n++;r[n]=$2;c[n]=$3}END{
        h=int(n/2); a=0; b=0; ca=0; cb=0
        for(i=1;i<=h;i++) { a+=r[i]; ca+=c[i] }
        for(i=h+1;i<=n;i++) { b+=r[i]; cb+=c[i] }
        if(h>0 && n-h>0) {
            printf "サンプル %d 件\n", n
            printf "RSS 前半平均 %.1fMB → 後半平均 %.1fMB (差 %+.1fMB)\n", a/h, b/(n-h), b/(n-h)-a/h
            printf "CPU 前半平均 %.1f%% → 後半平均 %.1f%% (差 %+.1f%%)\n", ca/h, cb/(n-h), cb/(n-h)-ca/h
        }
    }' "$csv"
    ;;

stop)
    stop
    ;;

*)
    sed -n '2,13p' "$0"
    exit 2
    ;;
esac
