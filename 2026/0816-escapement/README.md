# 0816-escapement — a skeleton clock that checks the basics

An escapement turns continuous power into exactly timed discrete steps. That is what a frame
loop does, so the clock is the subject.

Every visible part is driven by metaphor's **most basic** APIs — angles from `Constants` and
`radians()`, positions from `map()` / `lerp()`, motion from the waveform helpers, the plate's
grain from a seeded `random()` / `noise()`, and the outer band **is** the 30 easing curves.
Behind the dial, `Instrument.swift` and `Runtime.swift` check those same APIs against closed-form
maths and report `PASS` / `FAIL` per API.

Verification record: [metaphor-sketches#12](https://github.com/shinyaoguri/metaphor-sketches/issues/12).
Pinned to **metaphor 0.9.0** (`Package.resolved`).

![The dial](https://i.gyazo.com/3f8a4a1eec9797c3cdad3411fa62e03a.png)

## Run

```bash
swift build
tools/probe.sh check      # deterministic verdict table (run twice; must be identical)
tools/probe.sh input      # feeds a fixed stdin script and judges the input APIs
tools/collide.sh          # which Constants collide with Darwin macros
swift run                 # the clock itself
```

| key | |
|---|---|
| `SPACE` | stop / start (`noLoop()` / `loop()`) |
| `ENTER` | advance exactly one frame (`redraw()`) |
| `TAB` | next plate |
| `←` `→` | wind the time by a minute |
| `↑` `↓` | wind the mainspring |
| `ESC` | reset |

Drag with the mouse to wind (horizontal = time, vertical = mainspring); scroll to jog by minutes.

## Plates

| | |
|---|---|
| **DIAL** | the clock. Escape wheel steps once per second (`square()`), balance swings continuously (`sine01()`), mainspring spiral from `curvePoint()` / `smoothstep()` |
| **REGULATOR** | the 30 easing curves as a chart. The red dot rides `triangle()` in sync with the seconds |
| **OSCILLOGRAM** | the 5 waveforms over three periods |

![The regulator plate](https://i.gyazo.com/2de0a708595fdd46651812cf2a6e232e.png)
![The oscillogram plate](https://i.gyazo.com/4a775e51cce297c73926cd39275eca4d.png)

![One second of the movement](https://i.gyazo.com/2be4f90539137887610911cb4d0f17b2.gif)

Frame range: the dial only (the window's own frames via `beginFrameRecord`, nothing else on
screen). About 4 seconds. Watch the escape wheel jump one tooth per second while the balance
wheel keeps swinging smoothly — the discrete/continuous contrast is the point.

## What the self-check covers

64 checks in 8 groups. `tools/probe.sh check` prints them; they also land in `frame.json` under
`custom` as `check.<ID>`, and a failing one stays red in the top-right corner of the sketch.

| group | what |
|---|---|
| **M** 16 | `map` / `lerp` / `constrain` / `norm` / `mag` / `dist` / `sq` / `radians` / `degrees` / `saturate` / `smoothstep` / `bezierPoint` / `curvePoint` and their degenerate arguments |
| **E** 8 | all 30 easing functions: endpoints, In↔Out mirror, InOut symmetry, monotonicity, overshoot, continuity |
| **W** 8 | the 5 waveforms: range, period, frequency scaling, sine/cosine phase, square duty |
| **R** 10 | `randomSeed` reproducibility, ranges, uniformity, `randomGaussian` moments, `noise` range/continuity, `noiseDetail` against the fBm closed form |
| **C** 3 | the 21 `Constants`, key codes against `kVK_*` |
| **T** 6 | `millis` vs `time`, `frameCount`, `deltaTime` sum, wall clock vs `Foundation`, `frameRate()` |
| **L** 6 | `noLoop` / `redraw` / `loop` / `isLooping`, and the clock while stopped |
| **I** 7 | injected mouse / key / scroll events (`tools/probe.sh input`) |

## Measurements (2026-08-16, metaphor 0.9.0)

62 / 64 PASS. The two failures:

| check | measured | |
|---|---|---|
| `L5.resumeDelta` | 0.8 s paused → first `deltaTime` after `loop()` = **0.8554 s** (one frame is 0.0167 s) | new → [metaphor#793](https://github.com/shinyaoguri/metaphor/issues/793) |
| `I3.pmouse` | `pmouse` is 2 frames behind for one frame after a move | known → [metaphor#522](https://github.com/shinyaoguri/metaphor/issues/522), fixed on `main`, unreleased |

A third problem is not a check but a trap — `tools/probe.sh trap graphicsZero`:
`createGraphics(0, 0)` aborts the process on a Metal assertion instead of returning `nil`,
while `createImage(0, 0)` correctly returns `nil`
([metaphor#798](https://github.com/shinyaoguri/metaphor/issues/798), reproduces on `main` too).

Both are isolated in [`2026/0816-probe-frameloop`](../0816-probe-frameloop/) as minimal repros.

Everything else held, including some things worth naming:

- **All 30 easing functions satisfy the algebraic identities exactly** — `easeOut(t) == 1 - easeIn(1-t)`
  and `f(t) + f(1-t) == 1` hold to under 1e-4 across 101 samples for all 10 families.
- **`randomGaussian(5, 2)` over 200k samples: mean 5.0088, sd 1.9983.** `random()` is uniform to
  within 1.17% over 10 bins.
- **`noiseDetail(octaves:)` matches the fBm closed form.** Derivative RMS relative to N=1:
  measured 0.915 / 1.056 / 1.404 for N = 2 / 4 / 8, against √N/(1−2⁻ᴺ) predicting 0.943 / 1.067 / 1.420.
- **`frameRate(30)` lands on 30.0 fps**; `frameCount` increments by exactly 1 per `draw()`;
  `millis()` and `time` agree; the wall-clock functions match `Foundation`.
- **All 16 key-code constants equal the Carbon `kVK_*` values.**

## Notes for anyone reading the code

**`RETURN` / `TAB` / `BACKSPACE` / `CONTROL` cannot be written bare once the file imports
Foundation.** They collide with Darwin macros from `sys/tty.h`, and `metaphor.RETURN` does *not*
disambiguate (metaphor re-exports Foundation). Within the bare globals, a type annotation is the
only fix:

```swift
let ret: UInt16 = RETURN   // compiles
print("\(RETURN)")         // error: ambiguous use of 'RETURN'
```

`tools/collide.sh` scans all 21 constants under both import sets. Reported as
[metaphor#794](https://github.com/shinyaoguri/metaphor/issues/794) and **fixed in v0.10.0** —
not by renaming the globals (they still collide, so the tool keeps reporting all four) but by
adding a `KeyCode` namespace that carries the same values under a qualified spelling:

```swift
print("\(KeyCode.return)")      // compiles — no annotation needed
if keyCode == KeyCode.space { } // reads better than the bare global too
```

So read `collide.sh` output as "which spellings still need an annotation", not as "still broken".
The namespace is the way out whenever a sketch needs both key input and Foundation — which
includes every sketch using `saveState()` / `restoreState(_:)`, since those take `Data`.

**`square(_:frequency:duty:)` is shadowed inside a `Sketch`** by the drawing method
`square(_:_:_:)`. Write `MetaphorCore.square(t, frequency:duty:)`.

**Loop control must not be called from `draw()`.** `redraw()` calls `MTKView.draw()`
synchronously, so calling it inside `draw()` re-enters the render pass. `Runtime.scheduleLoopChecks`
drives it from a main-queue timer instead — the same path the `SPACE` / `ENTER` keys take.

**`R9.noiseDetail` was wrong before it was right.** The first version asserted "more octaves →
rougher", which is not what normalised fBm does: with `falloff = 0.5` going from 1 to 2 octaves
makes the field *slightly smoother*. The check now compares against √N/(1−2⁻ᴺ). Sampling step
matters too — at 0.01 the 8th octave (frequency 128) aliases and the measurement drifts from
theory; the check samples at 0.0005.

**The library source on disk is not the library the sketch runs.** `pmouse` looked correct when
read from a local `main` checkout and wrong when measured — because the sketch resolves 0.9.0
into `.build/checkouts/`. Measure, then A/B with `swift package edit`.

## Traps

Calls that would stop the sketch from starting if the self-check ran them every launch live
behind `ESCAPEMENT_TRAP=<name>` (`tools/probe.sh trap <name>`). Eleven degenerate arguments,
measured on v0.9.0:

| trap | result |
|---|---|
| `frameRateZero` / `frameRateNegative` | survives — clamped to 1 with a warning ([#358](https://github.com/shinyaoguri/metaphor/issues/358)) |
| `noiseOctavesZero` / `noiseOctavesNegative` | survives — clamped to 1 by `NoiseGenerator.octaves`' `didSet` |
| `textSizeZero` | survives — `textWidth("abc")` still returns 21.0, so the size is ignored rather than applied |
| `curveDetailZero` / `easeNaN` | survives — `easeInOutCubic(nan)` returns `nan` |
| `imageZero` | survives — `createImage(0, 0)` returns `nil`, which is the right answer |
| **`graphicsZero` / `graphicsNegative` / `graphics3DZero`** | **aborts the process** → [metaphor#798](https://github.com/shinyaoguri/metaphor/issues/798) |

## Soak

`tools/probe.sh soak 1800` runs a release build unattended for 30 minutes and compares the first
half's RSS / CPU against the second half. Output goes to `.probe-out/` and is not committed.

Measured 2026-08-16, release build, 180 samples over 1794 s: RSS **83.0 MB → 84.2 MB**
(+1.2 MB, flattening after ~15 min), CPU steady at **~7 %**. `L5.resumeDelta` fails in the
release build too (1.0258 s), so it is not a debug-build artefact.
