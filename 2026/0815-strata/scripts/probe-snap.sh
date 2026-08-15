#!/bin/bash
# 実行中の 0815-strata へ Probe リクエストを投げ、1 フレーム分の
# 画像 (PNG) とメタデータ (frame.json) を取り出す。
#
#   scripts/probe-snap.sh <label> [出力先ディレクトリ]
#
# 前提: 別プロセスで METAPHOR_PROBE=1 の 0815-strata が動いていること
#       (scripts/run.sh か soak.sh が起動する)。
#
# Probe の performance 節は単一フレーム経路にしか載らないため、
# 連続キャプチャ (sequence) ではなく request 方式で取る。
set -euo pipefail

cd "$(dirname "$0")/.."

label="${1:-snap}"
outdir="${2:-.probe-out}"
probe_dir=".metaphor/probe"
current="$probe_dir/current"

mkdir -p "$probe_dir" "$outdir"

id="${label}-$(date +%s)"
printf '{"id":"%s","label":"%s","scale":1.0}\n' "$id" "$label" > "$probe_dir/request.json"

# 応答待ち (最大 20 秒)。id が echo されたら自分のリクエストへの応答。
for _ in $(seq 1 200); do
  if [ -f "$current/frame.json" ] &&
     grep -q "\"id\"[[:space:]]*:[[:space:]]*\"$id\"" "$current/frame.json" 2>/dev/null; then
    cp "$current/frame.json" "$outdir/$label.json"
    [ -f "$current/frame.png" ] && cp "$current/frame.png" "$outdir/$label.png"
    echo "captured: $outdir/$label.png"
    python3 - "$outdir/$label.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
perf = d.get("performance", {})
custom = d.get("custom", {})
print("frame={} time={:.1f}s size={}x{}".format(
    d["frame"], d["time"], d["size"]["width"], d["size"]["height"]))
print("perf  fps={} frameMs={} memMB={} cpu={}% thermal={}".format(
    perf.get("fps"), (perf.get("frameTimeMs") or {}).get("mean"),
    perf.get("memoryMB"), perf.get("cpuPercent"), perf.get("thermalState")))
stats = d.get("stats", {})
print("stats meanLuminance={} contentFraction={}".format(
    stats.get("meanLuminance"), stats.get("contentFraction")))
print("scene={} switches={} transition={} uptime={}".format(
    custom.get("scene"), custom.get("sceneSwitches"),
    custom.get("transition"), custom.get("uptimeSec")))
print("camera avail={} samples={} energy={} | osc running={} msgs={}".format(
    custom.get("cameraAvailable"), custom.get("cameraSamples"),
    custom.get("senseEnergy"), custom.get("oscRunning"), custom.get("oscMessages")))
if d.get("warnings"):
    print("warnings:", d["warnings"])
PY
    exit 0
  fi
  sleep 0.1
done

echo "timeout: no probe response for id=$id" >&2
exit 1
