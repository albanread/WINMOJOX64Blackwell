# What MAX actually is, open vs closed

Determined by reading the tree at `f66d4d5`, not from documentation. This is
the constraint that defines the project, so it is written down first.

## Source-available, but not source-complete

The distinction matters and is easy to blur. MAX **is** openly licensed —
Apache-2.0 with LLVM exceptions for the published tree, with usage and
distribution under the Modular Community License. Nothing here is a complaint
about licensing.

The problem is narrower: **the engine's C++ is not in the published tree.**

`max/python/max/_core` — the graph compiler and execution engine — contains
only `.pyi` stubs. But the decisive evidence is its own build file, which names
sources that were stripped at export:

```python
# max/python/max/_core/BUILD.bazel
name = "_core.bindings",
srcs = ["//max/python/max/_core/internal:_core.cpp"],
deps = [
    "//max/python/max/_core/internal:AsyncRTPython",
    "//max/python/max/_core/internal/modules",
]
```

`max/python/max/_core/internal/` **does not exist in the repository, and never
appears anywhere in its git history** — `git log --all -- <that path>` returns
nothing, and `git ls-files` under `_core/` lists `.pyi` files exclusively. The
BUILD file is a public artifact of an internal monorepo in which that directory
does exist. What was published is the interface; the implementation was removed.

So this is not a licensing restriction on source we have. It is source we do
not have.

## The GPU device runtime is missing the same way

`max/mojo/max/gpu/host/device_context.mojo` is ~7,000 lines, and it is a
*binding*, not an implementation. Every operation is an `external_call` into
symbols named `AsyncRT_DeviceContext_*`, `AsyncRT_DeviceTimer_*`, etc.

Searching the **entire tree** for `AsyncRT_DeviceContext` in any C, C++ or
header file returns **zero hits**. Every hit is in a `.mojo` file, and every one
of those is a declaration: `device_context.mojo`, `device_graph.mojo`,
`_nvidia_cuda.mojo`, `_amdgpu_hip.mojo`, `_metal.mojo`, `_metal_capture.mojo`.
The per-vendor files are bindings too — `_nvidia_cuda.mojo` is five
`external_call`s and some opaque struct declarations, not a CUDA driver.

The open `AsyncRT/` tree ships the async runtime and `CPUDevice.cpp`. There is
no accelerator device anywhere in it.

**Consequence: you cannot add a Snapdragon backend by editing MAX's runtime,
because that source is not published.** Any device backend must either
reimplement the `AsyncRT_DeviceContext_*` C ABI from the outside, or replace
the execution layer entirely.

Nor does "just use the prebuilt binary" rescue it on this machine: upstream
`MODULE.bazel` at `f66d4d5` mentions Windows **zero** times. Every trace of
Windows in this tree is WINMOJO's own G2 work. There is no Modular-built engine
for Windows ARM64 to link against.

The one piece of good news: because `device_context.mojo` declares the entire
ABI it calls, the surface a reimplementation would have to satisfy is fully
enumerable from open source. It is large but it is not a mystery.

## What *is* open, and it is far more than the two gaps

The unpublished parts are **both runtime layers**. Everything on the compile
side is present, including the compiler itself.

| Component | Path | Size / nature |
|---|---|---|
| **KGEN — the Mojo compiler** | `KGEN/` | **326 `.cpp`, 234 `.h`, 66 `.td`** |
| Mojo stdlib | `mojo/stdlib/` | Apache-2.0, WINMOJO's scope |
| GPU programming model | `mojo/stdlib/std/gpu/` | device-side intrinsics |
| GPU target tables | `mojo/stdlib/std/gpu/host/info.mojo` | MLIR target per arch |
| **stdlib plugin mechanism** | `mojo/stdlib/std/_plugin/` | `cuda/`, `hip/`, `metal/` |
| Kernel library | `max/kernels/src/` | matmul, attention, conv, nn — Mojo |
| Graph API / layers / pipelines | `max/python/max/{graph,nn,pipelines}` | Python |
| Async runtime + CPU device | `AsyncRT/` | C++ |

