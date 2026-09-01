# life

Conway's Game of Life in a real Win32 window, from Mojo -- a CPU simulation
whose pixels reach the glass through `StretchDIBits`, with the mouse and the
keyboard wired up.

A port of the Cocoa `life` example. What that one does, this one does: pause
and single-step, draw cells with the mouse, colour by age, clear, randomise,
speed control, live statistics in the title bar.

```
main.exe                     interactive
main.exe --selftest          check three known patterns, then open the window,
                             read its own pixels back, and close
main.exe --selftest --ms N   as above, holding the window open N milliseconds
```

Run it from the IDE with Build > Run Without Debugging, or from a terminal:

```
mojo run main.mojo
```

## The controls

| | |
|---|---|
| `space` | pause / resume |
| `.` | one generation (the reason pause is worth having) |
| drag | draw cells |
| shift-drag, or right-drag | erase |
| `r` | randomise |
| `c` | clear |
| `[` `]` | slower / faster |
| `Esc` | quit |

## What to look for

**The colour is the point.** A flat green mask tells you which cells are
alive; this tells you what has been happening. A newborn burns white, cools
through cyan to green over its first twenty generations, and a long survivor
settles into deep violet. A cell that dies leaves an ember that fades over
twenty-five generations.

So the picture separates into things that read at a glance: the churning
regions are white-speckled and dragging brown wakes behind them, the still
lifes and blinkers left over in the cleared space sit quiet and violet, and a
glider is a bright head with a warm tail. Pause and single-step through a
collision and you can watch which cells are new.

**The grid is a torus.** Neighbours wrap, so a glider that sails off the right
edge comes back in on the left.

**Draw into a running simulation.** Nothing is paused while you draw. Scribble
a bar into open space and watch it collapse; hold shift and cut a channel
through a dense region.

## How it works

The simulation is ordinary. Everything interesting is in how the pixels and
the events get where they are going.

### Pixels: `StretchDIBits`, and nothing else

There are four ways to put a picture in a window in this tree -- a D3D11
texture and a fullscreen triangle (`nvidia_mandelbrot`), an HLSL pixel shader
(`d3djulia`), a Direct2D bitmap (`ide/chrome.mojo`), and this. For a buffer
the CPU computed, this is the shortest honest path: one call, no swap chain,
no D3D device, no COM, and nothing that can be lost and need recreating.

```mojo
_ = StretchDIBits(
    hdc,
    c_int(0), c_int(0), c_int(dest_w), c_int(dest_h),
    c_int(0), c_int(0), c_int(WIN_W), c_int(WIN_H),
    Pointer[UInt32, MutAnyOrigin](unsafe_from_address=life[].frame),
    com_addr(bmi),
    UInt32(winkb_constant["DIB_RGB_COLORS"]()),
    UInt32(winkb_constant["SRCCOPY"]()),
)
```

Two details that are wrong by default. `biHeight` is **negative**: that asks
GDI for a top-down DIB, where row 0 is the top row, which is the order
everybody computes pixels in -- positive means bottom-up and the picture
arrives upside down. And the buffer is stretched to the *client rectangle*
rather than blitted 1:1, so the window resizes; the mouse mapping goes through
the same rectangle, or drawing would land somewhere else the moment you
dragged a corner.

`WM_ERASEBKGND` returns 1. The client area is fully redrawn every paint, and
letting GDI clear it first is what makes a window flicker.

### DPI: declare it, or Windows blurs the lattice

This is the one thing the Cocoa version gets for free and Windows does not.
Without a declaration the process is told the screen is smaller than it is and
whatever it draws is bilinearly upscaled -- on a 150% display, a 1080x720
buffer becomes 1620x1080 physical pixels, which smears a lattice whose whole
point is a one-pixel gutter. So, before any window exists:

```mojo
SetProcessDpiAwarenessContext(
    winkb_constant["DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2"]()
)
```

Both the entry point and that context value come out of the metadata, so
there is no magic `-4` written down anywhere.

Then the client area has to be *exactly* 1080x720 or the blit is not 1:1.
`AdjustWindowRectEx` gets the frame size, but it answers for the system DPI
rather than this window's monitor's, and the frame also depends on the theme.
Rather than trust the arithmetic, the code measures what actually came out and
corrects it once with `SetWindowPos`. That is what lets the self-test below
demand an exact pixel count instead of a plausible one.

### State: a window procedure holds nothing

Windows calls the window procedure, so it is captureless -- there is no
closure and no `self`. Everything the simulation knows lives in one heap
struct whose address is parked in the window:

```mojo
_ = SetWindowLongPtrW(
    hwnd, c_int(winkb_constant["GWLP_USERDATA"]()), Int(store)
)
```

