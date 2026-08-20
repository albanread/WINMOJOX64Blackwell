# DragonMax → WINMOJO integration handoff

> The step-by-step runbook version of this document — copy-paste commands,
> smoke tests, bounce-back table, checklist — is [`/INTEGRATEME.md`](../INTEGRATEME.md)
> at the repo root. Integrators should start there; this file is the contract
> behind it.

**Decision, 2026-08-19: the DragonMax GPU compile line is code-complete and
available for integration.** Everything DragonMax owns on the path from Mojo
source to Adreno silicon is written, committed on `main`, and traced end to
end (`design/OFFLOAD-FLOW.md`). What remains is verification that requires a
building compiler — which is WINMOJO's G3/G4 by definition — plus one linking
decision that belongs to the integrating side.

"Available to integrate" does **not** mean "proven end to end". It means: no
DragonMax-side component is missing, every remaining unknown is enumerated
below with its verification step, and the finish line is an executable test,
not a judgement call.

## What DragonMax delivers

| Component | Where | Proven how |
|---|---|---|
| Device runtime (MAX ABI over OpenCL) | `dragon/runtime/dragonrt.cpp` | raw-ABI test: saxpy 4096/4096 exact on Adreno |
| ABI specification, generated | `dragon/runtime/ABI.md` + extractor | `--check` mode; 109 symbols, 94 prototypes |
| Adreno stdlib target (6 edit sites) | `mojo/stdlib/std/gpu/host/info.mojo` | data layout emitted by LLVM, not guessed |
| `adreno` stdlib plugin | `mojo/stdlib/std/_plugin/adreno/` | registered in `STD_PLUGINS` |
| SPIR-V compiler trio | `KGEN/lib/{Target,KGENToLLVM/Target,Compiler/ObjectCompiler/Target}/Spirv/` | modeled on Host trio; registration via alwayslink globs, zero BUILD edits |
| LLVM SPIRV backend enabled | `bazel/public-patches/llvm_project.bzl` | `"SPIRV"` confirmed in the overlay's target list |
| Offload flow traced, no gaps | `dragon/design/OFFLOAD-FLOW.md` | file:line chain from `enqueue_function` to `clEnqueueNDRangeKernel` |

## The finish line (decided)

> **The GPU line is FINISHED when `dragon/mojo-tests/adreno_saxpy.mojo`
> compiles with WINMOJO's `mojo build --target-accelerator adreno-x1` and
> passes on this machine's Adreno X1-45.**

That file exists now and is the acceptance spec. It is standard Mojo — 
`DeviceContext`, `enqueue_create_buffer`, `enqueue_function`, host-side
verification — deliberately containing nothing DragonMax-specific, because the
objective is that Mojo code stays standard. Its API surface may need touch-ups
as WINMOJO's stdlib lands; its *shape* is the contract.

Secondary checks, cheaper and earlier than the full test:

1. `mojo build --print-supported-accelerators` shows a
   **"Qualcomm Adreno (DragonMax)"** section — proves all three registrations
   survived linking.
2. `mojo build --target-accelerator adreno-x1 --emit=asm` on any kernel
   produces text starting with SPIR-V assembly — proves codegen without
   needing the runtime.

## First-compile checklist — the only items that can bounce back to DragonMax

These are written against interfaces read in full, but none has compiled (no
building KGEN exists on Windows yet). Each has a named, bounded fix if wrong:

| Check | Risk | Fix if wrong |
|---|---|---|
| `mlir::LLVM::cconv::CConv::SPIR_KERNEL` spelling | enum namespace from `.td` + memory; vendored tree vanished mid-verification | one-line rename |
| `WriteableBuffer`/`BufferRef` idioms in `SpirvBackend.cpp` | mirrored from `HostBackend.cpp` verbatim | mechanical |
| Glob + alwayslink actually picks up the three `Spirv/` dirs | confirmed in BUILD rules, untested | add explicit srcs |
| `"SPIRV"` overlay target builds on `aarch64-pc-windows-msvc` host | target exists; this host combination untested | build-flag triage |

## The one decision that belongs to WINMOJO

**How the produced executable finds `AsyncRT_*` symbols.** Modular links their
closed runtime into the binary; WINMOJO must link *something* that provides
the ABI. Options, in the order we recommend:

1. Link `dragonrt.lib` (import library, produced alongside the DLL) into the
   mojo-built executable for GPU symbols, with WINMOJO's own AsyncRT build
   providing the CPU device. Symbol sets are disjoint by construction —
   dragonrt implements only what `CPUDevice.cpp` does not.
2. Delay-load `dragonrt.dll` on first `DeviceContext(api="adreno")`.

This is sequencing-sensitive with WINMOJO's G4 (linking `mojo.exe`) and G5
(stdlib shims), so the choice is theirs; the runtime supports either.

## How to integrate

DragonMax is a fork of WINMOJO (`winmojo` remote already configured here), so:

```bash
git -C C:\projects\WINMOJO remote add dragonmax C:/projects/DRAGONMAX  # once
git -C C:\projects\WINMOJO fetch dragonmax
git -C C:\projects\WINMOJO merge dragonmax/main   # or cherry-pick the [dragonmax] commits
```

Everything integration-relevant is on `main`, tagged by `[dragonmax]` commit
prefixes. `dragon/` is self-contained; the in-tree edits are the six
`info.mojo` sites, `_plugin/adreno/`, `_overlay.mojo`, the three `Spirv/`
directories, `llvm_project.bzl`, and `.gitignore` (whose `target/` trap is
documented in the journal — do not drop that hunk).

## Not part of this handoff

The NPU line (QNN, W4), runtime hardening (events, real per-stream dispatch,
the graph-capture tier), and kernel work (W5) continue on the DragonMax side
and do not block compiler integration. The HTP work already runs today without
`mojo.exe` and lands through the graph layer, not this ABI.
