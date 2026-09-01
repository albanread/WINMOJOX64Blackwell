# ===----------------------------------------------------------------------=== #
# Stable Fluids (Jos Stam, SIGGRAPH 1999) -- the physics, and nothing else.
#
# Every kernel here is Mojo compiled to PTX and run on the NVIDIA GPU through
# the CUDA driver. There is no shader anywhere in the pipeline: `main.mojo`
# takes the BGRA words this file's render kernel produces and hands them
# straight to GDI.
#
# This module exists so that the window and the headless checker run the SAME
# code. `fluid_smoke.mojo` imports `fluid_step` and every kernel below and
# asserts things about their output; if those assertions pass, a black window
# is a window bug, not a physics bug. Two copies of the solver -- which is what
# the macOS original has -- can drift, and then the smoke test is checking
# something the app no longer runs.
#
# The physics in one paragraph: velocity is advected along itself by tracing
# each cell backwards through the field and sampling where it came from, which
# is unconditionally stable at any time step and is the whole reason Stam's
# method is used rather than a forward difference. The advected field is not
# divergence-free, so a Poisson equation is solved for pressure (Jacobi,
# ping-ponged between two buffers) and its gradient subtracted. Dye is passive:
# it rides the corrected velocity and does not affect it.
# ===----------------------------------------------------------------------=== #

from max.gpu.host import DeviceBuffer, DeviceContext
from std.gpu import global_idx
from std.memory import Pointer


# The simulation grid, and the window it is magnified into. The sim is coarser
# than the display on purpose: the pressure solve is the expensive part and
# scales with cell count, while the eye is perfectly happy with a bilinear
# magnification of a smooth field.
comptime W = 320
comptime H = 240
comptime N = W * H
comptime SCALE = 3
comptime WIN_W = W * SCALE  # 960
comptime WIN_H = H * SCALE  # 720
comptime PIXELS = WIN_W * WIN_H

comptime DT = Float32(0.125)
comptime JACOBI_ITERS = 30
comptime DYE_FADE = Float32(0.997)
comptime VEL_FADE = Float32(0.995)

comptime BLOCK = 256
comptime GRID = (N + BLOCK - 1) // BLOCK
comptime PIX_GRID = (PIXELS + BLOCK - 1) // BLOCK

comptime F32 = Pointer[Float32, MutAnyOrigin]
comptime U32 = Pointer[UInt32, MutAnyOrigin]

comptime Buf = DeviceBuffer[DType.float32]
comptime PixBuf = DeviceBuffer[DType.uint32]


# ===----------------------------------------------------------------------=== #
# Sampling. The boundary rule is stated once, here: clamp, which lets fluid
# slide along a wall rather than leak through it. That is free-slip, and it is
# all this demo needs.
# ===----------------------------------------------------------------------=== #


@always_inline
def _clampi(v: Int, lo: Int, hi: Int) -> Int:
    if v < lo:
        return lo
    if v > hi:
        return hi
    return v


@always_inline
def _at(f: F32, x: Int, y: Int) -> Float32:
    return f[unsafe_offset = _clampi(y, 0, H - 1) * W + _clampi(x, 0, W - 1)]


@always_inline
def _bilinear(f: F32, x: Float32, y: Float32) -> Float32:
    """Sample `f` at a fractional position, clamped at the edges."""
    var x0 = Int(x)
    var y0 = Int(y)
    # Int() truncates towards zero, so a negative coordinate would round the
    # wrong way and the fraction below would come out negative.
    if x < Float32(0):
        x0 = Int(x) - 1
    if y < Float32(0):
        y0 = Int(y) - 1
    var fx = x - Float32(x0)
    var fy = y - Float32(y0)
    var a = _at(f, x0, y0)
    var b = _at(f, x0 + 1, y0)
    var c = _at(f, x0, y0 + 1)
    var d = _at(f, x0 + 1, y0 + 1)
    var top = a + (b - a) * fx
    var bot = c + (d - c) * fx
    return top + (bot - top) * fy


@always_inline
def _expf(x: Float32) -> Float32:
    """exp, written out so host and device share one definition.

    Only ever called with x in [-9, 0] (the splat falloff), so the range
    reduction below does not need to be general.
    """
    if x < Float32(-20.0):
        return Float32(0)
    var k = x * Float32(1.44269504)  # 1/ln 2
    var ki = Float32(Int(k) - (1 if k < Float32(0) else 0))
    var f = (k - ki) * Float32(0.69314718)
    var poly = Float32(1) + f * (
        Float32(1)
        + f
        * (Float32(0.5) + f * (Float32(0.16666667) + f * Float32(0.04166667)))
    )
    var n = Int(ki)
    var scale = Float32(1)
    var i = 0
    while i < -n:
        scale *= Float32(0.5)
        i += 1
    return poly * scale


