# DragonMax port journal

Running record. Newest entry at the bottom. Chat gets short replies; the
detail lives here.

---

## 2026-08-19 — D0 recon, project stood up

Forked from WINMOJO `dde8f83773` (its G3) rather than from Modular, to inherit
the Windows ARM64 build work. Remotes: `winmojo` → local WINMOJO trunk,
`upstream` → modular/modular. No `origin` yet.

### The finding that defines the project

MAX's engine is **closed source**. `max/python/max/_core` holds thirteen `.pyi`
stubs and no implementation. The GPU device runtime is closed too:
`max/mojo/max/gpu/host/device_context.mojo` is ~7,000 lines of `external_call`
into `AsyncRT_DeviceContext_*`, and grepping all of `AsyncRT/**/*.{h,cpp}` for
that prefix returns **nothing** — the open AsyncRT ships `CPUDevice.cpp` and
the async machinery, no accelerator devices.

So the Snapdragon backend cannot be written by editing MAX's runtime. It has to
either satisfy that C ABI from outside or replace the execution layer.

Mitigating: `device_context.mojo` *declares* the whole ABI it calls, so the
surface is fully enumerable from open source. Large, but not a mystery.

### What is open, and the Metal precedent

Open: the Mojo GPU programming model, `info.mojo`'s MLIR target tables, all of
`max/kernels/src`, and the Python graph/nn/pipelines stack.

Counting `api=` tags in `info.mojo`: cuda 19, hip 15, **metal 10**, none 1.
Apple Metal is already a third backend that is tile-based, unified-memory and
non-PTX — architecturally the same shape as Adreno. And
`mojo/stdlib/docs/adding-gpu-targets.md` (19 KB) is a step-by-step guide to
adding a new GPU target, written by Modular. The compile side is well-paved.

### Hardware, measured on this box

Adreno X1-45 via `vulkaninfo` from the driver store: **subgroup size 64**,
32 KiB shared memory per workgroup, 1024 max invocations, fp16/int8/int16 all
supported, integrated (unified memory, no PCIe copy).

Wave-64 matches AMD CDNA, not NVIDIA's 32 — so where `max/kernels` forks by
vendor, the **AMD path is the better starting point**. But 32 KiB of shared
memory is under half of AMD's 64 KiB, so tile sizes lifted from either vendor's
matmul will not fit and must be re-derived.

Everything needed is already installed, no SDK downloads:
- Adreno OpenCL + Vulkan in `qcdx8380.inf_arm64_3555a260d521ff65`
- QAIRT (`QnnHtp.dll`, `QnnHtpV81Stub.dll`, skels) bundled inside GenieX CLI
- llama.cpp's `ggml-hexagon.dll` and `ggml-opencl.dll` — MIT-licensed worked
  examples for both surfaces, sitting on disk

One trap already spotted: **no OpenCL ICD is registered** under
`HKLM\SOFTWARE\Khronos\OpenCL\Vendors`, so the generic `OpenCL.dll` loader
enumerates nothing. Adreno's OpenCL must be loaded from the driver-store path
directly. D1 will confirm.

### The number that should steer everything

Prior measurements on this machine: QAIRT NPU-native decode 35.6 tok/s vs CPU
25.3 vs llama.cpp NPU offload 13.8. **Naive NPU offload loses to the CPU.**
Only an AOT-compiled QNN graph wins, and only by 1.4x.

Therefore the NPU is a *graph compiler target*, not a kernel-dispatch device,
while Adreno is the reverse. Two different mechanisms. A design that treats the
HTP like a GPU will be slower than doing nothing.

### Licensing, recorded not resolved

Repo is Apache-2.0-with-LLVM-exceptions, but the README puts MAX *usage and
distribution* under the separate Modular Community License. WINMOJO avoided
`max/` precisely to stay permissive; DragonMax enters it by definition and
inherits the question for anything distributed. Matters at publication time,
not for local research. Terms to be read before shipping artifacts.

### Next

D1: three probes under `dragon/probe/` — `adreno_cl`, `adreno_vk`, `htp_qnn` —
each proving we can drive the silicon from a native ARM64 process and print a
correct result. No Mojo needed, so this runs in parallel with WINMOJO's G3–G6.

The strategy gate is D3, deliberately placed *after* D2's measurements rather
than guessed at now. Three candidates written up in `DRAGONMAX.md`.

---

## 2026-08-19 — D1a: all three surfaces answer

`dragon/probe/probe_surfaces.py` — ctypes, no build system, no Mojo. Runs in a
native ARM64 Python 3.12 and asks each vendor runtime what it is.

```
  [ok] Adreno OpenCL
  [ok] Hexagon QNN system
  [ok] Hexagon QNN HTP
```

### Correction: the ICD trap I predicted does not exist

D0 recorded that no OpenCL ICD was registered under
`HKLM\SOFTWARE\Khronos\OpenCL\Vendors`, and inferred the generic loader would
find nothing. **Wrong.** `C:\Windows\System32\OpenCL.dll` enumerates two
platforms perfectly well. Registration lives somewhere other than the key I
checked. `HARDWARE.md` has been corrected.

Going the other way, `OpenCL_adreno.dll` exports *neither* `clGetPlatformIDs`
nor `clIcdGetPlatformIDsKHR`, so it is not usable as a direct loader — the
exact opposite of the D0 guess. Use the system loader.

### The real trap, which fails silently

**Two OpenCL platforms report the same device name.**

| Platform | Device reported | CUs |
|---|---|---|
| `QUALCOMM Snapdragon(TM)` — OpenCL 3.0, build 807.0 | Adreno X1-45 | 3 |
| `OpenCLOn12` — D3D12 translation | Adreno X1-45 | 1 |
| `OpenCLOn12` | Microsoft Basic Render Driver | 1 |

Anything that picks a device by matching "Adreno" in the name can land on
Microsoft's D3D12 translation layer and still look like it succeeded. **Select
by platform, not device name.** The probe now labels both inline so this can't
be misread later.

Also: the QUALCOMM driver reports `CL_DEVICE_MAX_CLOCK_FREQUENCY` as **1 MHz**.
Garbage. Do not use that field. Global memory reads 15 GiB — about half the
unified 31.6 GiB — and local memory 32 KiB, agreeing with the Vulkan numbers.

### NPU versions, measured

| Library | Provider | backendId | API |
|---|---|---|---|
| `QnnHtp.dll` | `HTP_QTI_AISW` | 6 | core 2.34.0, backend 5.45.0 |
| `QnnSystem.dll` | `SYSTEM_QTI_AISW` | 0 | system 1.9.0 |

So the bundled QAIRT is the 2.34 generation. Worth pinning: context binaries are
version-sensitive.

One self-inflicted bug worth recording, because it is the kind that produces
confident nonsense rather than an error. `QnnSystemInterface_t` carries a
*single* `systemApiVersion`, while `QnnInterface_t` carries a `coreApiVersion` +
`backendApiVersion` pair. Reading the system struct with the backend layout
printed `backend=0.860793856.32764` — plausible-looking garbage, no crash, no
error code. Two structs now, and a comment saying why.

That is the [[dolphin-32bit-offsets-rule]] lesson again in a new costume:
a struct layout taken from the wrong header does not fail, it lies.

### Next

D1b — reachability is not execution. Get a checkable numerical result out of
each surface: a real OpenCL kernel on the QUALCOMM platform, a Vulkan compute
dispatch, and a trivial QNN graph on HTP V81.

---

## 2026-08-19 — re-verified the closed-engine claim under challenge

Pushed back on: isn't MAX open, under a community license? Worth re-checking,
and the wording in D0 was sloppy. Two separate questions had been blurred.

**On licensing, the challenge is correct.** MAX is openly licensed. Published
tree is Apache-2.0 with LLVM exceptions; usage and distribution fall under the
Modular Community License, which is permissive for most purposes. Licensing is
*not* what blocks this port, and D0 implied otherwise by lumping them together.

**On source availability, the original finding survives, with better evidence.**

The decisive artifact is `max/python/max/_core/BUILD.bazel`, which names its own
sources:

```python
srcs = ["//max/python/max/_core/internal:_core.cpp"],
deps = ["//max/python/max/_core/internal:AsyncRTPython",
        "//max/python/max/_core/internal/modules"]
```

`max/python/max/_core/internal/` **does not exist in the repo and never appears
in its git history.** `git log --all -- <path>` returns nothing; `git ls-files`
under `_core/` lists `.pyi` and nothing else. The BUILD file is the public
residue of an internal monorepo where that directory does exist. The interface
was published; the implementation was stripped at export.

Same for the device runtime, checked more widely than in D0: `AsyncRT_DeviceContext`
across the **whole tree** in any `.c/.cpp/.h/.hpp/.cc` file returns **zero
hits**. Every hit is `.mojo`, and every one is a declaration —
`device_context.mojo`, `device_graph.mojo`, `_nvidia_cuda.mojo`,
`_amdgpu_hip.mojo`, `_metal.mojo`, `_metal_capture.mojo`. The per-vendor files
turn out to be bindings as well; `_nvidia_cuda.mojo` is five `external_call`s
and some opaque structs, not a CUDA driver.

