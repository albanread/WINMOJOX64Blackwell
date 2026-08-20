# DragonMax

Bringing MAX-class inference to Snapdragon silicon on native Windows ARM64 —
Hexagon NPU, Adreno GPU, Oryon CPU.

Started 2026-08-19. Trunk `C:\projects\DRAGONMAX`, branch `main`.
Running record: [`DRAGONMAX-JOURNAL.md`](DRAGONMAX-JOURNAL.md).

## Relationship to WINMOJO

Separate project, deliberately. [WINMOJO](../WINMOJO) ports the **Mojo
compiler** to Windows ARM64 and explicitly excludes `max/` and GPU. DragonMax
is the GPU/NPU layer that WINMOJO left out.

This tree is forked from WINMOJO rather than from Modular, so it inherits the
Windows ARM64 build work instead of repeating it. Three remotes:

| Remote | Points at | Role |
|---|---|---|
| `origin` | *(not yet created)* | DragonMax's own |
| `winmojo` | `C:/projects/WINMOJO` | Windows ARM64 port; fixes flow **in** |
| `upstream` | `github.com/modular/modular` | never pushed to |

Forked at WINMOJO `dde8f83773` (its G3).

**Dependency, and why it does not block:** DragonMax eventually needs a working
`mojo.exe`, which is WINMOJO's G6 and not done. But the early gates below need
no Mojo at all — they characterise hardware and drive vendor runtimes directly
from C++/Python. D0–D2 run in parallel with WINMOJO G3–G6.

## Documents

| Read | For |
|---|---|
| [`dragon/recon/MAX-ANATOMY.md`](dragon/recon/MAX-ANATOMY.md) | what is published and what is not |
| [`dragon/recon/HARDWARE.md`](dragon/recon/HARDWARE.md) | measured Snapdragon capability |
| [`dragon/design/ARCHITECTURE.md`](dragon/design/ARCHITECTURE.md) | the stack, the two gaps, codegen routes |
| [`dragon/design/PORTING-PLAN.md`](dragon/design/PORTING-PLAN.md) | support matrix, work breakdown W1–W6, risks |
| [`dragon/design/UPSTREAM-DOCS.md`](dragon/design/UPSTREAM-DOCS.md) | which of Modular's docs help, and which mislead |

## What we are up against

Read [`dragon/recon/MAX-ANATOMY.md`](dragon/recon/MAX-ANATOMY.md) before
planning anything. The short version:

MAX is **source-available but not source-complete**. Licensing is not the
issue — the tree is Apache-2.0 with LLVM exceptions and MAX use falls under the
permissive Community License. Two specific things were never published, and
both are runtime layers:

1. **The graph engine.** `_core/BUILD.bazel` names sources under
   `max/python/max/_core/internal/`, a directory absent from the tree and from
   all of its git history.
2. **The accelerator device runtime.** The 109 `AsyncRT_*` symbols that
   `device_context.mojo` calls have zero hits in any C/C++ file tree-wide.

**Everything on the compile side is open, including the compiler** — KGEN is
326 `.cpp` files in `KGEN/`, the target tables and stdlib plugin mechanism are
editable Mojo, and all of `max/kernels` is source. So codegen is a question of
work, not of access.

Better still, Modular already shipped a GPU whose backend they do not have:
Apple AIR is not an upstream LLVM target, and they handle it by emitting
downgraded LLVM bitcode for Apple's own compiler to lower
(`LLVMIRDowngradePass.cpp`, plus vendored bitcode writers for LLVM 17/19/21).
**Adreno is the easier version of that trick** — hand Qualcomm's driver
compiler SPIR-V, a documented format with an in-tree LLVM backend.

## The performance fact that steers the design

Measured on this box, decode / prefill tok/s:

| Path | Decode | Prefill |
|---|---|---|
| QAIRT NPU-native, Qwen3-1.7B | **35.6** | **766** |
| CPU, Gemma-4-E4B | 25.3 | 157 |
| llama.cpp NPU offload, Gemma-4-E4B | 13.8 | 431 |

Naive NPU offload *lost to the CPU* on decode. Only an ahead-of-time compiled
QNN graph beat it. The Hexagon NPU is not a kernel-dispatch device — it pays
off only when handed a whole graph at once. Adreno, by contrast, is a natural
kernel-dispatch target but is the weakest of the three in raw throughput on
this part (X1-45, the cut-down variant).

