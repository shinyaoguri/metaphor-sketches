#!/usr/bin/env python3
"""ソーク CSV を読み、前半 / 後半の比較で劣化とリークを判定する。

    python3 scripts/soak-report.py .probe-out/soak-....csv

読み方（0718-memory-stress の流儀を踏襲）:
- fps が後半で目に見えて落ちていれば劣化
- memoryMB が「前半→後半」で増え続けていればリーク疑い。キャッシュ由来の
  初回確保は有界なので、後半の傾きが 0 に寝ているかどうかで切り分ける
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


def fmt(s, unit=""):
    if not s:
        return "n/a"
    return f"mean {s['mean']:.1f}{unit}  min {s['min']:.1f}  max {s['max']:.1f}  (n={s['n']})"


def main() -> int:
    path = sys.argv[1]
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))

    if not rows:
        print("no samples")
        return 1

    timeouts = [r for r in rows if r.get("thermal") == "TIMEOUT"]
    ok = [r for r in rows if r.get("thermal") != "TIMEOUT"]
    half = len(ok) // 2
    first, second = ok[:half], ok[half:]

    duration = num(rows[-1], "elapsed") or 0
    print(f"samples={len(rows)} ok={len(ok)} timeouts={len(timeouts)} duration={duration:.0f}s")
    print()

    for key, unit in [("fps", ""), ("frameMeanMs", "ms"), ("frameMaxMs", "ms"),
                      ("memoryMB", "MB"), ("cpuPercent", "%")]:
        whole = summarize([num(r, key) for r in ok])
        a = summarize([num(r, key) for r in first])
        b = summarize([num(r, key) for r in second])
        print(f"{key:12} {fmt(whole, unit)}")
        if a and b:
            delta = b["mean"] - a["mean"]
            print(f"{'':12} 前半 {a['mean']:.1f} → 後半 {b['mean']:.1f}  (Δ {delta:+.1f})")
    print()

    scenes = {}
    for r in ok:
        scenes.setdefault(r.get("scene", "?"), 0)
        scenes[r.get("scene", "?")] += 1
    switches = max((num(r, "switches") or 0) for r in ok)
    print("scenes:", ", ".join(f"{k}={v}" for k, v in sorted(scenes.items())))
    print(f"scene switches: {switches:.0f}")

    cam = max((num(r, "camSamples") or 0) for r in ok)
    osc = max((num(r, "oscMsgs") or 0) for r in ok)
    auth = ok[-1].get("camAuth", "?")
    print(f"camera samples: {cam:.0f} (auth={auth})   osc messages: {osc:.0f}")
    print()

    # --- 判定 ---
    verdict = []
    fa = summarize([num(r, "fps") for r in first])
    fb = summarize([num(r, "fps") for r in second])
    if fa and fb:
        drop = fa["mean"] - fb["mean"]
        verdict.append(
            ("PASS" if drop < 2.0 else "FAIL")
            + f"  fps 劣化: 前半 {fa['mean']:.1f} → 後半 {fb['mean']:.1f} (低下 {drop:.1f})"
        )
    ma = summarize([num(r, "memoryMB") for r in first])
    mb = summarize([num(r, "memoryMB") for r in second])
    if ma and mb:
        growth = mb["mean"] - ma["mean"]
        verdict.append(
            ("PASS" if growth < 30.0 else "FAIL")
            + f"  メモリ増加: 前半 {ma['mean']:.0f}MB → 後半 {mb['mean']:.0f}MB (増加 {growth:+.0f}MB)"
        )
    verdict.append(
        ("PASS" if not timeouts else "FAIL") + f"  Probe 応答: timeout {len(timeouts)} 件"
    )
    verdict.append(
        ("PASS" if switches >= 4 else "FAIL") + f"  シーン巡回: {switches:.0f} 回切替"
    )
    verdict.append(
        ("PASS" if cam > 0 else "FAIL") + f"  カメラ入力: {cam:.0f} サンプル"
    )
    verdict.append(
        ("PASS" if osc > 0 else "FAIL") + f"  OSC 入力: {osc:.0f} メッセージ"
    )

    print("== 判定 ==")
    for line in verdict:
        print(" ", line)
    return 0 if all(v.startswith("PASS") for v in verdict) else 1


if __name__ == "__main__":
    raise SystemExit(main())
