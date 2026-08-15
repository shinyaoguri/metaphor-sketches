#!/bin/bash
# アセット入れ替えの長時間ソーク。既定 30 分。
#
#   scripts/soak.sh [秒数] [cache: off|library] [出力CSV]
#
# この作品の主題は「シーンごとにアセットが入れ替わる」こと。周回ごとに
# モデル / テクスチャ / 音 / 動画を読み直すので、**解放漏れがあればメモリが
# 単調に増える**。1 本目（0815-strata）はリソースを共有していたため、この
# 経路の負荷はここで初めて測る。
#
#   cache=off      … loadModel/loadImage を cache:false で読む（作品側が寿命を持つ）
#   cache=library  … ライブラリのキャッシュに任せる（SALVAGE_ASSET_CACHE=1）
#
# Probe の `performance` は単一フレーム経路にしか載らない（CONTRACT.md 契約点 4）ので
# 連続キャプチャではなく request 方式で 1 サンプルずつ取る。
set -euo pipefail

cd "$(dirname "$0")/.."

duration="${1:-1800}"
cache_mode="${2:-off}"
csv="${3:-.probe-out/soak-${cache_mode}-$(date +%Y%m%d-%H%M%S).csv}"
interval=10
probe_dir=".metaphor/probe"
bin=".build/release/Sketch0815Salvage"

mkdir -p "$(dirname "$csv")" "$probe_dir"

echo "==> building release"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
  swift build -c release > /dev/null

pkill -f Sketch0815Salvage 2>/dev/null || true
sleep 1
rm -rf "$probe_dir/current"

asset_cache=0
[ "$cache_mode" = "library" ] && asset_cache=1

echo "==> launching (duration=${duration}s interval=${interval}s cache=${cache_mode})"
METAPHOR_PROBE=1 SALVAGE_DEMO=1 SALVAGE_ASSET_CACHE="$asset_cache" \
  "$bin" > .probe-out/soak-${cache_mode}.log 2>&1 &
app_pid=$!

cleanup() {
  kill "$app_pid" 2>/dev/null || true
  pkill -f Sketch0815Salvage 2>/dev/null || true
}
trap cleanup EXIT

sleep 8  # 起動 + 最初のフレームが安定するまで

echo "elapsed,scene,transitions,cycles,fps,frameMeanMs,frameMaxMs,memoryMB,cpuPercent,thermal,assetsLive,assetsLoads,assetsFrees,assetLoadMs" > "$csv"

start=$(date +%s)
while :; do
  now=$(date +%s)
  elapsed=$((now - start))
  [ "$elapsed" -ge "$duration" ] && break

  id="soak-$elapsed"
  printf '{"id":"%s","label":"soak","scale":0.25}\n' "$id" > "$probe_dir/request.json"

  got=""
  for _ in $(seq 1 60); do
    if [ -f "$probe_dir/current/frame.json" ] &&
       grep -q "\"id\"[[:space:]]*:[[:space:]]*\"$id\"" "$probe_dir/current/frame.json" 2>/dev/null; then
      got="yes"; break
    fi
    sleep 0.1
  done

  if [ -n "$got" ]; then
    python3 - "$probe_dir/current/frame.json" "$elapsed" >> "$csv" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
p = d.get("performance", {}) or {}
c = d.get("custom", {}) or {}
ft = p.get("frameTimeMs") or {}
def g(v):
    return "" if v is None else v
print(",".join(str(x) for x in [
    sys.argv[2], g(c.get("scene")), g(c.get("sceneTransitions")), g(c.get("cycles")),
    g(p.get("fps")), g(ft.get("mean")), g(ft.get("max")),
    g(p.get("memoryMB")), g(p.get("cpuPercent")), g(p.get("thermalState")),
    g(c.get("assetsLive")), g(c.get("assetsLoads")), g(c.get("assetsFrees")),
    g(c.get("assetLoadMs")),
]))
PY
  else
    echo "$elapsed,,,,,,,,TIMEOUT,,,,," >> "$csv"
    echo "  [!] probe timeout at ${elapsed}s"
  fi

  sleep "$interval"
done

pkill -f Sketch0815Salvage 2>/dev/null || true
echo "==> csv: $csv"
python3 scripts/soak-report.py "$csv"
