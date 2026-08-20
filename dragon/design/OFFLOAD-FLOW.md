# How a kernel's SPIR-V travels from ObjectCompiler to the GPU

Traced 2026-08-19 through the published source, with file:line evidence. The
question this answers: after `SpirvBackend::emitObject` produces a `.spv`
module, what carries it to the `AsyncRT_DeviceContext_loadFunction` call our
runtime serves — and is any of that carrying machinery missing?

**Answer: nothing is missing. The flow is comptime compilation inside the
compiler itself, and it dispatches through exactly the three registries the
SPIR-V trio implements.**

## The chain, hop by hop

```
ctx.enqueue_function[my_kernel](...)                      user's standard Mojo
  │
  ▼
DeviceFunction (device_context.mojo:2796)
  comptime _emission_kind = "asm" if (cross-compiling NVIDIA) else "object"
  │                                   └─ Adreno takes the "object" path
  ▼
_compile_code[func, emission_kind, target](…)             compile.mojo:36
  = compile_info[…]()          ← comptime intrinsic; the ELABORATOR invokes
  │                              the ObjectCompiler for the device target
  ▼
ObjectCompiler::emitOffloadKernels                        ObjectCompiler.cpp:1811
  - lowers the module through KGENToLLVM
      └─ SpirvLowering.markExportedKernel marks each kernel SPIR_KERNEL,
         which the LLVM SPIR-V backend turns into OpEntryPoint
  - splitPerExported: one submodule per kernel (backend splitStrategy
    notwithstanding — offload is always split per exported kernel, :1806)
  - each split carries its identity as the kgen.offload.kernelid
    attribute (:1486; a missing id is a hard error for offload backends)
  - lowerLLVMModuleToObject → dispatches by triple through
    TargetBackendRegistry → SpirvBackend::emitObject → llc (SPIRV backend)
    → the .spv module, magic-checked, returned as a BufferRef
  - result: DenseMap<kernelId, DenseMap<EmitAs, BufferRef>>  (:1812)
  │
  ▼
CompiledFunctionInfo.asm                                   the elaborator
  materializes the winning buffer as comptime data in the program image.
  The field is named `asm` but carries bytes; loadFunction passes
  `asm.byte_length()`, so binary is fine.
  │
  ▼
AsyncRT_DeviceContext_loadFunction(name, fn, data, len, …) device_context.mojo:3672
  │
  ▼
dragonrt.dll loadFunction                                  dragon/runtime
  sniffs SPIR-V magic 0x07230203 → clCreateProgramWithIL → clBuildProgram
  (Qualcomm driver compiler lowers to Adreno ISA) → clCreateKernel(fn)
  │
  ▼
enqueueFunctionDirect → clEnqueueNDRangeKernel → silicon
```

## The three facts that make this closed-loop

1. **There is no separate packaging step.** The `.spv` never touches a linker,
   an archive, or the host image. `emitObject`'s buffer *is* what
   `CompiledFunctionInfo` embeds and what `loadFunction` receives. This is why
   `SpirvBackend::emitObject` returning the raw buffer (and never calling
   `ctx.linkObject`) is correct rather than lazy.

2. **The kernel's entry-point name survives the whole chain.** The LLVM
   function name becomes the SPIR-V `OpEntryPoint` name (via the SPIR_KERNEL
   marking), `CompiledFunctionInfo` carries the same mangled name, and
   `loadFunction` hands it to `clCreateKernel`. One name, three consumers, no
   translation table to maintain.

3. **Emission kind is decided in the stdlib, not the compiler.** Only
   cross-compiled NVIDIA uses `"asm"` (PTX text for later ptxas). Everything
   else — Metal, and now Adreno — ships the backend's object bytes. No stdlib
   change is needed for the object path; the default is already right.

## What this means for integration

The DragonMax-side chain has no gaps left to fill. Every remaining unknown is
a *first-compile* question (does the trio compile against the real MLIR/LLVM
headers), not a *missing-component* question. Those are enumerated in
`../HANDOFF.md`, which also defines the acceptance test that decides "done".
