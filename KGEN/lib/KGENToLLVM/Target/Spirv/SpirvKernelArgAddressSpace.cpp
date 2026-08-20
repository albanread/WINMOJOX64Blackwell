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
// Kernel pointer parameters must live in the global address space.
//
// Mojo's `Pointer` lowers to LLVM addrspace(0), which is right for the host
// and wrong at a kernel boundary. The SPIR-V backend maps addrspace(0) to the
// `Function` storage class, and a kernel parameter in `Function` storage is
// invalid: OpenCL requires kernel pointer arguments in CrossWorkgroup,
// Workgroup, UniformConstant or Generic, and `clSetKernelArg` has nothing to
// bind a Function-storage pointer to.
//
// The failure is silent and remote. Nothing rejects the module at emission,
// `clCreateProgramWithIL` accepts it, `clBuildProgram` succeeds, and then
// `clCreateKernel` returns CL_INVALID_PROGRAM (-5) -- an error that names the
// program, not the parameter. It also survives every structural bisect,
// because the defect is in the *types* of the parameters rather than in any
// instruction a stripping pass can remove; and it never shows up in a
// hand-written control module, because nobody hand-writes a Function-storage
// kernel argument. See DRAGONMAX-JOURNAL.md, 2026-08-20.
//
// So this pass promotes addrspace(0) pointer parameters of SPIR_KERNEL
// functions to addrspace(1) -- CrossWorkgroup, the OpenCL global address
// space -- and propagates that through the pointer arithmetic derived from
// them. It is conservative: it scans a function's full use closure first and
// promotes nothing unless every use is one it can retype.
//
//===----------------------------------------------------------------------===//

#include "SpirvKernelArgAddressSpace.h"

#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/SetVector.h"

using namespace mlir;

namespace M::KGEN {
namespace {

/// The OpenCL global address space, which the LLVM SPIR-V backend maps to the
/// CrossWorkgroup storage class. Its counterpart addrspace(0) maps to
/// Function, which is what makes the promotion necessary.
constexpr unsigned kCrossWorkgroupAS = 1;

/// Whether `type` is a pointer in the default address space, i.e. one that
/// would reach the backend as `Function` storage.
bool isDefaultAS(Type type) {
  auto ptr = dyn_cast<LLVM::LLVMPointerType>(type);
  return ptr && ptr.getAddressSpace() == 0;
}

/// Collects every value derived from `roots` by pointer arithmetic, refusing
/// the whole set if any use cannot be retyped.
///
/// Refusing wholesale rather than promoting what it can is the point: a
/// half-promoted function is a type error at best and a wrong address space on
/// one access at worst, and the second of those is exactly the class of bug
/// this pass exists to remove.
LogicalResult collectDerived(ArrayRef<Value> roots,
                             llvm::SetVector<Value> &derived,
                             Operation *&offender) {
  SmallVector<Value> worklist(roots.begin(), roots.end());
  derived.insert(roots.begin(), roots.end());

  while (!worklist.empty()) {
    Value value = worklist.pop_back_val();
    for (Operation *user : value.getUsers()) {
      // Reads and writes through the pointer are address-space agnostic: the
      // operand type carries the space and the result type does not mention
      // it, so nothing needs retyping.
      if (isa<LLVM::LoadOp, LLVM::StoreOp, LLVM::AtomicRMWOp,
              LLVM::AtomicCmpXchgOp, LLVM::AddrSpaceCastOp, LLVM::PtrToIntOp>(
              user))
        continue;

      // Pointer arithmetic and pointer-to-pointer casts carry the address
      // space into their result, so the result has to move with the operand.
      if (isa<LLVM::GEPOp, LLVM::BitcastOp>(user)) {
        Value result = user->getResult(0);
        if (!isDefaultAS(result.getType())) {
          offender = user;
          return failure();
        }
        if (derived.insert(result))
          worklist.push_back(result);
        continue;
      }

      // Anything else -- a call, a select, a stored-through-a-struct -- would
      // need its own reasoning about which operand the space flows to.
      offender = user;
      return failure();
    }
  }
  return success();
}

/// Promotes one kernel's addrspace(0) pointer parameters to addrspace(1).
///
/// Returns whether anything changed. Emits a warning and changes nothing when
/// the use closure contains something it cannot retype, so a kernel this pass
/// does not understand still compiles -- and still fails at `clCreateKernel`,
/// which is no worse than before and is now accompanied by a diagnostic
/// saying why.
bool promoteKernel(LLVM::LLVMFuncOp func) {
  if (func.isExternal())
    return false;

  LLVM::LLVMFunctionType fnType = func.getFunctionType();
  SmallVector<Type> params(fnType.getParams().begin(),
                           fnType.getParams().end());

  Block &entry = func.getBody().front();
  SmallVector<Value> roots;
  SmallVector<unsigned> promotedIndices;
  MLIRContext *ctx = func.getContext();
  Type globalPtr = LLVM::LLVMPointerType::get(ctx, kCrossWorkgroupAS);

  for (auto [index, param] : llvm::enumerate(params)) {
    if (!isDefaultAS(param))
      continue;
    promotedIndices.push_back(index);
    roots.push_back(entry.getArgument(index));
  }
  if (roots.empty())
    return false;

  llvm::SetVector<Value> derived;
  Operation *offender = nullptr;
  if (failed(collectDerived(roots, derived, offender))) {
    func.emitWarning()
        << "kernel pointer arguments left in the default address space: '"
        << offender->getName()
        << "' consumes one in a way this pass cannot retype. The kernel will "
           "emit with Function-storage parameters and clCreateKernel will "
           "reject it with CL_INVALID_PROGRAM";
    return false;
  }

  // Nothing above this line mutates, so the refusal path above is total.
  for (unsigned index : promotedIndices)
    params[index] = globalPtr;
  func.setFunctionTypeAttr(TypeAttr::get(LLVM::LLVMFunctionType::get(
      fnType.getReturnType(), params, fnType.isVarArg())));
  for (Value value : derived)
    value.setType(globalPtr);
  return true;
}

struct SpirvKernelArgAddressSpacePass
    : public PassWrapper<SpirvKernelArgAddressSpacePass,
                         OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(SpirvKernelArgAddressSpacePass)

  StringRef getArgument() const override {
    return "spirv-kernel-arg-address-space";
  }

  StringRef getDescription() const override {
    return "Promote SPIR_KERNEL pointer parameters to the global address "
           "space";
  }

  void runOnOperation() override {
    getOperation().walk([](LLVM::LLVMFuncOp func) {
      if (func.getCConv() == LLVM::cconv::CConv::SPIR_KERNEL)
        (void)promoteKernel(func);
    });
  }
};

} // namespace

std::unique_ptr<Pass> createSpirvKernelArgAddressSpacePass() {
  return std::make_unique<SpirvKernelArgAddressSpacePass>();
}

} // namespace M::KGEN
