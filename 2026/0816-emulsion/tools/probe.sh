#!/bin/bash
# 0816-emulsion の観測係。
#
#   tools/probe.sh check          自己検査（L/M/G/X 群）を走らせて表を出す
#   tools/probe.sh twice          check を 2 回走らせ、判定行が完全に一致するか見る（決定論）
#   tools/probe.sh shots          4 場面を一巡して 1 枚ずつ書き出す（~/Desktop へ）
#   tools/probe.sh frames [dir]   GIF 用の連番 PNG を書き出す（既定 .probe-out/frames）
#   tools/probe.sh soak [秒] [CSV] 無人稼働。既定 180 秒（4 場面 × 15 秒 = 1 巡 60 秒 → 3 巡）
#   tools/probe.sh trap <名前>     落ちうる呼び出しを 1 つだけ踏む（list で名前の一覧）
#   tools/probe.sh scene <0-3>    場面を 1 つに固定して走らせ続ける（証跡を撮るとき用）
#   tools/probe.sh stop           走っているスケッチを止める
#
# 判定は標準出力にも frame.json の `custom`（`check.<ID>`）にも出る。
# 「self-check 完了」の行が出たら L → M → G → X が全てそろっている。
set -uo pipefail

cd "$(dirname "$0")/.."

binary_name="Sketch0816Emulsion"
out_dir=".probe-out"

stop() {
    pkill -f "$binary_name" 2>/dev/null || true
}

# 「self-check 完了」が出るまで待って止める。
#
# 出力はログへ落としてから流す。パイプで読みながら pkill すると、bash が
# 「Terminated: 15」をパイプラインの中身として判定表の後ろへ吐いて読みにくい。
run_until_done() {
    local log="${1:-$out_dir/check.log}"
    mkdir -p "$out_dir"
    : > "$log"
    swift run > "$log" 2>&1 &
    local pid=$!
    for _ in $(seq 1 120); do
        grep -q "self-check 完了" "$log" 2>/dev/null && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    grep -q "self-check 完了" "$log" || { cat "$log"; echo "!! self-check が完了しなかった"; return 1; }
}

case "${1:-check}" in
check)
    stop
    run_until_done "$out_dir/check.log" || exit 1
    cat "$out_dir/check.log"
    ;;

# 決定論の確認。**2 回続けて同じ数値が出ること**が、この作品の検査を
# 信じてよい条件（0816-marionette 以来の作法）。読み戻しは GPU の
# タイミングに触るので、ここが揺れたら判定そのものを疑う。
twice)
    stop
    run_until_done "$out_dir/check-1.log" || exit 1
    stop
    run_until_done "$out_dir/check-2.log" || exit 1
    grep -E '^(PASS|FAIL|LOOK) ' "$out_dir/check-1.log" > "$out_dir/verdicts-1.txt"
    grep -E '^(PASS|FAIL|LOOK) ' "$out_dir/check-2.log" > "$out_dir/verdicts-2.txt"
    if diff -u "$out_dir/verdicts-1.txt" "$out_dir/verdicts-2.txt" > "$out_dir/verdicts.diff"; then
        echo "決定論: 2 回とも完全に同じ（$(wc -l < "$out_dir/verdicts-1.txt" | tr -d ' ') 行）"
        cat "$out_dir/verdicts-1.txt"
    else
        echo "!! 決定論が崩れている。差分:"
        cat "$out_dir/verdicts.diff"
        exit 1
    fi
    ;;

shots)
    stop
    mkdir -p "$out_dir"
    log="$out_dir/shots.log"
    : > "$log"
    # `saveFrame` は渡した名前に無条件で ~/Desktop を前置する（metaphor#757）ので、
    # 出力先はここでは選べない。書き出し先は ~/Desktop。
    EMULSION_SHOTS=1 swift run > "$log" 2>&1 &
    pid=$!
    for _ in $(seq 1 240); do
        grep -q "shots 完了" "$log" 2>/dev/null && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    cat "$log"
    echo "→ ~/Desktop の emulsion-*.png を見る"
    ;;

