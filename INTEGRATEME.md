# INTEGRATE ME — Adreno GPU support for your Mojo port

You are the WINMOJO compiler team. This file is the entire integration, in
order, with copy-paste commands and a checklist at the end. It is shorter than
your last bazel log. Read all of it once; after that you never need the
background docs unless something breaks.

**What you get for following it:** `mojo build` targets the Snapdragon's
Adreno GPU, and ordinary Mojo GPU code — `DeviceContext`, `enqueue_function`,
the same code people write for NVIDIA — runs on this machine's silicon.

**What it costs you:** one merge, one linking decision, and running three
commands you were going to run anyway. Everything hard is already done and
committed. The GPU-side runtime is already proven on hardware — it ran kernels
today, without your compiler, and verified every output element.

---

## The 60-second version of how it works

1. Your compiler (KGEN), when asked for `--target-accelerator adreno-x1`,
   compiles each kernel to **SPIR-V** using LLVM's in-tree backend and a small
   backend trio we added to KGEN. You did not have to write it. It is written.
2. The compiler **embeds the SPIR-V bytes into the executable** as constant
   data. This is Modular's existing offload machinery; we changed nothing
   there and verified the path end to end with file:line receipts
   (`dragon/design/OFFLOAD-FLOW.md` if you enjoy receipts).
3. At runtime, the standard library hands those bytes to
   `AsyncRT_DeviceContext_loadFunction` — a C symbol implemented by our
   **`dragonrt.dll`**, which feeds them to Qualcomm's driver and launches on
   the GPU. Also already written, built, and passing a numerical test.

The only closed component in this chain is Qualcomm's driver compiler, which
is a normal driver boundary — the same deal every GPU vendor offers. Everything
else is source, in this repo.

---

## Step 0 — prerequisites (read this so you don't waste an afternoon)

- **You need your G3: a KGEN that builds on this machine.** Nothing below
  works before that, and nothing below is the reason it doesn't build.
- Native ARM64 toolchain, bazel via `./bazelw` — your existing setup.
- Do **not** start by reading the design docs. Start by merging.

## Step 1 — merge

```bash
git remote add dragonmax C:/projects/DRAGONMAX
git fetch dragonmax
git merge dragonmax/main
```

Prefer cherry-picking? Every relevant commit is prefixed `[dragonmax]`. Take
them all; they are ordered and self-contained.

**Merge notes, so nothing "helpful" happens:**

- `.gitignore` gained re-include rules at the bottom. The upstream file has a
  bare `target/` rule (meant for Rust build dirs) that, on case-insensitive
  filesystems, **silently eats every new file under KGEN's `Target/`
  directories**. Our hunk fixes that. If you drop it, your next backend file
  will vanish from `git status` and you will spend an hour confused. Keep it.
- `bazel/public-patches/llvm_project.bzl` gained one line: `"SPIRV"` in
  `BACKENDS`. That is what makes LLVM able to emit SPIR-V. Keep it.

## Step 2 — build

Build whatever you build for G3/G4. There is no new bazel target to learn:
the three new compiler source directories are picked up by **existing globs**
(`Target/**/*.cpp`) in **existing rules** that are already `alwayslink = True`,
so they compile in and self-register. Zero BUILD file edits were needed, and
zero are asked of you.

New compiler sources, for orientation only:

| Directory | What it is |
|---|---|
| `KGEN/lib/Target/Spirv/` | target metadata (triple match, file extensions, the `adreno-x1` arch entry) |
| `KGEN/lib/KGENToLLVM/Target/Spirv/` | marks kernels `SPIR_KERNEL` so they become SPIR-V entry points |
| `KGEN/lib/Compiler/ObjectCompiler/Target/Spirv/` | runs llc's SPIR-V backend, validates the output, returns the module |

Also merged, outside KGEN: the Adreno target in
`mojo/stdlib/std/gpu/host/info.mojo` (six edit sites), a 12-line
`std/_plugin/adreno/` plugin, and the `dragon/` directory (runtime, tests,
docs — none of it on your build path).

**This is the first time this code will ever be compiled.** It was written
against the real interfaces, all read in full, but four things can only be
proven by a compiler. If the build breaks in a `Spirv/` file, check the
bounce-back table at the bottom before debugging anything yourself — the fix
is probably listed, one line, and our fault not yours.

## Step 3 — smoke test #1: is it registered? (10 seconds)

```bash
mojo build --print-supported-accelerators
```

