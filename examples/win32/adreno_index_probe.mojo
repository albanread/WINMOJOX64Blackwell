# What index does each work-item think it has?
#
# saxpy now creates, launches and returns without an OpenCL error, and most
# elements are still wrong -- which points at the index each work-item computes
# rather than at the arithmetic. So: write the index itself, leave the buffer
# pre-filled with a sentinel, and read back what actually landed where.
#
# Each of the three terms is written separately, so a wrong one is identifiable
# rather than merely visible in the sum.

from max.gpu.host import DeviceContext
from std.gpu.primitives import block_dim, block_idx, thread_idx
from std.memory import Pointer


comptime N = 4096
comptime BLOCK = 64


def index_kernel(
    block_out: Pointer[Float32, MutAnyOrigin],
    size_out: Pointer[Float32, MutAnyOrigin],
    thread_out: Pointer[Float32, MutAnyOrigin],
):
    var i = block_idx.x * block_dim.x + thread_idx.x
    if i < N:
        block_out.unsafe_offset(i)[] = Float32(block_idx.x)
        size_out.unsafe_offset(i)[] = Float32(block_dim.x)
        thread_out.unsafe_offset(i)[] = Float32(thread_idx.x)


def main() raises:
    var ctx = DeviceContext(api="adreno")

    var blocks_host = ctx.enqueue_create_host_buffer[DType.float32](N)
    var sizes_host = ctx.enqueue_create_host_buffer[DType.float32](N)
    var threads_host = ctx.enqueue_create_host_buffer[DType.float32](N)
    ctx.synchronize()

    # -1 marks a slot nothing wrote to. A hole means two work-items computed
    # the same index; a wrong value means the builtin itself is wrong.
    for i in range(N):
        blocks_host[i] = Float32(-1)
        sizes_host[i] = Float32(-1)
        threads_host[i] = Float32(-1)

    var blocks_dev = ctx.enqueue_create_buffer[DType.float32](N)
    var sizes_dev = ctx.enqueue_create_buffer[DType.float32](N)
    var threads_dev = ctx.enqueue_create_buffer[DType.float32](N)
    blocks_dev.enqueue_copy_from(blocks_host)
    sizes_dev.enqueue_copy_from(sizes_host)
    threads_dev.enqueue_copy_from(threads_host)

    ctx.enqueue_function[index_kernel](
        blocks_dev,
        sizes_dev,
        threads_dev,
        grid_dim=(N + BLOCK - 1) // BLOCK,
        block_dim=BLOCK,
    )

    blocks_host.enqueue_copy_from(blocks_dev)
    sizes_host.enqueue_copy_from(sizes_dev)
    threads_host.enqueue_copy_from(threads_dev)
    ctx.synchronize()

    print("launched grid_dim=", (N + BLOCK - 1) // BLOCK, " block_dim=", BLOCK)
    print("index  block_idx  block_dim  thread_idx   (expect i/64, 64, i%64)")
    var samples: List[Int] = [0, 1, 63, 64, 65, 127, 128, 1000, 4095]
    for i in samples:
        print(
            i,
            "     ",
            blocks_host[i],
            "      ",
            sizes_host[i],
            "      ",
            threads_host[i],
        )

    var holes = 0
    var wrong_size = 0
    for i in range(N):
        if blocks_host[i] == Float32(-1):
            holes += 1
        if sizes_host[i] != Float32(BLOCK):
            wrong_size += 1
    print("untouched slots:", holes, "of", N)
    print("block_dim not", BLOCK, ":", wrong_size, "of", N)
