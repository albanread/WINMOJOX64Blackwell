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

from std._plugin._trait import PluginHooks
from std.collections.string.string_span import _get_kgen_string


struct AdrenoPlugin(PluginHooks):
    """`PluginHooks` implementation for Qualcomm Adreno backends.

    Every hook is left at its `PluginHooks` default, matching `MetalPlugin`.
    The name must equal the `stdlib_plugin` field of the Adreno targets in
    `gpu/host/info.mojo`; `PluginSelector` matches on that string at compile
    time.

    Note `print` inside a kernel is not expected to work here. Adreno has no
    hostcall mechanism, and the AMD experience of building one from scratch is
    written up in `max/docs/design-docs/amd-printf-lessons-learned.md`. It is
    deliberately off the bring-up path.
    """

    comptime name: __mlir_type.`!kgen.string` = _get_kgen_string["adreno"]()
