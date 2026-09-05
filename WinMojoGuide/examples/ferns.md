# ferns — the chaos game, painted patiently by the CPU

A landscape of Barnsley ferns grown by the chaos game on the **CPU**, into
one 1024×640 BGRA buffer — 14,000 grass blades and a value-noise dusk sky
painted around them. The scene holds about five seconds, then reseeds
itself into new hills. Click to plant; space pauses; `r` reseeds; `q`/Esc
quits. `FERNS_FRAMES=N` runs unattended and exits; `FERNS_DUMP=PATH` saves
the frame.

## Run it

```
mojo run main.mojo
```

or `./examples/win32/build.sh ferns`.

## The walkthrough

**The renderer is a framebuffer and nothing else.** `plot` (main.mojo:450)
is the whole graphics technique: each chaos-game point lands in the buffer
with converge-to-colour shading, so the *density* of visits draws the fern
— the framebuffer is the accumulator, and structure emerges from iteration
counts rather than from geometry. No GPU, no D3D; the whole sample is
iteration plus a blit.

**The window is the plain Win32 shape, with `WM_TIMER` as the frame
clock.** `main` (main.mojo:835) asserts its structures against the
metadata, declares DPI awareness, builds the window from
`std.windows.gui`, publishes a heap `Scene` through `GWLP_USERDATA`, paints
the backdrop, and starts the timer; the `GetMessageW` loop lowers command
flag bits on each tick (main.mojo:998), grows the next cohort of ferns, and
calls `InvalidateRect`. Pixels reach the screen only in `WM_PAINT` →
`StretchDIBits`.

**The DIB is top-down because the height is negative** (main.mojo:533) —
the comment there is the trap worth carrying: *a positive height means
bottom-up and the picture arrives upside down*. `STRETCH_HALFTONE` keeps
the scale-down from aliasing the fronds away.

## What it teaches

The smallest complete windowed program in the tree that still produces
something you want to look at: `std.windows.gui`, one buffer, a timer, a
captureless window procedure — and an algorithm where the picture is the
statistics.
