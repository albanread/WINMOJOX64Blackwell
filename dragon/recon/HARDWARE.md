# Target hardware — measured, not assumed

Machine: Lenovo IdeaCentre Mini 01Q8X10. Everything below was read off *this*
box on 2026-08-19, not from a spec sheet.

## CPU — Qualcomm Oryon (Snapdragon X, X126100)

| Property | Value |
|---|---|
| Cores / threads | 8 / 8 (no SMT) |
| Max clock | 2956 MHz |
| RAM | 31.6 GiB, **unified** across CPU/GPU/NPU |

Already the target of the sibling port (WINMOJO). DragonMax inherits its
toolchain rather than redoing it.

## GPU — Adreno X1-45

Read via `vulkaninfo.exe` from the Adreno driver store package
(`qcdx8380.inf_arm64_3555a260d521ff65`).

| Property | Value | Compare |
|---|---|---|
| Vulkan API | 1.3.295, `DRIVER_ID_QUALCOMM_PROPRIETARY` | |
| Vendor / device ID | `0x5143` / `0x37314430` | |
| Device type | INTEGRATED (unified memory, no PCIe copy) | unlike CUDA/HIP discrete |
| **Subgroup size** | **64** | NVIDIA warp 32, AMD CDNA wave 64, Apple simd 32 |
| Shared memory / workgroup | 32 KiB | NVIDIA Hopper 228 KiB, AMD 64 KiB |
| Max workgroup invocations | 1024 | |
| Max single allocation | 1 GiB | |
| fp16 / int8 / int16 shaders | yes / yes / yes | |
| `subgroupSizeControl` | yes | |

**Caution on that subgroup size — it is not the whole story.** Vulkan reports
64 here, but D1b measured OpenCL returning a *per-kernel* preferred multiple of
64 or 128 on this same device (`probe_opencl_exec.py`). The scheduling width is
not a device constant on Adreno the way it is on NVIDIA and AMD. See
`../../DRAGONMAX-JOURNAL.md` for the measurement.

The AMD wave-64 kernel paths remain the better starting point than NVIDIA's 32,
since 64 divides both observed widths — but nothing should *assume* 64.

32 KiB of shared memory is the tightest constraint — under half of AMD's and a
seventh of Hopper's, so tile sizes copied from either vendor's matmul will not
fit.

### Driver-level APIs available now

Both live in the driver store package above; no SDK install needed.

- **OpenCL** — `OpenCL_adreno.dll`, `qcclarm64xcompiler.dll`
- **Vulkan compute** — `qcvkarm64xum.dll`, ICD `qcvk_icd_arm64x.json`

**OpenCL works through the standard ICD loader** (D1 probe, 2026-08-19). An
earlier guess that no ICD was registered — based on an empty
`HKLM\SOFTWARE\Khronos\OpenCL\Vendors` — was wrong; registration happens
elsewhere and `C:\Windows\System32\OpenCL.dll` enumerates fine.

The real trap is different and worse, because it fails silently:

> **Two OpenCL platforms both claim the Adreno X1-45.**
> `QUALCOMM Snapdragon(TM)` (OpenCL 3.0, QUALCOMM build 807.0) is the native
> driver. `OpenCLOn12` is Microsoft's D3D12 translation layer and reports the
> *same device name*. Pick by **platform**, never by device name.

Measured from the native QUALCOMM platform: 3 compute units, 32 KiB local
memory, 15 GiB global (half the unified 31.6 GiB is exposed to the GPU). The
driver reports `MAX_CLOCK_FREQUENCY` as 1 MHz, which is nonsense — do not use
that field for anything.

`OpenCL_adreno.dll` itself exports neither `clGetPlatformIDs` nor
`clIcdGetPlatformIDsKHR`, so it is not usable as a direct loader. Go through
the system loader.

## NPU — Hexagon HTP (V81)

The Qualcomm AI Runtime is **already on this machine**, bundled inside GenieX
CLI at `C:\Program Files (x86)\GenieX CLI\qairt\htp-files`:

`QnnHtp.dll`, `QnnHtpPrepare.dll`, `QnnHtpV81Stub.dll`, `QnnSystem.dll`,
`QnnIr.dll`, `QnnModelDlc.dll`, `QnnSaver.dll`, plus the DSP-side skels
(`libQnnHtpV81Skel.so`, `libQnnHtpV81.so`).

**V81 is this chip's Hexagon version.** V73/V75/V79 stubs are also present for
other Snapdragon parts — ignore them.

Measured by the D1 probe: `QnnHtp.dll` publishes provider **`HTP_QTI_AISW`**,
backendId 6, core API **2.34.0**, backend API **5.45.0**. `QnnSystem.dll`
publishes `SYSTEM_QTI_AISW`, system API 1.9.0. Both load and answer in a native
ARM64 process.

Driver: Qualcomm HND 30.0.220.3000. This does **not** come from Windows Update;
see the `geniex-gemma4-npu-setup` memory for why that matters.

### Two open-source worked examples are also sitting on disk

`C:\Program Files (x86)\GenieX CLI\llama_cpp` ships `ggml-hexagon.dll` +
`libggml-htp-v81.so` and `ggml-opencl.dll`. llama.cpp's Hexagon and Adreno
OpenCL backends are the nearest prior art for both surfaces, and they are
MIT-licensed and readable.

## The performance fact that should steer the whole project

Measured on this box (see `geniex-gemma4-npu-setup`), decode / prefill tok/s:

| Path | Decode | Prefill |
|---|---|---|
| QAIRT NPU-native, Qwen3-1.7B | **35.6** | **766** |
| CPU, Gemma-4-E4B | 25.3 | 157 |
| llama.cpp NPU (ggml-hex), Gemma-4-E4B | 13.8 | 431 |

**Naive NPU offload lost to the CPU on decode.** Only the NPU-native path — a
graph compiled ahead of time into a QNN context binary — beat it, and then by
just 1.4x. The NPU is not a fast kernel-dispatch device you can point a
kernel-launch runtime at; it pays off only when a whole graph is handed to it
in one piece. Any design that treats the HTP like a GPU will lose to doing
nothing at all.
