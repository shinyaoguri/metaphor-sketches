# 0816-atelier

An atelier. A plaster still life measured by the sketch itself.

Sphere, cube, cylinder, cone and ring sit on a table under a lamp that swings
overhead while the camera circles. The sketch then plays the drawing instructor:
it computes — **without calling metaphor** — where each silhouette should land,
how bright each surface should be, and where each shadow tip should fall, then
reads its own pixels back and marks every disagreement in red.

The four things an instructor corrects first — form, value, depth, shadow — are
the four families of checks. A fifth (hand) compares shapes built by hand with
the built-in primitives.

Verification record: [metaphor-sketches#17](https://github.com/shinyaoguri/metaphor-sketches/issues/17)

## Run

```bash
swift run                 # plain SwiftPM run
metaphor watch --viewer   # live-reload window
```

## The five scenes

Each scene is two halves: **採寸** (specimens measured one at a time, deterministic)
and **素描** (the whole still life, animated). One cycle is 75 s.

| # | Scene | What it exercises |
|---|---|---|
| 1 | 形 Form | `sphere` `box` `cylinder` `cone` `torus` `plane`, `detail:`, `translate`/`rotate`/`scale`, `push`/`pop` |
| 2 | 明暗 Value | `noLights` `lights` `ambientLight` `directionalLight` `pointLight` `spotLight` `specular` `shininess` `emissive` `ambientOcclusion` |
| 3 | 奥行き Depth | `perspective` `ortho` `camera` `screenX/Y/Z` `screenPosition` `currentViewProjection` `currentCameraRight/Up`, depth test |
| 4 | 影 Shadow | `enableShadows` `disableShadows` `shadowBias`, shadow-map resolution |
| 5 | 手 Hand | `beginShape3D` `vertex` `normal`, `create*Mesh` + `mesh`, `clearMeshCache`, `material`/`noMaterial`, `texture`, `applyMatrix` |

## Self-checks

100 checks, deterministic: two consecutive runs produce byte-identical output.

```bash
tools/probe.sh check        # measure all five scenes, print the table, quit
tools/probe.sh watch        # same but with the still life in between
tools/probe.sh stage <1-5>  # pin one scene
tools/probe.sh shots        # one PNG per scene to ~/Desktop
tools/probe.sh frames DIR   # numbered PNGs for building a GIF
tools/probe.sh trap NAME    # degenerate inputs — only on request
tools/probe.sh soak 180     # unattended run; RSS/CPU to CSV, first half vs second half
```

Soaked for 1800 s (180 samples, 24 cycles): RSS 84.3 → 86.3 MB, flat from ~750 s on
(87.5 / 86.1 / 86.4 MB over the last three 5-cycle windows), CPU 4.9 % → 3.2 %.
No leak signature. The 180 s run reported +11.3 MB, which turns out to be warm-up
being counted — recomputed without the first 60 s it is +0.5 MB.

Results appear in three places: stdout, the 講評 panel on screen, and `frame.json`'s
`custom` as `check.<ID>`.

## Notes for anyone reading the code

**The world's +Y points down the screen.** `Canvas3D.computeViewProjection` multiplies
by a Y-flip to match Processing's 2D convention, so "up" is `-Y` everywhere in this
sketch. The table is at a *large* y; the lamp is at a small one.

**At z = 0, one world unit is exactly one pixel.** The default camera is reset every
frame to `eye = (w/2, h/2, defaultZ)` with `defaultZ = (h/2) / tan(fov/2) = 623.54`
for a 720-tall canvas. The foreshortening at depth z is exactly
`defaultZ / (defaultZ − z)`. Every geometric expectation in `Optics.swift` rests on this.

**`Optics.swift` and `Analytic.swift` never call metaphor.** They re-derive lookAt,
the projection matrices, the Y-flip and the Blinn-Phong formula from the published
sources. Comparing metaphor against metaphor would pass whenever both are wrong
by the same amount.

**Gray overloads are not all on the same ruler.** `fill(_ gray:)` and
`ambientLight(_ strength:)` follow `colorMode` (0–255); `specular(_ gray:)` and
`emissive(_ gray:)` in v0.9.0 take the raw value, so `specular(120)` means 120×, not
120/255 ([#527](https://github.com/shinyaoguri/metaphor/issues/527), fixed on main).
This sketch passes 0…1 to those two.

**`loadPixels()` cannot read the same frame while shadows are enabled** — metaphor
warns and returns the last committed frame. The measuring phase therefore turns
shadows off outside scene 4; otherwise the previous frame's overlay would land inside
the silhouettes being measured.

**Shapes are inscribed, so measurements are bounded, not exact.** A `detail`-segment
primitive lands between `ideal × cos(π/detail)` and `ideal`. `expectInscribed` checks
that band instead of pretending to know the tessellation.

## What the checks found (metaphor 0.9.0)

| | |
|---|---|
| new | [#824](https://github.com/shinyaoguri/metaphor/issues/824) `screenX/Y/Z` flip behind the camera and cannot be told apart from valid values |
| new | [#825](https://github.com/shinyaoguri/metaphor/issues/825) `beginShape3D` shapes get `fill` applied twice; vertex colors get multiplied by `fill` |
| new | [#826](https://github.com/shinyaoguri/metaphor/issues/826) `material()` does not reach `beginShape3D` shapes |
| known | [#777](https://github.com/shinyaoguri/metaphor/issues/777) `ortho()` defaults throw the subject into the corner — measured at exactly half a screen |
| known | [#774](https://github.com/shinyaoguri/metaphor/issues/774) the default `lights()` shines from below |
| fixed on main | [#717](https://github.com/shinyaoguri/metaphor/issues/717) fragment-only custom materials draw nothing on the instanced path |
| fixed on main | [#527](https://github.com/shinyaoguri/metaphor/issues/527) `specular`/`emissive` gray overloads ignore `colorMode` |

The remaining 92 checks are 81 that matched the hand-solved value and 11 marked
**要確認** — observations that resist a true/false verdict (the cone's default
orientation, the unusable default `pointLight` falloff, shadow acne at bias 0,
the missing accessor for the `Canvas3D` mesh cache, and so on). Their numbers are
in the verification record.
