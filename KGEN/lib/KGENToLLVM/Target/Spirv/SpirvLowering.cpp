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
// MLIR-lowering policy for SPIR-V offload targets (Adreno via DragonMax).
//
//===----------------------------------------------------------------------===//

#include "SpirvKernelArgAddressSpace.h"
#include "Target/Spirv/SpirvTraits.h"
#include "Target/TargetLowering.h"

#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Pass/PassManager.h"

namespace M::KGEN {
namespace {

class SpirvLowering final : public TargetLowering {
public:
  const TargetTraits *traits() const override { return &SpirvTraits::get(); }

  /// The LLVM SPIR-V backend recognizes a kernel entry point by its calling
  /// convention: SPIR_KERNEL becomes an OpEntryPoint in the emitted module.
  /// Without this marking a kernel lowers as a plain function, the driver
  /// finds no entry point, and clCreateKernel fails at load time - far from
  /// the actual mistake.
  void markExportedKernel(mlir::Operation *func) const override {
    if (auto llvmFunc = mlir::dyn_cast<mlir::LLVM::LLVMFuncOp>(func))
      llvmFunc.setCConv(mlir::LLVM::cconv::CConv::SPIR_KERNEL);
  }

  bool isExportedKernel(mlir::Operation *func) const override {
    auto llvmFunc = mlir::dyn_cast<mlir::LLVM::LLVMFuncOp>(func);
    return llvmFunc &&
           llvmFunc.getCConv() == mlir::LLVM::cconv::CConv::SPIR_KERNEL;
  }

  /// A kernel's pointer parameters have to be moved out of the default address
  /// space before translation, or the backend emits them as Function storage
  /// and the driver rejects the program at clCreateKernel. This runs as a late
  /// pass rather than inside `markExportedKernel` because that hook fires
  /// during signature conversion, before the body exists to rewrite alongside
  /// it.
  void addPostLowerToLLVMPasses(mlir::OpPassManager &pm) const override {
    pm.addPass(createSpirvKernelArgAddressSpacePass());
  }

protected:
  // Compiled from source in this repo and always registered; see the
  // isBaseTarget note in SpirvTraits.h.
  bool isBaseTarget() const override { return true; }
};

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wglobal-constructors"
RegisterTargetLowering<SpirvLowering> registerSpirvLowering;
#pragma GCC diagnostic pop

} // namespace
} // namespace M::KGEN
