# 0816-gamut Brief

Template: `2d`

## Intent

- Two tables, side by side, holding the **same three primaries** and the **same knob**.
  Left: light on darkness, climbing to white. Right: pigment on paper, falling to black.
- The viewer should first notice that the two tables are mirror images of one another —
  the classic Venn diagram of additive and subtractive mixing.
- Then they turn α down, and only one of them obeys. The piece is built so that a defect
  in the library becomes something you can watch, not just something a test reports.

## Constraints

- 1280×720, 60 fps.
- Interaction: keyboard (view, blend mode, α, rotation) and vertical drag (circle spread).
- No assets. The primaries come from `Color(hue:saturation:brightness:)`; the light table's
  falloff comes from `radialGradient`.
- The self-check must stay deterministic — no wall clock, no drawing into the piece's own
  canvas. It composites offscreen and reads back.

## Visual Direction

- Palette: pure RGB on near-black `gray(0.04)`; pure CMY on near-white `gray(0.96)`.
- Motion: a slow rotation of the three circles (0.0035 rad/frame), plus α when swept.
- Light is drawn as a `radialGradient` halo **plus a solid core** — the halo alone never
  reaches full strength anywhere except its own centre, so three overlapping halos stop at
  grey instead of white.

## Iteration Notes

- Keep: the shared α knob driving both tables. That coupling is the whole argument.
- Keep: measured RGB in the bottom strip. The piece asserts something numeric, so it should
  show the numbers.
- Improve: the two-colour sample points are placed at 1.8× the placement radius so they
  land outside the three-colour region. That constant is geometry-dependent; if the circle
  spread or diameter changes, re-derive it.
- Avoid: making the light table's core so large that the piece stops looking like light.

## Current Task Prompt

（次に手を入れるときの指示をここへ）
