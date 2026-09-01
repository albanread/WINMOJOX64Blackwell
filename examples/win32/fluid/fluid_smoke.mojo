# ===----------------------------------------------------------------------=== #
# The fluid solver, headless and checked.
#
#     mojo build ... -o build/fluid_smoke.exe examples/win32/fluid/fluid_smoke.mojo
#     ./build/fluid_smoke.exe
#
# No window, no GDI, no COM -- just the physics, stepped a fixed number of
# times with diagnostics printed and then asserted. Run this first if the app
# ever looks wrong: from a black window "the physics broke" and "the window
# broke" are indistinguishable, and this is what tells them apart.
#
# Every kernel here comes from `solver.mojo`, which is the same module
# `main.mojo` imports. That is deliberate. A checker that has its own private
# copy of the solver drifts away from the program it is supposed to vouch for,
# and then it is checking something nobody runs.
#
# The four things a broken kernel would break, in order of how quietly they
# fail:
#
#   1. Mass. Dye is advected with a known per-step dissipation, so after n
#      steps the total is predictable to within the interpolation's own
#      diffusion. A splat that lands twice, an advection that samples the
#      wrong cell, a fade applied in the wrong place -- all move this number.
#   2. Divergence. After projection the field must be (nearly) divergence
#      free. If the Jacobi sweep is wrong, or ping-ponged wrongly, or the
#      gradient subtraction has a sign error, this is where it shows.
#   3. Velocity actually being non-zero, which catches a splat that never
#      landed -- the failure that makes everything else look perfect.
#   4. A rendered frame that is not entirely black, which catches the
#      magnification, the tone map and the byte packing. Those only ever fail
#      as a black window, which looks exactly like a dead solver.
# ===----------------------------------------------------------------------=== #

from examples.win32.fluid.png import write_png
from examples.win32.fluid.solver import (
    BLOCK,
    GRID,
    H,
    N,
    PIXELS,
    PIX_GRID,
    W,
    WIN_H,
    WIN_W,
    advect_dye,
    dispatches_per_step,
    divergence_kernel,
    fluid_step,
    render_kernel,
    splat,
)
from max.gpu.host import DeviceContext
from std.memory import Pointer
from std.windows import performance_counter, performance_frequency


comptime STEPS = 60

# Slow enough that the dye never saturates, and a round enough number that the
# predicted total after STEPS steps is worth comparing against.
comptime DISSIPATION = Float32(0.999)

# How far the measured dye total may sit from `DISSIPATION ** STEPS` times the
# seeded total. It is not zero and should not be: semi-Lagrangian advection
# interpolates, and interpolation of a bump loses a little of its peak every
# step. On this machine the gap is under 1%; 3% is a threshold that a real
# defect clears easily and a healthy run never approaches.
comptime MASS_TOLERANCE = 0.03

# After projection the velocity field should be divergence free. It is not
# exactly: thirty Jacobi sweeps is an approximation, deliberately.
comptime DIVERGENCE_LIMIT = Float32(0.05)

comptime F32 = Pointer[Float32, MutAnyOrigin]


def _stats(p: F32, n: Int) -> Tuple[Float32, Float32, Float32]:
    """(min, max, sum) over `n` elements, on the host.

    Takes a plain pointer rather than a buffer so the caller owns the copy --
    naming a device buffer type here buys nothing and ties this to one.
    """
    var lo = Float32(1.0e30)
    var hi = Float32(-1.0e30)
    var total = Float32(0)
    for i in range(n):
        var x = p[unsafe_offset=i]
        if x < lo:
            lo = x
        if x > hi:
            hi = x
        total += x
    return (lo, hi, total)


