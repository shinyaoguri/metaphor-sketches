# 0823-darkroom

**A darkroom.** One negative goes through three developing baths and leaves the building on
three separate Syphon lines. Window A shows the negative itself, B keeps only its edges
(`MPSSobelEffect`), C thickens and blurs it (`MPSDilateEffect` + `MPSBlurEffect`). There is
exactly **one** `Darkroom` state object and all three windows draw from it, so the three
lines carry *the same instant, three faces*.

Every 60 seconds the process walks 露光 → 現像 → **停止** → 定着. In 停止 the baths come out
and all three windows fall back to the same picture — the control for "the difference really
is the baths' doing".

Verification record: [metaphor-sketches#25](https://github.com/shinyaoguri/metaphor-sketches/issues/25).

## The negative is a test signal

The receiver never looks at the picture; it reads numbers off it. So the negative carries
three things that survive developing:

| | What it is for |
|---|---|
| **Exposure clock** | A thick hand, one turn per 8 s. Three lines agreeing on its angle ⇒ they show the same instant. Sobel leaves the edges of the hand, dilate leaves its direction — the angle survives both |
| **Step wedge** | 11 steps along the bottom edge. Mean luma is `255 × 0.5 = 127.5` **by construction**, so the expected value is derivable without calling metaphor |
| **Grain** | Deterministic (SplitMix, fixed seed). Coarse enough that sobel has something to find |

## Arranging it

**metaphor still has no API for window position** ([#20](https://github.com/shinyaoguri/metaphor-sketches/issues/20) `W7`,
[metaphor#837](https://github.com/shinyaoguri/metaphor/issues/837)), so the three windows come
up cascaded and you place them yourself. Each carries its bath name and its Syphon server name
on its plaque, so you can tell which window feeds which line without opening a receiver.

## Run

```bash
swift run
```

```bash
tools/probe.sh cycle       # built-in checks, prints the verdict table (D1–D11)
tools/syphon-read.sh       # receive all three lines from outside and judge them  ← the primary evidence
tools/probe.sh env         # METAPHOR_SYPHON_NAME on top of the declarations (D3)
tools/probe.sh anon        # .syphon() with no name on every window (D4)
tools/probe.sh stoptest    # declaration + env var, then one stopSyphonServer() (D11)
tools/probe.sh occlude     # hide the app and see whether publishing continues (D7)
tools/probe.sh term        # SIGTERM and check the Syphon directory is clean (D9)
tools/probe.sh soak 180    # unattended, RSS and CPU every 10 s
```

`tools/probe.sh` with no argument prints the rest.

While `DARKROOM_FRAMES` is set, all three windows drop to **6 fps** (`Bath.recordingFPS`), one
process stage shrinks to 4 s, and **the checks do not run at all**. Writing a 1920×1080 PNG per
frame on three windows is heavy enough that each window misses its target differently — 12 fps
gave 215 / 199 / 216 frames, so a GIF assembled by frame index shows a seam that is not there.
Worse, the lifecycle check (`D6`) rebuilds a window, which throws away its `beginFrameRecord`
setting: window C came out with 76 frames because it only recorded up to the close. At 6 fps
with the checks off, all three land on exactly 140.

### Why there is an external reader

`loadPixels()` reads `renderer.textureManager.colorTexture` — the canvas **before**
post-effects — so the sketch cannot see its own developed picture (that is judgement `D5`,
measured, not assumed). **The only place the baths can be measured is the receiving end**, so
`tools/syphon-read.sh` opens a `SyphonMetalClient` on each of the three servers, blits the
texture into a shared buffer and prints mean luma, bright-pixel share, edge rate, the wedge
profile at both edges, and the hand angle. No MadMapper needed; it all comes out as text.

## What it measured

metaphor 0.13.0 + metaphor-syphon 0.2.0, macOS 15, Apple Silicon.
`[ID]` matches the verdict lines the sketch prints.

| | Result |
|---|---|
| `D1` | **PASS** — three windows, and the lag between what a secondary drew and the primary's frame counter is **1 frame** |
| `D2` | **PASS** — `SketchWindowConfig.plugins: [.syphon(name:)]` gives each window its own server: `darkroom - A/B/C`, three distinct names |
| `D3` | **PASS** — `METAPHOR_SYPHON_NAME` does **not** leak into secondary windows (0 of 2 took the env name). It adds a **fourth** server on the primary instead |
| `D4` | `.syphon()` with no name: the primary publishes under the **sketch title**, both secondaries under the **process name** — so the two windows stand up **two servers with the same name** (distinct UUIDs; they coexist rather than collapse) |
| `D5` | `loadPixels()` returns the picture **before** developing — wedge reads 127.5 on both the plain and the sobel window, exactly the derived expectation |
| `D6a`/`D6b` | **PASS** — closing a window takes its server down (`onDetach` → `SyphonOutput.stop()`), reopening brings `darkroom - C` back. **No workaround needed**: the close/reopen crash that 0816-triptych had to splint ([metaphor#835](https://github.com/shinyaoguri/metaphor/issues/835)) does not reproduce on 0.13.0 |
| `D7` | **PASS** — hiding the app does not stop publishing: **+240 / +240 / +240 frames in 4 s** on all three windows (60 fps exactly). The `.externalRenderLoop` promotion reaches secondary windows too — the part [#20](https://github.com/shinyaoguri/metaphor-sketches/issues/20) `W6` could not observe |
| `D8` | **PASS** — per-window clock drift **1.3 ms (B) and 3.9 ms (C)** over 10 s, well under one 60 fps frame |
| `D9` | **PASS** — SIGTERM leaves **0** servers in the directory ([metaphor#715](https://github.com/shinyaoguri/metaphor/issues/715) does not regress) |
| `D10` | Measured from the receiving end: luma **B 8.9 < A 23.5 < C 32.6**, edge rate **B 7.52 ≫ C 2.64 ≈ A 2.30** — the three lines are not swapped |
| `D11` | Declaration + env var stand up two `SyphonPlugin`s **with the same `pluginID`**. `stopSyphonServer()` stops the **env** one and leaves the declared one running — see below |
| interlock | Hand angle spread across the three lines: **0.5°** and **7.5°** in two reads (the hand turns 45°/s, so 7.5° ≈ 0.17 s) |
| soak | **1800 s / 180 samples.** RSS climbs to ~104 MB in the first 5 minutes and then sits at **104.3–104.5 MB for the remaining 25 minutes** (slope +0.41 MB/hour over that stretch — flat). 30 process stages and 3 Syphon servers running throughout |

### Two things worth knowing before you build on this

**The texture arrives upside down.** metaphor-syphon publishes with `flipped: true`, which is
a *flag on the frame*, not a transform of the pixels. A receiver that ignores the flag — like
`tools/syphon-read.sh` — sees the step wedge, which the sketch draws along the **bottom** edge,
at the **top** of the received texture. That is the tool's `wedge↑` column reading 127.5 while
`wedge↓` reads 7.0.

**Declaring `.syphon(name:)` *and* passing `METAPHOR_SYPHON_NAME` gives you two servers, and
you cannot stop the one you declared.** Two servers is documented behaviour
(`PluginFactory.syphon(name:)` says the env var "stands up another server under that name,
independently of this factory"). What is not documented is which one the compatibility facade
reaches: `SyphonPlugin.id` is a fixed string, so the renderer holds two plugins with the same
id, metaphor warns about it —

```
[metaphor] Warning: addPlugin: a plugin with id 'org.metaphor.syphon-output' is already
registered; plugin(id:)/removePlugin(id:) will only reach the first one
```

— and `stopSyphonServer()` reaches only the first. Measured: before the call `syphonOutput`
reports `darkroom - ENV`; after it reports `darkroom - A`, and the directory drops from 4
servers to 3 with **`darkroom - A` still publishing**. Reproduce with `tools/probe.sh stoptest`.

### A note on measuring, not on metaphor

Two numbers in early runs were **our own instrument's fault**, not metaphor's, and both are
worth repeating because they are easy to fall into:

- **Clock drift read 399 ms** until the baseline was taken *after* the read-back checks.
  `loadPixels()` blocks the main thread waiting on the GPU, which stalls the secondary render
  loops for that moment — the sketch was measuring its own examination. `BathMeter.rebase()`
  now re-bases the drift baseline once the read-back checks are done; the real figure is 1–4 ms.
- **The hand angle on line B was 126° off** while A and C agreed, because the reader sampled a
  single circle. Under sobel the hand becomes two thin edges and lost to the scattered grain.
  Integrating radially (r = 80…340) before picking the angle fixed it — the spread went to 0.5°.

## Comments in the code

`App.swift` / `Plate.swift` / `Baths.swift` / `Instrument.swift` are commented in Japanese
(the split `metaphor new` intends: English for `AGENTS.md` and this file, Japanese for code).
