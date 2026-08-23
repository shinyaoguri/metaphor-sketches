# PROJECT_BRIEF — 0823-darkroom

## The idea

A darkroom. One negative goes through three developing baths and leaves the building
on three separate Syphon lines.

| Window | Bath | Syphon server |
|---|---|---|
| A (primary) | none — the negative itself | `darkroom - A` |
| B (`createWindow`) | `MPSSobelEffect` — edges only | `darkroom - B` |
| C (`createWindow`) | `MPSDilateEffect` + `MPSBlurEffect` — thickened and put to sleep | `darkroom - C` |

**Interlocked means all three windows draw the same negative from the same single state.**
There is exactly one `Darkroom` object; the only thing that differs per window is the bath
(the post-effect chain). So the three Syphon lines carry *the same instant, three faces*.
Every 60 seconds the process walks 露光 → 現像 → **停止** → 定着, and in 停止 the baths come
out — all three windows fall back to the same picture. That is the control: if they only
differ while the baths are in, the difference is really the baths' doing.

## The negative is also a test signal

It has to survive developing and still be readable by a receiver that never looks at it:

- **Exposure clock** — a thick hand that turns once every 8 s. Its angle says *which instant
  this is*, and neither sobel (which keeps the edges) nor dilate (which keeps the direction)
  destroys it. Three lines agreeing on the angle ⇒ interlocked.
- **Step wedge** — 11 steps along the bottom edge. Its mean luma is `255 × 0.5` by
  construction, so the expected value can be derived **without calling metaphor**.
- **Grain** — deterministic (SplitMix, fixed seed), coarse enough that sobel has something
  to find.

## What should happen

- Three windows open; three Syphon servers stand under three distinct names
- The three pictures move together (hand angle spread well under a frame's worth of turn)
- B is darker and edgier than A; C is brighter than A
- Closing a window takes its server down; reopening brings it back
- Hiding the app does **not** stop publishing (Syphon declares `.externalRenderLoop`)
- Killing the process leaves no server behind in the Syphon directory

## How it is judged

`tools/probe.sh` runs the built-in checks (deterministic, no drawing, IDs `D1`–`D10`), and
**`tools/syphon-read.sh` receives all three lines from outside** and prints mean luma,
bright-pixel share, edge rate, wedge profile and hand angle per line. The built-in checks
cannot see the developed picture — `loadPixels()` reads the canvas *before* post-effects —
so the receiver is the only place the baths can actually be measured.

Verification record: [metaphor-sketches#25](https://github.com/shinyaoguri/metaphor-sketches/issues/25).
