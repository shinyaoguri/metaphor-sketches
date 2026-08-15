#!/bin/bash
# ステージ遷移（= アセットの入れ替え）の動きを GIF で残す。
#
#   scripts/capture-gif.sh [開始シーン] [起動後の待ち秒] [出力名]
#
# Probe の連続キャプチャ（`request.json` に frames/every）で撮る。
# frames は最大 64（超えると clamp されて warning が載る）。every=6 なら
# 60fps のうち 6 フレームに 1 枚 = 0.1 秒間隔で 6.4 秒ぶん撮れる。
set -euo pipefail

cd "$(dirname "$0")/.."

scene="${1:-hull}"
warmup="${2:-6}"
name="${3:-transition}"
outdir=".probe-out/gif"
probe_dir=".metaphor/probe"
seq="$probe_dir/current/sequence"
bin=".build/release/Sketch0815Salvage"

[ -x "$bin" ] || bin=".build/debug/Sketch0815Salvage"
[ -x "$bin" ] || { echo "build first" >&2; exit 1; }

rm -rf "$outdir" "$seq"
mkdir -p "$outdir" "$probe_dir"

METAPHOR_PROBE=1 SALVAGE_START="$scene" SALVAGE_DEMO=1 "$bin" >/dev/null 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT

sleep "$warmup"

id="gif-$(date +%s)"
printf '{"id":"%s","label":"%s","scale":0.6,"frames":64,"every":6}\n' "$id" "$name" \
  > "$probe_dir/request.json"

for _ in $(seq 1 400); do
  if [ -f "$seq/sequence.json" ] &&
     grep -q "\"id\"[[:space:]]*:[[:space:]]*\"$id\"" "$seq/sequence.json" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

[ -f "$seq/sequence.json" ] || { echo "no sequence written" >&2; exit 1; }

cp "$seq"/frame.*.png "$outdir/" 2>/dev/null || true
count=$(ls -1 "$outdir"/frame.*.png 2>/dev/null | wc -l | tr -d ' ')
echo "frames: $count"
python3 - "$seq" <<'PY'
import json, pathlib, sys
seq = pathlib.Path(sys.argv[1])
d = json.load(open(seq / "sequence.json"))
# frames[].metadata は「メタデータ JSON のファイル名」（実体ではない）
scenes = []
for f in d["frames"]:
    meta = json.load(open(seq / f["metadata"]))
    scenes.append((meta.get("custom") or {}).get("scene"))
seen = []
for s in scenes:
    if not seen or seen[-1] != s:
        seen.append(s)
print("scene order:", " -> ".join(str(s) for s in seen))
print("warnings:", d.get("warnings"))
PY

ffmpeg -y -hide_banner -loglevel error -framerate 10 -pattern_type glob \
  -i "$outdir/frame.*.png" \
  -vf "scale=640:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer" \
  "$outdir/$name.gif"

ls -lh "$outdir/$name.gif"
