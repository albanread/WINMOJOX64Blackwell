# DragonMax architecture

How the pieces fit, what we build, and why. Derived from the recon in
`../recon/`; read `MAX-ANATOMY.md` first if you have not.

## The stack, with the two holes marked

```
   ┌──────────────────────────────────────────────────────────┐
   │  Model pipelines        max/python/max/pipelines    OPEN │
   │  Layers / nn            max/python/max/nn           OPEN │
   │  Graph API              max/python/max/graph        OPEN │
   ├──────────────────────────────────────────────────────────┤
   │  GRAPH ENGINE           max/python/max/_core    ▓▓ GAP 1 │  ← unpublished
   │    MLIR pipeline, scheduling, execution                  │
   ├──────────────────────────────────────────────────────────┤
   │  Kernels                max/kernels/src             OPEN │
   │  GPU programming model  mojo/stdlib/std/gpu         OPEN │
   │  Target tables          .../gpu/host/info.mojo      OPEN │
   │  stdlib plugins         mojo/stdlib/std/_plugin     OPEN │
   │  KGEN compiler          KGEN/  (326 .cpp)           OPEN │
   ├──────────────────────────────────────────────────────────┤
   │  DEVICE RUNTIME         AsyncRT_DeviceContext_* ▓▓ GAP 2 │  ← unpublished
   │    109 C symbols: memory, streams, kernels, events       │
   ├──────────────────────────────────────────────────────────┤
   │  AsyncRT CPU device + work queues   AsyncRT/        OPEN │
   ├──────────────────────────────────────────────────────────┤
   │  Vendor runtimes — all present on this box               │
   │    OpenCL / Vulkan (Adreno)   ·   QNN / QAIRT (Hexagon)  │
   └──────────────────────────────────────────────────────────┘
```

**Both holes are runtime layers. The entire compile side is open**, compiler
included. That is the single most important structural fact, and it means
codegen is a matter of work rather than of access.

## The QAIRT finding: one API already spans all three processors

Measured 2026-08-19 after obtaining the SDK. QAIRT ships **CPU, GPU *and* HTP
backends for `aarch64-windows-msvc`**, all behind the same
`QnnInterface_getProviders` table:

| DLL | Backend | id | backend API |
|---|---|---|---|
| `QnnCpu.dll` | `CPU_QTI_AISW` | 3 | 1.1.0 |
| `QnnGpu.dll` | `GPU_QTI_AISW` | 4 | 3.12.0 |
| `QnnHtp.dll` | `HTP_QTI_AISW` | 6 | 5.41.0 |
| `QnnIr.dll` | `IR_QTI_AISW` | 9 | 0.1.0 |
| `QnnSaver.dll` | `SAVER_QTI_AISW` | 2 | 1.1.0 |

All five load and answer in a native ARM64 process
(`dragon/probe/probe_qnn_backends.py`). `QnnGpu` was **not** in the
GenieX-bundled runtime — it is new capability from the SDK, and it is the piece
that makes NPU *and* GPU reachable without writing two runtimes.

This reshapes the plan. Where the original design needed a bespoke device
runtime over OpenCL for the GPU **plus** a separate QNN path for the NPU, one
QNN-based execution layer can cover both — and the CPU as a bonus. Qualcomm
already wrote and shipped it for this exact platform triple.

**What this does not settle.** Loading is not executing. Still unproven:
whether each backend builds and runs a real graph; how `QnnGpu`'s
graph-at-a-time model compares to the 41.9 GFLOP/s our own OpenCL kernel
reached in D2; and what op coverage differs between backends. A graph API may
well be *worse* than direct dispatch for GPU compute — that is exactly what D2
exists to compare against.

**Version trap, recorded because it reads backwards.** The package version is
not the API version. Package `2.42.0.251225` declares `QNN_API_VERSION 2.32.0`
in `QnnCommon.h`, while the GenieX bundle reports core **2.34.0** — so the
older-looking bundle is the *newer* API. Build against the SDK headers and run
against the SDK's own DLLs so the two match.

## Codegen: three surfaces, three routes

| Surface | Route | Backend exists? | Precedent |
|---|---|---|---|
| Oryon CPU | LLVM AArch64 | upstream, mature | WINMOJO already does this |
| Adreno GPU | LLVM → **SPIR-V** → Qualcomm driver compiler | upstream since LLVM 18 | Metal's handoff, below |
| Hexagon NPU | graph → **QNN IR** → AOT context binary | n/a — not a kernel target | none in MAX |

### Why SPIR-V, and why that is not a compromise

There is no Adreno backend in LLVM, and there never will be — Qualcomm does not
publish the shader ISA. That sounds fatal until you notice Modular already
shipped a GPU in exactly this position.

Apple's AIR is not an upstream LLVM target either, and there is no AIR backend
in the open KGEN. What there *is*:

- `KGEN/lib/Compiler/ObjectCompiler/LLVM/Transforms/LLVMIRDowngradePass.cpp` —
  *"Transform LLVM IR for backend compilation that takes older version of LLVM
  IR."*
- `Bitcode/17/`, `Bitcode/19/`, `Bitcode/21/` — vendored, version-pinned
  bitcode writers.

Modular does not write backends for closed GPUs. **They emit an interchange
format the vendor's own compiler accepts, and let the vendor lower it.**

