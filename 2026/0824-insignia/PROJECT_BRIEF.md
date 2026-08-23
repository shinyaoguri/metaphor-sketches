# PROJECT_BRIEF — 0824-insignia

## Intent

Take the metaphor logo and make it a solid you can walk around: one continuous ribbon that coils,
tapers, and converges to a point at both ends. Matte, cream-white, lit like a plaster maquette on a
dark navy field. Seen edge-on it reads as a lowercase **m**; turn it a quarter and it is a shell;
sight down its axis and it is a vortex. The piece is the same object the whole time — the reading
changes with the angle, which is what the four preset views are for.

The letter is not drawn. It falls out of one term in the centre curve: `y = R(t) · (1 − cos θ)`
returns to zero at every multiple of 2π, so the valleys land on the baseline and the legs stand on
the ground. `R · sin θ` would give the same coil with the legs floating, and no letter.

## What "working" means

- The `m` preset reads as a letter: three legs on a common baseline, two arches, a tail curling up
- Both ends converge to a point — no flat cut, no cap
- Fully matte: no specular highlight anywhere, at any angle
- Dragging orbits, the wheel zooms, and the four presets ease into place without snapping
- Overlapping coils never flicker against each other, at any zoom

## Also an instrument

Almost none of the above can be judged from a screenshot. metaphor never culls backfaces, so a
mesh wound inside-out looks *nearly* right — the shading inverts but nothing disappears. A tube
whose end ring is 0.0003 across instead of a point looks identical to one that closes. So the piece
carries `Instrument.swift`: eight deterministic checks that run once at startup, publish measured
values (not booleans) to `frame.json` and stdout, and decide the things the eye cannot.

The self-check that matters most is `G4`, which takes every one of the 53,664 non-degenerate
triangles and asks whether its face normal agrees with the normals handed to the GPU. That is the
machine form of "the winding is outward".

## What it is verifying in metaphor

`DynamicMesh` as a closed solid at scale (27k vertices, hand-written normals and UVs, duplicated
seam), `OrbitCamera` / `orbitControl()` — untouched by every other sketch in this book —
`perspective` at a long focal length with a shallow near plane, `enableShadows` / `shadowBias`
under a world scale the sketch controls, PBR `roughness` / `metallic` at the fully-matte end, and
`saveFrame` after the #757 fix.

Details and results: [metaphor-sketches#27](https://github.com/shinyaoguri/metaphor-sketches/issues/27).

## Parameters

Held in `Insignia` (`Geometry.swift`), in the logical units the spec is written in. `worldScale`
multiplies them at mesh-build time.

| | | |
|---|---|---|
| `turns` | 2.35 | two arches plus the tail curl |
| `r0` / `k` | 1.0 / 0.58 | helix radius and its decay over the length |
| `lx` | 3.05 | axial travel |
| `t0` / `kt` | 0.36 / 0.70 | tube radius and its taper |
| `lead` / `cap` | 0.065 / 0.07 | the pinch at the thick end, the rounding at the thin end |
| `tubular` / `radial` | 560 / 48 | mesh resolution |
