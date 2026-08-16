# 0816-encore — a shadow theatre made only of scheduled motion

A `Tween` does not move anything. It *books* a movement: start here, end there, take this long,
wait this much first, repeat this many times. A stage works the same way — every entrance, every
gesture, every curtain is decided before the house opens. So the stage is the subject.

**Nothing in this sketch computes a position per frame.** Every moving thing is a `Tween`.

Two troupes play the same piece side by side. Same choreography, same frame loop, one difference:

|  | 座組 甲 "left as booked" | 座組 乙 "called back" |
|---|---|---|
| opening night | `add` → `start()` | `add` → `start()` |
| encore | `reset()` → `start()` | **`add()` again**, then `reset()` → `start()` |

They are indistinguishable on the first performance. Call an encore and only one troupe comes out.

Verification record: [metaphor-sketches#18](https://github.com/shinyaoguri/metaphor-sketches/issues/18).
Pinned to **metaphor 0.9.0** (`Package.resolved`).

![Opening night — both troupes have all three actors on stage](https://i.gyazo.com/a06e58a0e60a1e6807dbbc83e8840bb3.png)

![The encore — the left stage stays empty and every value in its cue sheet reads 0.000](https://i.gyazo.com/9ce83c33d4e344808175e24455d62ee0.png)

![The encore, 9.8 s: the curtain rises on both stages but only the right one fills](https://i.gyazo.com/64f796b68bbc648417a6dc0d2913ee84.gif)

## Run

```bash
swift build
tools/probe.sh check      # 38 verdicts (T / M / I series)
tools/probe.sh twice      # run check twice; the deterministic 35 must be byte-identical
tools/probe.sh trace 40   # cue sheet to stdout for two performances
swift run                 # the theatre itself
```

| key | |
|---|---|
| `SPACE` | call an encore (both troupes at once) |

One performance is **17.2 s**; an encore is called automatically when it ends.

| env | |
|---|---|
| `ENCORE_TRACE=1` | print the cue sheet and `tweenManager.count` once a second |
| `ENCORE_SHOTS=1` | write one PNG each at act 1, the bow, and the encore |
| `ENCORE_FRAMES=<dir>` | write numbered PNGs for a GIF (absolute paths are honoured) |
| `ENCORE_ENCORES=<n>` | stop after n performances (used by the soak) |

## What it found

`Tween` / `TweenManager` / `Interpolatable` were essentially untouched by the other 14 sketches
in this book — `tween()` had been used once, for a single fade. The state machine on top of the
easing curves had never been exercised at all.

Two structural holes, both **confirmed against v0.9.0 and still present on upstream `main`**
(reported as [metaphor#838](https://github.com/shinyaoguri/metaphor/issues/838)):

### A completed tween cannot be replayed

`TweenManager.update` removes tweens whose `isComplete` is true. Call `start()` afterwards and
nobody updates it again — and `Tween.update(_:)` is `internal`, so you cannot step it yourself.

```
FAIL M5.restartAfterComplete  1 公演目の最終値 100.0000 / 完了で count=0。
  その後 start() して 200 刻み → 値 0.0000 期待=100.0000。
  isActive=true のまま from に凍る（除去済みで誰も update しない）
```

Worse than "it does not move": `start()` writes `value = fromValue` first, so the value **snaps
back to the start and freezes there** while `isActive` keeps reporting `true`. On stage, the
actors reappear in the wings and stand still. That is the left-hand panel of the GIF.

### An unstarted tween is retained forever

`tween()` is `@discardableResult` and registers the tween **without starting it**. Only
`isComplete` tweens are removed, and `.idle` never becomes complete — so if you drop the return
value you can no longer `cancel()` it either.

```
FAIL M3.unstartedNeverRemoved  未 start の Tween を 600 本登録 → 600 刻み後も count=600
PASS M9.tweenDoesNotAutoStart  tween() したまま start() しない 1 本: isActive=false isComplete=false 値 0.0000
```

### Smaller things worth knowing before you use this API

The documentation gaps below are [metaphor#840](https://github.com/shinyaoguri/metaphor/issues/840).

| | measured |
|---|---|
| `yoyo()` without `repeatCount` | no-op. One cycle means nothing to reverse — finishes at `to` in 64 steps, not 128 |
| `delay` with `repeatCount(3)` | applies to the **first cycle only** (14 steps of 0.25 s, not 18). Not documented either way |
| adding the same tween twice | runs at **double speed**, not the same speed |
| `clear()` | unregisters, but leaves the tweens `isActive == true`; they simply stop |
| `clear()` inside `onComplete` | the other tweens still advance one more step that frame (`update` iterates a copy) |
| `update(NaN)` once | poisons the tween permanently — `elapsed` is NaN, so completion is never true and it is never removed ([metaphor#839](https://github.com/shinyaoguri/metaphor/issues/839)) |
| `update(-0.75)` | extrapolates below `from` (measured 50.0 → −25.0) ([metaphor#839](https://github.com/shinyaoguri/metaphor/issues/839)) |
| completion timing | always **one frame late** (61 steps at 60 fps, 241 at 240 fps) — but it does **not** accumulate over repeats (601 steps for 10 cycles, not 610) |

### A tween waiting on its delay looks exactly like one that was never started

Only `isActive` (`state == .running`) and `isComplete` are public. The `.delaying` state reports
`false` for both, same as `.idle`:

```
FAIL T2b.delayingLooksIdle  delay 待ち (isActive,isComplete)=(false, false) / 未 start=(false, false)
```

This is why the cue sheet can only print `—` for both. It is also why the broken troupe's rows
read `—` rather than `RUN` — from the outside, the frozen actors are indistinguishable from
actors who were never cued.

## Soak

```bash
tools/probe.sh soak 180     # start here
tools/probe.sh soak 1800    # only if the short run looks suspicious
```

The short run looked suspicious, so it was extended:

| | 180 s / 18 samples / 10 performances | 1800 s / 180 samples / 110 performances |
|---|---|---|
| RSS | 72.8 → 86.6 MB (**+13.8**) | 85.4 → 87.2 MB (**+1.8**) |
| CPU | 6.6 → 4.4 % | 5.2 → 4.1 % |
| registered tweens | 8.1 → 8.7 | 9.9 → **9.0** (min 0, max 47) |

The +13.8 MB in the short run was warm-up, not a leak: RSS reaches ~87 MB by t≈300 s and is flat
for the remaining 25 minutes. Registered tweens do not accumulate — the average *falls* over the
run, and the count returns to 0 every performance.

**The soak did surface something the deterministic checks could only predict.** In 4 of 111
performances the count spiked (35, 34, 47, 54 against a steady-state 23) for under a second right
after an encore. That is `add()` being called while the previous performance's tweens were still
registered — the encore fires on `elapsed >= 17.2` and the curtain finishes at 16.8, so a frame
hitch is enough to overlap them. A double-registered tween runs at **double speed** (`M4`), which
is why `TweenManager.add` rejecting duplicates is part of the upstream proposal. The trace samples
once a second, so 4 is a lower bound.

## Notes for anyone reading the code

- **`tweenManager` is not reachable from `Sketch`.** It lives on `SketchContext`, so you have to
  write `context.tweenManager` — unlike `width`, `frameCount`, `deltaTime` and friends. That one
  extra hop is also why the retention above is hard for a sketch author to notice or clean up.
- **`Tween.update(_:)` is `internal`**, so the checks in `Instrument.swift` drive tweens through
  their own `TweenManager()` instances. Never mix the checks into the default `tweenManager` —
  `SketchContext.beginFrame` already calls `update` on it every frame, and you would get a
  double step.
- **metaphor has no `linear` easing.** `EasingFunction` is just `(Float) -> Float`, so the checks
  use `{ $0 }`; that is what makes the expected values hand-computable.
- The checks step by **powers of two** (`1/64`) so that `elapsed` accumulates exactly. `1/60`
  drifts, which is the subject of `T12` rather than a property the other checks should inherit.
- `easeOutBack` is used for the entrances on purpose: it overshoots past `1`, so the actors
  overshoot their marks and settle. The same overshoot is what `I6` measures (109.9997 against a
  target of 100).
- `saveFrame(_:)` prefixes `~/Desktop/` unconditionally
  ([metaphor#757](https://github.com/shinyaoguri/metaphor/issues/757)); `tools/probe.sh shots`
  collects the files from there. `beginFrameRecord(directory:)` honours absolute paths.
- **No crashing call was found in this API surface.** Unlike `2026/0816-marionette`, which needed
  a `TRAP` hatch for `step(dt, iterations: -1)`, every degenerate argument here is either clamped
  (`duration: 0` → `0.001`, `repeatCount(-1)` → infinite) or merely poisons the value (`NaN`).
  So there is no `trap` subcommand.
