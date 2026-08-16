# 0816-prism — splitting white light to check that colours survive the pipeline

A prism takes white light apart and a lens puts it back together. Both halves are the subject
*and* the test: the fan is a hue sweep, and the white spot at the focus is `blendMode(.additive)`
adding 72 monochromatic beams back to white. If the colours were wrong, the picture would say so.

Every other sketch in this book checks numbers that never reach the screen — physics, easing,
FFT, clocks. **This one checks the colour that comes out the far end of the drawing pipeline.**
`Spectrometer.swift` paints onto an offscreen `Graphics`, waits for the GPU with
`endDraw(wait: true)`, and reads pixels back with `toImage()` → `loadPixels()` → `get(x, y)`,
so it can measure colour without touching the artwork.

Verification record: [metaphor-sketches#14](https://github.com/shinyaoguri/metaphor-sketches/issues/14).
Pinned to **metaphor 0.9.0** (`Package.resolved`).

![Dispersion sweeping into total internal reflection](https://i.gyazo.com/8346a81388e93825d14a4ab082aa997d.gif)

The sketch window only, 8.5 s of the unattended swing. The prism turns, the fan sweeps down the
screen, and past the middle the angle of incidence drops below the critical angle — the violet end
goes first, then the whole spectrum, and the beam stops coming out at all. The label at the bottom
counts it (`全反射で欠けた波長 72/72` at 26°). Nothing is faded out by hand; that is the
total-internal-reflection condition in `Optics.deviation` returning `nil`.

## Run

```bash
swift build
tools/probe.sh check        # deterministic verdict table (run twice; must be identical)
swift run                   # the prism itself
```

| key | |
|---|---|
| `1`–`4` | pick a scene (dispersion / recombination / palette / aberration) |
| `SPACE` | stop / resume the automatic tour |
| `R` | run the self-check again |

Move the mouse to turn the prism (scene 1) or to change the aberration strength (scene 4).
Left alone, both swing on their own, so the sketch is worth watching unattended.

| env | |
|---|---|
| `PRISM_SCENE=<0-3>` | pin one scene — useful when capturing stills |
| `PRISM_SHOTS=1` | save one frame per scene and quit (lands in `~/Desktop`, see below) |
| `PRISM_FRAMES=<dir>` | write a numbered PNG sequence (absolute paths are honoured) |
| `PRISM_TRAP=<name>` | run one degenerate call on purpose |

## What it measures

39 checks in three layers, reported as `PASS` / `FAIL` with the **measured numbers inline**, to
stdout and to `probe("check.<ID>", …)`.

| layer | file | what it can reach |
|---|---|---|
| A | `Palette.swift` | the `Color` type itself — HSB conversion, interpolation, hex parsing, constants. Closed-form oracles, no drawing |
| B | `Spectrometer.swift` | colour **after** the pipeline — colour modes, blend modes, alpha, tint. Offscreen, so the artwork stays clean |
| C | `Runtime.swift` | things that need more than one frame — gradients, `pushStyle`, post effects |

Two of them fail, and both are upstream bugs found by this sketch:

- [metaphor#799](https://github.com/shinyaoguri/metaphor/issues/799) — `Color(hex: String)` does not
  check the digit count, so `"#FFF"` silently becomes blue instead of white (`A12`)
- [metaphor#800](https://github.com/shinyaoguri/metaphor/issues/800) — `BlendMode.subtract` also
  subtracts *alpha*, so anything drawn with it ends up fully transparent (`B9`)

## Notes for anyone reading the code

- **The spread is exaggerated ×9, the physics is not.** BK7's real dispersion puts n(700 nm) at
  1.513 and n(380 nm) at 1.534, a deviation difference of about 1.6° — roughly 18 px at this
  distance, which does not read as a rainbow. `App.swift` scales only the *difference from the
  540 nm ray*, so the order of the colours and the onset of total internal reflection stay
  physical. The label on screen says so too.
- **`previousFrame()` needs `enableFeedback()` first**, and it returns the frame from **two**
  frames ago, not one. `Runtime.swift` does not assume either: `G-0.feedbackLatency` paints a
  different shade every frame and works the delay out from what comes back. Hard-coding 1 made
  every gradient check read the *previous* stage's picture and fail.
- **Post effects never appear in `previousFrame()`.** `capturePreviousFrame` copies
  `colorTexture` (before the effect chain) at the top of the frame, while effects write to a
  separate texture that `saveFrame` picks up. That is why `P1` / `P2` assert the colour is
  *unchanged*; the effects are confirmed by eye in the `aberration` scene instead.
- **`Graphics` is a subset of the sketch API.** It has `colorMode`, `blendMode` and `tint`, but
  not `linearGradient`, `radialGradient` or `pushStyle` — which is exactly why layer C exists.
- **`saveFrame` always prefixes `~/Desktop`** ([metaphor#757](https://github.com/shinyaoguri/metaphor/issues/757)),
  so `PRISM_SHOTS` cannot choose its output directory. `beginFrameRecord(directory:)` does honour
  absolute paths, so `PRISM_FRAMES` can.
- **The colour APIs shrug off degenerate arguments.** `colorMode(.rgb, 0)`, a negative maximum,
  `radialGradient(segments: 0)` and a zero-sized gradient all survive. The one call that still
  kills the process is `createGraphics(0, 0)`
  ([metaphor#798](https://github.com/shinyaoguri/metaphor/issues/798)), kept behind
  `PRISM_TRAP=graphicsZero` so it never runs at startup.
