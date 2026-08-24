#!/bin/bash
# 0816-triptych の観測係。
#
#   tools/probe.sh check           自己検査を全部走らせて判定表を出す（破壊的な L/W5 群を含む）
#   tools/probe.sh run             作品として普通に起動する（軽い検査だけ）
#   tools/probe.sh trace [秒]      時計のずれ・fps・ウィンドウ位置を 2 秒ごとに出す（既定 40 秒）
#   tools/probe.sh own [秒]        翼を「自分の時計」で描かせる（継ぎ目が跳ぶのを見る用）
#   tools/probe.sh shots           3 パネルを 1 枚ずつ ~/Desktop へ書き出す
#   tools/probe.sh frames [dir]    GIF 用の連番 PNG を書き出す（既定 .probe-out/frames）
#   tools/probe.sh trap <名前>     落ちうる退化 config を再現する（zero / negative / huge / scalezero）
#   tools/probe.sh wings <n>       翼の枚数を振る（規模由来の穴を見る）
#   tools/probe.sh soak [秒] [CSV] 無人稼働。既定 180 秒（翼の開閉 42 秒 × 4 巡ぶん）
#   tools/probe.sh stop            走っているスケッチを止める
#
# 判定は標準出力に `[<ID>] PASS|FAIL ...` の形で出る。frame.json の `custom` にも
# `check.<ID>` として同じ内容が載る。
set -euo pipefail

cd "$(dirname "$0")/.."

binary_name="Sketch0816Triptych"
out_dir=".probe-out"

stop() {
    pkill -f "$binary_name" 2>/dev/null || true
}

# 「self-check 完了」が出たら判定がそろっているので止めてよい。
# 少し待ってから止めるのは saveFrame(_:) のため（書き出しはフレームの終わりに回る）。
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

# 一定秒数だけ走らせて出力を流す。
run_for() {
    local seconds="$1"
    swift run 2>&1 &
    local pid=$!
    sleep "$seconds"
    stop
    wait "$pid" 2>/dev/null || true
}

case "${1:-check}" in
check)
    stop
    sleep 1
    swift build >/dev/null
    TRIPTYCH_SELFTEST=1 run_until_done
    ;;

run)
    stop
    sleep 1
    swift build >/dev/null
    swift run
    ;;

trace)
    seconds="${2:-40}"
    stop
    sleep 1
    swift build >/dev/null
    TRIPTYCH_TRACE=1 run_for "$seconds"
    ;;

own)
    # 翼が自分の時計（ctx.time）で描くとどうなるか。継ぎ目の跳びを絵で見る用。
    seconds="${2:-40}"
    stop
    sleep 1
    swift build >/dev/null
    TRIPTYCH_CLOCK=own TRIPTYCH_TRACE=1 run_for "$seconds"
    ;;

shots)
    stop
    sleep 1
    swift build >/dev/null
    TRIPTYCH_SHOTS=1 run_until_done 4
    echo "→ output/triptych-center.png / triptych-wing-0.png / triptych-wing-1.png"
    ;;

frames)
    stop
    sleep 1
    swift build >/dev/null
    dir="${2:-$PWD/$out_dir/frames}"
    mkdir -p "$dir"
    echo "連番 PNG → $dir"
    TRIPTYCH_FRAMES="$dir" run_for "${3:-20}"
    ;;

trap)
    name="${2:-}"
    if [ -z "$name" ]; then
        echo "使い方: tools/probe.sh trap <zero|negative|huge|scalezero>" >&2
        exit 2
    fi
    stop
    sleep 1
    swift build >/dev/null
    mkdir -p "$out_dir"
    # 落ちるかどうかを見るので、終了コードもそのまま見せる。
    # 落ちない trap（scalezero）は走り続けるので 10 秒で打ち切る。
    set +e
    TRIPTYCH_TRAP="$name" ./.build/debug/"$binary_name" >"$out_dir/trap-$name.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "→ 10 秒たっても生きている（abort しない）"
        kill -TERM "$pid"
        code="alive"
    else
        wait "$pid"
        code=$?
    fi
    set -e
    cat "$out_dir/trap-$name.log"
    stop
    echo "exit=$code"
    ;;

wings)
    n="${2:-4}"
    seconds="${3:-30}"
    stop
    sleep 1
    swift build >/dev/null
    TRIPTYCH_WINGS="$n" TRIPTYCH_TRACE=1 run_for "$seconds"
    ;;

soak)
    # 既定 180 秒。翼の開閉は 42 秒で 1 巡するので 4 巡ぶん入る。
    # 傾向が出たときだけ 1800 秒へ延ばす（延長条件は sketch-verification スキルの §7）。
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
    # rss=0 の行は捨てる。起動直後の 1 サンプルが 0 で入ることがあり、
    # そのまま平均すると前半だけが不当に低く出て「増えている」と誤読する。
    awk -F, 'NR>1 && $2+0>0 {n++;r[n]=$2;c[n]=$3}END{
        h=int(n/2); a=0; b=0; ca=0; cb=0
        for(i=1;i<=h;i++){a+=r[i];ca+=c[i]}
        for(i=h+1;i<=n;i++){b+=r[i];cb+=c[i]}
        if(h>0 && n-h>0){
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
    sed -n '2,16p' "$0"
    exit 2
    ;;
esac
