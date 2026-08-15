#!/bin/bash
# 無人稼働ソーク。既定 30 分。
#
#   scripts/soak.sh [秒数] [出力CSV]
#
# やること:
#   1. release ビルドを .app に包んで起動（カメラの TCC は .app でしか通らない）
#   2. 10 秒ごとに Probe へリクエストを出し、performance と custom を CSV へ追記
#   3. 並行して OSC を流し込む（シーン切替・パラメータ書き込み・ping）
#   4. 終了時に前半平均 / 後半平均を比べて劣化とリークを判定
#
# Probe の `performance` は単一フレーム経路にしか載らない（CONTRACT.md 契約点 4）ので
# 連続キャプチャではなく request 方式で 1 サンプルずつ取る。
set -euo pipefail

cd "$(dirname "$0")/.."

duration="${1:-1800}"
csv="${2:-.probe-out/soak-$(date +%Y%m%d-%H%M%S).csv}"
interval=10
probe_dir=".metaphor/probe"

mkdir -p "$(dirname "$csv")" "$probe_dir"

echo "==> building .app"
./scripts/make-app.sh release > /dev/null

pkill -f Sketch0815Strata 2>/dev/null || true
sleep 1
rm -rf "$probe_dir/current"

echo "==> launching (duration=${duration}s interval=${interval}s)"
open -n .build/strata.app \
  --env METAPHOR_PROBE=1 \
  --env "STRATA_WORKDIR=$PWD" \
  --env STRATA_WIDTH=1920 \
  --env STRATA_HEIGHT=1080 \
  --env STRATA_HOLD=90 \
  --env STRATA_SYPHON=1

cleanup() {
  pkill -f Sketch0815Strata 2>/dev/null || true
}
trap cleanup EXIT

sleep 12  # 起動 + 最初のフレームが安定するまで

echo "elapsed,scene,switches,fps,frameMeanMs,frameMaxMs,memoryMB,cpuPercent,thermal,camSamples,camAuth,oscMsgs,energy" > "$csv"

start=$(date +%s)
tick=0
while :; do
  now=$(date +%s)
  elapsed=$((now - start))
  [ "$elapsed" -ge "$duration" ] && break

  # --- OSC を流す（無人稼働の駆動源かつ受信経路の生存確認）---
  python3 scripts/osc-send.py /ping > /dev/null 2>&1 || true
  if [ $((tick % 6)) -eq 3 ]; then
    # 60 秒ごとにパラメータを揺らす（Parameter Store の外部書き込み経路）
    v=$(python3 -c "import math,sys;print(round(1.0+0.35*math.sin($tick/6.0),3))")
    python3 scripts/osc-send.py /param/elevationScale "$v" > /dev/null 2>&1 || true
  fi
  if [ $((tick % 12)) -eq 11 ]; then
    # 120 秒ごとに外部からシーンを進める（自律タイマーとの二重駆動）
    python3 scripts/osc-send.py /scene/next > /dev/null 2>&1 || true
  fi

  # --- Probe を 1 サンプル取る ---
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
def g(v, default=""):
    return "" if v is None else v
print(",".join(str(x) for x in [
    sys.argv[2], g(c.get("scene")), g(c.get("sceneSwitches")),
    g(p.get("fps")), g(ft.get("mean")), g(ft.get("max")),
    g(p.get("memoryMB")), g(p.get("cpuPercent")), g(p.get("thermalState")),
    g(c.get("cameraSamples")), g(c.get("cameraAuthorization")),
    g(c.get("oscMessages")), g(c.get("senseEnergy")),
]))
PY
  else
    echo "$elapsed,,,,,,,,TIMEOUT,,,," >> "$csv"
    echo "  [!] probe timeout at ${elapsed}s"
  fi

  tick=$((tick + 1))
  sleep "$interval"
done

pkill -f Sketch0815Strata 2>/dev/null || true
echo "==> csv: $csv"
python3 scripts/soak-report.py "$csv"