Adreno is the easier version of that trick. SPIR-V is a documented standard with
an in-tree LLVM backend, and Qualcomm's SPIR-V consumers — `qcvkarm64xcompiler.dll`
(Vulkan) and `qcclarm64xcompiler.dll` (OpenCL) — are already installed. We hand
off at a published format rather than at a guessed bitcode version.

### Why the NPU is not on that list

The Hexagon HTP does not take kernels. QNN wants a whole graph, compiled ahead
of time into a context binary, executed as a unit. Measured consequence, from
this machine: naive per-op NPU offload ran at 13.8 tok/s decode against the
CPU's 25.3, while the AOT-compiled QAIRT graph reached 35.6.

**Pointing a kernel-dispatch runtime at the HTP is slower than not using it.**
So the NPU attaches at GAP 1 (graph level), not GAP 2 (device level). Two
different integration points for one project — the design must carry both.

## GAP 2: the device runtime, sized

`device_context.mojo` and its siblings declare **109 distinct `AsyncRT_*`
symbols**. Enumerated and tiered:

| Tier | Count | Contents | For Adreno |
|---|---|---|---|
| **Core** | ~68 | context lifecycle, buffers, H2D/D2H/D2D, streams, kernel load + launch, events, timers | **must implement** |
| Vendor escape hatches | 13 | `cuda_context`, `hip_device`, `metal_device`, `*_cuda_module`, `cuda_tensorMapEncode*`, Metal trace capture | not applicable — omit |
| Graph capture / replay | 20 | `DeviceGraphBuilder_*` (15), `DeviceGraph_*` (4), `createGraphBuilder` | stub unsupported at first |
| Multi-GPU / peer / multicast | 8 | `canAccess`, `enablePeerAccess`, `DeviceMulticastBuffer_*` | single GPU — stub |

A bring-up subset is far smaller than 68: create/release, one buffer type,
H2D/D2H, one stream, `loadFunction` + `enqueueFunctionDirect`, `synchronize`.
Call it **~30 symbols to first kernel**.

The ABI is not documented anywhere — there was nothing to document, since the
implementation is unpublished. But every symbol is *declared* in open Mojo with
its full signature, so extracting a real interface spec is mechanical. That
extraction is the first hard task in the plan.

### The constraint AsyncRT imposes on us

`AsyncRT/docs/AsyncRTRuntime.md` states the rule plainly: **"The design assumes
that work items never block."**

A QNN `graphExecute` is synchronous and long. An OpenCL `clFinish` blocks.
Neither may be called from a `WorkQueue` worker without stalling a core that the
runtime believes is doing useful work. Whatever we build needs its own
dispatch thread per device, signalling completion back through `AsyncValue`.
This is a design commitment, not an implementation detail — get it wrong and
the failure looks like poor scaling rather than a bug.

## GAP 1: the graph engine

Larger, and its resolution is the D3 strategy decision, deliberately deferred
until D2 has numbers. What is already settled by evidence:

- There is no prebuilt engine to fall back on. Upstream `MODULE.bazel` mentions
  Windows **zero** times; every Windows reference in this tree is WINMOJO's own
  work. Nothing exists to link against on this platform.
- Therefore any strategy that assumes Modular's engine runs here is dead. That
  removes candidate A from the D3 list on evidence rather than preference.
- The Python layers *above* the engine are open, so a replacement engine has a
  fixed, readable interface to satisfy on both sides.

## What we add, and where

| Change | Location | Kind |
|---|---|---|
| Adreno targets (5 edit sites) | `mojo/stdlib/std/gpu/host/info.mojo` | in-tree edit |
| `AdrenoPlugin` | `mojo/stdlib/std/_plugin/adreno/` | in-tree, ~12 lines |
| SPIR-V emission path | `KGEN/lib/Compiler/ObjectCompiler/` | in-tree edit |
| Device runtime over OpenCL/Vulkan | `dragon/runtime/` | **new, ours** |
| QNN graph lowering | `dragon/qnn/` | **new, ours** |
| Kernel variants for wave-64 / 32 KiB | `max/kernels/src/**` | in-tree edit |
| Probes, harnesses, benchmarks | `dragon/probe/`, `dragon/bench/` | **new, ours** |

Everything new lives under `dragon/` so the diff against `winmojo/main` stays
legible and rebasing onto upstream stays possible.

## Two rules this design commits to

**Never hardcode the wave width.** Vulkan reports `subgroupSize = 64`, but
D1b measured OpenCL's `CL_KERNEL_PREFERRED_WORK_GROUP_SIZE_MULTIPLE` returning
**64 for one kernel and 128 for two others on the same device**. Adreno's
scheduling width is a *per-kernel* property, unlike NVIDIA's fixed 32 and AMD
CDNA's fixed 64. Query it after compiling each kernel.

The reason for the variation is **not yet known** — register pressure was the
obvious hypothesis and the measurement contradicts it. Until it is understood,
treat any cross-lane assumption as suspect.

Practical consequence for kernel selection: the HIP (wave-64) paths in
`max/kernels` are still the better starting point than the CUDA ones, since 64
divides both observed widths. But "Adreno is wave-64" is not a fact to build
on.

**Re-derive every tile size.** Adreno gives 32 KiB of shared memory per
workgroup — under half of AMD's 64 KiB, a seventh of Hopper's 228 KiB. Every
tile constant in Modular's kernels and design docs overflows it. They are
inputs to a calculation, never values to copy.
