# 0816-probe-windowclose Brief

Template: `2d`

**This is not a work. It is a repro.**

Cut out of [`0816-triptych`](../0816-triptych/) to answer one question:
when the process dies after closing a secondary window, is the fault in metaphor
or in how the parent sketch held on to things?

## Intent

- Do the smallest thing that can possibly reproduce it: one `createWindow`, no drawing
  into it, no input, no shared state. If it still dies, the parent's context is irrelevant.
- Change exactly one condition per run (`PROBE_MODE`), so the result is a table, not a story.
- Include the control that is supposed to *not* crash, and the one-line fix that is supposed
  to *stop* the crash. A repro without both is just an anecdote.

## What "done" looked like

`reopen` died 3/3 and `reopen-fixed` — same code plus `isReleasedWhenClosed = false` —
survived 3/3. That pair is the whole finding; everything else in the table is there to
close off the alternatives.

Filed as [metaphor#835](https://github.com/shinyaoguri/metaphor/issues/835).

## Do not delete this sketch

It stays so the fix can be re-checked with the same code, and so upstream has a runnable
repro rather than a description of one. See `verification/upstream.json` for how it is
re-run (`upstream-recheck` skill).
