# life-python — Mojo's compute, pygame's window

Conway's Life again — same rules as [life](life.md), different everything
else: the grid is Mojo, the window is **pygame/SDL**, and there is no Win32
anywhere in the file. The title bar carries a live split —
`mojo X ms  pygame Y ms` — so the cost of each side of the boundary is on
screen the whole time.

## Run it

The environment is per-project, and Griddle manages it: open the file in
Griddle and run Python → Create or Repair Environment, then Python →
Install Project Dependencies (`requirements.txt` is one line: `pygame-ce`).
From then on the IDE's Run works; a built exe needs the same variables set
(`MOJO_PYTHON`, `MOJO_PYTHON_LIBRARY`, `VIRTUAL_ENV`, ...), which is why
the README is blunt about it: Run works from inside the editor, and
`main.exe` on its own does not unless you set them yourself. The caught
failure prints `No module named 'pygame'` plus the two menu steps.

`--ms N` (auto-close), `--shot PATH`, `--size N`, `--selftest`.

## The walkthrough

**The embedding is literal.** `Python.import_module("pygame")`
(main.mojo:103) loads libpython *into the Mojo process*; every result is a
live `PyObject` handle; `Python.tuple(x, y, w, h)` converts Mojo values
for the calls; the loop (main.mojo:148) is SDL's — `pygame.event.get`,
`window.fill`, one `draw.rect` per live cell, `flip`, `time.sleep` —
because the event loop belongs to whoever owns the window, and here that
is SDL.

**The compute never crosses.** `Grid` (gridv1.mojo) is the manual's Life
grid with one annotation edit for this dialect; `grid.evolve()` is pure
Mojo over Mojo lists. The boundary sees integers for `draw.rect`, nothing
else — which is the design point: send *answers* across an FFI, not
structures.

## What it teaches

That `std.python` is an embedding, not a bridge: no socket, no subprocess,
one process, and a title bar that measures the interop instead of
asserting it is free. And that a Mojo program can choose its window system
per project — Win32 where the platform matters, pygame where the
ecosystem does.
