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

from std.compile import compile_info
from std.testing import TestSuite, assert_true

from max.gpu.host.info import RTX5090


def test_windows_x64_blackwell_ptx_codegen() raises:
    """Checks the source-built NVVM/LLVM to PTX handoff used on Windows."""

    @__parameter
    def add_one(
        dst: Pointer[Int32, MutAnyOrigin],
        src: Pointer[Int32, ImmutAnyOrigin],
    ):
        dst[] = src[] + 1

    var ptx = String(
        compile_info[
            add_one,
            target=RTX5090.target(),
            emission_kind="asm",
            compile_options="nvptx-short-ptr=true",
        ]()
    )

    assert_true(".version 8.7" in ptx)
    assert_true(".target sm_120a" in ptx)
    assert_true(".address_size 64" in ptx)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