**Expected:** a section titled `Qualcomm Adreno (DragonMax)` listing
`adreno-x1`.

If it's missing, the static registration didn't survive your link. That means
the globs/alwayslink assumption broke in your build — see bounce-back item 3.
Do not proceed; nothing later can work if this doesn't.

## Step 4 — smoke test #2: does codegen work? (no GPU needed)

```bash
mojo build --target-accelerator adreno-x1 --emit=asm dragon/mojo-tests/adreno_saxpy.mojo
```

**Expected:** SPIR-V assembly text (starts with `; SPIR-V` and `OpCapability`
lines) containing an `OpEntryPoint` for the kernel.

This proves the whole compile side — stdlib target, lowering, backend —
without touching the driver or the runtime. If you get an error saying the
output "is not a SPIR-V module (bad magic)", the SPIRV LLVM backend isn't in
your build: re-check the `BACKENDS` line survived your merge.

## Step 5 — the one decision that is actually yours

The executables your `mojo build` produces must resolve the `AsyncRT_*` C
symbols at runtime. Modular links their closed runtime; you link ours. Two
options, both supported by the runtime as-is:

**Option A (recommended): link `dragonrt.lib`.** Build the runtime once —

```powershell
& "C:\Program Files\Microsoft Visual Studio\18\Professional\VC\Auxiliary\Build\vcvarsarm64.bat"
cd dragon\runtime
cl /nologo /O2 /EHsc /std:c++17 /LD /Fe:dragonrt.dll dragonrt.cpp
```

— and add `dragonrt.lib` to the libraries your driver links into produced
executables, alongside your own AsyncRT build (which provides the CPU device).
**The symbol sets are disjoint by construction** — dragonrt implements exactly
the accelerator symbols that the open `CPUDevice.cpp` does not — so there is
no conflict to manage. Ship `dragonrt.dll` next to `mojo.exe`.

**Option B: delay-load.** If your G4 linking story makes static import libs
awkward, `LoadLibrary("dragonrt.dll")` before the first
`DeviceContext(api="adreno")` is sufficient; all calls go through the export
table.

Why it's your call and not ours: it sequences with your G4 (linking
`mojo.exe`) and G5 (stdlib shims), and only you know what those look like this
week.

## Step 6 — the acceptance test. This is the finish line.

```bash
mojo build --target-accelerator adreno-x1 dragon/mojo-tests/adreno_saxpy.mojo
./adreno_saxpy
```

**Expected output:** `PASS: all 4096 elements correct on Qualcomm(R) Adreno(TM) X1-45 GPU`

That file is deliberately boring: standard-Mojo saxpy, the same program you'd
write for an NVIDIA card, zero DragonMax-specific APIs. That's the point — the
objective was "Mojo uses the GPU the standard Mojo way," so the test would
detect us failing it. One caveat: it was written against the stdlib API at the
fork point (`dde8f83773`); if your stdlib work moved `enqueue_create_buffer`
et al., adjust the calls — the *shape* is the contract, not the spellings.

When this prints PASS, the GPU line is done. Not "done pending discussion" —
done, by the definition both projects agreed to in `dragon/HANDOFF.md`.

---

## When it breaks: the bounce-back table

These four are the only known unknowns. Each is ours, bounded, and pre-triaged
— quote the item number back to DragonMax and it's a same-day fix, or just
apply the fix yourself if it's faster than Slack.

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | `SpirvLowering.cpp` fails on `cconv::CConv::SPIR_KERNEL` | enum namespace spelled from the `.td` + memory; the vendored LLVM tree vanished mid-verification | match whatever `mlir/Dialect/LLVMIR/LLVMEnums.h.inc` in *your* build says; one-line rename |
| 2 | `SpirvBackend.cpp` fails on `WriteableBuffer`/`BufferRef` usage | idioms mirrored from `HostBackend.cpp` verbatim; API may have drifted | re-mirror from your tree's `HostBackend.cpp`; mechanical |
| 3 | Builds, but Step 3 shows no Adreno section | your build doesn't compile the new dirs, or dropped alwayslink | add the three `Spirv/` source sets explicitly to `:TargetTraits`, `:KGENToLLVM`, `:ObjectCompiler` (or a new alwayslink rule like `:HostBackend`) |
| 4 | LLVM itself fails building the `SPIRV` target on this host | overlay target exists but this host/target combo is unproven | build-flag triage in `llvm_project.bzl`; worst case pin the SPIRV backend to the same LLVM version tricks used elsewhere in `bazel/public-patches/` |

