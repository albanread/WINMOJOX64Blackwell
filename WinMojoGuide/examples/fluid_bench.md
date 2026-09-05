# fluid_bench — where a fluid frame's time actually goes

The headless measurement behind [fluid](fluid.md). No window: it times a
one-thread kernel launched two thousand ways, the same kernels replayed as
graph nodes, whole frames enqueued three ways, and finishes with two
probes whose verdict lines are regression fixtures for the device-graph
runtime. Its README section is in [the fluid folder](../../examples/win32/fluid/README.md);
this walkthrough reads the program.

## Run it

Build like `fluid.exe`, from `fluid_bench.mojo`, and run
`build/fluid_bench.exe`. Knobs: `FLUID_BENCH_STAGES` (see below),
`FLUID_BENCH_SKIP_CLASSIC`.

## The four measurements

1. **The dispatch floor** — a one-thread kernel, 2000 launches behind one
   wait: ~131 µs per classic dispatch on the T1000. Times 44, that is the
   frame — before any physics runs.
2. **The graph floor** — the same 2000 kernels as one recorded graph,
   replayed: **~5 µs per node**. The ratio is the argument for graphs.
3. **Whole frames, three ways** — classic with a synchronize every step,
   classic with one synchronize at the end, and the 44-dispatch frame as a
   recorded graph. The first two land within a rounding error of each
   other (the frame is submission-bound, so batching the waits buys
   nothing), and the graph replays at ~0.94 ms — **7.3×, with the dye
   total bitwise identical across all three paths**, which is the
   correctness proof for the dependency chain, not merely the absence of a
   fault. Graph build costs one classic frame, once.
4. **Two probes with verdicts**:
   - *recording semantics*: record a memset and a copy through a recording
     context, read the destination before any replay. `0` before and the
     right value after means they recorded; any value before means they
     executed eagerly during capture — the defect this probe caught in
     nvptxrt, since fixed, kept as the guard.
   - *graph ownership*: record a one-node graph over a buffer never named
     again, allocate a same-sized buffer afterwards, replay, read the new
     buffer back. `9` means the graph wrote its own, still-live buffer;
     `1` means it wrote memory the allocator had already handed elsewhere —
     the use-after-free that once masqueraded as an addressing bug,
     caught here without needing a fault.

## The stage lattice

`FLUID_BENCH_STAGES` truncates the recorded frame graph kernel by kernel —
`0` is one `divergence_kernel` node, negative values are fifteen
single-kernel probes (indexed writes, the 2D decode, neighbour loads,
multiply, subtract, clamped variants...), `5` is the whole frame. It was
built to bisect the graph-replay fault, and kept because it is the
regression sweep for every future change to kernel-node recording: run the
lattice, and anything that broke ordering or ownership names itself.
