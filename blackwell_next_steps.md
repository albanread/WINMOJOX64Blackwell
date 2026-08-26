# Blackwell next steps

This document is the working plan for the Windows x64 NVIDIA Blackwell port of
Mojo and MAX. The current machine is an Intel Windows PC with an NVIDIA RTX PRO
2000 Blackwell Generation Laptop GPU. The runtime target is `sm_120a`.

The goal is not merely to compile a demonstration. The port should execute
ordinary Mojo GPU programs and useful MAX workloads correctly, diagnose its
own failures, and ship as a standalone Windows installation that does not need
Bazel or the CUDA development toolkit at run time. NVIDIA's installed driver
remains responsible for loading and executing PTX.

## Rules for continuing the port

- Do not run broad Bazel builds or test sweeps. Reuse the existing build tree
  and request only the narrow target needed for a changed component.
- Check free disk space and Bazel/cache growth before and after any build.
  Stop rather than allowing an unexpected rebuild of LLVM or the full graph.
- Prefer the no-Bazel Windows/WSL runner for correctness work. Run one test at
  a time at optimisation level 0 unless a test specifically requires another
  setting.
- Treat the official Linux Mojo package in WSL, using the same physical GPU,
  as the primary behavioural oracle. A shared failure is not evidence that the
  Windows port is correct; it is evidence that the problem may be shared or
  upstream.
- Keep test harnesses, oracle outputs, generated PTX comparisons, and machine
  measurements in the `oracles` repository. Do not add them to the public port
  repository.
- Keep production fixes, focused regression tests that belong with the source,
  and user-facing port documentation in `WINMOJOX64Blackwell`.
- Record the compiler revision, runtime revision, target, driver, command line,
  and cache identity for every published result.

## Current baseline

The published 24 August 2026 no-Bazel run contains 69 configured cases:

| Result | Count |
|---|---:|
| Windows passed its own validation | 50 |
| Windows and WSL matched passes | 44 |
| Windows regressions | 14 |
| Shared failures | 5 |
| Oracle-side failures or inconclusive cases | 6 |

All four explicitly consumer-Blackwell cases passed on Windows and matched
WSL. This is good evidence for basic SM120 execution, but the suite is centred
on `max/mojo/test`; it is not yet broad coverage of `max/kernels/test` or the
full MAX operator surface.

The runtime already has two important properties that the Apple ports recently
had to fix:

- `compute_capability()` is populated from the NVIDIA driver and reports the
  actual device generation rather than a hardcoded zero.
- `cuLaunchKernel` enqueues work without synchronising after every dispatch.
  Synchronisation is handled separately.

The current Blackwell performance reference points are:

- pure-FMA compiler ceiling: 12.049 TFLOP/s median at 32 chains;
- open, source-unrolled matmul: 3.049 TFLOP/s median at 2048 cubed;
- source-identical rolled register-blocked matmul: 11.6 GFLOP/s at 2048 cubed.

The last figure is a severe NVPTX lowering defect: dynamically indexed
accumulators become local-memory traffic instead of registers. It is not
explained by the laptop's 50 W power limit.

## P0: make every oracle result trustworthy

### Version the Mojo compilation cache

The Mojo kernel cache is keyed by the kernel body, not by the compiler binary
or its environment. The dual runner currently reuses a static Windows cache.
After a lowering change, that can silently execute old generated code and make
a compiler fix appear ineffective or verified when it was never exercised.

Before doing further lowering comparisons:

1. Derive a cache identity from the hashes of `mojo.exe`, `nvptxrt.dll`, the
   target (`sm_120a`), and any compilation options that affect code generation.
2. Use a separate bounded cache directory for that identity, or clear the
   compiler cache when the identity changes.
3. Write the identity and component hashes into every result JSON file.
4. Preserve the existing disk limits. Old generations should be reported and
   pruned explicitly rather than accumulating without bound.
5. Add a self-test that changes the compiler identity and proves that the
   runner cannot reuse the previous generated kernel.

Acceptance criterion: after changing a marker in NVPTX lowering, a no-Bazel
probe must show that the new compiler path ran without editing the Mojo kernel
body.

### Strengthen result classification

Exit code zero is not enough. Expand the runner's result model to distinguish:

