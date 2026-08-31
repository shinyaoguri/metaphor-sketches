#!/usr/bin/env python3
"""ライブビューアが送る入力イベント列を、GUI 無しでそのまま再生する。

`metaphor watch` のビューアは窓宛の NSEvent を JSON Lines にして子スケッチの stdin へ流す。
`METAPHOR_VIEWER=1` を立てれば同じ経路を手で叩けるので、**マウスを触らずに**入力の異常を
再現・計測できる（この作品で踏んだ「窓をリサイズすると押しっぱなしになる」の再現に使った）。

    tools/replay-input.py stuck    mouseDown のあと mouseUp が来ないまま mouseMove が続く
    tools/replay-input.py drag     正常なドラッグ (mouseDown → mouseDrag → mouseUp)
    tools/replay-input.py press    押下 1 回だけ。移動も解放もしない
    tools/replay-input.py --raw    作品側の受け止めを外し、metaphor の素の挙動を測る

どれも水平に 600px ぶんの入力を送り、カメラの方位角がいくら動いたかを出す。
判定の目安（metaphor 0.13.0 / この作品の設定）:

| 列 | 期待 |
|---|---|
| stuck | 0 rad。押していないのだから回ってはいけない |
| drag  | -3.0 rad。600px × sensitivity 0.005 |
| press | 0 rad。押下はドラッグではない |

`--raw` は `INSIGNIA_RAWCAM=1` を立てて**作品側の感度補正・押下ガード・回転上限を全部外す**。
上流が直っていれば素のままでも上の表と同じ値になるので、**上流の再検証はこちらで測る**
（作品の App.swift を手で書き換えて戻す必要が無い）。`ID: PASS` の行を足すので、
台帳の `oracle.verdictCommand` から機械判定できる。

関連: metaphor-cli#189 / metaphor#1099 / metaphor#1100
"""
import json
import os
import subprocess
import sys
import time

BINARY = ".build/debug/Sketch0824Insignia"
MODES = ("stuck", "drag", "press")


# --raw のときの合否。素の metaphor がこう振る舞えば作品側の受け止めは要らなくなる。
# stuck に合否を置かないのは、**押しっぱなしになるのはビューア側の落ち度**
# (metaphor-cli#189) で、押下中に動けば回る metaphor の側は正しいから。この再生は
# ビューアを通さず stdin へ直接流すので、そもそも cli#189 の判定にならない。測るだけにする。
RAW_CHECKS = {
    "drag": ("C1.dragGain", -3.0, 0.15, "metaphor#1099", "600px × sensitivity 0.005"),
    "press": ("C2.pressJump", 0.0, 0.01, "metaphor#1100", "押下はドラッグではない"),
}


def replay(mode: str, raw: bool = False) -> None:
    env = dict(os.environ, METAPHOR_VIEWER="1", INSIGNIA_INPUTLOG="1")
    if raw:
        env["INSIGNIA_RAWCAM"] = "1"
    proc = subprocess.Popen(
        [BINARY],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
        env=env,
    )

    def send(event: dict) -> None:
        proc.stdin.write(json.dumps(event) + "\n")
        proc.stdin.flush()

    time.sleep(3.0)  # setup() と最初の数フレームを待つ
    send({"t": "mouseDown", "x": 640.0, "y": 400.0, "button": 0})
    time.sleep(0.2)

    if mode != "press":
        kind = "mouseMove" if mode == "stuck" else "mouseDrag"
        for i in range(1, 61):
            send({"t": kind, "x": 640.0 + i * 10.0, "y": 400.0})
            time.sleep(0.02)
    if mode == "drag":
        send({"t": "mouseUp", "x": 1240.0, "y": 400.0, "button": 0})

    time.sleep(1.5)
    proc.kill()

    lines = [l for l in proc.stdout.read().splitlines() if "azimuth=" in l]
    if not lines:
        print(f"{mode}: 出力が取れなかった（{BINARY} をビルドしてあるか確認する）")
        return
    first = float(lines[0].split("azimuth=")[1])
    last = float(lines[-1].split("azimuth=")[1])
    delta = last - first
    print(f"{mode:6} 方位角 {first:+.4f} → {last:+.4f} rad（変化 {delta:+.4f}）")
    if raw and mode in RAW_CHECKS:
        check, expected, tol, issue, why = RAW_CHECKS[mode]
        ok = abs(delta - expected) <= tol
        print(
            f"  {check}: {'PASS' if ok else 'FAIL'} "
            f"作品側の受け止めを外して 変化 {delta:+.4f} rad 期待 {expected:+.1f}±{tol}"
            f"（{why} / {issue}）"
        )


if __name__ == "__main__":
    args = sys.argv[1:]
    raw = "--raw" in args
    modes = [a for a in args if a != "--raw"] or list(MODES)
    for mode in modes:
        if mode not in MODES:
            sys.exit(f"モードは {' / '.join(MODES)} のどれか（ほかに --raw）")
        replay(mode, raw=raw)