def main() raises:
    print("Stable Fluids -", W, "x", H, "(", N, "cells )")

    var ctx = DeviceContext(api="cuda")
    print("  GPU:", ctx.name())

    var u = ctx.enqueue_create_buffer[DType.float32](N)
    var v = ctx.enqueue_create_buffer[DType.float32](N)
    var u0 = ctx.enqueue_create_buffer[DType.float32](N)
    var v0 = ctx.enqueue_create_buffer[DType.float32](N)
    var dye = ctx.enqueue_create_buffer[DType.float32](N)
    var scratch = ctx.enqueue_create_buffer[DType.float32](N)
    var div = ctx.enqueue_create_buffer[DType.float32](N)
    var pr = ctx.enqueue_create_buffer[DType.float32](N)
    var pr0 = ctx.enqueue_create_buffer[DType.float32](N)
    var frame = ctx.enqueue_create_buffer[DType.uint32](PIXELS)

    var host = ctx.enqueue_create_host_buffer[DType.float32](N)
    var pixels = ctx.enqueue_create_host_buffer[DType.uint32](PIXELS)
    ctx.synchronize()

    for buf in [u, v, dye, pr]:
        ctx.enqueue_memset(buf, Float32(0))
    ctx.synchronize()

    # A puff of dye and a rightward shove, deliberately off-centre so the
    # blob shears and rolls into a vortex rather than simply translating.
    splat(ctx, dye, Float32(W // 4), Float32(H // 2), Float32(14), Float32(1.0))
    splat(
        ctx, u, Float32(W // 4), Float32(H // 2 - 8), Float32(14), Float32(9.0)
    )
    splat(
        ctx, v, Float32(W // 4), Float32(H // 2 - 8), Float32(14), Float32(3.0)
    )
    ctx.synchronize()

    var host_ptr = host.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    host.enqueue_copy_from(dye)
    ctx.synchronize()
    var seeded = _stats(host_ptr, N)
    print(
        "  seeded dye: min", seeded[0], " max", seeded[1], " sum", seeded[2]
    )

    # ---- the run ---------------------------------------------------------
    var hz = performance_frequency()
    var t0 = performance_counter()
    for _step in range(STEPS):
        # Velocity is not faded here: a decay term would make the mass check
        # below measure the decay rather than the advection.
        fluid_step(ctx, u, v, u0, v0, div, pr, pr0, Float32(1.0))
        advect_dye(ctx, dye, scratch, u, v, DISSIPATION)
        ctx.synchronize()
    var elapsed_us = (performance_counter() - t0) * 1000000 // hz

    # The divergence left in `div` by `fluid_step` is the PRE-projection
    # residual -- the thing the pressure solve was asked to cancel. Ask again,
    # on the corrected field, for the number that actually says whether it
    # worked.
    ctx.enqueue_function[divergence_kernel](
        div, u, v, grid_dim=GRID, block_dim=BLOCK
    )
    ctx.synchronize()

    host.enqueue_copy_from(dye)
    ctx.synchronize()
    var final = _stats(host_ptr, N)
    host.enqueue_copy_from(u)
    ctx.synchronize()
    var vel = _stats(host_ptr, N)
    host.enqueue_copy_from(div)
    ctx.synchronize()
    var residual = _stats(host_ptr, N)

    var per_step_us = elapsed_us // STEPS
    print(
        "  ",
        STEPS,
        "steps in",
        elapsed_us // 1000,
        "ms  (",
        per_step_us,
        "us/step,",
        dispatches_per_step() + 2,
        "dispatches/step )",
    )
    print("  dye:  min", final[0], " max", final[1], " sum", final[2])
    print("  u:    min", vel[0], " max", vel[1])
    print(
        "  div:  min",
        residual[0],
        " max",
        residual[1],
        " (post-projection, should be near zero)",
    )

    # ---- 1. mass ---------------------------------------------------------
    var predicted = seeded[2]
    for _i in range(STEPS):
        predicted *= DISSIPATION
    var drift = Float64(abs(final[2] - predicted)) / Float64(predicted)
    print(
        "  mass: predicted",
        predicted,
        " measured",
        final[2],
        " drift",
        drift * 100.0,
        "%",
    )

    # ---- 2, 3, 4 ---------------------------------------------------------
    # The dye goes into all three colour channels, which makes it grey and
    # exercises exactly the kernel `main.mojo` presents with.
    ctx.enqueue_function[render_kernel](
        frame, dye, dye, dye, grid_dim=PIX_GRID, block_dim=BLOCK
    )
    pixels.enqueue_copy_from(frame)
    ctx.synchronize()

    var nonzero = 0
    var brightest = UInt32(0)
    for i in range(PIXELS):
        var px = pixels[i]
        if (px & UInt32(0xFFFFFF)) != 0:
            nonzero += 1
        if (px & UInt32(0xFF)) > brightest:
            brightest = px & UInt32(0xFF)
    print(
        "  render:",
        WIN_W,
        "x",
        WIN_H,
        "-",
        nonzero,
        "non-black pixels, brightest",
        brightest,
        "of 255",
    )

    var out = String("fluid_frame.png")
    if write_png(
        out,
        pixels.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        WIN_W,
        WIN_H,
    ):
        print("  wrote", out, "- the crescent should be rolled at one end")
    else:
        print("  could not write", out)

    # ---- the assertions --------------------------------------------------
    if final[2] <= Float32(0):
        raise Error("dye vanished entirely - advection or the splat is broken")
    if final[1] > Float32(100):
        raise Error("dye blew up - advection is unstable")
    if vel[0] == Float32(0) and vel[1] == Float32(0):
        raise Error("velocity is identically zero - the splat never landed")
    if drift > MASS_TOLERANCE:
        raise Error(
            "dye mass drifted "
            + String(drift * 100.0)
            + "% from the predicted "
            + String(predicted)
            + " - advection is not conserving"
        )
    if (
        residual[0] < -DIVERGENCE_LIMIT
        or residual[1] > DIVERGENCE_LIMIT
    ):
        raise Error(
            "post-projection divergence is outside +/-"
            + String(DIVERGENCE_LIMIT)
            + " - the pressure solve is wrong"
        )
    if nonzero == 0:
        raise Error("render produced an entirely black frame")

    print("  ok - mass, divergence, velocity and the render all check out")
