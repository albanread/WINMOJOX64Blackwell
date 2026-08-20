# ===----------------------------------------------------------------------=== #
# DragonMax GPU acceptance test - THE definition of "finished" for the GPU
# compile line (see dragon/HANDOFF.md).
#
# Passes when:
#     mojo build --target-accelerator adreno-x1 adreno_saxpy.mojo && ./adreno_saxpy
# runs the kernel on the Adreno X1-45 and every element verifies on the host.
#
# Deliberately contains nothing DragonMax-specific: the objective is that Mojo
# code stays standard Mojo. If this file needs a DragonMax-only API to pass,
# the objective is not met. Written against the DeviceContext API surface of
# max/mojo/max/gpu/host/device_context.mojo at fork point dde8f83773; expect
# touch-ups as WINMOJO's stdlib lands, but the SHAPE is the contract.
# ===----------------------------------------------------------------------=== #

from max.gpu.host import DeviceContext


comptime N = 4096
comptime BLOCK = 64


fn saxpy_kernel(
    x: UnsafePointer[Float32],
    y: UnsafePointer[Float32],
    out: UnsafePointer[Float32],
    a: Float32,
):
    var i = block_idx.x * block_dim.x + thread_idx.x
    if i < N:
        out[i] = a * x[i] + y[i]


def main():
    # "adreno" dispatches through AsyncRT_DeviceContext_create's api string
    # to dragonrt.dll. The default (from AdrenoX1's api field) is also
    # "adreno" when built --target-accelerator adreno-x1, so the explicit
    # argument is belt and braces.
    var ctx = DeviceContext(api="adreno")

    var a = Float32(2.5)
    var x_host = ctx.enqueue_create_host_buffer[DType.float32](N)
    var y_host = ctx.enqueue_create_host_buffer[DType.float32](N)
    var out_host = ctx.enqueue_create_host_buffer[DType.float32](N)
    ctx.synchronize()

    for i in range(N):
        x_host[i] = Float32(i)
        y_host[i] = Float32(N - i)

    var x_dev = ctx.enqueue_create_buffer[DType.float32](N)
    var y_dev = ctx.enqueue_create_buffer[DType.float32](N)
    var out_dev = ctx.enqueue_create_buffer[DType.float32](N)
    x_dev.enqueue_copy_from(x_host)
    y_dev.enqueue_copy_from(y_host)

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
    if bad != 0:
        print("FAIL:", bad, "of", N, "elements wrong")
        raise Error("adreno_saxpy failed verification")
    print("PASS: all", N, "elements correct on", ctx.name())