And the fallback of using a prebuilt engine does not exist here either:
upstream `MODULE.bazel` at `f66d4d5` mentions Windows **zero** times. Every
Windows reference in this tree is WINMOJO's own G2 work.

**Corrected framing, now used in the docs: source-available, not
source-complete.** The unpublished parts happen to be exactly the two a new
hardware backend would need. The ladder is unchanged.

---

## 2026-08-19 — design docs, and a large correction in our favour

Went looking for Modular's own design docs, and found that the D0 picture was
**too pessimistic about the compile side**. Three findings, each of which moves
work from impossible to merely hard.

### KGEN — the Mojo compiler — is open source

`KGEN/` holds **326 `.cpp`, 234 `.h`, 66 `.td`**. D0 implied the compiler was
out of reach. It is not.

Concretely, `stdlib_plugin` is resolved in `KGEN/lib/KGENDialect/KGENAttrs.cpp`
and treated as an **opaque string** via `getStdlibPlugin()` — no closed enum, no
validation against a fixed vendor list. The Mojo-side registry
(`std/_plugin/selector.mojo`) matches that string at compile time, and
`std/_plugin/` already contains `cuda/`, `hip/`, `metal/`.

Scope check so nobody over-reads this: `MetalPlugin` is **twelve lines** with
every hook left at default. The hooks are `exp`, `tanh`, address-space lookup,
`print` emission, `abort`, assertion messages — stdlib behaviour, *not* codegen.
An `adreno` plugin is an afternoon. It is not the port.

### How Modular targets a GPU whose backend they do not have

The best thing in the tree, and it is in no design doc.

Apple's AIR is not an upstream LLVM target, and there is no AIR backend in the
open KGEN. So what makes `triple = "air64-apple-macosx"` work?

- `KGEN/lib/Compiler/ObjectCompiler/LLVM/Transforms/LLVMIRDowngradePass.cpp` —
  *"Transform LLVM IR for backend compilation that takes older version of LLVM
  IR."*
- `Bitcode/17/`, `Bitcode/19/`, `Bitcode/21/` — vendored, version-pinned
  bitcode writers.

**They do not write backends for closed GPUs. They emit something the vendor's
compiler already accepts.** For Adreno that is SPIR-V — a documented standard
with an in-tree LLVM backend since 18, consumed by `qcvkarm64xcompiler.dll` and
`qcclarm64xcompiler.dll`, both already installed. Strictly easier than what they
did for Metal, since we hand off at a published format rather than a guessed
bitcode version.

### The device ABI is exactly 109 symbols, and most are optional

Enumerated properly this time (the first grep missed multi-line `external_call`
and undercounted by 5x). Across `max/mojo/max/gpu/host/*.mojo`:

| Tier | Count | For Adreno |
|---|---|---|
| Core — lifecycle, buffers, transfers, streams, kernels, events | ~68 | must implement |
| Vendor escape hatches — `cuda_context`, `metal_device`, `cuda_tensorMapEncode*` | 13 | omit |
| Graph capture — `DeviceGraphBuilder_*` (15), `DeviceGraph_*` (4), +1 | 20 | stub unsupported |
| Multi-GPU / peer / multicast | 8 | stub — one GPU |

Bring-up subset is roughly **30 symbols**: create/release, one buffer type,
H2D/D2H, one stream, `loadFunction` + `enqueueFunctionDirect`, `synchronize`.
A far smaller problem than "109 unpublished functions" first suggested.

### Candidate A is dead

D3's option A — reimplement the ABI so Modular's own engine sits on top — is
**eliminated on evidence, not preference**. Upstream `MODULE.bazel` mentions
Windows **zero** times; there is no engine binary for Windows ARM64 to sit on.
D3 is now a two-way choice between B (independent runtime) and C (NPU-first),
and D2's numbers decide it.

### A constraint worth writing down before it bites

`AsyncRT/docs/AsyncRTRuntime.md`: **"The design assumes that work items never
block."** QNN's `graphExecute` is synchronous and long; OpenCL's `clFinish`
blocks. Neither can run on a `WorkQueue` worker without stalling a core the
runtime thinks is busy. We need a dispatch thread per device from the start,
signalling back through `AsyncValue`. Retrofitting that means redoing the whole
completion path, and the failure mode is bad scaling rather than a crash — the
kind of bug that hides.

### Written

- `dragon/design/ARCHITECTURE.md` — the stack with both gaps marked, codegen
  route per surface, the ABI tiering, what we add and where.
- `dragon/design/PORTING-PLAN.md` — support matrix (honest about the NPU int8
  cell being the point), dependency graph, work breakdown W1–W6, risk register,
  explicit non-goals.
- `dragon/design/UPSTREAM-DOCS.md` — Modular's docs tiered by usefulness.
  Tier 1 is three items; the Blackwell `wgmma` material is a dead end for us.

`MAX-ANATOMY.md` corrected — it understated how much is open.

### Next

W1 (extract the ABI spec) needs nothing and can start now. So can W4's QNN
harness, which never needs `mojo.exe`. D1b still wants a checked numeric result
out of each surface.

---

## 2026-08-19 — W1 done, and D1b runs a real kernel on the Adreno

### W1 — the ABI spec is generated, not transcribed

`dragon/runtime/extract_abi.py` walks the bindings and emits
`dragon/runtime/ABI.md`. **109 symbols, 94 of them (86%) with the real C
prototype** recovered from the comment above each `external_call`.

First attempt recovered only 26. The bug: the comment is not always on the line
directly above, because calls are usually wrapped —

```mojo
# const char *AsyncRT_DeviceContext_hip_device(hipDevice_t *result, ...)
_checked(
    external_call["AsyncRT_DeviceContext_hip_device", _CString[]](
```

— so a bare `_checked(` sits between comment and call. Scanning back over
intervening code, and accepting a comment block only when it *names the symbol*,
took it to 94. The name check is what makes the wider scan safe.

Generated rather than hand-written on purpose: 109 hand transcriptions is 109
chances at an error that only shows up as a wrong-arguments crash in a foreign
process. `--check` fails when stale, so a rebase that changes the interface is
reported rather than silently absorbed.

Tiers came out core 68 / graph 19 / vendor 14 / multigpu 8. All **33** hand-picked
bring-up symbols verified present in the bindings.

**Three structural findings, none of them in any Modular document:**

1. `const char *AsyncRT_DeviceContext_create(const DeviceContext **result,
   const char *api, int id)` — `api` is a **plain runtime string**
   (`"cpu"`, `"cuda"`, `"hip"`, `"metal"`), not an enum, not a compile-time
   parameter. The device runtime is a string-dispatched factory, and since we
   implement it, we own the dispatch.
2. `"cpu"` goes through the same interface, so AsyncRT's **published**
   `CPUDevice` is a working reference for the ABI's shape.
3. **77 of 109 calls return `const char *`**: null is success, non-null is an
   error message the *caller* owns and must release with
   `AsyncRT_DeviceContext_strfree`. Traced through `_checked` →
   `_raise_checked_impl` → `_string_from_owned_charptr`. Get the ownership rule
   wrong and it leaks on every error path.

### D1b — a real kernel, verified

`dragon/probe/probe_opencl_exec.py`: saxpy over 4096 floats on the QUALCOMM
platform, **every element checked against the host**. Qualcomm's OpenCL compiler
accepted the source; context, buffers, H2D, launch, D2H and `clFinish` all work.
Deliberately the same operations as the ABI bring-up subset, so what it learns
transfers straight to `dragon/runtime/`.

### The wave width is not a device constant

Vulkan said `subgroupSize = 64`. OpenCL disagreed, so I measured three kernels:

| kernel | max WG | preferred multiple |
|---|---|---|
| `saxpy` | 1024 | **128** |
| `wave_probe` | 1024 | **64** |
| `reg_heavy` | 1024 | **128** |

**Established: the preferred multiple varies by kernel on the same device.**
That is unlike NVIDIA's fixed 32 and AMD CDNA's fixed 64. Query it per kernel
after compilation; never hardcode it, and never derive it from Vulkan's
`subgroupSize`.

**Not established: why.** Register pressure was the hypothesis, and I wrote
`reg_heavy` specifically to test it — 64 live floats in a dependent chain. The
data contradicts the simple form of it: `reg_heavy` reports the same 128 as
trivial `saxpy`, while the even more trivial `wave_probe` reports 64. Cause
unknown. Recorded as unknown rather than guessed at.

This retires the "Adreno is wave-64, use the HIP paths" rule from
`ARCHITECTURE.md` in its confident form. The HIP paths are still the better
starting point — 64 divides both observed widths — but "Adreno is wave-64" is
not a fact to build on. Both design docs corrected.

Also worth noting for later: the Qualcomm driver reports `CL_DEVICE_MAX_COMPUTE_UNITS`
as 3 and `MAX_CLOCK_FREQUENCY` as 1 MHz. The clock is garbage (already known);
3 CUs is plausible for an X1-45 but should not be trusted for occupancy maths
until something independent confirms it.

