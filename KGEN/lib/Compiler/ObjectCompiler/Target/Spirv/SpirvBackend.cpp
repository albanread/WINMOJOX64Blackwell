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

#include "SpirvBackend.h"

#include "KGEN/Compiler/SaveAsmOutput.h"
#include "KGEN/ToolCommon/CompilationOptions.h"
#include "Target/Spirv/SpirvTraits.h"

#include "llvm/IR/Module.h"
#include <cstring>
#include "llvm/Support/Path.h"

namespace M::KGEN {

const TargetTraits *SpirvBackend::traits() const { return &SpirvTraits::get(); }

ErrorOr<BufferRef> SpirvBackend::emitAssembly(llvm::Module &module,
                                              EmitContext &ctx) const {
  WriteableBufferRef buf = WriteableBuffer::get();
  if (ErrorOrSuccess error =
          ctx.runLlc(module, *buf, /*createObjectFile=*/false)) {
    return Error(Twine(error.getError()) +
                 ", llc (SPIR-V backend) failed to emit SPIR-V assembly");
  }

  if (!ctx.options.saveTempsPrefix.empty()) {
    StringRef toEmit(buf->getBufferStart(), buf->getBufferSize());
    if (mlir::failed(writeBytesToTempWithHash(
            ctx.options.saveTempsPrefix,
            SpirvTraits::get().getAsmExtension().str(), toEmit)))
      return Error("failed to save SPIR-V asm to saveTempsPrefix");
  }
  return buf;
}

ErrorOr<BufferRef> SpirvBackend::emitObject(llvm::Module &module,
                                            EmitContext &ctx) const {
  WriteableBufferRef codeBuf = WriteableBuffer::get();
  if (ErrorOrSuccess error =
          ctx.runLlc(module, *codeBuf, /*createObjectFile=*/true)) {
    return Error(Twine(error.getError()) +
                 ", llc (SPIR-V backend) failed to emit a SPIR-V module");
  }

  // The SPIR-V binary is the deliverable: the DragonMax runtime hands it to
  // the Qualcomm driver compiler at kernel-load time. Deliberately NOT routed
  // through ctx.linkObject, which links host objects into the host image - a
  // .spv inside the host .so would load as garbage.
  //
  // Validate the magic before returning: a misconfigured LLVM build (SPIRV
  // backend absent, llc falling back elsewhere) would otherwise surface much
  // later as an inscrutable driver error inside clCreateProgramWithIL.
  static constexpr char kMagic[4] = {0x03, 0x02, 0x23, 0x07};
  if (codeBuf->getBufferSize() < 4 ||
      memcmp(codeBuf->getBufferStart(), kMagic, 4) != 0) {
    return Error("llc output is not a SPIR-V module (bad magic); was LLVM "
                 "built with the SPIRV backend? (see BACKENDS in "
                 "bazel/public-patches/llvm_project.bzl)");
  }

  return BufferRef::take(codeBuf.release());
}

ErrorOr<BufferRef>
SpirvBackend::createArchive(llvm::MutableArrayRef<BufferRef> objects,
                            llvm::StringRef moduleName,
                            EmitContext &ctx) const {
  // Mirrors HostBackend: the archive flow is not routed through backends yet.
  return Error("SpirvBackend::createArchive is not wired");
}

namespace {
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wglobal-constructors"
RegisterTargetBackend<SpirvBackend> registerSpirvBackend;
#pragma GCC diagnostic pop
} // namespace

} // namespace M::KGEN
