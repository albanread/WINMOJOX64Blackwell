# Test suite design — Windows x64 / NVIDIA

Status: design proposal. One piece of it — the G2 oracle comparison — is
already implemented and running, in the shared
[albanread/oracles](https://github.com/albanread/oracles) corpus; everything
else is unbuilt.
Scope: the MAX GPU layer first; the stdlib and host compiler second.
Written against revision `09bc34b`, measured on the T1000 (`sm_75`) box on
2026-08-23.

Two real defects were found while writing it, both reproducible and both in
`NVPTX DAG->DAG Pattern Instruction Selection`: a `nvptx-short-ptr` DataLayout
mismatch that crashes the compiler (§1), and a stale PTX ISA floor that makes
`tanh` unloadable on `sm_75` (F6). The second is upstream's, not ours.

---

## 1. Why this document exists

The port can run Mojo GPU kernels on NVIDIA hardware from Windows. What it
cannot do is *say how much of MAX works*. The README says so three times, and
lists "run a systematic MAX kernel census" as the first item under known
limitations.

That gap is not a shortage of tests. The tree already contains **795 MAX kernel
tests, 658 of them under `max/kernels/test/gpu/`**, plus 66 under
`max/mojo/test/` and 322 stdlib tests. They are upstream Modular's tests, they
are checked in, and on this fork **none of them has ever been executed**:
`bazel-testlogs` for `x64_windows-opt` is empty. The only recorded census,
`census.txt`, is a captured run from the *ARM64 predecessor project* against a
different CPU, a different GPU, and a different source root.

So the work is not "write tests". It is **build the apparatus that turns 658
existing tests into a trustworthy verdict**, and — this is the harder half —
make that verdict distinguish *the port is broken* from *this card cannot do
that*.

This document proposes that apparatus. Section 3 gives seven measured findings
that constrain the design; everything after follows from them.

**What running one existing test found.** Before writing this design I ran a
single Bazel test — the fork's *own* Windows NVPTX codegen regression test,
`max/mojo/test/compile/test_compile_nvptx_windows.mojo`. It crashes the
compiler:

```
LLVM ERROR: Can't create a MachineFunction using a Module with a
            Target-incompatible DataLayout attached
  Target DataLayout: e-p3:32:32-p4:32:32-p5:32:32-p6:32:32-p7:32:32-p101:32:32-i64:64-...
  Module DataLayout: e-p6:32:32-i64:64-...
0. Running pass 'Function Pass Manager' on module 'test_compile_nvptx_windows.mojo'
1. Running pass 'NVPTX DAG->DAG Pattern Instruction Selection'
```

The test passes `compile_options="nvptx-short-ptr=true"`, which shrinks address
spaces 3, 4, 5, 7 and 101 to 32-bit pointers in the *target's* DataLayout — but
the *module's* DataLayout is built without that option and carries only `p6`.
LLVM refuses the mismatch and aborts inside instruction selection. It
reproduces identically under `bazel test` and under `mojo run`, so it is a
compiler defect, not a harness artefact.

This test has been in the tree since the base import and has never passed,
because no test on this tree has ever been run. That is the argument for this
document in one line.

---

## 2. Current state, measured

### The asset

| Tree | `.mojo` files | BUILD files |
| --- | --- | --- |
| `max/kernels/test/gpu/` | **658** | 19 |
| `max/kernels/test/` (rest) | 137 | 13 |
| `max/mojo/test/` | 66 | 13 |
| `mojo/stdlib/test/` | 322 | 47 |

`max/kernels/test/gpu/` by subdirectory: `linalg` 194, `nn` 139, `basics` 54,
`layout` 51, `fuzz` 35, `kv_cache` 30, `structured_kernels` 21, `comm` 20,
`memory` 20, `compile` 18, `shmem` 16, `device_context` 15, `state_space` 12,
`quantization` 11, `examples` 10, `numerics` 9, `compute_sanitizer` 2,
`cluster` 1.

How they check themselves, in `max/kernels/test/gpu/`: **470 of 658 (71%) use
`assert_*`**, 68 (10%) use FileCheck `# CHECK` lines, 6 use both. The dominant
idiom is `std.testing.TestSuite` with
`TestSuite.discover_tests[__functions_in_module()]().run()`, which prints a
machine-readable summary line:

```
Summary [ 0.490 ] 59 tests run: 59 passed , 0 failed , 0 skipped
```

That line is a gift — it is a per-case verdict, not just a process exit code,
and the runner design in §5 leans on it.

### What has actually been validated

Nine focused tests, run by hand with `mojo.exe run`, tabulated in the README:
AsyncRT smoke, completion flags, 25 CUDA-graph scenarios, TMA tile copy, host
callback, multicast capability, GPU copy coverage, and the windowed Mandelbrot.
Plus, from a previous session on the T1000, eight of nine architecture-neutral
`max/mojo/test/asyncrt` tests.

That is roughly **1.4% of the GPU kernel tree**, chosen by hand, with no
regression gate.

### What exists to build on

The port is not starting from nothing, and the design should reuse rather than
reinvent:

- **`mojo_test` compiles and links a native `.exe`** and lets Bazel run it —
  it does *not* shell out to `mojo run`. (`bazel/internal/mojo_test.bzl:35`,
  and upstream `mojo/private/mojo_binary_test.bzl:361-378`, where `mojo_test`
  is `mojo_binary` with `test = True`.)
- **Every `mojo_test` also emits a `<name>.debug` plain `mojo_binary`**, tagged
  `manual` (`bazel/internal/mojo_test.bzl:48-60`). This is a directly runnable
  executable that needs no test toolchain at all — an escape hatch worth
  keeping in reserve (§5.5).
- **Upstream ships a mature kernel fuzzer** at `max/kernels/test/gpu/fuzz/`:
  a Python orchestrator (`fuzz.py`, 46 KB), a Mojo generation harness
  (`_fuzz.mojo`), a replayable corpus, per-case subprocess isolation with
  timeouts, and **seven named oracles** — `diff`, `ref`, `contract`,
  `schedule`, `determinism`, `batch_invariance`, `batch_variance`
  (`max/kernels/test/gpu/fuzz/README.md`). This is exactly the machinery a port
  needs and none of it has been run here.
- **Upstream ships compute-sanitizer positive controls** at
  `max/kernels/test/gpu/compute_sanitizer/` — deliberately-buggy kernels that
  only "pass" when a sanitizer lane catches them.
- **The Mandelbrot example is a genuine oracle**, and a well-designed one: it
  compares every one of 691,200 pixels against a single-threaded CPU reference
  but only *fails* on pixels that are low-count, locally flat, and off by more
  than one — because escape-time is chaotic at the boundary and a naive
  exact-match check would false-positive there
  (`examples/win32/nvidia_mandelbrot.mojo:507-586`). It reports 0 differing
  pixels on both `sm_75` and `sm_120a`.
- **The Windows shell toolchain is already wired.** `BAZEL_SH` is injected into
  the *repository* environment (`build/wrapper.bazelrc:14`) and spelled with
  forward slashes to survive the test launcher's backslash-eating escape pass
  (`bazelw.cmd:25-34`). The Windows test strategy line omits `sandboxed`,
  which is a hard error on Windows rather than a fallback
  (`bazel/internal/common.bazelrc:240-247`).

### The two port-authored tests

Only two test files carry the fork's own copyright, and both are models worth
generalising:

- `max/mojo/test/compile/test_compile_nvptx_windows.mojo` — compiles a trivial
  kernel and asserts on the **PTX text**: `.version 8.7`, `.target sm_120a`,
  `.address_size 64`. It carries no GPU tag and no `target_compatible_with`,
  because it needs no GPU. It targets `sm_120a` **from whatever machine runs
  it**. This is the seed of §5.4.
- `max/mojo/test/asyncrt/test_completion_flag.mojo` — written as the acceptance
  test for a new `nvptxrt` feature, landed in the same commit as the runtime
  code.

---

## 3. Seven findings that determine the design

Each was measured on this box during the review. Together they rule out the
obvious design ("loop over the test files, count exit codes") and point at a
different one.

### F0 — `bazel test` works; the blocker was never the harness

This was the open question the whole design branched on, and it is now
answered. `bazel test //max/mojo/test/compile:test_compile_nvptx_windows.mojo.test`
completed analysis, resolved the shell toolchain, hit **13,522 cached actions**,
built the test, and reported a result in **14.6 s**:

```
[13,579 / 13,581] 1 / 1 tests, 1 failed; checking cached actions
Executed 0 out of 1 test: 1 fails to build.
```

No `No suitable shell toolchain found`. No `LAUNCHER ERROR: Rlocation failed`.
No runfiles explosion. The `BAZEL_SH` and forward-slash fixes in
`build/wrapper.bazelrc:14` and `bazelw.cmd:25-34` did their job. The README's
statement that "Bazel's default Windows test execution toolchain is not
registered for these GPU tests in this tree" predates those fixes and is now
misleading — the tests were never blocked by the harness, they were blocked by
*nobody running them*.

**This is the single most consequential finding for the design.** It means the
suite can be built on `bazel test` (§5.2) with its caching, constraint
resolution, per-test GPU memory budgets and sharding, rather than on a bespoke
runner. It also means the incremental cost of the census is far lower than
feared: 13,522 of 13,581 actions were already cached.

The one caveat: this was a CPU-only compile test. Whether a *GPU* test also
launches cleanly under the Bazel launcher is Deliverable 0 (§11) and is one
command away.

### F1 — The exit code is not a verdict

Two tests in `max/kernels/test/gpu/comm/` have the *identical* precondition —
they need more than one GPU — and on a single-GPU box they disagree about what
that means:

```
rc=0   test_allgather_rmsnorm.mojo   →  "Need at least 2 GPUs but only found 1 - skipping."
rc=1   test_allreduce.mojo           →  AssertionError: must have multiple GPUs
```

One is a **vacuous pass**: it exercised nothing and reported success. The other
is a **false failure**: nothing is wrong. A census that counts exit codes gets
both wrong, in opposite directions, and its headline number is meaningless.

This is not two stray files. Across `max/kernels/test/gpu/`:

- **22 files self-skip by printing and returning 0** (`"Skipping: this test
  requires B200 (SM100)"`, `"Skipping test - AMD GPU not available"`,
  `"P2P not enabled, skipping test."`, …)
- **16 files self-skip by raising**, which exits non-zero
- **27 files gate on `DeviceContext.number_of_devices`** at all

So the verdict has to come from **reading the output**, not from `$?`.
Fortunately `TestSuite` already prints a parseable per-case summary, and the
self-skip messages are a small, enumerable vocabulary.

### F2 — The BUILD constraints are the skip oracle, and ignoring them manufactures failures

A naive sweep that runs every `.mojo` under `max/kernels/test/gpu/` runs tests
that Bazel would correctly refuse to run. Example, measured: `test_cluster.mojo`
compiled for 15 s and then failed with

```
constraint failed: elect one sync is only implemented for NVIDIA SM90+ GPUs
```

That is a **correct comptime diagnostic**, and Bazel would never have run the
test: `max/kernels/test/gpu/cluster/BUILD.bazel:11-13` declares
`target_compatible_with = ["//:b200_gpu"]`. My sweep produced a "failure" that
is purely an artefact of the sweep.

The constraint vocabulary is per-**card**, never per-SM-level. 33 labels of the
form `//:<name>_gpu` are generated from `SUPPORTED_GPUS.keys()`
(root `BUILD.bazel:119-126`), including `//:t1000_gpu`, `//:rtx3060_gpu`,
`//:rtxpro2000blackwell_gpu`. Constraint *mentions* across
`max/kernels/test/` skew hard toward hardware nobody here has:

| Constraint | Mentions | Reachable on T1000 / 3060 / Blackwell? |
| --- | --- | --- |
| `//:b200_gpu` | 158 | no |
| `//:has_gpu` | 104 | **yes** |
| `//:apple_gpu` | 86 | no |
| `//:mi355_gpu` | 52 | no |
| `//:h100_gpu` | 49 | no |
| `//:amd_gpu` | 47 | no |
| `//:nvidia_gpu` | 39 | **yes** |
| `//:has_multi_gpu` / `//:has_4_gpus` | 9 | no (single-GPU boxes) |
| `//:rtx5090` / `rtx5060ti` / `rtxpro2000blackwell` | 3 | Blackwell only |

**Consequence: the honest denominator is unknown and is much smaller than 658.**
Establishing it is Deliverable 0 (§11) and costs one command per platform:

```bash
./bazelw.cmd cquery --config=windows-nvidia-t1000 'tests(//max/kernels/test/...)' --output=label
```

Everything else is planning against an unmeasured denominator.

### F3 — `mojo run` is the wrong engine for a census

Measured, running tests through the JIT with hand-supplied `-I` paths:

| Test | Wall time |
| --- | --- |
| `test_add_constant.mojo` | 14.5 s |
| `test_device_context.mojo` | 27.9 s |
| `test_allreduce.mojo` | 39.6 s |
| stdlib `test_int.mojo` (CPU) | ~10 s |

Almost all of that is compilation, repeated on every run. Measured mean over a
76-test sample: **19.2 s**. At that rate the 652 real tests are **~3.5 hours
serial, every time, with no incrementality** — against the 14.6 s and 13,522
cached actions that `bazel test` managed in F0.

Meanwhile `mojo_test` already compiles once to a native `.exe` that Bazel
caches and re-runs in milliseconds. The design must use the build system's
caching, not a shell loop around the JIT. A JIT sweep is acceptable only as a
fallback (§5.5) and should never be the primary engine.

Two Windows mechanics reinforce this. `mojo build` fails under Git Bash because
`/usr/bin/link` shadows MSVC's `link.exe` and rejects `/`-style flags — already
documented at `examples/win32/build.sh:16-20`. And running tests outside Bazel
loses the GPU memory-manager environment
(`MODULAR_DEVICE_CONTEXT_MEMORY_MANAGER_ONLY/SIZE/CHUNK_PERCENT`,
`bazel/internal/config.bzl:218-223`, budgeted per test via
`exec_properties = {"test.resources:gpu-memory": …}`, default 0.8 GiB). Without
it, concurrent GPU tests on an 8 GB card have no allocation discipline.

### F4 — Codegen coverage is separable from execution coverage, and that is the port's biggest lever

`mojo build --emit asm` emits **a sidecar `.ptx` file per kernel**. The CUDA
Toolkit 13.2 is installed on this box (`ptxas`, `nvdisasm`, `cuobjdump`,
`compute-sanitizer`) even though the port deliberately does not *depend* on it.

Put those together and a large class of testing needs no matching GPU at all:

- Compile any kernel for `sm_75`, `sm_86`, **and** `sm_120a` from any box.
- Assemble the resulting PTX with `ptxas -arch=<target>` as an **independent
  validator** — a second opinion on whether our NVPTX backend emitted legal
  PTX, from a tool that is not ours.
- Diff the PTX **structurally** against a reference (§6, O4).

This matters because the port's riskiest surface is codegen (KGEN → MLIR →
NVPTX → PTX), and codegen is *where the port differs from upstream*, whereas
kernel execution is mostly the driver's business. The fork's own
`test_compile_nvptx_windows.mojo` already proves the pattern works and already
targets an architecture the running machine does not have.

