# 0816-triptych

**A triptych.** One continuous world painted across three windows — a centre panel
(the primary window) and two wings created with `createWindow`. A procession walks the
world from left to right, the sun crosses it once every 90 seconds, and a band of light
sweeps through every 6 seconds. Like an altarpiece, the wings close and open again.

The seam is the subject. In metaphor a secondary window gets its **own** renderer, canvas,
input manager, render loop and **clock**, so three panels showing "the same world at the
same instant" is not a given. If the clocks disagree, the procession jumps at the seam —
the light band runs at 480 px/s, so one frame of skew (16.7 ms) is roughly 8 px of jump.
The work is its own galvanometer.

Verification record: [metaphor-sketches#20](https://github.com/shinyaoguri/metaphor-sketches/issues/20).

## Arranging it

**metaphor has no API for window position**, so the three windows come up cascaded and you
place them yourself: left wing, centre, right wing. Each panel carries its own nameplate
(which slice of the world it shows) and a world-coordinate ruler along its bottom edge.
When the ruler reads continuously across the three windows — 0…800, 800…2080, 2080…2880 —
the seams are right.

Press `w` to close and reopen the wings by hand. Click any panel to leave a lantern in the
world; the procession lights up as it passes.

## Run

```bash
swift run
```

```bash
tools/probe.sh check     # full self-check, prints the verdict table
tools/probe.sh trace 60  # clock skew, per-window fps, window positions, every 2s
tools/probe.sh own 50    # let each wing use its OWN clock (this broke the seam on 0.9.0)
tools/probe.sh frames    # numbered PNGs from all three panels, for a GIF
tools/probe.sh soak 180  # unattended, RSS and CPU every 10s
```

While `TRIPTYCH_FRAMES` is set, all three panels drop to 20 fps (`Altar.recordingFPS`).
Writing a PNG per frame is heavy enough that the panels miss their targets otherwise, and
then **frame number no longer maps to the same instant on each panel** — a GIF assembled by
index shows a seam that is not there. `S2` reads its expected ratio from the configs so this
mode does not fail it spuriously.

`tools/probe.sh` with no argument prints the rest.

## What it measured

metaphor 0.10.0, macOS 15, Apple Silicon. `[ID]` matches the verdict lines the sketch prints.
The sketch was first measured on 0.9.0 and re-measured when the pin moved to 0.10.0; rows marked
*was FAIL on 0.9.0* are the ones that changed.

| | Result |
|---|---|
| `W1`–`W4` | `createWindow` / config round-trip / `context` dimensions / per-window isolation — all PASS |
| `W3` | `context.width/height` is the **offscreen texture** size (800×720), not the window size (400×360) |
| `S2` | wings at 30 and 60 fps: frame count ratio 359/719 = **0.499** (expected 0.500) |
| `S5` | not measurable here — a synthesised `NSEvent` reaches neither a wing nor the centre, so the check reports N/A rather than a false failure |
| `S1` | clocks of windows created together stay within **4–16 ms** over 12 s — under one frame of the shared clock's update granularity |
| `S4` | a click at the centre of a `windowScale: 0.5` wing maps to texture (400.0, 360.0), error **0.00 px** |
| `L1`–`L3` | `close()` is idempotent, `closeAllWindows()` closes everything, and creating again afterwards works |
| `L2` | on a closed window `draw(_:)` drops the closure and `onDraw(_:)` keeps it — the asymmetry the docs describe |
| `L5` | **PASS** *(was FAIL on 0.9.0)* — three reopens with the same config all land on (836, 751); the window no longer walks (30, −30) px each time |
| `W7` | **FAIL** — the wings cannot be placed left and right; there is no position API |
| `W6` | not observable — the `.timer(fps:)` promotion for `syphonName` never reaches `window.config` |
| `W8` | **PASS** *(was FAIL on 0.9.0)* — a 0, negative or 65536-wide config returns `nil`, and so does `windowScale: 0`, instead of aborting inside Metal |
| soak | **without the workaround**, 1800 s / 180 samples across 43 open-close cycles: RSS 87.8 MB → 89.7 MB overall; past the 120 s warm-up it is 88.8 → 89.7 MB, and the last 600 s (14 cycles) sits flat at 89.7 MB. `NSWindow` stays at 3 throughout |

Four of these went upstream. Three are fixed as of v0.10.0:

- [metaphor#835](https://github.com/shinyaoguri/metaphor/issues/835) — closing a secondary
  window and then opening another one **crashed the process** (`isReleasedWhenClosed`).
  **Fixed in v0.10.0**, which is what let the workaround below go
- [metaphor#836](https://github.com/shinyaoguri/metaphor/issues/836) — a re-created wing's
  `context.time` restarted at 0, contradicting the documented "time since the sketch started".
  **Fixed in v0.10.0**: after the t = 42 s reopen a wing reports `own = 42.22 s`, `Δ = 7.9 ms`,
  where it used to come back with `Δ = −42009.7 ms`
- [metaphor#842](https://github.com/shinyaoguri/metaphor/issues/842) — a degenerate
  `SketchWindowConfig` aborted on a Metal assertion instead of returning `nil`.
  **Fixed in v0.10.0** — all four traps (`zero` / `negative` / `huge` / `scalezero`) return
  `nil` and the process keeps running
- [metaphor#837](https://github.com/shinyaoguri/metaphor/issues/837) — no window position
  API, and the cascade counter never decreases. **Still open, but half of it moved on
  v0.10.0**: the cascade no longer drifts (`L5` passes and the wings hold their place across a
  reopen), while the position API is still missing (`W7` still fails, and `AltarArrangement`
  still has to place the three windows through AppKit)

## The workaround, and why it is gone

**On 0.9.0 this sketch could not exist without one.** Closing a wing and opening it again 12
seconds later killed the process 3 times out of 3 (metaphor#835), so `makeWindow(_:)` cleared
`isReleasedWhenClosed` on every `NSWindow` right after `createWindow` returned.

Clearing it on the one window matching the title was **not enough**: a closed window stayed
in `NSApp.windows` for over ten seconds, so reopening with the same title hit the stale
one and the new wing stayed unpatched — which is exactly how the second cycle (t = 84 s)
died before the workaround was widened.

**v0.10.0 fixes the double free, so the workaround and its `TRIPTYCH_NOWORKAROUND` escape hatch
are both gone.** `makeWindow(_:)` is a plain `createWindow(config)` now. What replaced the
workaround is the measurement: on 0.10.0 the destructive checks (`W5`, `L1`–`L5`) run to
completion, a 60 s trace crosses the t = 42 s reopen with the wings holding their position and
`NSWindow` staying at 3, and the soak above runs four open-close cycles without it.

The minimal repro still lives in [`0816-probe-windowclose`](../0816-probe-windowclose/), which
is still pinned to 0.9.0 — the version where the crash reproduces exactly as reported.

## Notes for reading the code

- `World.swift` draws a panel. It takes a `SketchContext` and a world-x origin, and it is
  the **same function** for all three panels — the centre passes `Sketch.context`, the wings
  pass `SketchWindow.context`.
- **The wings draw with the primary's clock, not their own.** `Stage.clock` is written by
  the centre every frame and read by the wings from their own render loops. On 0.9.0, letting
  each wing use its `ctx.time` instead (`tools/probe.sh own`) broke the seam by 42 seconds the
  moment a wing was recreated (metaphor#836). **v0.10.0 fixed that**: on 0.10.0 `own` stays in
  step — after the t = 42 s reopen the wings report `own = 42.31 s` and `42.32 s` against a
  centre at `42.32 s`. The shared clock is kept anyway, because it makes the seam independent
  of how each window's render loop happens to be driven.
- The destructive checks (`W5`, `L1`–`L5`) run **one step per frame**, not in `setup()`.
  Opening and closing windows in a single runloop turn was one of the shapes that crashed on
  0.9.0. Whether 0.10.0 also fixed *that* shape has not been re-measured — the checks were
  left frame-driven rather than moved back into `setup()` to find out.
- Colours are `Color` (0…1) throughout, never `fill(0–255)`, so there is no scale to mix up.
- `saveFrame(_:)` resolves a relative path against the **project directory** since 0.10.0
  ([metaphor#757](https://github.com/shinyaoguri/metaphor/issues/757)), so the shots are written
  to `output/`, which is gitignored. On 0.9.0 it prefixed `~/Desktop/` unconditionally and
  silently dropped absolute paths.
