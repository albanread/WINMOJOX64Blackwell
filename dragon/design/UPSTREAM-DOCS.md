# Modular's own docs, annotated for this port

What is in the tree, what it is worth to us, and what it does *not* cover.
Ranked by usefulness to DragonMax, not by their table of contents.

## Tier 1 — read before writing code

### `mojo/stdlib/docs/adding-gpu-targets.md` (19 KB)

The only document Modular wrote for precisely our job. Covers the MLIR target
attribute (`triple`, `arch`, `features`, `data_layout`, `index_bit_width`,
`simd_bit_width`), how to derive a `data_layout` string four different ways, a
six-step procedure, eight named pitfalls, and a validation checklist.

Its step 6 warns you must update **five** locations for one new GPU: the target
function, the `GPUInfo` alias, the constraint list in `_get_info_from_target`,
the `comptime` mapping block, and `GPUInfo.target()`. Miss one and it fails
somewhere unrelated.

**What it does not cover: the run side.** It gets Mojo emitting code for a new
architecture and stops. Nothing about device runtimes, memory, or dispatch —
which is exactly the half that is unpublished.

### `max/docs/design-docs/amd-printf-lessons-learned.md`

The honest write-up of what adding a *second* vendor actually cost. NVIDIA
offers a `vprintf` syscall; AMD does not, so `print` in a kernel required
implementing hostcalls — an async device→host message ring — from scratch,
while deliberately avoiding AMD's `device-libs` because vendoring it "would
require adding a whole other copy of LLVM".

Read it for the shape of the surprise, not the details. **Adreno has no
hostcall mechanism either**, and the same avoid-the-vendor-toolchain pressure
applies to us with Qualcomm's compiler DLLs. Budget for it.

### `AsyncRT/docs/` — `AsyncRTRuntime.md`, `WorkQueue.md`, `AsyncValue.md`, `WorkQueueNonblocking.md` (875 lines)

The concurrency model the whole stack sits on, and it is *fully open* — this
describes `CPUDevice`, which is published. Key design commitments that
constrain anything we build underneath:

- `WorkQueue` is an abstract interface with multiple implementations, chosen by
  policy rather than hardcoded.
- **"The design assumes that work items never block."** A QNN `graphExecute`
  call is synchronous and long. Handing one to a `WorkQueue` worker directly
  violates the model and will stall a core.
- Explicitly designed to *compose* with other things using CPU threads, not to
  own the machine.

That third point is why a Snapdragon device can coexist with the CPU device
rather than replacing it.

## Tier 2 — read when the relevant work starts

| Doc | When | Why |
|---|---|---|
| `max/docs/design-docs/elementwise-ops.md` | first kernel | simplest kernel abstraction; the natural bring-up target |
| `max/kernels/CLAUDE.md`, `CONTRIBUTING.md` | first kernel | authoring conventions to match |
| `max/docs/design-docs/matmul-to-flash-attention.md` | D2 baseline | how their matmul reaches attention |
| `max/docs/kernel-benchmarking.md`, `kernel-profiling.md` | D2 | their harness; reuse rather than invent |
| `KGEN/docs/DesignOverview.md` (68 KB), `MojoCompilerWalkthrough.md` (68 KB) | codegen work | KGEN is open, so these are actionable, not background |
| `KGEN/docs/manual/PassesAndIR.md` | codegen work | pass pipeline |
| `mojo/stdlib/docs/internal/pop_dialect.md` (242 lines) | codegen work | the POP dialect |
| `max/docs/contributing-models.md` | GOAL gate | how a model gets into MAX |
| `max/docs/why-bazel.md` | build friction | their rationale; relevant to WINMOJO's stated de-Bazel ambition |

## Tier 3 — vendor-specific, useful only as method

`matmul-on-blackwell-{1,2,3}.md`, `wgmma-programming.md`,
`uwgmma-flash-decoding.md`, `multi-head-flash-attention.md`,
`multi-head-latent-attention.md`, `genai-paged-attention.md`,
`fp8-support-in-mojo.md`, `token-sampling.md`.

Deeply NVIDIA. Blackwell `wgmma` has no Adreno counterpart. Read for *how they
reason* about tiling and pipelining, never for numbers to copy — and remember
Adreno gives us 32 KiB of shared memory against Hopper's 228 KiB, so every tile
size in these documents is wrong for us by construction.

`mojo/stdlib/docs/internal/runtime.md` is ten lines, nine of which are a
warning that everything in it may change without notice. Skip.

## The gap in their documentation

Nothing in the tree documents the device runtime interface — the
`AsyncRT_DeviceContext_*` ABI. That is not an oversight in the docs; the
implementation is unpublished too, so there was nothing to document.

The ABI is nonetheless **fully enumerable**, because
`max/mojo/max/gpu/host/device_context.mojo` declares every symbol it calls
across ~7,000 lines. Extracting that into a real interface specification is
work DragonMax has to do itself, and it is the first hard task in the plan.
