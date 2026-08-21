# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, WINMOJO contributors.
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

"""Tests mapped completion flags and their CUDA graph nodes."""

from asyncrt_test_utils import create_test_device_context
from max.gpu.host import CompletionFlag, DeviceGraph, DeviceGraphBuilder
from std.atomic import Atomic
from std.testing import TestSuite, assert_equal, assert_true


def _bump_counter(user_data: OpaquePointer[MutAnyOrigin]):
    var counter = user_data.unsafe_bitcast[Scalar[DType.int32]]()
    _ = Atomic[Int32].fetch_add(counter, 1)


def test_completion_flag_stream_wait() raises:
    var ctx = create_test_device_context()
    var flag = CompletionFlag(ctx)
    assert_equal(flag.load(), 0)
    assert_true(flag.device_ptr() != 0)

    var stream = ctx.stream()
    stream.wait_for_host_value(flag, 7)
    flag.signal(7)
    stream.synchronize()
    assert_equal(flag.load(), 7)

    flag.reset()
    assert_equal(flag.load(), 0)


def test_completion_flag_graph_wait_and_host_callback() raises:
    var ctx = create_test_device_context()
    var flag = CompletionFlag(ctx)
    var callback_count = Atomic[Int32](0)
    var counter_ptr = Pointer(to=callback_count).unsafe_bitcast[NoneType]()
    var counter_opaque = rebind[OpaquePointer[MutAnyOrigin]](counter_ptr)

    def build(mut builder: DeviceGraphBuilder) raises {imm}:
        with builder.recording_context() as recording_ctx:
            recording_ctx.stream().enqueue_host_func(
                _bump_counter, counter_opaque
            )
            recording_ctx.stream().wait_for_host_value(flag, 9)

    var graph = DeviceGraph.create(ctx, build)
    graph.replay()
    flag.signal(9)
    ctx.synchronize()
    assert_equal(flag.load(), 9)
    assert_equal(callback_count.load(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
