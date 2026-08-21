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
//
// NVVM/LLVM lowering policy for NVIDIA offload. This restores the open-source
// target hooks KGEN already exposes and leaves native-code generation to the
// CUDA driver's PTX JIT.
//
//===----------------------------------------------------------------------===//

#include "KGEN/KGENDialect/KGENTypes.h"
#include "Target/NVPTX/NVPTXTraits.h"
#include "Target/TargetLowering.h"

#include "mlir/Conversion/NVVMToLLVM/NVVMToLLVM.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Dialect/LLVMIR/NVVMDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/Threading.h"

namespace M::KGEN {
namespace {

class NVPTXLowering final : public TargetLowering {
public:
  const TargetTraits *traits() const override { return &NVPTXTraits::get(); }

  void populateLowerPOPToLLVMPatterns(mlir::RewritePatternSet &patterns,
                                      mlir::LLVMTypeConverter &converter,
                                      TargetInfoAttr target) const override {
    mlir::populateNVVMToLLVMConversionPatterns(patterns);
  }

  bool isConvergentOp(mlir::Operation *op) const override {
    return mlir::isa<mlir::NVVM::BarrierOp>(op);
  }

  void markExportedKernel(mlir::Operation *func) const override {
    if (auto llvmFunc = mlir::dyn_cast<mlir::LLVM::LLVMFuncOp>(func))
      llvmFunc->setAttr(mlir::NVVM::NVVMDialect::getKernelFuncAttrName(),
                        mlir::UnitAttr::get(func->getContext()));
  }

  bool isExportedKernel(mlir::Operation *func) const override {
    auto llvmFunc = mlir::dyn_cast<mlir::LLVM::LLVMFuncOp>(func);
    return llvmFunc &&
           llvmFunc->hasAttr(mlir::NVVM::NVVMDialect::getKernelFuncAttrName());
  }

  llvm::StringRef getKernelByValArgAttrName() const override {
    return mlir::LLVM::LLVMDialect::getByValAttrName();
  }

  mlir::Type lowerKernelArgToMemory(mlir::Type type) const override {
    auto structType = mlir::dyn_cast<StructType>(type);
    if (!structType || structType.getIsParamPack())
      return {};

    bool hasPointer = false;
    mlir::AttrTypeReplacer replacer;
    replacer.addReplacement([&hasPointer](PointerType) -> mlir::Type {
      hasPointer = true;
      return {};
    });
    replacer.replace(type);
    return hasPointer ? PointerType::get(type) : mlir::Type();
  }

  void mapKernelArgMetadata(mlir::Operation *func, mlir::NamedAttribute attr,
                            mlir::NamedAttrList &argAttrs) const override {
    if (attr.getName() != mlir::NVVM::NVVMDialect::getGridConstantAttrName())
      return;

    mlir::Builder builder(func->getContext());
    argAttrs.set(attr.getName(), builder.getUnitAttr());
    // CUDA's kernel-parameter ABI lowers a grid-constant CUtensorMap to an
    // 8-byte-aligned 128-byte parameter even though the host-side object must
    // be 64-byte aligned while it is populated by cuTensorMapEncode*.
    argAttrs.set(mlir::LLVM::LLVMDialect::getAlignAttrName(),
                 builder.getI32IntegerAttr(8));
  }

protected:
  bool isBaseTarget() const override { return true; }
};

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wglobal-constructors"
RegisterTargetLowering<NVPTXLowering> registerNVPTXLowering;
#pragma GCC diagnostic pop

} // namespace
} // namespace M::KGEN
