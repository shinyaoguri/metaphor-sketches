# 0816-gamut — light and pigment

The same three primaries. Stack them as **light** and they climb to white; stack them as
**pigment** and they fall to black. Both tables share one "thin it out" knob (α).

That shared knob is the point. α is supposed to mean *how much of the mix to apply*, so
lowering it should sink both tables toward their backdrop. It doesn't — and the asymmetry
you see on screen is the same defect the self-check reports as numbers
([metaphor#801](https://github.com/shinyaoguri/metaphor/issues/801)).

Verification record: [metaphor-sketches#13](https://github.com/shinyaoguri/metaphor-sketches/issues/13).
Pinned to **metaphor 0.9.0** (`Package.resolved`).

![Both tables at α = 1](https://i.gyazo.com/c4751b290a7f40b37768eab6ee47f4d8.png)

At α = 1 the light table's centre reaches white `rgb(255,255,255)` and the pigment table's
centre reaches black `rgb(0,0,0)`. Turn α down and only the left table obeys.

![α travelling from 1 to 0 and back](https://i.gyazo.com/f5535619b146d60785c447366db87308.gif)

## Run

```bash
swift build
tools/probe.sh check          # 102 deterministic verdicts
tools/probe.sh determinism    # runs check twice; the two outputs must be identical
swift run                     # the piece itself
```

| key | |
|---|---|
| `TAB` | compare / light / pigment / verdict table |
| `←` `→` | blend mode (additive·screen·lightest paired with multiply·darkest·subtract) |
| `↑` `↓` | α — the "thin it out" knob, applied to both tables at once |
| `SPACE` | stop / start the rotation |
| `ESC` | reset |

Drag vertically to spread the three circles apart.

Observation hooks, for when the MCP server isn't available:

| env | |
|---|---|
| `GAMUT_SHOTS=1` | write one PNG per view, then exit |
| `GAMUT_FRAMES=<dir>` | write numbered PNGs for a GIF |
| `GAMUT_TRACE=1` | print the sampled overlap colours |
| `GAMUT_DEMO=1` | sweep α automatically (this is how the GIF above was made) |
| `GAMUT_MODE=0\|1\|2` | pin the blend mode |

## What the self-check measures

`Instrument.swift` composites onto an offscreen buffer (`createGraphics`) and reads it back
with `toImage().loadPixels()`, so the piece itself is never disturbed. `Runtime.swift` covers
what only the main canvas can do. Every verdict carries **measured numbers**, not a boolean.

| | |
|---|---|
| `B*` | all 10 `BlendMode` cases against their closed-form formula at α=1 — **all pass** |
| `A0` `A5` | the same formulas under `mix(dst, blend, α)` at α=0 / 0.5 |
| `A2` `A3` `A4` | the **alpha of the composited result** at α=1 / 0 / 0.5 |
| `L*` | additive and subtractive identities, de Morgan duality, commutativity, idempotence, clamping |
| `P*` | the same blend through rect / circle / triangle / quad / beginShape / instanced circles |
| `G*` | `Color(hue:…)`, `lerp`, `interpolate`, `withAlpha` |
| `R*` | main canvas, gradients, vertex colours, `pushStyle`, cross-frame state |

16 of the 102 fail, and every one of them is the same root cause. Run
`tools/probe.sh check | grep FAIL` to see them with their measurements.

## Notes for anyone reading the code

- **`Graphics` is narrower than `Sketch`.** Its 62 public members do **not** include
  `linearGradient`, `radialGradient`, `pushStyle`/`popStyle`, or the colour-carrying
  `vertex(x:y:color:)`, even though the generated docs say "the other 60 drawing and
  transform members behave identically to the Sketch API". That split is why the checks
  live in two files.
- **`blendMode` persists across frames**, like `fill` and `rectMode`. Ending a frame in
  `.multiply` means the next frame starts in `.multiply` — including the rectangle you
  draw as a backdrop. `R10` pins this down.
- **`Color(hue:saturation:brightness:)` takes hue in 0…1**, not 0…360. That is a different
  scale from `colorMode(.hsb, 360, …)`, which follows whatever maximum you set. Out-of-range
  and negative hues wrap.
- **`linearGradient(axis: .diagonal)` interpolates the four corners**: it puts the midpoint
  colour at *both* the top-right and the bottom-left, so the iso-lines do not run
  perpendicular to the diagonal. `R5` records the corner measurements.
- **`radialGradient` clamps `segments` to a minimum of 6**, so passing 0 still draws.
- Expected values are computed from the **measured** backdrop, not from the float that was
  passed to `fill`. Quantisation to 8 bits happens on write, so deriving the expectation
  from the input forces a looser tolerance than the checks deserve.

## The two failing behaviours

| | |
|---|---|
| RGB ignores `src.a` | `multiply`, `screen`, `lightest`, `darkest` composite at full strength no matter what α says — α=0.5 is bit-identical to α=1. `subtract` does apply α, but *before* clamping. |
| Result alpha is destroyed | `multiply` and `darkest` produce `result.a = src.a × dst.a`; `subtract` produces `dst.a − src.a`, so painting a **fully opaque** colour leaves the canvas fully transparent. |

`difference` and `exclusion` go through a framebuffer-fetch shader that handles α correctly
(`mix(dest.rgb, blended, src.a)`), which is what makes this an internal inconsistency rather
than a design choice: the same `blendMode()` call means different things depending on which
case you pass.

A stripped-down reproduction lives in
[`2026/0816-probe-blendalpha`](../0816-probe-blendalpha/) — the piece's context removed, the
behaviour unchanged.