### Next

D1b's remaining half: a trivial graph on HTP V81 through QNN. That is also the
start of W4, and it needs no `mojo.exe`.

---

## 2026-08-19 — QAIRT SDK obtained; one API covers NPU **and** GPU

### Where the SDK came from

Qualcomm's own Windows-on-Snapdragon repo, [quic/wos-ai], has
`Scripts/qnn_setup.ps1`, which downloads QAIRT from a **direct public URL with
no account and no token**:

```
https://apigwx-aws.qualcomm.com/qsc/public/v1/api/download/software/sdks/
Qualcomm_AI_Runtime_Community/All/2.42.0.251225/v2.42.0.251225.zip
```

1,543,955,191 bytes (1.44 GB), 3.48 GB extracted, 10,910 entries. Installed to
`C:\Qualcomm\AIStack\qairt\2.42.0.251225`, matching Qualcomm's own convention;
`QNN_SDK_ROOT` persisted to the user environment.

Practical note: **`HEAD` on that URL returns 403 while `GET` works.** A ranged
`GET` (206) is the way to check size without pulling the whole file.

### The finding that changes the architecture

QAIRT ships **CPU, GPU and HTP backends for `aarch64-windows-msvc`, behind one
interface**. All five load and answer in a native ARM64 process:

| DLL | Provider | id | backend API |
|---|---|---|---|
| `QnnCpu.dll` | `CPU_QTI_AISW` | 3 | 1.1.0 |
| `QnnGpu.dll` | `GPU_QTI_AISW` | 4 | 3.12.0 |
| `QnnHtp.dll` | `HTP_QTI_AISW` | 6 | 5.41.0 |
| `QnnIr.dll` | `IR_QTI_AISW` | 9 | 0.1.0 |
| `QnnSaver.dll` | `SAVER_QTI_AISW` | 2 | 1.1.0 |

**`QnnGpu` was not in the GenieX bundle** — it is new capability, and it is
exactly what the dual NPU+GPU goal needs. The original design had a bespoke
OpenCL device runtime for the GPU *plus* a separate QNN path for the NPU. One
QNN execution layer can cover both, and the CPU as well. Qualcomm already wrote
it for this platform triple.

Unproven, and not to be assumed: that each backend actually *builds and runs* a
graph; how `QnnGpu`'s graph-at-a-time model compares with the **41.9 GFLOP/s**
our own OpenCL kernel hit in D2; and how op coverage differs per backend. A
graph API could easily be worse than direct dispatch for GPU compute. D2 is the
yardstick for finding out.

### Direction corrected

An earlier draft of `PORTING-PLAN.md` over-rotated to "NPU first" on a partial
reading. The actual direction is **NPU and GPU, both first-class** — the NPU at
45 TOPS for small models, the Adreno at 3.37x the CPU. Both design docs fixed.
This lands nearer candidate **B** than C, and the QAIRT finding makes B much
cheaper than it looked.

### Two version traps

**1. The package number is not the API version.** Package `2.42.0.251225`
declares `QNN_API_VERSION 2.32.0` in `QnnCommon.h`. The GenieX bundle reports
core **2.34.0** — so the older-looking bundle is the *newer* API. Build against
the SDK headers, run against the SDK's own DLLs, keep the pair matched.

**2. I guessed the backend-id enum and got it wrong.** Written from memory as
`{1: CPU, 2: GPU, 3: DSP, 4: HTA, 5: SAVER, 6: HTP}`, it was shifted by one and
mislabelled every backend while looking entirely reasonable — CPU printed as
"DSP", GPU as "HTA". The header says
`NULL 0, REFERENCE 1, SAVER 2, CPU 3, GPU 4, DSP 5, HTP 6`. The raw ids in the
probe output were right all along; only my map was wrong.

Third time this shape of error has appeared in this project
(QnnSystemInterface layout, the OpenCL ICD guess, now this). **We have the
headers now — there is no longer any excuse for guessing at a constant.**

### Next

W4.0: find the real model-size ceiling on the HTP. The D0 measurement of
`~5 GB` came from llama.cpp's ggml-hexagon backend; whether that limit belongs
to the HTP, its driver, or that backend is unknown, and it bounds the whole NPU
line. With the SDK in hand it is cheap to answer, and `bin/` ships
`qnn-net-run` and the converters to answer it with.

---

## 2026-08-19 — capability tests: GPU and NPU both execute

Goal was narrow: prove the surfaces work at all, not benchmark them. Full
report in `dragon/probe/CAPABILITIES.md`.

| Surface | Loads | Executes |
|---|---|---|
| Adreno via our own OpenCL | yes | **yes** — saxpy exact, matmul 41.9 GFLOP/s exact |
| Adreno via `QnnGpu` | yes | **yes** — vendor unit test passed |
| Hexagon via `QnnHtp` | yes | **yes** — vendor unit test passed |
| Oryon via `QnnCpu` | yes | provider negotiates; tool has no CPU unit test |
| Full model graph | — | **blocked** on a toolchain gap, below |

### The Hexagon failure was a path, not the hardware

First DSP run failed outright — `-6 . Error while executing the sum function`,
followed by advice about `testsig` and unsigned images. That advice is a red
herring. The real cause was the second line: `ADSP_LIBRARY_PATH` was unset, so
the DSP could not find its skels. Pointing it at
`lib\hexagon-v81\unsigned` turned the same command into
**"Unit Test on the backend DSP: Passed."**

Two oddities logged without explanation, because guessing is how this project
keeps getting caught out: the tool loads `QnnHtpV73CalculatorStub.dll` and
reports *"Hexagon Architecture V73"* on V81 silicon, yet passes against V81
skels. And `DSP_INFO UNSUPPORTED_KEY: 49/50` precedes every run harmlessly.
**Do not read that "V73" as a hardware fact.**

### QnnGpu is OpenCL underneath

The validator's GPU run found `OpenCL.dll` and resolved Qualcomm extensions —
including `clNewRecordingQCOM` / `clEnqueueRecordingQCOM`, a command
record-and-replay facility that looks directly useful for a dispatch runtime
later. It reported *"OpenCL 3.0 Qualcomm(R) Adreno(TM) X1-45 GPU"* and passed a
vector-addition unit test.

That means **QnnGpu takes the same OpenCL path our D2 kernel takes**, so D2's
41.9 GFLOP/s is a fair yardstick to hold it against rather than an unrelated
number. Good: the comparison we wanted is apples to apples.

### Blocked, and precisely why

`qnn-net-run` needs a compiled model library, and building the SDK's own
example fails in three diagnosed steps:

1. `qnn-model-lib-generator` hardcodes `cmake -T ClangCL`; this VS 18 install
   has no ClangCL component → `MSB8020`.
2. Forcing the default MSVC toolset configures fine, then fails to compile.
   `/std:c++20` clears the designated-initializer error (`C7555`) but not
   `C4576`/`C2059`, because the generated code uses `(Qnn_Tensor_t){...}` — a
   **C compound literal**, a Clang/GCC extension that is not valid ISO C++ at
   any standard level.
3. No clang exists anywhere on this machine.

**Qualcomm's generated model code requires Clang; there is no MSVC-only path.**
That is a toolchain gap, not a limitation of the silicon, and it does not
affect anything already proven above. Fix is a user action — VS Installer's
*C++ Clang tools for Windows*, or an LLVM ARM64 install.

Noted for the record: the generator writes its staging tree to `tmp_<pid>` in
the **current working directory**, not the `-o` output dir, and leaves it
behind. Two of them landed in `C:\projects`; both removed.

### Next

Once clang is available: build the example model and run `qnn-net-run` across
`QnnCpu` / `QnnGpu` / `QnnHtp` for a like-for-like three-way comparison, then
W4.0 — the HTP model-size ceiling.

---

## 2026-08-19 — full model graph runs on CPU and NPU; QnnGpu does not

Clang was already on the box after all — WINMOJO's bazel toolchain downloads
**clang 22.1.4, target `aarch64-pc-windows-msvc`**, under
`_bazel_alban\cache\repos\...\bin`. My earlier search missed it because I looked
at install locations and PATH rather than the bazel repo cache. It is not
registered anywhere, so `Get-Command` and the registry both come up empty.

With that, built the SDK's own InceptionV3 conv+relu example into an ARM64 DLL
and ran it through `qnn-net-run` on each backend:

| Backend | Result | Wall time |
|---|---|---|
| `QnnCpu` | **Finished Executing Graphs**, 2 result sets | 298 ms |
| `QnnHtp` | **Finished Executing Graphs**, 2 result sets | 1377 ms (incl. prepare) |
| `QnnGpu` | **Graph Execution failure** | 313 ms |

**A real graph executes on the Hexagon NPU.** That is the headline; the NPU line
is unblocked.

### QnnGpu is broken here, and it matters for the design

```
CL ERROR: (-59) CL_INVALID_OPERATION
GPU ERROR: GPU_ERROR_OPENCL(10014) - OpenCL recorable command queue error
```

