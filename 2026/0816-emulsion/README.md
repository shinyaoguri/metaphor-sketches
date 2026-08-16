# 0816-emulsion

**Emulsion — darkroom double exposure.** A 2D plate (`Graphics`) and a 3D subject
(`Graphics3D`) are exposed onto separate offscreen layers, then printed onto one sheet
through a `RenderGraph` of `MergePass` nodes. Changing the blend turns the same two
layers into a completely different photograph.

Built with metaphor 0.9.0 (pinned by `Package.resolved`), template `2d`.

Verification record (the primary log, in Japanese):
[metaphor-sketches#19](https://github.com/shinyaoguri/metaphor-sketches/issues/19)

## Run

```bash
swift run                 # plain SwiftPM run
metaphor watch --viewer   # live-reload window
```

The first ~2 seconds are a **test strip**: a deterministic self-check that prints a
verdict table (`L`/`M`/`G`/`X`) and then hands over to the four scenes.

```bash
tools/probe.sh check          # run the self-check and print the table
tools/probe.sh twice          # run it twice and diff — the checks must be deterministic
tools/probe.sh shots          # one still per scene (→ ~/Desktop)
tools/probe.sh frames [dir]   # numbered PNGs for a GIF
tools/probe.sh soak [sec]     # unattended run, RSS/CPU first-half vs second-half
tools/probe.sh trap <name>    # arm one crash-prone path only when asked
```

## What this sketch found

All numbers below are what `tools/probe.sh check` prints; they reproduce exactly on
every run. IDs in brackets are the self-check IDs.

### 1. An offscreen layer cannot be cleared to transparent in one frame `[L6][L8]`

`background(0, 0, 0, 0)` has **no effect on the frame it is called in**. Calling the
identical line again on the next frame does clear the layer.

```
white layer (1.000, 1.000, 1.000, a=1.000)
  1st background(0,0,0,0) → (1.000, 1.000, 1.000, a=1.000)   unchanged
  2nd background(0,0,0,0) → (0.000, 0.000, 0.000, a=0.000)   cleared
```

`Canvas2D+Background.swift` explains it: the render-pass `loadAction = .clear` path is
only taken when the same clear colour was already applied on a previous frame.
Otherwise `background()` falls back to **drawing a full-screen quad through normal
alpha blending** — and a quad with `α = 0` is by definition a no-op.

This matters because transparency is the whole basis of layer compositing. metaphor's
own `Examples/Samples/RenderGraphCompose` calls `pgOverlay.background(0, 0, 0, 0)`
every frame, so it happens to work from frame 2 onward; a one-shot bake does not.

### 2. `Graphics3D` has no `background()`, and clears to **opaque** black `[L3]`

`Graphics` has `background()`; `Graphics3D` does not. Its clear is fixed at
`(0.000, 0.000, 0.000, a=1.000)`. An opaque layer used as the foreground of
`MergePass(.alpha)` erases whatever is underneath, and there is no API to change it.

That is why scene 3 composites the subject with `.screen` rather than `.alpha` —
black is the identity for screen, so only the subject's shape lands on the plate.
Scene 2 keeps `.alpha` in its cycle **on purpose**: the frame where the plate vanishes
is the finding, printed rather than hidden.

### 3. `MergePass(.alpha)` multiplies by alpha a second time `[M4][M5]`

The canvases store semi-transparent colour **premultiplied** (`L7`: filling with
`rgb=(0.200, 0.800, 0.400), α=0.50` reads back as `(0.102, 0.400, 0.200, a=0.502)`).
The merge shader composites as if it were straight alpha, so α is applied twice:

| | RGB |
|---|---|
| what a compositor should produce | `(0.401, 0.500, 0.251)` |
| what `MergePass(.alpha)` produces | `(0.349, 0.302, 0.153)` |

The overlaid layer comes out darker than it should. The docs state the four blend
formulas but never state the alpha convention, so from the outside this reads only as
"somehow too dark".

### 4. In a mixed frame, 3D is always painted over 2D — regardless of call order `[X2][X5][X6]`

Drawing `2D → 3D → 2D` in one frame, the trailing 2D is hidden wherever it overlaps
the 3D geometry. Moving the box from `z = 0` to `z = -600` — changing nothing else —
leaves the result identical, so this is **pass ordering, not depth comparison**.

There is a workaround: `loadPixels()` splits the render pass, and 2D issued after the
split does land on top.

```
3D then 2D                      → (0.000, 1.000, 0.000)   the 2D band is hidden
3D then loadPixels() then 2D    → (1.000, 0.000, 0.000)   the 2D band is on top
```

Scene 4 uses that one line to keep its caption readable.

### 5. The two compositors disagree `[M7][M7b]`

The same two layers, composited two ways, come out different:

```
MergePass(.add)                 → (0.702, 0.600, 0.302)   A + B, correct
image() + blendMode(.additive)  → (0.651, 0.400, 0.204)   A + B·α, off by 0.2000
```

`image()` applies alpha to a source that is already premultiplied. Switching only the
blend mode to `.alpha` shows the same shape of error, so this is the `image()` path
rather than one blend mode. `MergePass`'s `.add` / `.multiply` / `.screen` are correct,
which is what makes the two paths disagree.

Between this, finding 3, and how the canvases store colour, **three different alpha
conventions coexist in the library**. That is now tracked upstream as an epic
(metaphor#854).

### 6. `text()` ignores the fill alpha entirely `[L10][L10b][X7]`

Sweeping alpha across three values and reading the brightest glyph pixel on black:

| target | α=0 | α=128 | α=255 | proportional would be |
|---|---|---|---|---|
| `Graphics` | 1.000 | 1.000 | 1.000 | 0.000 / 0.502 / 1.000 |
| main canvas | 1.000 | 1.000 | 1.000 | 0.000 / 0.502 / 1.000 |

Flat. With the same `fill(255, 255, 255, 0)`, `rect()` leaves zero pixels and `text()`
leaves 608. Reported as measurements on metaphor#846, whose model (alpha applied twice)
predicts text vanishing at α=0 — it does not.

### Things that checked out

| | |
|---|---|
| `.add` / `.multiply` / `.screen` `[M1-M3]` | match the documented formulas to within 8-bit quantisation (max Δ 0.0016) |
| `InvertEffect` `[G1]` | exactly `1 − c` (Δ 0.0000) |
| `GrayscaleEffect` `[G2]` | Rec.709 luma (Δ 0.0005 vs Rec.709, 0.0300 vs Rec.601) |
| DAG isolation `[G3]` | an effect on one branch leaves the shared upstream node untouched |
| `blendType` at runtime `[M6]` | reassignment takes effect from the next frame |
| mismatched-size merge | metaphor#145 does not regress — the uncovered region reads as transparent black, not garbage |
| multi-pass effects | `BloomEffect` through `EffectPass` over a `Graphics` input renders correctly, both standalone and merged — the warning comment in the official sample looks stale on 0.9.0 |

## Notes for anyone reading the code

- **`SourcePass` cannot be drawn into with sketch APIs** `[G6]`. Its `onDraw` hands you a
  raw `MTLRenderCommandEncoder` — no `circle()`, no `sphere()`. `Compose.swift` therefore
  wraps `Graphics`/`Graphics3D` in `RenderPassNode` adapters, the same workaround the
  official sample uses.
- **Setting a render graph replaces the main canvas output.** Anything drawn in `draw()`
  is discarded, so the caption bar has to be its own layer and be merged in.
- **Checks that involve the graph cannot live in `setup()`.** `MergePass`/`EffectPass`
  only execute once the renderer runs a frame; before that their `output` is `nil`.
  `Darkroom.swift` runs those as a frame-driven state machine — driven by frame index,
  never by wall-clock, so the numbers are identical on every run.
- All motion derives from `frameCount`, so `shots` and `frames` describe the same thing.
- `print` is always paired with `fflush(stdout)`; piped output is block-buffered
  otherwise and the sketch looks hung.
- **Alpha arguments to `fill`/`stroke` are 0–255, not 0–1.** `Color` is the 0–1 one.
  Getting this wrong here made the entire 2D plate render as nothing while every check
  still passed — the checks measured alpha correctly, the artwork code did not. If a
  layer looks empty, read back one pixel before assuming the drawing calls are wrong.
- The soak script deliberately drops the first 30 seconds. Including startup makes the
  first-half average low enough that any run looks like it is leaking (+10 MB on a
  process whose RSS is in fact flat).

## Feedback

[metaphor issues](https://github.com/shinyaoguri/metaphor/issues) ·
[metaphor-cli issues](https://github.com/shinyaoguri/metaphor-cli/issues)
