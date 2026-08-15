#!/usr/bin/env python3
"""ソーク CSV を読み、前半 / 後半の比較で劣化とリークを判定する。

    python3 scripts/soak-report.py .probe-out/soak-off-....csv

読み方（0718-memory-stress / 0815-strata の流儀を踏襲）:
- fps が後半で目に見えて落ちていれば劣化
- memoryMB が「前半 → 後半」で増え続けていればリーク疑い。キャッシュ由来の
  初回確保は有界なので、後半の傾きが 0 に寝いているかで切り分ける
- この作品固有: assetsLive（生存アセット数）が周回とともに増えないこと。
  増えるなら「シーンを抜けても解放されていない」= 寿命境界の破れ
"""
import csv
import statistics
import sys


def num(row, key):
    v = row.get(key, "")
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def summarize(values):
    vals = [v for v in values if v is not None]
    if not vals:
        return None
    return {
        "n": len(vals),
        "min": min(vals),
        "max": max(vals),
        "mean": statistics.fmean(vals),
    }


def halves(rows, key):
    vals = [num(r, key) for r in rows]
    vals = [v for v in vals if v is not None]
    if len(vals) < 4:
        return None, None
    mid = len(vals) // 2
    return statistics.fmean(vals[:mid]), statistics.fmean(vals[mid:])


def main(path):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))

    timeouts = [r for r in rows if r.get("thermal") == "TIMEOUT"]
    rows = [r for r in rows if r.get("thermal") != "TIMEOUT"]
    if not rows:
        print("no samples")
        return 1

    span = num(rows[-1], "elapsed") or 0
    print(f"samples={len(rows)}  span={span:.0f}s  probe timeouts={len(timeouts)}")

    for key, label in [
        ("fps", "fps"),
        ("frameMeanMs", "frameTime.mean(ms)"),
        ("frameMaxMs", "frameTime.max(ms)"),
        ("memoryMB", "memoryMB"),
        ("cpuPercent", "cpu%"),
        ("assetLoadMs", "assetLoad(ms)"),
    ]:
        s = summarize([num(r, key) for r in rows])
        if not s:
            continue
        first, second = halves(rows, key)
        delta = f"{second - first:+.1f}" if first is not None else "n/a"
        print(
            f"{label:20s} mean={s['mean']:8.1f}  min={s['min']:8.1f}  max={s['max']:8.1f}"
            f"   first→second {first:8.1f} → {second:8.1f} ({delta})"
        )

    live = [num(r, "assetsLive") for r in rows]
    live = [v for v in live if v is not None]
    loads = [num(r, "assetsLoads") for r in rows]
    loads = [v for v in loads if v is not None]
    frees = [num(r, "assetsFrees") for r in rows]
    frees = [v for v in frees if v is not None]
    cycles = [num(r, "cycles") for r in rows]
    cycles = [v for v in cycles if v is not None]
    transitions = [num(r, "transitions") for r in rows]
    transitions = [v for v in transitions if v is not None]

    if live:
        print(
            f"\nassetsLive  min={min(live):.0f} max={max(live):.0f} last={live[-1]:.0f}"
            "   (増え続けるなら解放漏れ)"
        )
    if loads and frees:
        print(f"assets loads={loads[-1]:.0f} frees={frees[-1]:.0f} "
              f"balance={loads[-1] - frees[-1]:.0f}")
    if transitions:
        print(f"scene transitions={transitions[-1]:.0f}  cycles={cycles[-1] if cycles else 0:.0f}")

    scenes = {}
    for r in rows:
        scenes[r.get("scene", "?")] = scenes.get(r.get("scene", "?"), 0) + 1
    print("scene samples:", ", ".join(f"{k}={v}" for k, v in sorted(scenes.items())))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else ".probe-out/soak.csv"))
