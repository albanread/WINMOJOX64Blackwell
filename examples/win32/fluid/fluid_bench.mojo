# ===----------------------------------------------------------------------=== #
# The fluid solver, headless, MEASURED.
#
#     mojo build -I mojo/stdlib -I . -I max/mojo \
#         -Xlinker "<repo>\bazel-bin\nvptx\runtime\nvptxrt.lib" \
#         -o build/fluid_bench.exe examples/win32/fluid/fluid_bench.mojo
#     ./build/fluid_bench.exe
#
# fluid_smoke.mojo answers "is the physics right"; this answers "where does
# the time go". A fluids frame is 44 dependent dispatches, so the interesting
# split is not GPU work versus everything else but launch cost versus GPU
# work -- and the two cures for launch cost, submitting without
# synchronising and replaying a recorded device graph, are different cures
# with different ceilings. Both are measured here against the same kernels,
# the same buffers, the same physics, so the numbers can be subtracted from
# each other and the difference MEANS something:
#
#   classic, synced      what main.mojo does today: enqueue a frame, wait
#                        for it, present. The per-dispatch cost is on the
#                        critical path, once per dispatch.
#   classic, one sync    the whole run submitted, one wait at the end. The
#                        GPU runs dispatches back to back; whatever this
#                        saves is pure submission overhead that was
#                        serialising the pipeline.
#   graph replay         the same 44 dispatches recorded once and replayed.
#                        The per-dispatch cost is paid once at record time;
#                        a replay is one launch.
#
# The frame graph records the pressure clear and the copies as KERNELS
# rather than memcpy/memset nodes. That kept the dispatch count at exactly
# 44 when the recording surface still executed copies and memsets eagerly
# instead of recording them -- the defect the probe below caught, since
# fixed in nvptxrt -- and it still keeps the stage lattice kernels-only,
# which is what isolates the replay fault the staged graph exists to
# reproduce: the frame faults in the clamped solve kernels long before a
# copy node would run, and mixing node kinds would blur which cell faults.
# ===----------------------------------------------------------------------=== #

from solver import (
    BLOCK,
    _at,
    DYE_FADE,
    DT,
    GRID,
    H,
    JACOBI_ITERS,
    N,
    PIXELS,
    PIX_GRID,
    VEL_FADE,
    W,
    WIN_W,
    WIN_H,
    advect_dye,
    advect_kernel,
    divergence_kernel,
    fluid_step,
    jacobi_kernel,
    project_kernel,
    render_kernel,
    splat,
)
from max.gpu.host import (
    DeviceBuffer,
    DeviceContext,
    DeviceGraph,
    DeviceGraphBuilder,
    HostBuffer,
)
from std.gpu import global_idx
from std.memory import Pointer
from std.windows import (
    get_environment,
    performance_counter,
    performance_frequency,
)


comptime STEPS = 200
comptime WARMUP = 16
comptime TRIVIAL_K = 2000
comptime FRAME_DISPATCHES = 2 + 1 + 1 + JACOBI_ITERS + 1 + 2 + 3 * 2 + 1

comptime F32 = Pointer[Float32, MutAnyOrigin]
comptime BUF = DeviceBuffer[DType.float32]


def tick_kernel(dst: F32, val: Float32):
    """The cheapest kernel that still writes: one thread, one word.

    Two arguments on purpose: the frame graph failed where a one-argument
    graph succeeded, and the difference between them is under test. The
    write keeps the launch honest -- a launch the driver could fold away
    would measure the driver's optimiser, not the dispatch path.
    """
    if Int(global_idx.x) == 0:
        dst[unsafe_offset=0] = val


def copy_kernel(dst: F32, src: F32):
    """dst[i] = src[i], as a kernel so it records and orders like any other."""
    var idx = Int(global_idx.x)
    if idx < N:
        dst[unsafe_offset=idx] = src[unsafe_offset=idx]


def zero_kernel(dst: F32):
    """dst[i] = 0 -- the graph-mode stand-in for the step's memset."""
    var idx = Int(global_idx.x)
    if idx < N:
        dst[unsafe_offset=idx] = Float32(0)


