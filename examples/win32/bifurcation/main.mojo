# Bifurcation — the logistic map, computed in Mojo and drawn by matplotlib.
#
# The thing Python is very good at is not arithmetic. It is everything that
# surrounds a result: axes with sensible ticks, a colour map with a legend,
# a log-scaled norm, two panels sharing an x-axis, a label in the right place,
# and a PNG at the end. That is thousands of decisions somebody has already
# made well, and reimplementing them is a career rather than an afternoon.
#
# `fern/` in this collection writes a PNG by hand -- 125 lines to put pixels
# in a file, with no axes, no ticks, no scale and no legend. It is the right
# answer when a bitmap is all you want. This example is the other answer.
#
# So the division of labour here is deliberate, and the program measures it:
#
#   * the map itself is a RECURRENCE -- x depends on the x before it -- so it
#     cannot be vectorised away, and 6.4 million iterations of it is real work
#     that Mojo does in milliseconds and CPython does in tens of seconds.
#   * the figure is presentation, and matplotlib has already solved it.
#
# Run it and it prints the ratio it measured on your machine, then writes
# bifurcation.png beside the project and opens it.
#
#     x -> r x (1 - x)
#
# Sweep r from 2.9 to 4.0 and the attractor doubles, doubles again, and falls
# into chaos -- with windows of order inside it. The lower panel is the
# Lyapunov exponent: positive means chaos, and it dips below zero exactly where
# the windows are.

from std.math import log
from std.pathlib import cwd
from std.python import Python
from std.python.numpy import copy_to_numpy_array
from std.time import perf_counter_ns
from std.utils.coord import Coord

comptime W = 1600          # columns: values of r
comptime H = 900           # rows: buckets of x in [0, 1]
comptime R_LO = 2.9
comptime R_HI = 4.0
comptime TRANSIENT = 2000  # iterations discarded so the orbit settles
comptime RECORD = 2000     # iterations plotted and measured
comptime PY_COLS = 24      # columns CPython is asked to do, for the comparison