That is the `clNewRecordingQCOM` / `clEnqueueRecordingQCOM` path the platform
validator reported resolving earlier. QnnGpu drives the Adreno through OpenCL
command record-and-replay, and **that path fails on this driver.**

Careful about what this is not. The Adreno is fine: our own direct OpenCL
dispatch runs saxpy and a tiled matmul correctly at 41.9 GFLOP/s, and QnnGpu's
own vector-add unit test passes. Only the recorded-queue path fails, and only
on a real graph. The unit test passing while the real workload fails is exactly
why "loads" and "executes" are tracked as separate columns.

The header offers a way out — `QnnGpuGraph.h` declares
`uint8_t disableQueueRecording` — but it is unreachable from the tool, and the
two layers contradict each other while saying so:

- top-level `disable_queue_recording` → schema rejects it, "depends on graph_names"
- moved beside `"graph_names": ["convReluModel"]` →
  `ERROR: Unsupported key: graphs/0/disable_queue_recording`

The JSON schema validates a key the extension DLL then refuses. **The toggle is
only reachable programmatically**, via `QnnGpuGraph_CustomConfig_t`.

**Design consequence: do not build the GPU path on QnnGpu.** Own the OpenCL
dispatch. QNN earns its place on the NPU, not the GPU. That reverses the
optimistic reading from the morning — one API spanning all three is *available*
but not *usable* for the GPU, and D2's 41.9 GFLOP/s is the reason we can say so
with numbers rather than shrugging.

### Four traps in building a model library

Recorded in `dragon/qnn/build_model_lib.ps1`, which automates the lot. None of
them produces an honest error:

1. `qnn-model-lib-generator` hardcodes `cmake -T ClangCL`; stock VS 18 has no
   ClangCL component → `MSB8020`.
2. Generated code uses `(Qnn_Tensor_t){...}`, a **C compound literal** — Clang
   extension, invalid ISO C++ at any level. `/std:c++20` clears `C7555` but
   never `C4576`/`C2059`. Clang is mandatory.
3. The generated `CMakeLists.txt` branches on `CMAKE_GENERATOR_PLATFORM`, which
   Ninja refuses. Branch on which `obj/` dir exists instead.
4. **`set VAR=value && next` in cmd captures the space before `&&`.**
   `QNN_SDK_ROOT` became `...251225 `, the include path `...251225 \include\QNN`,
   and it surfaced as `fatal error: 'QnnInterface.h' file not found` — a quoting
   bug dressed as a missing header. Use `set "VAR=value"`.

### Next

W4.0, now genuinely unblocked: find the HTP's real model-size ceiling. Then a
like-for-like CPU-vs-HTP comparison on something bigger than a two-op graph.

---

## 2026-08-19 — W4.0: our own model runs on the NPU, and the DSP wedges

### The pipeline is ours now

`dragon/qnn/gen_matmul_model.py` emits a QNN model of controllable weight size —
a chain of `[1,D] x [D,D]` MatMul layers, `.cpp` plus a `.bin` tar of raw
tensors in the SDK's own converter format. `build_model_lib.ps1` turns it into
an ARM64 DLL. So we can now generate, build and run arbitrary graphs on the
Hexagon NPU without going through anyone's converter.

First real result, 4 MiB of weights (dim 512, 4 layers):

| Backend | Result |
|---|---|
| `QnnCpu` | Finished Executing Graphs |
| `QnnHtp` | **Finished Executing Graphs** |

And they agree: **max |cpu − htp| = 0.0348 against a max magnitude of 56.1, so
0.062% relative.** The HTP is computing at reduced internal precision, as
expected, and getting the right answer. That is the first end-to-end numerical
validation of our own workload on the NPU.

One generator bug worth noting: weights were originally built with a
`struct.pack` per element, which at dim=4096 is 16.7M calls per layer and
dominates everything. Now tiles a 17-float period instead — 128 MiB in 0.31 s.

### Then the ceiling test, and a lesson

Scaled to 128 MiB (dim 2048, 8 layers). CPU ran it in 783 ms. HTP failed at
41 ms:

```
<E> DspTransport.openSession qnn_open failed, 0x80000406, prio 100
```

The obvious conclusion is "the HTP tops out somewhere under 128 MiB". **That
conclusion would have been wrong.** Re-ran the 4 MiB model that had passed
minutes earlier as a control — and it failed identically.

**The DSP session layer wedges.** Once wedged, every HTP run fails the same way
at session open, regardless of size. What it is not:

- not the device — Windows reports the Hexagon NPU with status **OK**
- not the driver stack broadly — `QnnCpu` keeps working throughout
- not a stray process — nothing is holding a session
- not transient — still failing after a 20 s settle

This is the pre-HND behaviour from the `geniex-gemma4-npu-setup` notes, which
the driver update was believed to have fixed. It has not been, for this path.

**So the 128 MiB number measures nothing.** Whether that model exceeded a real
limit, or merely triggered the wedge, is unknown. It failed during *session
open*, before weights would plausibly have moved, which hints at a
session-sizing rejection — but that is a hypothesis, not a measurement, and it
stays labelled as one.

### The rule, now enforced in code

**Every HTP probe is followed by a control run of a known-good small model.**
Control passes → the failure was real. Control fails → the DSP is wedged and
everything after the first failure is void.

`dragon/qnn/htp_ceiling_sweep.ps1` bakes this in: it builds a small control
model, refuses to start if the DSP is already wedged, and after any HTP failure
re-runs the control to label the result `CEILING` or `WEDGED` before deciding
whether to continue.

This is the same shape as every other trap in this project — a plausible number
that is actually an artefact. The difference is that this one would have set
the NPU roadmap around a fiction, so the control discipline is worth the cost.

### Blocked on a reboot

The DSP will not recover without one. Recovery might also come from disabling
and re-enabling the NPU in Device Manager, but that is a system change and the
user's call, not mine.

After a reboot: run `htp_ceiling_sweep.ps1` and get the real number.

---

## 2026-08-19 — D3 resolved, and the MAX device ABI runs on Adreno

### The decision

**Objective set by the owner: WINMOJO's Mojo should drive our accelerated
Snapdragon features, through a MAX-compatible interface, used the standard Mojo
way.** That resolves D3, and it is a better-scoped target than "port MAX" —
the seam is `device_context.mojo`, which is open, and implementing the symbols
it calls makes `DeviceContext`, `DeviceBuffer` and `enqueue_function` work
unchanged.

### W2 — the runtime works

`dragon/runtime/dragonrt.cpp` implements the 33-symbol bring-up subset over
OpenCL. `test_dragonrt.c` drives it through `GetProcAddress` only, with no
DragonMax header, so it exercises the ABI exactly as Mojo will find it.

```
all bring-up exports resolved
  device : Qualcomm(R) Adreno(TM) X1-45 GPU
  api    : adreno   id=0        ver=300  total=16163 MiB  maxAlloc=1024 MiB
  [ok] createBuffer x/y/out, HtoD, loadFunction(saxpy),
       enqueueFunctionDirect, synchronize, DtoH
  [ok] all 4096 elements correct
ALL PASS
```

Three things worth keeping from building it:

- `loadFunction` sniffs the **SPIR-V magic number** `0x07230203` and routes to
  `clCreateProgramWithIL`, otherwise treats the blob as OpenCL C. The source
  path exists so the runtime is testable *before* KGEN emits SPIR-V. That
  ordering means a codegen bug and a runtime bug can never be the same
  investigation.
- Launch dims are `uint32_t` because the bindings say so: Mojo has two launch
  paths and if they disagree (i64 vs i32) a module composing both fails to
  legalize.
- Mojo speaks a CUDA-shaped grid-of-blocks; OpenCL wants global work-items. The
  launch multiplies through.

### W3 — Adreno is now a Mojo target, on paper

Six edit sites, not the five `adding-gpu-targets.md` documents:

1. `QualcommAdrenoFamily` — wave 64, **32 KiB** shared memory
2. `_get_adreno_x1_target()` — triple `spirv64-unknown-unknown`,
   `stdlib_plugin = "adreno"`
3. `AdrenoX1` GPUInfo alias, `api="adreno"`, `sm_count=3`
4. `"adreno-x1"` in the `_all_targets` canonical list
5. `GPUInfo.target()` dispatch
6. the arch-string → GPUInfo mapping in `_get_info_from_target`

Plus `std/_plugin/adreno/` and its registration in `_overlay.mojo`'s
`STD_PLUGINS`.

**The data layout was emitted by LLVM, not written by hand** —
`clang -target spirv64-unknown-unknown -S -emit-llvm` gives
`e-i64:64-v16:16-...-n8:16:32:64-G1`, exactly the "query LLVM/Clang" method the
guide recommends. Given how many guessed constants have bitten this project,
that mattered.

The family's `warp_size=64` carries a caveat in its own docstring: Vulkan says
64, but OpenCL's preferred multiple comes back per-kernel as 64 **or** 128 on
this device. It is not a device constant, and kernels that care must query.

