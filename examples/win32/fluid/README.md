# fluid

Stable Fluids (Jos Stam, SIGGRAPH 1999) as a native Windows app written
entirely in Mojo. Drag the mouse and coloured dye swirls through a velocity
field that is advected along itself and then made divergence-free by a Jacobi
pressure solve. Every kernel is a Mojo kernel compiled to PTX and run on the
NVIDIA GPU through the CUDA driver. There is no shader anywhere in the
pipeline: the last thing the GPU does is pack BGRA words, and GDI blits them
into the window.

```
[space] pause   [c] clear   [r] rain   [s] save a shot   [Esc] quit
```

## Why this one exists, beyond being nice to look at

`nvidia_mandelbrot` is **one dispatch per frame**, so it measures the kernel and
says nothing whatever about launch cost. A fluids frame here is **44 dependent
dispatches** -- advect the velocity along itself (2), take its divergence (1),
clear the pressure (1), thirty ping-ponged Jacobi sweeps (30), subtract the
gradient (1), copy the corrected field back (2), then carry three dye channels
on it (6) and shade (1). Each one has to finish before the next can start, so
per-dispatch overhead stops being a rounding error and becomes the term that
decides the frame rate.

Measured on the T1000, 320x240 grid, warm:

```
  fluid.exe        44 dispatches/frame    12.1 ms/frame     82 fps
  fluid_smoke.exe  39 dispatches/step      9.4 ms/step
```

The first run of a freshly built binary is much slower -- around 270 ms/step --
because the five kernels are compiled to PTX on first use. That is a one-time
cost per build, not per run, and it is why the numbers above say "warm".

## Run it

```
mojo run main.mojo
```

or, with the direct compiler invocation this tree uses:

```bash
export MODULAR_MOJO_MAX_WINKB_PATH="F:/bzs/external/+http_archive+winkb/windows_api.db"
mojo build --no-optimization -I mojo/stdlib -I . -I max/mojo \
    -Xlinker "$(cygpath -w bazel-bin/nvptx/runtime/nvptxrt.if.lib)" \
    -o build/fluid.exe examples/win32/fluid/main.mojo
```

The `-I .` matters here and does not for the single-file examples: this project
is four files, and `main.mojo` imports the other three by their repo-relative
package path (`examples.win32.fluid.solver`).

`nvptxrt.if.lib` is an import library: the program it links loads
`nvptxrt.dll` when it starts, the way it loads `KGENCompilerRTShared.dll`.
To run it, `bazel-bin/nvptx/runtime` has to be on `PATH` (or the DLL beside
the executable) -- Griddle does that for anything it runs, and an installed
release keeps the DLL in `lib` where every launcher already looks. The point
of a DLL is that a runtime fix reaches every program already built against
it without a relink.

## Run the smoke test first if it ever looks wrong

```bash
mojo build ... -o build/fluid_smoke.exe examples/win32/fluid/fluid_smoke.mojo
./build/fluid_smoke.exe
```

From a black window "the physics broke" and "the window broke" look exactly
alike. `fluid_smoke.mojo` opens no window at all: it steps the solver 60 times
and then asserts the four things a broken kernel would break.

## `fluid_bench.mojo` -- the headless measurement

`fluid_smoke.mojo` proves the physics; `fluid_bench.mojo` measures where the
time actually goes: the per-dispatch cost (a one-thread kernel, launched 2000
times), the same kernel as replayed graph nodes, whole frames enqueued the
classic way (synced per step, and once at the end) and as a recorded device
graph. Build it exactly like `fluid.exe` above, from `fluid_bench.mojo`, and
run it without a window. It carries two fixtures:

- a recording-semantics regression guard: `enqueue_memset` and
  `enqueue_copy` through a recording context once **executed immediately**
  instead of becoming graph nodes, whatever the docstring promised, until
  nvptxrt grew recording branches for them; the probe now proves they
  record, and will say so loudly if that ever regresses, and
- a staged frame graph (`FLUID_BENCH_STAGES`) that once reproduced an
  illegal-memory-access fault (CUDA 700) on replaying the clamped stencil
  kernels as device-graph nodes, and now stands as the regression fixture
  for the bug that actually caused it. The clamp was never the cause. The
  fault was a **use-after-free**: a recorded kernel node held only the raw
  device addresses of its argument buffers, while a recorded copy or memset
  retained theirs. Mojo destroys a value at its LAST USE, and as far as the
  source can see a buffer that is only ever handed to the graph is last used
  at the record -- so `u0` and `v0` were `cuMemFree`'d before the first
  replay, and every replay after that read freed memory. Whether that
  faulted depended on whether the driver had reclaimed the pages yet, which
  is exactly why it looked address-sensitive, why unrelated edits to the
  binary moved it in and out, why freshly allocated buffers "fixed" it, and
  why only the kernels touching the most freed pages -- the clamped stencil
  reads -- ever tripped it. The refcount log that settled it, in order:
  record captures `u0`/`v0`; a classic launch of the same kernel works;
  `cuMemFree(v0)`, `cuMemFree(u0)` -- refs to zero; synchronize; replay;
  fault. The fix, in `nvptx/runtime/nvptxrt.cpp`: owning device buffers are
  registered on their root context, and a kernel node looks each
  pointer-sized argument up by address range and retains the owner, so a
  graph owns what its kernels name for as long as it exists -- the rule the
  other node types already followed.
