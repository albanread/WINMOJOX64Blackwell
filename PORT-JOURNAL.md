# WINMOJO — Mojo on native Windows ARM64

Running record of the port. Newest entry at the bottom.

**Goal:** `mojo.exe` compiles and runs a `.mojo` file natively on Windows ARM64.
No WSL, no emulation in the shipped binary.

**Scope:** Mojo compiler (KGEN) + C++ substrate + stdlib + CPU codegen.
**Out of scope:** MAX (kernels, graph, engine, serve), GPU backends (PTX/ROCm).

**Upstream:** `modular/modular` @ `f66d4d5` (shallow). Remote `upstream`.

---

## G0 — Recon (2026-08-19)

### Legal position

| Component | License | Port it? |
| --- | --- | --- |
| Mojo compiler (`KGEN/`), stdlib, substrate | Apache 2.0 **with LLVM exceptions** | Yes — permissive, patent grant, binary attribution waived |
| MAX (`max/`) usage + distribution | Modular Community License | No — out of scope, avoids the restrictive licence entirely |

Scoping to compiler+stdlib keeps us wholly inside Apache 2.0. This is deliberate,
not incidental: it is the reason the scope line is drawn where it is.

### Why there is nothing to fork

- [Issue #620 "[Feature Request] Native Windows support"](https://github.com/modular/modular/issues/620)
  open since **September 2023**. Modular calls native Windows a "mid-term project".
- No community fork, branch, or third-party port found.
- `CLAUDE.md` states: Linux x86_64/aarch64, macOS ARM64, "Windows: Not currently supported".

### The gate we hit

`./bazelw` switches on `$OSTYPE`, handling only `darwin*` and `linux*`;
everything else falls through to `error: unsupported platform`. Under Git-Bash
here `$OSTYPE=cygwin`, so it exits 1 before Bazel ever starts.

Note: `uname` reports `MINGW64_NT-10.0-26200-ARM64` with machine `x86_64` —
Git-Bash is itself x86-emulated. Any shell-level arch detection we add must not
trust `uname -m` on this platform.

### Host toolchain — verified working

| Tool | Status |
| --- | --- |
| MSVC `19.51.36252` **native ARM64** (`Hostarm64 -> arm64`, MSVC 14.51.36231) | Verified: compiled + ran a test exe, `dumpbin` reports `AA64 machine (ARM64)` |
| `vcvarsarm64.bat` | Present (also `vcvarsx86_arm64`, `vcvarsamd64_arm64` cross variants) |
| CMake + Ninja | Bundled inside VS 18 Professional, not on `PATH` |
| Python | 3.12 **ARM64-native** |
| clang-cl | **Missing** — VS component "C++ Clang tools for Windows" not installed |
| Bazel | **Missing** |

VS 18 Professional at `C:\Program Files\Microsoft Visual Studio\18\Professional`.
`vcvarsarm64.bat` emits a benign `vswhere.exe not recognized` warning and still
sets the environment correctly.

### Porting surface — measured, not guessed

| Area | Size / finding |
| --- | --- |
| `KGEN/` C++ | 326 `.cpp`, 234 `.h` |
| Substrate `AsyncRT` `Support` `Config` `Cache` `Init` | 207 `.cpp` |
| stdlib Mojo sources | 3,671 `.mojo` repo-wide; 40 modules in `mojo/stdlib/std` |
| stdlib POSIX syscall deps | `dlopen`×2, `dlsym`×2, `fork`×2, `execvp`×1, `unistd`×1, `O_RDONLY`×1 — and **`mmap`×0, `pthread`×0** |
| Windows awareness in stdlib | **None.** No `os_is_windows` predicate exists anywhere. 5 total string hits across 4 files, one of them a TODO: *"Move this to a generic path module when Windows is supported."* |
| COFF/MSVC awareness in KGEN | Already present in 10+ files incl. `ExecutionEngine`, JIT layers, `Lexer` — inherited from LLVM |

Two readings of this, both favourable:

1. The stdlib's OS-coupled surface is genuinely tiny. Most of it is SIMD,
   collections and math, which are OS-agnostic. `mmap`×0 and `pthread`×0 mean no
   memory-mapping or threading layer to reimplement in the stdlib itself.
2. Zero existing Windows branches means no half-finished abstraction to fight —
   we add the target predicate and the shims cleanly.

### The real blocker

**There is no CMake anywhere in the repo — `find . -name CMakeLists.txt` returns
nothing. KGEN is Bazel-only.** The build system, not the language semantics, is
the hard part of this port. `bazel/internal/cc-toolchain/BUILD.bazel` declares
sysroots for `linux_x86_64`, `linux_aarch64` and `macos` only; there is no
Windows platform, sysroot, or toolchain definition.

LLVM itself is not vendored as source in-tree — it is fetched by Bazel
(`llvm_source` / `llvm_configure` in `MODULE.bazel`). KGEN carries its own
bitcode readers/writers for LLVM **17, 19 and 21** side by side.

## G1 — The build-driver chain (2026-08-19)

Traced what `./bazelw` actually does. It does not download Bazel; it downloads
**bazelisk**, which then reads `.bazelversion` and fetches the real Bazel.

```
bazelw  ->  bazelisk v1.27.0  ->  .bazelversion = buildbuddy-io/5.0.382  ->  Bazel
```

Checking each link for a Windows ARM64 build:

| Link | windows-arm64? |
| --- | --- |
| bazelisk v1.27.0 | **Yes** — `bazelisk-windows-arm64.exe` is published |
| Upstream `bazelbuild/bazel` 9.2.0 | **Yes** — `bazel-9.2.0-windows-arm64.exe` |
| Pinned `buildbuddy-io/bazel` 5.0.382 | **No** — darwin-arm64, darwin-x86_64, linux-arm64, linux-x86_64 only. No Windows asset on any release. |

So the pin is the blocker, not Bazel. Native ARM64 Windows Bazel exists upstream;
Modular pin a BuildBuddy fork that is never built for Windows.

Encouragingly, every BuildBuddy reference in the repo is remote cache / BES
plumbing (`--bes_backend`, `--remote_cache`, `--remote_downloader`) and all of it
sits behind the optional `:cache` and `:public-cache` configs. Nothing in a
*local* build appears to need the fork. Repinning `.bazelversion` to upstream
Bazel is a one-line experiment.

### The expensive discovery

`--config=prebuilt-mojo` — the route the contributor docs tell you to use, and
the only cheap one — **downloads a prebuilt Mojo toolchain**. No Windows build of
that toolchain exists, so the config is unavailable to us by definition.

We are forced onto `--config=build-mojo`, which builds KGEN *and* LLVM from
source. There is no cheap path onto this platform: the port requires a full
compiler build from day one.

### The cc-toolchain is fully custom

`bazel/internal/cc-toolchain/BUILD.bazel` builds on the modern
`@rules_cc//cc/toolchains` API — `cc_toolchain`, `cc_sysroot`,
`cc_artifact_name_pattern`, plus their own `features/` and `tools/` with a
`PLATFORMS` list. Sysroots are hand-declared for `linux_x86_64`,
`linux_aarch64` and `macos`.

It does **not** use Bazel's built-in MSVC auto-detection, so we cannot get
Windows C++ for free by pointing Bazel at `vcvarsarm64`. A Windows toolchain has
to be written inside their framework. This is the main structural work of the
port.

### Ladder

| Gate | Goal | Status |
| --- | --- | --- |
| G0 | Recon, licence, toolchain, surface | Done |
| G1 | Identify the build-driver blocker | Done — repin `.bazelversion` to upstream, add a `bazelw` Windows entry point |
| G2 | Windows/MSVC `cc_toolchain` + `windows_arm64` platform in their rules_cc framework | Main structural work |
| G3 | Build LLVM + MLIR + KGEN from source (`--config=build-mojo`) | Multi-GB, multi-hour |
| G4 | `mojo.exe` links natively | |
| G5 | stdlib shims: `dlopen`→`LoadLibrary`, `dlsym`→`GetProcAddress`, `fork`/`execvp`→`CreateProcess`, `unistd`/`O_RDONLY`; add the missing `os_is_windows` predicate | ~8 files |
| G6 | `hello.mojo` compiles and runs natively on Windows ARM64 | Goal gate |

G1's fix is cheap and testable. G3 is the long pole and cannot be deferred.

---

## G1 — Done. Bazel runs natively on Windows ARM64 (2026-08-19)

**Result: `bazel query //KGEN:all` succeeds, exit 0, 617 targets enumerated,
including `//KGEN:mojo`.** The whole bzlmod module graph resolves on Windows.
No emulation anywhere in the chain.

The BuildBuddy fork was **not** load-bearing. Repinning to upstream Bazel was
sufficient, which confirms the G1 reading: their remote-cache plumbing is all
behind optional configs.

### The experiment

Ran bazelisk against the **unmodified** pin first, to prove the diagnosis rather
than assume it:

```
Downloading .../buildbuddy-io/bazel/releases/download/5.0.382/bazel-5.0.382-windows-arm64.exe...
could not download Bazel: ... failed with error 404
```

Bazelisk itself is flawless on Windows ARM64 — it resolved the fork, built the
correct URL, and asked for the right file. The file simply does not exist.
Repinning to `9.2.0` then downloaded `bazel-9.2.0-windows-arm64.exe` and printed
`bazel 9.2.0`.

### Changes

| File | Change |
| --- | --- |
| `.bazelversion` | `buildbuddy-io/5.0.382` -> `9.2.0`. Original preserved at `build/.bazelversion.upstream-orig`. |
| `bazelw` | Added an `msys*`/`cygwin*` branch with `.exe` suffix handling and pinned bazelisk SHAs for both Windows arches. |
| `bazelw.cmd` | New. Native entry point for cmd/PowerShell, no Git-Bash needed. |
| `tools/bazel.bat` | New. Windows counterpart of `tools/bazel`. |

bazelisk `windows-arm64` sha256
`46d97f32458cd88dd4c2c6ad1c597e02d38ee3a1d07b07715c5a9e1b0c09a6dc`, verified
equal to the digest GitHub publishes for the asset.

### Three Windows traps, all real

1. **Arch detection lies.** From Git-Bash on this ARM64 machine, `uname -m` says
   `x86_64` and `$PROCESSOR_ARCHITECTURE` says `AMD64` — Git-Bash is itself an
   x86-emulated process. Only `uname -s` carries the truth
   (`MINGW64_NT-10.0-26200-ARM64`). `bazelw` now keys off `uname -s` and
   explicitly does not trust `$arch`. Native cmd reports `ARM64` correctly, so
   `bazelw.cmd` can use `%PROCESSOR_ARCHITECTURE%`.

2. **The wrapper must be `tools/bazel.bat`, not `.cmd`.** Determined
   empirically: with `tools/bazel.cmd` in place bazelisk silently ignored it and
   ran Bazel directly, so `build/wrapper.bazelrc` was never generated and
   `.bazelrc`'s hard `import` of it aborted the build. Renaming to `.bat` made
   bazelisk delegate immediately. A silent non-delegation is a nasty failure
   mode — it looks like an unrelated rc-file error.

3. **Git-Bash mangles Bazel labels.** `./bazelw query '//KGEN:all'` fails with
   `invalid package name '/KGEN'` because MSYS path conversion rewrites `//...`
   into a Windows path. Use `MSYS_NO_PATHCONV=1` (verified working) or drive it
   from PowerShell via `bazelw.cmd`.

### Notes for later gates

- `detect_local_resources.sh` is pure GPU detection and its `else` branch
  assumes macOS, so it cannot run on Windows. Since GPU is out of scope,
  `tools/bazel.bat` writes an empty `local-resources.bazelrc`, which is exactly
  what a GPU-less Linux host produces.
- `tools/bazel.bat` rejects `--config=prebuilt-mojo` with an explanatory message,
  since that config cannot ever work on Windows.
- `//KGEN:mojo` is an `alias` rule, so the real binary target needs resolving
  before G4.

**Next: G2** — the `windows_arm64` platform and an MSVC `cc_toolchain` in their
custom `rules_cc` framework. Nothing further can build until that exists.

---

## G2 — Windows ARM64 toolchain declared (2026-08-19)

### Correction to the G1 plan

G1 called this "write an MSVC `cc_toolchain`". That was wrong, and reading
`tools/tools.bzl` changed the approach entirely: **Modular do not use MSVC on any
platform.** Every toolchain is hermetic Clang/LLVM — `@clang-{platform}//:bin/clang`,
`compiler = "clang"`, lld, and hermetic sysroots.

So writing an MSVC toolchain would have meant rewriting every `cc_args` in
`args/` and `features/` from GNU-style flags to `/W4`-style MSVC flags. Instead
we add a *fourth hermetic clang platform* and target `aarch64-pc-windows-msvc`
with the ordinary clang driver, which keeps every existing GNU-style arg working
unchanged. Using `clang-cl` would have reintroduced exactly the flag-dialect
problem, so it is deliberately avoided.

### The lucky break

Modular pin **LLVM 22.1.4** and host their own builds on S3, with no Windows
artifact. But upstream LLVM publish
`clang+llvm-22.1.4-aarch64-pc-windows-msvc.tar.xz` — *the exact same version*.
So `clang.BUILD`'s expected `lib/clang/22/...` layout lines up with no patching,
and we source that one platform from `llvm/llvm-project` releases instead of
Modular's S3. This is the difference between "port the toolchain" and "add a
platform".

737 MB, sha256 `958e314fc28968c3895a61c0b9ae54c9e4ec7a409ec4b59cc02c9c6a0ae90be4`.

### Changes

| File | Change |
| --- | --- |
| `BUILD.bazel` | Added `//:windows_arm64` config_setting and its `prebuilt_mojo_toolchain_enabled` entry. |
| `bazel/common.MODULE.bazel` | Added the `clang-windows-arm64` http_archive. |
| `MODULE.bazel` | Instantiated `windows_sysroot_repository`. |
| `bazel/internal/cc-toolchain/windows_sysroot_repository.bzl` | **New.** Locates MSVC + Windows SDK, emits `cc_args`. |
| `bazel/internal/cc-toolchain/tools/tools.bzl` | Added `windows-arm64` to `PLATFORMS` plus a separate `_declare_windows_tools`. |
| `bazel/internal/cc-toolchain/BUILD.bazel` | Windows sysroot args, target-triple args, four artifact-name patterns, toolchain registration, coverage_support entry. |

### Why Windows needs its own tool declarations

The existing tool map cannot be reused as-is:

- The `clang`/`clang++`/linker tools are **bash wrappers**
  (`multi-platform-clang.sh` and friends) that Windows cannot exec. Windows binds
  the `.exe` binaries directly.
- There is **no separate linker driver**: for a `windows-msvc` target the clang
  driver spawns `lld-link` itself, so `link_actions` map to `clang++`, with
  `:ld` carried in the tool's `data` so lld is present in runfiles.
- `llvm-otool`, `llvm-install-name-tool` and `dsymutil` are Mach-O tools with no
  PE/COFF meaning, so they are omitted.
- `dwp` is omitted: split DWARF does not apply to PDB-based debug info.

### The sysroot problem, and why this one is not hermetic

There is no `--sysroot` for an MSVC target, and `.bazelrc` sets
`--incompatible_strict_action_env`, so clang cannot discover MSVC from the
environment the way it does in a `vcvars` shell. `windows_sysroot_repository`
therefore resolves the paths once at fetch time — via `vswhere`, falling back to
scanning the standard install layout — and bakes them into `cc_args`. It fails
loudly with an actionable message if a directory is missing, rather than letting
clang fail later with a confusing missing-header error.

This one is deliberately **not** hermetic. Microsoft's licence does not permit
redistributing the CRT headers and import libraries the way the Linux sysroots
are redistributed, so a hermetic Windows sysroot would have to be assembled on
the machine anyway.

### Verified

- `bazel query //bazel/internal/cc-toolchain:all` exits 0 and lists
  `windows-arm64-toolchain`, `windows-arm64_clang_toolchain`, all four artifact
  patterns and `windows_arm64_target`.
- `bazel query @sysroot-windows-arm64//:all` exits 0: the repository rule runs
  and detects **MSVC 14.51.36231** and **Windows SDK 10.0.26100.0**, emitting
  correct `-imsvc` include paths and `-L` library paths for `arm64`.

### Not yet verified

**Nothing has been compiled.** The 737 MB clang archive has not been downloaded,
so no C++ has gone through this toolchain. Declaration and analysis are proven;
codegen is not. Expect real iteration here — flag-dialect mismatches in `args/`
and `features/`, and CRT link details, will only surface at first compile.

### Trap: do not mix shells

Driving Bazel from Git-Bash and PowerShell alternately restarts the Bazel server
every time, because Git-Bash injects
`--host_jvm_args=-Dbazel.windows_unix_root=...` and PowerShell does not. Pick one
shell per session. PowerShell + `bazelw.cmd` is the better default, since it also
avoids the `//`-label mangling.

**Next: G3** — fetch the clang archive and put real C++ through the toolchain.

---

## G3 — First contact with the toolchain (2026-08-19)

The 737 MB clang archive downloaded and extracted in 118 s. A smoke `cc_binary`
was added at `bazel/internal/cc-toolchain/smoke` — deliberately plain
`rules_cc` rather than the `modular_*` macros, so a failure there is
unambiguously a toolchain problem rather than a repo-convention one.

Five blockers hit in sequence. Four are fixed; the fifth is open.

### Fixed

1. **`clang.BUILD` does not fit the Windows distribution.** compiler-rt is
   `clang_rt.*` with no `lib` prefix under `lib/clang/22/lib/windows`, there is
   no `lib/clang/22/share`, and everything is `.exe`. Added
   `bazel/public-patches/clang-windows.BUILD` rather than relaxing the shared
   globs, so a genuinely missing file on Linux or macOS still fails loudly.

2. **Six selects in `args/BUILD.bazel` had no default**, covering only linux and
   macos, so each failed analysis on Windows. Each now has an explicit Windows
   branch, and the target triple moved into the existing `compile_and_link_args`
   select instead of a bespoke `cc_args` target.

3. **Two flags are actively wrong, not merely redundant.** `-fPIC` is rejected as
   unused for PE/COFF, and `-Werror=unused-command-line-argument` promotes that
   to a hard error. `-fno-autolink` suppresses the `#pragma comment(lib, ...)`
   directives in the MSVC headers, which is precisely the mechanism that selects
   a CRT variant matching the compilation mode — so it is dropped on Windows
   rather than pinning CRT libraries by hand.

4. **No `sandboxed` strategy exists on Windows**, and naming one is a hard error
   rather than a fallback. Added a `build:windows` section; the repo already sets
   `--enable_platform_specific_config`.

Also fixed `tools/bazel.bat`: cmd's `for` treats `=` as a delimiter, so
`--config=build-mojo` was silently split in two and never matched.

### Open blocker: no Windows ARM64 Python below 3.11

```
rules_python:python WARNING: No host compatible runtime found compatible with version 3.10
Error in fail: Unable to find interpreter for pip hub 'grpc_python_dependencies'
for python_version=3.9 ... Expected to find python_3_9_host among registered versions:
  python_3_11_host python_3_12_host python_3_13_host python_3_14_host
```

`PYTHON_VERSIONS` lists `3_10` through `3_14`, but only 3.11+ ever register on
this host: **rules_python publishes no `aarch64-pc-windows-msvc` interpreter for
3.9 or 3.10.** Adding `3_9` to the list was tried and reverted — it changes
nothing but the warning text, which confirms the gap rather than closing it.

`grpc` demands a 3.9 interpreter for its `grpc_python_dependencies` pip hub, and
toolchain resolution evaluates that extension even for a pure C++ target.

Scoping the mypy aspect to linux and macos (below) moved the failure from
"Analysis of aspects" to the target itself, which proves the aspect was one
route in but not the only one.

Candidate fixes, cheapest first:

- **Exclude grpc.** It is almost certainly a MAX serving dependency, and MAX is
  already out of scope. If nothing in the KGEN graph needs it, the cleanest fix
  is for it not to be in the graph at all.
- Override grpc's `python_version` to something with a win-arm64 runtime.
- Supply a local 3.9 via `local_runtime` rather than a hermetic download.

The first is most in keeping with the port's scope, and should be tried first.

### Note on the mypy aspect

`build --aspects=//bazel/pip:mypy.bzl%mypy_aspect` was applied unconditionally,
so it attached to C++ targets too. `--aspects` accumulates, so neither
`--aspects=` nor a `build:windows` section can clear it — it has to not be added
in the first place. It is now scoped to `build:linux` and `build:macos`. Python
linting has no bearing on porting a C++ compiler.

### Python versions: fixed by patching the modules that ask for 3.9

The 3.9 problem was not grpc-specific. `grpc` and `protoc-gen-validate` both
declare `PYTHON_VERSIONS = ["3.9" ... "3.13"]` and create a toolchain and a pip
hub per version — pgv copies grpc's block verbatim. Both are patched to start
at 3.11, using the `single_version_override` patches list Modular already
maintain for grpc, which is also where they already strip macOS x86
special-casing. So this follows an established mechanism rather than adding one.

Worth recording: **MODULE.bazel patches do take effect during bzlmod
resolution**, which was not obvious beforehand and is what makes this approach
viable at all.

Note this is *not* about compiling grpc. Nothing grpc-related is compiled; the
failure is in dependency resolution, and it blocks even a plain `cc_binary`
because toolchain resolution evaluates the pip extension regardless of what is
being built.

### Open blocker: Winsock fails inside repository rules

```
File ".../python_3_12_host/Lib/asyncio/windows_events.py", line 8, in <module>
  import _overlapped
OSError: [WinError 10106] The requested service provider could not be loaded or initialized
```

`rules_pycross` runs pip to install a wheel, pip imports `tenacity`, which
imports `asyncio`, which on Windows imports `_overlapped`, which initialises
Winsock. `WinError 10106` is `WSAEPROVIDERFAILEDINIT`.

What has been ruled out:

- **Not a broken interpreter.** Running that exact `python.exe` directly outside
  Bazel, `import _overlapped` succeeds. The interpreter also reports `ARM64
  64bit`, so it is not an emulated x64 build.
- **Not a missing environment variable.** Passing `SystemRoot`, `windir`,
  `SystemDrive`, `PATH`, `TEMP` and `TMP` through with `--repo_env` changes
  nothing. An earlier run that appeared to fix this was misread: repository
  evaluation order is not deterministic, so it had merely surfaced a different
  failure first. The `--repo_env=SystemRoot` line was therefore reverted rather
  than kept as unverified configuration.

So the failure is specific to Winsock initialising inside Bazel's
repository-rule subprocess on Windows ARM64, and the cause is not yet
identified.

Options not yet tried, roughly in order of appeal:

- Find out whether `rules_pycross` is reachable from the KGEN graph at all. Like
  grpc, it may be MAX-only, in which case the fix is for it not to be in the
  graph.
- Pin `rules_pycross` to a version whose bootstrap avoids pip, or patch its
  wheel install to not import `asyncio`.
- Drive `clang.exe` directly for one run to prove the compiler, sysroot and CRT
  link work, decoupling that proof from the Bazel dependency graph.

The last is worth doing regardless: it separates "is the toolchain right" from
"does the repo's dependency graph resolve on Windows", which are independent
risks currently entangled.

### The toolchain itself is proven correct

Bypassed Bazel entirely and drove `clang++.exe` with the exact flag set the
`windows-arm64` toolchain would use — every `cc_args` from `args/BUILD.bazel`
plus the include and library paths `windows_sysroot_repository` generated.
Preserved as `bazel/internal/cc-toolchain/smoke/toolchain_check.sh` so it can be
re-run whenever the toolchain args change.

Result: compiles, links, and runs.

```
winmojo smoke ok: windows-arm64-clang
pointer width: 64 bits
```

`dumpbin` reports `AA64 machine (ARM64)`, Windows CUI subsystem, 153,600 bytes.

This decouples two risks that were entangled: **the toolchain design is sound**,
and everything still failing is dependency-graph plumbing. It also settles the
open question from G2 — `-fno-exceptions` and `-fno-rtti` *do* work against the
MSVC STL, so `<vector>` and `<string>` compile despite the STL's use of
exceptions internally. That had been the largest unknown in the flag set.

**And it found a real bug that Bazel had not yet reached.**
`windows_sysroot_repository` emitted `-imsvc` for the MSVC and SDK include
directories. `-imsvc` is a **clang-cl** flag; the clang driver rejects it with
`error: unknown argument: '-imsvc'`. Since the toolchain deliberately uses the
clang driver rather than clang-cl to keep the GNU-style args working, the
correct spelling is `-isystem`. Fixed.

Worth noting the sequencing: this bug sat behind the pip/Winsock failures and
would only have surfaced after they were solved. Testing the toolchain directly
found it immediately, which is a good argument for keeping that script around.

### Scope correction: "not built here" is not "chop it out"

MAX is being ported to Windows ARM64 / Snapdragon / Adreno / Hexagon NPU as a
separate project that forks this trunk. So while MAX is not *built* here, every
MAX integration point — grpc, protoc-gen-validate, rules_pycross, the pip and
python plumbing — has to be made to **work** on Windows ARM64, never deleted or
excluded from the graph to turn a build green. Removing a dependency to get a
build passing here would leave a hole that the MAX port inherits.

An earlier suggestion in this journal to check whether `rules_pycross` was
reachable and keep it out of the graph was wrong on those grounds, and is
withdrawn. The distinction that does hold is between a *platform gap* and an
*inapplicable concept*: Mach-O tools such as `llvm-otool` and
`llvm-install-name-tool` have no PE/COFF meaning, and omitting those is not the
same as dropping a dependency.

### Winsock, solved: rctx.execute replaces the environment

`rules_pycross`'s `install_venv_wheels` does:

```python
env = dict(PYTHONPATH = str(rctx.path(pip_whl)))
result = rctx.execute([...], environment = env)
```

`rctx.execute(environment = ...)` **replaces** the environment rather than
extending it, so the subprocess gets `PYTHONPATH` and nothing else. Windows
cannot initialise Winsock without `SystemRoot`, so any import reaching `asyncio`
dies with `WinError 10106`. pip imports `tenacity`, which imports `asyncio`.

Reproduced exactly, outside Bazel:

| Environment passed to the same interpreter | Result |
| --- | --- |
| `{PYTHONPATH}` — what the rule passes | `WinError 10106` |
| `{PYTHONPATH, SystemRoot}` | `OK` |

This also explains why `--repo_env=SystemRoot` never helped: the rule discards
the inherited environment before that flag can matter. It is an upstream
`rules_pycross` bug, not a Modular one, and it is patched rather than routed
around.

Two process notes worth keeping:

- Earlier guesses at this — missing env vars, then
  `--sandbox_default_allow_network` — were both wrong, and `env -i` testing
  wrongly exonerated the environment because MSYS does not produce a truly empty
  Windows environment block. Reading `repo_venv_utils.bzl` found it in minutes.
  Read the code before theorising about the flags.
- The patch is matched case-insensitively with a fallback, because whether
  Bazel reports `SystemRoot` or `SYSTEMROOT` was not worth another guess.

With that fixed, analysis moves past all the pip machinery and into the C++
toolchain proper, where the remaining failures are ordinary missing-Windows
branches in `select()`s.

### G3 reached: Bazel builds and runs a native Windows ARM64 binary

```
$ bazel build --config=build-mojo -c fastbuild //bazel/internal/cc-toolchain/smoke
INFO: Build completed successfully, 5 total actions

$ ./bazel-bin/.../smoke.exe
winmojo smoke ok: windows-arm64-clang
pointer width: 64 bits
```

`dumpbin` reports `AA64 machine (ARM64)`, Windows CUI. No manual flags: plain
`bazel build`. The whole chain now works — bazelisk, Bazel, the module graph,
the pip and python plumbing, the hermetic clang, the MSVC sysroot, compile and
link.

Five further problems were solved to get here.

1. **Path mapping requires sandboxing.** `--experimental_output_paths=strip`
   makes CppCompile "require sandboxing due to path mapping", which Windows
   cannot provide. Disabled via the wrapper.

2. **Symlinked sysroots glob to nothing on Windows.** The first attempt mirrored
   `macos_sysroot_repository` and symlinked the MSVC and SDK trees in. The
   symlinks were created and were traversable from a shell, but Bazel's `glob`
   does not follow symlinked directories on Windows, so every `directory` target
   had empty srcs. The rule now **copies** instead — about 1.6 GB, a slower
   first fetch, and the price of Bazel actually seeing the headers.

3. **`directory` reports its package path, not its srcs' root.** With all eight
   targets declared in the repository root BUILD file, every one resolved to the
   repository root, so the toolchain silently emitted five identical `-isystem`
   flags pointing at the same place. That is why the macOS rule puts its
   `directory` inside `sysroot/BUILD.bazel`. Each copied tree now gets its own
   BUILD file and is referenced as `@sysroot-windows-arm64//<name>:dir`.

4. **`-D_DEBUG` means something else on MSVC.** `args/modular:assertions` pairs
   it with `-D_GLIBCXX_ASSERTIONS`, which is a libstdc++ idiom. On MSVC `_DEBUG`
   switches the entire CRT to its debug variant, so the STL emitted calls to
   `_CrtDbgReport` and the link failed on it. Windows keeps `-UNDEBUG`, which is
   the actual intent — `assert()` stays live outside production builds.

5. Shell actions need `BAZEL_SH`, since the builtin module map generator is a
   bash script.

The lesson repeated throughout: three of these produced misleading errors a long
way from their cause. Symlinked globs surfaced as "absolute path inclusion(s)
found"; the `directory` path bug surfaced as the same thing; `_DEBUG` surfaced as
an undefined symbol in `<vector>`. Dumping the actual command line with
`--subcommands` found two of them immediately after flag-level guessing had
failed.

**Next: G4** — point this at KGEN and build the compiler itself. The toolchain is
proven on one translation unit; KGEN is 326 `.cpp` files plus LLVM.

---

## G4 — Building KGEN (2026-08-19, in progress)

### Method

`--nobuild` runs loading and analysis without executing actions, so each missing
`select()` branch surfaces in about a second instead of hours into an LLVM
compile. Worth using for the whole of this gate.

### Fixed so far

- **`Support:Base` library naming.** Only the shared-library *suffix* was
  platform-dependent; the `lib` prefix and `.a` were unconditional. PE/COFF uses
  no prefix and `.dll`/`.lib`, so the whole set is now selected. These have to
  agree with the `artifact_name_patterns` the Windows toolchain declares, or
  runtime lookups construct names that were never produced. The select is
  *flattened*, not nested: `_process_defines` parses it with with_cfg.bzl's
  `decompose_select_elements`, which cannot handle a select inside a select.
- **Mojo's own target triple** is `aarch64-pc-windows-msvc`. Deliberately no
  `--target-cpu`: the other platforms pin one because their hardware is known,
  whereas Windows ARM64 spans several Snapdragon generations whose LLVM names
  move between releases. The triple is the part that must be right.
- **tcmalloc / gperftools** support neither Windows, so those aliases resolve to
  `empty_lib` and the process keeps the system allocator. A performance choice,
  not a correctness one.
- **`Support:Globals`** force-links an MLIR symbol by its *Itanium-mangled*
  name, which does not exist under the MSVC ABI. It only matters for matching
  MLIR types across separate shared objects, and `mojo.exe` links as a single
  static binary, so Windows takes no linkopt. Must be revisited before building
  Mojo as DLLs.
- **LLDB** attaches natively on Windows rather than through a debug server, so
  no `LLDB_DEBUGSERVER_PATH` is exported.

### Current blocker: crashpad has no Windows targets

`Support:CrashReporting` depends unconditionally on `@crashpad//:client`, and
Modular's hand-written `crashpad.BUILD` — 679 lines — only defines
`mini_chromium_linux`/`_macos`, `util_linux`/`_macos` and `client_linux`/`_macos`.
Its compat include list literally reads `includes = ["compat/non_win"]`.

The good news is that **the Windows sources are already in the vendored
tarball**: `client/crashpad_client_win.cc`, `client/crash_report_database_win.cc`,
`util/win/` (63 files), `compat/win/` (9 files) and `handler/win/`. Nothing needs
fetching or patching upstream — only Modular's Bazel wrapper needs extending.

So this is mechanical rather than novel: add `mini_chromium_windows`,
`util_windows` and `client_windows` targets, swap `compat/non_win` for
`compat/win`, and translate the source lists from crashpad's own GN build.

Scope note: only the **client** is linked into `mojo.exe`. `handler/win` builds a
separate crash-handler executable and is not on the critical path, so the client
comes first. Crash reporting stays in the graph either way — MAX uses it, and
removing it would leave a hole the MAX port inherits.

### Recon: crashpad is the *only* remaining analysis blocker

Rather than write the crashpad BUILD blind, the dependency was removed in a
throwaway edit purely to enumerate what else stands between here and compiling
C++. Two things came out of it, and the edit was reverted immediately.

**1. `//KGEN:mojo` is the wrong target.** It aliases to `mojo-full`, the
debugger-bundled variant, whose dependency chain is:

```
//KGEN:mojo -> mojo-full -> //KGEN:gdb-server
  -> lldb:gdb-server -> lldb:lldb-server   <-- marked incompatible
```

LLVM's own Bazel overlay marks `lldb-server` incompatible on Windows, correctly:
LLDB attaches natively there rather than through a remote debug server. The
plain `//KGEN/tools/mojo:mojo` target is the compiler binary without the
debugger bundle, and is the right thing to build. This is target selection, not
scope reduction — `mojo-full` is a packaging concern.

**2. With crashpad out of the way, analysis of the entire Mojo compiler passes
on Windows ARM64.** `bazel build --nobuild //KGEN/tools/mojo:mojo` exits 0.
Putting the dependency back leaves exactly one error, in crashpad's own
`BUILD.bazel:463`.

So the build-system work is nearly done: crashpad is the last plumbing gate, and
past it the remaining work is compiling roughly 326 KGEN `.cpp` files plus LLVM
and MLIR — real C++, where MSVC STL differences, the `-Werror` set and POSIX
assumptions in the source will be the actual obstacles.

### Repository state

The fork now has a real remote: `origin` =
`github.com/albanread/WINMOJO.git`, with `upstream` = `modular/modular`.

The first push was rejected — `did not receive expected object` — because the
working copy was a `--depth 1` clone and the pack was incomplete without the
base commit's ancestors. `git fetch --unshallow upstream` fixed it: the history
is now complete at 53,622 commits, which also makes future rebases onto upstream
tractable.

---

## G4 — Compiling KGEN: the first two full builds (2026-08-19)

Crashpad landed first (see below), then the whole compiler was pointed at the
toolchain. Two full builds so far.

| | actions | failed targets |
| --- | --- | --- |
| Build 1 | 8,734 / 8,738 | **484** |
| Build 2 | in progress | **3** so far at 3,099 / 8,885 |

Both were run with `--keep_going`, which matters: a multi-hour build that stops
at the first error teaches you one thing, whereas one that continues inventories
everything. Classifying ~2,000 errors from build 1 by normalising the messages
(strip quoted identifiers and digits, then sort by frequency) reduced them to
four causes.

### The four systemic causes, in order of blast radius

**1. MSVC flag dialect in third-party BUILD files — 1,633 errors.** curl passes
its eight feature defines as `/DBUILDING_LIBCURL` and friends; boringssl's
`util.bzl` passes `/std:c11`. Both spellings are clang-cl only. Under the
ordinary clang driver a leading slash is a *file path*, so every affected
translation unit died with `no such file or directory: '/DWIN32'`.

This is the recurring bill for choosing the clang driver over clang-cl in G2,
and it is still the right trade — clang-cl would have meant rewriting every
GNU-style flag in `args/` and `features/`. Worth doing proactively: a scan of
every external `BUILD`/`.bzl` for MSVC-style flags found only these two.
grpc's are confined to an RBE toolchain config that is never used.

**2. `NOMINMAX` — ~224 errors.** `windows.h` defines `min` and `max` as
function-like macros, so `std::numeric_limits<size_t>::max()` becomes a macro
invocation with the wrong arity. It surfaces either as "too few arguments
provided to function-like macro invocation" or, more confusingly, as "invalid
operands to binary expression". Almost all of it was boringssl.

This belongs in the toolchain's `compile_args`, not per-target, because it has to
hold for third-party code too. `WIN32_LEAN_AND_MEAN` went in beside it: it cuts
compile time and, usefully, excludes `wincrypt.h`, whose `X509_NAME` and `PKCS7`
macros collide with boringssl's own names.

**3. `layering_check` had no standard library in the module map.** Windows got
only clang's builtin headers, because MSVC has no `--sysroot` and G3 therefore
paired it with no sysroot directory. The other platforms cover their standard
library through exactly that directory, so on Windows every `#include <atomic>`
or `<string>` belonged to no module and was rejected with "does not depend on a
module exporting". Fixed by adding the MSVC STL and SDK directory targets to
`builtin_module_map`.

**4. `parse_headers` had no wrapper to create its marker.** The feature works by
setting `PARSE_HEADER` and expecting the compiler wrapper to create that file;
the `.sh` wrappers end with `touch "${PARSE_HEADER}"`. G2 bound `clang.exe`
directly, so the marker never appeared and every header parse failed with "not
all outputs were created". Fixed with `.bat` wrappers that mirror the shell
ones — including resolving the compiler relative to the execution root, which is
how the `.sh` version works too — and create the marker only on success.

### The real C++ problems, and a pattern worth knowing

Four dependencies needed source patches, and **every one of them already had a
portable fallback sitting behind the failing branch**. In each case the fix was
to correct an over-broad feature test rather than to write anything new.

| Dependency | Failing construct | Why it breaks on Windows ARM64 |
| --- | --- | --- |
| xxhash | `__asm__("" : "+w" (var))` | clang cannot lower the NEON `"+w"` constraint: "don't know how to handle tied indirect register inputs" |
| protobuf/upb | hand-written AArch64 assembly in `encode_longvarint` | LLVM cannot size a function containing inline asm, so SEH unwind emission fails |
| abseil | `__builtin_nontemporal_store` | `__m128i` is MSVC's `__n128`, a *union*, which the builtin rejects |
| LLVM BLAKE3 | `__builtin_shufflevector` | `vreinterpretq_*` yields `__n128` rather than a clang vector type |

Two lessons generalise:

- **`defined(__aarch64__) && defined(__clang__)` is true on Windows too.** Three
  of these four guards assumed that combination implied a Unix-like ARM64
  target. Adding `!defined(_WIN32)` was the whole fix in each case.
- **MSVC's NEON types are unions, not vector types.** Anything using clang
  vector builtins on `__m128i`/`uint8x16_t` will fail. abseil's case is
  especially misleading: `ABSL_HAVE_BUILTIN(__builtin_nontemporal_store)`
  reports the builtin as *present*, because it is — it just refuses this type.

The upb one is the most interesting for this port specifically, because Windows
ARM64 **requires** unwind data for every function. The failure is not cosmetic
and cannot be waived; the assembly simply cannot be used here.

### Method notes

- `--nobuild` for analysis-only passes: each missing `select()` branch surfaces
  in about a second rather than hours into a compile.
- `--subcommands=pretty_print` to see the real command line. This found the
  `-imsvc` bug and the collapsed `-isystem` paths immediately, after flag-level
  guessing had failed on both.
- **Generate patches with `git diff`, never by hand.** Hand-written unified-diff
  hunk headers were wrong three times in a row here; copying the file into a
  scratch git repo, editing it, and diffing is both faster and correct. Always
  `git apply --check` before handing a patch to Bazel, since Bazel's failure
  mode is a module-resolution error far from the cause.

---

## G5–G7 — The road to test results and a Python comparison (2026-08-19)

The goal is now explicit: run the Mojo test suite on Windows ARM64, report how
many pass, and compare performance against Python. That decomposes into three
gates, and the recon for each is done.

### What the test suite looks like

**322 `.mojo` test files** under `mojo/stdlib/test`, plus a `benchmarks/` tree.
Each test directory declares one `mojo_test` target per source file:

```python
[
    mojo_test(name = src + ".test", srcs = [src], ...)
    for src in glob(["*.mojo"])
]
```

So once `mojo.exe` links, `bazel test //mojo/stdlib/test/...` gives a pass/fail
count directly, with no new harness. Worth noting for honest reporting later:
some tests already carry `target_compatible_with` constraints pinning them to
Linux — `test_erf.mojo` and `test_tanh.mojo` among them — so those will be
*skipped*, not failed, and the denominator on Windows is not 322.

### G5: the stdlib has no concept of Windows

`CompilationTarget` had `is_linux()` and `is_macos()` and nothing else, and every
OS-specific value in the standard library flows through `platform_map`, which
accepted only `linux` and `macos` arms. Until that changed, no stdlib code could
express a Windows branch at all. `is_windows()` and a `windows` arm are now in,
keyed off the target's `os` field, which is `windows` for
`aarch64-pc-windows-msvc`.

The substantive work is `std/sys/_libc.mojo`, which the whole FFI layer sits on.
Four functions need Windows implementations, and three of them have semantics
that differ in ways that are easy to get quietly wrong:

| POSIX | Windows | Trap |
| --- | --- | --- |
| `dlopen(path, flags)` | `LoadLibraryA` | `dlopen(NULL, ...)` means "the main program" and maps to `GetModuleHandleA(NULL)`, not `LoadLibraryA(NULL)` |
| `dlsym(handle, name)` | `GetProcAddress` | straightforward |
| `dlclose(handle)` | `FreeLibrary` | **return values are inverted**: `dlclose` returns 0 on success, `FreeLibrary` returns non-zero on success |
| `dlerror()` | `GetLastError` + `FormatMessage` | `dlerror` returns a string or NULL *and clears* the error; Windows returns a numeric code and does not |

The `dlclose` inversion is the one most likely to produce a silently wrong port,
since the failure would look like "unloading always fails" rather than a crash.

### Sequencing note

These stdlib changes are deliberately **not** being written ahead of a working
`mojo.exe`. Mojo is unfamiliar enough that speculative code written with no way
to compile it would mostly be guesswork, and the compiler is the thing that tells
us whether the FFI declarations are right. The predicate work above is the
exception: it is additive, mechanical, and needed regardless.

---

## G4 — The build system is done (2026-04-19)

**Build 18 attempted all 8,847 actions for the first time.** Every remaining
failure is now first-party C++ rather than build configuration, which makes this
the boundary between porting the *build* and porting the *code*.

### The last build-system problem: three command-line limits

Windows has three ceilings and this port hit all of them, each with a different
signature:

| Limit | Applies to | Symptom |
| --- | --- | --- |
| 8,191 (cmd.exe) | anything through the .bat wrapper | `The command line is too long` |
| 32,767 (CreateProcess) | direct .exe invocation | bare `Exit -1`, no diagnostic |

The second is the dangerous one: no error text, just a failed launch, which
reads like a crash rather than a length problem.

Compiles needed `compiler_param_file`; links needed **both** the
`linker_param_file` feature *and* `cc_toolchain`'s `supports_param_files`
attribute, which defaults to False. Enabling the feature alone changed the
argument count by exactly zero. The attribute decides whether params are used at
all; the feature only describes how they are formatted. rules_cc's own MSVC
configuration sets both, which was the clue worth following sooner.

### The remaining surface: ~9 files

Roughly 70 targets fail, but they collapse to a small set of substrate files:

| Area | Problem |
| --- | --- |
| `Support/Threading/SpinWaiter.h` | includes `<immintrin.h>` on Windows |
| `Support/lib/Debugger.cpp` | `IsDebuggerPresent`, `Sleep` undeclared |
| `Support/lib/CPUCache.cpp`, `Threading/HWInfo.h` | `sched.h` |
| `AsyncRT/lib/Support/Semaphore.cpp` | `semaphore.h` |
| `Init/lib/DevelopmentSignalHandler.cpp` | `sys/ucontext.h` |
| `Support/lib/FileSystemExtras.cpp` | `ssize_t` |
| `AsyncRT/.../Globals.cpp`, `Support/lib/Context.cpp` | assorted |
| link | `CommandLineToArgvW` needs shell32 |

### A latent bug that is not Windows-specific

`SpinWaiter.h` guarded its x86 intrinsics on `_MSC_VER`:

```cpp
#ifdef _MSC_VER
#include <immintrin.h> // _mm_pause
#endif
```

and dispatched with `#if MODULAR_WINDOWS` *before* checking the architecture, so
Windows implied `_mm_pause()`. `_MSC_VER` says the compiler is MSVC-compatible,
which clang also is when targeting the MSVC ABI; it says nothing about the
target architecture. **MSVC on Windows ARM64 would hit this too.** The macros to
use were already there and correct — `MODULAR_ARM` is true for `_M_ARM64`.

This is the same shape as the dependency guards fixed earlier, where
`defined(__aarch64__) && defined(__clang__)` was taken to mean a Unix-like
target: **a compiler macro used as a proxy for an architecture**. It is the most
common single mistake found in this port.

Windows ARM64 uses `__yield()` rather than the `isb` inline assembly the other
ARM targets use, deliberately: inline assembly stops LLVM computing a function's
length for SEH unwind info, which is a hard error here rather than a warning.
The same constraint already forced upb onto its portable path.

## The heap corruption was never Bazel's fault

The stdlib precompile crashed under Bazel with `0xC0000374` (heap corruption)
and `0xC0000409` (fastfail), while the identical command run by hand appeared
to succeed. Both halves of that sentence turned out to be misleading, and the
path to the real bug is worth recording.

**Step one: distrust the sample size.** The "manual run succeeds" claim rested
on one run. Looping it six times gave six crashes — three `0xC0000374`, three
`0xC0000409`. There was never a Bazel-specific bug; there was a nondeterministic
crash and a lucky first roll. The lesson is old but keeps needing to be
relearned: one clean run of a nondeterministic failure proves nothing.

**Step two: notice *when* it dies.** Every crashing run had already written the
complete 3.2 MB `std.mojoc`. The compiler does all of its work correctly and
dies on the way out the door. Crashes at process teardown with completed output
are the signature of allocator trouble in destructors, not of compiler logic
bugs.

**Step three: look at the imports.** `llvm-readobj --coff-imports mojo.exe`
listed no `ucrtbase.dll`, no `api-ms-win-crt-*`, no `vcruntime140.dll` — and
the same for the Globals DLLs. Clang's default for MSVC targets is the *static*
CRT, so mojo.exe, MSupportGlobals.dll and AsyncRTRuntimeGlobals.dll each
carried a private copy of the C runtime, each with its own heap.

That is fatal to this codebase's architecture. Modular builds the Globals
libraries as shared objects precisely so that one allocator serves the whole
process — TCMalloc state, runtime globals, the works. On Linux and macOS a
single libc guarantees it. On Windows with static CRTs, the design inverts:
every module gets its own allocator, and any `std::string`, `shared_ptr`
control block or vector allocated in one module and freed in another goes back
to the wrong heap. The damage is silent until ntdll's heap validation trips,
which is why the exit code varied and why the crash always landed in teardown,
where each module's globals drain at once.

Why silent, even with crash reporting compiled in? Two reasons stacked:
`rules_mojo` sets `MODULAR_CRASH_REPORTING_ENABLED=false` for every compile
action, and `0xC0000374`/`0xC0000409` are raised via `__fastfail`, which
bypasses SEH and vectored handlers entirely. Only a debugger or WER sees them.

**The fix is one flag**: `-fms-runtime-lib=dll` in the toolchain's Windows
compile args. It defines `_MT` and `_DLL`, so the MSVC headers' autolink
pragmas select `msvcrt.lib`/`ucrt.lib` (the import libraries) instead of
`libcmt.lib`/`libucrt.lib`, and every module in the process shares the one
ucrtbase heap — the same topology the code was written against. Verified on a
scratch object before committing to the rebuild: with the flag the object
embeds `DEFAULTLIB:msvcrt`, without it `libcmt` territory. This is also simply
what Windows software does: /MD is the norm for anything shipping an exe with
DLLs.

The cost: the flag changes every compile command line, so the entire C++ tree
rebuilds and the disk cache starts cold.

## Reconnaissance for the test phase

Read the whole test stack top to bottom while the CRT rebuild ran, because the
first `bazelw test` will fail somewhere and it is cheaper to know the terrain
first. Findings, in decreasing order of certainty:

**The denominator is honest.** 322 test files under `mojo/stdlib/test`; exactly
one carries an OS gate (macOS), and the 36 `@platforms//:incompatible` selects
are ASAN gates, not platform ones. Upstream did not quietly write a
Linux-only test suite — nearly everything is expected to run.

**Three test rule families.** `mojo_test` (45 uses) compiles the test to a
native executable via the cc toolchain and runs it: our existing toolchain work
covers it, DLL placement is the only open question. `mojo_filecheck_test` (14)
pipes that binary through FileCheck/not — LLVM tools we already build — under a
four-line bash script that Git Bash handles. `lit_tests` (15) is the deep one:
it runs mojo *inside* the test, which drags in the whole SDK-configuration
surface.

**`mojo_test_environment.bzl` was built on two ELF assumptions.** It hands the
test-time `mojo build` a comma-joined linker argument list containing shared
library paths plus `-Xlinker,-rpath` pairs. PE breaks both halves: the file the
linker reads (import .lib) is not the file the loader loads (.dll), and rpath
does not exist. Fixed in Starlark: link arguments name the interface library,
runfiles carry both files, no rpath on Windows.

**One config key, two file kinds.** `MODULAR_MOJO_MAX_COMPILERRT_PATH` is
consumed twice in C++: `ExecutionEngine` *loads* the file (wants the .dll) and
`mojo-build` passes it to the *linker* (wants the .lib). On ELF one path serves
both. The key stays pointed at the .dll and the link path will substitute the
`.lib` sibling — a small Windows branch in mojo-build.cpp, queued until the
rebuild finishes because that file is an input of the running build.

**Deferred without evidence:** `lit.bzl` joins tool paths with `":"`, which is
wrong for a Windows PATH but possibly split on ':' by lit itself; and the `uv`
alias has no Windows case but only gates pip lockfile regeneration, nowhere
near the stdlib tests. Both wait for a real failure before being touched.

## Nobody delivers the dynamic CRT: a link told in three acts

Adding `-fms-runtime-lib=dll` to the compile args was necessary but turned out
to be one third of the fix. The full rebuild compiled 6,800 actions cleanly and
then failed to link mojo.exe, twice, each failure teaching one mechanism.

**Act one: the driver has its own opinion.** The first relink died with
undefined `__imp_` symbols for oddly minor functions — `strtoull`, `isxdigit`,
`_fpclass`, `isupper` — beneath a scroll of LNK4217 warnings saying `free`,
`calloc` and `exit` were "locally defined symbols imported", defined in
`libucrt.lib`. Static ucrt, in a build where every object was compiled for the
dynamic CRT. `clang++ -###` on the exact params file showed why: clang 22's
MSVC linker job does not read `-fms-runtime-lib` — that flag only shapes cc1
compile lines — and unconditionally passes `-defaultlib:libcmt` to lld-link.
The static CRT walks in through the front door on every link this driver
constructs. Symbols some static member happened to define resolved with a
warning; the ones nothing referenced statically became undefined imports.

**Act two: the veto exposes a second failure.** `/NODEFAULTLIB:libcmt.lib`
removed the static CRT and the link fell to a single error: `mainCRTStartup`
undefined. Startup for the dynamic CRT lives in msvcrt.lib — which every
object requests via the `DEFAULTLIB:msvcrt.lib` directive embedded by the
compile-side flag, and which mojo.o demonstrably carries (llvm-readobj shows
DEFAULTLIB:msvcprt.lib, msvcrt.lib, oldnames.lib). The directives were not
being honored for objects packed into .lib archives: the earlier failure had
already hinted at this, with std::time_get symbols from msvcprt undefined
while the referencing object named msvcprt in its .drectve. Two delivery
mechanisms, both broken — one in the driver, one in directive processing.

**Act three: say what you mean.** The link args now state the complete
dynamic CRT explicitly: `/NODEFAULTLIB:libcmt.lib` to veto the driver, then
`/DEFAULTLIB:` msvcrt, msvcprt, ucrt, vcruntime. Rerunning the failed link
with exactly those flags produced a 125 MB mojo.exe importing MSVCP140.dll,
VCRUNTIME140.dll and the api-ms-win-crt-* aprons — including
api-ms-win-crt-heap-l1-1-0.dll, which is the entire point: one ucrtbase heap
for the process.

Two smaller observations from the same params file, recorded for later:
Bazel's alwayslink emission (`-whole-archive`/`-no-whole-archive`) is ignored
with a warning by lld-link, so constructor-driven objects like runtool ride on
luck rather than /WHOLEARCHIVE; and clang appends the host's Visual Studio
lib directories before ours, so the sysroot is only hermetic while the host
SDK happens to match. Neither blocks the current gate.

## One line, eight hours: free(workers)

With the dynamic CRT in place the stdlib precompile still died at teardown,
4 for 4, same two exit codes. The per-module-heap theory had been *a* real
defect — the architecture genuinely requires one allocator per process — but
it was not this crash. Time to stop reasoning and start observing.

**Building the observer.** Nothing on this machine could see a fastfail: cdb
is not installed, our LLVM build carries no lldb, crashpad has no Windows
handler yet, and 0xC0000374/0xC0000409 bypass SEH by design — only a debugger
receives them. The Win32 Debug API is always present, so the port now carries
`tools/crashcatch`: three hundred lines that run a target under
DEBUG_ONLY_THIS_PROCESS, pass first-chance exceptions through untouched, and
on a fatal code print a stack walk and write a full-memory minidump. Two
ARM64 details cost the most time. StackWalk64 without symbols loses the chain
after one ntdll frame, so crashcatch walks AAPCS64 frame records by hand,
possible because this tree builds with -fno-omit-frame-pointer. And the
return addresses in those records carry pointer-authentication bits down
through bit 47 — Windows user VAs stop below 2^47 — which must be masked or
every second frame is garbage: 0xe4417ff7904b9888 is mojo.exe+0x3cc2c20
wearing a hat.

**Reading the answer.** lld-link relinked with /DEBUG:FULL produced a PDB,
llvm-symbolizer turned RVAs into names, and the stack said everything:
precompile → ~MLIRContext → M::Context refcount zero → CPUDevice::~CPUDevice
→ WorkItem teardown → plain free() inside ucrtbase — `_free_base+0x28`, the
crash RVA bracketed by ucrtbase's own export table — raising the failfast.

**The bug.** ThreadPoolWorkQueue allocates its worker array with
`M::alignedAlloc(alignof(WorkQueueThread), ...)` and its destructor released
it with `free(workers)`. AlignedAlloc.h states the contract — "The returned
pointer *must* be deallocated with alignedFree()" — and on POSIX breaking it
costs nothing, because free() accepts aligned_alloc memory. On Windows
alignedAlloc is _aligned_malloc, which returns an adjusted pointer that
free() hands to HeapFree as garbage. Correct on Linux by coincidence, fatal
on Windows by contract. A tree-wide audit of every alignedAlloc caller
(AsyncValue, MallocAllocator, BytecodeInterpreter, STLExtras) found the
pairing honored everywhere but this one line.

The fix is `M::alignedFree(workers)`. The nondeterminism now reads plainly:
whether HeapFree noticed the bad block immediately (0xC0000409), on a later
validation pass (0xC0000374), or never (the single "successful" run that
started this chapter) depended on what the adjusted pointer happened to point
at. The output was always complete because the corruption lived entirely in
process teardown, after the .mojoc was written and closed.

## 477 targets, zero tests: unblocking the analysis layer

The first `bazelw test //mojo/stdlib/test/...` executed nothing. 470 of 477
targets failed *analysis* — the phase before anything compiles or runs — from
four independent causes, worth recording because each is a category:

1. **The client environment is not the repository environment.** rules_shell
   locates bash via BAZEL_SH, our wrapper sets BAZEL_SH, and yet: repository
   rules read a separate environment that client variables never reach. The
   shell toolchain repo cached "no shell", and @bazel_tools'
   collect_coverage — an implicit input of every test target — failed
   analysis, taking the entire graph down. `--repo_env=BAZEL_SH=...` in the
   generated bazelrc fixes it, quoted, because the space in "Program Files"
   otherwise splits the flag and the remainder parses as a target pattern.

2. **Selects are closed sets.** The lit configuration's TARGET_TRIPLE select
   enumerated linux-x86_64, linux-aarch64 and macos; a fourth platform is an
   analysis error, not a fallthrough. One arm added.

3. **A dependency that cannot exist should skip, not fail.** The prebuilt
   max-core wheel has no windows-arm64 build, so the wheel repository's
   aliases now resolve to a @platforms//:incompatible target on Windows.
   Bazel propagates the incompatibility, and anything reaching for the wheel
   is SKIPPED with a reason instead of erroring — honest bookkeeping until
   DragonMax produces a native wheel.

4. **"libpython" is a spelling, not a concept.** rules_mojo scans the hermetic
   Python runtime for a file named libpython* so compiled tests can embed an
   interpreter. Windows CPython calls it python312.dll. A patch on the
   rules_mojo override accepts python3*.dll, excluding the python3.dll
   stable-ABI stub. Python-interop tests stay gated off separately until a
   hermetic CPython registers for the legacy toolchain type.

After the four: 477 targets analyzed, zero errors, 366 test targets running.
The compiler is now compiling and executing its own test suite on Windows
ARM64, which — whatever the pass rate turns out to be — is a sentence that
could not have been written this morning.

## Peeling the test stack: six layers to the first green tests

With analysis unblocked, the strategy switched to probing: run two or three
representative tests, read the first error, fix that one layer, run again.
Six layers deep, the first tests passed. In order:

**Layer 1 — the build id.** 238 of 366 targets failed with "No build id note
found": mojo build fingerprints every binary for MEF cache invalidation, the
Windows fingerprint is the CodeView RSDS record, and links carry no debug
directory by default. `/BUILD-ID` on the link line writes a content-hash
RSDS without a PDB — COFF's spelling of the `--build-id=md5` the Linux args
always had.

**Layer 2 — the silent alwayslink.** Next error: "target
'aarch64-pc-windows-msvc' is not supported by this build", from a registry
populated by static initializers — RegisterTargetLowering globals in
alwayslink libraries. Bazel spells alwayslink as GNU --whole-archive
brackets, and lld-link had been warning-and-ignoring them in every link of
the entire port. No registrar survived archive elision; the registry was
empty. lld-link has no bracketing switches, so a rules_cc patch teaches the
libraries_to_link args the COFF form, /wholearchive:<lib> on the library
argument itself, mirroring the Apple -force_load mechanism that sits right
beside it in the same file.

**Layer 3 — the stdlib's first real Windows gap.** test_int then failed to
link over clock_gettime_nsec_np, a Darwin-only symbol, reached because the
time module's dispatch reads "if Linux ... else macOS". time.mojo now has a
Windows implementation of all five clock ids — QueryPerformanceCounter for
the monotonic pair, GetSystemTimePreciseAsFileTime rebased from 1601 for
realtime, GetProcessTimes/GetThreadTimes for cputime — and sleep() maps to
Sleep. Upstream's own test_time passes against it.

**Layer 4 — the manifest nobody can read.** Tests then died at startup,
STATUS_DLL_NOT_FOUND: compiled tests import KGENCompilerRTShared.dll, which
exists only as a line in a runfiles MANIFEST, and the OS loader does not
read manifests. A rules_mojo patch materializes dependency DLLs beside each
test executable.

**Layers 5 and 6 — lit's POSIX reflexes.** FileCheck discovery needed three
separate corrections: resolve llvm_tools_dir through the runfiles library
rather than a cwd-relative path; restore PATHEXT to the scrubbed test
environment, because lit's which() only tries the .exe suffix when it is
set; and give the lit configs' libpython/PYTHONPATH blocks Windows branches
— INSTSONAME does not exist there and rules_python's bin/lib layout is a
POSIX shape, so both now derive from the interpreter that is already
running the configuration.

After six: test_int passes, test_time passes, and the first lit compile-fail
test passes — the last one meaning a test successfully ran `mojo` itself,
with the whole SDK-configuration environment (import paths, shared library
link arguments, CompilerRT path) working on Windows. The full census is
running.

## Debug mode was the slowness and half the failures

The first full census ran in compilation_mode=dbg — not by choice, but
because upstream's .bazelrc sets `build --compilation_mode=dbg` for every
developer build. That default put a full-debug LLVM inside mojo.exe, which
made each test's compile step crawl, and it put LLVM's assertions in the
JIT's codegen path, which turned out to be causing failures of its own.

The abort-message tests (test_span_bounds_abort and friends) were failing
with the expected "Assert Error:" line absent from stderr. Reproducing by
hand showed why: under `mojo run`, LLVM died on
`UNREACHABLE executed at llvm/lib/CodeGen/TargetSchedule.cpp:227` —
"incomplete machine model" — validating a load-pair instruction against the
neoverse-n1 scheduling model. An assertions-only check: the compiler
aborted before the test program executed a single instruction. In a release
LLVM the check does not exist.

So the census moved to release mode: a `local.bazelrc` (gitignored by
upstream's design, hence recorded here rather than committed) sets
`--compilation_mode=opt` and `--config=build-mojo` for every invocation on
this machine. One full opt rebuild of the C++ tree buys a compiler that
tests at proper speed and a census unpolluted by debug-only assertions.
Interim numbers from the abandoned dbg run, for the record: 47 of 366
executed, 21 passing, 26 failing — most failures of the scheduler-assertion
class, plus a `-Xlinker argument has no effect on mojo run` warning that
pollutes FileCheck's input on JIT-mode tests (a side effect of the test
environment handing link arguments to a run invocation; to be gated to
build-mode tests).

Also observed in passing: with crash reporting enabled, every mojo
invocation now warns "unable to locate crashpad handler executable" — the
client half of crashpad is ported, the handler binary is not. It moves up
the queue.

## Making the build survivable

Three findings turned a multi-hour build into roughly seventy minutes, and
all three were Windows-specific defaults nobody upstream had reason to
question.

**Every test was zipping CPython.** Each lit suite and each mojo test is a
`py_test` underneath, and `py_test` needs its runfiles. On Linux those are a
symlink tree and cost nothing; Windows Bazel assumes symlinks are
unavailable and instead packs the entire runfiles closure into a
self-extracting zip per target — measured here at 122 MB and 2,540 files,
including the hermetic CPython and its OpenSSL .pdb files, taking about two
minutes each across roughly two hundred targets. `--nobuild_python_zip --enable_runfiles`
deleted the whole category and took the action graph from 11,770 to ~3,500
for the same test set.

> **Correction.** This entry originally read "this machine has Developer Mode
> enabled, so symlinks work." Both halves were false, and the error was
> expensive — see *`ln -s` lies* below.

**Defender was scanning every object file.** Real-time protection with no
exclusion covering the Bazel output base — where every .obj, .lib and .pdb
is written. Excluding `C:\projects` alone is not enough and is the natural
mistake: essentially all build I/O happens under `_bazel_alban`. With
exclusions in place the build sustains ~160 actions/min on 8 cores, about
3 s/action for -O3 LLVM sources.

**Debug mode for everyone.** Upstream's .bazelrc sets
`--compilation_mode=dbg`, so a developer's default build is a debug LLVM
inside mojo.exe. That is 5-10x slower to produce, slower to run, and it
enables LLVM's own assertions in the JIT — one of which
(TargetSchedule.cpp:227, "incomplete machine model") was aborting the
compiler during tests and masquerading as a port bug. A `local.bazelrc` now
pins `--compilation_mode=opt`.

Also worth recording: first-party C++ compiles with `-g -O3` under
`modular_config=default`, so all of KGEN/Support/AsyncRT carries full
CodeView debug info even in release. `modular_config=release` uses
`-gline-tables-only`, which still symbolizes a crash stack — the thing we
actually want — at a fraction of the cost. Not switched yet because it
re-keys every first-party action.

### Never build LLVM again

The remaining bulk is LLVM itself: roughly 8,000 of 11,700 actions. A stock
prebuilt cannot substitute, because Modular patches LLVM's own headers —
`MachineFunction.h` changes a member from reference to pointer, an ABI
change that makes any object compiled against unpatched headers
incompatible. But the *output* is small: the built tree is 5 GB, 336 static
libraries and 912 generated .inc headers. Packaging that as a versioned
archive consumed through a repository rule turns those 8,000 compile actions
into an extract, and unlike the disk cache it is immune to toolchain flag
changes re-keying everything. That is the next structural piece of work.

Until then the protections are: the disk cache (re-enabled at
C:/bazel-cache/winmojo, 60 GB cap, now that the configuration has stopped
moving) and the discipline of never running `bazel clean` — the output base
is currently the only copy of work that costs an hour to reproduce.

---

## `ln -s` lies: 214 GB and the flag that was missing

The entry above once claimed this machine had Developer Mode enabled and
that symlinks therefore worked. Neither was true. That single sentence
filled a 475 GB disk twice and cost the better part of a day, so it is worth
recording precisely how a one-line check produced a confident wrong answer.

The check was `ln -s` in Git Bash. It succeeded. MSYS, when the OS refuses a
symlink, silently falls back to **copying** — so the probe cannot fail, and
proves nothing. The machine's actual state was Developer Mode off,
`AllowDevelopmentWithoutDevLicense` unset, and native symlink creation
denied.

### Three ways to give a Windows test its runfiles, all bad

| Strategy | Cost per target | How it fails |
| --- | --- | --- |
| manifest only | nothing | a `py_binary` cannot bootstrap from a manifest — `//KGEN:gen_dialect_checksum` dies at build time |
| `--build_python_zip` | 122 MB, ~2 min | bounded but slow: ~25 GB and hours across the test set |
| `--enable_runfiles`, no symlinks | **3.3 GB**, 6,989 real files | fills the disk |

The tree is expensive because a mojo test's runfiles carry the entire
toolchain — `clang++.exe` at 98 MB, `lld` at 65 MB — once per target, across
roughly two hundred targets. Copied, that is the whole disk. Symlinked, it
is nothing. The strategy is not a tuning preference; it is the difference
between a test suite that runs and one that cannot.

### Developer Mode is necessary and not sufficient

With Developer Mode on and the machine rebooted, `os.symlink()` succeeded
unprivileged — and Bazel *still* wrote 6,989 real files. Bazel does not emit
Windows symlinks on OS capability alone. It needs a **startup** option,
which is easy to miss because every other knob here is a `build` option:

```
startup --windows_enable_symlinks
build --nobuild_python_zip
build --enable_runfiles
```

With both the OS setting and the flag in place, the same tree is 1.9 MB and
6,990 symlinks with zero real files. A factor of about 1,700, and the zip
step disappears with it.

Changing a startup option restarts the Bazel server, which discards the
in-memory analysis cache but not the on-disk action cache: re-analysis is
seconds, and nothing recompiles. Worth knowing before hesitating over it.

### How to test this properly

Two of the three obvious probes lie, in opposite directions:

- **Git Bash `ln -s`** — copies when it cannot link, so it always succeeds.
  A false positive, and the origin of this entire episode.
- **PowerShell 5.1 `New-Item -ItemType SymbolicLink`** — does not pass
  `SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE`, so it reports
  "Administrator privilege required" even once Developer Mode has made the
  operation legal. A false negative.
- **Python `os.symlink()`** — passes the flag, and so matches what Bazel
  actually does. This is the probe to use.

The broader lesson is not about symlinks. Both wrong turns would have been
caught in seconds by measuring the artifact instead of reasoning about the
setting: `find <tree> -type l | wc -l` against `-type f` is the ground
truth, and the size of one materialized tree answers the question outright.
A capability check is only as good as its resemblance to the caller.

### What makes the cheap strategies viable at all

Two earlier changes are load-bearing here and should not be reverted
casually. `lit.common.configured.in` resolves FileCheck through
`python.runfiles` rather than path arithmetic, and the rules_mojo patch
materializes dependency DLLs beside each test binary — the OS loader cannot
read a manifest. Without both, the zip strategy is the only one that works,
and the disk cost comes straight back.

---

## Nine names the standard library could not find

The stdlib reaches libc by name. `external_call["symlink"]` is a C symbol that
must exist at link time, and if it does not the whole binary fails to link
rather than the one call failing. Nine were missing, and finding out which
turned out to matter more than fixing them.

Measured against the sysroot rather than assumed, they fell into three groups.
`oldnames.lib` already aliases the legacy set — `open`, `read`, `write`, `dup`,
`stat`, `chdir` and about ninety more — to their underscore-prefixed CRT
spellings, which is why linking it earlier resolved `write` and `dup` for free.
`popen`, `pclose` and `pipe` exist under different names or shapes. Only six
were genuinely absent.

That measurement is the whole reason this is a small file rather than a
dependency. [libunistd](https://github.com/robinrowe/libunistd) is MIT and
would have done the job; GNU's ports are GPL and could not. But six functions
is less code than the licence notice and the provenance question a third party
would have added, and the licensing article in the README depends on this tree
having no third-party entanglements.

### Where Windows cannot keep the promise

The interesting part is not the mapping, it is the places where there is no
mapping and the shim has to choose. Written up in full in
[docs/win32_posix_shim.md](docs/win32_posix_shim.md); the ones that would bite
hardest:

`symlink` and `link` take their arguments in the **opposite order** from the
Win32 calls that implement them. Get it wrong and you still get a link, just
pointing the wrong way — a test that checks a link exists will pass. The
stdlib's own `test_link.mojo` catches it properly: it reads through the link
and asserts the content, then asserts `st_ino` matches and `st_nlink == 2`.

`fchdir` is not atomic, because Windows has no directory-handle form of
`SetCurrentDirectory` — the handle is resolved to a path and the path entered.
`kill` cannot signal, so every signal but 0 terminates. And a killed process is
deliberately reported as *exited* rather than signalled, because
`Process.wait()` raises on a status that has not exited, which would turn a
successful kill into an exception.

`symlink` also depends on Developer Mode, since it passes
`SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE`. That machine setting is now
load-bearing twice over — once for Bazel's runfiles and once for the standard
library.

### Process spawning, and four gates behind one gate

`os.Process` was refused at compile time — *"Unknown platform process execution
not implemented"* — so nothing that spawned a child could even be built. Behind
that gate were four more, each visible only once the previous one was closed:
`_get_environ`, `FileDescriptor.read_bytes`, then `pipe`, then the launcher.
There is a particular flavour of porting where progress is measured in
discovering the next thing that was never going to work.

`posix_spawnp` maps onto `CreateProcessW` well. `SearchPathW` supplies the "p",
and passing the resolved path as the application name keeps `argv[0]` as the
caller wrote it, which Windows otherwise overwrites with the program path.

Two details are worth remembering because both fail silently. **Command-line
quoting** is the inverse of the MSVCRT parsing rule, in which a backslash
escapes only before a quote — so runs of backslashes double in that position
and nowhere else, and the naive wrap-in-quotes corrupts any argument ending in
a path separator, which on Windows is most of them. **A pid is reused** once
its process is gone, so waiting by reopening the pid races; the handle from
`CreateProcessW` is kept in a table keyed by the pid we report.

`_get_environ` deserves its own note. Windows keeps two environments — the
CRT's `_environ` and the Win32 block `CreateProcessW` actually copies — and
they can disagree. Marshalling one into the other would have been a way to
introduce a bug rather than fix one. Returning null means "inherit", which is
precisely what the only caller wants, so the null is the accurate answer and
not a stub.

`read_bytes` needed the opposite kind of care: the CRT's `_read` returns `int`,
not `ssize_t`, so reading its `-1` as a 64-bit value gives 4294967295 and the
failure check never fires. The caller would take a bogus length for a good
read.

### Verified against programs that exist

The stdlib's `test_process.mojo` spawns `echo`, `sleep` and `printenv`. None of
those is an executable on Windows — `echo` is a `cmd` builtin — so that test
cannot pass here whatever the shim does, and it is a test-content problem
rather than a port one. The shim was verified against real Windows programs
instead: PATH resolution through `where`, an exit code of 7 round-tripping
through the musl status encoding, argument quoting, failure on a missing
executable, and `kill`.

`test_process` now compiles and links, and fails in the Bazel test launcher,
which reports `Rlocation failed on C:Program FilesGitusrbinbash.exe` — the
backslashes stripped from the path. That is the same harness fault that takes
out `test_quick_bench`, it is unrelated to any of this, and it is the next
thing in the way.

Across os, subprocess and bit these changes took failures from twelve to one.

---

## Three machine settings, and one that cannot be worked around

If you are porting this to your own machine, read this section before you build
anything. Three Windows settings decide whether the build and its tests work at
all, none of them is discoverable from an error message, and one of them has to
be right *before* the first build because it cannot be changed afterwards
without throwing the build away.

### 1. Developer Mode — required, and not sufficient on its own

```
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Name AllowDevelopmentWithoutDevLicense -Value 1 -PropertyType DWord -Force
```

Grants unprivileged symlink creation. Two things need it: Bazel's runfiles
trees, which are otherwise written as real file copies at roughly a gigabyte
per test target, and the standard library's `symlink()`, which passes
`SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE`.

It takes effect at logon, so sign out and back in — and Bazel's server must be
restarted too, since it keeps the privileges it started with.

**Developer Mode alone does not make Bazel emit symlinks.** It also needs a
*startup* option, which is easy to miss because every other knob here is a
`build` option:

```
startup --windows_enable_symlinks
```

Do not test for symlink support with `ln -s` under Git Bash. MSYS silently
copies when it cannot link, so the probe always succeeds and proves nothing.
That false positive filled a 475 GB disk twice here. Use Python's
`os.symlink()`, which passes the same flag Bazel does, and then check the result
by measuring a materialized tree: `find <tree> -type l | wc -l` against
`-type f`.

### 2. Long paths — worth setting, but it does less than it appears

```
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1 -PropertyType DWord -Force
```

No reboot needed; new processes pick it up, though the Bazel server must be
restarted.

This lifts the 260-character limit for *file opens*, and it does work — Python
went from reporting a 260-character path as non-existent to opening it happily.

**It does not lift the limit for the DLL loader.** `LoadLibrary` enforces
MAX_PATH whatever the registry says, so anything that imports a native
extension from a deep runfiles path still fails with

```
ImportError: DLL load failed while importing _multiprocessing:
The filename or extension is too long.
```

Setting it is still correct — it removes one whole class of failure — but it
moves the wall rather than removing it. Expect the count to go *down* slightly
when you enable it: tests that used to fail early now run far enough to fail on
something real, which is a truer number rather than a worse state.

### 3. A short output base — and this one cannot be retrofitted

The remaining MAX_PATH failures are all runfiles paths, and the only fix is
fewer characters. The default output base here is
`C:\users\alban\_bazel_alban\rme75s5o`, 36 characters before the build even
starts; `C:\b` would give 32 of them back and clear every remaining case.

The obvious dodge does not work. A junction is not a shortcut:

```
mklink /J C:\b C:\users\<user>\_bazel_<user>\<hash>
```

creates a perfectly good alias, and Bazel will happily build through it —
9,552 action cache hits, nothing rebuilt — but every path it *hands out* is
still the long one, because Bazel canonicalises the output base at startup and
resolves the junction away. The test logs show the real path, and the DLL
loader fails exactly as before.

So the output base has to be genuinely short, which means choosing it before
the first build:

```
startup --output_base=C:/b
```

Changing it later means a fresh output base and repopulating from the disk
cache. That is much cheaper than it sounds when the cache is warm — 60 GB and
14,637 entries here — but it is not free, and it is entirely avoidable by
setting it on day one.

### The short version

| Setting | When | If you skip it |
| --- | --- | --- |
| Developer Mode + `--windows_enable_symlinks` | before first build | runfiles trees are copied, ~1 GB per test target |
| `LongPathsEnabled` | any time | a class of tests fails on file opens |
| short `--output_base` | **before first build** | deep-path tests fail in the DLL loader, unfixably |

---

## Origins, or: three bugs that were one lie

A COM write reported success while its out-parameter kept its sentinel. A
window class failed to register with ERROR_INVALID_PARAMETER -- until debug
prints were added, when it worked. A Direct3D descriptor failed the same way.
Three symptoms, days apart in feel, one cause, and the cause was me telling
the lifetime checker something false.

Every failing site had the shape

    Pointer(to=local).unsafe_origin_cast[MutUntrackedOrigin]()

and the origin module's own docs state precisely what that cast asserts: an
untracked origin "promises the reference aliases no value the compiler is
managing." The promise was false -- the pointer aliased `local` -- so the
compiler was entitled to hand the callee a temporary and never read it back.
Sometimes it did, sometimes it did not, which is the worst possible failure
mode: the COM out-param missed, an 80-byte RegisterClassExW struct missed
until prints happened to force it into memory, and a 64-byte
GlobalMemoryStatusEx in the minimal test landed. Undefined means undefined.

The minimal test (examples/win32/structptr.mojo) puts the three idioms side
by side against GlobalMemoryStatusEx, whose dwLength field is the same
must-set-cbSize pattern as WNDCLASSEXW. The rules it establishes:

1. **Variadic calls take the true origin, uncast.** `Pointer(to=local)`
   straight into external_call or a _DLCallable -- the origin is inferred,
   the aliasing is visible, the callee's writes land. This is what the
   standard library itself does at every libc boundary, which is why it
   never hits the bug.
2. **Declared signatures spell Mojo-owned pointers over AnyOrigin.** There is
   no implicit origin conversion, so the call site casts -- but to
   `MutAnyOrigin`/`ImmutAnyOrigin`, which keep the aliasing ("might access
   any memory value"), never to Untracked, which denies it.
3. **Untracked is only for memory Windows hands us.** Interface pointers,
   symbols, allocations from outside -- its documented purpose, and the one
   place it was being used correctly all along.

The wrong turn is worth dissecting. The first COM out-parameter failure was
"fixed" by moving the value into a one-element List -- heap storage, address
of its own -- which worked, and so became advice in _com.mojo. It treated
the symptom: heap memory cannot be register-promoted, so the lie about
aliasing happened to be survivable there. The advice is now replaced with
the actual rule. Reading the documentation first would have been faster
than three rounds of sentinel forensics; the stdlib's own call sites had
the correct idiom the whole time.

One more trap from the same stretch, different family:
`TrivialRegisterPassable` on an 80-byte struct does not fail to compile. It
silently lays fields out somewhere other than where a pointer-taking callee
expects them -- cbSize read back as garbage, lpfnWndProc as 18. Big structs
passed to Windows by pointer are `Copyable, Movable`, nothing more.

### The window, and the true test

With the rules applied, the full chain runs, and cleanly -- no casts on the
variadic path at all:

    window    -> 1443480 (class atom 49766)
    D3D11CreateDeviceAndSwapChain hr = 0  feature level = 45056
    presented 180 frames

RegisterClassExW, CreateWindowExW, a D3D11 device on the Adreno at feature
level 11.0, the back buffer fetched through IDXGISwapChain::GetBuffer at a
vtable slot the compiler queried from the metadata, a render target view,
and 180 vsynced frames of a teal-to-green fade. Confirmed by the only
instrument that can tell "drew correctly" from "never drew": a person
watching the screen go green.

The same session settled what the abstraction costs. `--emit asm` on
IUnknown::Release through the metadata-derived dispatcher:

    ldr  x8, [x19]        ; vtable from *this
    mov  x0, x19          ; this
    ldr  x8, [x8, #16]    ; slot 2 * 8, an immediate
    blr  x8

Byte-for-byte what C++ emits for p->Release(). The SQLite query is gone --
it became the #16. Zero cost, in the literal sense.

Working examples preserved under examples/win32/: the idiom test, the
metadata queries, and the Direct3D window.

---

## ComPtr: refcounting as ownership, and the count agrees

Feedback worth acting on immediately: COM's refcounting protocol IS Mojo's
ownership model, member for member. Copying is AddRef, destruction is
Release, and a move -- `deinit move`, which consumes the source without
running its destructor -- is *nothing at all*. That last one is the part C++
cannot express as cheaply: CComPtr pays an AddRef on every copy it cannot
prove away, while Mojo's transfers are elided by construction.

Two rules the metadata makes mechanical rather than reviewable. An adopted
out-parameter is NOT AddRef'd, because COM out-params arrive with the
callee's reference already counted -- getting that wrong in one direction
leaks and in the other crashes, and it is now the constructor's contract
rather than a review comment. And `query_interface[Target]` infers the IID
from the type parameter via `winkb_interface_iid`, so a GUID never appears
in user code and an IID/type mismatch is not expressible.

The whole model is asserted, not argued: AddRef returns the new count, so
examples/win32/comptr.mojo walks a live IStream through
adopt(1) copy(2) move(2) QI(3) drops(1), and an unrelated QueryInterface
raises instead of corrupting. The move line reading 2 is the entire pitch.

Same commit, same origin: the compiler now pins the metadata it built
against. `winkb_db_hash()` folds the SHA-256 of the database into the binary
at elaboration -- 8cc64439... for the current file -- so a build record can
say exactly which metadata revision produced a given binary. A compiler
whose semantics depend on a database needs to be able to answer that.

Still on the table from the same feedback: lowering the three Win32 error
conventions (HRESULT, BOOL+GetLastError, sentinel HANDLEs -- the metadata
knows which is which) into `raises`, and emitting vtables instead of
dispatching over them for server-side COM. The dispatcher's table read is
direction-agnostic.

### The callback direction, soaked

The last unproven mechanism was Windows calling into Mojo. The Julia demo now
registers a window procedure written in Mojo -- `@export def mojo_wndproc(...)
abi("C")`, coerced to a thin function value and bitcast to the LPARAM-shaped
pointer with the stdlib's own `_fn_ptr_as_opaque`, the same machinery CPython's
tp_dealloc callbacks ride. Inside the callback, Win32Module hits the process
cache, which is what makes calling it from message context reasonable.

The procedure also keeps GDI off the window -- refusing WM_ERASEBKGND and
answering WM_PAINT with ValidateRect alone, which no default-proc window can
do.

> **Correction.** This entry originally claimed that was the flicker fix. It
> was not: the user reported the flicker unchanged. The actual cause was
> flip-model `Present` unbinding the render target -- bound once before the
> loop, every alternate Draw went into an unbound pipeline, and the display
> ping-ponged between the image and undefined buffer contents. Reissuing
> OMSetRenderTargets every frame fixed it, confirmed by screenshot: the set
> sharp and still against a magenta field, "smooth as silk." Two lessons kept:
> in flip model, per-frame state is per-frame -- and a plausible documented
> artifact is not the same as the artifact on the screen.

Verified by the only camera that counts: the demo ran on screen for 1,286
seconds -- 77,166 frames, 60.002 fps against a refresh-rate-derived present
interval, the rate read from DEVMODEW by winkb field offset without declaring
the 272-byte struct -- through twenty-one minutes of live message traffic,
and exited cleanly through WM_CLOSE -> WM_DESTROY -> PostQuitMessage.

## A Windows library, because upstream has no reason to have one

Upstream Mojo does not support Windows, so it does not ship a Windows
library either: `os` and `pathlib` are written against POSIX, and the parts
that cannot be emulated are simply absent. The CompilerRT shim covers the
POSIX names a Mojo program calls. This is the other half — the things a
Windows program actually wants, in `std/windows/`.

It is layered, and the bottom layer is the reason it works at all.

**Wide strings, three times hand-rolled.** Every W entry point takes UTF-16
and every Mojo string is UTF-8, so each of `d3dwindow`, `d3djulia` and
`comptr` had grown its own `wide()`. `WideString` is that conversion done
once, through `MultiByteToWideChar` rather than open-coded per code point,
which is what makes surrogate pairs come out right: `🐉 dragon` measures 9
UTF-16 units, not 8. `MB_ERR_INVALID_CHARS` is set, so malformed input
raises instead of quietly becoming replacement characters.

**Errors, decoded.** Windows reports failure three incompatible ways —
LSTATUS straight from the call, BOOL plus `GetLastError`, and HRESULT — and
this is the whole surface for all three: `raise_last_error("CreateFileW")`,
`raise_if_failed(hr, "...")`, and a `_check` inside the registry module.
All of them run the code through `FormatMessageW`, so a failure reads *"The
system cannot find the file specified. (2)"* and not *"error 2"*. Windows
has the words; there is no reason to make the reader look them up.

**Handles that close.** `Handle` and `RegKey` are move-only for the same
reason `ComPtr` is: duplicating a handle is `DuplicateHandle`, not a copy,
so a copyable wrapper would double-close. `RegKey.__deinit__` skips
predefined roots, which are negative, and `list_directory` closes its search
with `FindClose` rather than `CloseHandle` — a find handle is its own kind,
and the mismatch is the sort that only shows up under handle-leak testing.

On top: the registry (open/create, typed reads and writes, subkey and value
enumeration), shell known folders, filesystem paths and listings, system
information, and the two console calls that decide whether a Windows program
looks broken.

### What the machine said

`examples/win32/windows_tour.mojo` is the acceptance test, and it prints
what the machine actually answered rather than asserting:

```
windows       10.0.26200
cpu name      Snapdragon(R) X - X126100 - Qualcomm(R) Oryon(TM) CPU
physical      14 GiB free of 31 GiB
desktop       C:\Users\alban\OneDrive\Desktop
product       Windows 10 Home
```

Two of those lines are the argument for the module existing.

`desktop` resolves through OneDrive. Any program that had built that path
from `%USERPROFILE%\Desktop` — the obvious thing, and what a POSIX-shaped
port would do — would have been wrong on this machine, and on every
OneDrive-backed or domain-joined machine. `SHGetKnownFolderPath` is not a
convenience over the environment variable; it is the only correct answer.

`product` says *Windows 10 Home* on a Windows 11 machine. `ProductName` in
the registry has lied since Windows 11 shipped, which is exactly why
`windows_version()` goes to `RtlGetVersion` in ntdll and reports the build
number: 26200 is 25H2 and 26100 is 24H2, and the marketing name is not
load-bearing. `GetVersionExW` would have lied differently — it reports 6.2
to any process without a compatibility manifest.

Two more of the same shape, coded but less visible: `processor_count()` uses
`GetActiveProcessorCount(ALL_PROCESSOR_GROUPS)` because `GetSystemInfo`'s
count stops at the calling process's own processor group and caps at 64; and
`uptime_ms()` is `GetTickCount64`, because the 32-bit one wraps after 49.7
days and the bug surfaces seven weeks after anyone could reproduce it.

### Offsets from the database, not from a header

Every struct this touches — `MEMORYSTATUSEX`, `WIN32_FIND_DATAW`,
`OSVERSIONINFOW`, `CONSOLE_SCREEN_BUFFER_INFO` — gets its size and field
offsets from winkb at compile time. That is not tidiness. `WIN32_FIND_DATAW`
is 592 bytes with `cFileName` at 44 on 64-bit, and the numbers in most
sample code are the 32-bit ones. A wrong offset here does not fail; it reads
a filename out of the middle of a timestamp.

The predefined registry roots are the same trap in constant form.
`HKEY_LOCAL_MACHINE` is `(HKEY)(ULONG_PTR)((LONG)0x80000002)` — a *signed*
32-bit value widened to a pointer, so on 64-bit it is `0xFFFFFFFF80000002`.
Writing the unsigned constant gives an invalid handle. winkb stores them
signed, and the module was written from what winkb said.

**A gap found in winkb.** The `constants` table has 5,837 rows of
`value_kind = 'guid'` — every `FOLDERID_*`, every `CLSID_*` — and stores
their *names* without their bytes: `value_text` is NULL for all of them. So
`KnownFolder`'s ids are transcribed from `shlobj.h` after all, in the same
textual form the COM code uses for IIDs so that one parser serves both, and
each one is exercised by the tour. Worth fixing at the knowledge-base end;
the interface IIDs, which come from `types.iid`, are complete.

### Getting an example to build at all

Four environment facts have to be right at once and each fails differently;
`examples/win32/build.sh` now sets all four, with the failure mode named in
a comment beside each. The table is in DIALECT-NOTES. Two are worth
repeating here:

**Git Bash's coreutils ships `/usr/bin/link.exe`**, which wins
`findProgramByName("link.exe")` and then rejects MSVC's flags with
*"link: unknown option -- X"*. The MSVC ARM64 linker has to precede it on
PATH.

**A silent `0xC0000135` before `main`.** The built .exe imports
`KGENCompilerRTShared.dll`, which in turn imports `AsyncRTRuntimeGlobals.dll`
and `MSupportGlobals.dll`. PE has no rpath. Miss any of them and the process
dies with STATUS_DLL_NOT_FOUND and no message at all — from Git Bash it
surfaces as the actively misleading *"error while loading shared libraries:
?: cannot open shared object file"*. The build script copies the set beside
the binary.

Also confirmed while getting there: **`--target-cpu generic` is required for
AOT builds on this machine.** The default `neoverse-n1` scheduling model is
incomplete for some load/store-pair instructions the backend emits, and an
assertions-enabled LLVM aborts at `TargetSchedule.cpp:227` with *"incomplete
machine model"*. The debug-mode version of this was diagnosed months ago and
attributed to `mojo run`; it is not JIT-specific, it is the N1 model. And
Snapdragon X is Oryon, so the N1 proxy was never right to begin with.

### A camera for console programs

`tools/shot.ps1` runs a program in a real console and photographs the
window, because redirected output is not console output: with stdout on a
pipe there is no console, so `GetConsoleMode` fails, ANSI colour never turns
on, and `GetConsoleScreenBufferInfo` has nothing to measure. Under
redirection the tour reports *"(no console; VT not enabled)"* — correct, and
also no evidence.

In a real one it reports `92 x 10 cells` for a window opened with
`mode con: cols=92 lines=10`, and prints *green yellow red* in green, yellow
and red. Three Windows-specific details had to be got right first: launch
`conhost.exe` explicitly (left alone, `cmd.exe` opens inside Windows
Terminal and the launched process's `MainWindowHandle` is zero); declare
`FindWindowW` with `CharSet.Unicode` (the default ANSI marshalling hands a W
entry point an ANSI string and finds nothing); and keep the RECT marshalling
inside the C# helper (through PowerShell's `[ref]` it silently yields zeroes,
and a 0x0 bitmap is the symptom).

## One wrong number in thirty-five, and the compiler could have said so

Writing the Windows library meant transcribing about thirty-five named
constants — access masks, flag bits, error codes. Thirty-four were right.

`STARTF_USESTDHANDLES` was written as 1. It is 0x100. One is
`STARTF_USESHOWWINDOW`.

The failure is instructive because of how it presented. `run_captured`
returned exit code 0 and an empty string, and the child's output appeared —
on the *parent's* console, above the line reporting that the child had said
nothing. Nothing errored. `CreateProcessW` succeeded, the pipe was created,
the read hit end-of-file immediately because nothing was ever written to it.
Every individual call did what it was told. The only evidence was output in
the wrong place.

winkb had the right value the whole time, in `enum_members`:

```
STARTF_USESHOWWINDOW    1
STARTF_USESTDHANDLES    256
```

So the metadata queries now cover constants. `constant_value` is one more row
in the `kQueries` table in `IREvaluatorContext.cpp` — no new opcode, because
`winkb_query` was already generic — reading `constants` and `enum_members` in
one UNION, and `winkb_constant["NAME"]()` on the Mojo side folds it to a
literal. `constant_text` does the same for the string-valued ones.

Two details in that SQL are load-bearing.

`COALESCE(value_i64, value_u64)` prefers the **signed** reading. It is the
one that survives narrowing in both directions: `HKEY_LOCAL_MACHINE` must
sign-extend to `0xFFFFFFFF80000002` when it is used as a pointer, while a
flag mask like `0x80000000` keeps its bits through the caller's `UInt32()`
either way. Preferring the unsigned reading breaks the first case silently —
which is the same class of bug this is meant to end.

`constants` wins over `enum_members` by ordinal where a name appears in both,
because a `#define` is what a program written against the headers means.

The whole windows package now goes through it. Every access mask, every
`FILE_ATTRIBUTE_*`, every error code, `CP_UTF8`, `CF_UNICODETEXT`,
`TokenElevation`, `ALL_PROCESSOR_GROUPS`, the FORMAT_MESSAGE flags, and the
five predefined HKEY roots. The values are unchanged — the tour prints the
same output before and after, which is the point — but a typo is now this,
at compile time, with the source line:

```
note: the Win32 metadata has no 'constant_value' for STARTF_USESTDHANDLE
```

**What this does not cover.** GUIDs. `constants` has 5,837 rows of
`value_kind = 'guid'` and stores none of their bytes, so `KnownFolder`'s ids
are still transcribed from `shlobj.h`. Interface IIDs are fine — those come
from `types.iid`, which is populated. Filling in the GUID constants is the
single highest-value thing left to do to winkb itself; it would close the
last category where this library is copying numbers out of a header.

## "LLVM cannot JIT on Windows ARM64" was false, and the user called it

The README said `mojo run` **cannot work** because "LLVM has no COFF/ARM64
JITLink backend". The user, who JITs ARM64 code on this machine daily,
refused to believe it. They were right to.

The claim confused a layer with the library. LLVM has two JIT linkers:
JITLink (new, `ObjectLinkingLayer`) genuinely has no COFF/aarch64 backend —
`lib/ExecutionEngine/JITLink/` holds `COFF_x86_64.cpp` and nothing else for
COFF. But RuntimeDyld (old, `RTDyldObjectLinkingLayer`) has shipped
`RuntimeDyldCOFFAArch64.h` since 2019. Mojo's `ExecutionEngine` hard-coded
the JITLink layer, so every ARM64 COFF object died at the last step with
*"Unsupported target machine architecture in COFF object : ARM64"* — after
codegen had already produced a perfectly good object.

The fix is a fork in `ExecutionEngine::create`: on COFF+AArch64 the engine
builds an `RTDyldObjectLinkingLayer` over `SectionMemoryManager` instead.
Three details were load-bearing:

- **The COMDAT flags.** COFF objects are full of COMDATs — every float
  constant the compiler materialises is one (the `__xmm@...` symbols in the
  error output). `setOverrideObjectFlagsWithResponsibilityFlags(true)` and
  `setAutoClaimResponsibilityForObjectSymbols(true)`, the same pair LLJIT
  sets for COFF targets, or materialisation dies on responsibility
  mismatches.
- **The CRT names an AOT link gets from import libraries.** First run after
  the swap: `Symbols not found: [ write, memcpy, fflush, fdopen, fclose,
  dup, __chkstk ]` — the JIT-side version of the day-one `oldnames.lib`
  find. A `Win32CRTSymbolGenerator` resolves them live: plain CRT names by
  `GetProcAddress` over every loaded module (ucrtbase.dll is loaded but the
  process-symbol generator does not search it), POSIX spellings by the
  oldnames rule applied at run time (`write` → `_write`), and `__chkstk` —
  which is statically linked and exported by nothing — to this binary's own
  copy, dragged in by an `extern "C"` reference.
- **Which dylib the generator lives on.** First placement was the platform
  stdlib, and nothing changed: materialisation searches the *link order* of
  the exec dylib — exec → `$compilerrt-lib` → `$mlirc-lib` — and the
  platform stdlib is not in it. The generator belongs on the CompilerRT
  dylib, which `addToSearchOrder` wires into every user dylib.

Proof, both sizes. Hello-world prints. Then the stress program: `List`,
`Dict`, unicode strings, recursion, Float64 math, `raises` unwinding across
JIT-compiled frames, and the whole `std.windows` surface — `RtlGetVersion`,
`SHGetKnownFolderPath` through the DLL module cache — all inside `mojo run`.

The REPL is a different story and stays blocked: it is an LLDB front end
("unable to resolve the lldb path"), and lldb is not ported. That was never
a JIT limitation; the README conflated the two, and now does not.

One census note while verifying: the abort-class test failures
(`test_string_span_bounds_abort` etc.) are NOT JIT failures — the harness
dies importing `_multiprocessing.pyd` with "The filename or extension is
too long" before lit starts. That is the parked MAX_PATH problem wearing a
test-failure costume, and it means the census's failure count mixes
path-length casualties with real ones. The rerun, when it happens, needs
the short output base first.

### The favourite, JIT'd

`./examples/win32/run.sh adreno_mandelbrot` now runs the windowed Mandelbrot
straight from source: RuntimeDyld links the ARM64 COFF objects in-process,
the SPIR-V kernel goes to the Adreno, `AsyncRT_*` comes from `dragonrt.dll`
via `-Xlinker` — which is `mojo run`'s spelling for "load this into the JIT
session" — and D3D11 presents. No linker, no .exe, and the window is
indistinguishable from the AOT one.

Measured to settle a perception: 20 seconds of animation each, same source —
**AOT 59 fps, JIT 59 fps**. The frame loop locks to vsync either way; the
apparent speed difference was the zoom cycle's phase (early frames crawl,
deep frames race). The real JIT cost is startup: the first run pays the full
compile before the window appears; a warm re-run reached it in 2 s.

Two pieces landed to make the one-liner work: `//dragon/runtime:dragonrt.dll`
(a `cc_binary` linkshared target — which is also the DLL `test_dragonrt` has
been failing to LoadLibrary under Bazel, error 126), and `run.sh`, which
reuses build.sh's environment and adds `--target-accelerator` plus the DLL
automatically when the source mentions the GPU. Also fixed in passing:
`winstr_smoke.mojo` still imported `std.sys._windows_core`, the module's
address before it became the `std.windows` package.
