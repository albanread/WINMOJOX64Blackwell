//===----------------------------------------------------------------------===//
// Copyright (c) 2026, DragonMax contributors.
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

#ifndef KGEN_KGENTOLLVM_TARGET_SPIRV_SPIRVKERNELARGADDRESSSPACE_H
#define KGEN_KGENTOLLVM_TARGET_SPIRV_SPIRVKERNELARGADDRESSSPACE_H

// Not a forward declaration: the caller hands the returned `unique_ptr` to a
// pass manager by value, and destroying it needs `Pass` complete there.
#include "mlir/Pass/Pass.h"

#include <memory>

namespace M::KGEN {

/// Promotes addrspace(0) pointer parameters of SPIR_KERNEL functions to
/// addrspace(1) (CrossWorkgroup), which is where OpenCL requires kernel
/// pointer arguments to live. See the implementation file for why this is not
/// optional.
std::unique_ptr<mlir::Pass> createSpirvKernelArgAddressSpacePass();

} // namespace M::KGEN

#endif // KGEN_KGENTOLLVM_TARGET_SPIRV_SPIRVKERNELARGADDRESSSPACE_H