and is fetched back at the top of every message. The five buffers inside it
are `Int` addresses rather than pointers, because `Pointer` is non-nullable
and an address of zero cannot be spelled; they become pointers only where
they are used.

The two grids are swapped by swapping their addresses. Nothing is copied.

### Events

Mouse buttons and modifiers arrive already decoded in `wParam`, so left,
right and shift are three bit tests and no `GetKeyState`. The point in
`lParam` is two **signed** 16-bit halves -- read unsigned, a drag that leaves
the window to the left reports x = 65,000-odd. `SetCapture` on button down is
what lets a drag continue past the window frame instead of stopping at it.

Typed characters come from `WM_CHAR`, not `WM_KEYDOWN`: by then Windows has
applied the keyboard layout, so what arrives is the character the person
meant. That only happens if the message loop calls `TranslateMessage` -- omit
it and nothing typed ever shows up.

The clock is a `SetTimer` at 16 ms and the loop is a blocking `GetMessageW`,
so a paused simulation costs no CPU at all.

### One bug worth writing down

The title bar refresh started out *inside* the "something changed" branch,
which is the obvious place for it. It meant that pressing space stopped the
simulation and left the title reading `running` -- indistinguishable from a
key that did nothing. Statistics are not the picture and do not belong on the
picture's clock: the refresh now runs on its own slower one, plus a `retitle`
flag so a state change shows at once. This was found by driving the program
from outside and reading the title back, not by looking at it.

## Evidence

`--selftest` does two things, in the spirit of `nvidia_mandelbrot`'s "a
picture that looks right is not evidence".

**The rule is checked against three patterns whose behaviour is known
exactly.** A glider is the strongest cheap check there is, because it is
periodic in four generations *and* displaced by one cell diagonally: a wrong
neighbour count, a wrong wrap, or an off-by-one in the index all break it, and
the expected answer is exact rather than approximate. A blinker checks period
2, a block checks that a still life does not drift.

**The window's own pixels are copied back out and counted.** A DIB section, a
`BitBlt` from the window's device context, and a count of pixels that are not
the background colour. The prediction is exact -- every live cell and every
ember paints a 5x5 interior and nothing else in the window is anything else --
so the check is an equality, not a plausibility. An actual run, `--ms 5000`:

```
pattern checks:
  glider  period 4, displaced (1,1): ok
  blinker period 2: ok
  block   still after 8: ok
readback: client 1080 x 720   (buffer 1080 x 720 )
   live cells 2021  embers 7020
   lit pixels 226025  predicted 226025
   1:1, so those two should agree exactly
```

`(2021 + 7020) * 25 = 226025`. That is the simulation's own state agreeing,
pixel for pixel, with what a screen grab of the window contains -- which is a
stronger statement than any screenshot.

The self-test seeds the generator with 1, so those numbers repeat run to run.

## Performance

Built with `--no-optimization`, on one core: a generation plus a full render
of the 1080x720 buffer takes about **3 ms**, which the title bar reports live
as `step`. At the default speed that is around 20 generations a second with
the CPU essentially idle between them.

The render only writes the 5x5 interior of each cell. The last row and column
of every block are the gutter, they are always the background colour, and the
buffer is filled with that colour once at start-up -- so a third of the writes
the obvious version does are writes of a value that is already there.

## Differences from the Cocoa version

* Presentation is `StretchDIBits` into the window's device context rather than
  a `CAMetalLayer` drawable. Same BGRA buffer, same layout, no GPU involved on
  either side.
* The window resizes, and the image stretches to fit. The Cocoa one is fixed.
* DPI awareness has to be declared (see above); on macOS the backing store
  handles it.
* `--selftest` is new: the Cocoa version has no equivalent.
* One fix, not a simplification: the colour ramps run their parameter past the
  end of a channel at the extremes, which wraps rather than clamping, so a
  deep-violet survivor flashes an impossible green for one generation. Channels
  are clamped here.

Nothing was left out.

## No hand-declared Windows

There is not a DLL name, a message number, a virtual key, a window style, a
raster operation, a struct size, or a DPI context value written by hand in
`main.mojo`. All of it is a query against `windows_api.db`, which means an
unknown name is a compile error rather than a wrong number:

```mojo
wc.hCursor = LoadCursorW(0, winkb_constant["IDC_CROSS"]())
var ps = List[UInt8](length=winkb_struct_size["PAINTSTRUCT"](), fill=0)
```

`PAINTSTRUCT` is never declared, only sized -- it is a box this code never
looks inside. The four structs that *are* declared each carry a
`comptime assert` against `winkb_struct_size`, so a layout that does not match
Windows fails to build.
