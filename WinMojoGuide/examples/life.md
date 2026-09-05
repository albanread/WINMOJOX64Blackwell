# life — Conway's Life, a timer, and a window that owns its state

Game of Life on a 180×120 torus, 6-pixel cells in a resizable window,
coloured by age: white-hot newborn, cooling through cyan and green to deep
blue, with fading embers where colonies died. Space pauses, `.` single-
steps, dragging draws, shift/right-drag erases, `r` reseeds, `c` clears,
`[` `]` change speed; the title bar carries live population and speed
stats.

## Run it

```
mojo run main.mojo
```

`--selftest` steps a glider, a blinker and a block headlessly and counts
the rendered pixels back through a DIB section — expected count
`(live + embers) × 25`, exact.

## The walkthrough

**One file, one `Life` struct, no allocation after startup.** `main`
(main.mojo:961) declares DPI awareness, allocates the three grid buffers
and a heap `Life` (`unsafe_alloc`, published to the window through
`GWLP_USERDATA` — a window procedure is captureless and cannot reach
`main`'s locals), builds the window from `std.windows.gui`, and starts a
16 ms `SetTimer`. The message loop is a plain blocking `run()`: a program
whose work happens in `WM_TIMER` can afford to sleep in `GetMessageW`,
which costs zero CPU when nothing is happening.

**The frame is two swaps.** `advance` (main.mojo:171) is an ordinary CPU
neighbour-count over the torus — no GPU, none needed — and the grids swap
by exchanging addresses (main.mojo:215), never by copying. `render`
(main.mojo:284) writes only each cell's 5×5 interior into a pre-guttered
BGRA buffer; `cell_color` (main.mojo:254) walks the age ramp. `WM_PAINT`
blits through `present_bgra` (`StretchDIBits`).

**Every Win32 constant is queried, none transcribed.** The window class,
structures and blit come from `std.windows.gui`; the remaining constants
come from `winkb_constant`/`winkb_struct_size`. The one language lesson
repeated throughout: `life_wndproc` (main.mojo:570) is a C-ABI function
Windows calls, so it never raises — everything is caught, state arrives
through `GWLP_USERDATA`, and the `lParam` mouse coordinates are *signed*
16-bit halves (`signed16`, main.mojo:556) or a drag past the left edge
reads as 65,000-odd.

## The trap, from the README

The title-bar refresh originally sat inside the "something changed" branch:
pressing Space stopped the simulation and left the title reading
`running` — indistinguishable from a key that did nothing. Status that
describes state belongs outside the branch that changes it.
