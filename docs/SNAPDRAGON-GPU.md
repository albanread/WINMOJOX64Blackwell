# Snapdragon GPU integration: the WINMOJO-side design

DragonMax declared HANDOFF on 2026-08-19: a complete Adreno GPU line —
SPIR-V backend trio in KGEN, stdlib target entries, a device runtime proven
on hardware — with a six-checkbox runbook
([`INTEGRATEME.md`](../../DRAGONMAX/INTEGRATEME.md)) whose finish line is
standard Mojo saxpy printing PASS on the X1-45. The Julia demo reached the
Adreno by handing HLSL to Direct3D; this is the honest version: **Mojo
compiles the kernel**, and the same `DeviceContext` code people write for
NVIDIA runs on this machine's silicon.

The runbook was written against WINMOJO at `dde8f83` (our G3). We are ~100
commits past that, and everything below is the reconciliation: what transfers
unchanged, what has drifted, and the decisions that are ours to make. This
document is the design; the runbook remains the execution script wherever the
two agree.

## What we verified before designing

Merge surface, checked against today's tree:

- **No conflicts expected.** We have zero commits touching
  `mojo/stdlib/std/gpu/`; their KGEN additions are three new `Target/Spirv/`
  directories; they made no BUILD edits; our sqlite/toolchain work touches
  none of their files. `.gitignore` line 69 has the bare `target/` rule their
  re-include hunk defuses — keep the hunk, exactly as the runbook warns.
- **The glob-and-alwayslink assumption is *three-quarters* true.**
  `lib/Target/**` (rule at KGEN/BUILD.bazel:1102, alwayslink) and
  `lib/KGENToLLVM/Target/**` (1130, alwayslink) will absorb their files and
  keep the self-registration alive. But the ObjectCompiler glob at :1341
  belongs to a rule whose alwayslink status must be confirmed — the Host
  backend got its own `alwayslink = True` rule (:1302) precisely because the
  parent may strip registrars. **Expect bounce-back #3**, and the fix the
  runbook names: a `:SpirvBackend` rule shaped like `:HostBackend`. That is
  one BUILD edit, contradicting the runbook's "zero," and it is fine.
- **`dragonrt.dll` dynamically loads `OpenCL.dll`** (no import lib needed)
  and carries ~10 allocation sites. Whether any allocation crosses the ABI
  is not audited; our CRT doctrine makes the question moot — see D2.

## The deltas the runbook cannot know