Design consequence: the NPU wants a **graph compiler target**, the GPU wants a
**device backend**. These are different mechanisms and the project should not
pretend otherwise.

## Gate ladder

Evidence first. The strategy decision sits at D3, *after* measurement, not
before it.

| Gate | Deliverable | Status |
|---|---|---|
| **D0** | Recon: hardware measured, MAX anatomy mapped, licensing recorded | **done** |
| **D1** | Probe harness — drive all three surfaces from native Win ARM64 | **D1a done; D1b GPU done**, NPU next |
| **D2** | Baseline: one reference workload timed on NPU / GPU / CPU | |
| **D3** | **Strategy gate** — pick the spine on D2's evidence | **done** — MAX-compatible ABI, Mojo the standard way |
| **W1–W3** | ABI spec · device runtime on Adreno · SPIR-V compiler trio | **done** (code-complete) |
| **HANDOFF** | GPU line integration-ready for WINMOJO | **declared 2026-08-19** — runbook: [`INTEGRATEME.md`](INTEGRATEME.md), contract: [`dragon/HANDOFF.md`](dragon/HANDOFF.md) |
| **GPU GOAL** | `dragon/mojo-tests/adreno_saxpy.mojo` passes via `mojo build` | blocked on WINMOJO G3+ |
| **NPU line** | QNN graph path (W4) — independent of `mojo.exe` | 1 GiB @ 4.1x CPU measured; continues |
| **GOAL** | A real model runs end-to-end on Snapdragon, beating CPU-only | |

### D1 — probe harness (no Mojo required)

Three standalone probes under `dragon/probe/`, each proving we can reach the
silicon from a native ARM64 process:

**D1a — reachability (done).** `dragon/probe/probe_surfaces.py` loads each
vendor runtime from a native ARM64 process and reports what it is. All three
answer. Findings in the journal; the important one is that **two OpenCL
platforms claim the same Adreno device**, so selection must be by platform.

**D1b — execution.** Reachability is not the same as running work.

- ✅ `probe_opencl_exec.py` — saxpy over 4096 elements on the QUALCOMM
  platform, every element verified against the host. Qualcomm's compiler
  accepted the source; buffers, H2D, launch, D2H and sync all work. This
  exercises exactly the bring-up subset of the device ABI.
- ⬜ `htp_qnn` — create a context and execute a trivial graph on HTP V81
- ⬜ `adreno_vk` — Vulkan compute, only if OpenCL's compiler disappoints

Exit criterion: each returns numbers we can check.

### D3 — the strategy gate

Three candidate spines. D2's numbers decide, and the choice is the user's.

**~~A. Reimplement the device ABI~~ — eliminated on evidence.** The idea was to
provide `AsyncRT_DeviceContext_*` over OpenCL so Modular's stack sits on top
unmodified. But there is no engine binary for Windows ARM64 to sit on: upstream
`MODULE.bazel` mentions Windows **zero** times. Nothing to link against.

**B. Independent runtime.** Take the open parts — Mojo kernels, graph API, nn
layers — and execute them on our own engine across all three surfaces. Most
work, no dependency on unpublished binaries, fully ours.

**C. NPU-first, narrow.** Skip the GPU. Graph → QNN lowering, AOT context
binaries, HTP execution. Smallest scope, best payoff per the table above, and it
matches what the hardware actually rewards.

**Direction set 2026-08-19: NPU *and* GPU, both first-class.** The NPU is 45
TOPS and runs small models quickly; the Adreno measured **3.37x the CPU** in D2.
The 32 GB of unified memory is the strategic asset — every processor addresses
the same RAM, so model size is not capped by VRAM as on a discrete GPU.

That points at **candidate B**, and the QAIRT SDK makes B far cheaper than it
looked: Qualcomm ships **CPU, GPU and HTP backends behind one API** for
`aarch64-windows-msvc`, all verified loading here. Work breakdown in
[`dragon/design/PORTING-PLAN.md`](dragon/design/PORTING-PLAN.md).

## Rules carried in from prior ports

- Assume every offset, size, and capability from documentation is wrong until
  measured on this box. The recon docs record measurements, not specs.
- Journal in-repo, not in chat.
- Finish, commit, start the next — in the same turn.
- GUI/visual results need a camera, not an assertion.
