# 0816-marionette

A 2D Verlet physics world is the strings; a 3D scene graph is the puppet.

Each scene solves its physics on a flat plane and then hangs that whole plane in 3D space as a
scene-graph node. The parent node carries the plane's pose and turns slowly; its children are
driven frame by frame by the bodies of the physics world. You see a suspended structure; what
moves it is an integrator running on a plane you never see.

This is the first sketch in this book to exercise **MetaphorPhysics** and **MetaphorSceneGraph**,
and the bridge between them (`Node.syncFromPhysics` / `syncToPhysics`).

## Run

```bash
swift run                 # or: metaphor run
metaphor watch --viewer   # live viewer + hot reload
```

Keys: `1`–`4` select a scene, space toggles auto-advance, `l` links, `h` HUD, `c` culling.

Diagnostic modes:

```bash
MARIONETTE_SHOTS=1 swift run          # write one PNG per scene to ~/Desktop, cycling every 12s
MARIONETTE_TRACE=1 swift run          # print body/node world positions every 120 frames
MARIONETTE_TRAP=iterations swift run  # reproduce the negative-iterations crash (see below)
```

## Scenes

| Scene | What it shows | API weight |
|---|---|---|
| `chain` | Three chains with heavy bobs, each on its own physics world, each plane turning | `pin` / `addConstraint` / `stiffness` / `worldTransform` composition |
| `cloth` | A 22×15 lattice pinned along its top edge, rippling in a slow wind | constraint count, broad-phase load, `applyForce` |
| `pit` | Circles and rectangles falling into a walled pit, swapped out as they settle | shape-pair collisions, `bounds`, `removeBody` at runtime |
| `swarm` | 240 cells drifting across a wide field while the camera sweeps | `AABB` / `worldBounds` / `intersects(frustum:)` / `extractFrustumPlanes` |

## The sketch checks itself

`Instrument.swift` runs a deterministic suite at startup — no rendering, no clock, same numbers
every run — and publishes every verdict to `frame.json` under `check.<ID>`, plus `summary.passed`
/ `summary.failed`. The results also print to stdout at launch, so a soak log carries them.

**Measured on metaphor v0.9.0: 13 / 18 PASS.** The five failures are library behaviour, not
sketch behaviour; each is reduced to a single number below.

| Check | Result |
|---|---|
| `P1.timestepJitter` | **FAIL** — the same 10 s at the same mean `dt` falls 25 % further when the step is jittered (`-50059` steady vs `-62536` jittered) |
| `P2.velocityUnits` | **FAIL** — `velocity` is px per **step**, not px per second (`-16.6665` after 1 s at g = 1000) |
| `P3.restitution` | **FAIL** — a ball dropped 290 with `e = 0.9` rebounds 15.7 (ratio 0.054, expected 0.81) |
| `P3b.restitutionMechanism` | **FAIL** — bounce-back is 0.000 at every approach speed, for both circle–rect and circle–circle |
| `P3c.friction` | **FAIL** — `friction = 0` and `friction = 1` leave exactly the same speed (8.0000) |
| `P4`–`P12`, `S1`–`S4` | PASS — guards, mass ratio, shape pairs, constraint convergence, broad-phase invariance, determinism, chain stability, driven-pendulum amplitude, transform cache, hierarchy ops, frustum culling, the physics↔node bridge |

`P3b` pins the cause down: give a ball an exact-contact approach and it stops dead; pre-overlap it
by 5 and give it a 0.1 approach and it leaves at **5.000** — exactly the position correction, with
no trace of `e`. Collision response derives its velocity from the already-corrected position, so the
approach velocity is cancelled before the impulse is computed and the impulse is always discarded.
`restitution` and `friction` are therefore inert. Same code in v0.9.0 and in `main`.

`P12` is the check that stopped a false alarm: the chains looked violent at first, but a single
pendulum and a 22-link chain under the same uniform lateral force both swing within the physical
bound (194 and 210 against a limit of 210). The violence was the sketch's own wind sitting on the
chain's natural frequency (√(g/L) ≈ 1.66 rad/s), not a library fault. The wind was moved off
resonance instead.

## Notes for anyone reading the code

- **Gravity is −Y.** `Physics2D` has no notion of up and `syncFromPhysics` passes XY straight
  through, so matching 3D's Y-up is the caller's job. The physics doc's own example uses
  `setGravity(0, 980)` — the opposite sign.
- **The physics runs on a fixed 1/120 s sub-step**, never on `deltaTime`. Feeding real frame times
  to `Physics2D.step` makes the result depend on frame jitter (`P1`). Note that the library's own
  `SketchSubsystem` conformance does exactly that.
- **Damping is the sketch's own.** Verlet has none, and with `restitution` / `friction` inert there
  is nothing to absorb the wind's energy, so `Plane.applyDamping()` trims velocity each sub-step.
- **Constraint iterations are per scene** (chain 18, cloth 12, pit 8, swarm 4). The default of 4
  cannot propagate tension along a 22-link chain, which stretches and tangles.
- **There is no collision filtering.** Bodies joined by a constraint still collide, so chain link
  radii are kept below half the link spacing.
- `saveFrame(name)` always writes to `~/Desktop/`; an absolute path silently produces no file.

## Soak

30 minutes, release build, 180 samples at 10 s intervals (`tools/probe.sh soak 1800`):
RSS 73.2 MB → 74.1 MB (**+0.9 MB**), CPU 15.7 % → 16.8 %. No leak, no warnings, no NaN — and the
self-check returns the same 13/18 in release as in debug. Over that run `pit` created and destroyed
roughly 2800 bodies and nodes.

Verification record: [metaphor-sketches#10](https://github.com/shinyaoguri/metaphor-sketches/issues/10).
Upstream issues found here: [metaphor#755](https://github.com/shinyaoguri/metaphor/issues/755)
(restitution / friction inert), [metaphor#756](https://github.com/shinyaoguri/metaphor/issues/756)
(timestep jitter, velocity units), [metaphor#757](https://github.com/shinyaoguri/metaphor/issues/757)
(`saveFrame` path).
