# life-python -- Conway's Game of Life, computed in Mojo and drawn by pygame.
#
# Modular's own get-started example, carried onto Windows. The rule lives in
# `gridv1.mojo` -- byte for byte the file the manual ships, unchanged by this
# port -- and everything you can see belongs to pygame, reached through
# `Python.import_module` and the CPython this toolchain carries.
#
# There is no Win32 in this file, and there was no Cocoa in the Mac one. That
# is exactly why it is worth having. Put it beside `life/`, which owns its
# window, decodes its own messages and pushes a BGRA buffer through
# `StretchDIBits`, and the two answer the same question in two different
# worlds. The native one is faster and it is not close -- about nine times per
# cell, measured on this machine at the same compiler flags. Everybody expects
# that, and everybody guesses the wrong reason for it. So this version does
# not assert the gap; it splits it, and puts the split in its own title bar:
#
#     Life (Mojo + pygame) -- gen 65  alive 1751  mojo 16.2 ms  pygame 3.9 ms
#
# `mojo` is one call to `Grid.evolve` over 16,384 cells. `pygame` is one
# `fill`, one `draw.rect` per live cell, and one `flip` -- plus the scan of
# all 16,384 cells that decides which rectangles those are, because that scan
# is ours and pretending otherwise would flatter us. Both are measured on the
# same clock, in the same loop, on the same generation. The sleep upstream puts
# between generations is in neither, because the interesting question is what
# the work costs and not what the pause costs.
#
# Those are real numbers off a real run, and the drawing is the cheap half.
# The expensive half is Mojo's, and specifically it is `Grid`: a
# `List[List[Int]]` rebuilt from scratch every generation, read through two
# levels of bounds-checked indirection, compiled with `--no-optimization`
# because that is what Griddle's Build button passes. Turn the optimiser on --
# which Griddle's Run button does -- and that 16 ms becomes about 1 ms while
# pygame's 4 ms only halves. The README works through why.
#
#     main.exe                 interactive; close the window, or press q / Esc
#     main.exe --ms N          the same, closing itself after N milliseconds
#     main.exe --shot PATH     also write a PNG of the first frame drawn
#     main.exe --size N        an N x N grid instead of 128 x 128
#     main.exe --selftest      three known patterns, then an exact count of
#                              the pixels pygame actually put on its surface
#
# pygame is not part of the toolchain. It lives in this project's own Python
# environment, and the project's `requirements.txt` names it. Once:
#
#     Python menu -> Create or Repair Environment
#     Python menu -> Install Project Dependencies

from std import time
from std.python import Python
from std.sys import argv

from gridv1 import Grid


# ===----------------------------------------------------------------------===#
# Small helpers
# ===----------------------------------------------------------------------===#


