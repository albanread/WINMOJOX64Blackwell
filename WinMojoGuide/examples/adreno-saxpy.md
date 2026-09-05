# adreno_saxpy — the other port's acceptance test, kept here on purpose

`saxpy` — `dst[i] = a·x[i] + y[i]`, 4096 elements, one kernel — written
against `DeviceContext(api="adreno")`, which dispatches to `dragonrt.dll`:
the Adreno X1-45 GPU of the ARM64 ports, not this tree's NVIDIA path. The
README states its purpose plainly: *the same program you would write for an
NVIDIA card* — the acceptance test for the DragonMax GPU stack, passing
when it runs on the Adreno and verifies every element on the host
(`PASS: all 4096 elements correct on <name>`).

## Does it run here?

No. This is the x64/NVIDIA port; the Adreno backend is `dragonrt` on
ARM64, `examples/win32/build.sh` is written for an ARM64 toolchain and
exits with "no MSVC ARM64 linker found" without one, and nothing in this
tree's BUILD.bazel builds the adreno samples. They live here because the
ports share a tree and a rule: the GPU program's *shape* does not change
between backends.

## What it teaches (from either side of the port boundary)

- The minimal kernel program, complete: create the context, create three
  buffers, copy x and y in, launch `saxpy_kernel` at `BLOCK=64`, copy back,
  verify — `enqueue_function` on one backend is `enqueue_function` on the
  other, which is the whole point.
- [adreno_saxpy_debug](../../examples/win32/adreno_saxpy_debug/main.mojo)
  is the debugging discipline made explicit: three rounds that isolate
  host-to-device copy (an echo), kernel reads (`dst = x`), then arithmetic
  — each printing expected-vs-got per slot, built after wrong answers
  needed an alibi.
- [adreno_index_probe](../../examples/win32/adreno_index_probe/main.mojo)
  answers one question — *what index does each work-item think it has?* —
  by writing `block_idx`, `block_dim` and `thread_idx` separately into
  sentinel-filled buffers and counting untouched slots. When elements come
  back wrong, this is the shape of the question that finds why.

A user of this tree reads them as documentation of the discipline: verify
copy, verify read, verify arithmetic — in that order, with sentinels.