**Implication:** a T1000 box can meaningfully validate Blackwell codegen. Three
architectures' worth of compile coverage is available on every machine, and
compile coverage is fast, deterministic, and needs no GPU serialisation.

### F5 — An unsupported feature must produce a diagnostic, never a crash

The port has already hit this once and fixed it. `cp.async` and `mbarrier` were
emitted with no architecture predicate, so on `sm_75` they reached the LLVM
backend and died with `LLVM ERROR: Cannot select: intrinsic
%llvm.nvvm.mbarrier.init.shared` — an instruction-selection crash, not a
diagnostic. It was fixed by adding comptime gates, and now says "requires
compute capability 8.0 (Ampere) or newer".

The review found **two** live instances of the same class:

```
rc=139 (SIGSEGV)   test_amd_asan_oob.mojo    — mojo.exe crashed, no diagnostic
LLVM ERROR        test_compile_nvptx_windows.mojo — DataLayout mismatch, ISel abort
```

The first log ends after deprecation warnings; whatever the right verdict is for
an AMD ASAN test on an NVIDIA box, **a compiler segfault is not it**. The
second is the fork's own regression test (§1) and is a real port defect in the
NVPTX DataLayout construction path — the `nvptx-short-ptr` option reaches the
target's DataLayout but not the module's.

