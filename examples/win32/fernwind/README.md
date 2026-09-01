# fernwind

A meadow of Barnsley ferns computed by the GPU, swaying in the wind. Every
frame is drawn from scratch by twenty-four thousand independent chaos games
that meet in shared density buffers through atomic adds.

```
  click        plant a fern where you clicked -- lower is nearer, so bigger
  space        still the air
  r            reseed the landscape
  q / Esc      quit, as does closing the window
```

## What it demonstrates

The honest way to grow a Barnsley fern is the chaos game: one point chasing
itself through four affine maps, plotted as it goes. That is one thread's
work, and it is also the reason a fern drawn that way cannot move -- the
picture **is** the accumulation, so erasing it erases the only copy of the
fern.

This is the fractal-flame answer instead. Twenty-four thousand threads each
run their **own** short chaos game -- twelve burn-in steps to land on the
attractor before anyone is allowed to see them, then 140 plotted ones -- and
their hits land in four shared density buffers through `Atomic.fetch_add`.
Nothing is carried between frames, and that is what buys the animation: with
no accumulated picture to protect, the **maps** are free to change.

So the wind lives in the mathematics rather than in a displacement applied
afterwards. Each fern's climb map is rotated a fraction of a degree by a
gusting wind field, and because that map applies *recursively* up the plant, a
uniform rotation compounds into a progressive bend. Stems lean, tips whip.
Nobody wrote a bend; rotating one 2x2 matrix did it.

`nvidia_mandelbrot` puts a Mojo kernel on the NVIDIA GPU and proves NVPTX
handles a divergent loop. This is the next shape after that one: divergent
loops **plus** scattered read-modify-write traffic between threads that never
synchronise with each other. Atomics on global memory are the load-bearing
feature, and every visible thing in the window depends on them being real.

## The atomics are proved, not assumed

The Mac original lowers these atomics through the AIR backend. Here they go
through NVPTX onto a T1000 -- Turing, sm_75 -- so `atomics_hold()` runs
before the window is allowed to open: 65,536 threads hammer 256 slots sixteen
times each, and the totals must come out exact.

```
atomics        1048576 of 1048576 increments survived, 7340032 of 7340032 weighted
               all present, so the density buffers are sound
```

This is worth a kernel of its own because the failure is invisible. If the
backend lowered `fetch_add` as a load-add-store, the picture would still look
like a fern -- just quietly, undetectably thin. The program refuses to draw a
picture it cannot vouch for.

Nothing else here needs sm_80: no bf16, no tensor cores, no async copy. Float32
arithmetic, a data-dependent loop, and four atomic adds.

## What to look for

The ferns do not merely wobble. Watch the **tips** against the **bases**: the
bases barely move and the tips travel several pixels, because the rotation is
applied once per level of recursion and there are more levels between the root
and a tip than between the root and the first frond. Gusts also *travel* --
each fern reads the wind field a little later the further right it stands, so
a gust crosses the meadow rather than hitting it all at once.

Press **space** and the geometry freezes but the picture does not go
completely static: the fern is still being replotted from scratch every frame
with fresh randomness, so a faint Monte-Carlo shimmer stays on the wisps. That
shimmer is the honest signature of the method. Measured off the screen, a
half-second of wind changes ~22,000 pixels by more than 40 levels; the same
interval with the air stilled changes ~1,100.

Where two ferns overlap they **blend by evidence, not by draw order** -- each
hit contributes its fern's colour weighted into the accumulators, so the
composite is the density-weighted mean of the colours that actually landed
there. Click into an existing fern to see it.

Clicking low plants a big, bright, warm fern and clicking near the horizon
plants a small, dim, blue-shifted one, because depth below the horizon drives
size, brightness and blue-shift together and that is the only thing making the
meadow recede. Past 24 ferns the oldest is replaced.

## How the pixels reach the window

The route is the proven one from `nvidia_mandelbrot`, and Direct3D does almost
nothing:

1. `chaos_kernel` scatters 3.4 M points into four `uint32` density buffers.
2. `shade_kernel` composites those densities over a CPU-painted backdrop and
   writes **finished BGRA**, one word per pixel.
3. That frame is read back into pinned host memory and uploaded straight into
   a `B8G8R8A8_UNORM` texture with `UpdateSubresource`.
4. A fullscreen triangle draws it. The only HLSL in the program is one
   `Load` -- the shading already happened in Mojo, on the GPU.

The tone curve is where the picture gets its restraint: coverage is
`n / (n + K)`, which density can push toward opaque but never past it, so the
spine goes solid, the wisps stay wisps, and nothing blows out to white however
many streams happen to land on one pixel.

The sky and lawn are painted once per landscape by the CPU -- value-noise
clouds and fourteen thousand grass blades, back to front -- and uploaded. Only
the ferns are recomputed.

## Windows details worth stealing

**Everything Windows-shaped comes from the metadata.** Struct sizes are
asserted against `winkb_struct_size` at compile time, every window message and
style and virtual-key code comes from `winkb_constant`, every vtable slot from
`winkb_vtable_index`, the `GetBuffer` IID from `winkb_interface_iid`, and each
entry point's DLL from `winkb_function_dll`. There are no hand-written slots,
sizes, GUIDs or DLL names.

