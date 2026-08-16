# 0816-escapement Brief

Template: `2d`

## Intent

- **Feel:** a skeleton wristwatch movement seen through its own dial. Dark plate, brass and
  steel, one ruby accent. Precise rather than decorative.
- **First noticed:** it is a clock, and it tells the right time. Then that the escape wheel
  jumps once a second while the balance wheel swings smoothly — discrete against continuous.
- **Over time:** the seconds tick, the balance oscillates, and one segment of the outer band
  lights up per second, walking around the ring once every 30 seconds.

The subject is the escapement itself: the part that turns continuous power into exactly timed
discrete steps, which is what a frame loop does. Every visible part is built from metaphor's
most basic APIs, and the sketch checks those APIs against closed-form maths while it runs.

## Constraints

- 1280×720, 60 fps.
- No assets. Everything is drawn from primitives; the plate's grain is seeded `random()` so the
  picture is identical on every launch.
- Interaction: mouse drag and scroll wind the crown; `SPACE` / `ENTER` / `TAB` / arrows / `ESC`
  drive loop control, plates and winding. Also drivable from stdin via `InputInjectionPlugin`.
- The self-check must not delay startup noticeably and must be deterministic.

## Visual Direction

- Palette: plate `#0A0D12`, edge `#161C26`, brass `#C9A227`, steel `#8FA3B0`, ruby `#C0392B`,
  ink `#E8E4D9`.
- Motion: the second hand jumps (no sweep). The balance is a sine. The anchor is a square wave.
- Shapes: dial with 60 ticks and 12 numerals, escape wheel, anchor with two pallets, balance
  wheel, mainspring spiral, and an outer band whose 30 segments are the 30 easing curves.
- References: skeleton watch movements, regulator dials, oscilloscope plates.

## Iteration Notes

- **Keep:** the dial has to stay readable as a clock. If it stops reading as a clock, the
  verification loses the visual channel that caught composition problems in the first place.
- **Improve:** the anchor is small enough to read as debris near the centre; a larger pallet
  fork with a visible impulse would sell the mechanism better.
- **Avoid:** filling the screen with the verdict table. That is 0816-adversary's job — here the
  check lives behind the dial and only failures surface, in the top-right corner.

## Current Task Prompt

(none — the work is recorded in metaphor-sketches#12)
