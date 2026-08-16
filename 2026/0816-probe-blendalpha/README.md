# 0816-probe-blendalpha — does `fill`'s alpha reach the blend?

A cut-down reproduction, split out of [`0816-gamut`](../0816-gamut/). Everything the piece
carried — the tables, the rotation, the HUD — is stripped away, leaving one question:

> Lay down an opaque backdrop, put **one** rectangle on top of it with a given
> `blendMode`, and read the middle pixel. What did the alpha do?

If the numbers stay the same once the context is gone, the cause is the library rather than
the piece. They do. Reported as
[metaphor#801](https://github.com/shinyaoguri/metaphor/issues/801); the parent's verification
record is [metaphor-sketches#13](https://github.com/shinyaoguri/metaphor-sketches/issues/13).

Pinned to **metaphor 0.9.0** (`Package.resolved`), so this keeps reproducing the 0.9.0
behaviour even after the library moves on. Re-run it against a newer metaphor to check
whether the issue is fixed.

## Run

```bash
swift run
```

No window interaction needed — it prints three tables and stops. The backdrop is
`rgb(102,77,51)`; **anything other than that under α=0 is the defect**, and the fourth
number (alpha) should be 255 everywhere.

```
下地            rgba(102, 77, 51,255)

--- α = 0（完全に透明。どのモードでも下地のままが期待）---
alpha       rgba(102, 77, 51,255)
additive    rgba(102, 77, 51,255)
multiply    rgba( 26, 42,  8,  0)     ← 変わってしまう + α が 0
screen      rgba(140,175, 82,255)     ← 変わってしまう
subtract    rgba(102, 77, 51,255)
lightest    rgba(102,140, 51,255)     ← 変わってしまう
darkest     rgba( 64, 77, 38,  0)     ← 変わってしまう + α が 0
difference  rgba(102, 77, 51,255)
exclusion   rgba(102, 77, 51,255)

--- α = 0.5（効きが半分になるのが期待）---
alpha       rgba( 83,109, 45,255)
additive    rgba(134,147, 70,255)
multiply    rgba( 26, 42,  8,128)     ← α=1 と同値
screen      rgba(140,175, 82,255)     ← α=1 と同値
subtract    rgba( 70,  7, 32,128)     ← クランプ前に α が掛かっている
lightest    rgba(102,140, 51,255)     ← α=1 と同値
darkest     rgba( 64, 77, 38,128)     ← α=1 と同値
difference  rgba( 70, 70, 32,255)
exclusion   rgba(108,105, 62,255)

--- α = 1（RGB はこの列だけ全モード正しい）---
subtract    rgba( 38,  0, 13,  0)     ← 不透明で塗ったのに結果が完全に透明
```

`difference` と `exclusion` だけが α を正しく扱うのは、この 2 つが固定関数ブレンドではなく
framebuffer fetch のシェーダー（`MetaphorCanvas2D.metal`）で実装されていて、そちらが
`mix(dest.rgb, blended, src.a)` と書いているため。同じ `blendMode()` なのにモードで
意味論が割れている、というのが報告の骨子。

## Why this stayed

Solving it wasn't the reason to keep the code. Two other reasons were:

- **Re-checking later.** When metaphor moves past 0.9.0, `swift run` here answers
  "is it fixed?" without rebuilding the argument.
- **Letting upstream follow along.** The snippet pasted into the issue also exists as
  something that runs.
