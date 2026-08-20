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
//
// TargetBackend for SPIR-V offload targets (Adreno via DragonMax): llc's
// SPIR-V backend emits the .spv module, and that module IS the deliverable -
// the DragonMax device runtime feeds it to the Qualcomm driver compiler at
// kernel-load time (loadFunction sniffs the SPIR-V magic and calls
// clCreateProgramWithIL). Nothing here links into the host image.
//
//===----------------------------------------------------------------------===//

#ifndef KGEN_COMPILER_TARGET_SPIRV_SPIRVBACKEND_H
#define KGEN_COMPILER_TARGET_SPIRV_SPIRVBACKEND_H

#include "KGEN/Compiler/Target/TargetBackend.h"

namespace M::KGEN {

class SpirvBackend final : public TargetBackend {
public:
  const TargetTraits *traits() const override;

  /// One SPIR-V module per compilation unit. The driver compiler consumes
  /// whole modules; there is no MCLinker step for .spv, so per-function
  /// splitting would only multiply driver compilations.
  SplitStrategy splitStrategy(const CompilationOptions &options) const override {
    return SplitStrategy::None;
  }

  bool isOffload() const override { return true; }

  /// No sanitizer instrumentation device-side: the runtime calls ASan/TSan
  /// insert do not exist in a shader environment.
  void addSanitizers(llvm::ModulePassManager &mpm,
                     const CompilationOptions &options) const override {}

  ErrorOr<BufferRef> emitAssembly(llvm::Module &module,
                                  EmitContext &ctx) const override;
  ErrorOr<BufferRef> emitObject(llvm::Module &module,
                                EmitContext &ctx) const override;
  ErrorOr<BufferRef> createArchive(llvm::MutableArrayRef<BufferRef> objects,
                                   llvm::StringRef moduleName,
                                   EmitContext &ctx) const override;

protected:
  /// addrspace(3) is Workgroup in the LLVM SPIR-V backend's numbering (the
  /// same convention as NVPTX/AMDGPU shared memory).
  std::optional<unsigned> sharedMemoryAddressSpace() const override {
    return 3;
  }

  // Compiled from source in this repo and always registered; see the
  // isBaseTarget note in SpirvTraits.h.
  bool isBaseTarget() const override { return true; }
};

} // namespace M::KGEN

#endif // KGEN_COMPILER_TARGET_SPIRV_SPIRVBACKEND_H
