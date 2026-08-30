# What a keystroke costs

Sprint 1.7, the budget run. The claim this editor is built around is that a
keystroke reaches the screen in one frame, and that the claim holds on a
document of any size. This is the measurement, what it covers, and — the part
that matters more — what it does not.

## The numbers

Optimized build, 60 Hz display, 500 keystrokes through the real `WM_CHAR`
path with a frame forced after each:

| document | work, mean | work, worst | of a 16.7 ms frame | frames missed |
| --- | --- | --- | --- | --- |
| 250,001 lines (14 MB) | 0.85 ms | 2.01 ms | 5.1% | 0 of 500 |
| 1,900,001 lines (104 MB) | 0.94 ms | 1.76 ms | 5.6% | 0 of 300 |

Debug build, which is what ships — sprint 0.0 wants the IDE debuggable, and
`-O2` inlines the frames a person wants to stand in:

| document | work, mean | work, worst | of a frame | frames missed |
| --- | --- | --- | --- | --- |
| 250,001 lines (14 MB) | 3.40 ms | 5.56 ms | 20.4% | 0 of 500 |

**The number does not track document size.** 0.85 ms on 14 MB and 0.94 ms on
104 MB, a document seven times larger. That is the whole thesis: the rope
makes the edit O(log n), the grid draws only the visible lines, and the layout
cache means a keystroke re-lays-out one of them. None of those costs are the
size of the file.

## What "work" means, exactly

From the `WM_CHAR` handler being entered to the last Direct2D drawing command
being issued. That is the whole of this application's response to a keystroke:
the edit, the caret arithmetic, the layout of the changed line, and every fill
and draw for the frame.

The clock starts on the first line of the handler, before any work, because
starting it after the response has begun would measure a shorter response.

## What is not measured, and why

Two hops, one at each end, and neither is visible from inside the process:

**Key press to `WM_CHAR`.** The keyboard's own scan interval, the driver, the
raw input thread, and the message queue. Milliseconds, and none of them this
application's.

**Present to photon.** Scanout and the panel's response. Also milliseconds,
also not ours.

Between them sits one more thing that *is* measured but is not work: the wait
at the vertical blank. `EndDraw` on a vsync-presenting render target blocks
until the frame is handed over, so a keystroke arriving at a random point
inside a refresh interval waits somewhere in [0, 16.7] ms for it. That wait is
real — a person experiences it — but no amount of work here shortens it.

So the reported total (keystroke to `EndDraw` returning) has a mean near one
full frame and a worst of 20.3 ms, and the useful test on it is not "under one
frame" — half the samples exceed that by construction — but **did any
keystroke miss the next blank and wait for the one after**. None did, in any
run.

## PresentMon, and why it was not used

The sprint named PresentMon, which reads input-to-photon out of ETW and would
close both missing hops. It is not installed on this machine, and downloading
and running an external binary is a decision for a person rather than
something a sprint should take on its own.

So the application half is measured precisely, the two hops are named, and the
number is not dressed up as more complete than it is. If someone installs
PresentMon, the storm to run under it is:

```bash
build/griddle-opt.exe --lines 250000 --ms 30000
```

then drive it from another shell with `tools/griddle-cmd.ps1 "storm 2000"` and
capture PresentMon over the same window. The in-process numbers above should
appear as the application's share of whatever PresentMon reports end to end;
if they do not, one of the two is wrong and that is worth knowing.

## Reproducing

```bash
build/griddle-opt.exe --lines 250000 --cmd "storm 500"
build/griddle-opt.exe --lines 250000 --no-vsync --cmd "storm 500"
```

The second removes the vertical-blank wait, so the total collapses to the work
plus the present call itself — 0.50 ms mean, 0.95 ms worst. That is the
closest thing to a pure keystroke-to-pixels number this process can produce,
and it is what the display would show if it refreshed the instant it was
asked.

`tools/check-ide.ps1` runs a shorter storm and fails if any frame is missed.
