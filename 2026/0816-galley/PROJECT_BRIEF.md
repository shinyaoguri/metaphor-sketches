# 0816-galley Brief

Template: `2d` · metaphor 0.9.0

## Intent

A galley proof — the sheet a printer pulls *before* committing a page, so that
every misfit can be marked in red while marking is still cheap.

The viewer should first read a page of properly set type: two balanced columns,
justified, on a warm paper ground. Only then should they notice the pale blue
rules, and then the red marks in the margin. The order matters — this is a page
of text that turns out to be an instrument, not an instrument dressed as a page.

Over time each sheet performs the whole act of proofreading: **組む → 読み戻す →
朱を入れる** (set the type, read the page back, mark it up). Five sheets cycle.

The wager: a justified column depends *entirely* on measurement. The compositor
here is given only `textWidth()`, `textAscent()` and `textDescent()` and no eyes.
If those answers are true the right edge is a straight line; if the measuring
ruler and the drawing ruler differ, the edge frays. **The fraying is the finding.**

## Constraints

- Target resolution: 1280 × 800, fixed. It is a sheet of paper, not a viewport.
- Performance: 60fps. `loadPixels()` is called **once per page**, never per element.
- Inputs: keyboard only — `1`–`5` choose a page, `space` pauses, `r` re-judges.
- Assets: none. The type is the only material.
- Determinism: no clock, no randomness in anything a check reads. Two runs must
  produce identical numbers, or the checks are worthless as evidence.

## Visual Direction

- Palette: paper `(236,231,221)`, sumi `(26,24,22)`, vermilion `(190,44,36)`,
  non-repro blue `(126,152,186)`. Four colours, each with a job:
  paper and sumi are what gets printed and read back; blue and red are what the
  proofreader adds afterwards and are never counted as ink.
- Motion: type sets progressively, then the rules snap on, then the marks draw
  themselves toward the place they are pointing at. Nothing loops or pulses.
- Motifs: corner registration marks, a wide right margin for corrections, a
  footer that carries the running totals.
- References: letterpress galley proofs; standard proofreading marks; type
  specimen sheets.

## Iteration Notes

- **Keep:** the compositor may only see the public measuring API. The moment it
  reads an advance width from the renderer, the whole page stops being evidence.
- **Keep:** ink is printed before the readback, rules and marks strictly after.
- **Improve:** the fraying is only ~1–2px at 17pt body size, so the headline
  effect is quantitative rather than visible. A display-size justified page would
  show it to the naked eye.
- **Avoid:** turning this into another grid of test cells. 0816-adversary already
  is one. This one has to survive being read as a page.

## Current Task Prompt

—
