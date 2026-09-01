# Bifurcation — Mojo computes, Python presents

The logistic map, `x → r x (1 − x)`, swept across 1,600 values of `r`. The
attractor doubles, doubles again, and falls into chaos — with windows of order
inside it. The lower panel is the Lyapunov exponent, and it dips below zero
exactly where those windows are.

![the figure this writes](example-output.png)

## What this example is for

**The thing Python is very good at is not arithmetic.** It is everything that
surrounds a result: axes with sensible ticks, a colour map with a legend, a
norm that makes a sparse histogram readable, two panels sharing an x-axis, and
a PNG at the end. Those are thousands of decisions somebody has already made
well.

`fern/` in this collection writes a PNG **by hand** — 125 lines to put pixels
in a file, with no axes, no ticks, no scale and no legend. That is the right
answer when a bitmap is all you want. This is the other answer, and the two
sit side by side on purpose.

The compute stays in Mojo, and the program measures why. The map is a
**recurrence** — every iterate depends on the one before it — so there is
nothing to vectorise and nothing to hand a GPU. It is simply a lot of
arithmetic that has to happen in order:

```text
  grid   1600 columns x 900 rows
  work   6400000 iterations, each depending on the one before it

  Mojo     23.8 ms  for all 1600 columns
  CPython   8.5 ms  for 24 columns  ->  0.6 s extrapolated
  ratio    20.2 x
```

That comparison runs the **same algorithm** on both sides, histogram write and
logarithm included, so it is not flattered by leaving work out. It is also
measured with `timeit`, which runs the loop in a function scope with the
collector off — CPython's best case, deliberately. On this machine the honest
answer is about 20×, not the 100× a badly-set-up comparison would report.

Twenty times is the whole argument. Half a second is tolerable once and
intolerable in a loop, and the figure is not the part that costs anything.

## How the data crosses

`std.python.numpy` copies a flat Mojo `Span` straight into a real NumPy array:

```mojo
var dens = copy_to_numpy_tensor(density, Coord(H, W))
var lam = copy_to_numpy_array(lyap)
```

The alternative — appending 1.4 million values across the bridge one at a time
— is the slow path, and avoiding it is why that module exists. Its own
docstring names matplotlib as the case it was written for.

## Two details worth stealing

**The colorbar goes on both axes.** A colorbar takes its space from the axes
you give it, so attaching one to the top panel alone makes that panel narrower
than the bottom — and two panels that share an x-axis but do not line up are
worse than no colorbar at all. `ax=[top, bottom]` steals from both and keeps
them aligned.

**`PowerNorm`, not a log norm.** Most buckets in the histogram are empty, and
the log of zero is not a colour.

## First run

matplotlib lives in this project's own Python environment. Once:

1. Python menu → **Create or Repair Environment**
2. Python menu → **Install Project Dependencies**

Then ⌘R. It writes `bifurcation.png` beside the project and opens it.