- strong or adequate checked pass;
- partial pass;
- vacuous pass where every relevant path skipped;
- unverified execution with no failure mechanism;
- assertion or numerical failure;
- compiler crash;
- lowering/verifier failure;
- driver launch or pipeline failure;
- timeout or resource termination;
- out-of-scope vendor, hardware, or missing-source test.

For numerical GPU tests, also ask whether an all-zero output could pass. A
GPU-versus-GPU comparison is not an independent reference if both paths can
fail in the same way.

Acceptance criterion: the coverage report states both how many tests ran and
how many performed a meaningful independent check.

## P1: close the highest-value correctness gaps

### Test shared `rowwise` RMSNorm on Blackwell

The Apple M4 Max and Vega II ports independently reproduced incorrect output
from the shared `max/kernels/src/algorithm/rowwise.mojo` surface. The older
hand-written RMSNorm GPU implementation is correct on the same machines, which
points to shared kernel-library logic rather than an AIR backend defect.

Add direct Windows/WSL probes using a CPU closed-form reference for at least:

- `Float32` widths 32, 33, 64, 96, 128, 256, 1024, and a width above 16384;
- `BFloat16` and `Float16` representative widths;
- ordinary RMSNorm, fused residual add, RMSNorm plus RoPE, and Q/K RMSNorm;
- non-power-of-two widths and multiple rows.

Do not classify a matching Windows/WSL failure as a pass. If both fail against
the closed form, record it as a shared source defect. If only Windows fails,
compare emitted PTX and isolate the NVPTX or Windows runtime difference.

Acceptance criterion: every supported case matches an independent CPU
reference within an explicitly documented tolerance, or has a narrowly scoped
known-failure entry.

### Re-run and reduce the known Windows regressions

Revalidate the 14 published Windows regressions with a fresh compiler-keyed
cache, including the recently updated CUDA external-function test. Work from
smallest reproducer to subsystem fix. Current priority classes are:

1. the fatal NVPTX short-pointer/data-layout crash;
2. AsyncRT semantic differences, including invalid-buffer handling;
3. CUDA external-function compilation and execution;
4. remaining Windows-only compilation or output mismatches.

Every fix should gain a focused regression test. When the test is runner-only
or contains oracle-specific adaptation, keep it in `oracles`; when it directly
tests a stable source contract, place it beside the production source.

Acceptance criterion: no in-scope case remains a Windows regression without a
minimal reproducer, an assigned defect class, and a documented next action.

### Isolate unsafe shared failures

The existing bf16 `pow` and `powf` cases can produce illegal GPU memory access
on both Windows and WSL. Matching the official package does not make this safe.
Reduce the failure by dtype, vector width, launch shape, and emitted PTX, then
either correct it or reject the unsupported operation before launch.

Acceptance criterion: an unsupported operation fails deterministically with a
diagnostic; it must not be allowed to corrupt a CUDA context.

## P2: expand Blackwell-specific lowering coverage

Grow the no-Bazel suite from `max/mojo/test` into a deliberately scoped subset
of `max/kernels/test`. Start with operations that exercise distinct lowering
or runtime mechanisms:

- scalar, vector, bf16, fp16, fp8, and integer conversions;
- warp shuffle, vote, reduction, and lane-mask operations;
- shared memory, barriers, atomics, and global memory ordering;
- captured scalars, nested captures, device pointers, and aggregate kernel
  arguments;
- `cp.async`, tensor-core MMA, launch attributes, and dynamic shared memory;
- reductions, scans, softmax, normalization, elementwise math, and matmul;
- graph capture/replay, streams, events, and device-to-host observation paths.

Use explicit inclusion rules. Tests requiring AMD, Apple, multi-GPU,
InfiniBand, unavailable closed components, or a different NVIDIA architecture
must not inflate the denominator.

For each failure, retain the stage:

1. Mojo parsing or function instantiation;
2. KGEN/LLVM/NVPTX lowering;
3. PTX driver compilation;
4. kernel launch;
5. runtime synchronisation or memory transfer;
6. numerical validation.

Acceptance criterion: publish a reproducible Blackwell corpus census with
scope, meaningful-pass count, and failure taxonomy. Do not compare its
percentage with another port until both use the same scope definition.

## P3: repair rolled-accumulator NVPTX lowering

The stock rolled register-blocked matmul is the clearest code-generation
failure. Dynamic indexing currently places accumulator arrays in a local depot
and accesses them through local-address conversion, turning register blocking
into device-memory traffic.

