# 0816-probe-frameloop Brief

Template: `2d`

## Intent

Not an artwork. This is the minimal reproduction carved out of
[`0816-escapement`](../0816-escapement/) for two frame-loop behaviours, kept in the repository so
that both the upstream issue and the future re-check have running code to point at.

The only visual is a cleared background — anything more would add noise to the measurement.
The output is text on stdout.

## Constraints

- 480×270, 60 fps. Two modes selected by `PROBE=resume` / `PROBE=pmouse`.
- No assets, no interaction beyond stdin event injection.
- Must stay small enough to paste into an upstream issue verbatim.

## Iteration Notes

- **Keep:** minimality. If a reader has to understand the sketch before understanding the
  measurement, the repro has failed.
- **Improve:** `PROBE=pmouse` still needs a fifo driven from the shell. A self-driving mode
  would make the re-check a single command.
- **Avoid:** deleting this once the upstream issues close. It is the regression board.

## Current Task Prompt

(none — see metaphor-sketches#12, metaphor#793, metaphor#522)