def tri_kernel(a: F32, b: F32, c: F32):
    """Three pointer arguments, one node -- isolates the argument count from
    the module a kernel comes from."""
    if Int(global_idx.x) == 0:
        a[unsafe_offset=0] = b[unsafe_offset=0] + c[unsafe_offset=0]


@always_inline
def _bench_clampi(v: Int, lo: Int, hi: Int) -> Int:
    if v < lo:
        return lo
    if v > hi:
        return hi
    return v


@always_inline
def _bench_at(f: F32, x: Int, y: Int) -> Float32:
    return f[
        unsafe_offset = _bench_clampi(y, 0, H - 1) * W
        + _bench_clampi(x, 0, W - 1)
    ]


def local_at_divergence(div: F32, u: F32, v: F32):
    """The divergence body with EVERY helper local: nothing crosses a
    module boundary at all."""
    var idx = Int(global_idx.x)
    if idx < N:
        var x = idx % W
        var y = idx // W
        div[unsafe_offset=idx] = Float32(0.5) * (
            (_bench_at(u, x + 1, y) - _bench_at(u, x - 1, y))
            + (_bench_at(v, x, y + 1) - _bench_at(v, x, y - 1))
        )


def mul_kernel(a: F32, b: F32):
    """A float multiply and nothing else."""
    var idx = Int(global_idx.x)
    if idx < N:
        a[unsafe_offset=idx] = Float32(0.5) * b[unsafe_offset=idx]


def sub_kernel(a: F32, b: F32, c: F32):
    """A float subtract and nothing else."""
    var idx = Int(global_idx.x)
    if idx < N:
        a[unsafe_offset=idx] = b[unsafe_offset=idx] - c[unsafe_offset=idx]


def neighbor_kernel(a: F32, b: F32):
    """Neighbour loads without the imported helper, without div/mod."""
    var idx = Int(global_idx.x)
    if idx > 0 and idx < N - 1:
        a[unsafe_offset=idx] = (
            b[unsafe_offset=idx - 1] + b[unsafe_offset=idx + 1]
        )


def divmod_kernel(a: F32, b: F32):
    """The x/y decode the solver kernels do, and nothing else."""
    var idx = Int(global_idx.x)
    if idx < N:
        var x = idx % W
        var y = idx // W
        a[unsafe_offset=idx] = b[unsafe_offset=y * W + x]


def tri_idx_kernel(a: F32):
    """The barest per-thread indexed write there is: a[idx] = 1."""
    var idx = Int(global_idx.x)
    if idx < N:
        a[unsafe_offset=idx] = Float32(1)


def tri_n_kernel(a: F32, b: F32, c: F32):
    """tri_kernel plus ONE reference to an imported comptime constant (N).
    If this is what breaks the graph node, the trigger is the hidden
    argument such a reference can become, not the code around it."""
    var idx = Int(global_idx.x)
    if idx < N:
        a[unsafe_offset=0] = b[unsafe_offset=0] + c[unsafe_offset=0]


def local_divergence_kernel(div: F32, u: F32, v: F32):
    """divergence_kernel's body, defined in THIS module: same code, same
    helper calls, same argument shape -- only the module the kernel is
    compiled into differs."""
    var idx = Int(global_idx.x)
    if idx < N:
        var x = idx % W
        var y = idx // W
        div[unsafe_offset=idx] = Float32(0.5) * (
            (_at(u, x + 1, y) - _at(u, x - 1, y))
            + (_at(v, x, y + 1) - _at(v, x, y - 1))
        )


