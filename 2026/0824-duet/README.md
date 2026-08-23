# 0824-duet

**A duet.** One swirl, two players. The left hand is a Swift loop on the CPU; the right hand
is an MSL compute kernel on the GPU. Same score (`Score.swift` ⇄ `Kernels.swift`), same opening
positions, same fixed step — the right hand only mirrors the stage when it draws. So **when
both play it right, the picture is symmetric**, and the seam down the middle stays dark.
When they drift apart, the seam lights up by decade and the symmetry breaks in front of you.

Before the curtain there is 調弦 (tuning): the instrument hits every part of metaphor's GPU
compute surface once and leaves the verdicts on screen. **A red FAIL sitting on that board is
part of the piece.**

Verification record: [metaphor-sketches#26](https://github.com/shinyaoguri/metaphor-sketches/issues/26).

## Why a duet

GPU compute is where a creative-coding library breaks quietly: threadgroup remainders,
buffer lifetimes, memory layout across the language boundary, and "when is the result
actually there". None of it throws. It just draws the wrong thing, or nothing.

The trick that makes it measurable is that **the expected value is solvable on the CPU**.
The same integrator runs on both sides, so any disagreement is a number, not an impression.

| Movement | What it aims at |
|---|---|
| 斉唱 unison | one kernel, fixed `dt`. The gap should be float rounding only |
| 端数 odd bars | voice count walks 63 / 64 / 65 / 255 / 1023 / 1025 — a dropped tail eats the rim of the cloud |
| 輪唱 canon | the two-pass chain runs with `computeBarrier()` on and off, every 2 s |
| 写譜 copy | the right hand is drawn straight from the `GPUBuffer`, then via `toArray()`, alternating |

## The checks

`Instrument.swift` runs once, deterministically, and writes every verdict to `probe("check.<ID>", …)`
and to stdout. Values, not booleans — the numbers are the evidence.

```bash
tools/probe.sh check      # 起動 → 検査が出そろうまで待つ → 結果だけ出す
```

Measured on this machine (Apple GPU, `threadExecutionWidth` 32, metaphor 0.13.0):

| ID | Verdict | The number |
|---|---|---|
| G1.parity | PASS | 1 step / 1024 voices: position 1.49e-08, velocity 2.99e-08 |
| G2.parityLong | PASS | 240 steps chained: position 1.19e-06, velocity 1.51e-06, seeds 1024/1024 |
| G3.tail | PASS | threads 1/7/63/64/65/255/1023/1025 — nothing unwritten, no sentinel touched |
| G5.dispatch2D | PASS | 1D `threads=2048` and 2D `64×32` write the same index (row-major) |
| G6.barrier | PASS | barrier on: 0 mismatches. barrier **off: also 0** — see below |
| G7.readback | PASS | reading right after `dispatch` gives the old value; next frame gives 12345 |
| G7b.loadPixelsSync | PASS | `loadPixels()` in the same frame makes it readable — the only sync there is |
| G8.bufferAlloc | PASS | `count: 0` → nil, `count: 2^34` → nil |
| G9.copyFromLen | PASS | clamped to `min(data.count, count)` both ways; the untouched tail survives |
| G10.layout | PASS | `CircleInstance` stride 32, position@0 diameter@8 color@16 |
| G11.circlesCount | PASS | 省略→5, 3→3, 99→5, 0→0, -5→0 (counted off the pixels) |
| G12.compileError | PASS | broken MSL throws, and the message names the identifier |
| G13.kernelBuild | LOOK | 5 kernels in 0.2 ms — paid again on every hot reload |
| G14.dispatchOutsideFrame | LOOK | `dispatch` from `setup()` does nothing, **and says nothing** |

Each check was verified by breaking the thing it watches (wrong damping, a kernel that stops
at gid 60, column-major indexing, a poisoned chain, a different fill value) and confirming it
turns red. G1 was rewritten during that pass: one step of a 0.995 → 0.994 damping change moves
the *position* by only 7.2e-06, under the original threshold — **velocity is where the score
change lands first**, so G1 now watches both.

## Notes for whoever reads the code

- **`dispatch` only works inside `compute()`.** Outside it there is no command buffer, and
  `ensureComputeEncoder()` returns nil without a word. `threads: 0` warns; this does not.
- **There is no public way to wait for compute.** `toArray()` right after `dispatch` hands
  back the pre-dispatch contents. The kernel writes its own step number into a status buffer
  here, and the readback is matched against the CPU snapshot of *that* step — comparing
  "probably one frame behind" would report the lag as a disagreement.
- **`computeBarrier()` is not what keeps the chain honest.** metaphor makes the encoder with
  the default (serial) dispatch type, so dispatches in one encoder are already ordered. The
  barrier-off run stays correct at 65536 elements; that is the encoder, not luck.
- **`CircleInstance`'s field order is not in the public docs.** `llms.txt` lists members
  alphabetically (color / diameter / position); memory is position → diameter → padding →
  color. Write the MSL struct in doc order and it still compiles — the right hand simply goes
  silent. See the picture in [#26](https://github.com/shinyaoguri/metaphor-sketches/issues/26).
- **Out-of-range kernel writes land in someone else's buffer.** `tools/probe.sh trap oob`
  dispatches 96 threads at a 64-element buffer; the process survives and *another* buffer's
  contents change (G11 starts reporting 1 circle where it should report 5). Nothing warns.

## Running it

```bash
swift run                          # 巡回（調弦 8s → 4 楽章 × 12s）
tools/probe.sh check               # 検査だけ
tools/probe.sh run canon           # 楽章を固定して起動
tools/probe.sh trace 30            # 食い違いの推移を追う
tools/probe.sh frames out/ 8       # 連番 PNG（GIF / WebP の材料）
tools/probe.sh trap oob            # 落ちうる口（oob / alloc / index）
tools/probe.sh soak 180            # release で無人稼働し RSS / CPU の傾向を見る
```

| Env | What it does |
|---|---|
| `DUET_N` | voice count (1…4096, default 4096) |
| `DUET_MOVEMENT` | pin one movement (`tuning` / `unison` / `oddBars` / `canon` / `copy`) |
| `DUET_SHOTS=1` | one still per movement, 3 s in (`saveFrame` always prefixes `~/Desktop/`) |
| `DUET_FRAMES=<dir>` | numbered PNGs via `beginFrameRecord` (absolute paths are honoured) |
| `DUET_TRACE=1` | print the divergence every 60 frames |
| `DUET_TRAP=<name>` | run one of the crashing paths on purpose (`oob` / `alloc` / `index`) |

The traps are behind an env var on purpose: `alloc` and `index` kill the process, and a check
that kills the process at startup means there is no piece left to look at.