Runtime-side failures (test builds, PASS doesn't print): first run
`dragon\runtime\test_dragonrt.exe`. If that passes, the runtime and GPU are
fine and the problem is between your executable and the DLL (Step 5). If it
fails, reboot-grade GPU weirdness is documented in
`dragon/probe/CAPABILITIES.md` — but as of today it passes clean.

## Things not to "improve" while you're in there

- **Launch dimensions in the runtime are `uint32_t` on purpose.** Mojo declares
  the same symbol from two launch paths; widen one to `size_t`/i64 and modules
  composing both stop legalizing, with an error nowhere near the cause.
- **`SpirvBackend::emitObject` returns the raw buffer and never calls
  `ctx.linkObject` — on purpose.** The `.spv` is consumed by the runtime at
  kernel-load; "fixing" it to link like HostBackend embeds garbage in the host
  image.
- **The `.gitignore` re-includes** (see Step 1).
- **`warp_size=64` in the Adreno family is nominal, not a fact** — measured
  preferred width varies per kernel (64 *or* 128) on this device. Kernels that
  care must query. The docstring on `QualcommAdrenoFamily` says so; leave it
  saying so.

## If you want the background (optional, genuinely)

| Doc | Contents |
|---|---|
| `dragon/HANDOFF.md` | the formal contract this file is the friendly version of |
| `dragon/design/OFFLOAD-FLOW.md` | the file:line trace proving no component is missing |
| `dragon/runtime/ABI.md` | all 109 ABI symbols, generated from the bindings |
| `dragon/runtime/BUILD.md` | runtime build/test, design notes |
| `DRAGONMAX-JOURNAL.md` | the full running record, including everything we got wrong first |

## Addendum, 2026-08-19 (post-first-compile)

Your field report absorbed, and thank you — the trio compiling unmodified
while all four predicted risks stayed silent is the outcome we hoped for; the
fifth, unlisted assumption (native IL ingestion) firing instead is ours to
own, and we have.

**Decision: Route 2 now, Route 3 as the endgame, Route 1 declined** (full
rationale in the journal). Route 2 is no longer speculative — we hand-encoded
a kernel-flavor SPIR-V module and **executed it on the Adreno via OpenCLOn12,
verified** (`dragon/probe/probe_adreno_spirv.py`).

Merge one more commit from `dragonmax/main` and re-run your pipeline:
dragonrt now (a) selects the OpenCL platform by **IL capability**, not name —
default prefers the SPIR-V-capable platform so `mojo`-built binaries work out
of the box; `DRAGONRT_PREFER=native` pins the faster native driver for
source-only runs; (b) resolves ingestion via
`clGetExtensionFunctionAddressForPlatform("clCreateProgramWithILKHR")` —
**never the loader's core slot, which access-violates on an On12 context**;
(c) always passes `CL_CONTEXT_PLATFORM` — with two platforms installed,
NULL-properties context creation is ambiguous and returns null on On12. The
last two would have broken a bare strstr version of Route 2.

Route 3 (Vulkan), scoped honestly before anyone budgets it as runtime-only:
Vulkan consumes **shader-flavor** SPIR-V (Logical, `GLCompute`); the backend
emits **kernel-flavor** (`Physical64`, `Kernel`), which Vulkan rejects. The
real Route 3 is a compiler flavor flip plus a descriptor-set argument ABI —
a proper work item, not a weekend.

On Route 1: LLVM has no OpenCL-C backend, so "same backend point, different
output form" is a transpiler project in a small-change costume — unless you
have a concrete emission mechanism in mind, in which case send it over and
we'll re-rank with pleasure.

## The checklist

- [ ] Merged `dragonmax/main`; kept the `.gitignore` hunk and the `"SPIRV"` line
- [ ] KGEN builds (your G3 — the four bounce-backs above are the only new-code suspects)
- [ ] `--print-supported-accelerators` shows **Qualcomm Adreno (DragonMax)**
- [ ] `--emit=asm` on the test kernel yields SPIR-V with an `OpEntryPoint`
- [ ] Linking decision made (A or B); `dragonrt.dll` ships beside `mojo.exe`
- [ ] `adreno_saxpy.mojo` builds, runs, prints **PASS** on the X1-45

Six boxes. Tick the last one and Mojo-on-Snapdragon-GPU is shipped.
