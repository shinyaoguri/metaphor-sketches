# 0824-insignia

The metaphor logo as a solid you can walk around.

One continuous ribbon coils, tapers, and converges to a point at both ends — a shell, or a drill
bit. Seen edge-on it reads as a lowercase **m**: three legs on the baseline, two arches between
them, and the leftover 0.35 of a turn curling up as a tail.

![the m view](https://i.gyazo.com/ec34f5d746a34d9888432bc78ec4d849.png)

![one full turn](https://i.gyazo.com/92b74ad89f76aa25b06ea8dfd233c4cf.webp)

The letter comes from one choice in the centre curve: `y = R(t) · (1 − cos θ)` rather than
`R · sin θ`. `1 − cos` returns to zero at every multiple of 2π, so **the valleys always touch the
baseline** — the legs stand on the ground instead of floating. Everything else (the radius decay,
the tube taper, the rounded tip) only decides how it tapers.

This is the first sketch in this book to exercise **`OrbitCamera` / `orbitControl()`**, and the
first to build a **closed solid** out of `DynamicMesh` — 27,489 vertices and 53,760 triangles with
hand-written normals, no caps, no backface culling to hide a mistake behind.

Verification record: [metaphor-sketches#27](https://github.com/shinyaoguri/metaphor-sketches/issues/27).

## Run

```bash
swift run           # or: metaphor run
metaphor watch      # live viewer + hot reload
```

| Key | |
|---|---|
| `1` `2` `3` `4` | preset views — `m` / `iso` / `top` / `axis` |
| drag / wheel | orbit / zoom |
| `a` | auto-rotate |
| `f` | floor (the only shadow receiver; turning it on turns shadows on) |
| `x` | shadows on/off |
| `s` | save a PNG into `output/` |
| `b` | transparent-background save — **has no effect**, see below |
| `h` | overlay |

## Observing it without a viewer

```bash
tools/probe.sh check      # the deterministic self-checks, with measured values
tools/probe.sh shots      # the four presets into output/
tools/probe.sh contrast   # the shadow experiment: worldScale 120 vs 1
tools/probe.sh frames     # one full turn as a numbered PNG sequence
tools/probe.sh soak 180   # unattended run, RSS/CPU into a CSV
tools/replay-input.py     # replay the viewer's input events with no GUI at all
```

`replay-input.py` is how the mouse bugs below were found and fixed. `METAPHOR_VIEWER=1` makes the
sketch read the same JSON-Lines input stream the live viewer sends, so a pathological event
sequence can be replayed and measured without touching a mouse:

| Sequence | Camera azimuth after 600px of input |
|---|---|
| `stuck` — `mouseDown`, then `mouseMove` with no `mouseUp` | 0 rad (was -25.26 before the fixes) |
| `drag` — `mouseDown` → `mouseDrag` ×60 → `mouseUp` | -3.00 rad = 600px × 0.005 rad/px |
| `press` — a single `mouseDown`, nothing else | 0 rad (was -3.20) |

Environment hooks: `INSIGNIA_SHOTS=1`, `INSIGNIA_FRAMES=<dir>`, `INSIGNIA_SCALE=<float>`,
`INSIGNIA_SHADOWS=0|1`, `INSIGNIA_FLOOR=1`, `INSIGNIA_TRANSPARENT=1`, `INSIGNIA_SPIN=1`.

## Self-checks

`Instrument.swift` runs once in `setup()` — no drawing, no clock, so the numbers are the same on
every run. Each verdict goes to `frame.json` as `check.<ID>` and to stdout. Measured on
metaphor 0.13.0 at the default `worldScale = 120`:

| ID | What it decides | Measured |
|---|---|---|
| `G1.baselineContact` | the valleys sit exactly on `y = 0` | PASS — 3 valleys, max \|y\| = 0 |
| `G2.tipConvergence` | both ends reach radius 0, so no caps are needed | PASS — 0 / 0, mid 0.301 |
| `G3.meshCounts` | 561 × 49 vertices, 560 × 48 × 6 indices | PASS — 27,489 / 161,280 |
| `G4.outwardWinding` | every face normal agrees with its vertex normals | PASS — 0 inward of 53,664, min dot 0.260 |
| `G5.frameOrthonormality` | (T, N, B) stays orthonormal and right-handed | PASS — max deviation 2.4e-07 |
| `G6.closedSolid` | manifold edges, and both end rings collapse to a point | PASS — 0 over-shared, 96 boundary, spread 0 |
| `G7.letterProfile` | the profile really is 2 arches over 3 legs | PASS — 2 peaks / 3 valleys |
| `S1.shadowFootprint` | how much of the shadow map the piece occupies | PASS — 1877px of 4096 (FAIL at `INSIGNIA_SCALE=1`: 15px) |

`G4` exists because **metaphor never culls backfaces** — every 3D path sets `cullMode(.none)`. Wind
a triangle the wrong way and the face does not disappear; only the shading quietly inverts. The
usual "it went inside-out, you can see through it" symptom never appears, so the winding has to be
decided by arithmetic rather than by looking.

## Notes for anyone reading the code

- **`perspective()` must be called every frame.** `Canvas3D` resets fov / near / far to the
  Processing-style defaults at the start of each frame, so calling it once in `setup()` silently
  renders at the default 60° fov. Filed as [metaphor#1098](https://github.com/shinyaoguri/metaphor/issues/1098).
- **World +y points down the screen.** metaphor flips Y in the projection (Processing's
  convention). `Insignia.yAxis` applies that flip once, in `curve()`; everything downstream — the
  checks, the camera presets, the lights — lives in the flipped world.
- **`ambientLight` takes `colorMode` units (0–255); `directionalLight`'s `color:` takes a `Color`
  (0…1).** Both appear within three lines of each other in `applyLights()`.
- **Shadows are off by default.** The spec this sketch follows wants the mesh to cast but not
  receive, with a hidden floor as the only receiver. metaphor has no per-object receive flag, so
  the closest honest realisation is "put no receiver in the scene". Turning shadows on makes the
  far coils sink into a flat dark mass and the silhouette stops reading —
  [metaphor#1096](https://github.com/shinyaoguri/metaphor/issues/1096).
- **The shadow's ortho extent is fixed at ±500 world units** and cannot be narrowed, which is why
  the geometry is built in logical units and multiplied by `worldScale = 120` at build time rather
  than being camera-fitted at spec scale — [metaphor#1095](https://github.com/shinyaoguri/metaphor/issues/1095).
- **`saveFrame` is asynchronous.** It writes during the next frame's GPU completion, so exiting
  right after calling it loses the file (this cost the fourth preset shot once). Both capture modes
  hold for a few extra frames before `exit`.
- **`b` (transparent save) is kept even though it does nothing.** `background(r, g, b, 0)` still
  produces a fully opaque PNG — [metaphor#1097](https://github.com/shinyaoguri/metaphor/issues/1097).
  The code path stays so the claim can be re-measured when that changes.
- **`orbitControl()` is wrapped in three guards.** It rotates purely from "is the button down"
  and "how far did the cursor move since last frame", so it turns whenever either of those lies:
  a stale button state (the live viewer forwards window-frame clicks and loses the matching
  mouse-up when you resize the window — [metaphor-cli#189](https://github.com/shinyaoguri/metaphor-cli/issues/189)),
  and the press frame itself, where the cursor position jumps to wherever it was clicked
  ([metaphor#1100](https://github.com/shinyaoguri/metaphor/issues/1100)). The third guard is a
  0.25 rad/frame ceiling as a backstop. Without them, resizing the viewer window left the object
  spinning at drag speed from bare mouse movement.
- **`orbitCamera.sensitivity` is divided by `(1 - damping)`.** `damping` accumulates raw deltas
  into a velocity without compensating the gain, so it multiplies effective sensitivity by
  `1/(1 - damping)` — 7.1× at 0.86 — [metaphor#1099](https://github.com/shinyaoguri/metaphor/issues/1099).
- **The tube radius is snapped to exactly 0 at `t = 0` and `t = 1`.** `sqrt(1 − u²)` picks up a
  1e-8 residual just short of `u = 1`, and the square root lifts it to 1e-4 — a ring 0.0003 across
  where a point belongs. Invisible, but it stops being a closed solid, and `G6` fails on it.

## Layout

| File | |
|---|---|
| `Sources/Sketch0824Insignia/Geometry.swift` | the shape. Pure functions, no metaphor API — the checks call the same code the mesh is built from |
| `Sources/Sketch0824Insignia/Instrument.swift` | the deterministic checks |
| `Sources/Sketch0824Insignia/App.swift` | the viewer — camera, lights, presets, input, capture |
| `tools/probe.sh` | observing it without a viewer |
| `tools/replay-input.py` | replaying the viewer's input stream headlessly (kept as the repro for the mouse bugs) |
