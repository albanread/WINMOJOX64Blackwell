# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #

from std.builtin._closure import __ownership_keepalive

from max.gpu.host import DeviceContext
from max.gpu.host.nvidia.tma import TMADescriptor, create_tma_descriptor
from std.gpu import block_idx
from max.gpu.memory import (
    cp_async_bulk_tensor_shared_cluster_global,
)
from max.gpu.sync import (
    mbarrier_arrive_expect_tx_shared,
    mbarrier_init,
    mbarrier_try_wait_parity_shared,
)
from std.memory import unsafe_stack_allocation
from std.memory.alloc import unsafe_alloc
from std.testing import assert_equal

from std.utils.index import Index


@__llvm_arg_metadata(descriptor, `nvvm.grid_constant`)
def kernel_copy_async_tma(
    descriptor: TMADescriptor,
    output: Pointer[Float32, MutAnyOrigin],
):
    var shmem = unsafe_stack_allocation[
        16, DType.float32, alignment=16, address_space=AddressSpace.SHARED
    ]()
    var mbar = unsafe_stack_allocation[
        1, Int64, address_space=AddressSpace.SHARED
    ]()
    var descriptor_ptr = Pointer(to=descriptor).unsafe_bitcast[NoneType]()
    mbarrier_init(mbar, 1)

    mbarrier_arrive_expect_tx_shared(mbar, 64)
    cp_async_bulk_tensor_shared_cluster_global(
        shmem, descriptor_ptr, mbar, Index(block_idx.x * 4, block_idx.y * 4)
    )
    mbarrier_try_wait_parity_shared(mbar, 0, 10000000)

    var tile_x = Int(block_idx.x) * 4
    var tile_y = Int(block_idx.y) * 4
    for row in range(4):
        for column in range(4):
            output[unsafe_offset=(tile_y + row) * 8 + tile_x + column] = shmem[
                unsafe_offset=row * 4 + column
            ]


def test_tma_tile_copy(ctx: DeviceContext) raises:
    print("== test_tma_tile_copy")
    var gmem_host = unsafe_alloc[Float32](8 * 8)
    for i in range(64):
        gmem_host[unsafe_offset=i] = Float32(i)

    var gmem_dev = ctx.enqueue_create_buffer[DType.float32](8 * 8)
    var output_dev = ctx.enqueue_create_buffer[DType.float32](8 * 8)

    ctx.enqueue_copy(gmem_dev, gmem_host)

    var descriptor = create_tma_descriptor[DType.float32, 2](
        gmem_dev, (8, 8), (8, 1), (4, 4)
    )

    ctx.enqueue_function[kernel_copy_async_tma](
        descriptor, output_dev, grid_dim=(2, 2), block_dim=(1)
    )
    ctx.synchronize()
    with output_dev.map_to_host() as output_host:
        for i in range(64):
            assert_equal(output_host[i], Float32(i))
    __ownership_keepalive(gmem_dev)
    gmem_host.unsafe_free()


def main() raises:
    with DeviceContext() as ctx:
        test_tma_tile_copy(ctx)
