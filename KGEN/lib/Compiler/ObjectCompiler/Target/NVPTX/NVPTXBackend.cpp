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
// LLVM NVPTX backend for Windows. It emits PTX rather than invoking a CUDA
// compiler: PTX is the IR layer below CUDA source and the NVIDIA driver owns
// the final device-specific JIT at load time.
//
//===----------------------------------------------------------------------===//

#include "NVPTXBackend.h"

#include "KGEN/Compiler/SaveAsmOutput.h"
#include "KGEN/ToolCommon/CompilationOptions.h"
#include "Target/NVPTX/NVPTXTraits.h"
#include "LLVM/Transforms/SetFunctionAttributes.h"

#include "llvm/IR/Attributes.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Module.h"

#include <limits>
#include <tuple>

namespace M::KGEN {

const TargetTraits *NVPTXBackend::traits() const { return &NVPTXTraits::get(); }

void NVPTXBackend::reorderLinkedModuleFunctions(
    llvm::Module &module,
    const llvm::StringMap<unsigned> &originalOrder) const {
  auto rank = [&originalOrder](const llvm::Function &function) {
    if (function.isDeclaration())
      return std::tuple{1U, 0U};
    auto iter = originalOrder.find(function.getName());
    unsigned order = iter == originalOrder.end()
                         ? std::numeric_limits<unsigned>::max()
                         : iter->second;
    return std::tuple{0U, order};
  };
  module.getFunctionList().sort(
      [&rank](const llvm::Function &lhs, const llvm::Function &rhs) {
        return rank(lhs) < rank(rhs);
      });
}

void NVPTXBackend::addPipelineStartPasses(
    llvm::ModulePassManager &mpm, const CompilationOptions &options) const {
  mpm.addPass(SetFunctionAttributes());
}

void NVPTXBackend::attachCodegenAttributes(llvm::Function *kernelEntry) const {
  // CUDA does not support recursive kernel entry functions. This matches the
  // attribute Clang applies to CUDA kernels before NVPTX code generation.
  kernelEntry->addFnAttr(llvm::Attribute::NoRecurse);
}

ErrorOr<BufferRef> NVPTXBackend::emitAssembly(llvm::Module &module,
                                              EmitContext &ctx) const {
  WriteableBufferRef buf = WriteableBuffer::get();
  if (ErrorOrSuccess error =
          ctx.runLlc(module, *buf, /*createObjectFile=*/false)) {
    return Error(llvm::Twine(error.getError()) +
                 ", LLVM NVPTX failed to emit PTX");
  }

  if (!ctx.options.saveTempsPrefix.empty()) {
    llvm::StringRef ptx(buf->getBufferStart(), buf->getBufferSize());
    if (mlir::failed(writeBytesToTempWithHash(
            ctx.options.saveTempsPrefix,
            NVPTXTraits::get().getAsmExtension().str(), ptx)))
      return Error("failed to save PTX to saveTempsPrefix");
  }
  return buf;
}

ErrorOr<BufferRef> NVPTXBackend::emitObject(llvm::Module &module,
                                            EmitContext &ctx) const {
  // KGEN's device-function consumer accepts assembly bytes. Returning PTX here
  // as well keeps file/object emission at the same driver-JIT boundary and
  // avoids introducing ptxas or nvJitLink as compiler build dependencies.
  return emitAssembly(module, ctx);
}

ErrorOr<BufferRef>
NVPTXBackend::createArchive(llvm::MutableArrayRef<BufferRef> objects,
                            llvm::StringRef moduleName,
                            EmitContext &ctx) const {
  return Error("NVPTXBackend::createArchive is not wired");
}

namespace {
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wglobal-constructors"
RegisterTargetBackend<NVPTXBackend> registerNVPTXBackend;
#pragma GCC diagnostic pop
} // namespace

} // namespace M::KGEN
