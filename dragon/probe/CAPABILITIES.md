# Snapdragon capability report

What has actually been proven to run on this machine, measured 2026-08-19.
"Loads" and "executes" are tracked separately on purpose — the first is cheap
and the second is the one that matters.

| Surface | Loads | Executes | Evidence |
|---|---|---|---|
| **Adreno GPU** via our OpenCL | ✅ | ✅ | saxpy 4096 elems exact; matmul 41.9 GFLOP/s exact |
| **Adreno GPU** via `QnnGpu` | ✅ | ✅ | `qnn-platform-validator --backend gpu`: **Unit Test Passed** |
| **Hexagon NPU** via `QnnHtp` | ✅ | ✅ | `qnn-platform-validator --backend dsp`: **Unit Test Passed** |
| **Oryon CPU** via `QnnCpu` | ✅ | ✅ | full graph via `qnn-net-run`, outputs written |
| **Full model graph** on CPU | ✅ | ✅ | InceptionV3-shaped, 298 ms, 2 result sets |
| **Full model graph** on **HTP** | ✅ | ✅ | same graph, 1377 ms incl. prepare, 2 result sets |
| **Full model graph** on `QnnGpu` | ✅ | ❌ | `CL_INVALID_OPERATION` in the recording queue |
| **Our own synthetic model** on CPU + HTP | ✅ | ✅ | 4 MiB matmul chain; HTP matches CPU to 0.062% |
| **128 MiB model** on HTP | ✅ | ✅ | 555 ms on the QAIRT 2.45 runtime |
| **SPIR-V ingestion, native QUALCOMM CL** | — | ❌ | empty `CL_DEVICE_IL_VERSION`, no `cl_khr_il_program` — measured, `probe_adreno_spirv.py` |
| **SPIR-V execution via OpenCLOn12** | ✅ | ✅ | hand-encoded kernel-flavor module ran on the Adreno, returned 42 |

## Reproducing

```powershell
python dragon\probe\probe_surfaces.py         # all three reachable
python dragon\probe\probe_qnn_backends.py     # 5 QNN backends negotiate
python dragon\probe\probe_opencl_exec.py      # real kernel, verified
dragon\bench\matmul_baseline.exe              # CPU vs GPU, verified
```

For the vendor validator, both environment variables matter:

```powershell
$R = "C:\Qualcomm\AIStack\qairt\2.42.0.251225"
$env:PATH = "$R\lib\aarch64-windows-msvc;$R\bin\aarch64-windows-msvc;" + $env:PATH
$env:ADSP_LIBRARY_PATH = "$R\lib\hexagon-v81\unsigned"
& "$R\bin\aarch64-windows-msvc\qnn-platform-validator.exe" --backend all --testBackend --coreVersion
```

## What the validator actually said

**GPU — passed.** It found `OpenCL.dll`, resolved Qualcomm extensions
(`clNewRecordingQCOM`, `clEnqueueRecordingQCOM` — command record/replay, worth
noting for later), reported *"OpenCL 3.0 Qualcomm(R) Adreno(TM) X1-45 GPU"*,
built and ran a vector-addition program, and concluded *"QNN is supported for
backend GPU on the device."*

So **QNN's GPU backend is OpenCL underneath** — the same path our own D2 kernel
takes. That makes the D2 number a fair yardstick for it.

**Hexagon — passed, but only after a fix.** First run failed:

```
ERROR: -6 . Error while executing the sum function.
ERROR: Please use testsig if using unsigned images.
ERROR: Also make sure ADSP_LIBRARY_PATH points to directory containing skels.
Unit Test on the backend DSP: Failed.
```

Setting `ADSP_LIBRARY_PATH` to `lib\hexagon-v81\unsigned` turned it into
*"Unit Test on the backend DSP: Passed."* **Nothing about the hardware was
wrong; the DSP simply could not find its skels.** Worth remembering — the error
text points at image signing first, which is a red herring here.

Two oddities recorded, not explained:

- The tool loads `QnnHtpV73CalculatorStub.dll` and reports *"Core Version:
  Hexagon Architecture V73"* on what is V81 silicon. It then passes against the
  V81 skels. Either the tool's detection is legacy, or the V73 stub is generic.
  Do not treat that "V73" as a reading of the hardware.
- `DSP_INFO UNSUPPORTED_KEY: 49` / `50` appear before the run and appear to be
  harmless.

## Full model graph — CPU and NPU work, GPU does not

Built the SDK's own example model (`examples/QNN/converter/models/qnn_model_float.cpp`,
an InceptionV3 conv+relu graph) into an ARM64 DLL and ran it through
`qnn-net-run` on each backend.

| Backend | Result | Wall time |
|---|---|---|
| `QnnCpu` | **Finished Executing Graphs**, 2 result sets written | 298 ms |
| `QnnHtp` | **Finished Executing Graphs**, 2 result sets written | 1377 ms (incl. prepare) |
| `QnnGpu` | **Graph Execution failure** | 313 ms |

