#!/bin/bash
# 0816-prism の観測係。
#
#   tools/probe.sh check          自己検査（A/B/G/P/I 系）を走らせて表を出す
#   tools/probe.sh shots          4 場面を一巡して 1 枚ずつ書き出す（~/Desktop へ）
#   tools/probe.sh frames [dir]   GIF 用の連番 PNG を書き出す（既定 .probe-out/frames）
#   tools/probe.sh soak [秒] [CSV] 無人稼働。既定 1800 秒
#   tools/probe.sh trap <名前>     落ちうる呼び出しを 1 つだけ踏む
#   tools/probe.sh stop           走っているスケッチを止める
#
# 判定は標準出力にも frame.json の `custom`（`check.<ID>`）にも出る。
# 「self-check 完了」の行が出たら全層（A → B → G/P/I）がそろっている。
set -euo pipefail

cd "$(dirname "$0")/.."

binary_name="Sketch0816Prism"
out_dir=".probe-out"

stop() {
    pkill -f "$binary_name" 2>/dev/null || true
}

# 「self-check 完了」が出るまで待って止める。
#
# 出力はログへ落としてから流す。パイプで読みながら pkill すると、bash が
# 「Terminated: 15」をパイプラインの中身として判定表の後ろへ吐いて読みにくい。
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
    run_until_done
    ;;

shots)
    stop
    mkdir -p "$out_dir"
    log="$out_dir/shots.log"
    : > "$log"
    # `saveFrame` は渡した名前に無条件で ~/Desktop を前置する（metaphor#757）ので、
    # 出力先はここでは選べない。書き出し先は ~/Desktop。
    PRISM_SHOTS=1 swift run > "$log" 2>&1 &
    pid=$!
    for _ in $(seq 1 120); do
        grep -q "shots 完了" "$log" 2>/dev/null && break
        sleep 0.5
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    cat "$log"
    echo "→ ~/Desktop の prism-*.png を見る"
    ;;

frames)
    stop
    dir="${2:-$out_dir/frames}"
    mkdir -p "$dir"
    echo "連番 PNG を $dir へ書き出す（Ctrl-C か tools/probe.sh stop で止める）"
    PRISM_FRAMES="$(cd "$dir" && pwd)" swift run
    ;;

soak)
    stop
    seconds="${2:-1800}"
    csv="${3:-$out_dir/soak.csv}"
    mkdir -p "$out_dir"
    swift build -c release > /dev/null
    ./.build/release/"$binary_name" > "$out_dir/soak.log" 2>&1 &
    pid=$!
    echo "elapsed,rss_mb,cpu_pct" > "$csv"
    start=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
        now=$(date +%s)
        elapsed=$((now - start))
        [ "$elapsed" -ge "$seconds" ] && break
        read -r rss cpu <<< "$(ps -o rss=,pcpu= -p "$pid" | tr -s ' ')" || break
        echo "$elapsed,$(echo "scale=1; $rss/1024" | bc),$cpu" >> "$csv"
        sleep 10
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "→ $csv"
    # 前半平均と後半平均を比べる。伸び続けていればリークを疑う。
    awk -F, 'NR>1{n++; a[n]=$2} END{
        if (n < 4) { print "サンプルが少なく比較できない"; exit }
        h=int(n/2); s1=0; s2=0
        for(i=1;i<=h;i++) s1+=a[i]
        for(i=h+1;i<=n;i++) s2+=a[i]
        printf "RSS 前半平均 %.1f MB / 後半平均 %.1f MB / 差 %+.1f MB\n", s1/h, s2/(n-h), s2/(n-h)-s1/h
    }' "$csv"
    ;;

trap)
    stop
    name="${2:-}"
    [ -z "$name" ] && { echo "使い方: tools/probe.sh trap <名前>"; exit 1; }
    mkdir -p "$out_dir"
    log="$out_dir/trap-$name.log"
    : > "$log"
    # 落ちるかどうかを見るので、終了コードは握りつぶさず読む。
    set +e
    PRISM_TRAP="$name" swift run > "$log" 2>&1 &
    pid=$!
    for _ in $(seq 1 60); do
        kill -0 "$pid" 2>/dev/null || break
        grep -q "self-check 完了" "$log" 2>/dev/null && break
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        verdict="生き残った（落ちない）"
    else
        wait "$pid" 2>/dev/null
        code=$?
        verdict="プロセスが終了した（code=$code）"
    fi
    set -e
    cat "$log"
    echo "→ trap $name: $verdict"
    ;;

stop)
    stop
    echo "止めた"
    ;;

*)
    sed -n '2,12p' "$0"
    exit 1
    ;;
esac
