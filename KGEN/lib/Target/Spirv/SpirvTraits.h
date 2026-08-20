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
// TargetTraits for SPIR-V offload targets (Qualcomm Adreno via DragonMax).
//
// Adreno has no LLVM backend and Qualcomm does not publish the shader ISA, so
// codegen stops at SPIR-V and the Qualcomm driver compiler lowers it the rest
// of the way at load time (clCreateProgramWithIL in dragon/runtime). This is
// the same handoff shape the Metal target uses with Apple's compiler; the
// difference is the interchange format is a published standard with an
// in-tree LLVM backend.
//
//===----------------------------------------------------------------------===//

#ifndef KGEN_TARGET_SPIRV_SPIRVTRAITS_H
#define KGEN_TARGET_SPIRV_SPIRVTRAITS_H

#include "Target/TargetTraits.h"

#include "llvm/TargetParser/Triple.h"

namespace M::KGEN {

struct SpirvTraits final : TargetTraits {
  llvm::StringRef name() const override { return "spirv"; }
  bool matches(const llvm::Triple &triple) const override {
    // spirv64-unknown-unknown is what the stdlib's Adreno target emits
    // (mojo/stdlib/std/gpu/host/info.mojo, _get_adreno_x1_target). isSPIRV()
    // also covers spirv32/logical-spirv, which is fine: they dispatch here or
    // nowhere.
    return triple.isSPIRV();
  }
  bool isGPU() const override { return true; }

  // Distinct spellings so offload kernels from different targets do not
  // collide in one output directory (see TargetTraits.h).
  llvm::StringRef getAsmExtension() const override { return ".spvasm"; }
  llvm::StringRef getLLVMExtension() const override { return ".spv.ll"; }
  llvm::StringRef getObjectExtension() const override { return ".spv"; }

  llvm::StringRef acceleratorSectionTitle() const override {
    return "Qualcomm Adreno (DragonMax)";
  }
  llvm::ArrayRef<AcceleratorArch> supportedAcceleratorArchs() const override {
    static const AcceleratorArch archs[] = {
        {"adreno-x1",
         "Adreno X1 (Snapdragon X); SPIR-V, lowered by the Qualcomm driver"},
    };
    return archs;
  }

  /// Shared stateless instance for the lowering/backend `traits()`.
  static const SpirvTraits &get();

protected:
  // The MAX gate (requireMaxForAccelerator) exists to demand Modular's binary
  // distribution for the accelerator backends Modular ships inside it. This
  // trio is compiled from source in this repository and is always registered;
  // there is no package whose absence could invalidate it. The closed piece in
  // this chain is Qualcomm's driver compiler, which consumes the SPIR-V at
  // load time - a driver boundary, not a withheld runtime.
  bool isBaseTarget() const override { return true; }
};

} // namespace M::KGEN

#endif // KGEN_TARGET_SPIRV_SPIRVTRAITS_H