The GPU failure is specific:

```
CL ERROR: (-59) CL_INVALID_OPERATION
GPU ERROR: GPU_ERROR_OPENCL(10014) - OpenCL recorable command queue error
```

That is the `clNewRecordingQCOM` / `clEnqueueRecordingQCOM` path the validator
reported resolving. **`QnnGpu` drives the Adreno through OpenCL command
record-and-replay, and that path is broken on this driver.** Note what it is
*not*: the Adreno itself is fine. Our own direct OpenCL dispatch runs saxpy and
matmul correctly at 41.9 GFLOP/s, and `QnnGpu`'s own vector-add unit test
passes. Only the recorded-queue path fails, and only on a real graph.

### The documented workaround does not exist in this build

`QnnGpuGraph.h` declares `uint8_t disableQueueRecording` as a graph custom
config, defaulting to 0. Reaching it through `qnn-net-run` fails in a way worth
recording, because the two layers contradict each other:

- Put `disable_queue_recording` at the top level of the GPU extension config →
  schema rejects it, saying it depends on `graph_names`.
- Move it beside `"graph_names": ["convReluModel"]` as instructed →
  `ERROR: Unsupported key: graphs/0/disable_queue_recording`.

So the JSON schema validates a key that `QnnGpuNetRunExtensions.dll` then
refuses. **The toggle is only reachable programmatically**, by a host that sets
`QnnGpuGraph_CustomConfig_t` through the API — which is work DragonMax will be
doing anyway, but is not available from the stock tool.

**Consequence for the design: do not build the GPU path on `QnnGpu`.** Our own
OpenCL dispatch already works and is measurably fast; QnnGpu's graph path is
broken here and its escape hatch is unreachable from tooling. The NPU is the
backend where QNN earns its place.

## The HTP does NOT wedge — corrected 2026-08-19

An earlier version of this page reported that the DSP wedged and needed a
reboot, and that the HTP topped out under 128 MiB. **Both were wrong.** See
`../qnn/HTP-RUNTIMES.md` for the full account.

The real fault: the **QAIRT 2.42 runtime** stopped opening DSP sessions, while
GenieX's bundled **QAIRT 2.45** ran the same models on the same device
throughout — including the 128 MiB model, in 555 ms.

| Runtime | 4 MiB | 128 MiB |
|---|---|---|
| SDK QAIRT 2.42 + its unsigned skels | ran, then stopped | fails at session open |
| GenieX QAIRT 2.45 + its skels | **ok**, 395 ms | **ok**, 555 ms |

The failure signature `DspTransport.openSession qnn_open failed, 0x80000406` is
documented by Qualcomm as "the HTP Stub library cannot find the respective Skel
library" — but `ADSP_LIBRARY_PATH` was set correctly and the skel was present,
so the documented cause was ruled out by test.

**The methodological lesson:** my control run re-used the *same runtime* as the
failing run, so when it failed too, that looked like proof of a dead device. It
was nothing of the sort. **A control that shares the suspected fault with the
test is not a control.** The control that actually worked was a *different QNN
runtime against the same device*.

Working configuration today: GenieX's `htp-files` for both `QnnHtp.dll` and
`ADSP_LIBRARY_PATH`. Model DLLs are runtime-agnostic.

Unresolved: why 2.42 stops. Leading hypothesis is unsigned process domains — the
SDK ships only `hexagon-v81/unsigned/`, and the platform validator hinted at
`testsig`. `QnnHtpDevice_UseSignedProcessDomain_t` is the lever to test it.
Not established; not to be written up as the cause until it is.

## Building a model library — the working recipe

`dragon/qnn/build_model_lib.ps1` automates all of this. Four separate traps had
to be cleared, none of which produces an honest error:

1. `qnn-model-lib-generator` hardcodes `cmake -T ClangCL`; a stock VS 18 has no
   ClangCL component → `MSB8020`.
2. The generated code uses `(Qnn_Tensor_t){...}` — a **C compound literal**, a
   Clang extension invalid in ISO C++ at any level. `/std:c++20` clears the
   designated-initializer error (`C7555`) but never `C4576`/`C2059`. **Clang is
   mandatory; there is no MSVC-only path.** WINMOJO's bazel toolchain already
   provides clang 22.1.4 targeting `aarch64-pc-windows-msvc`.
3. The generated `CMakeLists.txt` branches on `CMAKE_GENERATOR_PLATFORM`, which
   Ninja refuses to accept. Branch on which `obj/` directory exists instead.
4. `set VAR=value && next` in cmd captures the space before `&&`. That turned
   `QNN_SDK_ROOT` into `...251225 `, the include path into `...251225 \include\QNN`,
   and surfaced as `fatal error: 'QnnInterface.h' file not found` — a quoting
   bug wearing a missing-header costume. Use `set "VAR=value"`.

Also: the generator writes its staging tree to `tmp_<pid>` in the **current
working directory**, not the `-o` directory, and leaves it behind.