frames)
    stop
    dir="${2:-$out_dir/frames}"
    mkdir -p "$dir"
    # `beginFrameRecord(directory:)` は `saveFrame` と違って絶対パスを尊重する。
    echo "連番 PNG を $dir へ書き出す（Ctrl-C か tools/probe.sh stop で止める）"
    EMULSION_FRAMES="$(cd "$dir" && pwd)" swift run
    ;;

soak)
    stop
    # 既定は 180 秒。**まず短く回して、怪しければ 1800 秒へ延ばす。**
    # この作品は 1 巡 60 秒なので 180 秒で 3 巡し、場面遷移とグラフの
    # 差し替えを 3 回ずつ通る（巡回しきらないとリークの出る経路を通らない）。
    seconds="${2:-180}"
    csv="${3:-$out_dir/soak.csv}"
    mkdir -p "$out_dir"
    swift build -c release > /dev/null
    ./.build/release/"$binary_name" > "$out_dir/soak.log" 2>&1 &
    pid=$!
    echo "elapsed,rss_mb,cpu_pct" > "$csv"
    start=$(date +%s)
    # 立ち上がりを比較に混ぜない。起動直後は RSS が 0 → 83 → 86 と伸びるので、
    # そこを前半に入れると「後半で増えた」と必ず読めてしまう（実際に一度誤読した）。
    warmup=30
    while kill -0 "$pid" 2>/dev/null; do
        now=$(date +%s)
        elapsed=$((now - start))
        [ "$elapsed" -ge "$seconds" ] && break
        read -r rss cpu <<< "$(ps -o rss=,pcpu= -p "$pid" | tr -s ' ')" || break
        if [ "$elapsed" -ge "$warmup" ] && [ "$rss" -gt 0 ] 2>/dev/null; then
            echo "$elapsed,$(echo "scale=1; $rss/1024" | bc),$cpu" >> "$csv"
        fi
        sleep 10
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    else
        echo "!! ソーク中にプロセスが落ちた（$out_dir/soak.log を見る）"
    fi
    echo "→ $csv"
    # 前半平均と後半平均を比べる。伸び続けていればリークを疑う。
    awk -F, 'NR>1{n++; a[n]=$2; c[n]=$3} END{
        if (n < 4) { print "サンプルが少なく比較できない"; exit }
        h=int(n/2); s1=0; s2=0; d1=0; d2=0
        for(i=1;i<=h;i++) { s1+=a[i]; d1+=c[i] }
        for(i=h+1;i<=n;i++) { s2+=a[i]; d2+=c[i] }
        printf "サンプル %d 件（起動から 30 秒ぶんは比較に入れていない）\n", n
        printf "RSS 前半平均 %.1f MB / 後半平均 %.1f MB / 差 %+.1f MB\n", s1/h, s2/(n-h), s2/(n-h)-s1/h
        printf "CPU 前半平均 %.1f %% / 後半平均 %.1f %% / 差 %+.1f %%\n", d1/h, d2/(n-h), d2/(n-h)-d1/h
    }' "$csv"
    ;;

trap)
    stop
    name="${2:-list}"
    mkdir -p "$out_dir"
    log="$out_dir/trap-$name.log"
    : > "$log"
    # 落ちるかどうかを見るので、終了コードは握りつぶさず読む。
    set +e
    EMULSION_TRAP="$name" swift run > "$log" 2>&1 &
    pid=$!
    for _ in $(seq 1 90); do
        kill -0 "$pid" 2>/dev/null || break
        grep -q "trap 完了" "$log" 2>/dev/null && break
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

# 場面を固定して走らせ続ける。巡回を待たずに 1 場面を撮れるようにするための口。
# 15 秒ごとに切り替わるのを待ちながらウィンドウを撮るのは、
# 撮れたコマが毎回ずれて証跡として使いにくい。
scene)
    stop
    idx="${2:-0}"
    echo "場面 $idx に固定して走らせる（Ctrl-C か tools/probe.sh stop で止める）"
    EMULSION_SCENE="$idx" swift run
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
