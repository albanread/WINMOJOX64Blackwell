# saxpy with its working shown.
#
# The index probe proved every work-item computes the right index and writes
# the right slot. saxpy still fails verification, so the difference has to be
# in what saxpy does that the probe does not: READ from device buffers that
# were populated by a host-to-device copy. This prints expected against actual
# for a few slots, plus what a pure passthrough kernel (dst = x) sees, which
# separates "the copy never landed" from "the arithmetic is wrong".

from max.gpu.host import DeviceContext
from std.gpu.primitives import block_dim, block_idx, thread_idx
from std.memory import Pointer


comptime N = 4096
comptime BLOCK = 64


def passthrough_kernel(
    x: Pointer[Float32, MutAnyOrigin],
    dst: Pointer[Float32, MutAnyOrigin],
):
    var i = block_idx.x * block_dim.x + thread_idx.x
    if i < N:
        dst.unsafe_offset(i)[] = x.unsafe_offset(i)[]


def saxpy_kernel(
    x: Pointer[Float32, MutAnyOrigin],
    y: Pointer[Float32, MutAnyOrigin],
    dst: Pointer[Float32, MutAnyOrigin],
    a: Float32,
):
    var i = block_idx.x * block_dim.x + thread_idx.x
    if i < N:
        dst.unsafe_offset(i)[] = a * x.unsafe_offset(i)[] + y.unsafe_offset(i)[]


def main() raises:
    var ctx = DeviceContext(api="adreno")
    var a = Float32(2.5)

    var x_host = ctx.enqueue_create_host_buffer[DType.float32](N)
    var y_host = ctx.enqueue_create_host_buffer[DType.float32](N)
    var out_host = ctx.enqueue_create_host_buffer[DType.float32](N)
    ctx.synchronize()

    for i in range(N):
        x_host[i] = Float32(i)
        y_host[i] = Float32(N - i)
        out_host[i] = Float32(-999)

    var x_dev = ctx.enqueue_create_buffer[DType.float32](N)
    var y_dev = ctx.enqueue_create_buffer[DType.float32](N)
    var out_dev = ctx.enqueue_create_buffer[DType.float32](N)
    x_dev.enqueue_copy_from(x_host)
    y_dev.enqueue_copy_from(y_host)
    out_dev.enqueue_copy_from(out_host)

    # Round 0: pure copy round-trip, no kernel anywhere. H2D then D2H on the
    # same buffer separates "the copy never landed" from "the kernel reads
    # wrongly" -- the index probe could not, because its kernel overwrote
    # every slot before anything was read back.
    var echo_host = ctx.enqueue_create_host_buffer[DType.float32](N)
    ctx.synchronize()
    for i in range(N):
        echo_host[i] = Float32(-5)
    echo_host.enqueue_copy_from(x_dev)
    ctx.synchronize()
    var echo_bad = 0
    for i in range(N):
        if echo_host[i] != Float32(i):
            echo_bad += 1
    print("h2d+d2h echo:", echo_bad, "of", N, "wrong")
    print("  slot 0..4:", echo_host[0], echo_host[1], echo_host[2], echo_host[3], echo_host[4])

    # Round 1: passthrough. If dst != x afterwards, the host-to-device copy
    # (or the read) is the broken half and the arithmetic never mattered.
    ctx.enqueue_function[passthrough_kernel](
        x_dev,
        out_dev,
        grid_dim=(N + BLOCK - 1) // BLOCK,
        block_dim=BLOCK,
    )
    out_host.enqueue_copy_from(out_dev)
    ctx.synchronize()

    var pass_bad = 0
    for i in range(N):
        if out_host[i] != Float32(i):
            pass_bad += 1
    print("passthrough: ", pass_bad, "of", N, "wrong")
    print("  slot 0..4:", out_host[0], out_host[1], out_host[2], out_host[3], out_host[4])

    # Round 2: the real thing, with samples printed either way.
    ctx.enqueue_function[saxpy_kernel](
        x_dev,
        y_dev,
        out_dev,
        a,
        grid_dim=(N + BLOCK - 1) // BLOCK,
        block_dim=BLOCK,
    )
    out_host.enqueue_copy_from(out_dev)
    ctx.synchronize()

    var bad = 0
    for i in range(N):
        var want = a * Float32(i) + Float32(N - i)
        if abs(out_host[i] - want) > 1e-3:
            bad += 1
    print("saxpy:       ", bad, "of", N, "wrong")
    print("  slot    expected    got")
    var samples: List[Int] = [0, 1, 2, 63, 64, 100, 4095]
    for i in samples:
        print("  ", i, "   ", a * Float32(i) + Float32(N - i), "   ", out_host[i])