def one_dp(v: Float64) -> String:
    """One decimal place, because six of them is not a measurement."""
    var scaled = Int(v * 10.0 + 0.5)
    return String(scaled // 10) + String(".") + String(scaled % 10)


def compute(mut density: List[UInt32], mut lyap: List[Float64]):
    """W columns of the logistic map: a density histogram and an exponent.

    This is the part that has to be fast. Every iteration depends on the one
    before it, so there is nothing to vectorise and nothing to hand a GPU --
    it is simply a lot of arithmetic, done in order.
    """
    for col in range(W):
        var r = R_LO + (R_HI - R_LO) * Float64(col) / Float64(W - 1)

        # Let the orbit settle before recording anything, or the plot carries
        # a smear of wherever x happened to start.
        var x = 0.5
        for _ in range(TRANSIENT):
            x = r * x * (1.0 - x)

        var lsum = 0.0
        for _ in range(RECORD):
            x = r * x * (1.0 - x)

            var row = Int(x * Float64(H))
            if row >= 0 and row < H:
                var at = row * W + col
                density[at] = density[at] + UInt32(1)

            # The Lyapunov exponent: the mean log of |dx'/dx|. Positive means
            # nearby orbits separate, which is what chaos is.
            var d = r * (1.0 - 2.0 * x)
            if d < 0.0:
                d = -d
            if d > 1e-12:
                lsum = lsum + log(d)

        lyap[col] = lsum / Float64(RECORD)


def python_seconds(cols: Int) raises -> Float64:
    """The same algorithm, in CPython, timed by `timeit`.

    Sent as source rather than kept in a file beside this one, so the example
    stays a folder with a main.mojo in it. `timeit` takes a statement and a
    setup as strings, which is exactly the shape this needs.
    """
    var timeit = Python.import_module("timeit")
    var nl = String("\n")

    var setup = String("import math") + nl
    setup += String("W = ") + String(W) + nl
    setup += String("H = ") + String(H) + nl
    setup += String("R_LO = 2.9") + nl
    setup += String("R_HI = 4.0") + nl
    setup += String("TRANSIENT = ") + String(TRANSIENT) + nl
    setup += String("RECORD = ") + String(RECORD) + nl
    setup += String("NCOL = ") + String(cols) + nl
    setup += String("dens = [0] * (W * H)") + nl
    setup += String("lyap = [0.0] * W") + nl

    # Deliberately the same work, including the histogram write and the log,
    # so the comparison is not flattered by leaving something out.
    var stmt = String("for col in range(NCOL):") + nl
    stmt += String("    r = R_LO + (R_HI - R_LO) * col / (W - 1)") + nl
    stmt += String("    x = 0.5") + nl
    stmt += String("    for _ in range(TRANSIENT):") + nl
    stmt += String("        x = r * x * (1.0 - x)") + nl
    stmt += String("    s = 0.0") + nl
    stmt += String("    for _ in range(RECORD):") + nl
    stmt += String("        x = r * x * (1.0 - x)") + nl
    stmt += String("        row = int(x * H)") + nl
    stmt += String("        if 0 <= row < H:") + nl
    stmt += String("            dens[row * W + col] += 1") + nl
    stmt += String("        d = abs(r * (1.0 - 2.0 * x))") + nl
    stmt += String("        if d > 1e-12:") + nl
    stmt += String("            s += math.log(d)") + nl
    stmt += String("    lyap[col] = s / RECORD") + nl

    return Float64(py=timeit.timeit(stmt, setup, number=1))


def plot(density: List[UInt32], lyap: List[Float64], path: String) raises:
    """Hand both arrays to matplotlib and let it do what it is good at."""
    # Agg before pyplot: this writes a file and must not need a window.
    var mpl = Python.import_module("matplotlib")
    _ = mpl.use("Agg")
    var plt = Python.import_module("matplotlib.pyplot")
    var mcolors = Python.import_module("matplotlib.colors")

    # std.python.numpy copies a flat Mojo Span into a real NumPy array. The
    # alternative -- appending 1.4 million values across the bridge one at a
    # time -- is the slow path, and this is the reason that module exists.
    #
    # Flat, then reshaped on the NumPy side. The Mac fork has a
    # `copy_to_numpy_tensor` that takes a shape and does both at once; this
    # fork's stdlib has only the 1-D `copy_to_numpy_array`, and `reshape` on
    # a C-order buffer is exactly the same arrangement of exactly the same
    # bytes -- it returns a view, so nothing is copied twice.
    var dens = copy_to_numpy_array(density).reshape(H, W)
    var lam = copy_to_numpy_array(lyap)

    var made = plt.subplots(
        2,
        1,
        figsize=Python.tuple(12.0, 9.0),
        height_ratios=Python.list(3, 1),
        sharex=True,
        layout="constrained",
    )
    var fig = made[0]
    var ax = made[1]
    var top = ax[0]
    var bottom = ax[1]

    var extent = Python.list(R_LO, R_HI, 0.0, 1.0)
    # PowerNorm rather than a log norm: most buckets are empty, and a log of
    # zero is not a colour.
    var im = top.imshow(
        dens,
        extent=extent,
        origin="lower",
        aspect="auto",
        cmap="magma",
        norm=mcolors.PowerNorm(0.35),
        interpolation="nearest",
    )
    _ = top.set_ylabel("x")
    _ = top.set_title(
        "Logistic map: x → r x (1 − x)      "
        + String(W)
        + " × "
        + String(H)
        + ", "
        + String(RECORD)
        + " iterates per column"
    )
    # Against both axes, not just the top one. A colorbar takes its space
    # from the axes it is given, so attaching it to `top` alone makes the top
    # panel narrower than the bottom -- and two panels that share an x-axis
    # but do not line up are worse than no colorbar at all.
    var cb = fig.colorbar(im, ax=Python.list(top, bottom), pad=0.01)
    _ = cb.set_label("visits per bucket")

    _ = bottom.axhline(0.0, color="0.4", linewidth=0.8)
    var rs = Python.import_module("numpy").linspace(R_LO, R_HI, W)
    _ = bottom.fill_between(rs, 0.0, lam, where=lam.__gt__(0.0),
                            color="#C2410C", alpha=0.35, linewidth=0)
    _ = bottom.plot(rs, lam, color="#1F1A16", linewidth=0.7)
    _ = bottom.set_ylim(-2.0, 1.0)
    _ = bottom.set_xlabel("r")
    _ = bottom.set_ylabel("Lyapunov λ")
    _ = bottom.set_title("λ > 0 is chaos; the dips are the windows of order",
                         fontsize=9, loc="left")

    _ = fig.savefig(path, dpi=140)
    _ = plt.close(fig)


def main() raises:
    var steps = W * (TRANSIENT + RECORD)
    print("bifurcation — the logistic map, x -> r x (1 - x)")
    print("  grid  ", W, "columns x", H, "rows")
    print("  work  ", steps, "iterations, each depending on the one before it")
    print()

    var density = List[UInt32](capacity=W * H)
    for _ in range(W * H):
        density.append(0)
    var lyap = List[Float64](capacity=W)
    for _ in range(W):
        lyap.append(0.0)

    var t0 = perf_counter_ns()
    compute(density, lyap)
    var t1 = perf_counter_ns()
    var mojo_ms = Float64(t1 - t0) / 1.0e6
    print("  Mojo    ", one_dp(mojo_ms), "ms  for all", W, "columns")

    # The same algorithm in CPython, on a few columns, extrapolated honestly.
    try:
        var py_s = python_seconds(PY_COLS)
        var py_full_s = py_s * Float64(W) / Float64(PY_COLS)
        print(
            "  CPython ",
            one_dp(py_s * 1000.0),
            "ms  for",
            PY_COLS,
            "columns  ->",
            one_dp(py_full_s),
            "s extrapolated",
        )
        print("  ratio   ", one_dp(py_full_s * 1000.0 / mojo_ms), "x")
    except e:
        print("  CPython  (comparison skipped:", e, ")")

    print()
    var path = String(cwd()) + "\\bifurcation.png"
    try:
        plot(density, lyap, path)
        print("wrote", path)
        # `os.startfile` rather than the Mac's `open`: it is the Windows
        # shell's "do whatever this file's type says", which for a PNG is
        # the image viewer the person has chosen. subprocess with `start`
        # would work too and would need a shell to interpret it.
        var os_module = Python.import_module("os")
        _ = os_module.startfile(path)
    except e:
        print("could not plot:", e)
        print()
        print("matplotlib lives in this project's Python environment:")
        print("  Python menu -> Create or Repair Environment")
        print("  Python menu -> Install Project Dependencies")
