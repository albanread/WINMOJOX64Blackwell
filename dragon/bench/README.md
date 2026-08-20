# `dragon/bench/` — baselines

## `matmul_baseline.c` — D2

fp32 matmul, CPU and Adreno in the **same process**, same matrices, same timer,
same verification. Built to answer one question: is the Adreno X1-45 worth a
device runtime, or does the CPU already win?

```powershell
& "C:\Program Files\Microsoft Visual Studio\18\Professional\VC\Auxiliary\Build\vcvarsarm64.bat"
cl /O2 /openmp /Fe:matmul_baseline.exe matmul_baseline.c
.\matmul_baseline.exe
```

No OpenCL SDK is installed, so the entry points are declared in the source and
resolved from `OpenCL.dll` at runtime. MSVC's `/openmp` is OpenMP 2.0 and will
not accept a loop variable declared in the `for`-init clause — hence the
hoisted `int i`.

### Result, 1024x1024 (2.15 GFLOP), 2026-08-19

| Path | Time | Throughput |
|---|---|---|
| CPU, Oryon, 8 threads | 172.5 ms | 12.45 GFLOP/s |
| Adreno X1-45, kernel only | 51.2 ms | **41.92 GFLOP/s** |
| Adreno, incl. H2D+D2H | 52.4 ms | 41.02 GFLOP/s |

**3.37x the CPU**, verified exact — worst absolute difference 0 across all
1,048,576 elements.

**Read the CPU number sceptically, in our own favour's despite.** 12.45 GFLOP/s
is about 6.6% of the Oryon's ~189 GFLOP/s fp32 peak (8 cores x 2.95 GHz x 4
lanes x 2 FMA). The `i-k-j` loop is threaded but not blocked or hand-vectorised,
so this is a competent-naive baseline, not a tuned one. **A proper NEON matmul
would narrow the 3.37x considerably** — treat it as an upper bound on the GPU's
advantage, not a measurement of it.

The transfer numbers are the more durable finding: **H2D 0.3 ms + D2H 0.9 ms for
4 MiB each way**, so transfers cost 2% of the kernel. That is the integrated,
unified-memory architecture showing up, and it is a real structural advantage
over discrete GPUs that no amount of CPU tuning erodes.

Also recorded: the tiled kernel uses 2048 B of local memory against the 32 KiB
limit, and reported a preferred workgroup multiple of 128.