def now_us() raises -> Int:
    var hz = performance_frequency()
    return Int((performance_counter() * 1000000) // hz)


def seed_the_scene(
    ctx: DeviceContext,
    u: BUF,
    v: BUF,
    dr: BUF,
    dg: BUF,
    db: BUF,
) raises:
    """One puff and one shove, identical for every mode, so the modes share
    an initial condition down to the bit."""
    for buf in [u, v, dr, dg, db]:
        ctx.enqueue_memset(buf, Float32(0))
    splat(ctx, dr, Float32(W // 4), Float32(H // 2), Float32(14), Float32(1.0))
    splat(ctx, dg, Float32(W // 4), Float32(H // 2), Float32(14), Float32(0.8))
    splat(ctx, db, Float32(W // 4), Float32(H // 2), Float32(14), Float32(0.6))
    splat(
        ctx, u, Float32(W // 4), Float32(H // 2 - 8), Float32(14), Float32(9.0)
    )
    splat(
        ctx, v, Float32(W // 4), Float32(H // 2 - 8), Float32(14), Float32(3.0)
    )
    ctx.synchronize()


def dye_sum(ctx: DeviceContext, host: HostBuffer[DType.float32],
            dye: BUF) raises -> Float32:
    """The total dye, read back.

    Every mode must agree on it to the bit: they run the same kernels in the
    same order on the same data, and none of those kernels uses atomics. A
    divergence means a dependency is missing somewhere, not rounding.
    """
    host.enqueue_copy_from(dye)
    ctx.synchronize()
    var p = host.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    var total = Float32(0)
    for i in range(N):
        total += p[unsafe_offset=i]
    return total


def run_classic(
    ctx: DeviceContext,
    u: BUF,
    v: BUF,
    u0: BUF,
    v0: BUF,
    div: BUF,
    pr: BUF,
    pr0: BUF,
    dr: BUF,
    dg: BUF,
    db: BUF,
    scratch: BUF,
    sync_each_step: Bool,
) raises:
    """STEPS frames the way main.mojo enqueues them, minus the render."""
    for _step in range(STEPS):
        fluid_step(ctx, u, v, u0, v0, div, pr, pr0, VEL_FADE)
        advect_dye(ctx, dr, scratch, u, v, DYE_FADE)
        advect_dye(ctx, dg, scratch, u, v, DYE_FADE)
        advect_dye(ctx, db, scratch, u, v, DYE_FADE)
        if sync_each_step:
            ctx.synchronize()
    ctx.synchronize()


def _env_int(name: StringSlice, fallback: Int) raises -> Int:
    """A small integer out of the environment, as main.mojo reads it --
    through std.windows, which is GetEnvironmentVariableW. A leading minus
    is allowed: the stage knob uses negative values for extra probes."""
    var text = get_environment(name)
    if text.byte_length() == 0:
        return fallback
    var negative = False
    var start = 0
    var bytes = text.as_bytes()
    if bytes[0] == UInt8(ord("-")):
        negative = True
        start = 1
    var value = 0
    for i in range(start, len(bytes)):
        var ch = Int(bytes[i])
        if ch < 48 or ch > 57:
            return fallback
        value = value * 10 + (ch - 48)
    return -value if negative else value


def build_frame_graph(
    ctx: DeviceContext,
    u: BUF,
    v: BUF,
    u0: BUF,
    v0: BUF,
    dr: BUF,
    dg: BUF,
    db: BUF,
    scratch: BUF,
    div: BUF,
    pr: BUF,
    pr0: BUF,
    frame: DeviceBuffer[DType.uint32],
    stages: Int,
) raises -> DeviceGraph:
    """One whole frame -- solver step, three dye channels, render -- as a
    graph, recorded through the recording context so the dependency chain is
    simply the order of the code.

    The sequence mirrors fluid_step + three advect_dye + render exactly,
    dispatch for dispatch, with enqueue_memset(pr) as zero_kernel and the
    enqueue_copy calls as copy_kernel.

    `stages` truncates the recording for bisection: 1 advects+divergence,
    2 +pressure solve, 3 +projection and copies, 4 +dye, 5 +render. The
    default of 5 is the whole frame.
    """

    def build(mut builder: DeviceGraphBuilder) raises {imm}:
        with builder.recording_context() as rctx:
            if stages == 0:
                # Bisection floor: the LOCAL tick kernel against a SOLVER
                # buffer, one node, the tick graph's shape -- separates the
                # kernel from the buffer from the shape.
                rctx.enqueue_function[tick_kernel](
                    u0, Float32(1), grid_dim=1, block_dim=32
                )
                return
            if stages == -1:
                # Three pointer arguments from THIS module: if this fails
                # where the two-argument tick succeeds, the count or the
                # all-pointer shape is the trigger; if it survives, the
                # problem is specific to kernels imported from solver.mojo.
                rctx.enqueue_function[tri_kernel](
                    u0, u0, v0, grid_dim=1, block_dim=32
                )
                return
            if stages == -2:
                # One solver-module kernel, still one node, for the
                # skip-classic ordering experiment.
                rctx.enqueue_function[divergence_kernel](
                    div, u0, v0, grid_dim=1, block_dim=32
                )
                return
            if stages == -11:
                rctx.enqueue_function[mul_kernel](
                    u0, v0, grid_dim=1, block_dim=32
                )
                return
            if stages == -12:
                rctx.enqueue_function[sub_kernel](
                    u0, v0, u0, grid_dim=1, block_dim=32
                )
                return
            if stages == -10:
                rctx.enqueue_function[local_at_divergence](
                    div, u0, v0, grid_dim=1, block_dim=32
                )
                return
            if stages == -8:
                rctx.enqueue_function[neighbor_kernel](
                    u0, v0, grid_dim=1, block_dim=32
                )
                return
            if stages == -9:
                rctx.enqueue_function[divmod_kernel](
                    u0, v0, grid_dim=1, block_dim=32
                )
                return
            if stages == -7:
                # The barest per-thread indexed write. Splits "any indexed
                # access faults in a node" from "something in the
                # divergence body specifically".
                rctx.enqueue_function[tri_idx_kernel](
                    u0, grid_dim=1, block_dim=32
                )
                return
            if stages == -6:
                # One thread, in-bounds by construction: if a single-thread
                # replay of the guarded, clamped kernel still faults, the
                # fault is not in what the threads do.
                rctx.enqueue_function[divergence_kernel](
                    div, u0, v0, grid_dim=1, block_dim=1
                )
                return
            if stages == -5:
                # tri plus one comptime-constant reference: the hidden-
                # argument experiment.
                rctx.enqueue_function[tri_n_kernel](
                    u0, u0, v0, grid_dim=1, block_dim=32
                )
                return
            if stages == -4:
                # The same BODY as divergence_kernel, defined locally. If
                # this replays, the fault follows the MODULE the kernel was
                # compiled into, not its code.
                rctx.enqueue_function[local_divergence_kernel](
                    div, u0, v0, grid_dim=1, block_dim=32
                )
                return
            if stages == -3:
                # The same solver kernel through the EXPLICIT node API
                # rather than the recording context. If this replays where
                # the recorded node faults, the recording path is the
                # culprit and explicit nodes are the workaround; if it
                # faults too, node creation itself is broken for these
                # kernels.
                var f = ctx.compile_function[divergence_kernel]()
                builder.add_function(
                    f, div, u0, v0, grid_dim=1, block_dim=32
                )
                return
            rctx.enqueue_function[advect_kernel](
                u0, u, u, v, DT, VEL_FADE, grid_dim=GRID, block_dim=BLOCK
            )
            rctx.enqueue_function[advect_kernel](
                v0, v, u, v, DT, VEL_FADE, grid_dim=GRID, block_dim=BLOCK
            )
            rctx.enqueue_function[divergence_kernel](
                div, u0, v0, grid_dim=GRID, block_dim=BLOCK
            )
            if stages < 2:
                return
            rctx.enqueue_function[zero_kernel](
                pr, grid_dim=GRID, block_dim=BLOCK
            )
            for _it in range(JACOBI_ITERS // 2):
                rctx.enqueue_function[jacobi_kernel](
                    pr0, pr, div, grid_dim=GRID, block_dim=BLOCK
                )
                rctx.enqueue_function[jacobi_kernel](
                    pr, pr0, div, grid_dim=GRID, block_dim=BLOCK
                )
            if stages < 3:
                return
            rctx.enqueue_function[project_kernel](
                u0, v0, pr, grid_dim=GRID, block_dim=BLOCK
            )
            rctx.enqueue_function[copy_kernel](
                u, u0, grid_dim=GRID, block_dim=BLOCK
            )
            rctx.enqueue_function[copy_kernel](
                v, v0, grid_dim=GRID, block_dim=BLOCK
            )
            if stages < 4:
                return
            rctx.enqueue_function[advect_kernel](
                scratch, dr, u, v, DT, DYE_FADE, grid_dim=GRID, block_dim=BLOCK
            )
            rctx.enqueue_function[copy_kernel](
                dr, scratch, grid_dim=GRID, block_dim=BLOCK
            )
            rctx.enqueue_function[advect_kernel](
                scratch, dg, u, v, DT, DYE_FADE, grid_dim=GRID, block_dim=BLOCK
            )
            rctx.enqueue_function[copy_kernel](
                dg, scratch, grid_dim=GRID, block_dim=BLOCK
            )
            rctx.enqueue_function[advect_kernel](
                scratch, db, u, v, DT, DYE_FADE, grid_dim=GRID, block_dim=BLOCK
            )
            rctx.enqueue_function[copy_kernel](
                db, scratch, grid_dim=GRID, block_dim=BLOCK
            )
            if stages < 5:
                return
            rctx.enqueue_function[render_kernel](
                frame, dr, dg, db, grid_dim=PIX_GRID, block_dim=BLOCK
            )

    return DeviceGraph.create(ctx, build)


def main() raises:
    print(
        "Fluid bench -",
        W,
        "x",
        H,
        "sim,",
        STEPS,
        "steps,",
        FRAME_DISPATCHES,
        "dispatches per frame",
    )

    var ctx = DeviceContext(api="cuda")
    print("  GPU:", ctx.name())

    var u = ctx.enqueue_create_buffer[DType.float32](N)
    var v = ctx.enqueue_create_buffer[DType.float32](N)
    var u0 = ctx.enqueue_create_buffer[DType.float32](N)
    var v0 = ctx.enqueue_create_buffer[DType.float32](N)
    var dr = ctx.enqueue_create_buffer[DType.float32](N)
    var dg = ctx.enqueue_create_buffer[DType.float32](N)
    var db = ctx.enqueue_create_buffer[DType.float32](N)
    var scratch = ctx.enqueue_create_buffer[DType.float32](N)
    var div = ctx.enqueue_create_buffer[DType.float32](N)
    var pr = ctx.enqueue_create_buffer[DType.float32](N)
    var pr0 = ctx.enqueue_create_buffer[DType.float32](N)
    var frame = ctx.enqueue_create_buffer[DType.uint32](PIXELS)
    var host = ctx.enqueue_create_host_buffer[DType.float32](N)
    ctx.synchronize()

    # ---- 1. the dispatch itself ------------------------------------------
    # K launches of a one-thread kernel, one wait: the floor every frame
    # pays 44 times over in the classic path.
    var tick = ctx.enqueue_create_buffer[DType.float32](1)
    ctx.synchronize()
    for _warm in range(WARMUP):
        ctx.enqueue_function[tick_kernel](tick, Float32(1), grid_dim=1,
            block_dim=32)
    ctx.synchronize()
    var t0 = now_us()
    for _k in range(TRIVIAL_K):
        ctx.enqueue_function[tick_kernel](tick, Float32(1), grid_dim=1,
            block_dim=32)
    ctx.synchronize()
    var launch_us = (now_us() - t0) / TRIVIAL_K
    print()
    print("  trivial kernel, one thread:")
    print("    classic dispatch:", launch_us, "us")
    print(
        "      x",
        FRAME_DISPATCHES,
        "=",
        launch_us * FRAME_DISPATCHES,
        "us of a frame, before any physics runs",
    )

    # The same K kernels as a graph, so a replay's per-node cost sits beside
    # the per-dispatch number it replaces.
    def build_ticks(mut builder: DeviceGraphBuilder) raises {imm}:
        with builder.recording_context() as rctx:
            for _k in range(TRIVIAL_K):
                rctx.enqueue_function[tick_kernel](
                    tick, Float32(1), grid_dim=1, block_dim=32
                )

    var ticks_graph = DeviceGraph.create(ctx, build_ticks)
    ticks_graph.replay()
    ctx.synchronize()
    t0 = now_us()
    ticks_graph.replay()
    ctx.synchronize()
    var replay_us = (now_us() - t0) / TRIVIAL_K
    print("    graph node, replayed:", replay_us, "us")

    # ---- 2. what does the recording surface actually record? --------------
    # A regression guard with a history. The recording context's docstring
    # promises that kernels, copies and memsets all record; until nvptxrt
    # grew recording branches for the four copy and memset entry points, a
    # memset or a copy enqueued through a recording context executed RIGHT
    # THEN on the live stream and never became a node, so a replayed graph
    # silently computed without them. The probe records one of each and
    # asks the destination, before and after a replay, which happened.
    print()
    print("  recording-semantics probe (memset and copy through a")
    print("  recording context):")
    var probe_dst = ctx.enqueue_create_buffer[DType.float32](4)
    var probe_src = ctx.enqueue_create_buffer[DType.float32](4)
    var probe_host = ctx.enqueue_create_host_buffer[DType.float32](4)
    ctx.synchronize()
    ctx.enqueue_memset(probe_dst, Float32(0))
    ctx.enqueue_memset(probe_src, Float32(5))
    ctx.synchronize()

    def build_probe(mut builder: DeviceGraphBuilder) raises {imm}:
        with builder.recording_context() as rctx:
            rctx.enqueue_memset(probe_dst, Float32(7))
            rctx.enqueue_copy(probe_dst, probe_src)

    var probe = DeviceGraph.create(ctx, build_probe)

    # dst[0], read back: 0 means nothing has touched it yet, 7 means a
    # memset ran, 5 means the copy ran.
    probe_host.enqueue_copy_from(probe_dst)
    ctx.synchronize()
    var before = probe_host[0]
    probe.replay()
    ctx.synchronize()
    probe_host.enqueue_copy_from(probe_dst)
    ctx.synchronize()
    var after = probe_host[0]
    print("    dst[0] before any replay:", before, " (0 means: recorded,")
    print("      not run during recording)")
    print("    dst[0] after one replay: ", after, " (5 means: the copy ran)")
    if before == Float32(0) and after == Float32(5):
        print("    verdict: memsets and copies RECORD - the docstring holds")
    else:
        print(
            "    verdict: memsets and copies EXECUTED DURING RECORDING - they"
        )
        print(
            "    never became graph nodes; a graph relying on them replays"
        )
        print("    without them")


    # The graph must OWN the buffers its kernel nodes name. Mojo destroys a
    # value at its last use, and a recorded kernel's buffer is used, as far
    # as the source can see, exactly once: at the record. If the graph only
    # kept the raw device address, the buffer was cuMemFree'd before the
    # first replay and every replay after that was a use-after-free -- one
    # that faulted or did not depending on whether the driver had reclaimed
    # the pages yet, which is what made the frame-graph failure look like
    # it was about clamped address arithmetic. This catches it without a
    # fault: a same-sized allocation made after the record lands on the
    # freed block if there was one, and the replay then writes into it.
    print()
    print("  recording-semantics probe (a graph owns its kernels' buffers):")
    var owned_host = ctx.enqueue_create_host_buffer[DType.float32](4)

    def build_owned(mut builder: DeviceGraphBuilder) raises {imm}:
        var a = ctx.enqueue_create_buffer[DType.float32](4)
        ctx.enqueue_memset(a, Float32(0))
        with builder.recording_context() as rctx:
            rctx.enqueue_function[tick_kernel](
                a, Float32(1), grid_dim=1, block_dim=32
            )
        # `a` is not named again: without graph ownership it dies here.

    var owned = DeviceGraph.create(ctx, build_owned)
    var b = ctx.enqueue_create_buffer[DType.float32](4)
    ctx.enqueue_memset(b, Float32(9))
    ctx.synchronize()
    owned.replay()
    ctx.synchronize()
    owned_host.enqueue_copy_from(b)
    ctx.synchronize()
    var untouched = owned_host[0]
    print("    a later same-sized buffer after replay:", untouched,
          " (9 means the graph wrote its own buffer;")
    print("      1 means it wrote into memory the buffer had already lost)")
    if untouched == Float32(9):
        print("    verdict: the graph OWNS its buffers")
    else:
        print("    verdict: USE-AFTER-FREE - the graph held a dead pointer")

    # ---- 3. whole frames --------------------------------------------------
    # FLUID_BENCH_SKIP_CLASSIC=1 jumps straight to the graph section: no
    # classic use of the solver kernels before recording, which is the
    # ordering experiment for the graph failure.
    var skip_classic = _env_int("FLUID_BENCH_SKIP_CLASSIC", 0) == 1
    var synced_us = 0
    var async_us = 0
    var synced_total = Float32(-1)
    var async_total = Float32(-1)
    print()
    print("  a frame: solver step, three dye channels, no render:")
    if not skip_classic:
        seed_the_scene(ctx, u, v, dr, dg, db)
        for _warm in range(WARMUP):
            run_classic(
                ctx, u, v, u0, v0, div, pr, pr0, dr, dg, db, scratch, True
            )
        seed_the_scene(ctx, u, v, dr, dg, db)
        t0 = now_us()
        run_classic(
            ctx, u, v, u0, v0, div, pr, pr0, dr, dg, db, scratch, True
        )
        synced_us = now_us() - t0
        synced_total = dye_sum(ctx, host, dr)
        print(
            "    classic, synced every step:",
            synced_us // STEPS,
            "us/frame (",
            synced_us // STEPS // 1000,
            "ms ),",
            synced_us // STEPS // FRAME_DISPATCHES,
            "us per dispatch",
        )

        seed_the_scene(ctx, u, v, dr, dg, db)
        for _warm in range(WARMUP):
            run_classic(
                ctx, u, v, u0, v0, div, pr, pr0, dr, dg, db, scratch, True
            )
        seed_the_scene(ctx, u, v, dr, dg, db)
        t0 = now_us()
        run_classic(
            ctx, u, v, u0, v0, div, pr, pr0, dr, dg, db, scratch, False
        )
        async_us = now_us() - t0
        async_total = dye_sum(ctx, host, dr)
        print(
            "    classic, one sync at end:  ",
            async_us // STEPS,
            "us/frame (",
            async_us // STEPS // 1000,
            "ms )",
        )
    else:
        print("    (skipped: FLUID_BENCH_SKIP_CLASSIC=1)")

    var stages = _env_int("FLUID_BENCH_STAGES", 5)
    var graph_t0 = now_us()
    var graph = build_frame_graph(
        ctx, u, v, u0, v0, dr, dg, db, scratch, div, pr, pr0, frame, stages
    )
    var graph_build_us = now_us() - graph_t0
    # SKIP_CLASSIC=2 also skips the reseeds around replay: the buffers hold
    # garbage VALUES, which cannot fault -- the memory is allocated -- but
    # nothing transient touches the solver kernels between record and
    # replay, which is the experiment.
    var no_reseed = _env_int("FLUID_BENCH_SKIP_CLASSIC", 0) == 2
    if not no_reseed:
        seed_the_scene(ctx, u, v, dr, dg, db)
    var graph_us = -1
    var graph_total = Float32(-1)
    try:
        for _warm in range(WARMUP):
            graph.replay()
            ctx.synchronize()
        if not no_reseed:
            seed_the_scene(ctx, u, v, dr, dg, db)
        t0 = now_us()
        for _step in range(STEPS):
            graph.replay()
            ctx.synchronize()
        graph_us = now_us() - t0
        graph_total = dye_sum(ctx, host, dr)
    except err:
        # An error 700 here poisons the CUDA context: everything after it
        # would fail for the same reason. Say it plainly and stop -- the
        # classic numbers above stand, and the stage that broke is named by
        # the FLUID_BENCH_STAGES knob used to get here.
        print("    graph replay FAILED at stage", stages, ":", err)
        print("    (a failed replay poisons the CUDA context; stopping)")
        return
    print(
        "    graph replay, synced:      ",
        graph_us // STEPS,
        "us/frame (",
        graph_us // STEPS // 1000,
        "ms ),",
        graph_us // STEPS // FRAME_DISPATCHES,
        "us per node",
    )
    print(
        "    graph build + instantiate: ",
        graph_build_us,
        "us, once, not per frame",
    )

    print()
    print("  same physics?  dye totals: classic", synced_total)
    print("                  one-sync ", async_total)
    print("                  graph   ", graph_total)
    if abs(graph_total - synced_total) > Float32(0.0001) * abs(synced_total):
        print("    DANGER: the graph path drifted - a dependency is missing")
    else:
        print("    all three agree - the graph's 44 nodes order correctly")

    print("  measured: trivial", TRIVIAL_K, "launches;", STEPS, "frames")
