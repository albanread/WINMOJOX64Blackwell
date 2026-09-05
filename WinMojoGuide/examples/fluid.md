# fluid — Stam's Stable Fluids, forty-four dispatches at a time

Jos Stam's 1999 Stable Fluids as a native window: drag the mouse and
coloured dye swirls through a velocity field that advects itself and is
made divergence-free by a Jacobi pressure solve. Every kernel is Mojo
compiled to PTX; there is no shader anywhere — the last thing the GPU does
is pack BGRA words, and GDI blits them. `[space]` pauses, `c` clears,
`r` rains, `s` saves a shot, Esc quits; `FLUID_AUTOSHOT=N` runs N frames,
proves the pixels landed, saves a PNG and exits.

## Run it

```
mojo build --no-optimization -I mojo/stdlib -I . -I max/mojo \
    -Xlinker "$(cygpath -w bazel-bin/nvptx/runtime/nvptxrt.if.lib)" \
    -o build/fluid.exe examples/win32/fluid/main.mojo
./build/fluid.exe
```

(The `-I .` matters: the solver is imported as
`examples.win32.fluid.solver`. `./examples/win32/build.sh fluid` does all
of it. `nvptxrt.dll` must be reachable.)

## The walkthrough

**The physics lives in solver.mojo, shared by every entry point.**
`fluid_step` (solver.mojo:261): two semi-Lagrangian advects, a divergence,
a pressure clear, **thirty ping-ponged Jacobi sweeps**, gradient
subtraction, two copy-backs — then three dye channels ride the corrected
field, then `render_kernel` magnifies and tone-maps. Forty-four dependent
dispatches per frame, and the file says why the ping-pong is not an
optimisation: writing a Jacobi sweep in place silently becomes
Gauss-Seidel, *a result that changes with occupancy*.

**The window is the pump-shaped loop**: `PeekMessageW`, never blocking,
because something is animating; input handled in the pump (the window
procedure cannot reach the DeviceContext); signed `lParam` halves for the
mouse; a per-frame client-size re-read so DPI and resizes keep the mapping
honest. Pixels go GPU → pinned host buffer → `present_bgra`.

**The two sibling programs are the real lesson.** [fluid_smoke](../../examples/win32/fluid/fluid_smoke.mojo)
runs the *same* kernels headless and asserts the four things a broken
solver breaks — mass conservation, post-projection divergence, non-zero
velocity, a non-black frame — separating "the physics broke" from "the
window broke". [fluid_bench](fluid_bench.md) measures where the frame's
time goes and carries the device-graph probes. A demo whose failure modes
are indistinguishable built the tooling that distinguishes them.

## The trap, from the bench

The frame was long launch-bound — 6.9 ms of submission over ~0.7 ms of GPU
work — and putting it behind a CUDA device graph found a real bug: a
recorded kernel node held only raw addresses, Mojo freed the buffers at
their last use (the record), and the replay was a use-after-free that
looked exactly like an addressing-pattern fault. The full story is in
`findings/device-graph-recording.md` in the oracles repository; the graph
now replays at 0.94 ms with bitwise-identical physics.
