#!/bin/bash
# 全シーンの絵を 1 コマンドで撮る。
#
#   scripts/shots.sh [出力先ディレクトリ]
#
# 各シーンを `SALVAGE_START` で直接開いて Probe で 1 枚ずつ撮る。ゲームなので
# タイトルから遊んで到達するのは現実的でなく、AI が自分で絵を確かめるには
# 「任意の状態から起動する」入口が要る（作品側で用意した）。
#
# プレイ中のシーンは自動操縦（SALVAGE_DEMO=1）で動かした状態を撮る。
# タイトルと結果は自動遷移してしまうのでデモを切る。
set -euo pipefail

cd "$(dirname "$0")/.."

outdir="${1:-.probe-out}"
bin=".build/debug/Sketch0815Salvage"

[ -x "$bin" ] || { echo "build first: swift build" >&2; exit 1; }
mkdir -p "$outdir"

for scene in title hull reactor vent result; do
  case "$scene" in
    title|result) demo=0 ;;
    *) demo=1 ;;
  esac

  METAPHOR_PROBE=1 SALVAGE_START="$scene" SALVAGE_DEMO="$demo" "$bin" >/dev/null 2>&1 &
  pid=$!
  sleep 5
  bash scripts/probe-snap.sh "$scene" "$outdir" || echo "capture failed: $scene" >&2
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  sleep 1
done

echo "---"
ls -1 "$outdir"/*.png