### The gap that stops this compiling today

`info.mojo` carries a SYNC comment: the canonical target list must match
"the TargetTraits accelerator tables in `KGEN/lib/Target/`". Those tables are
**not in the published KGEN** — `grep` for `apple-m4` or `gfx942` across all of
`KGEN/**/*.{cpp,h,td}` finds only help text in `TargetOptions.td`.
`TargetTraits.h` declares the interface (`supportedAcceleratorArchs()` returning
`ArrayRef<AcceleratorArch>`), but the per-target subclasses that populate it are
absent.

So the stdlib now describes Adreno correctly, and the compiler will still reject
`--target-accelerator=adreno-x1` until that table is reachable. **That is the
next real obstacle, and it is a fresh instance of the same compile-side-open /
run-side-closed split — except this time it is the accelerator registry.**

Worth being precise: this does not block the runtime, which is done and tested.
It blocks *Mojo-authored* kernels reaching it. Hand-written OpenCL C already
runs through the same ABI today.

### Next

Find where `supportedAcceleratorArchs()` is populated — a generated file, an
unpublished subclass, or something reachable from `MAttrs.td`. That determines
whether Mojo can be taught a new accelerator at all, and it is the single most
important open question for this objective.

---

## 2026-08-19 — correction: the accelerator list is NOT fixed in closed code

Challenged on the W3 conclusion that Mojo's GPU targets are gated by
unpublished KGEN tables. **The challenge was right. The claim was wrong.**
Re-traced the whole path with the flag in hand this time, not one grep.

### How `--target-accelerator` actually flows

1. `Compilation.cpp:497` — the flag is read with `getLastArgValue` and stored
   **verbatim**: `compilationOptions.targetAccelerator = targetAccelerator.str()`.
   The only checks are "exactly one" and non-empty. **No table lookup.**
2. `IREvaluator.cpp:183` — `POC::AcceleratorArch` returns
   `StringAttr::get(elaborator->options.targetAccelerator)`. So the stdlib's
   `_accelerator_arch()` receives the *flag string verbatim*.
3. Validation happens **in the stdlib**, at comptime, in
   `_get_info_from_target`'s constraint against `_all_targets` — the exact
   file W3 already edited. Adding `"adreno-x1"` there was not cosmetic; it was
   the actual gate.

The `supportedAcceleratorArchs()` tables I called load-bearing feed exactly one
thing: `printSupportedAccelerators()`, the help text behind
`--print-supported-accelerators`. The SYNC comment keeps *help output* in sync
with the stdlib list. Modular's per-vendor tables are indeed not published, but
they gate nothing — they print.

### The two real gates, both open

