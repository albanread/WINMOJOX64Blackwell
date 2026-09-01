# ferns

A landscape of Barnsley ferns, growing live in a Win32 window. A dozen plants,
each an iterated function system played as the chaos game, a few hundred points
per fern per frame, so the landscape assembles in front of you: stems first,
then fronds, then the fine leaf texture as points pile up. Farther ferns are
smaller, dimmer and bluer. They grow out of a procedural lawn of fourteen
thousand individual grass blades, under a dusk sky whose clouds are two octaves
of value noise. When everything is grown it holds for about five seconds, then
a new landscape seeds itself, sky and lawn and all.

```
  click    plant a fern where you clicked -- lower on screen means closer,
           so it comes up bigger
  space    pause the growing (the title bar says so)
  r        clear the ground and reseed
  q / esc  quit, as does closing the window
```

This is the port of the MojoCocoa `ferns` example, which puts the same buffer
on screen through a `CAMetalLayer`.

## What it demonstrates

**A picture the CPU has already finished needs none of Direct3D.** The other
window examples here reach the screen through a swap chain: `d3djulia` compiles
HLSL at runtime, `nvidia_mandelbrot` uploads a texture and draws a fullscreen
triangle. Both are the right answer when the GPU is doing the work. Here the
GPU is doing none of it -- every pixel is arithmetic in Mojo -- and the whole
presentation layer is one top-down DIB and one `StretchDIBits` inside
`WM_PAINT`. No device, no swap chain, no device loss, no `D2DERR_RECREATE_TARGET`,
and nothing to rebind every frame. The whole of it is one function, `blit`,
and it is what a Cocoa `NSBitmapImageRep` blit becomes on Windows.

**Input on Windows' schedule, pixels on ours.** The window procedure is a
captureless C-ABI function -- Windows calls it, so it captures nothing and must
never raise. Its handlers do not touch the landscape; they raise bits in a
`Scene` struct reached through `GWLP_USERDATA`, and the frame loop, which owns
the buffer, lowers them again. Bits rather than a single value, so a click and a
keypress arriving in the same frame do not lose each other. It is the same
split the Cocoa version uses, with `GWLP_USERDATA` standing in for
`named_global`.

**Nothing Windows-shaped is written by hand.** Which DLL exports each entry
point, every constant, and the size of every structure comes from
`windows_api.db`. `PAINTSTRUCT` is never declared at all -- only sized, and used
as an opaque 72-byte box. The four structures that *are* declared assert their
own size against the metadata with `comptime assert`, so a layout that drifts
from Windows fails the build rather than the picture.

## What to look for

The order things appear in is the point. A fern's spine and stem show up within
a dozen frames; the big fronds fill in over a second or two; the fine
serrations at the frond tips take the rest of the ten seconds. That is the
chaos game's own convergence, visible, because the framebuffer *is* the
accumulator -- the `Fern` struct carries only the current point, not the picture.

Watch the depth cues. Ferns standing higher on the ground band are farther away,
so they are smaller, dimmer and shifted toward blue; the grass they stand in is
shorter and duller too. Nothing computes a perspective transform. A single
depth parameter `t`, taken from how far below the horizon the base sits, drives
size, brightness and hue at once, which is most of why the picture reads as a
landscape rather than as a row of fractals.

Click low in the window and a large, bright fern sprouts immediately where you
clicked. Click near the horizon and you get a small dim one. Twenty-four is the
ceiling; after that a click replaces the oldest.

## How the pixels get shaded

Each chaos-game hit moves the pixel **a quarter of the way** to the fern's own
colour rather than adding to it:

```mojo
var db = b - ob
var step_b = db // 4
if step_b == 0 and db != 0:
    step_b = 1 if db > 0 else -1
```

Density does the shading for free -- a wisp brushed once stays mostly backdrop, a
spine hit hundreds of times converges to the full shade and stops there. The
first version of this in the Cocoa example used saturating increments and dense
regions blew out to white. Converging can overshoot nothing, and it occludes
correctly whether the pixel underneath was dark sky or a bright grass tip.

## Two things worth stealing

**The lattice column is the same for every scanline.** Value noise sampled per
pixel is two bilinear interpolations per sky pixel, and the sky is 360,000
pixels. But every row samples the lattice at the same 1,024 horizontal
positions, so the cell index and the smoothstepped fraction can be computed once
into two arrays and reused for all 352 rows. The inner loop is then four array
reads and six multiplies. That is the difference between a reseed you notice and
a reseed you do not:

```
  backdrop, mojo build --no-optimization    214 ms
  backdrop, mojo run (JIT, optimized)         6 ms
```

Both are under the five seconds Windows waits before declaring a thread hung,
which is the number that actually matters -- a window that stops pumping gains
"(Not Responding)" in its title bar and DWM starts drawing a ghost of it. The
unoptimized 214 ms is still a visible hitch at each reseed; it is the price of
the build line this repository uses, and it goes away under `mojo run`.

**HALFTONE, but only when the sizes differ.** The window is resizable and the
buffer is not, so `StretchDIBits` scales. GDI's default stretch drops whole rows
and columns, and a fern reduced that way loses fronds to the decimation and
grows coloured speckle. `SetStretchBltMode(hdc, STRETCH_HALFTONE)` averages
instead. It is slower, so it is set only when the destination is not the
buffer's own size -- at 1:1 there is nothing to average.

## Traps this example stood on

- **`fn` is a reserved word.** `var fn = ...` for a noise value is a compile
  error reading `'fn' has been removed; use 'def' instead`, which is not what is
  wrong with the line.
- **A struct passed by value into `unsafe_write` needs `ImplicitlyCopyable`**,
  not just `Copyable`, or every call site wants a `^` or a `.copy()`.
- **The window procedure gets the ferns through a pointer, not a list.** The
  ferns live in one `alloc[Fern](MAX_FERNS)` block so the growth loop can mutate
  them in place: `list[i].field = x` mutates a copy in this dialect.
- **The runtime posts its own thread-level `WM_TIMER`s**, with a null `hwnd`.
  The frame loop checks `msg.hwnd == hwnd and msg.wParam == TICK_ID` before
  treating a tick as its own. Without that check a landscape reseeds and then
  the window shuts within a second, which looks exactly like "the window does
  not stay up" and is nothing of the kind.
- **`SetProcessDPIAware` before the first window**, or on this 144-DPI display
  Windows hands back a 682x426 client for a 1024x640 request and upscales the
  result to blur.
- **`WM_ERASEBKGND` returns 1.** The client area is fully redrawn every frame;
  letting GDI clear it first is what makes it flicker.
- **`AdjustWindowRectEx`, not a guess.** `nvidia_mandelbrot` adds a hard-coded
  `+16, +39` for the `WS_OVERLAPPEDWINDOW` frame at 100% scaling. Asking
  Windows costs one call and is right at every scaling.

## Unattended

`FERNS_FRAMES=N` grows for N frames, copies the window's own client area back
out through a DIB section and prints nine samples down the middle, then exits.
That is proof the pixels reached the window rather than proof the calls returned
without complaining -- sky colours at the top, earth and lawn at the bottom, and
nine distinct colours in nine samples. `FERNS_DUMP=path` writes the final frame
as raw BGRA, 1024 x 640 x 4 bytes, for a reviewer who was not at the screen.

The landscape is deterministic: one xorshift64\* seeded at `0x5EED` drives the
sky, the lawn, the fern placement and the chaos game, so the same landscape
grows on every run and a harness can assert something about the picture.

## Run it

Run it from the IDE with Build > Run Without Debugging, or from a terminal:

```
mojo run main.mojo
```