1. **The acceptance test does not compile in our dialect.**
   `adreno_saxpy.mojo` uses `fn` (a hard error here) and imports
   `from max.gpu.host` (the `max.*` namespace is out of scope and unbuilt;
   our tree's GPU API is `std.gpu.host`). The runbook anticipated this —
   "the *shape* is the contract, not the spellings" — so the port is ours:
   `fn`→`def`, `max.gpu.host`→`std.gpu.host`, and whatever
   [DIALECT-NOTES.md](DIALECT-NOTES.md) says when it fights back. The ported
   test lands in `examples/win32/` beside the others, plus a Bazel
   `mojo_test` gated on the existing `//:has_gpu` constraint so the CPU
   census never waits on a GPU.

2. **Adding `"SPIRV"` to `BACKENDS` re-keys the LLVM build.** The backends
   list feeds `llvm_configure`; changing it invalidates the LLVM action
   graph — roughly 8,000 actions, the never-build-LLVM-again journal entry's
   whole subject. The disk cache will absorb the unchanged majority, but
   budget **an hour-class rebuild once**, and do the merge when that is
   acceptable. This is also bounce-back #4's home: the SPIRV backend has
   never been built by this toolchain on this host. Highest-risk single item
   in the plan.

3. **Their runtime build violates our CRT invariant.** The runbook builds
   `dragonrt.dll` with `cl /LD` and no `/MD`, which defaults to the static
   CRT. This port's hardest bug established the law: every module in the
   process shares one ucrtbase heap, no exceptions
   (`-fms-runtime-lib=dll`). Even if no allocation crosses the ABI today,
   we do not ship a module that breaks the invariant. Decision D2.

4. **Our linking story is richer than the one they wrote against.** Since
   G3 we grew: `mojo build` linking via `lld-link` with explicit inputs
   (the machine-type and oldnames fixes in `mojo-build.cpp`), the
   rules_mojo patch materializing dependency DLLs beside test binaries,
   `Win32Module` for process-lifetime DLL loading, and a toolchain-input
   pattern (winkb) for shipping files beside the compiler. All four slot
   directly into their Step 5.

## Decisions

**D1 — take the merge, not cherry-picks.** `git remote add dragonmax
C:/projects/DRAGONMAX && git fetch && git merge dragonmax/main`. The
conflict surface is near-nil, the commits are ordered, and a remote keeps
future DragonMax fixes one fetch away. Their `dragon/` tree rides along
off the build path; harmless, and the NPU line will want it later.

**D2 — `dragonrt` becomes a first-class Bazel target.** A
`modular_shared_library` beside `KGENCompilerRTShared`, built by the
hermetic clang with the dynamic CRT, replacing the `cl /LD` recipe. Its
smoke test (`test_dragonrt`) becomes a `cc_test` tagged `gpu`. This kills
the CRT question, gives the DLL our toolchain's provenance, and lets the
existing DLL-materialization machinery put it beside test binaries. The
source is 612 lines of C++ with no build-time deps (OpenCL is
`LoadLibraryA`'d), so the port is a BUILD file, not a porting job.

**D3 — linking is Option A through `mojo-build.cpp`, with B as the test
fallback.** The import library joins the Windows link block in
`mojo-build.cpp` exactly as `oldnames.lib` did — unconditionally; an
unreferenced import lib costs nothing, and conditioning the link on the
target would put policy in two places. `dragonrt.dll` ships beside
`mojo.exe` the way `KGENCompilerRTShared.dll` already does. Option B
(`Win32Module("dragonrt.dll")` before first use) stays documented for any
context where the import lib is awkward — we built that mechanism this
week and it is exactly delay-load.

**D4 — the acceptance test is ported, not patched around.** The dialect
port of `adreno_saxpy.mojo` is small, ours, and becomes the repo's example
of standard Mojo GPU code (`examples/win32/adreno_saxpy.mojo`). PASS on
hardware is the finish line, per the HANDOFF contract, and the human
camera rule applies: the number check *is* the camera here — every element
verified against the host.

**D5 — the NPU line is explicitly out of this design.** DragonMax's own
measurements say the Hexagon pays off only as an AOT graph target
(35.6 tok/s NPU-native vs 13.8 offloaded); that is a graph-compiler
integration, not a device backend, and it continues in DragonMax as W4.
Nothing here forecloses it; `dragon/` merges in regardless.

## The ladder

House rules: each gate has evidence, the census stays green, journal over
chat.

| Gate | Deliverable | Evidence |
|---|---|---|
| **SG0** | Merge landed; `.gitignore` hunk and `BACKENDS` line intact; tree still builds *without* the SPIRV rebuild being wasted — do SG0+SG1 in one sitting | `git log` shows dragonmax commits; `bazelw build //KGEN/tools/mojo:mojo` green |
| **SG1** | LLVM+SPIRV builds; KGEN's Spirv trio compiles (bounce-backs 1–3 burned down; `:SpirvBackend` alwayslink rule if needed) | full build green; census unchanged vs pre-merge |
| **SG2** | Registration + codegen: accelerator listed, SPIR-V emitted | `--print-supported-accelerators` shows Adreno; `--emit=asm` on the ported test yields `OpEntryPoint` |
| **SG3** | `dragonrt` under Bazel (D2), linked (D3); runtime smoke passes | `test_dragonrt` PASS as a bazel test |
| **SG4** | **The finish line**: ported saxpy builds via `mojo build`, runs on the X1-45 | `PASS: all 4096 elements correct on Qualcomm(R) Adreno(TM) X1-45 GPU` |

SG2 needs no GPU and no runtime; SG3 needs no compiler. They parallelize if
SG1 drags.

## Risk register

| Risk | Standing | Mitigation |
|---|---|---|
| SPIRV backend fails to build here (bounce-back 4) | **highest**; unproven toolchain/target combo | triage in `llvm_project.bzl`; DragonMax pre-triaged; same-day contract |
| The three Spirv sources hit API drift (bounce-backs 1–2) | expected, mechanical | fixes are named in the runbook; re-mirror from our tree |
| ObjectCompiler glob lacks alwayslink (bounce-back 3) | **likely**, verified plausible at :1341 | the `:HostBackend`-shaped rule; one BUILD edit |
| Dialect drift inside `DeviceContext`/stdlib GPU path deeper than the test | unknown until SG2 | our dialect notes + the stdlib-is-the-reference rule |
| `enqueue_*` API shape moved since fork | anticipated by handoff | port the call sites; shape is the contract |
| CRT mismatch via their cl recipe | eliminated by D2 | bazel build with `-fms-runtime-lib=dll` |
| Launch-dim widening / `.spv` "fixes" / warp_size assumptions | self-inflicted only | the runbook's do-not-improve list is law; copy it into the PR description |
| Census regression from merged stdlib edits | low; six sites in `info.mojo`, no overlap | SG1 evidence includes census diff |

## What this buys, said plainly

The Julia demo proved the *window*; this proves the *language*. After SG4,
the README's irony section needs a new paragraph: the machine Mojo does not
support runs Mojo kernels on its GPU, compiled by Mojo, launched by
`DeviceContext`, with no vendor SDK in the build and one driver boundary —
the same deal NVIDIA gets. The winkb metadata line and this one converge
later: a `d3djulia` whose pixel shader is a **Mojo kernel** instead of HLSL
is the demo that closes the "cheating" era, and after SG4 it is roughly a
weekend, not a project.

---

# Execution log: SG0-SG4, and where the line actually stops

SG0-SG3 are done. SG4 gets within one driver call of the finish line.

**SG0 - merge.** 23 `[dragonmax]` commits, one conflict (README; kept ours,
theirs being DragonMax's identity). Every invariant verified: `"SPIRV"` in
`BACKENDS`, the `.gitignore` re-includes, all three `Spirv/` source
directories, the stdlib target, the plugin, the runtime.

**SG1 - the rebuild, plus two build-system bugs of our own.** The predicted
LLVM re-key happened (7,352 actions, 2,033s). Neither failure along the way
was on DragonMax's bounce-back list:

- A transient: the first build raced the overlay re-materialisation.
- The real one. Re-fetching `@llvm-project` under our
  `--windows_enable_symlinks` turned the overlay from copies into **relative
  symlinks** (`llvm -> ..\+llvm_source+llvm-raw\llvm`). Windows resolves a
  relative symlink *lexically against the path traversed*, and actions reach
  the repo through `execroot/_main/external/`, where `..` finds nothing --
  because Bazel plants a repo into that forest only when one of its files is
  an action input, and nothing inputs raw LLVM sources; they are only symlink
  *targets*. Every hand probe passed (absolute paths resolve); only the
  action's relative path failed, on a different file each run as the action
  cache advanced. Fix: `@llvm-raw//:README.md` as data on the toolchain's
  resource-dir args, making one llvm-raw file an input to every compile.

Bounce-backs 1-3 never fired: their three source directories compiled
unmodified and the globs absorbed them, alwayslink intact.

**SG2 - registration and codegen, both green.**
`--print-supported-accelerators` lists `Qualcomm Adreno (DragonMax)`, and
`--emit=asm` produces a SPIR-V sidecar with `OpCapability Kernel`,
`OpEntryPoint Kernel`, and `BuiltIn WorkgroupId/WorkgroupSize/
LocalInvocationId`.

That needed work the handoff did not anticipate. `thread_idx`, `block_idx`
and `block_dim` dispatch on target inside `std/gpu/primitives/id.mojo`, and
the chain knew NVVM, AMDGCN and AIR only -- so the kernel failed to
instantiate before codegen ran. Added `is_spirv_gpu()` to
`std/sys/info.mojo` (and to `is_gpu()`, or every GPU-gated path treats
SPIR-V kernels as host code), plus three branches over
`llvm.spv.thread.id.in.group` / `llvm.spv.group.id` /
`llvm.spv.workgroup.size`. Shape difference worth noting: SPIR-V takes the
dimension as an *argument* (0/1/2) where the others suffix the name.

**SG3 - the runtime, under Bazel.** `//dragon/runtime:dragonrt` and its
smoke test build with the hermetic toolchain and the dynamic CRT, replacing
the `cl /LD` recipe (D2). The wheel remap in `bazel/api.bzl` -- which
upstream points at a prebuilt that does not exist for Windows ARM64 and that
our licensing line forbids anyway -- now resolves
`//MLRT:Driver/DeviceContext` to dragonrt. That is what made `//max:max_mojo`
build: the `max` Mojo package, 6,997 lines of `DeviceContext`, is already in
our dialect and needed no porting.

**SG4 - built, ran, stopped at the driver.** The ported test
(`examples/win32/adreno_saxpy.mojo`: `fn` to `def`, `out` to `dst` since
`out` is reserved, pointer spelling) compiles for `adreno-x1`, links against
`dragonrt.lib`, and runs. Two ABI drifts surfaced and were fixed in the
runtime:

- `AsyncRT_DeviceBuffer_context` did not exist; `ctx` was already in the
  struct, so it is a one-line accessor.
- Host/device copies now route through the single buffer-to-buffer entry
  point, where a host buffer arrives with `hostPtr` set and `mem` null.
  `DtoD_async` assumed two `cl_mem`s and died `CL_INVALID_MEM_OBJECT (-38)`.
  It now dispatches on shape across all four combinations.

## Where it stops, and why it is not a bug

```
clCreateProgramWithIL failed: -59   (CL_INVALID_OPERATION)
```

Probed live, both OpenCL platforms on this box:

| Platform | `CL_DEVICE_IL_VERSION` | `cl_khr_il_program` |
|---|---|---|
| QUALCOMM Snapdragon(TM) | *(empty)* | **no** |
| OpenCLOn12 | SPIR-V_1.0 | yes |

**Qualcomm's OpenCL driver on this device cannot ingest SPIR-V.** Not a
version mismatch, not a flag: the extension is absent and the IL version
string is empty, so `clCreateProgramWithIL` is required to fail. The compile
line is complete and correct -- Mojo emits valid SPIR-V for the Adreno --
but this driver will not accept that *form*.

Note the irony, since the handoff leaned on it: the OpenCLOn12 platform does
take SPIR-V, and it reaches the same GPU through D3D12. On this machine, the
path with IL support is the path the Julia demo used.

## The three ways forward

1. **Source hand-off.** Qualcomm's driver compiles OpenCL C
   (`clCreateProgramWithSource` -- DragonMax's D1b probe proved it, and
   dragonrt already uses it in its own smoke test). Emitting OpenCL C rather
   than SPIR-V from the same KGEN backend point keeps everything else. This
   is exactly the Apple-AIR trick DRAGONMAX.md cites: hand the vendor a form
   its driver accepts.
2. **SPIR-V through OpenCLOn12.** One `strstr` in `pickQualcomm`, and the
   existing pipeline may work unmodified -- but it routes through D3D12
   rather than the native driver, which the project would need to accept
   knowingly, and its performance on this part is unmeasured.
3. **Vulkan compute.** Vulkan on Adreno takes SPIR-V natively. Already
   DragonMax's own contingency (`adreno_vk`, "only if OpenCL's compiler
   disappoints"). It disappointed -- differently than expected.

Route 1 is the smallest change and the only one keeping the native driver.
Route 3 is the most robust and the most work.

---

# Postscript: SG4 is green

*(2026-08-20, superseding "where the line actually stops" above — the line
moved.)*

Route 2 (SPIR-V through OpenCLOn12) went from "may work unmodified" to
working, in four steps recorded fully in DRAGONMAX-JOURNAL.md:

1. `clCreateKernel -5` was Function-storage kernel pointer parameters — the
   GPU team's root cause, verified byte-for-byte. Fixed in the compiler:
   `SpirvKernelArgAddressSpace` promotes kernel pointer params to
   CrossWorkgroup on the spirv triple. Their temporary bridge in dragonrt is
   deleted, per its own comment.
2. `argSizes` never crossed the C boundary (`Optional[Pointer]` lowers as an
   indirect aggregate; the checked launch path never built the array at
   all). Both fixed in the max package's launch paths.
3. OpenCLOn12 does not honour in-order visibility for `CL_FALSE` host
   transfers, and corrupts the first 16 bytes even after `clFinish`. All
   host-touching transfers in dragonrt are now blocking.
4. `PASS: all 4096 elements correct on Qualcomm(R) Adreno(TM) X1-45 GPU` —
   the unmodified acceptance test, one command:
   `./examples/win32/build.sh adreno_saxpy --target-accelerator adreno-x1`.

Routes 1 and 3 stand unchanged as native-driver and performance options; what
changed is that they are no longer required for correctness.
