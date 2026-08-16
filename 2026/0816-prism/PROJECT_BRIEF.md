# 0816-prism Brief

Template: `2d`

## Intent

- **Feel:** an optics bench in a dark room. One beam, one piece of glass, one screen. Nothing
  decorative — the only bright things are the light itself and where it lands.
- **First noticed:** white light goes into the prism and a rainbow comes out, landing as a band
  on the screen at the right.
- **Over time:** the prism turns slowly, the fan sweeps across the screen, and at shallow angles
  the violet end starts dropping out — total internal reflection eating the short wavelengths
  first. Then the scene changes and the same spectrum is folded back into a single white spot.

The subject is that light is separable and re-addable, and that both directions have to agree.
Splitting is a hue sweep; recombining is additive blending. **If metaphor's colour handling were
wrong, the focus would not come back white** — so the artwork is the assertion.

## Constraints

- 1280×720, 60 fps.
- Four scenes on a 9-second tour: dispersion → recombination → palette → aberration.
- Dispersion must stay physically ordered: violet bends most, red least, and the loss at shallow
  angles must come from the actual total-internal-reflection condition, not from a fudge.
- The visual spread may be exaggerated (it has to be — the real difference is 1.6°), but the
  exaggeration has to be stated on screen and only applied to the *difference* between rays.
- Runs unattended: with no mouse input the prism and the aberration strength swing by themselves.
- The self-check must never stop the artwork from starting. Calls that can kill the process live
  behind `PRISM_TRAP` and only run when asked.

## Verification role

This sketch covers the colour surface of metaphor, which no earlier sketch had measured:

- `Color` construction and conversion — HSB, hex, gray, interpolation, constants
- Colour modes — the 0…255 / 0…1 / HSB scales, and whether a `Color` value is affected by them
- All ten `BlendMode` cases, in RGB **and** alpha
- `linearGradient` across all three `GradientAxis` values, and `radialGradient`
- `tint` / `noTint`, alpha compositing, style-stack save and restore
- The colour post effects, and where they do and do not appear

The measurement itself is the interesting part: colour cannot be judged until it is a pixel, so
the sketch draws to an offscreen buffer and reads it back rather than trusting the values it
passed in. See the README for what that caught.
