# 0816-probe-windowclose

A one-purpose repro sketch cut out of [`0816-triptych`](../0816-triptych/):
**closing a secondary window and then opening another one crashes the process.**

It creates a single secondary window with `createWindow` and does nothing else —
no drawing into it, no input, no physics. If it still crashes, the parent sketch's
context is irrelevant and the fault is in metaphor.

Reported upstream as
[metaphor#835](https://github.com/shinyaoguri/metaphor/issues/835).
Kept in the repository so the fix can be re-checked with the same sketch.

## Run

```bash
PROBE_MODE=reopen swift run   # → Segmentation fault: 11
```

The verdict is the exit code: `0` means it ran to the end, `139` (SIGSEGV) means it crashed.

| `PROBE_MODE` | What it does | Result (repeated runs) |
|---|---|---|
| `keep` | opens a window and never closes it | exit 0 ×3 |
| `close` (default) | closes it at frame 120, runs 3 more seconds | exit 0 ×5 |
| `closelong` | closes it at frame 120, runs 18 more seconds | exit 0 ×3 |
| `openclose` | closes it in the **same runloop turn** it was opened | **SIGSEGV ×3** |
| `burst` | opens 4, then `closeAllWindows()` in the same turn | **SIGSEGV ×3** |
| `cycle` | open-then-close, three times, in the same turn | **SIGSEGV ×3** |
| `reopen` | closes at frame 120, **reopens** at frame 180 | **SIGSEGV ×3** |
| `openclose-fixed` | same as `openclose` + `isReleasedWhenClosed = false` | **exit 0 ×3** |
| `reopen-fixed` | same as `reopen` + `isReleasedWhenClosed = false` | **exit 0 ×3** |

The only difference between the last two rows and the rows above them is one AppKit
property, and it flips the outcome 3/3 either way.

## Cause

`SketchWindow.setupWindow()` leaves `NSWindow.isReleasedWhenClosed` at its default `true`.
Under ARC that is a double release: AppKit releases the window on `close()`, and
`handleWindowClose()` releases it again via `window = nil`. It does not fault immediately —
it faults when AppKit next drains a pool holding window-related objects, which is why
"close, then open another window" is the shape that shows it.

## Reading the code

`Sources/Sketch0816ProbeWindowclose/App.swift` is the whole sketch. `NSApplicationWindows`
at the bottom exists only because metaphor does not expose the `NSWindow` behind a
`SketchWindow`, so the `*-fixed` modes have to find it by title.