- a second recording-semantics probe guarding that rule without needing a
  fault: it records a one-node graph over a buffer that is never named
  again, allocates a same-sized buffer afterwards and fills it with 9, then
  replays and reads the new buffer back. `9` means the graph wrote its own,
  still-live buffer; `1` means the allocator handed the freed block to the
  new buffer and the replay wrote into it. It reported `1` on the runtime
  before the fix and reports `9` after.


```
  seeded dye: min 0.0  max 1.0  sum 615.5668
   60 steps in 566 ms  ( 9447 us/step, 39 dispatches/step )
  dye:  min 0.0  max 0.82379603  sum 576.4599
  u:    min -0.5785218  max 3.9745913
  div:  min -0.044581235  max 0.038681284  (post-projection, should be near zero)
  mass: predicted 579.702  measured 576.4599  drift 0.5592746475566335 %
  render: 960 x 720 - 32435 non-black pixels, brightest 115 of 255
  wrote fluid_frame.png - the crescent should be rolled at one end
  ok - mass, divergence, velocity and the render all check out
```

1. **Mass.** Dye is advected with a known per-step dissipation, so after 60
   steps the total is predictable: `0.999^60 x 615.57 = 579.70`, measured
   576.46, **0.56% low**. It is low and not exact because semi-Lagrangian
   advection interpolates, and interpolating a bump shaves its peak every step.
   A splat that lands twice, an advection that samples the wrong cell or a fade
   applied in the wrong place all move this number a great deal further; the
   test fails above 3%.
2. **Divergence.** Post-projection, `div` lands in `[-0.045, +0.039]`, inside
   the `+/-0.05` the test demands. This is asked *again* on the corrected
   field, not read out of the residual the solve was handed -- those are
   different numbers and only the first one means "the projection worked".
3. **Velocity is actually non-zero**, which catches a splat that never landed.
   That failure makes everything else look perfect.
4. **A rendered frame that is not entirely black**, which covers the
   magnification, the tone map and the byte packing. Those only ever fail as a
   black window, which is indistinguishable from a dead solver.

It also writes `fluid_frame.png` so the result can be *looked at* rather than
inferred from three numbers. The picture is the initial circular puff sheared
into a crescent and rolled at one end -- a vortex, which is what shoving a blob
off its centre is supposed to produce.

**The numbers above are the macOS original's numbers.** That version reports a
seeded sum of 615.57, 576.46 after sixty steps, 0.6% drift and 32,435 non-black
pixels. Same source, same arithmetic, Apple M4 and NVIDIA Turing -- and 32,435
pixels on the nose.

## What is different from the macOS original

- **`solver.mojo` is shared.** The macOS version has two copies of the solver,
  one in the app and one in the checker. Two copies drift, and a checker that
  has drifted is vouching for something nobody runs. Here `main.mojo` and
  `fluid_smoke.mojo` import the same kernels and the same `fluid_step`.
- **GDI instead of `CAMetalLayer`.** The GPU writes 960x720 BGRA words into
  pinned host memory and `StretchDIBits` blits them. That is the closest
  Windows analogue of `replaceRegion:` on a drawable, and it is deliberately
  the *dullest* option available: no swap chain, no device, no COM, and nothing
  that can report the window occluded and present nothing.
- **No Apple Events.** The macOS spike registers a `FLUD` event class and ships
  a `fluidctl` to drive the demo from outside the process -- and documents that
  the receiving side never fires. There is no analogous "script a bare
  executable" mechanism worth porting, so the verbs are on the keyboard only.
  `FLUID_AUTOSHOT` covers the one case the events were actually wanted for.
- **The PNG writer is ours.** libz is on every Mac; nothing equivalent is
  guaranteed on Windows, and taking a dependency on zlib to save a screenshot
  would be strange in an example about fluid dynamics. `png.mojo` writes the one
  DEFLATE stream that needs no compressor: **stored blocks**. The file is a
  completely ordinary PNG that any viewer opens, and about as big as the pixels
  are (2.0 MB for 960x720). Both checksums are real, because a PNG with a wrong
  CRC is rejected -- CRC-32 per chunk, Adler-32 over the zlib stream.

