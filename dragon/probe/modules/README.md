# Captured SPIR-V modules

- `saxpy_adreno_as5.spv` — the compiler team's captured Mojo-emitted saxpy
  (original at WINMOJO `dragon/probe/modules/saxpy_adreno.spv`, 2,096 bytes)
  with its two `OpTypePointer Function` words flipped to `CrossWorkgroup`.
  This patched module was the experiment that isolated the clCreateKernel -5
  root cause: original fails creation; this one creates, launches, and
  verifies 4096/4096 on the Adreno via OpenCLOn12.

Tools: `../spv_tool.py` (decoder + structural checks — the kernel-param
storage check catches this class on sight), `../spv_run.py` (step-by-step
loader/launcher for any .spv).
