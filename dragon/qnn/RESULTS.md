# HTP vs CPU — measured

Our own generated matmul chains, run through `qnn-net-run` on the QAIRT 2.45
runtime (GenieX's; see `HTP-RUNTIMES.md` for why not the SDK's 2.42).

| Weights | dim × layers | CPU | HTP | HTP speedup |
|---:|---|---:|---:|---:|
| 4 MiB | 512 × 4 | — | ok | — |
| 32 MiB | 1024 × 8 | **348 ms** | 451 ms | 0.77x — *CPU wins* |
| 128 MiB | 2048 × 8 | 783 ms | **555 ms** | 1.4x |
| 512 MiB | 4096 × 8 | 3268 ms | **1210 ms** | 2.7x |
| 1 GiB | 4096 × 16 | 7116 ms | **1751 ms** | **4.1x** |

## What this establishes

**No ceiling anywhere near where we feared.** 1 GiB of weights executes on the
Hexagon without complaint. The "128 MiB ceiling" recorded earlier today was an
artefact of a broken runtime pairing, not a hardware limit, and it is retracted.

**The crossover sits between 32 MiB and 128 MiB.** Below it the Oryon CPU is
faster; above it the NPU pulls away. That puts a number on the pattern already
seen in the GenieX benchmarks, where naive NPU offload lost to the CPU on
decode — small graphs do not amortise the cost of getting onto the DSP.

**The advantage grows with size:** 1.4x → 2.7x → 4.1x. That is the shape you
want for LLM work, where the weights are the workload.

## Numerical validity, and a flaw worth recording

With correctly scaled weights, CPU and HTP agree closely:

| Model | max output | max abs diff | relative |
|---|---|---|---|
| 4 MiB (512 × 4) | 56.1 | 0.0348 | **0.062%** |
| 32 MiB (1024 × 8) | 5788 | 1.586 | **0.0274%** |

The HTP computes at reduced internal precision and lands within a few
hundredths of a percent. That is a real correctness signal, not just "it ran".

**The flaw:** the first version of the generator scaled weights by a constant,
so a `[1,D] × [D,D]` layer amplified by roughly `sqrt(D) × mean|w|` — about 4.5x
per layer at D=4096. Eight layers reached ~1e14 and the two backends disagreed
**100%**. Both still printed *Finished Executing Graphs* and both still wrote
output files.

So the 512 MiB and 1 GiB rows above are valid as **capacity and throughput**
measurements — the same arithmetic work is performed either way — but their
*outputs* are numerically meaningless and no correctness claim is made for
them. The generator now scales by `1/sqrt(dim)`, which is what produced the
32 MiB row.

This is the second time today a run that "passed" was not a pass.
`Finished Executing Graphs` means the graph executed, nothing more.

## Reproducing

```powershell
$env:QNN_SDK_ROOT = "C:\Qualcomm\AIStack\qairt\2.42.0.251225"
python dragon\qnn\gen_matmul_model.py --dim 4096 --layers 16 --out gen
.\dragon\qnn\build_model_lib.ps1 -Cpp gen\mm_d4096_l16.cpp -Bin gen\mm_d4096_l16.bin -Out build
```

Then run with `PATH` and `ADSP_LIBRARY_PATH` both pointed at the GenieX
`htp-files` directory.

## Still open

- Where the ceiling actually is. 1 GiB is a floor, not a limit. Next steps:
  2 GiB, 4 GiB — and note the weights are embedded in a DLL, so the PE image
  format may bite before the DSP does. That would be a *tooling* limit, and the
  context-binary route (`qnn-context-binary-generator`) is the way past it.
- int8 / quantised throughput, which is what the 45 TOPS figure actually refers
  to. Everything above is fp32.
- Why the SDK's own 2.42 runtime stops working.
