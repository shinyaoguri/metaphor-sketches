# PROJECT_BRIEF — 0816-sounding

## Intent

A depth chart that is being surveyed by sound.

The sketch plays a score it synthesises itself, analyses that sound back, and lets the band
energies carve a noise field. What you watch is a bathymetric map — depth bands in colour,
contour lines on top — redrawn every frame from a `GKNoise` field whose configuration is
being rewritten by the spectrum. On every beat a sonar ping expands from the sounding point,
and at intervals the seed changes and the sea floor becomes a different sea floor.

"Sounding" is the old word for measuring depth with sound. The structure of the piece is the
same sentence: audio drives noise, noise is the terrain, the terrain is the picture.

The piece is also an instrument. `Instrument.swift` runs a deterministic self-check suite at
startup — no rendering, no clock — and publishes every verdict to `frame.json`, so an agent can
judge a run from numbers instead of from a screenshot.

## Why these two modules

`MetaphorAudio` and `MetaphorNoise` were both entirely unused across the first seven sketches
in this book. They have no bridge API between them: the coupling is written here, in the piece.
That is the point — the interesting failures in this book have all come from *combinations*,
not from single calls, and "a real-time analysis value rewrites another module's configuration
every frame" is a combination nothing had exercised yet.

`AudioAnalyzer.injectSamples(_:)` together with `sampleRate` is what makes the audio side
checkable without a microphone: the expected spectrum of a synthesised wave can be written
down as a formula, so the verdicts are oracle-backed rather than eyeballed.

## Expected behaviour

- The contour map reads as a map: closed, non-crossing iso-lines over a depth-coloured field.
- Bass swells widen the features; highs roughen the edges; mids drift the whole field sideways.
- A ping is visible on each kick, and it is in time with what you hear.
- The terrain changes character on a seed change without the picture tearing or flashing.
- Silence is a valid state: no NaN, no flicker, the map simply stops moving.
- The self-check verdict count is stable across runs — the same numbers every time.

## Constraints

- 1280×720. Contours are drawn as one `beginShape(.lines)` batch, not thousands of `line()` calls.
- The sound source is the built-in score by default. `SOUNDING_MIC=1` switches to the microphone
  so the `AudioAnalyzer.start()` path gets exercised too; it is not the default because it needs
  a permission grant and makes runs non-deterministic.
- The score is synthesised at startup into a WAV under the system temp directory. Nothing audio
  is committed to the repository.
- `SOUNDING_MUTE=1` silences playback (`gain = 0`) while leaving analysis intact, for soaks.

## Visual Direction

- Palette: deep navy through teal to a pale shoal; contour lines a bone white, the ping cyan.
- Motion: slow. The terrain should look surveyed, not animated.
- Motifs: nautical chart, echo sounder trace, iso-lines.

## Non-goals

- No 3D, no physics, no Syphon. Those belong to other sketches.
- Not a spectrum analyser: the spectrum is the cause, never the picture.
