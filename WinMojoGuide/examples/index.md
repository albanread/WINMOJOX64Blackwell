# The examples, walked through

One page per sample under [examples/win32/](../../examples/win32/): what it
is, how to run it, what to read in it, and the trap it paid for. Read the
program beside the page; the pages quote file and line.

## The floor — start here

| | Sample | What it teaches |
|:---|:---|:---|
| [windows_tour](windows_tour.md) | everything in `std.windows`, against the real machine; the package's acceptance test |
| [winkb_queries](winkb_queries.md) | the metadata queries printing their own answers and provenance |
| [structptr](structptr.md) | one struct, one API, three pointer idioms — the origin rules made observable |
| [comptr](comptr.md) | `ComPtr`'s ownership table asserted against a live COM object |
| [winstr_smoke](winstr_smoke.md) | the UTF-8/UTF-16 boundary, error text, handle truthiness |

## Windows applications

| | Sample | What it teaches |
|:---|:---|:---|
| [life](life.md) | the complete small windowed program: timer, buffers, `GWLP_USERDATA` |
| [ferns](ferns.md) | the chaos game into one BGRA buffer; iteration as a renderer |
| [othello](othello.md) | bitboards; alpha-beta on CPU vs GPU playouts, and why the split |
| [bifurcation](bifurcation.md) | `std.python` as a measured tool: numpy, matplotlib, a timing ratio |
| [life-python](life-python.md) | libpython embedded in the process; pygame's loop, Mojo's grid |

## Direct3D

| | Sample | What it teaches |
|:---|:---|:---|
| [d3dwindow](d3dwindow.md) | the whole D3D11 handshake in 320 lines, field offsets asserted |
| [d3djulia](d3djulia.md) | runtime-compiled HLSL, flip-model traps, a measured refresh rate |

## GPU compute

| | Sample | What it teaches |
|:---|:---|:---|
| [nvidia_mandelbrot](nvidia_mandelbrot.md) | the smallest `max.gpu` kernel, validated against a CPU twin before shown |
| [fernwind](fernwind.md) | GPU atomics proven before pixels; per-frame parameter traffic |
| [fluid](fluid.md) | 44 dependent dispatches; the solver shared by app, smoke test and bench |
| [fluid_bench](fluid_bench.md) | launch cost measured; graph replay at 7.3×; two probe verdicts as fixtures |

## Audio

| | Sample | What it teaches |
|:---|:---|:---|
| [chip](chip.md) | a SID re-implementation; the WASAPI event contract; silent underruns |
| [abcplayer](abcplayer.md) | one schedule, two clocks (samples and ticks); the fill-callback discipline |

## Probes for the other port

| | Sample | What it is |
|:---|:---|:---|
| [adreno_saxpy](adreno-saxpy.md) | the ARM64/Adreno acceptance test, with its debug and index probes; the program shape this tree's GPU path shares |

## Conventions every sample follows

Structures asserted against the metadata (`comptime assert size_of[...]()
== winkb_struct_size[...]()`); no hand-transcribed constants where
`winkb_constant` answers; window procedures that never raise, with state
through `GWLP_USERDATA`; `lParam` coordinates treated as signed halves;
DPI awareness declared before the window exists. `build.sh` builds any
sample (and stages the runtime DLLs beside the exe — a PE has no rpath, and
a missing DLL is a silent 0xC0000135 before `main`); `run.sh` JIT-runs one.