**Gate 1 — `isMaxInstalled()`** (`TargetTraits.cpp` fatal-errors "please
install MAX for accelerator support" on any accelerator request without it).
Read the implementation, `Support/lib/Configuration.cpp:663`: it checks config
key `max.lib_path`, then `max.package_root` for `lib/libmax.so` — and if **no
config value exists at all**:

```cpp
// No value, so probably in bazel, pretend we have MAX.
return true;
```

Default is TRUE. In a bazel-driven build — which WINMOJO is — the gate passes
by itself. (Also note the probe hardcodes `.so`/`.dylib`; it has never met
Windows.)

**Gate 2 — the per-triple registries.** A `spirv64-unknown-unknown` module
needs traits/lowering/backend that resolve its triple, or
`TargetTraitsRegistry::lookup` errors "target not supported by this build".
There are three registries, and each has a **complete open implementation as a
template**:

| Registry | Open template | Size |
|---|---|---|
| `TargetTraitsRegistry` | `Target/Host/HostTraits.{h,cpp}` | ~40 lines |
| `TargetLoweringRegistry` | `KGENToLLVM/Target/Host/HostLowering.cpp` | small |
| `TargetBackendRegistry` | `ObjectCompiler/Target/Host/HostBackend.cpp` | small |

`HostTraits.matches()` claims x86/aarch64/arm/riscv; a `SpirvTraits` claiming
`triple.isSPIRV()` is the same shape. And the LLVM backend list is
`bazel/public-patches/llvm_project.bzl`:

```python
BACKENDS = ["AArch64", "RISCV", "X86"]
```

— a plain list with an `extra_targets` module hook already provided. Adding
`"SPIRV"` is one line, and LLVM 22 carries the SPIR-V backend in-tree.

### What Modular's MAX gate is actually about

Their GPU support ships as prebuilt libraries with the MAX package
(`libNVPTX.so` in the wheel, linux-only — seen in
`modular_wheel_repository.bzl`). "Install MAX for accelerator support" means
*their* closed traits/backends arrive with the wheel. The extension points those
plug into are open, and nothing about them is vendor-locked.

### Revised path to `mojo build --target-accelerator=adreno-x1`

1. stdlib target + plugin — **done (W3)**
2. `"SPIRV"` in the BACKENDS list — one line
3. `SpirvTraits` + `SpirvLowering` + `SpirvBackend` modeled on the Host trio,
   registered alongside it — bounded, all-open work
4. `isMaxInstalled` — expected to pass by default under bazel; verify, patch
   in-fork only if it doesn't

Blocked on nothing except WINMOJO's G3–G6 producing a building compiler to put
this into. The W3 journal entry's "next real obstacle" framing is retired.

The recurring lesson, fourth instance: one grep is a hypothesis, not a finding.
The difference this time is it got challenged before it shaped a plan.

---

## 2026-08-19 — the SPIR-V trio: KGEN taught to emit for Adreno

W3's compiler half, written and wired. Three registries, three implementations,
modeled line-for-line on the open Host trio:

| File | Registry | Job |
|---|---|---|
| `KGEN/lib/Target/Spirv/SpirvTraits.{h,cpp}` | `TargetTraitsRegistry` | triple match (`isSPIRV()`), extensions (`.spvasm`/`.spv.ll`/`.spv`), accelerator table entry `adreno-x1` |
| `KGEN/lib/KGENToLLVM/Target/Spirv/SpirvLowering.cpp` | `TargetLoweringRegistry` | kernel marking |
| `KGEN/lib/Compiler/ObjectCompiler/Target/Spirv/SpirvBackend.{h,cpp}` | `TargetBackendRegistry` | llc → SPIR-V module emission |

Plus one line: `"SPIRV"` in `BACKENDS` (`bazel/public-patches/llvm_project.bzl`),
verified against the LLVM bazel overlay's own target list before adding —
`configure.bzl:23` lists SPIRV and the overlay carries full build rules for it.

**Zero KGEN/BUILD.bazel edits needed.** All three library rules glob
`Target/**/*.cpp` and are `alwayslink = True`, so a source file dropped into
the right directory compiles in and its static-initializer registration
survives the linker. "Targets are dropped from a build by omitting their
source" — the registration design in TargetTraits.h — works in both directions.

### Design decisions worth defending later

**Kernel entry points are marked with the `SPIR_KERNEL` calling convention.**
The LLVM SPIR-V backend recognizes kernels by CConv and emits `OpEntryPoint`
for them. Miss this and a kernel lowers as a plain function, the driver finds
no entry point, and the failure surfaces as `clCreateKernel` failing at load
time — nowhere near the actual mistake. `markExportedKernel` sets it,
`isExportedKernel` reads it back.

**`emitObject` returns the `.spv` directly and never calls `ctx.linkObject`.**
HostBackend links each object into the host image; a SPIR-V module inside the
host `.so` would load as garbage. The module *is* the deliverable — the
DragonMax runtime's `loadFunction` sniffs the magic and hands it to
`clCreateProgramWithIL`. The backend validates the magic on emission with an
error that points at the BACKENDS list, so a misconfigured LLVM build fails at
compile time with a named cause instead of at kernel-load time inside the
driver.

**`isBaseTarget() = true`, stated plainly in the header.** The MAX gate exists
to require Modular's binary distribution for the backends Modular ships inside
it. This trio is compiled from source in this repository; there is no package
whose absence could invalidate it. The closed piece in our chain is Qualcomm's
driver compiler consuming the SPIR-V at load time — a driver boundary, the same
one every GPU vendor imposes, not a withheld runtime.

**`SplitStrategy::None`.** The driver compiler consumes whole modules; there is
no MCLinker step for `.spv`, so per-function splitting would only multiply
driver compilations. Shared memory is addrspace(3) (Workgroup, same numbering
as NVPTX/AMDGPU). Sanitizers are dropped device-side.

### A gitignore trap that nearly ate the whole thing

`git status` showed the five new files as... nothing. `.gitignore:69` has a
bare `target/` — a Rust build-dir rule — and on this case-insensitive
filesystem it swallows **every `Target/` source directory in KGEN**. The Host
files are only visible because upstream tracked them before the rule could
bite; any *new* file under a `Target/` dir silently vanishes from commits.
Fixed with re-include rules at the bottom of `.gitignore` rather than
`git add -f`, so the next person does not hit it.

### Verification status, stated honestly

None of this has compiled — it cannot until WINMOJO's G3 delivers a building
KGEN on this machine. Written against the real interfaces (all three read in
full) and the real LLVM overlay, but the first compile will adjudicate:

- the `mlir::LLVM::cconv::CConv` spelling (the enum case is confirmed in
  `LLVMEnums.td`; the generated namespace is from memory — the vendored LLVM
  tree in bazel's output base vanished mid-read, ephemeral by design)
- the exact `WriteableBuffer`/`BufferRef` idioms mirrored from HostBackend
- whether the offload flow expects anything beyond `emitObject`'s buffer —
  how the `.spv` travels from ObjectCompiler into the Mojo-side `loadFunction`
  call is the next thing to trace once a compiler exists to trace it with

The full path, end to end, now reads: Mojo source → KGEN (`--target-accelerator
adreno-x1` → stdlib `AdrenoX1` target → SpirvLowering marks kernels →
SpirvBackend emits `.spv`) → `dragonrt.dll` (`loadFunction` →
`clCreateProgramWithIL`) → Qualcomm driver → Adreno silicon. Every arrow except
the last is open source in this repository.

---

## 2026-08-19 — offload flow traced; GPU line declared integration-ready

### The trace (full version in `dragon/design/OFFLOAD-FLOW.md`)

The question left open by the trio: what carries the `.spv` from
`SpirvBackend::emitObject` to the `loadFunction` call. Answer, with file:line
evidence — **comptime compilation, and nothing else**:

`DeviceFunction` picks `_emission_kind = "object"` for everything except
cross-compiled NVIDIA (`device_context.mojo:2796`) → `_compile_code` is the
`compile_info` comptime intrinsic (`compile.mojo:36`) → the elaborator invokes
`ObjectCompiler::emitOffloadKernels` (`ObjectCompiler.cpp:1811`), which splits
per exported kernel, tags each with `kgen.offload.kernelid` (:1486), and
dispatches by triple to the backend → our `emitObject` buffer lands in
`CompiledFunctionInfo.asm` (bytes, despite the name — `loadFunction` passes
`asm.byte_length()`) → `AsyncRT_DeviceContext_loadFunction` → dragonrt sniffs
the magic → `clCreateProgramWithIL` → driver → silicon.

**No packaging step exists to build.** The `.spv` never meets a linker or the
host image. `emitObject` returning the raw buffer was the right call, and the
kernel's name survives to `clCreateKernel` because SPIR_KERNEL marking makes
the LLVM function name the OpEntryPoint name.

Also settled: only NVIDIA-cross uses `"asm"`, so the stdlib default already
routes Adreno down the object path — no stdlib change needed there.

### The decision

**The GPU compile line is code-complete and available for WINMOJO to
integrate.** Declared in `dragon/HANDOFF.md`, which is now the contract:

- **Finish line, made executable:** `dragon/mojo-tests/adreno_saxpy.mojo` —
  standard Mojo, nothing DragonMax-specific, passes ⇒ done. Two cheaper early
  checks: `--print-supported-accelerators` shows the Adreno section (proves
  registration survived linking), and `--emit=asm` yields SPIR-V assembly
  (proves codegen without the runtime).
- **First-compile checklist** — the only items that can bounce back to us:
  the `cconv` namespace spelling, the Buffer idioms, glob/alwayslink pickup,
  and SPIRV-backend-on-Windows-host. Each has a named, bounded fix.
- **One decision deliberately left to WINMOJO:** how the built executable
  finds `AsyncRT_*` — link `dragonrt.lib` alongside their AsyncRT (symbol sets
  are disjoint by construction), or delay-load the DLL. Sequencing-sensitive
  with their G4/G5, so it is theirs.

Not in the handoff: the NPU/QNN line (runs today without `mojo.exe`), runtime
hardening, kernels. Those stay here.

The ladder in `DRAGONMAX.md` now reads: D0–D3 done, W1–W3 done, **HANDOFF
declared**, GPU GOAL = the acceptance test, blocked only on WINMOJO G3+.

---

## 2026-08-19 — the MAX license, read properly: the trap was real, then it moved

Suspicion raised: the Community License is a commercial-use trap. Verdict from
reading all three instruments (full analysis with verbatim quotes in
`dragon/design/LICENSE-ANALYSIS.md`): **confirmed — and the copy in this repo
is the smoking gun.**

`Licenses/LICENSE` here (from upstream `f66d4d5`) is dated **Aug 17, 2026**
and contains: a preamble binding anyone "developing software using... [the]
Mojo programming language"; a non-compete on developing Mojo applications; an
**8-accelerator cap on commercial use for anything that is not an x86/ARM CPU
or NVIDIA hardware** — Snapdragon's Adreno and Hexagon are exactly the
monetised class; and a clause requiring Modular's written permission to run
distributed apps on hardware MAX does not expressly support.

**One day later — Aug 18 — the website version removed every one of those.**
Their own FAQ admits it: "The old license capped free production use at eight
accelerators outside x86, ARM and NVIDIA... Both requirements are now gone."
Our tree carries the stale, harsher text; the fork happened the day after the
correction.

The replacement trap is aimed at AI-assisted reimplementation: new §1.3 (no
using MAX as AI input "to produce software that reimplements or substitutes
for MAX") and the ToU's "AI-Derived Work" definition, which sweeps in
"translations, ports, transpilations, refactorings" and asserts clean-room
separation is no exemption if Modular IP was "input, reference, or
inspiration". Aimed, in other words, at the genus this project belongs to.

Why it does not reach us, on the facts: those instruments bind on *using their
SDK binaries or hosted platform*, and this project has never done either — no
account, no wheel, no prebuilt toolchain (impossible on Windows anyway).
Everything here descends from per-file Apache-licensed source, whose grant the
new Community License itself concedes "controls... in the event of any
conflict". Even the new §1.3 carves out "develop[ing] Your own software that
runs on or interoperates with MAX".

**Bright-line rule adopted:** no Modular binaries, wheels, or accounts in this
project or WINMOJO, ever. Costs nothing — everything measured this week was
done without them — and keeps the entire stack on the Apache grant, where the
AI clauses do not exist.

Also flagged: trademarks are a separate axis ("maxdragon" leads with their
mark; cheap to rename if this grows commercial weight), and Qualcomm's QAIRT
LICENSE.pdf is the document to read before the NPU line ever ships Qnn DLLs.

---

## 2026-08-19 — DEBAZEL: the design and sprint to excise Bazel (design only)

Directive: get rid of Bazel, replace with something simple and fast; design
and sprint first, no implementation. Done — `dragon/design/DEBAZEL.md`.

The audit that grounds it: **619 BUILD.bazel files** (391 in `max/`, irrelevant
to `mojo.exe`), **40,897 lines** of `.bzl` under `bazel/`, ~25 external deps of
which most are CI-shaped (rules_js/ts, gazelle, buildifier, mypy, otel, grpc),
and the 115 GB output tree. Against that, the actual build of mojo.exe reduces
to three jobs: LLVM+MLIR from source (rarely), **31 gentbl rules**, and ~700
C++ files plus one stdlib packaging step.

Modular's own `why-bazel.md` was read first and answered on its merits: every
benefit it lists (hermetic vendored toolchains, remote execution, shared
cache, multi-language at org scale) accrues to Modular's infrastructure, none
of which reaches this machine — the vendored toolchain doesn't even exist for
Windows ARM64, which is why WINMOJO had to write one. Their cost-benefit, our
costs.

The load-bearing design idea: **use Bazel once, to escape Bazel.** The BUILD
files are a machine-readable spec, and `bazel aquery --output=jsonproto` emits
the entire action graph with literal command lines. A ~250-line translator
turns that into a checked-in `build.ninja`, so the first non-Bazel build is
command-identical to the Bazel one — parity by construction. LLVM itself
moves to a frozen CMake/Ninja prefix built once (its native build system).
Endgame: a small owned generator replaces the export; Bazel's engine is
deleted; the 619 BUILD files stay as inert fossils so upstream rebases don't
become six hundred merge conflicts.

Sprint: **B0** ground truth (aquery counts) → **B1** frozen LLVM prefix
(independently useful — it's also the SDK for the BCPL/BASIC offload ideas) →
**B2** exporter → **B3 parity gate** (ninja-built mojo.exe passes the same lit
subset; nothing is deleted before this passes twice) → **B4** re-point +
stdlib + lit → **B5** owned generator → **B6** excision, 115 GB reclaimed.
B0–B2 need only an *analysable* Bazel, which WINMOJO's G3 already achieved —
the ladder can start before KGEN builds.

Not started, per instruction. The go decision is the user's.

---

## 2026-08-19 — first compile verdict in; the IL assumption fires; Route 2 landed

The compiler team's field report: **the trio compiled unmodified** — all four
bounce-back risks silent — `mojo build --target-accelerator adreno-x1` emits
real SPIR-V, dragonrt links and runs, and kernel load dies because **the
native QUALCOMM driver cannot ingest SPIR-V at all**. Empty
`CL_DEVICE_IL_VERSION`, no `cl_khr_il_program`. The fifth unmeasured
assumption of this project, and this one was mine: the 30-second IL query was
never run. OpenCL 3.0 makes IL optional, and Qualcomm opted out.

Verified independently and extended (`dragon/probe/probe_adreno_spirv.py`),
including the question nobody had answered — does OpenCLOn12 actually
*execute* kernel-flavor SPIR-V, or merely advertise it:

| Platform | IL advertised | Hand-encoded SPIR-V |
|---|---|---|
| QUALCOMM Snapdragon(TM) | none | — |
| OpenCLOn12 | SPIR-V_1.0 | **EXECUTES, verified (42 read back)** |

The probe hand-encodes a minimal OpenCL-flavor module (Physical64, Kernel,
`*p = 42`) so the test has no toolchain dependencies and the words are
auditable in the file.

Two traps found on the way, either of which would have broken a naive
"one strstr" Route 2:

1. **The loader's core `clCreateProgramWithIL` slot access-violates** (read at
   offset 0x38 in the dispatch) on an OpenCLOn12 context. Only the
   per-platform `clCreateProgramWithILKHR` pointer from
   `clGetExtensionFunctionAddressForPlatform` is safe.
2. **`clCreateContext(NULL props)` is ambiguous with two platforms installed**
   and returns null on On12. dragonrt had this latent bug since W2 — it worked
   on the native platform by luck. `CL_CONTEXT_PLATFORM` is now always passed.

### The decision (the team asked for our call)

**Route 2 now — and it is landed, not recommended.** dragonrt selects the
platform by IL *capability*: default prefers the SPIR-V-capable platform so
Mojo binaries work out of the box; `DRAGONRT_PREFER=native` pins the native
driver for source-only work (and for measuring the D3D12 tax). A future native
driver that gains IL wins automatically because native platforms sort first.
Both policies pass the full ABI test. The doctrine survives intact: selection
by platform capability, never by device name — the trench-coat platform turns
out to be the bridge, which is an irony we will simply have to live with.

**Route 3 (Vulkan) is the endgame, scoped honestly:** Vulkan consumes
shader-flavor SPIR-V; the backend emits kernel-flavor. The real item is a
compiler flavor flip plus a descriptor-set kernel ABI — compiler *and* runtime
work. Queued behind a green adreno_saxpy, prioritised by the tax measurement.

**Route 1 (emit OpenCL C) declined:** LLVM has no OpenCL-C backend; producing
compilable OpenCL C from post-elaboration LLVM IR is a transpiler project
wearing a small-change costume — the third such costume this week. Standing
invitation to the team: a concrete emission mechanism reverses this.

### Next measurement

The D3D12 tax: same kernel, both platforms, `DRAGONRT_PREFER` as the switch.
Its size decides how urgent Route 3 is. Then: adreno_saxpy should PASS.

---

## 2026-08-19 — review of the team's clCreateKernel bisect; dump hook landed

Their report reviewed and endorsed on method: the three-shape negative-space
bisect (444-char name / +BuiltIn WorkgroupId / real saxpy signature — all
callable when hand-built) is exactly the right move, and the
CL_PROGRAM_NUM_KERNELS false-lead warning is a keeper. "Route 2 half-works"
is the correct framing: ingestion fixed, kernel creation refused (-5).

### Review findings added to theirs

**-5 is not literally "out of resources".** On Mesa-derived CLOn12, per-kernel
lowering (SPIR-V → NIR → DXIL) happens at clCreateKernel time; an internal
lowering failure surfaces as CL_OUT_OF_RESOURCES with no build log. Read -5 as
"the translator choked on this kernel", which also makes NUM_KERNELS=0 partly
honest — zero kernels may genuinely have survived lowering for OUR module,
even though the query is also unreliable on hand-built ones. Both readings
coexist.

**Suspect ranking, from their list of five.** Promote the Constant-decorated
WorkgroupSize from "favourite" to prime suspect, for a sharper reason than
oddness: `OpDecorate BuiltIn WorkgroupSize` on an OpConstantComposite is the
**Vulkan spec-constant idiom** — GLCompute furniture. In kernel-flavor SPIR-V
the local size arrives either via OpExecutionMode LocalSize or the builtin
**Input variable**; a Constant-decorated builtin inside an OpenCL-flavor
module is a shape Mesa's CL ingestion path has no rail for. And even if it
were ingested, it *declares a fixed workgroup size* that will fight the
runtime-chosen block dims at every enqueue — a second failure waiting behind
the first. Likely origin: saxpy uses `block_dim.x`, and the team's new
`llvm.spv.*` index lowering presumably maps block_dim to WorkgroupSize — in
the constant form rather than the Input-variable form. If so the fix is in
their new lowering branch: emit the variable form.

Demote the rest with reasons: Int8 capability, ContractionOff, FuncParamAttr
NoWrite and the OpenCL.std import are all standard clang-emitted furniture
that CLOn12 digests daily from ordinary OpenCL C compilations (it passed 1.2
conformance full of them). Merely importing OpenCL.std is harmless; only an
exotic *instruction* from it would matter.

### Unblock landed

Their stated next step needs the emitted module, byte-exact. That capture
point is our runtime: **`DRAGONRT_DUMP_SPV=<dir>`** now writes every SPIR-V
blob loadFunction receives, before ingestion, named
`NNN_<kernelname-truncated>.spv` (mangled Mojo names run to hundreds of
characters). No compiler round-trip needed; the dump is literally what the
driver sees. Rebuilt, ABI test still ALL PASS, pushed.

Standing offer recorded: if they hand back a dumped module, our hand-encoder
knowledge is sufficient for a word-level stripper (the SPIR-V instruction
stream is trivially parseable) — progressive decoration-stripping without
needing SPIRV-Tools on this box.

Also: their broken-then-fixed push (escapes collapsed in transit) is the same
heredoc gremlin that bit this session twice today, including in the dump hook
itself (a path separator arrived over-escaped; now a forward slash, which the
CRT accepts). Sympathy extended; range after d05d899 is clean.

---

## 2026-08-20 — clCreateKernel -5: root cause found, verified, bridged

Their "interaction, not a feature" conclusion was reasonable and wrong in the
best way: it WAS a single feature — one that lives in the kernel's parameter
types, the only place a stripping bisect structurally cannot reach, and a
place every hand-built control module silently got right.

### The decode that settled it

`dragon/probe/spv_tool.py` (the promised stripper's front half: full annotated
decoder + structural checks) renders the 2,096-byte module completely. The
smoking lines:

```
%5 = OpTypeArray  i8 x 4
%6 = OpTypePointer Function %5            <-- the kernel argument type
%9 = OpTypeFunction void(%6, %6, %6, float)
```

**The kernel's three buffer arguments are Function-storage pointers** (to an
i8[4] placeholder — opaque-pointer residue). Kernel-flavor SPIR-V requires
kernel pointer args in CrossWorkgroup/Workgroup/UniformConstant/Generic;
Function storage is invalid as an argument and unmappable by clSetKernelArg.
Provenance is clean: Mojo's `UnsafePointer` carries LLVM addrspace(0), and the
LLVM SPIR-V backend maps AS0 → Function. The address space was lost at the
kernel boundary. Every hand-built probe used CrossWorkgroup, as anyone
hand-writing a kernel would — which is exactly why five shapes passed.

### The experiment

| Module | create | launch | verify |
|---|---|---|---|
| original (their capture, byte-exact) | **-5** | — | — |
| same module, TWO WORDS changed (`Function`→`CrossWorkgroup` on the two `OpTypePointer`s) | ok | ok | **4096/4096 correct** |

That patched run is the first Mojo-compiled kernel to execute correctly on
this Adreno — 444-char mangled name, v3i32 builtins, OpBitcasts and all.
Which also settles two side-questions:

- **The v3i32 builtins are downgraded from suspect to note**: the verified
  output requires correct per-element global indices, so Mesa's builtin
  lowering handles the 32-bit form fine. Off-flavor, harmless.
- **CL_PROGRAM_NUM_KERNELS = 0 was half-honest all along**: a program whose
  only kernel has invalid parameters genuinely contains zero creatable
  kernels. (It also reads 0 for valid hand-built ones, so it stays useless as
  a diagnostic — but it wasn't lying about THIS module.)

### What landed

1. **`spv_tool.py`** — decoder + checks; a new rule flags Function-storage
   kernel params on sight, so this class of bug is now a one-command
   diagnosis. (Also fixed my own opcode table: 124 is OpBitcast; the 121–124
   block was off — their off-by-one confession had company.)
2. **`spv_run.py`** — step-by-step loader/launcher for any .spv via
   OpenCLOn12, with the entry name parsed from the module.
3. **The dragonrt bridge (TEMPORARY)**: `loadFunction` rewrites
   `OpTypePointer Function` → `CrossWorkgroup` in memory before ingestion.
   Guarded — skipped entirely if the module declares any Function-storage
   `OpVariable` (allocas share those types; today's kernels have none) —
   and `DRAGONRT_NO_SPV_FIXUP=1` disables. The dump hook fires BEFORE the
   bridge, so captured modules stay pristine. Delete when the compiler fix
   lands.
4. **ABI-layer proof**: `test_dragonrt.exe <module.spv>` now drives a real
   module through `loadFunction` exactly as a Mojo binary does. The original,
   unpatched capture: loadFunction ok, launch ok, **all 4096 verified**.

### The compiler fix (theirs, precisely aimed)

Kernel pointer parameters must reach the SPIR-V backend as **addrspace(1)**.
The LLVM SPIR-V mapping is AS0→Function, AS1→CrossWorkgroup, AS4→Generic; the
kernel-argument lowering (the same new path that marks SPIR_KERNEL and lowers
`llvm.spv.*`) should force AS1 on pointer params for the spirv triple. When
that lands, the bridge becomes dead code and should be deleted.

Expected on their side after merging: their existing built binary re-run =
**adreno_saxpy PASS**.

---

## 2026-08-20 — SG4 green: `mojo build --target-accelerator adreno-x1` PASSES

```
PASS: all 4096 elements correct on Qualcomm(R) Adreno(TM) X1-45 GPU
```

That is the unmodified acceptance test, compiled by this tree's compiler,
launched through dragonrt, with `DRAGONRT_NO_SPV_FIXUP=1` — no bridge, no
patched module, no hand-holding. The bridge is deleted, per its own comment.

Their root cause held exactly as stated, and landing the compiler fix
uncovered three more bugs stacked behind it, each invisible until the one
above it was gone. The stack, in the order it peeled:

### 1. The compiler fix: `SpirvKernelArgAddressSpace` (KGENToLLVM)

A late MLIR pass on the LLVM dialect, contributed by `SpirvLowering` through
`addPostLowerToLLVMPasses` — not inside `markExportedKernel`, which fires
during signature conversion, before a body exists to rewrite alongside it.
It promotes addrspace(0) pointer params of `SPIR_KERNEL` functions to
addrspace(1) and propagates through the derived GEP/bitcast closure.
Conservative on purpose: it scans the full use closure first and refuses
wholesale — with a warning naming the offending op — rather than
half-promote, because one access in the wrong space is exactly the bug class
being removed. `spv_tool.py` on the fresh dump confirms:

```
%6 = OpTypePointer CrossWorkgroup %5
kernel param 0..2: pointer, storage CrossWorkgroup
```

### 2. `clSetKernelArg(3, size=8) failed: -51` — argSizes never arrived

With create/launch unblocked, the scalar argument failed: dragonrt received
`argSizes=NULL` and guessed pointer-sized for the float. Two causes, both in
the max package's launch paths:

- **`Optional[Pointer]` does not cross `external_call` as a pointer.** It is
  niche-optimised to one field, but it still lowers as
  `!kgen.struct<(struct<(struct<(pointer<none>) memoryOnly>)>)>` and is
  passed indirectly — the callee reads garbage-or-null. Both
  `enqueueFunctionDirect` bindings now pass
  `Int(arg_sizes.value()) if arg_sizes else 0`: one register, null for None.
  (Proved with a temporary `DragonRT_ProbePointer` export, since deleted;
  the compile-time diagnostic that settled it — "existing function with
  conflicting signature ... memoryOnly" — is recorded in DIALECT-NOTES.)
- **`_call_with_pack_checked` never built a sizes array at all** — it passed
  `Optional[...]()`  where the unchecked path allocates and fills one. It now
  allocates `dense_args_sizes`, records each translated argument's DEVICE
  size (unaligned — `clSetKernelArg` wants the argument's width, not its
  padded stride in the staging buffer), and hands the compaction helper the
  same array so surviving captures keep their sizes.

`DRAGONRT_TRACE_ARGS=1` (kept, in dragonrt) now shows `8 8 8 4`.

### 3. Kernel ran, 4071/4096 wrong — transfers were never coherent

The index probe cleared the obvious suspect: every work-item computes the
right index (`block_idx`/`block_dim`/`thread_idx` all correct, zero holes),
so the off-flavor v3i32 builtins are confirmed harmless a second way. A
passthrough kernel (`dst = x`) then failed the same way saxpy did, which
moved the fault below the arithmetic: the kernel reads garbage.

The H2D copies were arriving (`DRAGONRT_TRACE_COPY=1`, kept, shows correct
mem/hostPtr/bytes on every call) and `clEnqueueWriteBuffer` returned
CL_SUCCESS. But on OpenCLOn12, measured today:

- a `CL_FALSE` WriteBuffer followed by an NDRange **on the same in-order
  queue** hands the kernel stale data — the ordering guarantee is not
  honoured for the write's visibility;
- and even with `clFinish` between them, **the first 16 bytes** of the
  destination arrive corrupted, deterministically.

Nobody had ever seen this because nothing before today both wrote a buffer
from the host and then read it in a kernel: test_dragonrt's HtoD calls have
a whole program-compile between copy and launch, and the index probe only
ever read back what its own kernel wrote. A kernel-free H2D→D2H echo made
it visible in one run: first four floats garbage, 4092 correct.

Every host-touching transfer in dragonrt is now blocking (`CL_TRUE`). The
`_async` ABI contract is still honoured — the caller synchronizes before
reading results — so this trades copy/compute overlap we were not using for
correctness. When overlap matters, the right fix is events, not CL_FALSE.

### The ledger

- saxpy, index probe, and the copy-echo/passthrough/saxpy debug harness all
  report 0 of 4096 wrong, bridge deleted, no env vars.
- `adreno_index_probe.mojo` and `adreno_saxpy_debug.mojo` stay in
  examples/win32: one verifies the index layer, the other the transfer
  layer, and today proved those are exactly the two layers that fail
  independently.
- `examples/win32/build.sh` now finds the max package and dragonrt.lib
  itself; `mojo build --target-accelerator adreno-x1 X.mojo` is one command.
- Still open, GPU team's side: `bazelw test //dragon/runtime:test_dragonrt`
  fails with "cannot load dragonrt.dll (126)" — the test LoadLibrary's a DLL
  the Bazel target does not produce (it builds a static .lib). Their
  workflow evidently builds the DLL out of band; either a `cc_binary`
  linkshared target or a static-link variant of the test would make it run
  under Bazel.
- Two trace switches stay: `DRAGONRT_TRACE_ARGS`, `DRAGONRT_TRACE_COPY`.
  Both are one `getenv` on a cold path.

---

## 2026-08-20 — Mandelbrot: the first Mojo program worth watching on the Adreno

`examples/win32/adreno_mandelbrot.mojo`. A window opens and zooms into
seahorse valley; every pixel of every frame is computed by a Mojo kernel
compiled to SPIR-V and executed on the Adreno. Direct3D is reduced to a
texture upload and a fullscreen triangle, and the only HLSL left is the
colour ramp. The Julia demo's "cheating with a shader" era is closed the
right way round: the GPU language is Mojo now.

Numbers, 960x720 at 512 max iterations (73M iterations/frame mean):

| | per frame |
|---|---|
| Adreno X1-45, Mojo kernel via OpenCLOn12, incl. readback | **11-13 ms** |
| Oryon, one core, identical scalar Mojo | 250 ms |

~20x against a single scalar core, sustained while animating — and this
kernel is the shape saxpy never tested: a data-dependent `while` whose trip
count varies 1..512 per work-item, wavefront divergence, structured control
flow. One writing lesson: SPIR-V wants ONE loop exit; the kernel keeps the
escape test in the loop condition rather than `break`ing from the body.

### What "the same answer" means for a chaotic function

The demo verifies GPU against CPU before opening the window, and demanding
bit-exactness would have been wrong. Of 691,200 pixels, 1,713 differ — every
one either high-count (near the set, where a one-ulp FMA difference
amplifies every iteration; the CPU holds a filament pixel to 512 while the
GPU honestly escapes it at 450) or a ±1 flip at the escape radius. The
check therefore demands exactness only where chaos cannot excuse anything:
pixels with low CPU count (<256), locally flat neighbourhood, delta > 1.
**Zero of those** — and a real codegen bug would light that region up,
because wrong arithmetic is wrong everywhere, including the far field.

First cut of the check was stricter (any smooth-neighbourhood mismatch) and
aborted the program on 4 filament pixels before the window opened — worth
recording because "the window closed straight away" was the entire symptom,
and the cause was a too-honest assertion three layers below.

### Two loose ends found and fixed on the way

- **build.sh resolved `external` through the execroot**, which is a symlink
  forest containing only what the last build touched — winkb vanished from
  it the moment a build didn't use the DB. Now resolved via the output base,
  where the real store lives.
- **`std.windows` gained `read_file`/`write_file`** (CreateFileW/ReadFile/
  WriteFile, byte-exact, short-read/short-write loops) — written for the
  console version of this demo, kept because the stdlib had no way to write
  a binary file: Mojo's `open()` rejects `"wb"`, and a text-mode writer
  would turn every 0x0A into 0x0D 0x0A. The tour now round-trips all 256
  byte values through the temp directory.