# ===----------------------------------------------------------------------=== #
# Kernels
# ===----------------------------------------------------------------------=== #


def advect_kernel(
    dst: F32, src: F32, u: F32, v: F32, dt: Float32, fade: Float32
):
    """Semi-Lagrangian advection: trace backwards, sample where it came from.

    Unconditionally stable whatever the time step, which is the whole reason
    Stam's method is used here rather than a forward difference.
    """
    var idx = Int(global_idx.x)
    if idx < N:
        var px = Float32(idx % W) - dt * u[unsafe_offset=idx]
        var py = Float32(idx // W) - dt * v[unsafe_offset=idx]
        dst[unsafe_offset=idx] = _bilinear(src, px, py) * fade


def divergence_kernel(div: F32, u: F32, v: F32):
    """How much is flowing out of each cell -- what the pressure must cancel."""
    var idx = Int(global_idx.x)
    if idx < N:
        var x = idx % W
        var y = idx // W
        div[unsafe_offset=idx] = Float32(0.5) * (
            (_at(u, x + 1, y) - _at(u, x - 1, y))
            + (_at(v, x, y + 1) - _at(v, x, y - 1))
        )


def jacobi_kernel(p_next: F32, p: F32, div: F32):
    """One Jacobi sweep of the pressure Poisson equation.

    Ping-ponged rather than updated in place: a Jacobi step reads the previous
    iterate's whole neighbourhood, and writing in place would feed half-new
    values back in, silently turning this into Gauss-Seidel with a
    thread-order-dependent answer -- which on a GPU means a result that changes
    with occupancy.
    """
    var idx = Int(global_idx.x)
    if idx < N:
        var x = idx % W
        var y = idx // W
        var s = (
            _at(p, x - 1, y)
            + _at(p, x + 1, y)
            + _at(p, x, y - 1)
            + _at(p, x, y + 1)
        )
        p_next[unsafe_offset=idx] = (s - div[unsafe_offset=idx]) * Float32(0.25)


def project_kernel(u: F32, v: F32, p: F32):
    """Subtract the pressure gradient, leaving a divergence-free field."""
    var idx = Int(global_idx.x)
    if idx < N:
        var x = idx % W
        var y = idx // W
        u[unsafe_offset=idx] -= Float32(0.5) * (
            _at(p, x + 1, y) - _at(p, x - 1, y)
        )
        v[unsafe_offset=idx] -= Float32(0.5) * (
            _at(p, x, y + 1) - _at(p, x, y - 1)
        )


def splat_kernel(
    field: F32, cx: Float32, cy: Float32, radius: Float32, amount: Float32
):
    """Add a soft Gaussian blob: the mouse, or a starting puff."""
    var idx = Int(global_idx.x)
    if idx < N:
        var dx = Float32(idx % W) - cx
        var dy = Float32(idx // W) - cy
        var r2 = radius * radius
        var d2 = dx * dx + dy * dy
        if d2 < r2 * Float32(9.0):
            field[unsafe_offset=idx] += amount * _expf(-d2 / r2)


def render_kernel(dst: U32, dr: F32, dg: F32, db: F32):
    """Magnify the dye field into the window, as packed BGRA8.

    Bilinear rather than nearest: the field is smooth, and point-sampling a
    320x240 grid into 960x720 would show the simulation's cells rather than the
    fluid. Tone-mapped with x/(1+x) so a heavy drag saturates gracefully
    instead of clipping to white.

    The packing is the one place this differs from nothing at all on Windows:
    a 32-bit BI_RGB DIB is 0xAARRGGBB little-endian, i.e. B, G, R, A in
    ascending byte order -- exactly the layout Metal calls BGRA8Unorm, so the
    macOS kernel needed no change.
    """
    var idx = Int(global_idx.x)
    if idx < PIXELS:
        var sx = Float32(idx % WIN_W) / Float32(SCALE)
        var sy = Float32(idx // WIN_W) / Float32(SCALE)
        var r = _bilinear(dr, sx, sy)
        var g = _bilinear(dg, sx, sy)
        var b = _bilinear(db, sx, sy)
        r = r / (Float32(1) + r)
        g = g / (Float32(1) + g)
        b = b / (Float32(1) + b)
        var ri = UInt32(Int(r * Float32(255.0)))
        var gi = UInt32(Int(g * Float32(255.0)))
        var bi = UInt32(Int(b * Float32(255.0)))
        dst[unsafe_offset=idx] = (
            bi | (gi << 8) | (ri << 16) | (UInt32(255) << 24)
        )


# ===----------------------------------------------------------------------=== #
# The step, on the host. ~35 dependent dispatches, which is the reason this
# demo exists as a measurement and not only as a picture: mandelbrot is one
# dispatch per frame, so it says nothing at all about launch cost.
# ===----------------------------------------------------------------------=== #


def splat(
    ctx: DeviceContext,
    field: Buf,
    cx: Float32,
    cy: Float32,
    radius: Float32,
    amount: Float32,
) raises:
    """One Gaussian blob into one field."""
    ctx.enqueue_function[splat_kernel](
        field, cx, cy, radius, amount, grid_dim=GRID, block_dim=BLOCK
    )


def fluid_step(
    ctx: DeviceContext,
    u: Buf,
    v: Buf,
    u0: Buf,
    v0: Buf,
    div: Buf,
    pr: Buf,
    pr0: Buf,
    vel_fade: Float32,
) raises:
    """Advect the velocity along itself, then make it divergence-free.

    On return `u` and `v` hold the corrected field and `div` holds the
    divergence that was cancelled -- the pre-projection residual, not the
    post-projection one. Ask for the latter by running `divergence_kernel`
    again afterwards, which is what the smoke test does.

    Args:
        ctx: The device the buffers live on.
        u: Horizontal velocity, in and out.
        v: Vertical velocity, in and out.
        u0: Scratch the width of `u`.
        v0: Scratch the width of `v`.
        div: Scratch for the divergence.
        pr: Pressure, ping.
        pr0: Pressure, pong.
        vel_fade: Per-step velocity decay; 1.0 for no decay.

    Raises:
        If any dispatch is rejected.
    """
    ctx.enqueue_function[advect_kernel](
        u0, u, u, v, DT, vel_fade, grid_dim=GRID, block_dim=BLOCK
    )
    ctx.enqueue_function[advect_kernel](
        v0, v, u, v, DT, vel_fade, grid_dim=GRID, block_dim=BLOCK
    )
    ctx.enqueue_function[divergence_kernel](
        div, u0, v0, grid_dim=GRID, block_dim=BLOCK
    )
    ctx.enqueue_memset(pr, Float32(0))
    for _it in range(JACOBI_ITERS // 2):
        ctx.enqueue_function[jacobi_kernel](
            pr0, pr, div, grid_dim=GRID, block_dim=BLOCK
        )
        ctx.enqueue_function[jacobi_kernel](
            pr, pr0, div, grid_dim=GRID, block_dim=BLOCK
        )
    ctx.enqueue_function[project_kernel](
        u0, v0, pr, grid_dim=GRID, block_dim=BLOCK
    )
    ctx.enqueue_copy(u, u0)
    ctx.enqueue_copy(v, v0)


def advect_dye(
    ctx: DeviceContext, dye: Buf, scratch: Buf, u: Buf, v: Buf, fade: Float32
) raises:
    """Carry one passive channel on the corrected velocity field.

    Advection cannot be done in place -- a cell's new value is sampled from
    four neighbours of the old field -- so it goes through `scratch` and is
    copied back. One scratch buffer serves all three colour channels, which
    keeps the buffer count down.
    """
    ctx.enqueue_function[advect_kernel](
        scratch, dye, u, v, DT, fade, grid_dim=GRID, block_dim=BLOCK
    )
    ctx.enqueue_copy(dye, scratch)


def dispatches_per_step() -> Int:
    """How many kernel launches one call to `fluid_step` costs.

    Two advections, one divergence, one memset, `JACOBI_ITERS` sweeps, one
    projection, two copies. Counted rather than guessed because the whole
    argument for this demo is a per-dispatch cost multiplied by this number.
    """
    return 2 + 1 + 1 + JACOBI_ITERS + 1 + 2


# ===----------------------------------------------------------------------=== #
# Host-side colour: a hue that advances with every drag, so a session paints
# through the spectrum instead of one muddy colour.
# ===----------------------------------------------------------------------=== #


def hue_rgb(h: Float32) -> Tuple[Float32, Float32, Float32]:
    """A saturated colour for a hue in [0, 1), wrapping."""
    var x = h - Float32(Int(h))  # fract
    var s = x * Float32(6.0)
    var i = Int(s)
    var f = s - Float32(i)
    if i == 0:
        return (Float32(1), f, Float32(0))
    if i == 1:
        return (Float32(1) - f, Float32(1), Float32(0))
    if i == 2:
        return (Float32(0), Float32(1), f)
    if i == 3:
        return (Float32(0), Float32(1) - f, Float32(1))
    if i == 4:
        return (f, Float32(0), Float32(1))
    return (Float32(1), Float32(0), Float32(1) - f)
