# 0816-galley

A galley proof for metaphor's text metrics.

A justified typesetting engine written **using nothing but metaphor's public
measuring API** — `textWidth()` for word widths, `textAscent() + textDescent()`
for line height. It never touches the drawing side's internal quantities.

If the measurements are true, the right edge of each column is a straight line.
If the ruler used for *measuring* differs from the ruler used for *drawing*, the
edge frays. The sketch then reads its own page back with `loadPixels()` and marks
every disagreement in red, with the number of pixels involved.

Verification record: [metaphor-sketches#15](https://github.com/shinyaoguri/metaphor-sketches/issues/15)

## Run

```bash
swift run                 # plain SwiftPM run
metaphor watch --viewer   # live-reload window
```

Keys: `1`–`5` pick a page · `space` pause · `r` re-judge the current page.

## The five pages

| # | Page | What it exercises |
|---|---|---|
| 1 | 段組 Columns | `textWidth()` distributes word spaces; both columns are balanced and justified |
| 2 | 見出し Display | `textAlign(.center)` for headings |
| 3 | 格子 Grid | `textAscent() + textDescent()` as the line box; all four `TextAlignV` cases |
| 4 | 号数見本 Specimen | the same word at eight sizes in all three `TextAlignH` alignments |
| 5 | 端物 Oddments | degenerate input — empty, whitespace-only, padded, `\n`, overhanging glyphs |

## Self-checks

Deterministic. Two consecutive runs produce byte-identical output.

```bash
tools/probe.sh check        # run the checks and print the table, then quit
tools/probe.sh shots        # write one PNG per page to ~/Desktop
tools/probe.sh sweep        # textSize sweep as CSV (no drawing involved)
tools/probe.sh frames DIR   # numbered PNGs for building a GIF
tools/probe.sh trap NAME    # zero | negative | huge | atlas — only on request
tools/probe.sh soak 1800    # unattended run; RSS/CPU to CSV, first half vs second half
```

Results appear in three places: stdout, the page margin (校正欄), and `frame.json`'s
`custom` as `check.<ID>`.

- **G1–G7** (`Instrument.swift`) — pure measurement. No drawing, no clock.
- **P1–P10** (`Pages.swift`) — read the printed page back and compare against
  expectations derived from the *documented* meaning of each API.

### Measured on metaphor 0.9.0, Helvetica

| Check | Result |
|---|---|
| `G1.width-additivity` | **FAIL** — `textWidth("T")+textWidth("o")` = 21.0 but `textWidth("To")` = 18.0 (3px) |
| `G2.width-space-trim` | **FAIL** — `textWidth(" ")` = 0.0; `textWidth("A ")` = `textWidth("A")` = 12.0 but `textWidth(" A")` = 16.0 |
| `G6.monospace-advance` | **FAIL** — Menlo 17px: `×1`=11.0 `×2`=21.0 `×4`=41.0 `×8`=82.0 `×16`=164.0 → per glyph 11.00, 10.50, 10.25, 10.25, 10.25 |
| `G3` `G4` `G5` | OK — empty string is 0; width and ascent/descent are linear in `textSize` |
| `G7.bogus-font` | LOOK — an unknown family name falls back to the default metrics without failing |
| `P1.ruler-mismatch` | OK within 2px — but the gap is a **constant 2.0px at every size** from 11 to 105 |
| `P9.justify-residual` | OK — 48 justified lines, worst right-edge residual 2.0px, RMS 1.2px |
| `P2.drift-accumulates` | OK — r=0.04 against word count, so the residual is rounding noise, not accumulation |
| `P3` `P4` `P5` `P6` `P7` `P8` | OK — alignment, line box, and size continuity all hold |

## Notes for anyone reading the code

**`fill()` does not colour text on 0.9.0.** `drawTextFromAtlas` writes `tintColor`
into the glyph vertices, not `fillColor`, so with no tint set the glyphs come out
white ([metaphor#516](https://github.com/shinyaoguri/metaphor/issues/516) — fixed
on main by `693d8ed` on 2026-08-12, but v0.9.0 was cut on 2026-08-10). `textColor()`
in `App.swift` sets both `fill()` and `tint()` to work around it. Remove the `tint()`
half once this sketch moves past 0.9.0.

**Print order is load-bearing.** Paper → ink → `loadPixels()` → rules → red marks →
margin. The blue rules and the red marks would otherwise be counted as ink by
`PixelReader` and corrupt every judgement.

**`Compositor` measures a word space as `measure("n n") - measure("nn")`,** not as
`measure(" ")` — because `G2` shows the latter returns 0. The difference method
works regardless of what the implementation does with whitespace.

**Two judgement bugs were found in this sketch's own checks and fixed** — worth
knowing about, because both produced confident-looking wrong numbers:

- the column-1 band was 90px wider than the column, so it reached into column 2 and
  reported a 60px right-edge residual. The give-away was that the "measured" value
  sat exactly on the band edge. The band is now narrower than the 44px gutter.
- the line-box band spanned 2.4 line heights and picked up neighbouring lines. It is
  now clamped to halfway to the next baseline.

**`saveFrame(_:)` prefixes `~/Desktop/` unconditionally** on 0.9.0
([metaphor#757](https://github.com/shinyaoguri/metaphor/issues/757)), so numbered
output goes through `beginFrameRecord(directory:)`, which honours absolute paths.
`probe.sh` also waits a few seconds before killing the process, because the write is
deferred to the end of the frame and the last page's PNG was otherwise lost.

## Why there is no separate probe sketch

The findings here are numeric only — they need no drawing, no input, and no
long run — so per the repository's `sketch-verification` skill they stay in this
sketch's own `Instrument.swift` rather than being split into a
`2026/0816-probe-*` package. That also makes this sketch the regression harness:
when the upstream fix ships, `tools/probe.sh check` re-verifies it by ID.
