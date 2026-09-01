# othello

Othello on a green felt board, in a real Win32 window, with four computer
players -- a port of the Cocoa `othello` example, which is itself a port of a
Common Lisp demo.

It exists to answer a question honestly: **does a computer board-game player
want a GPU?** The short answer is that half of it does, and the useful part of
this example is which half, and why.

```
othello.exe                you are black, white is Advanced
othello.exe --selftest     perft, CPU-vs-GPU agreement, and the timings the
                           argument rests on; no window, nonzero exit on failure
othello.exe --match 20     twenty games, Master (GPU) vs Advanced (alpha-beta)
othello.exe --demo         the window, with the computer playing both sides
othello.exe --ms N         close after N ms, reading the window's own pixels
                           back first and comparing them with the buffer
othello.exe --no-gpu       pretend there is no CUDA device
othello.exe --level N      start at level N (0 Beginner .. 3 Master)
```

## The controls

| | |
|---|---|
| click a dotted square | play there -- you are black |
| `N` | new game |
| `B` `I` `A` `M` | Beginner, Intermediate, Advanced, Master |
| `D` | demo: the computer takes both sides |
| `Q` or `Esc` | quit |

## Build and run

```bash
export MODULAR_MOJO_MAX_WINKB_PATH="F:/bzs/external/+http_archive+winkb/windows_api.db"
./bazel-bin/KGEN/tools/mojo/mojo.exe build --no-optimization \
    -I mojo/stdlib -I . -I max/mojo \
    -Xlinker "$(cygpath -w bazel-bin/nvptx/runtime/nvptxrt.lib)" \
    -o build/othello.exe examples/win32/othello/main.mojo

export PATH="bazel-bin/KGEN:bazel-bin/AsyncRT:bazel-bin/Support:$PATH"
./build/othello.exe
```

`-I .` matters here and does not for the single-file examples: this project is
three files and `main.mojo` imports the other two by their repo-relative
package path (`examples.win32.othello.board`).

It also builds and runs with optimisation -- drop `--no-optimization` -- and
the numbers below are given for both, because the ratio the example is about
moves when you do.

## The board is two integers

Norvig's version in *Paradigms of AI Programming* uses a 100-element array with
a border of sentinel squares, so a walk off the edge hits a wall rather than
wrapping onto the opposite rank. That is the right shape for a language with
arrays and no wide integers, and it costs a bounds check per step in eight
directions.

A board is 64 squares and a machine word is 64 bits, so a position is two
words: the squares one player holds and the squares the other holds. Every rule
becomes shifts and masks -- the sentinel border becomes a mask applied after
the shift, and generating every legal move is eight shifted, masked
propagations with no branches that depend on the position.

`board.mojo` is the whole ruleset -- about eighty lines of code inside 260
lines of file, the rest being why. It is checked against the published perft
numbers, which is the only way to be sure a move generator is right, because
one that is subtly wrong plays a game that looks entirely normal:

```
perft 1 = 4        perft 5 = 1396
perft 2 = 12       perft 6 = 8200
perft 3 = 56       perft 7 = 55092
perft 4 = 244
```

## Where the GPU does not help

**Alpha-beta.** Its whole advantage is never examining a branch that cannot
change the answer, which makes the work each thread does depend on what the
other threads have already found. That is the opposite of what the hardware is
for: threads diverge at the first cutoff, and the pruning -- the entire point
-- has to be given up to keep them in step.

It also does not need help. Measured here, choosing an opening move:

| | `--no-optimization` | optimised |
|---|---|---|
| depth 3 | 53 µs | 11 µs |
| depth 4 | 143 µs | 23 µs |
| depth 6 | 2113 µs | 336 µs |

A hundred and forty microseconds. Moving that to a GPU would make it slower,
and saying otherwise would be a demo rather than an argument.

## Where it does

**Monte-Carlo playouts.** Play the position out to the end with random legal
moves, four thousand times per candidate, and keep the move that wins most
often. Every playout is independent, holds its entire state in two registers,
touches no memory until it reports one integer, and runs exactly the same
instructions as its neighbours. That is the shape the hardware is built for.

16,384 playouts from the opening position, on a T1000 (Turing, 14 SMs -- the
smallest NVIDIA card in this tree):

| | CPU | GPU | |
|---|---|---|---|
| `--no-optimization` | 485 ms | 9 ms | **49x** |
| optimised | 57 ms | 1.7 ms | **34x** |

Both pick the same move, which is the cheap correctness check worth doing
whenever the same algorithm exists twice -- and the self-test repeats it from
three midgame positions, because the opening is symmetric and a bug that
ignores half the board can survive it.

