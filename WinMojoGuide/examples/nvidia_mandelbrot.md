# nvidia_mandelbrot — a Mojo kernel on the GPU, proven before it is shown

A zooming Mandelbrot computed entirely by a Mojo kernel on the NVIDIA GPU
— and, before the window ever opens, the **identical computation on the
CPU** is compared against it, with a validation that raises on the kind of
wrong a picture cannot show. Direct3D is reduced to what it should be here:
a texture upload and a fullscreen triangle whose shader is a colour ramp.

## Run it

```
./bazelw.cmd build //examples/win32:nvidia_mandelbrot
./bazel-bin/examples/win32/nvidia_mandelbrot.exe
```

or `mojo run main.mojo` from the folder (GPU required — the kernel goes
through `max.gpu` to PTX and the installed driver).

## The walkthrough

**The kernel and its twin.** `mandelbrot_kernel` (main.mojo:54) is a
single-exit divergent `while` — the escape loop — launched with
`ctx.enqueue_function[...](..., grid_dim=GRID, block_dim=BLOCK)` into an
R32_FLOAT device buffer; `mandelbrot_host` (main.mojo:81) is the same
iteration in the same order on the CPU. One launch warms up the JIT before
anything is timed.

**The validation is the point.** Comparing chaos to chaos needs sense:
pixel values diverge legitimately once orbits escape differently, so the
check (main.mojo:507) tolerates disagreement in high-count regions and
**raises only where an interior pixel is locally flat but differs** — the
signature of a codegen bug, not of arithmetic. The comment is the creed:
*a picture that looks right is not evidence: a Mandelbrot set is
recognisable long before it is correct.*

**The present path is deliberately thin.** Per frame: zoom the window,
launch the kernel, copy the float buffer to pinned host memory,
`UpdateSubresource` into an R32_FLOAT texture (main.mojo:1010), and
`Draw(3)` a triangle whose shader fetches the texture and applies a colour
ramp. The GPU computes; D3D displays; neither does the other's job.

## What it teaches

The `max.gpu` shape — `DeviceContext`, `enqueue_function`, pinned-host
readback — in its smallest complete form, wrapped in the discipline this
tree demands of GPU code: a CPU twin, a validation that can actually fail,
and a presentation layer that stays out of the way. One dispatch per frame,
which is exactly why [fluid](fluid.md) exists to measure what this one
cannot: launch cost.
