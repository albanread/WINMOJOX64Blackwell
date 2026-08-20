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
// Target traits for NVIDIA offload. PTX is intentionally the final compiler
// artifact: NVIDIA's Windows CUDA driver consumes it and JITs native code for
// the installed GPU.
//
//===----------------------------------------------------------------------===//

#ifndef KGEN_TARGET_NVPTX_NVPTXTRAITS_H
#define KGEN_TARGET_NVPTX_NVPTXTRAITS_H

#include "Target/TargetTraits.h"

#include "llvm/TargetParser/Triple.h"

namespace M::KGEN {

struct NVPTXTraits final : TargetTraits {
  llvm::StringRef name() const override { return "nvptx"; }
  bool matches(const llvm::Triple &triple) const override {
    return triple.isNVPTX();
  }
  bool isGPU() const override { return true; }

  // PTX is driver-consumable device IR rather than a host-linkable object.
  bool emitsOffloadObjectFile() const override { return false; }
  std::optional<unsigned> requiredStackAllocationAddressSpace() const override {
    return 5;
  }

  llvm::StringRef getAsmExtension() const override { return ".ptx"; }
  llvm::StringRef getLLVMExtension() const override { return ".nvptx.ll"; }
  llvm::StringRef getObjectExtension() const override { return ".ptx"; }

  llvm::StringRef acceleratorSectionTitle() const override {
    return "NVIDIA CUDA (PTX driver JIT)";
  }
  llvm::ArrayRef<AcceleratorArch> supportedAcceleratorArchs() const override {
    static const AcceleratorArch archs[] = {
        {"cuda", "CUDA device; select the installed GPU automatically"},
        {"sm_52", "Maxwell"},
        {"sm_60", "Pascal"},
        {"sm_61", "Pascal"},
        {"sm_75", "Turing"},
        {"sm_80", "Ampere"},
        {"sm_86", "Ampere"},
        {"sm_87", "Ampere"},
        {"sm_89", "Ada Lovelace"},
        {"sm_90", "Hopper"},
        {"sm_90a", "Hopper, architecture-specific"},
        {"sm_100", "Blackwell"},
        {"sm_100a", "Blackwell, architecture-specific"},
        {"sm_103", "Blackwell"},
        {"sm_103a", "Blackwell, architecture-specific"},
        {"sm_110", "Blackwell"},
        {"sm_110a", "Blackwell, architecture-specific"},
        {"sm_120", "Blackwell"},
        {"sm_120a", "Blackwell, architecture-specific"},
        {"sm_121", "Blackwell"},
        {"sm_121a", "Blackwell, architecture-specific"},
    };
    return archs;
  }

  static const NVPTXTraits &get();

protected:
  // This target is built entirely from source in this repository. The only
  // closed component is the NVIDIA driver behind the PTX load boundary.
  bool isBaseTarget() const override { return true; }
};

} // namespace M::KGEN

#endif // KGEN_TARGET_NVPTX_NVPTXTRAITS_H
