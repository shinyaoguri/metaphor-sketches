# 0816-sounding

A depth chart being surveyed by sound.

The sketch synthesises its own score, analyses that sound back, and lets the band energies carve
a noise field. What you watch is a bathymetric map — depth bands in colour, contour lines on top —
redrawn every frame from a `GKNoise` field whose configuration is rewritten by the spectrum.
On every beat a sonar ping expands from the sounding point; every 24 seconds a survey line sweeps
across and the sea floor becomes a different sea floor.

*Sounding* is the old word for measuring depth with sound. The structure of the piece is the same
sentence: audio drives noise, noise is the terrain, the terrain is the picture.

This is the first sketch in this book to exercise **MetaphorAudio** and **MetaphorNoise** — both
were entirely unused across the previous seven sketches. There is no library bridge between them;
the coupling is written here, in the piece, which is the point.

![0816-sounding](https://i.gyazo.com/24d341ac288e9c4582698c7140afe843.png)

The survey line sweeping and the sonar pings (release build, 7 s, window capture):

![survey transition and sonar pings](https://i.gyazo.com/9e4eb40f6c6df08cde11bbb2769d0352.gif)

## Run

```bash
swift run                 # or: metaphor run
metaphor watch --viewer   # live viewer + hot reload
```

**Use a release build to watch it.** A debug build spends ~13 ms per frame in the marching-squares
pass alone and runs at 10–20 fps; `swift build -c release && .build/release/Sketch0816Sounding`
holds 60 fps.

Diagnostic modes:

```bash
tools/probe.sh check                  # deterministic self-check table, then exit
tools/probe.sh shots                  # four PNGs to ~/Desktop
tools/probe.sh frames 30              # numbered PNGs for a GIF, into .probe-out/frames
tools/probe.sh soak 1800              # 30 min unattended, RSS/CPU to CSV
tools/probe.sh trap grid              # reproduce the sampleGrid/sample mismatch (metaphor#785)
```

| Environment variable | Effect |
|---|---|
| `SOUNDING_MUTE=1` | Do not play audio. Analysis continues (see below). |
| `SOUNDING_MIC=1` | Drive the piece from the microphone instead of the built-in score. |
| `SOUNDING_TRACE=1` | Print bands, field config, contour count, and per-frame timings every 120 frames. |
| `SOUNDING_SHOTS=1` | Write one PNG every 6 s (four in total) to `~/Desktop`. |
| `SOUNDING_FRAMES=<dir>` | Record numbered PNGs to an absolute path. |
| `SOUNDING_TRAP=grid` | Print the raw tables behind `N8` / `N9`. |

## Notes for anyone reading the code

- **`SOUNDING_MUTE=1` does not go through `gain = 0`.** The `SoundFile` analysis tap sits on the
  main mixer, downstream of the player node, so silencing the player silences the analysis too and
  the picture freezes. Muted runs feed the synthesised PCM straight into an `AudioAnalyzer` with
  `injectSamples(_:)` instead, so a soak still exercises the whole visual path.
- **The piece drives its visuals from `bandEnergy(lowFreq:highFreq:)`, not `band(0/1/2)`.** The
  latter splits at fixed *bin* fractions (1/8 and 1/2 of `halfFFTSize`), so at 44.1 kHz "bass"
  reaches 2.7 kHz and the arpeggio lands in it (metaphor#782).
- **Never read the same field through both `sampleGrid` and `sample(x:y:)`.** They do not share a
  coordinate space, and `sample` ignores `origin` and `sampleScale` entirely (metaphor#785). This
  sketch reads `sampleGrid` only; the colours and the contours come from the same array, so the
  picture is self-consistent.
- **Order matters when driving noise from audio.** Writing `config` rebuilds the `GKNoise` source
  and silently discards `add` / `multiply` / `invert` / `applyTurbulence`. Turbulence is therefore
  applied *after* the config write, every frame. Because the rebuild is total, nothing accumulates.
- **Depth is contrast-stretched before it is drawn.** A normalised `GKNoise` field can span a very
  narrow range depending on `frequency`, and with fixed contour levels the map came out with zero
  lines. `Field.stretch()` remaps the observed min/max, smoothed over time so the map does not flicker.
- **`saveFrame(_:)` prepends `~/Desktop/` unconditionally**, so an absolute path is silently
  dropped (metaphor#757). `beginFrameRecord(directory:)` honours absolute paths — that is why the
  two recording modes take different kinds of argument.

## The sketch checks itself

`Instrument.swift` runs a deterministic suite at startup — no rendering, no clock, the same numbers
every run — and publishes every verdict to `frame.json` under `check.<ID>`, plus
`summary.passed` / `summary.failed`. Results also print to stdout at launch, so a soak log carries them.

**Measured on metaphor v0.9.0: 25 / 30 PASS.** Two consecutive runs produce byte-identical output.
The five failures are library behaviour, not sketch behaviour; each is reduced to a single number.

| Check | Result |
|---|---|
| `A3.bandEnergyWithoutSampleRate` | **FAIL** — with `sampleRate` unset, `bandEnergy` returns `0.00000` while `spectrum` is alive; a misconfiguration is indistinguishable from silence (metaphor#783) |
| `A4.bandBoundaries` | **FAIL** — measured coverage is band0 = 60–2715 Hz, band1 = 3047–10861 Hz, band2 = 12191–19352 Hz; the doc says 0–250 / 250–2k / 2k+ (metaphor#782) |
| `A5.volumeScale` | **FAIL** — an A = 0.2 sine reads `volume = 0.5645` against an RMS of `0.1411` (ratio 4.000); saturates at 1.0 from A ≈ 0.354 (metaphor#782) |
| `N8.originScope` | **FAIL** — `sample(0.37, 0.61)` returns `0.55775` with and without `origin = (5.37, 5.61)`; `sampleGrid` honours the origin (metaphor#785) |
| `N9.gridMatchesSample` | **FAIL** — over a full 64-point row, `grid[i]` and `sample(origin + i × sampleScale)` differ by up to `0.26009`; `grid[0]` matches exactly (metaphor#785) |
| `A1`, `A2`, `A6`–`A13` | PASS — peak bin, band selectivity, smoothing clamp, spectrum normalisation, waveform padding, beat determinism, silence safety, `SoundFile` ranges, analysis toggle, missing-file error |
| `N1`–`N7`, `N10`–`N15` | PASS — constant value, normalised range, seed reproducibility, transforms, composition commutativity, frequency/period, octave detail, Float/Double parity, standalone `noise()`, Voronoi flag, texture consistency, turbulence, config-resets-composition |
| `X2`, `X3` | PASS — octave-change discontinuity stays under 0.025; NaN/∞ from the audio side never reach the noise config |

Startup also prints one measurement that is deliberately *not* a verdict, because it uses a clock:

```
MEASURE  X1 sampleGrid(160×90) [release]: 設定を変えない 0.068 ms / 毎回変える 1.549 ms（23 倍）
MEASURE  X1 sampleGrid(160×90) [debug]:   設定を変えない 1.664 ms / 毎回変える 3.144 ms（2 倍）
```

The line carries its build configuration because the two differ by an order of magnitude —
`tools/probe.sh check` builds debug, so its number is not the number the piece runs at.

`GKNoiseWrapper` caches its `GKNoiseMap`, and the `config` setter throws that cache away. Driving
noise from audio means paying for a fresh map every frame. In the live loop (release, 160×90,
6 contour levels) the whole field update costs ~4.7 ms, of which ~4.5 ms is `sampleGrid`; the
contour extraction is ~0.2 ms and the config rewrite itself ~0.01 ms.

## Soak

30 minutes unattended, release build, `SOUNDING_MUTE=1` (analysis still running, so the whole
visual path is exercised), 180 samples at 10 s intervals:

| Window | RSS (mean) | CPU (mean) |
|---|---|---|
| 5–10 min | 184.6 MB | 67.4 % |
| 10–15 min | 192.3 MB | 77.6 % |
| 15–20 min | 194.7 MB | 70.5 % |
| 20–25 min | 200.3 MB | 70.3 % |
| 25–30 min | 199.6 MB | 75.2 % |

**Not a leak.** RSS climbs from ~170 MB to a plateau just under 200 MB and stops: the fitted
slope falls from **+45 MB/h** measured from minute 5, to **+33 MB/h** from minute 10, to
**−12 MB/h** over the last ten minutes. Warm-up, not unbounded growth. Frame rate held and the
sketch was still drawing when the run was cut at 1793 s.

The naive first-half/second-half comparison reports +15.8 MB and looks like a leak; it is an
artefact of averaging the warm-up into the first half. Fit the tail before concluding.

## What this verifies

Verification notes live in
[metaphor-sketches#11](https://github.com/shinyaoguri/metaphor-sketches/issues/11), API by API.
Upstream issues found from this sketch: metaphor#782, #783, #785, #786.