## Proving the pixels landed

That every call returned success is not evidence that anything is on screen, so
`[s]` and `FLUID_AUTOSHOT` do two different things and print both:

- **the file** -- `fluid-<n>.png`, written from the same words that were just
  presented, so the file and the window cannot disagree;
- **the readback** -- the window's own client area pulled back through
  `CreateDIBSection` + `BitBlt`, which is the presenting machinery pointed the
  other way.

```
FLUID_AUTOSHOT=150 ./build/fluid.exe
```

runs 150 frames, reports, saves, and exits -- the only way to exercise any of
this without a person holding the mouse:

```
frame 150 - 0 drag samples so far
  readback: client 960 x 720 - 59297 non-black pixels
     brightest 0x723200 at 420 , 270
     ink spans x 350 .. 610  y 161 .. 451
  saved fluid-0.png
```

That is the starting plume: risen from the middle, 260 pixels wide. If the
readback ever says zero, the window is up and every call succeeded and the
client area is black, and the program says so in as many words.

## The physics, briefly

Velocity is advected along itself by tracing each cell backwards through the
field and sampling where it came from. That is unconditionally stable at any
time step, which is the whole reason Stam's method is used rather than a
forward difference. The advected field is not divergence-free, so a Poisson
equation is solved for pressure and its gradient subtracted. Dye is passive: it
rides the corrected velocity and does not affect it.

Boundaries are handled by clamping every sample, which lets fluid slide along a
wall rather than leak through it -- free-slip, and all this needs.

The Jacobi sweep is **ping-ponged between two buffers rather than updated in
place**, on purpose. A Jacobi iteration reads the whole neighbourhood of the
*previous* iterate; writing in place feeds half-updated values back in and
quietly turns it into Gauss-Seidel with a thread-order-dependent answer --
which on a GPU means a result that changes with occupancy.

The simulation is 320x240 and the window is 960x720. The grid is coarser than
the display deliberately: the pressure solve is the expensive part and scales
with cell count, while the eye is perfectly happy with a bilinear magnification
of a smooth field. The magnification is done in the render kernel rather than
by GDI, because point-sampling 320x240 into 960x720 would show the simulation's
cells instead of the fluid.

Nothing here needs anything past sm_75: Float32 arithmetic, a `while` loop and
one linear index. No bf16, no tensor cores, no async copy.

## Details worth stealing

**Input is handled in the message pump, not in the window procedure.** A window
procedure is captureless -- Windows calls it, so it cannot close over `main`'s
locals -- and a procedure that dispatched kernels would need the
`DeviceContext` and its twelve buffers reachable from a C-ABI callback.
Reading `msg.message` out of `PeekMessageW` before dispatching it keeps all of
them ordinary locals in `main`. (This is the exact trade the macOS spike writes
up in its porting note, and it lands the same way here.)

**`lParam` packs the mouse position as two SIGNED 16-bit halves**, and they are
signed: a drag that leaves the window to the left reports a negative x, which
read unsigned becomes 65,000-odd and splats dye into the far corner.

**`PeekMessageW` removes `WM_QUIT` from the queue**, so the loop has to notice
it explicitly. `DispatchMessageW` will not do it for you.

**A negative `biHeight` asks GDI for a top-down DIB**, which is the order the
render kernel writes rows in. A positive height means bottom-up and the fluid
arrives upside down.

**All painting funnels through `WM_PAINT`.** The loop calls `InvalidateRect`
then `UpdateWindow`; the procedure does `BeginPaint` / `StretchDIBits` /
`EndPaint`. One blit path, so an uncovered window repaints from the same code
that animates it -- and `WM_ERASEBKGND` returns 1, because letting GDI clear
the client area first is what makes it flicker.

**The window is sized with `AdjustWindowRect`** rather than by adding a
remembered 16 and 39 to the client size, and the mouse is scaled by the client
rectangle that `GetClientRect` actually reports, so a DPI setting cannot make
the paint land somewhere other than the pointer.

Every entry point, every constant, every structure size and every DLL name
comes out of `windows_api.db`. Four structures are declared by hand and all
four have their size asserted against the metadata at compile time; none of
them is `TrivialRegisterPassable`, because claiming that of a big struct does
not fail to compile -- it silently writes the fields to the wrong places.

## The pieces

| file | what it is |
|---|---|
| `solver.mojo` | the physics: the kernels, `fluid_step`, `advect_dye`. No Windows in it at all. |
| `main.mojo` | the app: window, message pump, mouse forces, hue cycling, GDI present, readback. |
| `fluid_smoke.mojo` | the same kernels, headless, with the four assertions above. |
| `png.mojo` | CRC-32, Adler-32, stored-block DEFLATE, `CreateFileW`/`WriteFile`. |
