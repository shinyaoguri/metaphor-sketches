# PROJECT_BRIEF — 0824-duet

## The idea

A duet. One swirl, played twice at once.

| Hand | Who plays it | How it is drawn |
|---|---|---|
| Left (第一奏者) | Swift loop on the CPU | `circles([CircleInstance])` from a CPU array |
| Right (第二奏者) | MSL compute kernel | `circles(GPUBuffer<CircleInstance>)`, written by the kernel |

Both start from the same opening (`Score.opening`), advance with the same fixed step
(1/60 s, not the frame time), and follow the same integrator. The only asymmetry is that the
right hand mirrors x when it maps the stage to the screen. **So a correct performance is a
symmetric picture**, and the seam between the panels — one bar per voice, lit by decade of
disagreement — stays dark.

The piece opens with 調弦 (tuning): a board of verdicts from the instrument, held for 8 s.
Then four movements of 12 s each, on a loop.

## What "as intended" means

- The two panels are mirror images at every instant. Not approximately — the divergence
  readout stays at 1e-06 or below over hundreds of steps.
- The seam is dark in 斉唱 and stays dark through 輪唱 (both with and without the barrier).
- 端数 changes the voice count on the fly without eating the rim of either cloud.
- 写譜 looks identical whichever way the right hand is drawn.
- The board shows no FAIL. A LOOK is a thing a human decides, not a failure.

If any of that stops being true, the picture says so before the numbers do — that is the
point of making it a duet instead of a test suite.

## What it is verifying

metaphor's GPU compute surface, which no other sketch in this book had touched:
`createComputeKernel` / `createBuffer` / `dispatch` (1D and 2D) / `computeBarrier` /
`GPUBuffer` (`toArray` / `copyFrom` / subscript) / `circles(GPUBuffer<CircleInstance>)`.

The angle is deliberate: **the expected value is solvable on the CPU**, so every disagreement
comes out as a number rather than an impression. The checks live in `Instrument.swift`
(IDs `G1`…`G14`) and are described in [README.md](README.md); the running record is
[metaphor-sketches#26](https://github.com/shinyaoguri/metaphor-sketches/issues/26).
