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
tools/probe.sh own 40    # let each wing use its OWN clock — watch the seam break
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

metaphor 0.9.0, macOS 15, Apple Silicon. `[ID]` matches the verdict lines the sketch prints.

| | Result |
|---|---|
| `W1`–`W4` | `createWindow` / config round-trip / `context` dimensions / per-window isolation — all PASS |
| `W3` | `context.width/height` is the **offscreen texture** size (800×720), not the window size (400×360) |
| `S2` | wings at 30 and 60 fps: frame count ratio 360/719 = **0.501** (expected 0.500) |
| `S5` | not measurable here — a synthesised `NSEvent` reaches neither a wing nor the centre, so the check reports N/A rather than a false failure |
| `S1` | clocks of windows created together stay within **10–17 ms** over 12 s — under one frame of the shared clock's update granularity |
| `S4` | a click at the centre of a `windowScale: 0.5` wing maps to texture (400.0, 360.0), error **0.00 px** |
| `L1`–`L3` | `close()` is idempotent, `closeAllWindows()` closes everything, and creating again afterwards works |
| `L2` | on a closed window `draw(_:)` drops the closure and `onDraw(_:)` keeps it — the asymmetry the docs describe |
| `L5` | **FAIL** — reopening with the same config walks the window (30, −30) px each time |
| `W7` | **FAIL** — the wings cannot be placed left and right; there is no position API |
| `W6` | not observable — the `.timer(fps:)` promotion for `syphonName` never reaches `window.config` |
| `W8` | **FAIL** — a 0, negative or 65536-wide config aborts inside Metal instead of returning `nil`; `windowScale: 0` opens a live 0×0 window |
| soak | 1800 s / 179 samples, RSS 88.6 MB → 88.7 MB across 42 open-close cycles — flat |

Four of these went upstream:

- [metaphor#835](https://github.com/shinyaoguri/metaphor/issues/835) — closing a secondary
  window and then opening another one **crashes the process** (`isReleasedWhenClosed`)
- [metaphor#836](https://github.com/shinyaoguri/metaphor/issues/836) — a re-created wing's
  `context.time` restarts at 0, contradicting the documented "time since the sketch started"
- [metaphor#837](https://github.com/shinyaoguri/metaphor/issues/837) — no window position
  API, and the cascade counter never decreases
- [metaphor#842](https://github.com/shinyaoguri/metaphor/issues/842) — a degenerate
  `SketchWindowConfig` aborts on a Metal assertion instead of returning `nil`

## The workaround

**Without it this sketch cannot exist.** Closing a wing and opening it again 12 seconds
later kills the process 3 times out of 3 (metaphor#835). So `makeWindow(_:)` clears
`isReleasedWhenClosed` on every `NSWindow` right after `createWindow` returns.

Clearing it on the one window matching the title is **not enough**: a closed window stays
in `NSApp.windows` for over ten seconds, so reopening with the same title hits the stale
one and the new wing stays unpatched — which is exactly how the second cycle (t = 84 s)
died before the workaround was widened.

Set `TRIPTYCH_NOWORKAROUND=1` to drop the workaround and watch it crash at t = 42 s.
The minimal repro lives in [`0816-probe-windowclose`](../0816-probe-windowclose/).

## Notes for reading the code

- `World.swift` draws a panel. It takes a `SketchContext` and a world-x origin, and it is
  the **same function** for all three panels — the centre passes `Sketch.context`, the wings
  pass `SketchWindow.context`.
- **The wings draw with the primary's clock, not their own.** `Stage.clock` is written by
  the centre every frame and read by the wings from their own render loops. Using each
  wing's `ctx.time` instead (`tools/probe.sh own`) breaks the seam by 42 seconds the moment
  a wing is recreated — see metaphor#836.
- The destructive checks (`W5`, `L1`–`L5`) run **one step per frame**, not in `setup()`.
  Opening and closing windows in a single runloop turn is one of the shapes that crashes.
- Colours are `Color` (0…1) throughout, never `fill(0–255)`, so there is no scale to mix up.
- `saveFrame(_:)` prefixes `~/Desktop/` unconditionally, so the shots pass a bare filename
  ([metaphor#757](https://github.com/shinyaoguri/metaphor/issues/757)).
