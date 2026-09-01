# life-python — Life, through Python

Conway's Game of Life again — but this window is **pygame's**, not Win32's.
The rule is Mojo (`gridv1.mojo`, the file Modular's manual ships); the window,
the event queue and every rectangle in it belong to pygame, reached through
`Python.import_module` and the CPython this toolchain carries.

```
main.exe                 interactive; close the window, or press q / Esc
main.exe --ms N          the same, closing itself after N milliseconds
main.exe --shot PATH     also write a PNG of the first frame drawn
main.exe --size N        an N x N grid instead of 128 x 128
main.exe --selftest      three known patterns, then an exact count of the
                         pixels pygame actually put on its surface
```

## First run

pygame is not part of the toolchain. It lives in this project's own Python
environment, and the project ships a `requirements.txt` naming it —
`pygame-ce`, the community build, because it publishes wheels for current
CPython. It installs as the same `pygame` module.

So, once:

1. Python menu → **Create or Repair Environment**
2. Python menu → **Install Project Dependencies**

Then Run. Close the window, or press `q` or `Esc`, to stop.

Both menu items are the `python create` and `python install` commands, so the
same thing without a mouse is:

```
griddle.exe --open examples/win32/life-python/main.mojo --no-lsp \
            --cmd "python create;;python install"
```

which on this machine answered

```
Python environment ready: C:\Users\alban\AppData\Local\Griddle\Python\Environments\03f496a42e9def84\py-3.13
Python packages installed
```

and put pygame-ce 2.5.8 (SDL 2.32.10) into a CPython 3.13.11 venv. Nothing is
installed into the checkout and nothing into the system Python;
`ide/python_env.mojo` keeps environments per project under `%LOCALAPPDATA%`,
keyed by a hash of the project path.

## Put it beside `life/`

That is the whole reason this example exists. `life/` owns its window, decodes
its own messages, and pushes a BGRA buffer through `StretchDIBits`. This one
does none of that and has no Windows in it at all. Same question, two worlds.

The native one is faster and it is not close. Everybody expects that. Almost
everybody guesses the wrong reason, so this version reports the split live in
its own title bar rather than asserting anything:

```
Life (Mojo + pygame) -- gen 85  alive 1390  mojo 19.0 ms  pygame 4.5 ms  8.0 gen/s
```

`mojo` is one `Grid.evolve` over 16,384 cells. `pygame` is one `fill`, one
`draw.rect` per live cell, and one `flip` — **plus** the scan of all 16,384
cells that decides which rectangles those are, because that scan is ours and
charging it to pygame would flatter us. The 0.1 s sleep upstream puts between
generations is in neither.

**The drawing is the cheap half.** Measured here, 128 × 128 cells, both built
with `--no-optimization`, means over a whole run:

| | per generation |
|---|---|
| `Grid.evolve`, 16,384 cells | **16.6 ms** |
| pygame: scan, fill, one `draw.rect` per live cell, flip | **4.5 ms** |

and, for scale, `life/` in the same session, on the same machine, at the same
flags: `step 3296 us` in its title bar — one generation **and** a full render
of a 1080 × 720 buffer, over 21,600 cells. Per cell that is 148 ns against
1,288 ns here, a factor of about nine.

So the honest reading is not "Python is slow". Two things are going on and
neither of them is the language boundary. `Grid` is a `List[List[Int]]` rebuilt
from scratch every generation and read through two levels of bounds-checked
indirection, where `life/` has a flat byte buffer indexed by arithmetic — and
`--no-optimization` means none of that folds away. Rebuild with the optimiser
on and it is a different program:

| | `--no-optimization` | optimised |
|---|---|---|
| mojo | 15.3 – 16.9 ms | 0.6 – 1.3 ms |
| pygame | 4.4 – 4.6 ms | 1.5 – 2.4 ms |

The Mojo half falls by about fourteen times, because all of it is code the
optimiser can see. The pygame half only halves — the part that moved is our
16,384-cell scan and the four multiplies per live cell; the rest is inside SDL
and CPython, where a Mojo compiler flag does not reach.

**Which means the numbers depend on which button you pressed.** Griddle's
Build passes `--no-optimization`; its Run does not:

```
mojo.exe build --no-optimization -I ... -o ...\main.exe ...\main.mojo
mojo.exe run                     -I ...                 ...\main.mojo
```

Same program, same machine, `mojo 16.6 ms` one way and `mojo 0.7 ms` the
other. Worth knowing before quoting a number off the glass.

## What to look for

**The lattice.** 128 columns across 600 pixels is 4.6875 pixels per cell, and
the one-pixel border comes off that, so each live cell is a 3.6875-pixel
rectangle — which SDL truncates to a 3 × 3 block of nine pixels, on origins
that are themselves fractional and rounded. The blocks therefore land on
slightly uneven centres and the grid shimmers as patterns move through it.
`--size 100` divides 600 exactly, 5 × 5 per cell, and the shimmer goes away;
`--size 64` is 9.375 pixels a cell and you can pick out individual gliders.

**The torus.** `gridv1.mojo` wraps with `%`, so a glider that sails off the
right edge comes back in on the left.

**The die-off.** A random start is about half alive — some 8,000 rectangles in
the first frame. It falls fast: about 2,200 by generation 40, 1,550 by
generation 100, and then a long slow decline through 1,100 at generation 300
to 900 at generation 500, by which point most of what is left is still lifes,
blinkers and the occasional glider. The `alive` count in the title bar tracks
it, and the frame gets cheaper as it falls — that is the `draw.rect` count
dropping, and it is why the pygame figure is a mean over a run rather than a
constant.

## Evidence

A window that looked right is not evidence, and neither is an import that did
not raise. `--selftest` does two things, in the spirit of `life/` and
`ferns/`.

**The rule is checked against three patterns whose behaviour is known
exactly.** These run against `gridv1.Grid` as shipped, which is the point: the
file the manual publishes is the file under test. A glider is the strongest
cheap check there is, because it is periodic in four generations *and*
displaced by one cell diagonally — a wrong neighbour count, a wrong wrap, or
an off-by-one in the index all break it, and the expected answer is exact.

**pygame's own surface is read back and the lit pixels counted.** `life/` does
this with `BitBlt` out of the window's device context; there is no device
context to blit here, because the surface belongs to SDL — but pygame will
answer the same question about itself. `pygame.mask.from_threshold` counts
matching pixels in C, so 409,600 of them do not have to cross the language
bridge one at a time.

The prediction is exact because the geometry is chosen to be exact: eight
cells across a 640-pixel window is 80.0 pixels per cell with nothing left
over, and a one-pixel border leaves a 79 × 79 block per live cell. An actual
run:

```
pattern checks:
  glider  period 4, displaced (1,1): ok
  blinker period 2: ok
  block   still after 8: ok
readback: window 640 x 640  cell 80.0 px
   live cells 5  lit pixels 31205  predicted 31205
   the geometry is exact, so those two must agree exactly
  pixel readback: ok
all checks passed
```

`5 × 79 × 79 = 31205`. That is the simulation's own state agreeing, pixel for
pixel, with what is on pygame's surface.

The event loop was checked from outside too: `WM_CLOSE` sent to the window
from PowerShell reaches SDL as a `QUIT` event, the loop ends, the summary
prints and the process exits 0 — which is upstream's event handling,
unmodified, doing what the close button does.

## Differences from the Mac version

* **`gridv1.mojo` needed exactly one edit**, and it is a type annotation. A
  bare list-of-lists literal infers `Array[Array[Int, 8], 8]` in this fork — a
  fixed-size stack thing — and `Grid.data` is a `List[List[Int]]`, which it
  will not convert to. `var glider: List[List[Int]] = [...]` is the whole fix.
  Nothing about the pattern or the rule changes. The rest of the file is byte
  for byte what the manual ships.
* **Discarded Python results are assigned to `_`.** `window.fill(...)` on its
  own is a warning here; `_ = window.fill(...)` is not. Cosmetic, and the same
  thing `bifurcation/` does.
* **A title bar that measures itself**, and the `--ms`, `--shot`, `--size` and
  `--selftest` doors. The Mac version has none of these. `--ms` and
  `--selftest` are what let an unattended run prove the window opened, drew
  the right pixels and closed cleanly, which is the standard the rest of
  `examples/win32` is held to.
* **No DPI declaration, deliberately.** `life/` must call
  `SetProcessDpiAwarenessContext` before it creates a window or Windows
  bilinearly upscales its lattice. Here the window is SDL's and the decision
  is SDL's: it leaves the process DPI-unaware, so on a scaled display Windows
  will stretch the picture. Declaring awareness behind SDL's back would tell
  Windows one thing and SDL another. Measured on this machine: system DPI 96,
  awareness 0, a 600 × 600 request arriving as a 600 × 600 surface — so it
  does not arise here, and it will on a 150% display.
* **`pygame-ce`, not `pygame`** — the same choice the Mac version made and for
  the same reason, carried over unchanged.

Nothing was left out. `run_display` is upstream's loop, comment for comment,
with additions around it.

## No hand-declared Windows

There is none to declare. This file imports `std.time`, `std.python`,
`std.sys.argv` and `gridv1`, and that is the entire dependency list — no
`winkb` query, no `win32[...]`, no COM, no struct sizes, because every window,
event and pixel in the program belongs to SDL. That is the example.

The one Windows-shaped fact in the folder is `requirements.txt`, and what
makes it work is `ide/python_env.mojo`: a Mojo program that calls Python loads
libpython *into itself*, so it must be told both which library to load and
whose `site-packages` that library should see. Neither is discoverable on
Windows. Griddle sets `MOJO_PYTHON`, `PYTHONEXECUTABLE`, `MOJO_PYTHON_LIBRARY`,
`VIRTUAL_ENV` and `PYTHONNOUSERSITE` before it starts anything, which is why
Run works from inside the editor and `main.exe` on its own does not unless you
set them yourself. Ask the editor what it would set with `python show`.

Run it without them and the failure is at least legible, because the one error
worth explaining is caught by name:

```
could not run: No module named 'pygame'

pygame lives in this project's Python environment:
  Python menu -> Create or Repair Environment
  Python menu -> Install Project Dependencies
```