**The window procedure only sets flags.** Windows calls it, so it must never
raise -- unwinding through a Windows frame is undefined -- and nothing that
touches the GPU may happen inside a callback. It is also captureless, so it
cannot see a local in `main`: the command block lives on the heap and the
window carries its address in `GWLP_USERDATA`.

**`AdjustWindowRectEx`, not a guess.** The client area has to be exactly
1024x640 or the swap chain and the window disagree and DXGI stretches the
meadow. Windows is asked how much frame this style needs rather than being
told 16 and 39.

**Per-monitor DPI awareness, set first.** Without it Windows reports a smaller
desktop than there is, lets the process draw at that size, and stretches the
result -- a soft meadow, and clicks that land somewhere other than where they
were aimed.

**`Present`'s HRESULT is read as `Int32`.** A COM method returns its HRESULT in
EAX, which zeroes the upper half of RAX, so read into a 64-bit integer a
failure code looks positive and `< 0` is never true. Only a negative code is a
failure here: `DXGI_STATUS_OCCLUDED` is a *success* that means nobody can see
the window, which is a machine state worth reporting rather than dying of, and
the exit summary says how many frames it happened to.

**Mouse coordinates are two signed 16-bit halves of `lParam`.** Read unsigned,
a press arriving from off the left edge reports x = 65,000-odd.

**The window resizes; the swap chain does not.** Drag an edge and DXGI scales
the fixed 1024x640 back buffer into the new client area, which is a perfectly
good answer for a picture — but it means a click no longer arrives in meadow
coordinates. The handler asks `GetClientRect` and maps it back, so a fern is
planted under the pointer at any window size. Without that step the error is
proportional to how far from native the window has been dragged, which is the
kind of bug that looks like bad aim rather than missing arithmetic.

## Ported from the Mac original, with one deliberate change

`MojoCocoa/examples/fernwind` plots **280** points per stream, 6.9 M a frame.
This plots 140, and says so out loud because the reason is measurable rather
than a matter of taste. On this T1000 the chaos-game arithmetic costs 9.5 ms a
frame and the four atomic adds on top of it cost 51 ms. Atomic throughput is
the entire cost, it is very nearly linear in the number of adds issued, and it
is a property of the card:

```
  chaos game, atomics replaced by a plain store    9.5 ms
  ... with 1 atomic add per plotted point         15.3 ms
  ... with 2                                      29.0 ms
  ... with 4 (what the picture needs)             60.7 ms
```

Packing the three colour channels into a single 64-bit atomic was tried and
saved only 15%, because a `u64` atomic costs about what two `u32` ones do. So
the point count comes down instead and `TONE_K` comes down with it -- coverage
is `n/(n+K)`, so halving the density and halving K leaves every pixel at the
opacity it had. The two pictures are indistinguishable; the frame rate
doubles, from 14 fps to 28.

The wind clock also differs. The Mac steps its wind by a fixed 1/60 s because
its frame budget is never in question; here the step is the frame that
actually elapsed, clamped, because a fixed step on a card that does not always
hold 60 puts the wind into slow motion rather than dropping frames of it,
which looks like a bug and is one.

Everything else is the same program: same four maps, same wind field, same
depth-driven colouring, same backdrop, same controls.

## Measured on this machine

NVIDIA T1000 8GB, 1024x640, twelve seeded ferns, built with the
`--no-optimization` line below:

```
swayed 1 landscape(s) over 600 frames in 20814 ms
               28 fps
last frame      61422 of 655360 pixels carry fern — 9 percent coverage
```

Dropping `--no-optimization` from that line takes the same 600 frames to
11,800 ms — **50 fps** — because roughly half the remaining cost is the
chaos game's own arithmetic rather than the atomics.

That last line is the program checking its own work: the backdrop is known, so
counting the pixels the ferns changed answers "did the GPU actually put a
meadow there" without anyone having to look at a screen.

Two environment variables exist for exactly that kind of unattended run:
`FERNWIND_FRAMES=N` renders N frames and exits, and `FERNWIND_DUMP=path`
writes the final frame as raw BGRA on the way out.

## Running it

Run it from the IDE with Build > Run Without Debugging, or from a
terminal:

```
mojo run main.mojo
```

Built and run standalone from the repository root:

```bash
export MODULAR_MOJO_MAX_WINKB_PATH="F:/bzs/external/+http_archive+winkb/windows_api.db"
./bazel-bin/KGEN/tools/mojo/mojo.exe build --no-optimization \
    -I mojo/stdlib -I . -I max/mojo \
    -Xlinker "$(cygpath -w bazel-bin/nvptx/runtime/nvptxrt.lib)" \
    -o build/fernwind.exe examples/win32/fernwind/main.mojo

export PATH="bazel-bin/KGEN:bazel-bin/AsyncRT:bazel-bin/Support:$PATH"
./build/fernwind.exe
```

The `-I max/mojo` is what makes `max.gpu.host` resolve, and the `-Xlinker`
line is the NVPTX device runtime -- without it every `AsyncRT_*` symbol is
unresolved. The three runtime DLLs must be on `PATH` or the process dies with
`0xC0000135` before `main`, silently.
