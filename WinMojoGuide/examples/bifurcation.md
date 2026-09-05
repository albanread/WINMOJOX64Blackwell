# bifurcation — six million iterations, and a Python you can measure against

The logistic map `x → r·x·(1−x)`, r swept from 2.9 to 4.0: 1,600 columns ×
900 rows, 6.4 million sequential iterations on the **CPU** — deliberately,
says the README: nothing to vectorise, nothing to hand a GPU. The output is
a PNG with two panels: the attractor's density (the classic bifurcation
figure, magma-coloured), and the Lyapunov exponent beneath it — *λ > 0 is
chaos; the dips are the windows of order*.

## Run it

From Griddle: Python menu → Create or Repair Environment, then Install
Project Dependencies (this one has a `requirements.txt`: matplotlib), then
Run. Or `mojo run main.mojo` from the folder. It prints the Mojo-vs-CPython
timing (CPython is extrapolated from a `timeit`'d sample; expect ~20×) and
opens `bifurcation.png` via `os.startfile`.

## The walkthrough

**The compute is pure Mojo** (main.mojo:59): the recurrence with a transient
burn-in, a density histogram per r, and a Lyapunov accumulation from the
same iterations. One buffer, one loop, no platform anything — the point of
the sample is the *other* half.

**The Python half is embedding, and it is bidirectional.** The same
algorithm is sent to CPython *as source text* and timed with `timeit`
(main.mojo:88) — that is the measurement the ratio line reports. The
results cross into Python with `copy_to_numpy_array(density).reshape(H, W)`
(main.mojo:147) — note in the source that this fork's stdlib has only the
1-D spelling (the README still shows the Mac fork's `copy_to_numpy_tensor`;
the source comment is right). matplotlib is then driven from Mojo like any
library: `mpl.use("Agg")`, `subplots`, `imshow`, `colorbar`, `savefig`
(main.mojo:130–204).

## What it teaches

- `std.python` loads libpython **into the Mojo process** — `Python.import_module`
  returns live objects, `Python.tuple(...)` converts arguments, and a Mojo
  array becomes a NumPy array without a copy across a process boundary.
- A program can be mostly Mojo with Python as its plotting library, and the
  boundary cost is measurable rather than folklore: the console line is the
  measurement.
- Plotting failing is an environment problem, and the program says so with
  the two menu steps that fix it.
