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

#ifndef KGEN_COMPILER_TARGET_NVPTX_NVPTXBACKEND_H
#define KGEN_COMPILER_TARGET_NVPTX_NVPTXBACKEND_H

#include "KGEN/Compiler/Target/TargetBackend.h"

namespace M::KGEN {

class NVPTXBackend final : public TargetBackend {
public:
  const TargetTraits *traits() const override;

  SplitStrategy
  splitStrategy(const CompilationOptions &options) const override {
    return SplitStrategy::None;
  }
  bool isCodegenInterprocedural() const override { return true; }
  bool isOffload() const override { return true; }

  bool requiresOriginalFunctionOrder() const override { return true; }
  bool requiresSingleModuleSplit() const override { return true; }
  void reorderLinkedModuleFunctions(
      llvm::Module &module,
      const llvm::StringMap<unsigned> &originalOrder) const override;

  llvm::SimplifyCFGOptions
  adjustSimplifyCFGOptions(llvm::SimplifyCFGOptions options) const override {
    return options.bonusInstThreshold(2);
  }

  void addSanitizers(llvm::ModulePassManager &mpm,
                     const CompilationOptions &options) const override {}
  void addPipelineStartPasses(llvm::ModulePassManager &mpm,
                              const CompilationOptions &options) const override;
  void attachCodegenAttributes(llvm::Function *kernelEntry) const override;

  ErrorOr<BufferRef> emitAssembly(llvm::Module &module,
                                  EmitContext &ctx) const override;
  ErrorOr<BufferRef> emitObject(llvm::Module &module,
                                EmitContext &ctx) const override;
  ErrorOr<BufferRef> createArchive(llvm::MutableArrayRef<BufferRef> objects,
                                   llvm::StringRef moduleName,
                                   EmitContext &ctx) const override;

protected:
  std::optional<unsigned> sharedMemoryAddressSpace() const override {
    return 3;
  }
  bool isBaseTarget() const override { return true; }
};

} // namespace M::KGEN

#endif // KGEN_COMPILER_TARGET_NVPTX_NVPTXBACKEND_H
