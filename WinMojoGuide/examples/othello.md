# othello — bitboards on the CPU, playouts on the GPU, and knowing which is which

Othello on a green felt board: you are black against four CPU levels —
Beginner plays random moves; Intermediate and Advanced are alpha-beta at 3
and 4 ply; **Master runs 4,096 Monte-Carlo playouts per candidate move on
the NVIDIA GPU**. Click a dotted square. `N` starts a new game,
`B`/`I`/`A`/`M` switch levels, `D` toggles the GPU off, `Q` quits.

## Run it

```
./examples/win32/build.sh othello
./bazel-bin/examples/win32/othello.exe
```

Headless doors: `--selftest` (rules and perft), `--match N` (levels play
each other), `--demo`, `--ms N`, `--no-gpu`, `--level N`.

## The walkthrough

**The rules are two `UInt64` bitboards** (board.mojo): black and white,
moves and flips computed as shifted masked propagations — eight directions,
no branches — with `shift[dir]` taking the direction as a compile-time
parameter so each fold is one shift+AND (board.mojo:46). `perft` sits in
the same file, which is how the rules stay honest: `--selftest` counts
nodes to known depths.

**The thesis is the interesting part.** Alpha-beta *must* stay on the CPU —
it is branchy, serial, and cache-shaped (ai.mojo:116, `negamax` with pass
handling and terminal disc-count scoring; the evaluation is Norvig's weight
table folded to a quarter 4×4, corners 120, corners-adjacent −40). Random
playouts are *embarrassingly* parallel: `playout` (ai.mojo:225) plays one
random game entirely in registers, shared verbatim between CPU and GPU, and
`playout_kernel` (ai.mojo:301) runs one thread per playout with threads
laid out `(move, playout)` so a warp shares a candidate — the reduction
happens on the host in `GpuPlayouts.best`. Measured: **34–49× over the CPU
player**, which is why Master is a different kind of opponent rather than a
deeper one.

**The window is the plain Win32 shape**: event-driven, `WaitMessage` when
idle (zero CPU), `present_bgra` for the board and `TextOutW` for status.
One deliberate two-pass: the computer's move runs *after* a paint that
shows "White is thinking..." — the README's trap is exactly this: *setting
the flag and calling the search in the same pass paints the message after
the move it was describing*.

## What it teaches

Bitboards as the natural Mojo idiom; GPU kernels alongside CPU code sharing
one source of truth for the rules; and the honest split — the GPU gets the
work that scales with thread count, the CPU keeps the work that scales with
branch prediction.