Investigate the earliest IR stage at which the accumulator ceases to be
scalarisable. Compare the Windows port against official Linux output from the
same GPU and, where API drift permits, the same source. Candidate areas include
loop unrolling, scalar replacement of aggregates, constant propagation of
small loop indices, and pass ordering. Do not special-case the benchmark.

Required checks for a proposed fix:

- the byte-identical rolled source remains numerically exact for every shape;
- generated PTX no longer uses a local depot for the accumulator tile;
- register count and occupancy remain reasonable;
- compilation time and code size do not grow pathologically;
- unrelated dynamic arrays that genuinely require local memory remain valid;
- the source-unrolled control does not regress.

Acceptance criterion: eliminate the orders-of-magnitude rolled/unrolled gap by
a general lowering improvement, with PTX evidence explaining the change.

## P4: broaden MAX operation compatibility

Once the basic lowering census is dependable, exercise representative MAX
operator paths rather than isolated primitives alone:

- elementwise and broadcast operations across supported dtypes;
- reductions, normalization, softmax, and RoPE;
- dense, grouped, batched, and quantized matmul variants appropriate to SM120;
- convolution and pooling;
- attention prefill/decode and KV-cache manipulation;
- graph construction, compilation, replay, and host/device transfers;
- a small end-to-end model or pipeline that does not depend on an unavailable
  proprietary development component.

For each operator, compare Windows GPU output with both a CPU reference and the
official WSL GPU implementation where possible. Record unsupported operations
explicitly instead of allowing silent CPU fallback. Keep
`MODULAR_DISABLE_VENDOR_FALLBACK=1` enabled in port-validation runs.

Acceptance criterion: maintain a feature matrix whose claims are backed by
named tests, dtypes, shapes, and the date/revision last verified.

## P5: measure performance without confusing runtime and code generation

Measure a near-empty kernel to determine Windows/WDDM per-dispatch overhead and
compare it with WSL on the same GPU. The NVPTX launch path is asynchronous, but
short kernels may still be dominated by the operating-system and driver path.

Performance reports should therefore:

- use 2048 cubed as the primary cross-port matmul score;
- retain smaller shapes for diagnostic purposes but state their launch-cost
  share;
- report five or more repetitions, median, range, spread, and warm-up policy;
- sweep FMA chains far enough to bracket the measured peak;
- distinguish rated peak from the measured compiler ceiling;
- report the 50 W laptop power configuration;
- keep stock/source-identical and open/tuned competition entries separate.

After correctness is stable, tune Blackwell-specific tile shapes, occupancy,
shared-memory use, and tensor-core paths. Correctness and generated-code
inspection remain gates for every performance change.

Acceptance criterion: every headline score is reproducible, stable, and large
enough that launch overhead does not dominate it.

## P6: finish and refresh the standalone Windows release

Leave the existing `C:\projects\mojo_release` installation unchanged while
compiler and runtime correctness work continues. Refresh it only from a tested
revision.

Before publishing the next release, verify:

- Mojo `run` and ahead-of-time build both execute GPU programs on `sm_120a`;
- the windowed Mandelbrot example runs without Bazel;
- `nvptxrt.dll` and every required runtime dependency are present;
- Crashpad starts and reports failures without breaking normal execution;
- the LLDB-backed REPL/debug workflow is included and functional;
- MAX imports and representative GPU operations work from the packaged tree;
- no build-tree paths, Bazel runfiles, CUDA toolkit binaries, or accidental
  machine-local cache dependencies remain;
- a clean-shell smoke test succeeds using only the packaged environment and the
  installed NVIDIA driver.

Acceptance criterion: copy the release to a clean directory, remove build-tree
environment variables, and pass the documented CPU, GPU, JIT, AOT, REPL, and
MAX smoke tests without invoking Bazel.

## Immediate execution order

The next three increments should be small and independently verifiable:

1. Make the dual-runner cache compiler-aware and prove stale PTX cannot survive
   a compiler/runtime revision change.
2. Add and run the focused `rowwise` RMSNorm Windows/WSL comparison with an
   independent CPU reference.
3. Expand a first bounded slice of `max/kernels/test`, classify meaningful
   passes and failures, then choose the highest-impact Windows-only defect from
   evidence rather than raw test order.

Only after those steps should the rolled-accumulator lowering work be judged by
new performance measurements. This order prevents stale generated code,
vacuous tests, or runtime launch costs from being mistaken for compiler
progress.
