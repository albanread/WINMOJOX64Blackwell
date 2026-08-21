# WINMOJO x64 — Mojo 1.1 on Windows and NVIDIA Blackwell

This repository is an unofficial native Windows x64 port of the open-source
Mojo compiler, standard library, MAX Mojo packages, and GPU runtime. Its current
target is an Intel Windows 11 PC with an NVIDIA Blackwell GPU.

The current repository is
[albanread/WINMOJOX64Blackwell](https://github.com/albanread/WINMOJOX64Blackwell).

It builds a native `mojo.exe`, supports both `mojo build` and `mojo run`, and
executes ordinary Mojo GPU kernels through PTX on the installed NVIDIA driver.
It does not use WSL and it does not require the CUDA SDK, `nvcc`, `ptxas`,
`cudart`, cuBLAS, or cuDNN.

> [!IMPORTANT]
> This is an experimental, unsupported fork. It is not a Modular product and
> is not affiliated with or supported by Modular or NVIDIA. Report problems
> with this port here, not to either vendor.

## Current target

The reference machine used to develop and validate this branch is:

| Component | Reference system |
| --- | --- |
| Host architecture | Windows x64 (`x86_64-pc-windows-msvc`) |
| CPU | Intel Core Ultra 9 285H, 16 cores / 16 logical processors |
| Operating system | Windows 11 Enterprise x64, build 26200 |
| GPU | NVIDIA RTX PRO 2000 Blackwell Generation Laptop GPU |
| GPU memory | 8 GB |
| Compute capability | 12.0 |
| Mojo accelerator target | `sm_120a` |
| NVIDIA driver used for validation | 573.14 |
| Mojo version | 1.1.0 development source build |
| Branch | `windows-x64-nvidia-blackwell` |

The checked-in Bazel platform is
`//:windows_x86_64_nvidia_blackwell`. It deliberately selects x86-64 Windows,
the NVIDIA toolchain, and the RTX PRO 2000 Blackwell `sm_120a` target. This is
not the old Snapdragon build with its CPU or GPU labels changed at the command
line; the host toolchain, object format, JIT, debugger, runtime, examples, and
release packaging have all been ported to the new machine.

## Lineage

This work started from [albanread/WINMOJO](https://github.com/albanread/WINMOJO),
which was a native Windows ARM64 port for a Snapdragon X PC. That predecessor
used:

- an ARM64 Windows host compiler;
- Qualcomm Oryon CPU code generation;
- an Adreno GPU backend that emitted SPIR-V; and
- `dragonrt`, an AsyncRT-compatible OpenCL runtime for the Adreno GPU.

This repository is the next port of that work:

- ARM64 host code generation became native Windows x64;
- the reference CPU is Intel rather than Qualcomm Oryon;
- SPIR-V/OpenCL/Adreno became NVPTX/NVIDIA/Blackwell;
- `dragonrt` was replaced for the active target by `nvptxrt`; and
- the Git repository was reinitialized around this Windows x64 port.

Some ARM64, Adreno, and `dragonrt` sources remain in the tree as historical
work and useful reference implementations. They are not the active runtime or
the supported configuration of this branch. Old ARM benchmark counts and
Adreno coverage numbers do not describe this port.

## What has been achieved

The working GPU path is:

```text
Mojo source
    │
    ▼
KGEN + MLIR + LLVM NVPTX backend
    │
    ▼
PTX for sm_120a
    │
    ▼
nvptxrt.dll (open-source AsyncRT device ABI implementation)
    │
    ▼
nvcuda.dll (installed NVIDIA display driver and PTX JIT)
    │
    ▼
RTX PRO 2000 Blackwell GPU
```

`nvptxrt` dynamically loads the CUDA Driver API from `nvcuda.dll`. The build
and the standalone release therefore need the NVIDIA display driver to execute
GPU code, but they do not bundle or require NVIDIA's proprietary CUDA
development stack. Final PTX-to-machine-code compilation is performed by the
driver, as it must be for this hardware.

The windowed Mandelbrot example is the end-to-end demonstration. Its pixels are
computed by a Mojo kernel on the Blackwell GPU, copied back through `nvptxrt`,
and displayed in a native Win32 window. Both AOT compilation and `mojo run` JIT
execution have been verified.

## Feature coverage

The tables below describe this branch at revision `34db48b` and the hardware
tests run on 21 August 2026. “Implemented” means the required ABI and code path
exist. “Tested” additionally means the path ran successfully on the reference
machine.

### Windows host and compiler

| Area | State | Evidence or qualification |
| --- | --- | --- |
| Native Windows x64 compiler | **Implemented and tested** | `mojo.exe` is a native PE/COFF x64 executable. |
| AOT compilation | **Implemented and tested** | `mojo build` produces native Windows x64 executables. |
| JIT execution | **Implemented and tested** | `mojo run` uses the Windows RuntimeDyld path and runs CPU and GPU Mojo source. |
| Automatic NVIDIA selection | **Implemented and tested** | No accelerator flag and `--target-accelerator cuda` both detect this machine as `sm_120a`. |
| Mojo REPL | **Built and packaged** | LLDB, the Mojo LLDB plugin, and the REPL entry point are included in the release. |
| Crash reporting | **Built and packaged** | The Windows Crashpad handler and crash database layout are included. |
| Standard library | **Built** | Packaged as `std.mojoc`. The obsolete ARM64 test census has been removed from this README. |
| MAX Mojo package | **Built** | Packaged as `max.mojoc`; this does not imply that every MAX kernel or Python service has been validated. |
| Win32 API metadata | **Implemented** | The compiler consumes `windows_api.db` for compile-time Win32 layout, constant, and COM queries. |
| Standalone release | **Implemented and tested** | Runs from `C:\projects\mojo_release` without Bazel. |

### NVIDIA runtime and GPU execution

| Area | State | Evidence or qualification |
| --- | --- | --- |
| Driver loading | **Implemented and tested** | Loads `nvcuda.dll` dynamically; no link-time CUDA SDK dependency. |
| Device discovery and metadata | **Implemented and tested** | Correctly reports one Blackwell GPU, compute capability 120, name, memory, and attributes. |
| Contexts and synchronization | **Implemented and tested** | Primary CUDA contexts, current-context scopes, stream and context synchronization. |
| Device and pinned host buffers | **Implemented and tested** | Allocation, release, sub-buffers, mapped host buffers, and ownership transfer. |
| H→D, D→H, and D→D copies | **Implemented and tested** | Small, 1 Mi-element, sub-buffer, and non-owning alias paths pass. |
| Memory fill | **Implemented and tested** | 8-, 16-, 32-, and 64-bit paths, including graph memset nodes. |
| Streams, events, and timers | **Implemented** | Core stream/event AsyncRT ABI is present; the windowed example and focused runtime tests use it. |
| PTX module and kernel launch | **Implemented and tested** | Module loading, function lookup, normal launch, launch attributes, and constant memory. |
| Occupancy and function attributes | **Implemented** | CUDA Driver API queries are exposed through the MAX Mojo host API. |
| Blackwell TMA | **Implemented and tested** | Correct grid-constant ABI, 64-bit generic pointers, descriptor lifetime, and a verified 8×8 tile copy. |
| CUDA graphs | **Implemented and tested** | Kernel, copy, memset, empty, host, and wait nodes; dependencies, regions, inputs, outputs, caching, instantiate, and replay. |
| Completion flags | **Implemented and tested** | Mapped pinned flags, host signal/reset/load, stream wait, and graph wait. |
| GPU host callbacks | **Implemented and tested** | Direct stream callbacks and recorded CUDA graph host nodes pass. |
| Peer capability and enablement | **Implemented** | Per-pair and all-device APIs are present and self-access correctly reports false. |
| Cross-device copy | **Implemented, not hardware-tested** | Uses `cuMemcpyPeerAsync`; falls back to a host-staged copy when the driver rejects direct peer access. This PC has only one GPU. |
| Multicast/NVSwitch memory | **Not implemented** | Capability reports false and calls fail with a clear error instead of an unresolved symbol. |
| CUDA vendor libraries | **Not included** | No cuBLAS, cuDNN, NCCL, or CUDA runtime dependency is bundled. Operations that require them need additional work. |

### MAX feature coverage

This port now supports a substantial part of the MAX Mojo GPU host layer, but
it does **not** claim universal MAX coverage.

| MAX area | Coverage |
| --- | --- |
| Mojo-authored GPU kernels using standard NVPTX operations | Working for the tested kernels and examples. |
| Device contexts, buffers, streams, events, launches, graphs, and host synchronization | Implemented in `nvptxrt`. |
| SM120a TMA | Working on the reference Blackwell GPU. |
| Broad kernel catalogue | Partial; a complete Windows/SM120a test census has not yet been run. |
| SM120 tensor-core/TCGen05-specific paths | Not yet systematically validated. |
| Multi-GPU collectives and peer algorithms | Runtime foundations implemented; real multi-GPU hardware testing still required. |
| Multicast collectives | Unsupported. |
| Vendor-library-backed operations | Unsupported unless they have a pure Mojo fallback. |
| Python MAX graph, engine, pipelines, and serving stack | Outside the current standalone release and not validated by this port. |

The most valuable next coverage work is a systematic SM120a kernel census,
starting with matmul/tensor-core kernels, reductions, attention primitives,
layouts, and communication kernels. After that come real two-GPU peer tests,
mixed CPU/GPU AsyncRT dispatch, and multi-architecture packaging.

## Test progress

The following focused tests have run successfully on the reference system:

| Test | Result |
| --- | --- |
| Native compiler plus runtime build | Passed; the final focused rebuild executed 7 actions with the existing Bazel cache. |
| AsyncRT smoke test | 1/1 passed; device count is 1 and self peer access is false. |
| Completion flag suite | 2/2 passed with both automatic detection and explicit `--target-accelerator cuda`. |
| CUDA graph builder suite | 25 graph scenarios passed. |
| Blackwell TMA tile-copy test | Passed; all 64 output values were checked on the host. |
| Direct GPU host callback test | 1/1 passed. |
| Multicast capability test | Passed by correctly reporting that multicast is unsupported. |
| GPU copy coverage | Normal, large, sub-buffer, and non-owning alias cases passed. |
| Windowed NVIDIA Mandelbrot | Passed as an AOT executable and through `mojo run`; every frame is recomputed on the GPU. |

One upstream copy test also creates a CPU `DeviceContext` after finishing its
GPU checks. Its GPU sections pass, but the final mixed CPU/GPU section currently
stops because `nvptxrt` owns an unnamespaced `AsyncRT_DeviceContext_*` ABI and
does not dispatch CPU context objects to the CPU provider. This is a known
integration gap, not a failed GPU copy.

Bazel's default Windows test execution toolchain is not registered for these
GPU tests in this tree, so the hardware tests above were run directly with the
newly built `mojo.exe`. Focused Bazel build targets are used to compile the
compiler and runtime without invalidating thousands of cached components.

## PTX portability

PTX is portable within the architecture and feature contract encoded in the
module; `sm_120a` is not a universal NVIDIA target. The current default is
intentionally optimized for this machine and uses architecture-specific
Blackwell features.

The compiler and runtime now recognize Windows NVIDIA architectures and append
the architecture-specific `a` suffix for the known targets that require it.
Other NVIDIA cards can be supported by selecting their correct `sm_XX` or
`sm_XXa` toolchain and rebuilding. A future general release should contain
multiple PTX targets or select one at installation/run time rather than ship
only this machine's `sm_120a` configuration.

## Building from source

### Prerequisites

- Windows 11 x64;
- Visual Studio 2022 Build Tools with the MSVC x64 toolchain and Windows SDK;
- Git with long paths enabled;
- Windows Developer Mode for efficient symlink-based Bazel runfiles;
- a current NVIDIA display driver for GPU execution; and
- enough disk space for a large LLVM/MLIR source build.

The CUDA toolkit is optional for diagnostics and is not a build dependency of
`nvptxrt`.

### Machine-local Bazel configuration

Create `local.bazelrc` at the repository root. This is the validated
configuration for the reference machine:

```bazelrc
startup --output_base=C:/b/w
build --config=build-mojo
build --config=windows-nvidia-blackwell
build --compilation_mode=opt
build --//:modular_config=production
build --jobs=12
build --experimental_disk_cache_gc_max_size=10G
build --experimental_disk_cache_gc_idle_delay=5s
```

`--config=windows-nvidia-blackwell` is the important target selection. Adjust
the job count and cache limit to the machine, but do not replace the platform
with an unrelated host or GPU configuration.

The short output base keeps Windows path lengths under control. The disk-cache
limit prevents Bazel from consuming the system drive indefinitely. Avoid
`bazel clean --expunge` during normal work: it throws away valid LLVM, compiler,
and runtime artifacts and forces an enormous rebuild.

### Focused builds

Use the repository wrapper, not a separately installed Bazel:

```powershell
.\bazelw.cmd build //KGEN/tools/mojo:mojo //nvptx/runtime:nvptxrt.dll
.\bazelw.cmd build //mojo/stdlib/std:std //max/mojo/max:max
.\bazelw.cmd build //examples/win32:nvidia_mandelbrot
```

Build debugger components only when needed:

```powershell
.\bazelw.cmd build //KGEN:MojoLLDB `
  //KGEN/tools/mojo-repl-entry-point:mojo-repl-entry-point
```

With an intact output base, editing `nvptxrt.cpp` normally rebuilds and links
only a handful of actions. Changing widely included compiler headers can still
cause a larger relink.

## Running from the build tree

Point the JIT at the NVIDIA AsyncRT provider:

```powershell
$env:MODULAR_MOJO_MAX_SHARED_LIBS = `
  (Resolve-Path 'bazel-bin/nvptx/runtime/nvptxrt.dll').Path
$mojo = 'bazel-bin/KGEN/tools/mojo/mojo.exe'
```

Run ordinary Mojo source with automatic GPU detection:

```powershell
& $mojo run -I mojo/stdlib -I max/mojo program.mojo
```

Or request the generic CUDA selector, which resolves to `sm_120a` on the
reference machine:

```powershell
& $mojo run --target-accelerator cuda `
  -I mojo/stdlib -I max/mojo -I max/kernels/src program.mojo
```

Run the prebuilt windowed Mandelbrot example:

```powershell
.\bazel-bin\examples\win32\nvidia_mandelbrot.exe
```

The source is
[examples/win32/nvidia_mandelbrot.mojo](examples/win32/nvidia_mandelbrot.mojo).
It prints a startup CPU/GPU comparison, opens a native Win32 window, and reports
the final frame count when closed.

## Focused hardware test commands

After defining `$mojo` and `MODULAR_MOJO_MAX_SHARED_LIBS` as above:

```powershell
# Runtime smoke and peer semantics
& $mojo run -I mojo/stdlib -I max/mojo -I max/mojo/test/asyncrt `
  max/mojo/test/asyncrt/test_smoke.mojo

# Completion flags and host/graph synchronization
& $mojo run --target-accelerator cuda `
  -I mojo/stdlib -I max/mojo -I max/mojo/test/asyncrt `
  max/mojo/test/asyncrt/test_completion_flag.mojo

# Full CUDA graph builder suite
& $mojo run -I mojo/stdlib -I max/mojo -I max/kernels/src `
  max/kernels/test/gpu/device_context/test_device_graph_builder.mojo

# SM120a TMA correctness
& $mojo run -I mojo/stdlib -I max/mojo -I max/kernels/src `
  max/kernels/test/gpu/memory/test_tma.mojo

# Direct stream host callback
& $mojo run -I mojo/stdlib -I max/mojo -I max/mojo/test/asyncrt `
  max/mojo/test/asyncrt/test_host_func.mojo
```

## Standalone release

The release packager gathers the compiler, standard library, MAX Mojo package,
NVPTX runtime, LLDB/REPL support, Crashpad, Windows API metadata, and the
Mandelbrot example:

```powershell
.\release\windows\create-release.ps1 `
  -Destination C:\projects\mojo_release
```

The existing reference release is deliberately independent of Bazel at run
time. Its launchers configure package lookup, runtime DLLs, Windows metadata,
LLDB, Crashpad, the compiler cache, and the Visual Studio x64 library paths.

```text
mojo.cmd --version
mojo.cmd run examples\hello.mojo
mojo.cmd build examples\hello.mojo -o hello.exe
mojo-gpu-run.cmd file.mojo
mojo-gpu-build.cmd file.mojo -o file.exe
mojo.cmd repl
mandelbrot.cmd
```

The repository README describes current source progress. The release directory
is a fixed artifact and is not silently rewritten while runtime development
continues; regenerate it explicitly when a new release is wanted.

## Repository map

| Path | Purpose |
| --- | --- |
| `KGEN/` | Mojo compiler, Windows JIT/AOT support, accelerator detection, LLDB plugin. |
| `mojo/stdlib/` | Mojo standard library and Windows/NVPTX target descriptions. |
| `max/mojo/max/` | MAX Mojo host APIs used by the NVIDIA runtime. |
| `max/kernels/` | Mojo GPU kernels and the focused graph/TMA tests. |
| `nvptx/runtime/` | Windows NVIDIA AsyncRT implementation over the CUDA Driver API. |
| `examples/win32/` | Native Windows examples, including NVIDIA Mandelbrot. |
| `release/windows/` | Standalone Windows x64 release templates and packager. |
| `dragon/runtime/` | Historical Snapdragon/Adreno runtime; not active for this target. |

## Known limitations and next work

1. Run a systematic MAX kernel census on SM120a and record pass/fail/unsupported
   results rather than inferring support from the host runtime ABI.
2. Validate tensor-core, TCGen05, attention, reduction, and communication paths
   specifically on consumer Blackwell.
3. Test direct peer access, peer copies, and collective algorithms on a real
   multi-GPU Windows system.
4. Add multicast/NVSwitch virtual-memory support where the Windows driver and
   hardware expose it.
5. Resolve mixed CPU/GPU AsyncRT symbol dispatch so CPU contexts and NVIDIA
   contexts can coexist in the same direct-JIT process.
6. Package multiple NVIDIA architecture targets rather than defaulting the
   entire release to `sm_120a`.
7. Expand validation from the Mojo kernel layer into the Python MAX graph,
   engine, pipelines, and serving stack if those components are brought into
   scope.

## Attribution and licensing

Mojo, KGEN, the standard library, MAX sources, LLVM, MLIR, LLDB, and the other
third-party components remain the work of their respective authors. The
original upstream project is [modular/modular](https://github.com/modular/modular),
and this x64 port descends from the earlier
[WINMOJO](https://github.com/albanread/WINMOJO) Windows ARM64 work.

This repository contains files under multiple licenses. Read the root
[LICENSE](LICENSE), [Licenses](Licenses/), third-party notices, and the license
header of each source file before redistributing a build. Nothing in this
README is legal advice.