Both die inside `NVPTX DAG->DAG Pattern Instruction Selection`. That is the
same failure site as the `cp.async`/`mbarrier` bug. **ISel is where this port's
codegen defects surface, and an ISel abort is always a port bug** — which makes
it worth detecting as its own verdict class rather than as a generic failure.

This gives the suite a machine-checkable invariant that is *specific to a port*
and that upstream has little reason to test, because upstream runs each test on
hardware that supports it:

> For every test gated to hardware we do not have, compiling it must terminate
> with a diagnostic naming the missing capability — never an ISel failure, an
> `UNREACHABLE`, an assertion, or a segfault.

Turning "cannot run here" from noise into a **positive assertion** is the
single highest-value idea in this design. It converts the ~500 tests that are
unreachable on consumer NVIDIA hardware from dead weight into a gate-hygiene
audit, and it runs on any box, needs no GPU, and is fast.

The sibling macOS port arrived at the same conclusion independently: its
`spikes/run-cocoa-checks.sh` has a first-class `run_mustfail` class whose header
reads *"a run where they quietly succeed is a FAILED run"*, and it greps the
rejection message to check the test failed *for the right reason*.

### F6 — There is no Windows *toolchain* oracle, but there is now a captured *corpus* one

> **Amended 2026-08-23, after this section was first written.** A shared
> corpus now exists at [albanread/oracles](https://github.com/albanread/oracles):
> reference PTX from Modular's released compiler for six probe kernels,
> including **`sm_75` — the card in this box**. It is checked in, so it needs
> no wheel, no WSL and no Linux leg, and it works on a machine with no Mojo
> toolchain at all.
>
> It has already paid for itself. Diffing all six probes took minutes and
> found that **five are byte-identical** to the released compiler — including
> the mangled entry-point symbols — while the sixth differs only in
> induction-variable direction. It also found a real defect: on `sm_75`,
> `tanh` lowers to `tanh.approx.f32` inside a module declaring `.version 6.3`,
> which forbids it, so `ptxas` **and the driver JIT** reject it
> (`CUDA error 218`). The oracle's own PTX fails identically, which is what
> proved the defect is upstream rather than ours.
>
> That last step is the transferable lesson: **run the validator against the
> oracle too.** A failure on our output alone is our bug; a failure on both is
> upstream of both. Without that control the finding would have been "fixed"
> locally by raising our version header — diverging from ground truth for no
> reason and leaving the real defect in place.
>
> Consequence for this plan: **O4 and a large part of O8 are available today**,
> and move from Phase 4 to Phase 1. The corpus does not replace a full
> upstream oracle — it covers six kernels, not 652 — but it answers the
> codegen question, which is the port's riskiest surface (F4), at near-zero
> cost. The rest of this section still applies to the *toolchain* oracle.

Checked against PyPI: upstream `max` 26.5.0 publishes
`manylinux_2_34_x86_64`, `manylinux_2_34_aarch64`, and `macosx_13_0_arm64`
wheels. `max-core` likewise. **There is no Windows wheel and no prospect of
one.** WSL is not installed on this box.

So a differential oracle against upstream MAX requires a Linux leg: WSL2 with
CUDA passthrough (cheapest — *same silicon, same driver*, isolating the OS and
compiler-host variables cleanly), a second Linux box, or a cloud GPU.

Two cautions before anyone builds one. First, **version skew**: this fork
reports `Mojo 1.1.0.dev0` against upstream's 26.5.0 calendar versioning, so a
wheel oracle compares two different source trees and every difference is
confounded. Building upstream from *this same tree* on Linux is the sound
version, and is what makes the comparison mean anything.

Second, the epistemics. The macOS sibling port ran exactly this experiment
against Modular's own toolchain and stated the limit plainly in
`spikes/air-oracle.sh`: each side is a *complete stack*, so a divergence is
"evidence about two stacks, not proof about our backend". An oracle is
excellent at *localising* a difference and poor at *assigning blame*.

**Therefore the oracle is valuable but should not be Phase 1.** The oracles
that need no second platform — CPU-vs-GPU on the same machine, cross-arch
invariance across three cards, `ptxas` as an independent PTX validator,
higher-precision references, determinism — are cheaper, available today, and
answer most of the questions. §6 ranks them.

---

## 4. Design principles

1. **A verdict is derived from evidence, not from an exit code.** Every result
   carries a *reason*, and "skipped" is a reason with a subtype.
2. **Coverage is two numbers, not one**: what compiled, and what executed. Do
   not let a card's limits cap the codegen coverage.
3. **Every skip is attributed.** "Not run" must resolve to *constrained away by
   BUILD*, *self-skipped at runtime*, *arch-gated at comptime*, or *we do not
   know* — and the last category is a bug in the harness.
4. **Report deltas against a checked-in ledger.** A 400-line census that nobody
   diffs is decoration. The gate is "no test moved from pass to fail".
5. **Reuse upstream machinery.** `mojo_test`, the fuzz orchestrator, the
   compute-sanitizer controls, the `_EXTRA_CONSTRAINTS` idiom. Do not fork
   upstream tests — fix the port until upstream tests pass. (The macOS port
   held this line and it worked: *"tests were never forked or patched"*.)
6. **A gate that cries wolf gets switched off.** Any new gate must be tuned
   until its false-positive rate is near zero before it becomes blocking.
7. **Negative tests are first-class.** "This must fail, and fail with *this*
   message" is a real assertion, and for a port it is often the important one.

---

## 5. Architecture

### 5.1 The gate ladder

Seven gates, each isolating one layer, ordered so that a failure at gate *n*
explains failures at gate *n+1*. This layering is borrowed from the macOS
sibling port, where it demonstrably worked.

| Gate | What it proves | GPU needed | Target runtime |
| --- | --- | --- | --- |
| **G0 Smoke** | compiler runs, GPU detected, one kernel launches, release package executes | yes | < 60 s |
| **G1 `nvptxrt` ABI** | the runtime is correct *in isolation from codegen* | yes | < 2 min |
| **G2 Codegen / PTX** | we emit legal, well-formed PTX for `sm_75`, `sm_86`, `sm_120a`, and it matches the `oracles` corpus | **no** | minutes, parallel |
| **G3 Arch-gate conformance** | unsupported features diagnose rather than crash (F5) | **no** | minutes, parallel |
| **G4 MAX kernel census** | how much of MAX actually works on this card | yes | ~1 h incremental |
| **G5 Numerical / differential** | the answers are *right*, not merely produced | yes | nightly |
| **G6 Stress / sanitizer / fuzz** | no races, no OOB, no run-to-run drift | yes | nightly |

G2 and G3 are new, port-specific, need no GPU, and are where the leverage is.
G0 and G1 are new and small. G4 is the 658 tests. G5 and G6 are mostly
upstream machinery that has never been switched on here.

### 5.2 The runner

**Primary engine: `bazel test`, and F0 establishes that this is viable.** It
already has everything the design needs — `target_compatible_with` resolution
(F2), per-test GPU memory budgets (F3), compile caching, sharding,
`--keep_going`, XML output. The shell toolchain is wired
(`build/wrapper.bazelrc:14`, `bazelw.cmd:32-34`) and was measured working.

Before the first sweep, `local.bazelrc` needs three lines the journal proved
load-bearing and which are **currently absent**
(`PORT-JOURNAL.md:1323-1334`, `:1239-1248`, `:1307-1313`):

```bazelrc
startup --windows_enable_symlinks
build --nobuild_python_zip
build --enable_runfiles
```

Without them Bazel either packs a 122 MB self-extracting CPython zip *per test
target* — measured, ~25 GB and hours across the test set — or writes 6,989 real
files per runfiles tree. Developer Mode alone is necessary and not sufficient;
Bazel needs the startup flag. (Probe symlink capability with Python's
`os.symlink()`, not Git Bash `ln -s`, which silently copies, nor PowerShell 5.1
`New-Item -ItemType SymbolicLink`, which reports a false negative.)

**The wrapper on top: `tools/census.py`.** Bazel produces per-target
pass/fail; the wrapper turns that into an *attributed* census. It:

1. Resolves the reachable set with `bazel cquery` for the active platform, and
   records the *constrained-away* set separately with its constraint labels —
   that is skip-reason class A, obtained for free (F2).
2. Runs `bazel test --keep_going --test_output=errors` over the reachable set.
3. Parses each `test.log` with the verdict classifier (§5.3) rather than
   trusting the exit code (F1).
4. Emits `census/<platform>.tsv` and diffs it against the checked-in
   expectations ledger (§5.4).
5. Exits non-zero only on a **delta**, never on absolute failures.

Python, not PowerShell or bash: it must run identically in CI and on both
boxes, and `fuzz.py` sets the precedent.

### 5.3 The verdict classifier

This is the core of the design. Ten verdicts, each with a decision rule and an
owner. The classifier reads `test.log` plus the exit code; the `TestSuite`
summary line gives per-case granularity where present.

| Verdict | Decision rule | Means | Counts against |
| --- | --- | --- | --- |
| `PASS` | `TestSuite` summary reports ≥1 run, 0 failed; or exit 0 with no skip marker | works here | — |
| `PASS_VACUOUS` | exit 0 **and** output matches a self-skip phrase, or 0 cases run | tested nothing (F1) | coverage, not correctness |
| `SKIP_CONSTRAINT` | excluded by `cquery` for this platform | upstream says wrong hardware | nothing |
| `SKIP_RUNTIME` | non-zero exit whose message is a recognised precondition (`must have multiple GPUs`, `P2P not enabled`, …) | wrong hardware, reported by raising (F1) | nothing |
| `SKIP_ARCH_CLEAN` | compile fails with a comptime `constraint failed:` naming a capability | **the gate works** — a pass for G3 | nothing |
| `FAIL_ARCH_DIRTY` | compile fails with `LLVM ERROR`, `UNREACHABLE`, assertion, or signal | **port defect**: a missing gate (F5) | port |
| `FAIL_COMPILE` | compile fails for any other reason | port or upstream drift | triage |
| `FAIL_RUNTIME` | runs, assertion fails or crashes | the interesting column | port or kernel |
| `FAIL_PROVIDER` | `Failed to materialize symbols`, `does not implement device API 'cpu'` | the known CPU/GPU AsyncRT dispatch gap — a named limitation, not a mystery | port (tracked) |
| `FAIL_HARNESS` | path-length, DLL-not-found, `Rlocation failed`, launcher error | Windows plumbing, not Mojo | harness |
| `NOT_A_TEST` | `module does not define a 'main' function` | a shared helper, not a test — exclude from the denominator | nothing |
| `TIMEOUT` | exceeded the per-test budget | hang; treat as failure, capture a dump | port |

Five notes on why this shape:

- **`FAIL_ARCH_DIRTY` is the payoff.** It is the ISel-crash class that F5
  describes, and it is detectable purely from the message. Every unreachable
  test becomes a probe for it.
- **`PASS_VACUOUS` must be visible**, or the census inflates. It is the only
  verdict that looks like success and isn't.
- **`FAIL_HARNESS` must be separable**, because `census.txt`'s 56 failures are
  known to mix real failures with `STATUS_NAME_TOO_LONG` path-length casualties
  — the journal says so explicitly (`PORT-JOURNAL.md:1973-1979`). Repeating
  that mistake would waste the whole exercise.
- The recognised-phrase tables for `PASS_VACUOUS` and `SKIP_RUNTIME` are small
  and enumerable (22 and 16 files today) and belong in one checked-in file, so
  that an unrecognised skip phrase surfaces as "we do not know" (principle 3)
  rather than being silently misfiled.
- **The classifier must match wrapper messages, not just root causes.** Applied
  to the review's sample it reached only **76% attribution** (Appendix A),
  and the largest residue was `error: failed to run the pass manager` — the
  generic text that wraps a comptime `constraint failed:`. Matching only the
  inner message misfiles a `SKIP_ARCH_CLEAN` as unknown. Attribution rate is a
  tracked metric (§10) precisely so this stays visible.

### 5.4 The expectations ledger and the census format

One TSV per platform, checked in:

```
census/windows-x64-t1000.tsv
census/windows-x64-rtx3060.tsv
census/windows-x64-blackwell.tsv
```

```tsv
target                                              verdict           reason                          ms
//max/kernels/test/gpu/basics:test_sum.mojo.test    PASS              -                               340
//max/kernels/test/gpu/comm:test_allreduce...       SKIP_RUNTIME      must have multiple GPUs         120
//max/kernels/test/gpu/cluster:test_cluster...      SKIP_CONSTRAINT   //:b200_gpu                     0
//max/kernels/test/gpu/compile:test_amd_asan...     FAIL_ARCH_DIRTY   signal 11, no diagnostic        16832
```

The gate is the **diff**, and the rule is the macOS port's: *no test moved from
passing to failing*. A new `FAIL_*` fails the build. A new `PASS` is a
celebration and requires updating the ledger in the same commit. A
`FAIL_ARCH_DIRTY` is always a bug, never an accepted expectation.

`census.txt` at the repo root should be renamed `census-arm64-historical.txt`
or deleted. The README already claims it was removed; leaving a stale ARM64
census where a reader will find it is worse than having none.

### 5.5 Fallbacks, in preference order

1. **`bazel test`** — the design target.
2. **Build `<name>.debug` binaries and run them externally.** Every `mojo_test`
   emits one (`bazel/internal/mojo_test.bzl:48-60`). This keeps Bazel's correct
   dependency graph, include paths, copts, and constraint resolution while
   bypassing the test launcher entirely. The runner must then supply the GPU
   memory-manager environment itself (F3). Use this if the launcher proves
   unfixable.
3. **`mojo run` sweep with hand-built `-I` paths** — what the review used, and
   what the README documents today. Correct but ~15 s per test, no caching,
   no constraint resolution. Acceptable for a single test during debugging;
   never for a census.

---

## 6. Oracles, ranked

For MAX GPU the question is rarely "did it crash" — it is "is the answer
right". Seven oracles are available; five need nothing this box does not have.

| # | Oracle | Catches | Cost | Available now |
| --- | --- | --- | --- | --- |
| **O1** | In-test `assert_*` | logic errors the test author anticipated | free — 470 of 658 tests already | **yes** |
| **O2** | Same source, CPU vs GPU | codegen and runtime divergence | low; needs a CPU path per kernel | **yes** (proven by Mandelbrot) |
| **O3** | `ptxas` as independent PTX validator | illegal/malformed PTX, for any arch | very low; no GPU | **yes** (CUDA 13.2 installed) |
| **O4** | PTX structural diff vs reference | codegen drift, unexpected constructs | low | **yes** — `oracles` corpus has `sm_75` |
| **O5** | Cross-arch invariance (`sm_75` / `sm_86` / `sm_120a`) | arch-specific miscompiles | low; needs three cards | **yes**, two boxes |
| **O6** | Higher-precision reference (`fuzz --oracle ref`) | numerical error, tolerance drift | low; upstream harness exists | **yes** |
| **O7** | Determinism / bit-stability (`--oracle determinism`) | races, order-dependent atomics | low; upstream harness exists | **yes** |
| **O8** | Upstream MAX on Linux/NVIDIA | anything the port does differently | **high** — needs a Linux leg | no (F6) |

Notes on the ones that need design work:

**O2 — CPU vs GPU, generalised.** Mandelbrot proves the pattern and also
proves the subtlety: an exact-match check false-positives on chaotic kernels,
so it demands exactness only where the reference is *locally flat*. The macOS
port hit the same wall on the same program and solved it with an agreement-rate
threshold. Generalise this into a shared helper — *compare with a
sensitivity-aware predicate, and report the agreement rate, not a boolean* —
and apply it to reductions, norms, and elementwise kernels where a CPU
reference is cheap.

**O3 — `ptxas` as a second opinion.** `mojo build --emit asm` writes a `.ptx`
sidecar per kernel; `ptxas -arch=sm_XX` accepts or rejects it. This is a
validator our own toolchain did not write, it runs without a GPU, and it works
for architectures the box does not have. Cheapest real signal in the list.
Note it validates *legality*, not *correctness* — legal PTX can still compute
the wrong thing, which is why O2 and O6 still matter.

**O4 — structural PTX diff.** The macOS port's sharpest technique: rather than
chasing the backend's error messages serially, it inventoried the *record
kinds* its compiler emitted versus the reference's and diffed the sets —
"OURS-ONLY record kinds, each is version skew until shown otherwise". The NVPTX
analogue is an instruction/directive inventory per kernel.

**This is now implemented and running.** The `oracles` corpus provides the
reference for `sm_75`, and `tools/compare-ptx.sh` there does the comparison:
normalised text diff, opcode-multiset diff, and `ptxas` run against *both*
sides. The multiset diff is what earns its keep — it reported the one
divergent probe as `REORDERED (same opcodes)` rather than `DIVERGES`, which
is the difference between a one-line note and an afternoon reading a loop.

Two further references need no Linux leg either: `nvcc` compiling equivalent
CUDA (a "constructs NVIDIA never emits here" list), and **the port's own PTX
across architectures and across revisions** — a snapshot diff that catches
codegen drift on merge. The corpus covers six kernels; the self-snapshot
scales to all 652 and is nearly free, so the two are complementary rather
than alternatives.

**O5 — cross-arch invariance.** Three registered NVIDIA targets span every
feature gate that matters: `sm_75` (no `cp.async`, no `mbarrier`, no bf16, no
tensor cores), `sm_86` (clears `_is_sm_8x_or_newer`), `sm_120a` (adds TMA and
clusters). A kernel that produces the *same answer* on all three has been
checked against the whole span the port supports, and a kernel that differs has
an arch-specific bug — which is precisely the port's risk profile. Note the
`sm_86` card is registered but has never been measured; that is a gap worth
closing early because it is the middle of the range.

**O8 — the upstream oracle.** Worth building eventually, on the terms in F6:
build upstream from *this same source tree* on Linux, not a version-skewed
wheel; run it as a separate process, never linked in; state the asymmetry
rather than hiding it. WSL2 with CUDA passthrough on the T1000 is the cheapest
form and holds the GPU and driver constant, which makes it a genuinely clean
experiment. But it is Phase 4, not Phase 1.

**One warning, from the macOS port, that applies directly here.** That port
once accidentally linked Modular's closed runtime instead of its own. The
result was *"a clean exit, a plausible 243x speedup and a buffer nothing had
written"* — and the harness reported 0% agreement, which *reads like a codegen
fault and is not one*. The Windows analogue is `MODULAR_MOJO_MAX_SHARED_LIBS`
pointing at the wrong DLL, or the known CPU-provider dispatch gap where
`nvptxrt` owns an unnamespaced `AsyncRT_DeviceContext_*` ABI. **The runner must
record which runtime DLL it loaded, with its hash, in every census header.**

---

## 7. New suites to write

Four, all port-specific, none large. These are the tests upstream has no reason
to write because upstream is not a port.

### 7.1 `nvptxrt` ABI conformance (G1)

`nvptx/runtime/` contains `nvptxrt.cpp` and a BUILD file and **no test target
at all**, despite being the single most port-specific component. `max/mojo/test/asyncrt/`
covers it indirectly through Mojo, which means a runtime bug and a codegen bug
present identically.

Write a headerless C test that declares the `AsyncRT_*` entry points with local
prototypes — *the same way Mojo's `external_call` finds them* — and drives the
runtime with no Mojo in the picture. This is exactly the macOS port's
`applegpu_metal_smoke.c`, and it earned its keep there: a later refactor broke
the MSL saxpy path and the commit message records *"that is a regression I
introduced … because I stopped running the runtime smoke test"*.

Cover: device discovery and attributes, context lifecycle, buffer alloc/free/
sub-buffer, H2D/D2H/D2D, memset widths, streams/events/timers, module load and
kernel launch, graphs, completion flags, host callbacks. Plus **negative
assertions**: multicast must fail with a clear error rather than an unresolved
symbol; peer self-access must report false. The `dragon/runtime/test_dragonrt.c`
precedent exists but was never wired to a Bazel target — do not repeat that.

### 7.2 Arch-gate conformance (G3) — the must-fail suite

Directly from F5, and the highest-value new suite.

For every feature the stdlib gates on architecture — `cp.async`, `mbarrier`,
TMA, `tcgen05`, clusters, `elect_one_sync`, bf16, tensor cores, fp8, multicast
— assert that on an architecture that lacks it, compilation **fails with a
diagnostic naming the capability**. Model it on
`spikes/run-cocoa-checks.sh`'s `run_mustfail`: it is not enough that the build
failed, the *reason* must match.

Two ways to source the cases, and both should run:

1. **Explicit**: a small table of `(feature, minimum arch, expected message
   fragment)`. Precise, and it documents the contract.
2. **Derived**: every test that `cquery` constrains away on this platform,
   compiled anyway, classified by §5.3. `SKIP_ARCH_CLEAN` is a pass;
   `FAIL_ARCH_DIRTY` is a bug. This turns ~500 otherwise-dead tests into a
   gate-hygiene audit at zero authoring cost.

Runs anywhere, needs no GPU, is fast, and is exactly the class of defect a port
introduces.

### 7.3 Device-info conformance

`mojo/stdlib/std/gpu/host/info.mojo:2225` maps `sm_75` to `RTX2060` and reports
`sm_count = 30`. The driver reports `NVIDIA T1000 8GB`, and the real TU117 has
**14** SMs. Launch heuristics keyed on `sm_count` therefore over-subscribe by
about 2.1x on this card. Nothing currently catches that, because nothing
compares the stdlib's table against the driver.

Write one test that cross-checks the stdlib's device table against the CUDA
Driver API for the *running* device: name, compute capability, SM count, memory,
warp size, shared memory per block. Cheap, and it catches a whole class of
silent mis-tuning that no kernel test will ever report as a failure.

### 7.4 Release smoke test

`release/windows/create-release.ps1` verifies that 29 artifacts exist and
hashes them. It never launches `mojo.exe`. A release can therefore be packaged,
hashed, and shipped with a compiler that cannot run a single line of Mojo.

`examples/hello.mojo` is already bundled for exactly this purpose. Add to the
packager: run `mojo.cmd run examples\hello.mojo` and assert the output string;
run `mojo.cmd build` on the same file and execute the result; run the GPU
launcher on a trivial kernel. Roughly five lines, and it closes the largest
credibility gap in the release path.

---

## 8. Machine and architecture matrix

| | T1000 (this box) | RTX 3060 | RTX PRO 2000 Blackwell |
| --- | --- | --- | --- |
| Arch | `sm_75` Turing | `sm_86` Ampere | `sm_120a` Blackwell |
| Registered | yes | yes | yes |
| Ever measured | partly (9 asyncrt tests) | **never** | focused tests only |
| `cp.async` / `mbarrier` / bf16 / tensor cores | no | yes | yes |
| TMA / clusters | no | no | yes |
| Role | **lower bound + gate hygiene** | **the untested middle** | **feature ceiling** |

Every box runs G2 and G3 for **all three architectures** (F4) — codegen
coverage does not depend on the local card. Only G0/G1/G4/G5/G6 are
card-specific.

The `sm_86` gap is the notable one: it is the tier where `cp.async`, `mbarrier`,
bf16 and tensor cores first become available, so it is where a whole family of
fast paths is exercised for the first time. Both other cards sit on the far
sides of that boundary. Measuring it should be early.

None of the three boxes has more than one GPU, so the ~9 multi-GPU tests are
permanently `SKIP_CONSTRAINT` and the peer/collective paths stay unvalidated.
That should be stated in the census header rather than rediscovered.

---

## 9. Windows mechanics the harness must handle

Each of these has already cost this project time; the harness should encode
them rather than let them be re-found.

| Trap | Symptom | Handling |
| --- | --- | --- |
| Path length | `STATUS_NAME_TOO_LONG` (`0xC0000106`); `ImportError: DLL load failed … filename or extension is too long` | short output base (`F:/bzs` today); `LoadLibrary` enforces MAX_PATH regardless of `LongPathsEnabled`. The fuzz corpus already contains paths that fail `git checkout` without `core.longpaths=true`. |
| Runfiles | 122 MB CPython zip per test target, or 6,989 real files | `startup --windows_enable_symlinks`, `--nobuild_python_zip`, `--enable_runfiles` — **all three currently missing from `local.bazelrc`** |
| `BAZEL_SH` backslashes | `LAUNCHER ERROR: Rlocation failed on C:Program FilesGitusrbinbash.exe` | forward slashes only (`bazelw.cmd:32-34`) — already fixed, keep it |
| Strict repo env | GPU "absent"; `vcvarsall.bat` hangs 600 s | one variable each; see the patches in `bazel/public-patches/` |
| Git Bash `link.exe` | `mojo build` fails with `Try '/usr/bin/link --help'` — **reproduced during this review** | never build from Git Bash; use the VS environment (`release/windows/vsenv.cmd`) |
| No `sandboxed` strategy | hard error, not a fallback | Windows strategy line lives in `build/wrapper.bazelrc` |
| Compilation mode | `-c opt` elides an inline destructor the LLDB `.def` exports | already fixed; re-check after LLVM bumps |
| Python/pytest | `uv` alias has no `//conditions:default`; wheels map to `:unavailable_on_windows` | the 999 `test_*.py` files are **out of scope**; say so explicitly |
| Console output | redirected stdout has no console, so ANSI and `GetConsoleScreenBufferInfo` behave differently | `tools/shot.ps1` exists for this; keep it for the print/format tests |
| Silent crashes | `0xC0000374` heap corruption and `0xC0000409` `__fastfail` bypass SEH entirely | `tools/crashcatch` exists but is **still ARM64-specific** — porting its stack walk to x64 is a prerequisite for diagnosing `FAIL_RUNTIME` |

---

## 10. What "better" means — the metrics

Five numbers, reported per platform in the census header. Today four of them
are unknown.

1. **Reachable set size** — how many targets `cquery` admits for this platform.
   *The denominator.* Currently unknown (F2).
2. **Execution coverage** — `PASS / (reachable − SKIP_* )`.
3. **Codegen coverage** — fraction of the whole tree that compiles cleanly per
   architecture, independent of the local card (F4). This is the number that
   can be high on every box.
4. **Attribution rate** — fraction of non-`PASS` results with a classified
   reason. Principle 3 says this must reach 100%; anything unattributed is a
   harness bug.
5. **`FAIL_ARCH_DIRTY` count** — must be zero. Any non-zero value is a missing
   comptime gate (F5).

Plus two hygiene numbers: **flake rate** (re-run failures once; a differing
result is a flake, and flakes are bugs) and **time to signal** (G0–G3 must
finish in minutes or nobody will run them).

---

## 11. Phasing

**Deliverable 0 — establish the denominator, and confirm a GPU test launches
(hours).**
The harness question is already answered (F0): `bazel test` runs, caches, and
reports. What remains is to (a) run `bazel cquery` per platform for the
reachable set, (b) add the three `local.bazelrc` lines, and (c) run **one GPU
test** end-to-end — F0's evidence is a CPU-only compile test, so the GPU
launcher path is still unproven. Pick something small and unconditional, e.g.
`//max/kernels/test/gpu/basics:test_add_constant.mojo.test`. If a GPU test
launches, the design is §5.2 throughout; if only GPU tests fail in the
launcher, fall back to §5.5 option 2 for G4 alone.

Fix the `nvptx-short-ptr` DataLayout crash (§1) in the same pass — it is a real
defect, it is already diagnosed, and it blocks the fork's own regression test.

**Phase 1 — the ladder's cheap half (days).**
G0 smoke, G2 PTX/`ptxas` gates for all three architectures, G3 arch-gate
conformance, the release smoke test (§7.4), and the device-info test (§7.3).
None needs a GPU except G0. This produces the first honest coverage numbers and
the first `FAIL_ARCH_DIRTY` list.

The oracle comparison belongs here too, not in Phase 4 (F6 as amended). It is
already working: wire `oracles/tools/compare-ptx.sh` into G2 so a regression
against the released compiler fails the gate, and fix the `+ptx63` floor it
found. Regenerating the corpus for `sm_86` and `sm_120a` needs a machine with
the wheel, which is a Phase 3 dependency, but `sm_75` is checked in and runs
today.

**Phase 2 — the census (days).**
`tools/census.py`, the verdict classifier, the ledger, and the first full G4
run on the T1000. Rename `census.txt`. Expect the first run to be mostly
triage, and expect `FAIL_HARNESS` to be large before it is small.

**Phase 3 — the middle card and the runtime suite (days).**
G1 `nvptxrt` conformance (§7.1). Run the full census on the RTX 3060 — the
untested `sm_86` tier — and on Blackwell. Cross-arch invariance (O5) becomes
available once two censuses exist.

**Phase 4 — depth (weeks, nightly).**
Switch on the upstream fuzz orchestrator with the `ref`, `determinism`, and
`contract` oracles. Add compute-sanitizer lanes using the existing positive
controls. Then, and only then, consider the full Linux *toolchain* oracle
(O8) under the constraints in F6 — the captured corpus already covers the
codegen question, so what remains for O8 is behavioural comparison across the
whole kernel tree, which is a much larger undertaking for a narrower marginal
gain.

**Continuous.** Port `tools/crashcatch` to x64. Adopt the macOS port's commit
discipline: every commit that touches the port carries a before/after
scoreboard with failures decomposed into *fails here* versus *cannot build
here*, and an explicit no-regression statement.

---

## 12. Open questions

1. ~~Does `bazel test` execute on this tree?~~ **Answered: yes** (F0). Open
   remainder: does a *GPU* test launch? F0's evidence is a CPU-only compile
   test.
2. **What is the reachable set on each card?** Guessed at ~150–250 of 658 from
   constraint mentions; unmeasured.
3. **Is the FileCheck tier worth reviving?** 68 GPU tests plus 101 stdlib tests
   need `sh_test` + bash + FileCheck. `@llvm-project//llvm:FileCheck` is a
   buildable target and lit already uses its internal shell on Windows
   (`lit.common.cfg.py:36-46`), so the machinery may work. But the fork's own
   TMA change went the *other* way — converting a `mojo_filecheck_test` into an
   assert-based `mojo_test` — which suggests conversion may be cheaper than
   revival for the tests that matter. Decide after Deliverable 0.
4. **Where does the `sm_86` box live**, and can it run unattended? The census
   is only a regression gate if it runs on a schedule.
5. **Is the CPU-provider dispatch gap in scope?** It blocks
   `max/mojo/test/asyncrt/test_copies.mojo` on both cards and any mixed CPU/GPU
   test. It is a known limitation, not a mystery — but it caps `max/mojo/test`
   coverage until fixed.
6. **How much upstream API drift is there?** Every sampled test emitted
   `UnsafePointer` and positional-`__getitem__` deprecation warnings. Harmless
   now, but they will become errors, and the census should track warning counts
   so the cliff is visible before it arrives.

---

## Appendix A — evidence from this review

Measured on the T1000 box, 2026-08-23, with `mojo.exe` at `09bc34b` and
`MODULAR_MOJO_MAX_SHARED_LIBS` pointed at `nvptxrt.dll`.

A stratified sample of `max/kernels/test/gpu/` (first four files per
subdirectory) was run through `mojo run` **deliberately ignoring BUILD
constraints**, to see what a naive sweep produces.

Aggregate over the full 76: **28 exit 0, 47 exit 1, 1 exit 139**, mean 19.2 s,
total 24.3 minutes. Read as a census that would be **36.8% passing** — and it
would be wrong in both directions.

Running the §5.3 classifier over the same logs shows why:

| Classified verdict | n | Would a naive census get it right? |
| --- | --- | --- |
| `SKIP_ARCH_CLEAN` — comptime diagnostic | 20 | no — counted as failures |
| *unclassified residue* | 18 | no |
| `FAIL_COMPILE` — deps/includes | 4 | yes |
| `SKIP_RUNTIME` — needs >1 GPU | 2 | no — counted as failures |
| `FAIL_RUNTIME` — assertion | 2 | yes |
| `FAIL_ARCH_DIRTY` — LLVM/ISel abort | 1 | no — indistinguishable from above |
| `FAIL_ARCH_DIRTY` — signal 139 | 1 | no |
| `PASS_VACUOUS` (among the 28 exit-0) | 1 | no — counted as a pass |

**Twenty of the 47 "failures" are the arch gate working correctly.** One is a
port defect that a naive census would file identically. That is the argument
for §5.3 in one table.

The **attribution rate is 76%** (58 of 76 classified) — measured against
principle 3's target of 100%. The 18-file residue is itself informative and
splits into four groups, each of which the classifier should learn:

- **`module does not define a 'main' function`** (4 files) — these are *not
  tests*. `_fuzz.mojo`, `kv_cache_test_utils.mojo`, `matmul_kernels.mojo`,
  `tensor_core_kernels.mojo` are shared helpers. Tree-wide there are **6 such
  files in 658** (10 in the full 795), so the real test count is **652**. The
  correction is small; the lesson is not — a file glob cannot tell a test from
  a helper, and `bazel cquery` can. *(Caveat on this sample: taking the first
  four files per directory alphabetically over-represented helpers, since `_`
  prefixes and `*_utils` sort before `test_*`. It caught 4 of the 6.)*
- **`failed to run the pass manager`** (AMD/Apple target tests) — almost
  certainly `SKIP_ARCH_CLEAN` wearing a generic message. The classifier must
  match this wrapper text, not just `constraint failed:`.
- **`Failed to materialize symbols`** (`test_device_context_cpu.mojo`) — the
  known CPU-provider dispatch gap, and it deserves its own verdict so it stops
  being counted as a mystery.
- **`failed to parse the provided Mojo source`** (`_test_tma.mojo`) — another
  helper.

Selected individual results:

| Test | rc | ms | What it actually means |
| --- | --- | --- | --- |
| `basics/test_add_constant` | 0 | 14518 | genuine pass |
| `basics/test_accelerator_arch` | 1 | 10166 | test hardcodes an arch allowlist; `sm_75` not in it |
| `cluster/test_cluster` | 1 | 15333 | clean comptime diagnostic, SM90+ — and Bazel would have skipped it (`//:b200_gpu`) |
| `comm/test_allgather_rmsnorm` | 0 | 26274 | **vacuous pass** — printed "only found 1 - skipping" |
| `comm/test_allreduce` | 1 | 39589 | **false failure** — same precondition, raised instead |
| `compile/test_amd_asan_oob` | **139** | 16832 | **compiler segfault, no diagnostic** |
| `device_context/test_device_context` | 0 | 27879 | genuine pass |

Environment facts established: no `mojo test` subcommand exists; `mojo build
--emit asm` writes a `.ptx` sidecar per kernel; CUDA Toolkit 13.2 is installed
(`ptxas`, `nvdisasm`, `cuobjdump`, `compute-sanitizer.exe`); WSL is not
installed; upstream `max` 26.5.0 ships no Windows wheel; `bazel-testlogs` for
`x64_windows-opt` is empty; `mojo build` fails under Git Bash because
`/usr/bin/link` shadows MSVC's linker; `bazelw.cmd` must be driven from
PowerShell, not Git Bash.

Two defects found, both reproducible, both in `NVPTX DAG->DAG Pattern
Instruction Selection`:

1. **`nvptx-short-ptr` DataLayout mismatch** — `LLVM ERROR: Can't create a
   MachineFunction using a Module with a Target-incompatible DataLayout`. The
   target gets `p3/p4/p5/p6/p7/p101:32:32`, the module gets only `p6:32:32`.
   Reproduces under both `bazel test` and `mojo run`. Blocks
   `max/mojo/test/compile/test_compile_nvptx_windows.mojo`, which is the
   fork's own Windows NVPTX regression test and has never passed.
2. **Compiler segfault** (exit 139, no diagnostic) on
   `max/kernels/test/gpu/compile/test_amd_asan_oob.mojo`.

## Appendix B — what was borrowed from the macOS sibling port

[MojoCocoa](https://github.com/albanread/MojoCocoa) is the same author's
in-progress macOS/Metal port. It targets different silicon, but it has already
solved several problems this design faces, and its lessons are cited above.

**Adopted:** the layered gate ladder where each gate isolates one component;
the runtime-only smoke test with local ABI prototypes (§7.1); must-fail tests
that check the *reason* for rejection (§7.2); the oracle as a separate process
with its asymmetry stated rather than hidden (§6); agreement-rate rather than
exact-match comparison for chaotic kernels (O2); structural inventory diffing
instead of chasing backend error messages serially (O4); debug hatches that
preserve evidence *before* the failing step, treated as part of the test suite;
and the commit-scoreboard discipline with failures decomposed into *fails here*
versus *cannot build here*.

**Deliberately not adopted:** its results live only in commit messages and a
`STATUS.md` that drifted out of date within a day. It has no persistent
machine-readable census, no timeouts in any runner, hardcoded test lists rather
than discovery, and only binary pass/fail with no skip or unsupported verdicts.
Given 658 GPU tests and three architectures, this port needs the ledger
(§5.4) and the ten-verdict taxonomy (§5.3) that the macOS port could do
without.