def one_dp(v: Float64) -> String:
    """One decimal place, because six of them is not a measurement."""
    var scaled = Int(v * 10.0 + 0.5)
    return String(scaled // 10) + String(".") + String(scaled % 10)


def population(g: Grid) -> Int:
    """How many cells are alive."""
    var alive = 0
    for row in range(g.rows):
        for col in range(g.cols):
            alive += g[row, col]
    return alive


def grid_of(var cells: List[List[Int]]) -> Grid:
    """A grid from a literal, so a check can spell the pattern it means."""
    var rows = len(cells)
    var cols = len(cells[0]) if rows > 0 else 0
    return Grid(rows, cols, cells^)


# ===----------------------------------------------------------------------===#
# The display loop
#
# This is upstream's `run_display`, with three things added and nothing taken
# away: a title bar that reports where the time went, a `--ms` door so an
# unattended run can prove the window opened and closed cleanly, and a
# `--shot` door so it can prove what was in it.
# ===----------------------------------------------------------------------===#


def run_display(
    var grid: Grid,
    window_height: Int = 600,
    window_width: Int = 600,
    background_color: String = "black",
    cell_color: String = "green",
    pause: Float64 = 0.1,
    close_ms: Int = 0,
    shot: String = String(""),
) raises -> None:
    # Import the pygame Python package
    var pygame = Python.import_module("pygame")

    # Initialize pygame modules
    _ = pygame.init()

    # Create a window and set its title
    var window = pygame.display.set_mode(
        Python.tuple(window_width, window_height)
    )
    _ = pygame.display.set_caption("Conway's Game of Life")

    # Which video backend SDL chose, printed rather than assumed. On this
    # machine it is `windows`; a headless or remote session can hand back
    # `dummy`, which draws perfectly into a surface nobody will ever see, and
    # that is a failure worth being able to tell apart from a black window.
    print(
        "pygame",
        pygame.version.ver,
        "SDL",
        pygame.version.SDL,
        "driver",
        pygame.display.get_driver(),
    )
    print("grid", grid.rows, "x", grid.cols, " window", window_width, "x", window_height)

    var cell_height = Float64(window_height) / Float64(grid.rows)
    var cell_width = Float64(window_width) / Float64(grid.cols)
    var border_size = 1
    var cell_fill_color = pygame.Color(cell_color)
    var background_fill_color = pygame.Color(background_color)

    # Everything below this line that is not upstream's is bookkeeping for the
    # title bar. It is deliberately outside the two timed spans.
    var opened_at = time.perf_counter_ns()
    var reported_at = opened_at
    var generation = 0
    var reported_gen = 0
    var mojo_ns = 0
    var pygame_ns = 0
    # The same two totals again, never reset, so the line printed on the way
    # out is a mean over the whole run rather than over the last half second.
    var all_mojo_ns = 0
    var all_pygame_ns = 0

    var running = True
    while running:
        # Poll for events
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                # Quit if the window is closed
                running = False
            elif event.type == pygame.KEYDOWN:
                # Also quit if the user presses <Escape> or 'q'
                if event.key == pygame.K_ESCAPE or event.key == pygame.K_q:
                    running = False

        var drew_at = time.perf_counter_ns()

        # Clear the window by painting with the background color
        _ = window.fill(background_fill_color)

        # Draw each live cell in the grid
        var alive = 0
        for row in range(grid.rows):
            for col in range(grid.cols):
                if grid[row, col]:
                    alive += 1
                    var x = Float64(col) * cell_width + Float64(border_size)
                    var y = Float64(row) * cell_height + Float64(border_size)
                    var width = cell_width - Float64(border_size)
                    var height = cell_height - Float64(border_size)
                    _ = pygame.draw.rect(
                        window,
                        cell_fill_color,
                        Python.tuple(x, y, width, height),
                    )

        # Update the display
        _ = pygame.display.flip()
        var flipped_at = time.perf_counter_ns()
        pygame_ns += flipped_at - drew_at
        all_pygame_ns += flipped_at - drew_at

        # The first frame is the one worth photographing: it is the random
        # start, so a reader can see the grid the seed produced rather than
        # whatever it had decayed into by the time somebody pressed a key.
        if generation == 0 and shot != "":
            _ = pygame.image.save(window, shot)
            print("wrote", shot)

        # Pause to let the user appreciate the scene
        time.sleep(pause)

        # Next generation
        var evolved_from = time.perf_counter_ns()
        grid = grid.evolve()
        var evolve_ns = time.perf_counter_ns() - evolved_from
        mojo_ns += evolve_ns
        all_mojo_ns += evolve_ns
        generation += 1

        # Retitle on its own clock, not the simulation's. `life/` learned this
        # the hard way: statistics recomputed inside the "something changed"
        # branch either flicker four times a second or go stale, and neither
        # is a measurement anybody can read off the glass.
        var now = time.perf_counter_ns()
        if now - reported_at >= 500_000_000:
            var frames = generation - reported_gen
            var window_s = Float64(now - reported_at) / 1.0e9
            var caption = String("Life (Mojo + pygame) -- gen ")
            caption += String(generation)
            caption += String("  alive ") + String(alive)
            caption += String("  mojo ")
            caption += one_dp(Float64(mojo_ns) / 1.0e6 / Float64(frames))
            caption += String(" ms  pygame ")
            caption += one_dp(Float64(pygame_ns) / 1.0e6 / Float64(frames))
            caption += String(" ms  ")
            caption += one_dp(Float64(frames) / window_s)
            caption += String(" gen/s")
            _ = pygame.display.set_caption(caption)
            reported_at = now
            reported_gen = generation
            mojo_ns = 0
            pygame_ns = 0

        # An unattended run needs a way out that is not a keystroke. Checked
        # after a full generation so `--ms 1` still draws one frame rather
        # than none.
        if close_ms > 0:
            var open_ms = Float64(now - opened_at) / 1.0e6
            if open_ms >= Float64(close_ms):
                print(
                    "closing after",
                    one_dp(open_ms),
                    "ms and",
                    generation,
                    "generations",
                )
                running = False

    # What the title bar was saying, once, on the way out -- so an unattended
    # run leaves the same measurement behind that a person reads off the glass.
    if generation > 0:
        var gens = Float64(generation)
        print("generations", generation)
        print(
            "  mojo   ",
            one_dp(Float64(all_mojo_ns) / 1.0e6 / gens),
            "ms per generation  (Grid.evolve over",
            grid.rows * grid.cols,
            "cells)",
        )
        print(
            "  pygame ",
            one_dp(Float64(all_pygame_ns) / 1.0e6 / gens),
            "ms per generation  (scan, fill, draw.rect per live cell, flip)",
        )

    # Shut down pygame cleanly
    _ = pygame.quit()


# ===----------------------------------------------------------------------===#
# Evidence
#
# A window that looked right is not evidence, and neither is an import that
# did not raise. Two checks, in the spirit of `life/` and `ferns/`: the rule
# is exercised on three patterns whose behaviour is known exactly, and then
# pygame's own surface is read back and the lit pixels counted against a
# number worked out in advance.
# ===----------------------------------------------------------------------===#


def check_patterns() -> Int:
    """Returns the number of failures.

    A glider is the strongest cheap check there is: it is periodic in four
    generations AND displaced by one cell diagonally, so a wrong neighbour
    count, a wrong wrap, or an off-by-one in the index all break it, and the
    expected answer is exact rather than approximate.

    These run against `gridv1.Grid` untouched, which is the point -- the file
    the manual ships is the file under test.
    """
    var bad = 0

    # The glider gridv1 itself ships, on its own 8 x 8 torus. Four generations
    # must put the same five cells one row down and one column right; nothing
    # ever comes within two cells of the wrap, so the answer is the flat-plane
    # one and can be written down.
    var g = Grid.glider()
    for _ in range(4):
        g = g.evolve()
    var glider_ok = population(g) == 5
    if not g[1, 2]:
        glider_ok = False
    if not g[2, 3]:
        glider_ok = False
    if not g[3, 1]:
        glider_ok = False
    if not g[3, 2]:
        glider_ok = False
    if not g[3, 3]:
        glider_ok = False
    print("  glider  period 4, displaced (1,1):", "ok" if glider_ok else "FAIL")
    if not glider_ok:
        bad += 1

    # A blinker: horizontal, vertical, horizontal. Centred on a 5 x 5 torus so
    # that no phase of it touches an edge.
    #
    # The annotation is not decoration: a bare list-of-lists literal infers
    # `Array[Array[Int, 5], 5]` in this fork, and `Grid.data` is a
    # `List[List[Int]]`. `gridv1.mojo` needed the same one-word fix.
    var blinker: List[List[Int]] = [
        [0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0],
        [0, 1, 1, 1, 0],
        [0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0],
    ]
    var b = grid_of(blinker^)
    b = b.evolve()
    var blink_ok = (
        population(b) == 3
        and Bool(b[1, 2])
        and Bool(b[2, 2])
        and Bool(b[3, 2])
    )
    b = b.evolve()
    if not (
        population(b) == 3
        and Bool(b[2, 1])
        and Bool(b[2, 2])
        and Bool(b[2, 3])
    ):
        blink_ok = False
    print("  blinker period 2:", "ok" if blink_ok else "FAIL")
    if not blink_ok:
        bad += 1

    # A block, which must not move at all. On a 6 x 6 torus: a 4 x 4 one would
    # wrap the block onto its own neighbours and it would not be still.
    var block: List[List[Int]] = [
        [0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0],
        [0, 0, 1, 1, 0, 0],
        [0, 0, 1, 1, 0, 0],
        [0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0],
    ]
    var s = grid_of(block^)
    for _ in range(8):
        s = s.evolve()
    var block_ok = (
        population(s) == 4
        and Bool(s[2, 2])
        and Bool(s[2, 3])
        and Bool(s[3, 2])
        and Bool(s[3, 3])
    )
    print("  block   still after 8:", "ok" if block_ok else "FAIL")
    if not block_ok:
        bad += 1

    return bad


def check_pixels(
    background_color: String = "black", cell_color: String = "green"
) raises -> Int:
    """Returns the number of failures.

    `life/` copies its window's pixels back out with `BitBlt` and counts them.
    There is no device context to blit here -- the surface belongs to SDL --
    but pygame will answer the same question about itself, and
    `pygame.mask.from_threshold` counts matching pixels in C rather than
    walking 400,000 of them across the language bridge.

    The prediction is exact because the geometry is chosen to be exact. Eight
    cells across a 640-pixel window is 80.0 pixels per cell with nothing left
    over, and a one-pixel border leaves a 79 x 79 block per live cell. Five
    live cells is 5 * 79 * 79 = 31205 lit pixels and not one more, because
    nothing else in the window is that colour.
    """
    var pygame = Python.import_module("pygame")
    _ = pygame.init()

    var side = 640
    var window = pygame.display.set_mode(Python.tuple(side, side))
    _ = pygame.display.set_caption("life-python self-test")

    var g = Grid.glider()
    var cell = Float64(side) / Float64(g.rows)
    var border = 1
    var fill = pygame.Color(cell_color)
    var back = pygame.Color(background_color)

    _ = window.fill(back)
    for row in range(g.rows):
        for col in range(g.cols):
            if g[row, col]:
                _ = pygame.draw.rect(
                    window,
                    fill,
                    Python.tuple(
                        Float64(col) * cell + Float64(border),
                        Float64(row) * cell + Float64(border),
                        cell - Float64(border),
                        cell - Float64(border),
                    ),
                )
    _ = pygame.display.flip()

    # A threshold of 1 per channel means "this exact colour", not "greenish".
    var mask = pygame.mask.from_threshold(
        window, fill, Python.tuple(1, 1, 1, 255)
    )
    var lit = Int(py=mask.count())

    var alive = population(g)
    var side_px = Int(cell) - border
    var predicted = alive * side_px * side_px

    print("readback: window", side, "x", side, " cell", one_dp(cell), "px")
    print("   live cells", alive, " lit pixels", lit, " predicted", predicted)
    print("   the geometry is exact, so those two must agree exactly")

    _ = pygame.quit()

    if lit != predicted:
        print("  pixel readback: FAIL")
        return 1
    print("  pixel readback: ok")
    return 0


# ===----------------------------------------------------------------------===#
# Entry point
# ===----------------------------------------------------------------------===#


def main() raises:
    var selftest = False
    var close_ms = 0
    var shot = String("")
    var rows = 128
    var cols = 128
    var args = argv()
    for i in range(len(args)):
        if args[i] == "--selftest":
            selftest = True
        if args[i] == "--ms" and i + 1 < len(args):
            close_ms = Int(args[i + 1])
        if args[i] == "--shot" and i + 1 < len(args):
            shot = String(args[i + 1])
        if args[i] == "--size" and i + 1 < len(args):
            rows = Int(args[i + 1])
            cols = rows

    if selftest:
        print("pattern checks:")
        var bad = check_patterns()
        try:
            bad += check_pixels()
        except e:
            print("  pixel readback: could not run:", e)
            bad += 1
        if bad == 0:
            print("all checks passed")
        else:
            print(bad, "check(s) FAILED")
        return

    var start = Grid.random(rows, cols)
    try:
        run_display(start^, close_ms=close_ms, shot=shot)
    except e:
        # The one failure worth explaining rather than re-raising. pygame is
        # not part of the toolchain and a fresh checkout does not have it, so
        # the first run of this example on any machine is the run that fails
        # here -- and "No module named 'pygame'" out of a compiled binary
        # tells nobody which of two menu items to click.
        print("could not run:", e)
        print()
        print("pygame lives in this project's Python environment:")
        print("  Python menu -> Create or Repair Environment")
        print("  Python menu -> Install Project Dependencies")