The gap between the two rows is worth a sentence. `--no-optimization` costs the
CPU player a factor of eight and the GPU player only a factor of five, because
the GPU's number is a PTX kernel that the host flag does not reach plus a host
side reduction and launch that it does. Quote either ratio you like; quote the
build with it.

The speed is not the interesting part -- the strength is. Given the GPU, a
level that would take most of a second per move on the CPU answers while your
hand is still on the mouse, so it can afford to be the strongest player here.
Twenty games against the best CPU level, `--match 20`:

```
Master (GPU playouts, 4096 per move) vs Advanced (alpha-beta, 4 ply)
  Master 15 - 5 Advanced  ( 0 drawn ) in 928 ms
```

with winning margins from 2 to 33 discs. (That is the optimised build; the
same twenty games take 4.6 s built with `--no-optimization`, and come out the
same, because the seeds are fixed.) So the bitboards are not a
micro-optimisation: they are the reason a thread can hold a whole game, which
is the reason the GPU player exists at all.

## What to look for

**Watch a level lose to the next one up.** Press `D` and the computer takes
both sides: black is always Master, white is whatever level is selected. Set it
to `B` first and watch a random player get taken apart; set it to `A` and watch
a much closer game that Master still usually wins.

**Watch the clock in the status line.** Advanced answers in 0 ms, Master in 5
to 40, and the number moves with the board: the playout cost is
`legal moves x 4096`, so it peaks in the midgame where there are most
candidates and falls away at both ends.

**The dots are legal moves**, shown for you and not for the computer. The amber
ring is the square just played.

**Corners.** Both search levels use Norvig's weighted squares, which value a
corner at 120 and the square diagonally inside it at -40, so you will see the
computer refuse squares next to an empty corner. Master knows nothing about
corners at all -- it has no evaluation function, only the result of playing the
game out -- and takes them anyway, because positions with corners in them win
more random games.

## How it works

### Pixels: `StretchDIBits`, and GDI text on top

The board is drawn into a BGRA buffer and pushed into the window's device
context with one `StretchDIBits`, exactly as `life/` does: no swap chain, no
D3D device, no COM, nothing that can be lost and need recreating.

Two differences from `life/`. The blit is **1:1 and the window is not
resizable** -- `WS_THICKFRAME` and `WS_MAXIMIZEBOX` are taken out of
`WS_OVERLAPPEDWINDOW` -- because a click has to map to a square by division and
a half-scaled disc is ugly. And the two lines under the board are **GDI text
drawn on the same device context after the blit**, because text is the one
thing a hand-written rasteriser has no business doing: a font, hinting and
ClearType are already in the box.

The felt, the grid, the star points and the vignette never change, so they are
built once into a background buffer and copied over the frame at the start of
each redraw; only the discs are drawn per move. Discs are anti-aliased by
coverage and shaded from a highlight above and to the left, with a soft shadow
under each -- a flat black ellipse on green felt reads as a hole in the board
rather than as a piece.

### The loop owns the GPU

`life/` uses a blocking `GetMessageW` loop and does its work in the window
procedure. This one cannot: a window procedure is captureless -- Windows calls
it -- so anything it touches has to be reachable through the single pointer a
window can store. A `DeviceContext` and its two buffers would have to be
smuggled through that hole.

So the structure is `fluid/`'s. A hand-rolled `PeekMessageW` pump in `main`
owns the CUDA context, the device buffer, the pinned host buffer and the whole
game as ordinary locals; the window procedure paints and closes and does
nothing else. Input is read in the pump, out of the `MSG` it just peeked.

Unlike `fluid/`, nothing here animates, so the pump ends each idle turn in
`WaitMessage` and the process uses no CPU at all while it is your move.

One ordering detail that is easy to get backwards: "White is thinking..."
has to be *painted* before the thinking starts, so the pump sets the flag,
`continue`s to the top, redraws, forces the paint with `UpdateWindow`, and only
then calls the search. Setting the flag and calling the search in the same pass
paints the message after the move it was describing.

### One kernel, one thread, one game

```mojo
def playout_kernel(wins, black, white, moves, move_count, black_to_move, seed):
    var idx = Int(global_idx.x)
    ...
    var move = nth_bit(moves, idx // PLAYOUTS_PER_MOVE)
```

Threads are laid out as (move, playout), so a whole warp works on the same
candidate and walks the same code with different dice. Each thread writes one
`Int32` and the sum is taken on the host: an atomic per playout would serialise
exactly the thing that is supposed to be parallel, and the reduction is a few
thousand additions on a CPU that is waiting anyway.

The kernel and the CPU fallback call the *same* `playout` from `ai.mojo`, which
is what makes "both pick the same move" a real check rather than a comparison
of two different programs.

## Evidence

`--selftest` opens no window and returns nonzero if anything fails:

```
rules -- perft from the opening position:
  perft 1 = 4  expected 4   ok  ( 7 us )
  ...
  perft 7 = 55092  expected 55092   ok  ( 15361 us )

search -- alpha-beta, the level that does not want a GPU:
  depth 4 -> d3   143 us

playouts -- the level that does:
  CPU  16384 playouts -> f5   485 ms
  GPU  NVIDIA T1000 8GB
  GPU  16384 playouts -> f5   9 ms   speedup 48.9x
  both pick the same move: ok
  after 3 random moves, both pick c6 / c6   ok
  after 6 random moves, both pick c2 / c2   ok
  after 9 random moves, both pick a8 / a8   ok
```

`--ms N` proves the *window*, which is a different question. It copies the
client area back out with a `BitBlt` into a DIB section and compares it with
the buffer we computed, pixel for pixel -- not a count of lit pixels, an
equality, because the blit is 1:1 and GDI copies 32-bit BGRA verbatim:

```
frames painted: 122
readback: client 560 x 598  (buffer 560 x 598 )
   board area: 300160 pixels identical, 0 different
   the window is showing exactly the buffer we computed
   status strip: 12173 pixels differ from the buffer -- that is the GDI text
```

The strip below the board is excluded from the equality and reported
separately: those 12,173 pixels are the difference GDI's text made after the
blit, so a run where the text silently failed to draw says `NO TEXT WAS DRAWN`
rather than passing.

## Differences from the Cocoa version, and why

* **The status line is GDI text, not `NSString drawAtPoint:`.** Same two lines,
  same content, a `CreateFontW` handle instead of `NSFont`.
* **The window does not resize**, and the blit is 1:1. The Cocoa one is fixed
  too; what is new is having to say so, and having to declare DPI awareness
  before any window exists or Windows bilinearly upscales the discs.
* **The direction is a compile-time parameter.** `shift[dir](b)` with a
  `comptime for` over the eight directions, where the Mac passes `dir` as a
  runtime argument to an if-chain. The eight-way branch is uniform across a
  warp so it never diverged, but it is also the inner loop of alpha-beta, and
  removing it is most of why depth 4 costs 143 µs in an unoptimised build.
* **Master falls back to CPU playouts when there is no CUDA device**, at 512
  per move instead of 4096, and says which it is doing in the status line. The
  Mac version does the same; here it is an `Optional[GpuPlayouts]` because the
  Windows examples that need CUDA otherwise refuse to start, and three of these
  four players never wanted a GPU.
* **`--selftest`, `--match` and `--ms` are new.** The Mac version quotes perft
  numbers and a 6-0 match result in its README without shipping anything that
  reproduces them. All three are doors in this one, and the match result is
  reported as measured: **15-5 over twenty games**, not 6-0. Six games is a
  small enough sample that 6-0 and 4-2 are the same claim.
* **The `llvm.scmp` workaround is kept but is not needed here.** The Mac's
  kernel would not link because `Int(b > w) - Int(w > b)` folds into a three-way
  compare intrinsic the Metal backend has no instruction for. NVPTX lowers it
  fine. The odd-looking `Int(b > w) * 2 - Int(b != w)` stays, with the comment,
  because it costs nothing and the next backend somebody targets may be Metal
  again.
* **The event loop is hand-rolled for a different reason.** On the Mac it is
  because a `DeviceContext` cannot live in a `named_global` and a Cocoa
  callback cannot reach a local. On Windows the callback is a C-ABI window
  procedure with the same problem and the same answer, so the code looks
  similar and the paragraph explaining it is not the same paragraph.

Nothing was left out: same four levels, same evaluation table, same corner
bonus, same playout policy, same 4096 playouts per candidate, same board.

## No hand-declared Windows

There is not a DLL name, a message number, a virtual key, a window style, a
raster operation, a stock font, a text background mode or a struct size written
by hand in `main.mojo`. All of it is a query against `windows_api.db`, so an
unknown name is a compile error rather than a wrong number:

```mojo
comptime STYLE = winkb_constant["WS_OVERLAPPEDWINDOW"]() & ~(
    winkb_constant["WS_THICKFRAME"]() | winkb_constant["WS_MAXIMIZEBOX"]()
)
_ = SetBkMode(hdc, c_int(winkb_constant["TRANSPARENT"]()))
var ps = List[UInt8](length=winkb_struct_size["PAINTSTRUCT"](), fill=0)
```

`PAINTSTRUCT` is never declared, only sized -- it is a box this code never
looks inside. The four structs that *are* declared each carry a
`comptime assert` against `winkb_struct_size`, so a layout that does not match
Windows fails to build.

## Files

```
board.mojo    the rules, as shifts and masks, plus perft
ai.mojo       four players, and the kernel one of them runs
main.mojo     the window, the drawing, and the pump
```
