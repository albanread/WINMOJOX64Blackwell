# Building and testing the device runtime

```powershell
& "C:\Program Files\Microsoft Visual Studio\18\Professional\VC\Auxiliary\Build\vcvarsarm64.bat"
cd dragon\runtime
cl /nologo /O2 /EHsc /std:c++17 /LD /Fe:dragonrt.dll dragonrt.cpp
cl /nologo /O2 /Fe:test_dragonrt.exe test_dragonrt.c
.\test_dragonrt.exe
```

`test_dragonrt.c` deliberately includes no DragonMax header. It resolves every
symbol with `GetProcAddress` and calls through the raw ABI, so it exercises the
interface exactly as Mojo's `DeviceContext` will find it — same symbols, same
calling convention, same ownership rules. If it passes, the surface is right.

## Status — bring-up subset passing on Adreno, 2026-08-19

```
all bring-up exports resolved
  [ok]   DeviceContext_create("adreno", 0)
  device : Qualcomm(R) Adreno(TM) X1-45 GPU
  api    : adreno   id=0
  ver=300  total=16163 MiB  maxAlloc=1024 MiB
  [ok]   createBuffer x / y / out      (bytesize 16384, as expected)
  [ok]   HtoD x / y
  [ok]   loadFunction(saxpy)
  [ok]   enqueueFunctionDirect
  [ok]   synchronize / DtoH / synchronize
  [ok]   all 4096 elements correct (out[0]=4096.0 out[4095]=10238.5)
ALL PASS
```

## Design notes worth keeping

**Module blobs come in two forms.** `loadFunction` sniffs the SPIR-V magic
number `0x07230203` and routes to `clCreateProgramWithIL`; anything else is
treated as OpenCL C and goes through `clCreateProgramWithSource`. The SPIR-V
path is what Mojo will use once KGEN grows SPIR-V emission (W3); the source
path exists so the runtime can be exercised *today*, with hand-written kernels,
before that codegen lands. That ordering is deliberate — it keeps a codegen bug
and a runtime bug from ever being the same investigation.

**Grid/block are CUDA-shaped, OpenCL is not.** Mojo passes a grid of blocks;
OpenCL wants a global size in work-items. The launch multiplies through:
`gws = grid * block`, `lws = block`.

**Launch dimensions must be `uint32_t`.** The bindings carry an explicit warning
that Mojo has two launch paths, and if they declare the symbol with conflicting
i64/i32 signatures, a module composing both fails to legalize. Do not "tidy"
these to `size_t`.

**The ABI is not pure C.** `AsyncRT_DeviceContext_deviceApi` takes an
`llvm::StringRef *`. That is a pointer plus a length, reproduced here as a POD
rather than dragging in LLVM — but it means the interface has a C++ dependency
baked into it, which will matter if the ABI ever grows a second such type.

**Error strings are caller-owned.** NULL means success; anything else must be
released with `AsyncRT_DeviceContext_strfree`. 77 of the 109 symbols return
`const char *`, so getting this wrong leaks on every error path.

## Not yet implemented

Beyond the 33-symbol bring-up subset: events and timers, graph capture
(`DeviceGraphBuilder_*`), multi-device and peer access, and the vendor escape
hatches (`cuda_context`, `metal_device`, …) which have no Adreno meaning and
should stay unimplemented. `ABI.md` tiers all 109.

Real streams are also still nominal: `createStream` makes a distinct OpenCL
queue, but every transfer and launch currently goes to the context's default
stream. That is correct but not concurrent, and it is the next thing to fix
once something needs overlap.
