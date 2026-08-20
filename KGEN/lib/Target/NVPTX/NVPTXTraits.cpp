//===----------------------------------------------------------------------===//
// Copyright (c) 2026, WINMOJO contributors.
//
// Licensed under the Apache License v2.0 with LLVM Exceptions:
// https://llvm.org/LICENSE.txt
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#include "Target/NVPTX/NVPTXTraits.h"

namespace M::KGEN {

const NVPTXTraits &NVPTXTraits::get() {
  static const NVPTXTraits instance;
  return instance;
}

namespace {
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wglobal-constructors"
RegisterTargetTraits<NVPTXTraits> registerNVPTXTraits;
#pragma GCC diagnostic pop
} // namespace

} // namespace M::KGEN
