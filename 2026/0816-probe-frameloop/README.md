# 0816-probe-frameloop — frame loop edge cases (minimal repro)

Carved out of [`0816-escapement`](../0816-escapement/) to isolate two behaviours that only
show up **across frames**, with the artwork's context (dial, movement, self-checks) stripped away.

Kept in the repository on purpose: it is both the reproduction attached to the upstream issue
and the board that re-checks it once metaphor is updated.

Pinned to **metaphor 0.9.0** (`Package.resolved`).

## Run

```bash
cd 2026/0816-probe-frameloop

# 1) deltaTime spike after noLoop() -> loop()
PROBE=resume swift run

# 2) pmouseX/pmouseY lag under injected input
mkfifo /tmp/pm.fifo
PROBE=pmouse swift run < /tmp/pm.fifo &
sleep 6; exec 3>/tmp/pm.fifo
printf '{"t":"mouseMove","x":300,"y":200}\n' >&3
```

Both print plain text; no screenshots needed.

## 1. `PROBE=resume` — the paused wall time arrives as one frame's `deltaTime`

`noLoop()` at t≈2.0s, nothing drawn for 0.8s, `loop()` at t≈2.8s:

```
noLoop at frame=122 time=2.0910516
loop  at frame=122 time=2.0910516 (paused for 0.8s)
after resume: frame=123 deltaTime=0.9000025s time=2.991054s
  expected: one frame = 0.01667s / paused wall time = 0.8s
  time advanced by: 0.9000025s
```

The first frame after resuming gets `deltaTime = 0.90s`, i.e. **54x a 60fps frame**. Anything
integrating over `deltaTime` (`Physics2D` driven as a `SketchSubsystem`, `TweenManager`, or a
hand-written velocity step) takes one enormous step and blows up.

**Reproduces on v0.9.0 and on `main`** (checked with `swift package edit metaphor --path <checkout>`).
Reported as [metaphor#793](https://github.com/shinyaoguri/metaphor/issues/793).

## 2. `PROBE=pmouse` — `pmouse` is two frames behind, not one

One injected `mouseMove` to (300, 200):

| | v0.9.0 | `main` |
|---|---|---|
| frame 1 | mouse=(300,200) pmouse=(0,0) | mouse=(300,200) pmouse=(0,0) |
| frame 2 | mouse=(300,200) **pmouse=(0,0)** | mouse=(300,200) pmouse=(300,200) |
| frame 3 | mouse=(300,200) pmouse=(300,200) | mouse=(300,200) pmouse=(300,200) |

On v0.9.0 `pmouse` catches up only at frame 3 — two frames behind. This is
[metaphor#522](https://github.com/shinyaoguri/metaphor/issues/522), **already fixed on `main`**
(PR #534 added `InputManager.endFrame()`) but not in any release as of 2026-08-16.

Reading the library source is not enough to tell: the local `main` checkout already has the fix,
while the sketch runs the pinned 0.9.0 from `.build/checkouts/`. The A/B above is the only
reliable way to separate "broken" from "unreleased".

## Why this is a separate package

The parent's `Instrument.swift` holds checks that need nothing but arithmetic. These two need a
live render loop, so they cannot live there — and the parent's own drawing would only add noise
to the measurement.
