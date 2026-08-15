# PROJECT_BRIEF — 0816-marionette

## Intent

A 2D Verlet physics world acts as the strings; a 3D scene graph is the puppet.

Each scene solves its physics on a flat plane (XY), then hangs that whole plane in 3D space
as a scene-graph node. The parent node carries the plane's pose and turns slowly; the children
are driven, frame by frame, by the bodies of the physics world. What you see is a suspended
structure — what moves it is an integrator running on a plane you never see.

The piece is also an instrument. `Instrument.swift` runs a deterministic self-check suite at
startup (no rendering, no clock) and publishes every verdict to `frame.json`, so an agent can
judge the run from numbers rather than from a screenshot.

## Scenes

| Scene | What it shows | API weight |
|---|---|---|
| `chain` | Three chains with heavy bobs, each on its own physics world, each plane turning | `pin` / `addConstraint` / `stiffness` / `worldTransform` composition |
| `cloth` | A 22×15 lattice pinned along its top edge, rippling in a slow wind | constraint count, broad-phase load, `applyForce` |
| `pit` | Circles and rectangles falling into a walled pit, swapped out as they settle | shape-pair collisions, `bounds`, `removeBody` at runtime |
| `swarm` | 240 cells drifting across a wide field while the camera sweeps | `AABB` / `worldBounds` / `intersects(frustum:)` / `extractFrustumPlanes` |

## Expected behaviour

- Chains hang straight down at rest and sway without ever swinging past horizontal.
- The cloth keeps its lattice: no link stretches far past its rest length, no self-intersection blowup.
- Objects in the pit come to rest in a pile and stay inside the walls.
- In `swarm`, the drawn-node count rises and falls as the camera sweeps; nothing visible is culled.
- The self-check verdict count is stable across runs — the same numbers every time.

## Coordinate convention

Gravity is **−Y**. `Physics2D` has no built-in notion of up, and `Node.syncFromPhysics` passes XY
straight through, so matching the 3D Y-up convention is the caller's job. The physics doc's own
example uses `setGravity(0, 980)` (screen-style, Y-down); this sketch deliberately uses the
opposite sign so that falling reads as falling in 3D.

## Non-goals

- No audio, video, Syphon, or post-processing. Those belong to other sketches.
- Not a game: nothing to win, no interaction beyond scene selection and parameter tuning.