**KGEN being open is the single most important correction to the first pass of
this document.** An earlier draft implied the compiler was out of reach. It is
not: `stdlib_plugin` is resolved in `KGEN/lib/KGENDialect/KGENAttrs.cpp`, and
that code treats it as an **opaque string** (`getStdlibPlugin()`), validated
against no closed enum. The plugin registry on the Mojo side
(`std/_plugin/selector.mojo`) matches that string at compile time.

Scope check before anyone gets excited: a plugin is *narrow*. `MetalPlugin` is
twelve lines and leaves every hook at its default. The hooks cover
target-specific stdlib behaviour — `exp`, `tanh`, address-space lookup, `print`
emission, `abort`, assertion messages — **not** code generation. Adding an
`adreno` plugin is an afternoon; it is not the port.

## How Modular targets a GPU with no LLVM backend

This is the most useful thing in the tree, and it is not in any design doc.

Apple's AIR is not an upstream LLVM target, and there is no AIR backend in the
open KGEN either. So how does `triple = "air64-apple-macosx"` produce code?

`KGEN/lib/Compiler/ObjectCompiler/LLVM/` answers it:

- `Transforms/LLVMIRDowngradePass.cpp` — *"Transform LLVM IR for backend
  compilation that takes older version of LLVM IR."*
- `Bitcode/17/`, `Bitcode/19/`, `Bitcode/21/` — three **vendored, version-pinned
  bitcode writers**.

They do not write a backend. They emit LLVM IR, downgrade it to the bitcode
version the foreign toolchain accepts, and hand it to Apple's own compiler.

**That is the template for Adreno**, and Adreno is the easier case: LLVM has had
an in-tree SPIR-V backend since 18, and Qualcomm's driver compilers
(`qcvkarm64xcompiler.dll` for Vulkan, `qcclarm64xcompiler.dll` for OpenCL) are
already on this machine and already consume SPIR-V. We hand off at a documented
interchange format instead of a reverse-engineered bitcode version.

## Metal is the precedent that matters

`info.mojo` tags every target with an `api=` field. Counting them:

- `cuda` — 19 targets
- `hip` — 15 targets
- **`metal` — 10 targets**
- `none` — 1

Apple Metal is a third, already-shipping backend that is neither CUDA nor HIP:
tile-based, unified-memory, mobile-lineage, non-PTX. That is architecturally
the same shape as Adreno. It proves the target layer generalises beyond the two
desktop vendors, and it gives a concrete diff to imitate.

Better still, `mojo/stdlib/docs/adding-gpu-targets.md` is a 19 KB
step-by-step guide to adding a new GPU target — MLIR triple, `data_layout`
string format, `GPUInfo` alias, `_get_info_from_target` wiring, and a
validation checklist. Modular wrote the instructions for exactly this job.

What the guide covers is the **compile** side: getting Mojo to emit code for a
new architecture. It says nothing about the **run** side, which is the closed
part above. That split — compile-side open, run-side closed — is the shape of
the whole problem.

## Licensing, kept separate from the above

Worth restating because the two questions get conflated: licensing is *not*
what blocks the port. The repository is Apache-2.0 with LLVM exceptions, and
`README.md` adds that "MAX usage and distribution are licensed under the
Modular Community License" (https://www.modular.com/legal/community) — a
permissive arrangement for most uses. The blocker is that specific source files
were not published, which is an availability question, not a rights question.

WINMOJO deliberately stays out of `max/` to keep that port wholly permissive.
DragonMax enters `max/` by definition, so it inherits that question for
anything it distributes. This is a real consideration at distribution time, not
a blocker for local research work. Read the actual terms before publishing
artifacts; nothing here is legal advice.
