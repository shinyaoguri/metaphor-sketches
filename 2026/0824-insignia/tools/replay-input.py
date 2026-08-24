#!/usr/bin/env python3
"""ライブビューアが送る入力イベント列を、GUI 無しでそのまま再生する。

`metaphor watch` のビューアは窓宛の NSEvent を JSON Lines にして子スケッチの stdin へ流す。
`METAPHOR_VIEWER=1` を立てれば同じ経路を手で叩けるので、**マウスを触らずに**入力の異常を
再現・計測できる（この作品で踏んだ「窓をリサイズすると押しっぱなしになる」の再現に使った）。

    tools/replay-input.py stuck    mouseDown のあと mouseUp が来ないまま mouseMove が続く
    tools/replay-input.py drag     正常なドラッグ (mouseDown → mouseDrag → mouseUp)
    tools/replay-input.py press    押下 1 回だけ。移動も解放もしない

どれも水平に 600px ぶんの入力を送り、カメラの方位角がいくら動いたかを出す。
判定の目安（metaphor 0.13.0 / この作品の設定）:

| 列 | 期待 |
|---|---|
| stuck | 0 rad。押していないのだから回ってはいけない |
| drag  | -3.0 rad。600px × sensitivity 0.005 |
| press | 0 rad。押下はドラッグではない |

関連: metaphor-cli#189 / metaphor#1099 / metaphor#1100
"""
import json
import os
import subprocess
import sys
import time

BINARY = ".build/debug/Sketch0824Insignia"
MODES = ("stuck", "drag", "press")


def replay(mode: str) -> None:
    env = dict(os.environ, METAPHOR_VIEWER="1", INSIGNIA_INPUTLOG="1")
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
    print(f"{mode:6} 方位角 {first:+.4f} → {last:+.4f} rad（変化 {last - first:+.4f}）")


if __name__ == "__main__":
    modes = sys.argv[1:] or list(MODES)
    for mode in modes:
        if mode not in MODES:
            sys.exit(f"モードは {' / '.join(MODES)} のどれか")
        replay(mode)
