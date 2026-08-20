# WINMOJO — Mojo 1.1 on native Windows ARM64

## Thanks, and a statement of intent

Mojo is a serious piece of language engineering, and it was given away. Thanks
are owed to Chris Lattner and the team at Modular who designed and built it, and
to everyone who has contributed to the compiler and the standard library since.

Open-sourcing the compiler and stdlib under Apache 2.0 — with a patent grant and
no field-of-use restriction — is what makes a port like this one both legal and
possible. It means someone can take the source, aim it at hardware the authors
never targeted, and find out what happens. That is not the industry norm, and it
is the reason this repository can exist at all.

What follows is not written in a spirit of celebration, and it would be dishonest
to pretend otherwise.

This repository exists to run Mojo on my own hardware, to understand how it
works, and to find out whether it is useful to me. It is not a tribute and not an
advertisement. Much of what is recorded here — in this README and at far greater
length in the [journal](PORT-JOURNAL.md) — is blunt about the language, the
toolchain, and the licensing, and it will stay blunt wherever the evidence points
that way. That is the point of the exercise rather than a failure of manners:
**I am interested; I am not a fan.**

## What this is

**An unofficial, unsupported fork of [modular/modular](https://github.com/modular/modular)
that ports the Mojo compiler and standard library to native Windows 11 on
Snapdragon (ARM64) PCs.**

No WSL. No emulation in the shipped binary. `mojo.exe` is a PE/COFF ARM64
executable that compiles and runs `.mojo` files on the machine you are sitting at.

> [!IMPORTANT]
> This is not a Modular product and is not affiliated with, endorsed by, or
> supported by Modular. Do not file issues about this fork on the upstream
> repository. It carries no warranty and no support commitment of any kind.
> If you need supported Mojo, use [the real thing](https://mojolang.org) on a
> platform Modular actually ships for.

| | |
| --- | --- |
| **Upstream** | `modular/modular` @ `f66d4d5` |
| **Language version** | Mojo 1.1.0 — **frozen, see below** |
| **Target** | `aarch64-pc-windows-msvc`, Windows 11, Snapdragon X |
| **Scope** | Mojo compiler (KGEN), C++ substrate, stdlib, CPU codegen |
| **Out of scope** | MAX (kernels, graph, engine, serve), GPU backends |
| **Licence** | Apache 2.0 with LLVM exceptions (compiler & stdlib) |

## The irony

Mojo exists because AI compute is heterogeneous. Its entire premise is that one
source file should specialize to whatever silicon you point it at — CPUs, GPUs,
accelerators, NPUs.

Snapdragon X is an AI PC. It has a capable ARM64 CPU, an Adreno GPU, and a
Hexagon NPU sitting right there. It is precisely the sort of heterogeneous
consumer silicon Mojo was designed to talk to.

Mojo does not support it. Modular ships Linux x86-64, Linux ARM64, and macOS
ARM64. On Windows the official answer is WSL — a Linux VM, on a machine whose
native ISA is already ARM64, to run a language whose reason for existing is
meeting hardware where it lives.

This fork exists to close that gap for one machine. That is the whole ambition.
It is not a bid to become the Windows port.

## The freeze

**When this port is complete it stays at Mojo 1.1.0. It does not track upstream.**

That is a deliberate design decision, not neglect. A solo port cannot chase a
language that redefines itself every few weeks: every upstream churn re-keys the
build, invalidates substrate work, and moves the finish line. Pinning to a single
commit turns an infinite task into a finite one.

What that buys:

- **A finishable artifact.** The target is fixed, so "done" is a state that can
  actually be reached and then verified.
- **A stable language to write against.** Code written for this compiler keeps
  compiling. No deprecation treadmill, no syntax that evaporates next release.
- **Reproducibility.** One upstream commit, one toolchain, one answer to "why did
  this change?"

What that costs, stated plainly: no upstream bug fixes, no new language features,
no new stdlib APIs, and a growing distance from whatever Mojo becomes. This is a
preserved snapshot of a language at version 1, not a living distribution. If that
trade is wrong for you, this fork is wrong for you.

## Status

Full stdlib test census, native Windows ARM64:

| Result | Targets |
| --- | --- |
| pass | **258** |
| fail | 52 |
| fail to build | 4 |
| skipped (platform-gated) | 55 |
| **total** | **369** |

`mojo.exe` builds, links, parses, compiles and runs Mojo. The stdlib compiles to
`std.mojoc` with warnings only and required no source changes. The remaining
failures are the current work; see [PORT-JOURNAL.md](PORT-JOURNAL.md) for the
running record, which is where the real detail lives.

### What works, and what does not

| | State |
| --- | --- |
| `mojo build` (AOT) | **works** — produces a running native ARM64 PE/COFF binary |
| `mojo run` (JIT) | **works** — on LLVM's RuntimeDyld, which has had a COFF/ARM64 backend since 2019; JITLink (the default layer) has none, and this README wrongly said "cannot work" until someone refused to believe it |
| REPL | blocked on LLDB — Mojo's REPL is an LLDB front end, and lldb is not ported; nothing to do with the JIT |
| native CPU target | **broken** — `oryon-1` crashes the compiler, see below |
| standalone driver | works only with two environment overrides, see below |

Two defects had to be fixed before any Mojo program could be compiled and run on
this platform. The COFF machine type was hardcoded to `/machine:X64` — carrying
upstream's comment *"Mojo only supports X86_64 COFF right now"* — so the linker
was handed ARM64 objects and told they were x86-64. With that derived from the
target triple, the link reached symbol resolution and failed on `write` and
`dup`: the stdlib's FFI calls POSIX names that the MSVC CRT exports
underscore-prefixed, and `oldnames.lib` supplies the aliases that `cl.exe` would
normally request through a `/DEFAULTLIB` directive Mojo never emits.

Three gaps remain worked around rather than fixed:

- **The compiler cannot target this machine's CPU.** `oryon-1` — the actual
  Snapdragon X core — hits an assertion in LLVM's AArch64 scheduling model
  (`TargetSchedule.cpp:227`, "incomplete machine model") and aborts codegen
  outright. The benchmarks below were compiled for `neoverse-n1` instead; both
  are ARMv8-A AArch64 and neither has SVE, so the substitution is sound and the
  code is correct and native — but it is scheduled for a narrower core than the
  one running it. `neoverse-n1` is not a general escape either: it aborts the
  same way on some load/store-pair sequences, so AOT builds of the Windows
  examples use `--target-cpu generic`, which selects no scheduling model at all.
  A compiler that crashes on its own host CPU is a defect, not a footnote, and
  it is the next thing to fix.
- **The compiler_rt default path is Linux-shaped**
  (`lib/libKGENCompilerRTShared.so`), so `MODULAR_MOJO_MAX_COMPILERRT_PATH` must
  be set for a standalone invocation. Bazel-driven builds resolve it via runfiles
  and are unaffected.
- **The linker driver must be named explicitly** through
  `MODULAR_MOJO_MAX_LINKER_DRIVER`, since the driver emits MSVC-style flags and
  looks for `link.exe` on PATH.

### First benchmarks

Six programs, transliterated line-for-line into Mojo, C and Python, run on one
Snapdragon X desktop. C is clang 22.1.4 at `-O3` — the same LLVM version Mojo
itself uses — and both were given the same `-mcpu`. Times in milliseconds,
in-process, excluding startup.

| Benchmark | Mojo | C | CPython 3.12 | vs C |
| --- | --- | --- | --- | --- |
| fib30 · recursion | 2 | 2 | 165 | 1.00× |
| mandelbrot · float | 21 | 19 | 1157 | 1.11× |
| collatz · int div | 70 | 24 | 2284 | 2.92× |
| sieve5m · memory | 27 | 13 | 1167 | 2.08× |
| matmul256 · cache | 6 | 3 | 2277 | 2.00× |
| qsort1m · branchy | 77 | 67 | 2478 | 1.15× |
| **geometric mean** | | | | **1.58×** |

Mojo comes out around **65× faster than CPython and 1.6× slower than C**. Only
the second number means anything: beating a bytecode interpreter by two orders of
magnitude is the entry fee for any compiled language, not a result worth
reporting. The spread against C — 1.0× on pure call overhead, 2.9× on a tight
integer-division loop — is where the actual information is.

Caveats that matter before anyone quotes these: the CPU target is wrong for both
languages (above); `fib30` and `matmul256` are near timer resolution; mandelbrot
is numerically chaotic and all three languages return slightly different counts,
so it measures speed and not correctness; and none of Mojo's actual selling
points — SIMD, `parallelize`, GPU — are exercised at all. This is scalar
single-threaded codegen, the part Mojo shares with every other LLVM language.

### The compiler knows Windows

![An animated Julia set, rendered by a Mojo pixel shader](docs/images/julia.png)

That window is a native Mojo binary. It registers a window class whose window
procedure is a Mojo function Windows calls directly, compiles the HLSL below it
at run time with `D3DCompile`, drives the whole Direct3D 11 pipeline through
COM, and holds 60fps against the display's measured refresh rate. The full
source is [examples/win32/d3djulia.mojo](examples/win32/d3djulia.mojo); what
makes it unusual is what is *not* in it. No vtable slot numbers, no GUIDs, no
struct sizes, no field offsets. Every Windows-shaped fact is a query the
compiler answers while compiling:

```mojo
# The layout is checked against Windows itself -- a disagreement is a build
# failure, not memory corruption at the first call.
comptime assert (
    size_of[DXGI_SWAP_CHAIN_DESC]()
    == winkb_struct_size["DXGI_SWAP_CHAIN_DESC"]()
), "DXGI_SWAP_CHAIN_DESC does not match Windows"

# A COM call, by interface and method name. The vtable slot -- 13, but nobody
# typed that -- is looked up in the metadata during elaboration.
var draw = com_method_of[
    def (OpaquePointer[MutUntrackedOrigin], UInt32, UInt32)
        thin abi("C") -> NoneType,
    "ID3D11DeviceContext", "Draw",
](context)

# The window procedure is a Mojo function with the C ABI; Windows calls it
# for every message the window receives.
@export("mojo_wndproc")
def mojo_wndproc(hwnd: Int, message: UInt32, wparam: Int, lparam: Int
) abi("C") -> Int:
    ...
```

How that works: this fork's compiler carries a copy of the Win32 API
metadata -- 18,271 functions, 15,764 structs with byte-exact field offsets,
7,912 COM interfaces with their IIDs and vtable orders -- as a SQLite
database, and the elaborator can read it. `winkb_query` is a compile-time
parameter expression alongside `get_env`, the same shape: a name goes in
during elaboration, a constant comes out, and the query leaves no trace in
the binary. `--emit asm` on a COM call shows exactly what a C++ compiler
emits for `p->Release()`:

```asm
ldr  x8, [x19]        ; vtable from *this
mov  x0, x19          ; this
ldr  x8, [x8, #16]    ; slot 2 x 8 bytes -- the query, folded to an immediate
blr  x8
```

The database is a declared toolchain input, so its content is part of every
compile action's cache key, and `winkb_db_hash()` folds its SHA-256 into a
binary at elaboration -- a build record can state exactly which metadata
revision produced it. Releases ship the database beside the compiler as
`lib/windows_api.db`.

On top of the queries sit three small pieces in the standard library:
`com_method_of` (the dispatcher above), `ComPtr` (COM refcounting mapped onto
Mojo ownership: copy is AddRef, destruction is Release, and a move is
provably neither -- with `adopt=` for pre-counted out-parameters and
`query_interface[T]` inferring the IID from the type), and `Win32Module`
(process-lifetime DLL cache). The metadata plumbing is
[std/sys/_winkb.mojo](mojo/stdlib/std/sys/_winkb.mojo); the compiler side is
`winkb_query` in the KGEN elaborator.

### A standard library for Windows

![The std.windows tour, run on this machine](docs/images/windows_tour.png)

Upstream Mojo does not support Windows, so it has no Windows library either:
`os` and `pathlib` are written against POSIX, and the parts that cannot be
emulated are simply absent. A POSIX shim in the compiler runtime covers the
names Mojo itself calls. `std/windows/` is the other half — the things a
Windows program actually wants.

| Module | |
| --- | --- |
| `core` | `WideString` (UTF-8 ↔ UTF-16), decoded errors, owning `Handle` |
| `registry` | `RegKey` open/create, typed get/set, subkey and value enumeration |
| `shell` | `known_folder`, `expand_environment`, `message_box` |
| `fs` | attributes, directory listing with metadata, path services, copy/move/delete, free space |
| `sysinfo` | OS version, computer and user, memory, processors, uptime, performance counter |
| `console` | UTF-8 code page, ANSI escape handling, window size, title |
| `time` | FILETIME ↔ Unix, local calendar time, file timestamps |
| `process` | `run`, `run_captured`, environment, argument quoting, `is_elevated` |
| `clipboard` | get and set text |

Two lines of that screenshot are the argument for the module existing at all.

`desktop` is `C:\Users\alban\OneDrive\Desktop`. Any program that had built
that path from `%USERPROFILE%\Desktop` — the obvious thing, and what a
POSIX-shaped port does — would be wrong on this machine, and on every
OneDrive-backed or domain-joined machine. `SHGetKnownFolderPath` is not a
convenience over the environment variable; it is the only correct answer.

`product` says **Windows 10 Home** on a Windows 11 box. `ProductName` in the
registry has lied since Windows 11 shipped, which is why `windows_version()`
goes to `RtlGetVersion` in ntdll and reports the build number — 26200 is 25H2,
26100 is 24H2, and the marketing name is not load-bearing. `GetVersionExW`
would have lied differently: it reports 6.2 to any process without a
compatibility manifest.

```mojo
from std.windows import RegKey, HKEY_LOCAL_MACHINE, KnownFolder, known_folder

def main() raises:
    print(known_folder(KnownFolder.DOCUMENTS))

    var cpu = RegKey.open(
        HKEY_LOCAL_MACHINE,
        "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0",
    )
    print(cpu.get_string("ProcessorNameString"))
```

Every struct offset in it comes from the metadata at compile time, for the
reason the section above gives: `WIN32_FIND_DATAW` is 592 bytes with
`cFileName` at 44 on 64-bit, and the numbers most sample code shows are the
32-bit ones. A wrong offset there does not fail — it reads a filename out of
the middle of a timestamp.

**Named constants come from the metadata too**, and that was not the original
plan. Writing this library meant transcribing about thirty-five constants by
hand — access masks, flag bits, error codes. Thirty-four were right.
`STARTF_USESTDHANDLES` was written as 1; it is 0x100, and 1 is
`STARTF_USESHOWWINDOW`. Nothing errored: `CreateProcessW` succeeded, the pipe
was created, `run_captured` returned exit 0 and an empty string, and the
child's output appeared on the *parent's* console. The metadata had the right
value the whole time, so `winkb_constant["NAME"]()` now folds any named
constant or flag member to a literal at compile time, and a typo is this,
with the source line:

```
note: the Win32 metadata has no 'constant_value' for STARTF_USESTDHANDLE
```

The tour that produced the screenshot is
[examples/win32/windows_tour.mojo](examples/win32/windows_tour.mojo); it runs
every function in the package against the real machine and prints what the
machine said, rather than asserting. The run continues past the crop with the
console section (which proves ANSI colour and console sizing), file
timestamps, a captured child process, and a clipboard round trip through
`café über 🐉`.

One gap, named honestly: the metadata stores 5,837 GUID-valued constants
(`FOLDERID_*`, `CLSID_*`) **without their bytes**, so `KnownFolder`'s ids are
still transcribed from `shlobj.h`. COM interface IIDs are fine — those come
from a different column, which is populated.

### Mojo on the GPU

![The Mandelbrot set, every pixel computed by a Mojo kernel on the Adreno X1-45](docs/images/mandelbrot.png)

This is the evidence. That window is zooming into seahorse valley, and every
pixel of every frame is computed by this Mojo kernel — compiled to SPIR-V,
executed on the Snapdragon's Adreno X1-45 through OpenCL:

```mojo
def mandelbrot_kernel(
    escape: Pointer[Float32, MutAnyOrigin],
    center_x: Float32,
    center_y: Float32,
    scale: Float32,
):
    var index = block_idx.x * block_dim.x + thread_idx.x
    if index < PIXELS:
        var px = index % WIDTH
        var py = index // WIDTH
        var cx = center_x + (Float32(px) - Float32(WIDTH) * 0.5) * scale
        var cy = center_y + (Float32(py) - Float32(HEIGHT) * 0.5) * scale

        var zx = Float32(0)
        var zy = Float32(0)
        var n = 0
        while n < MAX_ITER and zx * zx + zy * zy <= Float32(4):
            var next_zx = zx * zx - zy * zy + cx
            zy = Float32(2) * zx * zy + cy
            zx = next_zx
            n += 1

        escape.unsafe_offset(index)[] = Float32(n)
```

That is standard Mojo GPU code — `block_idx`, `thread_idx`, `enqueue_function`
— the same program you would write for an NVIDIA card. Nothing about the
kernel knows it is running on a Snapdragon. The full demo is
[examples/win32/adreno_mandelbrot.mojo](examples/win32/adreno_mandelbrot.mojo);
the Julia demo above painted with an HLSL pixel shader, and this closes that
era from the right direction: Direct3D is reduced to a texture upload and a
fullscreen triangle, and the GPU language is Mojo.

| 960×720, 512 max iterations, ~73M iterations/frame | per frame |
| --- | --- |
| **Adreno X1-45** — Mojo kernel via SPIR-V/OpenCL, including readback | **11–13 ms** |
| Oryon CPU, one core — the identical scalar Mojo | 250 ms |

The GPU and CPU results are compared before the window opens. Not for
bit-exactness — escape time is chaotic near the set, where a one-ulp FMA
difference legitimately moves a pixel from 512 iterations to 450 — but for
exactness where chaos cannot excuse anything: low-count, locally-flat pixels,
where wrong codegen would have nowhere to hide. Zero mismatches there.

How this exists at all: Mojo has no Snapdragon target, and Qualcomm's OpenCL
driver cannot ingest SPIR-V. The compiler side (a SPIR-V offload backend for
`--target-accelerator adreno-x1`) and the runtime side (`dragonrt`, an
implementation of Modular's unpublished `AsyncRT_*` device ABI over OpenCL,
routed through Windows' OpenCLOn12 layer) come from
[DragonMax](DRAGONMAX.md), this port's sister project, and the running record
of how the last three stacked bugs fell — invalid kernel parameter address
spaces, an `Optional[Pointer]` that never survived the C ABI, and a transfer
path that was never coherent — is in
[DRAGONMAX-JOURNAL.md](DRAGONMAX-JOURNAL.md).

### Building

Requires Windows 11 ARM64 and Visual Studio Build Tools (for the MSVC sysroot).

Three machine settings decide whether this works, none of them is discoverable
from an error message, and **one of them cannot be changed after the first
build**. Read [Three machine settings](PORT-JOURNAL.md) before building:
Developer Mode plus `startup --windows_enable_symlinks` (without both, runfiles
trees are written as copies at about a gigabyte per test target),
`LongPathsEnabled`, and a short `--output_base` — that last one has to be chosen
up front, because Bazel canonicalises the output base and a junction pointing at
a long path resolves straight back to it.

```bash
.\bazelw.cmd build //KGEN/tools/mojo:mojo
```

### Bazel

Bazel sounds like it just arrived from hell, and acts like it. Building this
tree on a little Snapdragon with the hungry Bazel was a dire experience, made
workable only with a lot of effort — every item below was learned by losing an
afternoon to it, and every one is invisible until it has already cost you the
afternoon.

- **It zipped a Python interpreter into every test.** Windows Bazel assumes
  symlinks are unavailable, so instead of a runfiles tree each of ~200 test
  targets got a self-extracting zip of its entire runfiles closure — 122 MB
  and 2,540 files *each*, including the hermetic CPython and its OpenSSL
  debug symbols, at about two minutes per target. `--build_python_zip=false`
  plus `--enable_runfiles` plus Developer Mode plus
  `startup --windows_enable_symlinks` deleted the whole category and took the
  action graph from 11,770 actions to ~3,500. All four are required at once.
- **It filled the disk twice before that was understood.** A tree of
  copies-instead-of-symlinks is quiet right up until the volume is full.
- **Defender ate half the build.** Real-time protection scans every `.obj`,
  `.lib` and `.pdb` as it is written — and the natural exclusion,
  `C:\projects`, does nothing, because essentially all build I/O happens
  under the output base in `_bazel_<user>`. With the right exclusion the
  build sustains ~160 actions/min on eight cores; without it, about half.
- **Upstream's default is a debug LLVM.** `--compilation_mode=dbg` for every
  developer build means a full-debug LLVM inside `mojo.exe`: 5–10× slower to
  produce, slower to run, and with LLVM's own assertions enabled — one of
  which aborted the compiler during tests and masqueraded as a port bug for
  a day.
- **The output base cannot be moved after the fact.** Bazel canonicalises
  it, so a junction pointing at a shorter path resolves straight back to the
  long one, and Windows' 260-character path limit then breaks things as deep
  and unrelated as Python's `_multiprocessing.pyd` refusing to load inside
  test runfiles. Choose a short `--output_base` before the first build;
  there is no second chance without rebuilding the world.
- **Git Bash mangles its labels.** MSYS path conversion rewrites `//KGEN`
  into a filesystem path mid-command; `MSYS2_ARG_CONV_EXCL` or the `.cmd`
  wrapper is mandatory, and `bazelisk` needs `tools/bazel.bat` to be found
  at all.
- **`build:windows` silently does not override.**
  `--enable_platform_specific_config` expands the platform section as if it
  were at the *start* of the command line, so any unconditional flag later
  in the same file outranks it. An override that looks correct, parses
  correctly, and does nothing.
- **The action cache is the only friend it has.** With the configuration
  finally stable, the disk cache (60 GB cap) and the discipline of never
  running `bazel clean` are what make the tree livable: the output base is
  frequently the only copy of work that costs an hour to reproduce.

None of this is Snapdragon-specific in cause — it is Windows-shaped neglect —
but on eight Oryon cores with 32 GB, mistakes a build farm shrugs off each
cost this machine an hour. The full running record, with the exact settings,
is in [PORT-JOURNAL.md](PORT-JOURNAL.md).

---

# Anatomy of Mojo

*What one 120 MB compiler binary actually contains, how a `.mojo` file becomes
machine code, and where the runtime, standard library, and MAX fit around it —
as found in the source tree during this port.*

| | |
| --- | --- |
| **1** | binary: `mojo` — driver, parser, compiler, JIT, REPL, LSP |
| **120 MB** | `mojo.exe`, with LLVM + MLIR statically inside |
| **5** | private MLIR dialects (KGEN, POP, CO, HLCF, LIT) |
| **38** | stdlib modules, pure Mojo, zero C in the library itself |
| **322** | stdlib test files |

## Part I — What Mojo is

Mojo is a systems programming language wearing Python's syntax. Functions,
structs, traits, and generics compile to native code with no interpreter and no
GC, and ownership and borrow semantics do the memory management. Older writing
about Mojo describes a Python-style `def` coexisting with a systems-style `fn`;
that is no longer true at this version, which rejects `fn` with *"'fn' has been
removed; use 'def' instead"*. It is not an isolated case — see
[language drift](docs/LANGUAGE-DRIFT.md) for the full list of constructs the
documentation still teaches and this compiler refuses, and
[dialect notes](docs/DIALECT-NOTES.md) for how to write what it accepts. It was built by Modular as the language
for writing AI kernels — code that must run on CPUs, GPUs, and accelerators from
one source — and that origin explains its two defining traits.

First, it is **MLIR-native**. Where most languages lower their AST to LLVM IR
directly, Mojo parses into Modular's own MLIR dialects and does nearly all of its
work — metaprogramming, generics, optimization — as MLIR transformations. LLVM
only sees the final, fully-specialized result.

Second, **compile-time execution is the metaprogramming system**. There is no
separate template or macro language: `@parameter` code, generic instantiation,
and constant evaluation all run in a built-in interpreter that executes the same
IR the compiler is building. Types are values at compile time.

The consequence is the unusual shape of the distribution: one large binary
containing a full compiler stack, plus a small runtime the generated code calls
into, plus a standard library written entirely in Mojo itself.

## Part II — From source to machine code

```mermaid
flowchart LR
    SRC([".mojo source"]) --> P

    P["<b>Parse</b><br/>hand-written recursive descent<br/>AST, then initial IR<br/><i>KGEN/lib/MojoParser</i>"]
    P --> R["<b>Raise to dialects</b><br/>ops in Modular's private MLIR<br/>dialects; types are first-class IR<br/><i>KGEN · POP · CO · HLCF · LIT</i>"]
    R --> E["<b>Elaborate</b><br/>an interpreter executes compile-time<br/>code, instantiates generics,<br/>folds parameters<br/><i>KGEN/lib/Elaborator · Interpreter</i>"]
    E --> L["<b>Lower</b><br/>LIT lowering, transforms,<br/>conversion to LLVM dialect<br/><i>KGEN/lib/LowerLIT · KGENToLLVM</i>"]
    L --> V["<b>LLVM 22</b><br/>stock backend, statically linked<br/>codegen, optimization, target CPUs<br/><i>third-party/llvm-project</i>"]
    V --> BIN(["<b>mojo build</b> — native binary<br/>linked by embedded lld against<br/>CompilerRT + AsyncRT<br/>PE/COFF, /MACHINE:ARM64, dynamic CRT"])

    R -. "serialized before specialization" .-> PKG(["<b>mojo precompile</b> — .mojoc package<br/>pre-elaboration IR, architecture-independent;<br/>the importing compilation elaborates it for<br/>its own target — this is how the stdlib ships"])

    classDef hot fill:#F5E3D7,stroke:#C2410C,stroke-width:2px,color:#1F1A16
    classDef exit fill:#E2EAF0,stroke:#3B5F7A,color:#1F1A16
    class E hot
    class BIN,PKG exit
```

JIT variants of the same pipeline back `mojo run` and the REPL
(`KGEN/lib/ExecutionEngine`).

**Why the elaborator is the hot stage:** generic instantiation by compile-time
interpretation is what lets one kernel source specialize for any target, and it
is why a `.mojoc` is portable while a `.o` is not. It is also why the compiler
needs its runtime present at build time — compile-time code allocates through the
same `KGEN_CompilerRT` ABI that compiled programs use at run time.

## Part III — How the repository composes

```mermaid
flowchart TB
    D["<b>driver</b> — <i>KGEN/tools/mojo</i><br/>one CLI, subcommand per tool<br/>build · run · precompile · repl · debug · doc · format · demangle"]
    C["<b>compiler</b> — <i>KGEN/lib</i><br/>parser, five dialects, elaborator/interpreter,<br/>lowering, JIT, LLDB and Jupyter glue<br/>the 120 MB lives here, plus LLVM"]
    RT["<b>runtime</b> — <i>KGEN/lib/CompilerRT · AsyncRT</i><br/>what compiled programs link against:<br/>the KGEN_CompilerRT_* C ABI and async scheduler<br/>shared libraries, so <b>one allocator serves the process</b>"]
    SL["<b>stdlib</b> — <i>mojo/stdlib/std</i><br/>38 modules of pure Mojo, shipped as one<br/>pre-elaborated std.mojoc (3.1 MB)<br/>OS access via ffi/sys, not C — why it ported unchanged"]
    MX["<b>MAX</b> — <i>max/</i> — out of scope for this fork<br/>kernels in Mojo, graph compiler and serving in Python<br/>Mojo is its kernel language the way CUDA C++ is NVIDIA's"]

    D --> C --> RT
    SL -. "compiled by" .-> C
    SL -. "calls" .-> RT
    MX -. "built on" .-> SL

    subgraph rail ["support machinery"]
        direction TB
        S1["<b>Support/ · AsyncRT/</b><br/>paths, logging, random, threading, tcmalloc glue<br/>where most Windows porting happened —<br/>POSIX assumptions live here, not in the language"]
        S2["<b>bazel/ · rules_mojo</b><br/>custom cc-toolchain driving hermetic clang<br/>this port added an MSVC-sysroot repository rule<br/>and an aarch64-pc-windows-msvc toolchain"]
        S3["<b>third-party LLVM 22</b><br/>vendored and patched; MLIR, backends, lld,<br/>LLDB, compiler-rt — statically linked into mojo"]
    end

    classDef magma fill:#F5E3D7,stroke:#7C2D12,stroke-width:2px,color:#1F1A16
    classDef hot fill:#F5E3D7,stroke:#C2410C,stroke-width:2px,color:#1F1A16
    classDef steel fill:#E2EAF0,stroke:#3B5F7A,color:#1F1A16
    classDef plain fill:#FFFFFF,stroke:#1F1A16,color:#1F1A16
    class C magma
    class RT hot
    class MX steel
    class D,SL plain
    class S1,S2,S3 plain
```

## Part IV — The process, on Windows

Upstream builds the runtime globals as shared libraries for a reason: TCMalloc
state, runtime configuration, and the allocator must exist *once* per process, no
matter how many components link them. On Linux and macOS a single libc makes that
automatic. On Windows it became the port's hardest bug: clang's default static
CRT gave every module a private heap, and cross-module frees corrupted memory
nondeterministically at teardown. The fix — `-fms-runtime-lib=dll` — restores the
intended topology.

```mermaid
flowchart TB
    subgraph proc ["one process"]
        direction LR
        EXE["<b>mojo.exe</b><br/>driver + compiler + LLVM<br/>statically linked"]
        MS["<b>MSupportGlobals.dll</b><br/>allocator authority<br/>tc_new / tc_delete, support globals"]
        AR["<b>AsyncRTRuntimeGlobals.dll</b><br/>async runtime state<br/>one scheduler per process"]
    end

    EXE --> HEAP
    MS --> HEAP
    AR --> HEAP
    HEAP["<b>one shared ucrtbase heap</b><br/>/MD everywhere — exactly one allocator per process"]

    classDef hot fill:#F5E3D7,stroke:#C2410C,stroke-width:2px,color:#1F1A16
    classDef plain fill:#FFFFFF,stroke:#1F1A16,color:#1F1A16
    class HEAP hot
    class EXE,MS,AR plain
```

**Rule this port enforces:** memory may be allocated in any module and freed in
any other, so every module must share the dynamic CRT. Static-CRT builds of this
codebase are not a packaging choice — they are undefined behaviour.

## Part V — Where the port stands

| Milestone | State |
| --- | --- |
| toolchain | Hermetic clang 22 targeting `aarch64-pc-windows-msvc`, MSVC sysroot via vswhere, GNU-style flags against the MSVC ABI — the same architecture as Modular's Linux and macOS toolchains. |
| dependencies | LLVM, MLIR, gRPC, protobuf, abseil, boringssl, curl, zlib-ng all compile. |
| `mojo.exe` | Builds, links, parses and compiles Mojo on Windows ARM64. |
| stdlib | Compiles to `std.mojoc` with warnings only — no source changes required. |
| tests | 258 of 369 targets pass; 52 fail, 4 fail to build, 55 platform-skipped. |
| Windows API | `std/windows/` — registry, shell folders, filesystem, console, system info, time, processes, clipboard — on metadata-derived layouts and constants. |
| GPU | Mojo kernels compile to SPIR-V and execute on the Adreno X1-45 via `--target-accelerator adreno-x1`; Mandelbrot at 11–13 ms/frame vs 250 ms on one CPU core. |
| next | Drive down the failures, then performance against CPython. |

> **Reading the tree yourself?** Start at `KGEN/tools/mojo/mojo.cpp` and follow a
> subcommand into `KGEN/lib`. The dialect TableGen files under
> `KGEN/include/KGEN` are the closest thing to a language-internals reference
> that exists.

---

## Licence and attribution

The Mojo compiler (`KGEN/`), the substrate, and the standard library are Apache
2.0 **with LLVM exceptions**, and this fork inherits that licence — permissive,
with a patent grant, and binary attribution waived. That is precisely why the
scope line is drawn where it is.

MAX (`max/`) is under the Modular Community License and is **out of scope** for
this fork. Scoping to compiler and stdlib keeps this work wholly inside
Apache 2.0.

Upstream is [modular/modular](https://github.com/modular/modular). All original
design credit belongs to Modular; the errors in this port are mine.

---

# The licence traps, and why they miss this work

Modular's licensing is not one document but three, and most confusion about what
you may do with Mojo comes from reading the wrong one. The traps in the stack are
real, sharply drawn, and — for a project built the way this one is — inapplicable.
The reasoning is worth writing down, because it is also the reason this repository
is built the way it is.

## Three instruments, and which governs what

| Instrument | Governs | Reach here |
| --- | --- | --- |
| **Apache 2.0 + LLVM exceptions** | the per-file source: the compiler, and 4,585 files under `max/` by header count | **this is what we use** — irrevocable, commercial use fine, derivatives fine, no hardware or field-of-use limits |
| **Community License** | Modular's **binary** SDK distributions | never invoked — no binaries used |
| **Terms of Use** | the hosted platform and accounts | never invoked — no account |

Decisively, the Community License itself concedes the point: for Apache-licensed
components, Apache **"controls over these Terms in the event of any conflict."**
The permissive grant on the source is not overridden by the terms attached to the
binaries.

## The trap, confirmed and dated

`Licenses/LICENSE` in this tree is the Community License, **Last Modified:
August 17, 2026**, and it contains — verbatim, verifiable in the file:

- **Commercial use unlimited on x86/ARM CPUs and NVIDIA hardware, capped at
  eight (8) accelerator devices for everything else.** Adreno and Hexagon are
  neither CPUs nor NVIDIA. Snapdragon is precisely the monetised class:
  free-on-NVIDIA to fight CUDA, pay-to-play everywhere else.
- **Distributed applications "must only be run on hardware expressly supported by
  MAX"** — custom hardware requires Modular's written permission "in its sole
  discretion." A Snapdragon port would literally have to ask.
- **A non-compete attached to the language**: you may not "develop an Application
  in Mojo, for any Competitive Activity."
- **A preamble** claiming the Terms bind anyone "developing software using... [the]
  Mojo programming language" at all.
- Plus mandatory logo rights for commercial users, telemetry, and a reserved right
  to begin charging.

## Then it changed, one day later

The website version is dated **August 18** and removed every one of those clauses.
Modular's own FAQ concedes it: the old licence *"capped free production use at
eight accelerators outside x86, ARM and NVIDIA... Both requirements are now gone."*
That has the unmistakable rhythm of a backlash correction. This tree still carries
the stale, harsher text — which is why the dated quotation above matters.

## The trap moved rather than died

The replacement is aimed squarely at AI-assisted reimplementation. New **§1.3**
forbids using MAX as AI input *"to produce software that reimplements or
substitutes for MAX."* The Terms of Use add the concept of an **"AI-Derived
Work"** — sweeping in *"translations, ports, transpilations, refactorings"*
performed by AI, with explicit language that clean-room separation is **no
exemption** if Modular IP was "input, reference, or inspiration."

That clause describes this project's genus with uncomfortable precision, and it
should be read carefully rather than waved away.

## Why it does not reach us

Both instruments bind on **using Modular's binaries or hosted platform**. This
project never has:

- **No account.** Nothing was ever accepted, clicked through, or signed.
- **No wheel, no prebuilt toolchain.** Not one Modular binary has entered the
  tree. On Windows ARM64 that was never even possible — a constraint that turns
  out to be legally convenient.
- **Everything descends from per-file Apache source**, whose grant Modular's own
  supremacy clause concedes controls.

And even the new §1.3 carves out *"develop[ing] Your own software that runs on or
interoperates with MAX."* An ABI-compatible runtime is interoperation by
definition.

The journal's day-by-day provenance record turns out to be evidence, not merely a
diary.

## The bright line

> **Never introduce Modular binaries, wheels, or accounts into this project.**

The moment one is used, the AI clauses attach — and they attach to a person, not
to a repository. Staying binary-free costs nothing: everything measured here was
obtained without them.

## Two residual flags

- **Trademarks are a separate axis** from copyright licensing. Names that lead
  with Modular's mark are the exposure; "MAX-compatible" in prose is defensible
  nominative use. Renaming is cheap now and expensive later, if any of this ever
  acquires commercial weight.
- **Qualcomm's QAIRT `LICENSE.pdf`** is the other licence in the stack.
  Irrelevant to the CPU and GPU lines, but it is the document to read before any
  NPU work ships Qnn DLLs inside a product.

## Caveat, honestly meant

I am not a lawyer and this is not legal advice. The structural read is solid,
quoted from the file in this tree, and dated — but it is a careful engineer's
reading, not counsel. Anyone attaching commercial weight to this work should get
a real opinion.
