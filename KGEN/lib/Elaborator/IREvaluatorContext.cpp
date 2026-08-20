//===----------------------------------------------------------------------===//
// Copyright (c) 2026, Modular Inc. All rights reserved.
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

#include "IREvaluatorContext.h"
#include "ElaboratorHelper.h"
#include "KGEN/Interpreter/InterpreterState.h"
#include "KGEN/KGENDialect/KGENAttrs.h"
#include "KGEN/KGENDialect/KGENTypes.h"
#include "KGEN/KGENDialect/ParameterEvaluator.h"
#include "KGEN/POPDialect/POPAttrs.h"
#include "KGEN/POPDialect/POPTypes.h"
#include "KGEN/POPDialect/POPUtils.h"
#include "KGEN/Support/Configuration.h"
#include "KGEN/Support/NameMangling.h"
#include "KGEN/TransformUtils/ManglingUtils.h"
#include "Support/Compiler/DiagnosticHandler.h"
#include "Support/StringExtras.h"
#include "mlir/Support/DebugStringHelper.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/ScopeExit.h"

#include "llvm/ADT/StringExtras.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/SHA256.h"

#include "sqlite3.h"

#include <mutex>

using namespace M;
using namespace KGEN;

//===----------------------------------------------------------------------===//
// Utils
//===----------------------------------------------------------------------===//

SymbolConstantAttr KGEN::extractSymbolConstantAttr(TypedAttr attr) {
  if (auto literal = dyn_cast<FuncLiteralTypeGeneratorType>(attr.getType()))
    return literal.getSymbolConstantAttr();
  if (auto literal = dyn_cast<FuncLiteralType>(attr.getType())) {
    auto funcSymbol = cast<FuncSymbolAttr>(literal.getFuncLiteral());
    return SymbolConstantAttr::get(
        funcSymbol.getSymbol(),
        FuncTypeGeneratorType::get({}, funcSymbol.getType(), nullptr),
        funcSymbol.getParamValues());
  }
  if (auto genSymbol = dyn_cast<GeneratorAttr>(attr)) {
    assert(genSymbol.getInputParamTypes().empty());
    auto funcSymbol = cast<FuncSymbolAttr>(genSymbol.getBody());
    return SymbolConstantAttr::get(
        funcSymbol.getSymbol(),
        FuncTypeGeneratorType::get({}, funcSymbol.getType(), nullptr),
        funcSymbol.getParamValues());
  }

  return dyn_cast<SymbolConstantAttr>(attr);
}

ErrorTreeOr<OffloadFunc> KGEN::extractOffloadFunc(CompileOffloadOp op,
                                                  mlir::SymbolTable &symtab) {
  Location loc = op.getLoc();
  SymbolConstantAttr symbol = extractSymbolConstantAttr(op.getFuncAttr());
  if (!symbol) {
    return ErrorTree(loc, "'compile_offload' func argument did not resolve to "
                          "a concrete function");
  }

  if (!symbol.getType().isFullyBound()) {
    std::string errMsg;
    llvm::raw_string_ostream os(errMsg);
    os << "'compile_offload' func is not fully bound: "
       << symbol.getSymbol().getLeafReference().getValue() << " missing "
       << symbol.getType().getInputParamTypes().size()
       << " parameter binding(s)";
    return ErrorTree(loc, errMsg);
  }

  auto generator = symtab.lookup<GeneratorOp>(
      cast<FlatSymbolRefAttr>(symbol.getSymbol()).getAttr());
  if (!generator) {
    std::string errMsg;
    llvm::raw_string_ostream os(errMsg);
    os << "compile_offload must reference a valid GeneratorOp, but got "
       << symbol.getSymbol().getLeafReference().getValue();
    return ErrorTree(loc, errMsg);
  }

  return OffloadFunc{symbol, generator};
}

//===----------------------------------------------------------------------===//
// ImplNodeBase
//===----------------------------------------------------------------------===//

void ImplNodeBase::initialize(InstantiatedOpInterface inst,
                              ParameterUseDefGraph &&graph) {
  this->inst = inst;
  this->paramGraph = std::move(graph);
}

//===----------------------------------------------------------------------===//
// ParamNodeBase
//===----------------------------------------------------------------------===//

AsyncValueRef<Chain> ParamNodeBase::copy() const { return paramCh.copy(); }

StringAttr ParamNodeBase::getMangledName() {
  // Check cached result.
  if (const void *namePtr = mangledName.load())
    return StringAttr::getFromOpaquePointer(namePtr);

  // Bind all parameter values in this scope.
  ArrayRef<TypedAttr> inputParamValues = inputParams.getValue();
  [[maybe_unused]] ArrayRef<ParamDeclAttr> inputParamDecls =
      gen.getInputParams();
  assert(inputParamValues.size() == inputParamDecls.size() &&
         "incorrect # input parameter values");
  std::string baseName = mangleParameterValues(gen, inputParamValues);
  StringAttr name = StringAttr::get(gen->getContext(), baseName);

  const void *existing = nullptr;
  if (mangledName.compare_exchange_strong(existing, name.getAsOpaquePointer()))
    return name;
  return StringAttr::getFromOpaquePointer(existing);
}

FailureOr<TypedAttr> IREvaluatorContext::evaluateGetLinkageNameAttr(
    GetLinkageNameAttr getLinkageNameAttr) {
  TargetInfoAttr target =
      cast<TargetParamAttr>(getLinkageNameAttr.getTarget()).getTarget();

  ErrorTreeOr<StringAttr> nameOrError = evaluateMangledName(
      getLinkageNameAttr.getFunc(),
      /*sanitize=*/target.isGPU(), *errorLoc, "get_linkage_name");

  if (nameOrError.isError()) {
    emitError(nameOrError.takeError());
    return failure();
  }

  StringAttr mangledName = nameOrError.takeValue();

  if (!mangledName)
    return TypedAttr(); // Not ready yet — signal retry.

  return {
      StringAttr::get(mangledName.getValue(), getLinkageNameAttr.getType())};
}

FailureOr<TypedAttr> IREvaluatorContext::evaluateGetSourceNameAttr(
    GetSourceNameAttr getSourceNameAttr) {
  auto symbol = extractSymbolConstantAttr(getSourceNameAttr.getFunc());
  if (!symbol) {
    emitError({*errorLoc, "'get_source_name' function argument did not resolve "
                          "to a concrete function"});
    return failure();
  }

  auto func = getGenerator(symbol.getSymbol());

  std::optional<StringRef> sourceName = func.getSourceName();
  if (!sourceName) {
    emitError({*errorLoc, "function '" +
                              symbol.getSymbol().getLeafReference().getValue() +
                              "' has no source name"});
    return failure();
  }
  return {StringAttr::get(*sourceName, getSourceNameAttr.getType())};
}

static TypedAttr getElementTypeFromPointer(TypedAttr typeValue) {
  auto typeParam = dyn_cast<TypeParamAttr>(typeValue);
  if (!typeParam)
    return {};
  auto pointerType = dyn_cast<PointerType>(typeParam.getTypeValue());
  if (!pointerType)
    return {};
  auto typeValueType = dyn_cast<TypeValueType>(pointerType.getElementType());
  if (!typeValueType)
    return {};
  return typeValueType.getTypeValue();
}

FailureOr<TypedAttr>
IREvaluatorContext::evaluateGetTypeNameAttr(GetTypeNameAttr getTypeNameAttr) {
  auto qualifiedBuiltins =
      dyn_cast<SIMDAttr>(getTypeNameAttr.getQualifiedBuiltins());
  if (!qualifiedBuiltins) {
    emitError({*errorLoc, "'get_type_name' name did not narrow to a constant"});
    return failure();
  }

  bool qualified = qualifiedBuiltins.getAsBool();
  TypedAttr typeValue = getTypeNameAttr.getTypeValue();
  bool isRef = false;
  if (TypedAttr inner = getElementTypeFromPointer(typeValue)) {
    typeValue = inner;
    isRef = true;
  }

  TypedAttr typeRef = getTypeRefForTypeValueIfResolved(typeValue);
  if (auto instanceRef = dyn_cast_if_present<TypeInstanceRefAttr>(typeRef)) {
    std::string name;
    llvm::raw_string_ostream os(name);
    if (isRef)
      os << "ref[";
    os << stringifyTypeInstanceRef(instanceRef, qualified);
    if (isRef)
      os << "]";
    return {StringAttr::get(name, getTypeNameAttr.getType())};
  }

  emitError({*errorLoc, "'get_type_name' requires a concrete type, got " +
                            mlir::debugString(getTypeNameAttr)});
  return failure();
}

FailureOr<TypedAttr>
IREvaluatorContext::evaluateIsStructTypeAttr(IsStructTypeAttr attr) {
  MLIRContext *ctx = attr.getContext();

  if (auto typeParam = sugarDynCast<TypeParamAttr>(attr.getTypeValue())) {
    if (sugarDynCast<KGEN::StructType>(typeParam.getTypeValue()))
      return {BoolAttr::get(ctx, true)};
  }

  // Unwrap the type value to get the underlying reference.
  TypedAttr typeRef = getTypeRefForTypeValueIfResolved(attr.getTypeValue());

  // Check if it's a TypeInstanceRefAttr (concrete type instance).
  // Returns false for:
  // - MLIR primitive types (index, i64, etc.) - these are TypeAttr, not refs
  // - TypeGeneratorRefAttr (unbound generics) - can't reflect on unbound types
  // - nullptr/unresolved types
  auto instanceRef = dyn_cast_if_present<TypeInstanceRefAttr>(typeRef);
  if (!instanceRef)
    return {BoolAttr::get(ctx, false)};

  // Look up the symbol to verify it's a StructGeneratorOp.
  // Returns false for non-struct type generators (e.g., trait types).
  ParamNodeBase *genNode = lookupParamNodeBase(instanceRef.getSymbol());
  if (!isa<StructGeneratorOp>(genNode->gen))
    return {BoolAttr::get(ctx, false)};

  return {BoolAttr::get(ctx, true)};
}

FailureOr<TypedAttr>
IREvaluatorContext::evaluateFnTypeIsCABIAttr(FnTypeIsCABIAttr attr) {
  MLIRContext *ctx = attr.getContext();

  // After generic parameter substitution, typeValue is a TypeParamAttr.
  // TypeParamAttr.getMlirType() holds the concrete FuncTypeGeneratorType
  // (including its FnEffects bits such as CABI). For non-function types,
  // return false.
  TypedAttr typeValue = SugarAttr::strip(attr.getTypeValue());
  auto typeParam = dyn_cast<TypeParamAttr>(typeValue);
  if (!typeParam)
    return {BoolAttr::get(ctx, false)};

  auto funcType = dyn_cast<FuncTypeGeneratorType>(typeParam.getMlirType());
  if (!funcType)
    return {BoolAttr::get(ctx, false)};

  return {BoolAttr::get(ctx, funcType.getBody().isCABI())};
}

//===----------------------------------------------------------------------===//
// Base Type Reflection Evaluators
//===----------------------------------------------------------------------===//

/// Helper to get the base type name from a type reference.
/// Returns the unqualified name from the generator's valueDomainType.
/// For non-struct types, returns null.
StringAttr IREvaluatorContext::getBaseTypeName(TypedAttr typeRef) {
  typeRef = SugarAttr::strip(typeRef);

  // Helper to extract unqualified name from a StructGeneratorOp.
  auto getNameFromStructGen = [](StructGeneratorOp structGen) -> StringAttr {
    Type valueDomainType = structGen.getValueDomainType();
    if (auto structInstType = dyn_cast<StructInstanceType>(valueDomainType)) {
      StringRef fullName = structInstType.getName().getValue();
      // Strip module qualification (e.g., "std::builtin::int::Int" -> "Int")
      size_t lastSep = fullName.rfind("::");
      StringRef baseName = (lastSep != StringRef::npos)
                               ? fullName.substr(lastSep + 2)
                               : fullName;
      return StringAttr::get(structGen.getContext(), baseName);
    }
    return nullptr;
  };

  // For TypeInstanceRefAttr, look up the generator through the evaluator.
  if (auto instanceRef = dyn_cast<TypeInstanceRefAttr>(typeRef)) {
    ParamNodeBase *genNode = lookupParamNodeBase(instanceRef.getSymbol());
    if (genNode && genNode->gen) {
      if (auto structGen =
              dyn_cast<StructGeneratorOp>(genNode->gen.getOperation()))
        return getNameFromStructGen(structGen);
    }
    return nullptr;
  }

  // For TypeGeneratorRefAttr, look up the generator.
  if (auto genRef = dyn_cast<TypeGeneratorRefAttr>(typeRef)) {
    GeneratorOp gen = getGenerator(genRef.getSymbol());
    if (auto structGen = dyn_cast<StructGeneratorOp>(*gen))
      return getNameFromStructGen(structGen);
    return nullptr;
  }

  return nullptr;
}

FailureOr<TypedAttr>
IREvaluatorContext::evaluateGetBaseTypeNameAttr(GetBaseTypeNameAttr attr) {
  // Get the underlying type reference.
  // Returns null for primitives (index, i64, etc.) since they're not type refs.
  TypedAttr typeRef = getTypeRefForTypeValueIfResolved(attr.getTypeValue());

  // For primitives or non-struct types, return "<unknown>".
  if (!typeRef)
    return {StringAttr::get("<unknown>", attr.getType())};

  // Get the base type name from the generator's valueDomainType.
  StringAttr name = getBaseTypeName(typeRef);
  if (!name)
    return {StringAttr::get("<unknown>", attr.getType())};

  return {StringAttr::get(name.getValue(), attr.getType())};
}

static void emitDiagnosticToStream(raw_ostream &os, Diagnostic &diag) {
  os << "\n" << diag.getLocation() << ": " << diag;
  for (Diagnostic &note : diag.getNotes())
    emitDiagnosticToStream(os, note);
}

FailureOr<TypedAttr>
IREvaluatorContext::evaluateCompileAssemblyAttr(CompileAssemblyAttr attr) {
  // Cheeky copy. The state of the symbol table right at this moment is
  // sufficient to produce a standalone object for the generator being JIT'd.
  // Slice out a standalone module to re-elaborate with the new target.

  TargetInfoAttr target = cast<TargetParamAttr>(attr.getTarget()).getTarget();
  EmitAs emissionKind = cast<EmitAsAttr>(attr.getEmissionKind()).getValue();
  StringRef emissionOptionsStr =
      cast<StringAttr>(attr.getEmissionOptions()).getValue();
  bool propagateError = cast<BoolAttr>(attr.getPropagateError()).getValue();
  SymbolConstantAttr symbol = extractSymbolConstantAttr(attr.getFunc());
  ErrorTreeOr<StringAttr> nameOrError = evaluateMangledName(
      symbol, /*sanitize=*/false, *errorLoc, "compile_assembly");
  if (nameOrError.isError()) {
    getParentNode()->setToError(nameOrError.takeError());
    return failure();
  }

  StringAttr name = nameOrError.takeValue();

  if (!name)
    return TypedAttr(); // Not ready yet — signal retry.

  GeneratorOp func = getGenerator(symbol.getSymbol());

  // Construct the expected result type.
  MLIRContext *ctx = attr.getContext();
  Builder b(ctx);
  auto noneType = KGEN::NoneType::get(ctx);
  auto populateFnType = FuncTypeGeneratorType::get(
      /*inputParamTypes=*/{},
      b.getFunctionType(PointerType::get(noneType), noneType),
      {ArgConvention::ReadReg}, FnEffects().setCapturing());

  // Specialize the generator with another target by slicing it and its
  // transitive dependencies out of the IR and re-invoking the elaborator. If it
  // turns out that the specialization has more than one implementation, then
  // the elaborator invocation will fail due to multiple implementations of a
  // primary generator, and the functor will return an error.

  // Parse the emission options from a comma separated list of values.
  SmallVector<StringRef> emissionOptions;
  emissionOptionsStr.split(emissionOptions, /*Separator=*/",",
                           /*MaxSplit=*/-1, /*KeepEmpty=*/false);

  // Capture the diagnostics that may be emitted.
  DiagnosticHandler handler(ctx);
  ErrorOr<CrossDeviceFunction> closure = compileAsm(
      ctx, func, symbol, name, target, emissionKind, emissionOptions);
  handler.release();

  if (closure.isError()) {
    // Emit all the errors now.
    if (!propagateError) {
      handler.emitDiagnostics([&](Diagnostic &diag) {
        ctx->getDiagEngine().emit(std::move(diag));
      });
      emitError({*errorLoc, closure.takeError()});
      return failure();
    }
    // Concat all the errors together and return it as a variant.
    std::string error;
    llvm::raw_string_ostream os(error);
    os << closure.getError();
    handler.emitDiagnostics(
        [&](Diagnostic &diag) { emitDiagnosticToStream(os, diag); });
    // Note: return -1 to indicate an error state.
    return {StructAttr::get({StringAttr::get(os.str(), StringType::get(ctx)),
                             b.getIndexAttr(-1),
                             UninitMemAttr::get(populateFnType)})};
  }

  auto populate = cast<FuncOp>(closure->populateCapturesFn.release());
  auto populateFnRef = SymbolConstantAttr::get(populate);
  addDeferredFunction(populate);
  return {
      StructAttr::get({closure->contents, b.getIndexAttr(closure->numCaptures),
                       populateFnRef})};
}

/// Resolve the linkageName of @p gen to a concrete string for the given
/// symbol instantiation.
///
/// Precondition: @p gen must have a linkageName attribute. Call this only
/// when gen.getLinkageNameAttr() is non-null.
///
/// Returns:
///   - failure()          — linkage name could not be resolved
///   - success(null)      — not ready yet; a blocker has been registered
///                          and the caller should retry
///   - success(TypedAttr) — the resolved linkage name expression
static FailureOr<TypedAttr>
evaluateLinkageName(GeneratorOp gen, SymbolConstantAttr symbol,
                    ParameterEvaluationContext *evalCtx) {
  assert(gen.getLinkageNameAttr() &&
         "evaluateLinkageName requires gen to have a linkageName attribute");
  // Fall back to evaluating the generator's linkageName expression directly.
  LinkageNameAttr genLinkageName =
      dyn_cast_if_present<LinkageNameAttr>(gen.getLinkageNameAttr());
  if (!genLinkageName)
    return failure();

  // Substitute the generator's parameters with the symbol's concrete values.
  // getReboundAttribute evaluates any residual parametric expressions —
  // including DataToStr — via the evaluateContextSpecific hook in the
  // evaluation context, which is always the concrete IREvaluator subclass.
  ParameterEvaluator tempEval(gen.getInputParams(), symbol.getParamValues());
  tempEval.setEvaluationContext(evalCtx);
  Attribute rebound = tempEval.getReboundAttribute(genLinkageName);
  if (!rebound)
    return TypedAttr(); // not-ready: a sub-dependency is still being elaborated
  if (auto lna = dyn_cast_if_present<LinkageNameAttr>(rebound))
    if (auto prefix = dyn_cast<StringAttr>(lna.getName()))
      return TypedAttr(StringAttr::get(prefix.getValue(),
                                       StringType::get(gen.getContext())));
  return failure();
}

std::optional<ErrorTreeOr<SymbolConstantAttr>>
IREvaluatorContext::resolveTransparentThunkCallee(GeneratorOp generator,
                                                  SymbolConstantAttr symbol,
                                                  Location loc) {
  auto calleeExpr =
      generator->getAttrOfType<TypedAttr>(kTransparentThunkCalleeExprAttr);
  if (!calleeExpr)
    return std::nullopt;

  // Save/restore the error-capture state. The helper may be invoked while an
  // outer evaluation (e.g. `concretizeParameterExpr`) already has its own
  // `emitError` lambda installed; clobbering it without restoring would
  // leave the outer evaluation with a dangling lambda after we return.
  std::function<void(ErrorTree)> savedEmitError = std::move(emitError);
  std::optional<Location> savedErrorLoc = errorLoc;
  auto restore = llvm::scope_exit([&] {
    emitError = std::move(savedEmitError);
    errorLoc = savedErrorLoc;
  });

  errorLoc = loc;
  std::optional<ErrorTree> error;
  emitError = [&](ErrorTree err) { error = std::move(err); };

  // Plug `this` in as the evaluation context so the rebind dispatches
  // parameter operators through the subclass's `evaluateContextSpecific`
  // hook (and routes any materialization errors back through `emitError`).
  ParameterEvaluator evaluator(generator.getInputParams(),
                               symbol.getParamValues());
  evaluator.setEvaluationContext(this);
  Attribute rebound =
      extractSymbolConstantAttr(evaluator.getReboundAttribute(calleeExpr));

  if (error)
    return ErrorTreeOr<SymbolConstantAttr>(std::move(*error));
  if (!rebound)
    return ErrorTreeOr<SymbolConstantAttr>(SymbolConstantAttr());
  if (auto resolved = dyn_cast<SymbolConstantAttr>(rebound))
    return ErrorTreeOr<SymbolConstantAttr>(resolved);

  // Defensive: the callee expression rebound to a non-symbol attr. A
  // well-formed `kgen.transparent_thunk_callee_expr` should always resolve to
  // a `SymbolConstantAttr`; reaching this branch means the attribute is
  // malformed (likely a compiler bug at the producer site). Surface as an
  // internal error rather than crashing in `cast`.
  return ErrorTreeOr<SymbolConstantAttr>(ErrorTree(
      loc, "internal error: transparent thunk callee expression resolved to "
           "non-symbol attr: " +
               mlir::debugString(rebound)));
}

/// Evaluate the mangled name of a function. Returns an empty StringAttr to
/// signal "not ready yet" (caller should retry).
ErrorTreeOr<StringAttr>
IREvaluatorContext::evaluateMangledName(TypedAttr symCst, bool sanitize,
                                        Location errorLoc,
                                        StringRef errorContext) {
  auto symbol = extractSymbolConstantAttr(symCst);
  if (!symbol) {
    return ErrorTree(errorLoc,
                     "'" + errorContext +
                         "' function argument did not resolve to a concrete "
                         "function");
  }

  if (!symbol.getType().isFullyBound()) {
    std::string errMsg;
    llvm::raw_string_ostream os(errMsg);
    os << "'" << errorContext << "' function is not fully bound: "
       << symbol.getSymbol().getLeafReference().getValue() << " missing "
       << symbol.getType().getInputParamTypes().size()
       << " parameter binding(s)";
    return ErrorTree(errorLoc, errMsg);
  }

  GeneratorOp generator = getGenerator(symbol.getSymbol());
  if (!generator) {
    std::string errMsg;
    llvm::raw_string_ostream os(errMsg);
    os << "'" << errorContext
       << "' expected a valid generator reference, but got "
       << symbol.getSymbol().getLeafReference().getValue() << "\n";
    return ErrorTree(errorLoc, errMsg);
  }

  // For a transparent thunk, look through to the wrapped function.
  // `processCompileOffload` does the same redirect on the offload side — the
  // wrapped function is what gets compiled, so its mangled name is what the
  // host needs to look up.
  if (auto thunkCallee =
          resolveTransparentThunkCallee(generator, symbol, errorLoc)) {
    if (thunkCallee->isError())
      return thunkCallee->takeError();
    SymbolConstantAttr calleeSym = thunkCallee->takeValue();
    if (!calleeSym)
      return StringAttr(); // not ready: retry
    return evaluateMangledName(calleeSym, sanitize, errorLoc, errorContext);
  }

  if (generator.getLinkageNameAttr()) {
    // @__name is present: evaluate the (possibly parametric) name expression.
    FailureOr<TypedAttr> result = evaluateLinkageName(generator, symbol, this);
    if (failed(result)) {
      return ErrorTree(
          {errorLoc,
           "'" + errorContext + "' failed to resolve linkage name for '" +
               symbol.getSymbol().getLeafReference().getValue() + "'"});
    }
    if (!*result)
      return StringAttr(); // retry
    auto resolved = dyn_cast<StringAttr>(*result);
    if (!resolved) {
      return ErrorTree(
          {errorLoc, "'" + errorContext +
                         "' linkage name did not resolve to a string for '" +
                         symbol.getSymbol().getLeafReference().getValue() +
                         "'"});
    }
    // symName is the auto-mangled wrapper symbol used as a hash input
    // (mangle=true). Always use mangleParameterValues so the host and offload
    // paths hash the same seed. renameFunctions calls applyLinkageName with
    // func.getSymName() - the concrete function's MLIR sym - which equals
    // mangleParameterValues for both constant and parametric linkage names.
    // Using the linkage name literal here instead would produce a different
    // hash whenever sym_name != literal, causing a runtime kernel-launch
    // failure.
    std::string symName =
        mangleParameterValues(generator, symbol.getParamValues());
    auto lna = cast<LinkageNameAttr>(generator.getLinkageNameAttr());
    return applyLinkageName(resolved, lna, sanitize, symName,
                            symbol.getType().getBody().getValues());
  }

  // No @__name: use the auto-mangled sym_name, optionally sanitized.
  StringAttr name = StringAttr::get(
      generator.getContext(),
      mangleParameterValues(generator, symbol.getParamValues()));
  if (sanitize)
    name = sanitizeSymbolToAlnum(name);
  return name;
}

FailureOr<TypedAttr> IREvaluatorContext::evaluateCompileOffloadClosureAttr(
    CompileOffloadClosureAttr compileOffloadClosureAttr) {
  // Create the signature and an empty body of the populate capture for offload
  // closures as part of elaboration step.
  // We currently only support capturing closure as a parameter. So this closure
  // has to be created during elaboration time as a compile time constant.
  // However, bundling offload compilation means
  // that the actual compilation of the offload functions will happen later
  // once all of them are seen and collected, and the actual body of this
  // closure will not be known until the offload function is compiled
  // (so that we know what needs to be captured).
  // We will generated the actual body of this closure later.

  // Slice out a standalone module to re-elaborate with the new target later.

  // compile_offload_closure attrs are compiler-generated; these invariants
  // must hold.
  auto closureSymbolForLookup =
      extractSymbolConstantAttr(compileOffloadClosureAttr.getFunc());
  assert(closureSymbolForLookup &&
         "compile_offload_closure func must resolve to a SymbolConstantAttr");
  assert(closureSymbolForLookup.getType().isFullyBound() &&
         "compile_offload_closure func must be fully bound");
  GeneratorOp generator = getGenerator(closureSymbolForLookup.getSymbol());
  assert(generator &&
         "compile_offload_closure must reference a valid GeneratorOp");

  // If `generator` is a transparent thunk, mirror what `processCompileOffload`
  // does and look through it to the wrapped function. The offload-side
  // `writeCaptureArgs` names the populate function body after the *redirected*
  // (user-kernel) generator, so this stub must be named the same way for the
  // fill step to match them up.
  if (auto thunkCallee = resolveTransparentThunkCallee(
          generator, closureSymbolForLookup, *errorLoc)) {
    if (thunkCallee->isError()) {
      emitError(thunkCallee->takeError());
      return failure();
    }
    SymbolConstantAttr calleeSym = thunkCallee->takeValue();
    if (!calleeSym)
      return TypedAttr(); // Not ready yet — signal retry.
    if (GeneratorOp calleeGen = getGenerator(calleeSym.getSymbol())) {
      generator = calleeGen;
      closureSymbolForLookup = calleeSym;
    }
  }

  // Construct the expected result type.
  MLIRContext *ctx = compileOffloadClosureAttr.getContext();
  auto noneType = KGEN::NoneType::get(ctx);

  // The location to use for generated code. Remove all debuginfo from it.
  Location loc = DebugInfo::stripDebugScopesRecursively(*errorLoc);

  // The expected signature is `fn(Pointer[None]) capturing -> None`.
  ImplicitLocOpBuilder bb(loc, ctx);
  auto nonePtr = PointerType::get(noneType);
  auto sig = FuncType::get(bb.getFunctionType(nonePtr, noneType),
                           ArgConvention::ReadReg, FnEffects().setCapturing());

  // Use the auto-mangled sym_name (NOT @__name) for the stub name. Each
  // distinct closure instantiation gets its own stub keyed by the pre-rename
  // sym, even when multiple instantiations share the same @__name value
  // (e.g. closures capturing uint32 vs uint64). writeCaptureArgs in the
  // offload compilation path names the populate function body using the same
  // pre-rename sym, so the fill step can match stub to body by name.
  std::string stubBaseName =
      mangleParameterValues(generator, closureSymbolForLookup.getParamValues());

  OwningOpRef<FuncOp> populateFunc =
      FuncOp::create(bb, bb.getStringAttr(stubBaseName + "_populate_captures"),
                     sig, InlineLevel::Always);

  auto populate = cast<FuncOp>(populateFunc.get());
  auto populateFnRef = SymbolConstantAttr::get(populate);
  addDeferredFunction(std::move(populateFunc));
  return {populateFnRef};
}

/// Print a KGENDType, following the naming scheme in the Mojo DType struct.
/// NOTE: It would be better to have custom type name printing that can be
/// implemented on the struct directly.
static void printDType(raw_ostream &os, KGENDType dtype, bool qualified) {
  if (qualified)
    os << "std.builtin.dtype.";
  os << "DType." << dtype.getAsString(/*libForm=*/true);
}

void IREvaluatorContext::printParamValue(raw_ostream &os, ParamDeclAttr decl,
                                         TypedAttr value,
                                         bool qualifiedBuiltins) {
  TypeSwitch<TypedAttr>(value)
      .Case<DTypeConstantAttr>([&](auto dtypeConstant) {
        printDType(os, dtypeConstant.getDType(), qualifiedBuiltins);
      })
      .Case<IntegerAttr>([&](auto intAttr) {
        // Print booleans nicely.
        if (intAttr.getType().isSignlessInteger(1))
          os << (intAttr.getValue().isZero() ? "False" : "True");
        else
          intAttr.print(os, /*elideType=*/true);
      })
      .Case<NoneAttr>([&](auto noneAttr) { os << "None"; })
      .Case<UnboundAttr>([&](auto unboundAttr) { os << "?"; })
      .Case<TypeParamAttr>([&](auto typeAttr) {
        if (auto typeValue = dyn_cast<TypeValueType>(typeAttr.getTypeValue())) {
          if (auto instanceRef =
                  dyn_cast<TypeInstanceRefAttr>(typeValue.getTypeValue())) {
            os << stringifyTypeInstanceRef(instanceRef, qualifiedBuiltins);
            return;
          }
        }
        if (TypedAttr inner = getElementTypeFromPointer(typeAttr)) {
          if (auto instanceRef = dyn_cast<TypeInstanceRefAttr>(inner)) {
            os << "ref["
               << stringifyTypeInstanceRef(instanceRef, qualifiedBuiltins)
               << "]";
            return;
          }
        }

        // We print a placeholder for anything we don't know how to print.
        // NOTE: We could consider just printing the mlir for anything else. For
        // now, this is a more conservative approach, since it prevents leaking
        // IR details.
        os << "<unprintable>";
      })
      .Case<StructAttr>([&](auto structAttr) {
        os << "{";
        llvm::interleaveComma(structAttr.getValues(), os, [&](TypedAttr value) {
          printParamValue(os, decl, value, qualifiedBuiltins);
        });
        os << "}";
      })
      .Case<MemRefAttr>([&](auto memRefAttr) {
        MemoryBlobAttr memory =
            memRefAttr.getModel().getMemory()[memRefAttr.getIndex()];
        if (MemoryHandleAttr handle = memory.getHandle(); handle.isString()) {
          // NOTE: these strings should be null terminated.
          os << '"' << StringRef(handle.getData(), handle.getSize()) << '"';
          return;
        }

        os << "<unprintable>";
      })
      .Case<KGEN::SIMDAttr>([&](auto simdAttr) {
        ArrayRef<KGEN::DTypeValue> values = simdAttr.getValues();
        KGENDType dType = *simdAttr.getType().getResolvedDType();
        KGEN::printDTypeValues(os, values, dType);
        // Don't print Bool as a SIMD type.
        if (!isScalarOf<KGENDType::kBool>(simdAttr.getType())) {
          os << " : ";
          if (qualifiedBuiltins)
            os << "std.builtin.simd.";
          os << "SIMD[";
          printDType(os, dType, qualifiedBuiltins);
          os << ", " << values.size() << "]";
        }
      })
      .Default([&](auto value) { os << "<unprintable>"; });
}

std::string
IREvaluatorContext::stringifyTypeInstanceRef(TypeInstanceRefAttr instanceRef,
                                             bool qualifiedBuiltins) {
  ParamNodeBase *genNode = lookupParamNodeBase(instanceRef.getSymbol());
  StructGeneratorOp genOp = cast<StructGeneratorOp>(genNode->gen);

  llvm::SmallDenseMap<llvm::StringRef, llvm::StringRef> eligibleBuiltins = {
      {"std::builtin::bool::Bool", "Bool"},
      {"std::builtin::int::Int", "Int"},
      {"std::collections::list::List", "List"},
      {"std::builtin::simd::SIMD", "SIMD"},
      {"std::collections::string::string::String", "String"},
      {"std::builtin::uint::UInt", "UInt"},
  };

  // Print the type name first. A few common types can be printed more tersely.
  /// NOTE: It would be better to have custom type name printing that can be
  /// implemented on the struct directly.
  std::string name = genOp.getSymName().str();
  if (!qualifiedBuiltins && name.starts_with("std::")) {
    if (auto it = eligibleBuiltins.find(name); it != eligibleBuiltins.end())
      name = it->second;
  }
  replaceAll(name, "::", ".");

  ArrayRef<TypedAttr> paramValues = genNode->inputParams.getValue();
  if (!paramValues.empty()) {
    std::string paramValuesStr;
    llvm::raw_string_ostream os(paramValuesStr);
    auto paramDecls = genOp.getInputParams();

    // If the type is parameterized, print the parameter values.
    llvm::interleaveComma(llvm::zip(paramDecls, paramValues), os,
                          [&](auto pair) {
                            auto [decl, value] = pair;
                            printParamValue(os, decl, value, qualifiedBuiltins);
                          });

    name += "[" + paramValuesStr + "]";
  }
  return name;
}

//===----------------------------------------------------------------------===//
// IREvaluatorContext
//===----------------------------------------------------------------------===//

IREvaluatorContext::IREvaluatorContext(EnvAttr env, MLIRContext *mlirCtx,
                                       InterpreterState *state)
    : env(env), state(state), mlirCtx(mlirCtx) {}

FailureOr<TypedAttr> IREvaluatorContext::evaluateGetEnv(ParamOperatorAttr op) {
  // Grab the module from the elaborator. This is a read operation of memory
  // that is not modified during elaboration, so no synchronization is needed.
  auto name = dyn_cast<StringAttr>(op.getOperands().front());
  if (!name) {
    emitError({*errorLoc, "'get_env' name did not narrow to a constant"});
    return failure();
  }

  // Get the `StringRef` out of the `StringAttr` because the latter comes with
  // a `StringType` type that makes pointer comparisons fails.
  ErrorOr<TypedAttr> result = env.queryValue(name.getValue(), op.getType());

  if (result.isError()) {
    emitError({*errorLoc, result.getError()});
    return failure();
  }

  return result.get();
}

//===----------------------------------------------------------------------===//
// Win32 metadata queries
//===----------------------------------------------------------------------===//
//
// The Win32 API surface is 18,000 functions over 15,000 structs and 8,000 COM
// interfaces, and all of it is already described precisely -- field offsets,
// struct sizes, vtable order, interface IIDs -- in a metadata database. The
// alternative to reading it here is generating megabytes of Mojo declarations
// and keeping them in sync by hand, which is a second source of truth and
// therefore a source of drift.
//
// Reading it during elaboration means a binding states one fact -- a name --
// and the compiler supplies the rest. A struct whose declaration disagrees
// with Windows fails to build instead of corrupting memory at the first call.
//
// The database is opened lazily and only if a query is actually evaluated, so
// a build that uses no Win32 metadata never touches it.

namespace {

/// A lazily-opened, read-only handle on the Win32 metadata database, shared
/// for the life of the process. Elaboration is concurrent, so the open is
/// guarded; the queries themselves are reads against an immutable file.
class WinKBDatabase {
public:
  /// Returns the shared instance, opening the database on first use.
  static WinKBDatabase &get() {
    static WinKBDatabase instance;
    return instance;
  }

  /// Run one query. Returns the error text on failure so the caller can put it
  /// in a diagnostic pointing at the source that asked.
  llvm::Expected<int64_t> queryInt(StringRef query, ArrayRef<StringRef> args);

  llvm::Expected<std::string> queryString(StringRef query,
                                          ArrayRef<StringRef> args);

private:
  WinKBDatabase() = default;
  llvm::Error openLocked();
  llvm::Expected<sqlite3_stmt *> prepare(StringRef query,
                                         ArrayRef<StringRef> args);

  std::mutex mutex;
  sqlite3 *db = nullptr;
  bool attempted = false;
  std::string openError;
  std::string openedPath;
  std::string cachedHash;
};

/// The queries this exposes, by the name Mojo passes as the first operand.
///
/// Each is stated once here rather than assembled from fragments: a binding
/// asks for "struct_size", not for SQL, so the schema stays an implementation
/// detail of the compiler and a metadata layout change is a one-line fix here
/// instead of a break in every caller.
struct WinKBQueryDef {
  StringRef name;
  unsigned argCount;
  StringRef sql;
};

constexpr StringRef kStructSizeSQL =
    "SELECT size_bits / 8 FROM types WHERE type_name = ?1 AND kind = 'struct'";
constexpr StringRef kStructAlignSQL =
    "SELECT align_bits / 8 FROM types WHERE type_name = ?1 AND kind = 'struct'";
constexpr StringRef kFieldOffsetSQL =
    "SELECT f.byte_offset FROM struct_fields f "
    "JOIN types t ON t.type_id = f.struct_type_id "
    "WHERE t.type_name = ?1 AND f.field_name = ?2";
constexpr StringRef kVtableIndexSQL =
    "SELECT m.vtable_index FROM interface_methods m "
    "JOIN types t ON t.type_id = m.interface_type_id "
    "WHERE t.type_name = ?1 AND m.method_name = ?2";
constexpr StringRef kInterfaceIIDSQL =
    "SELECT iid FROM types WHERE type_name = ?1 AND iid IS NOT NULL";
constexpr StringRef kFunctionDLLSQL =
    "SELECT dll_name FROM functions WHERE function_name = ?1";

// Named constants come from two tables. Plain #define-style values live in
// `constants`; flag and enumeration members live in `enum_members`, and the
// two namespaces overlap only rarely, so `constants` wins by ordinal.
//
// COALESCE(value_i64, value_u64) prefers the SIGNED reading, which is the one
// that survives narrowing in both directions: HKEY_LOCAL_MACHINE has to
// sign-extend to 0xFFFFFFFF80000002 as a pointer, while a flag mask such as
// 0x80000000 is narrowed by the caller's UInt32() and keeps its bits either
// way. Preferring the unsigned reading would break the first case silently.
constexpr StringRef kConstantValueSQL =
    "SELECT value FROM ("
    "  SELECT COALESCE(value_i64, value_u64) AS value, 0 AS rank"
    "    FROM constants WHERE constant_name = ?1"
    "     AND value_kind IN ('int', 'uint')"
    "  UNION ALL"
    "  SELECT COALESCE(value_i64, value_u64) AS value, 1 AS rank"
    "    FROM enum_members WHERE member_name = ?1"
    ") WHERE value IS NOT NULL ORDER BY rank LIMIT 1";
constexpr StringRef kConstantTextSQL =
    "SELECT value_text FROM constants "
    "WHERE constant_name = ?1 AND value_kind = 'string'";

constexpr StringRef kSchemaVersionSQL =
    "SELECT value FROM schema_meta WHERE key = 'schema_version'";

const WinKBQueryDef kQueries[] = {
    {"db_schema_version", 0, kSchemaVersionSQL},
    {"struct_size", 1, kStructSizeSQL},
    {"struct_align", 1, kStructAlignSQL},
    {"field_offset", 2, kFieldOffsetSQL},
    {"vtable_index", 2, kVtableIndexSQL},
    {"interface_iid", 1, kInterfaceIIDSQL},
    {"function_dll", 1, kFunctionDLLSQL},
    {"constant_value", 1, kConstantValueSQL},
    {"constant_text", 1, kConstantTextSQL},
};

llvm::Error WinKBDatabase::openLocked() {
  if (attempted)
    return openError.empty() ? llvm::Error::success()
                             : llvm::createStringError(llvm::inconvertibleErrorCode(),
                                                       openError);
  attempted = true;

  ErrorOr<MojoConfig> configOr = MojoConfig::open();
  if (configOr.isError()) {
    openError = "cannot read the Mojo configuration to locate the Win32 "
                "metadata database";
    return llvm::createStringError(llvm::inconvertibleErrorCode(), openError);
  }
  // The config owns the string, so copy it before the config goes out of scope.
  std::string path = configOr.get().getWinKBPath().str();
  if (path.empty()) {
    openError = "no Win32 metadata database is configured; set "
                "MODULAR_MOJO_MAX_WINKB_PATH to windows_api.db";
    return llvm::createStringError(llvm::inconvertibleErrorCode(), openError);
  }

  // Read-only, and never created: a missing database is a configuration error
  // to report, not an empty one to invent and then answer wrongly from.
  openedPath = path;
  int rc = sqlite3_open_v2(path.c_str(), &db, SQLITE_OPEN_READONLY,
                           nullptr);
  if (rc != SQLITE_OK) {
    openError = "cannot open the Win32 metadata database at '" + path +
                "': " + std::string(db ? sqlite3_errmsg(db) : "out of memory");
    if (db) {
      sqlite3_close(db);
      db = nullptr;
    }
    return llvm::createStringError(llvm::inconvertibleErrorCode(), openError);
  }
  return llvm::Error::success();
}

llvm::Expected<sqlite3_stmt *> WinKBDatabase::prepare(StringRef query,
                                                      ArrayRef<StringRef> args) {
  const WinKBQueryDef *def = nullptr;
  for (const auto &candidate : kQueries)
    if (candidate.name == query)
      def = &candidate;

  if (!def) {
    std::string known;
    for (const auto &candidate : kQueries)
      known += (known.empty() ? "" : ", ") + candidate.name.str();
    return llvm::createStringError(
        llvm::inconvertibleErrorCode(),
        "unknown Win32 metadata query '" + query.str() + "'; known queries: " +
            known);
  }

  if (args.size() != def->argCount)
    return llvm::createStringError(
        llvm::inconvertibleErrorCode(),
        "Win32 metadata query '" + query.str() + "' takes " +
            std::to_string(def->argCount) + " argument(s), got " +
            std::to_string(args.size()));

  if (auto err = openLocked())
    return std::move(err);

  sqlite3_stmt *stmt = nullptr;
  if (sqlite3_prepare_v2(db, def->sql.str().c_str(), -1, &stmt, nullptr) !=
      SQLITE_OK)
    return llvm::createStringError(llvm::inconvertibleErrorCode(),
                                   StringRef(sqlite3_errmsg(db)));

  for (auto [index, arg] : llvm::enumerate(args))
    sqlite3_bind_text(stmt, static_cast<int>(index + 1), arg.data(),
                      static_cast<int>(arg.size()), SQLITE_TRANSIENT);
  return stmt;
}

llvm::Expected<int64_t> WinKBDatabase::queryInt(StringRef query,
                                                ArrayRef<StringRef> args) {
  std::lock_guard<std::mutex> lock(mutex);
  auto stmt = prepare(query, args);
  if (!stmt)
    return stmt.takeError();
  llvm::scope_exit cleanup([&] { sqlite3_finalize(*stmt); });

  int rc = sqlite3_step(*stmt);
  if (rc != SQLITE_ROW)
    return llvm::createStringError(
        llvm::inconvertibleErrorCode(),
        "the Win32 metadata has no '" + query.str() + "' for " +
            llvm::join(args, ", "));
  // A NULL column means the metadata knows the entity but not this property,
  // which is a different failure from not knowing the entity at all.
  if (sqlite3_column_type(*stmt, 0) == SQLITE_NULL)
    return llvm::createStringError(llvm::inconvertibleErrorCode(),
                                   "the Win32 metadata records no " +
                                       query.str() + " for " +
                                       llvm::join(args, ", "));
  return sqlite3_column_int64(*stmt, 0);
}

llvm::Expected<std::string>
WinKBDatabase::queryString(StringRef query, ArrayRef<StringRef> args) {
  std::lock_guard<std::mutex> lock(mutex);

  // The reproducibility pin: a compiler whose semantics depend on a database
  // must be able to say WHICH database. Hashed lazily -- the file is 86 MB --
  // and cached for the process, so release tooling and canary programs can
  // record the exact metadata revision a binary was built against.
  if (query == "db_hash") {
    if (!args.empty())
      return llvm::createStringError(llvm::inconvertibleErrorCode(),
                                     "'db_hash' takes no arguments");
    if (auto err = openLocked())
      return std::move(err);
    if (cachedHash.empty()) {
      llvm::ErrorOr<std::unique_ptr<llvm::MemoryBuffer>> bufferOr =
          llvm::MemoryBuffer::getFile(openedPath, /*IsText=*/false);
      if (!bufferOr)
        return llvm::createStringError(
            llvm::inconvertibleErrorCode(),
            "cannot read the Win32 metadata database for hashing");
      llvm::SHA256 sha;
      sha.update((*bufferOr)->getBuffer());
      cachedHash = llvm::toHex(sha.final(), /*LowerCase=*/true);
    }
    return cachedHash;
  }
  auto stmt = prepare(query, args);
  if (!stmt)
    return stmt.takeError();
  llvm::scope_exit cleanup([&] { sqlite3_finalize(*stmt); });

  int rc = sqlite3_step(*stmt);
  if (rc != SQLITE_ROW || sqlite3_column_type(*stmt, 0) == SQLITE_NULL)
    return llvm::createStringError(
        llvm::inconvertibleErrorCode(),
        "the Win32 metadata has no '" + query.str() + "' for " +
            llvm::join(args, ", "));

  const auto *text = sqlite3_column_text(*stmt, 0);
  return std::string(reinterpret_cast<const char *>(text),
                     sqlite3_column_bytes(*stmt, 0));
}

} // namespace

FailureOr<TypedAttr>
IREvaluatorContext::evaluateWinKBQuery(ParamOperatorAttr op) {
  SmallVector<StringRef> operands;
  for (auto operand : op.getOperands()) {
    auto str = dyn_cast<StringAttr>(operand);
    if (!str) {
      emitError({*errorLoc, "'winkb_query' operand did not narrow to a "
                            "constant string"});
      return failure();
    }
    operands.push_back(str.getValue());
  }

  StringRef query = operands.front();
  ArrayRef<StringRef> args = ArrayRef<StringRef>(operands).drop_front();

  auto &database = WinKBDatabase::get();

  if (::isa<IndexType>(op.getType())) {
    auto value = database.queryInt(query, args);
    if (!value) {
      emitError({*errorLoc, llvm::toString(value.takeError())});
      return failure();
    }
    return cast<TypedAttr>(
        IntegerAttr::get(IndexType::get(mlirCtx), *value));
  }

  auto value = database.queryString(query, args);
  if (!value) {
    emitError({*errorLoc, llvm::toString(value.takeError())});
    return failure();
  }
  return cast<TypedAttr>(
      StringAttr::get(*value, StringType::get(mlirCtx)));
}

// See if we can decode the first 'numBytes' of the memory blob into a
// StringAttr.
static StringAttr getBytesOf(MemoryBlobAttr value, size_t numBytes) {
  // We don't bother handling these.
  if (!value.getPointerRegions().empty() || !value.getSymbolRegions().empty())
    return {};

  if (numBytes <= value.getHandle().getSize()) {
    return StringAttr::get(StringRef(value.getHandle().getData(), numBytes),
                           StringType::get(value.getContext()));
  }
  return {};
}

/// Extract a value of type `struct<(pointer<none>, index)>` into a StringAttr.
FailureOr<StringAttr> IREvaluatorContext::evaluateStringPart(TypedAttr part,
                                                             bool reset) {
  // Get the two parts of the struct, StructExtract will fold.
  TypedAttr lengthAttr = StructExtractAttr::get(part, 1);
  ErrorOr<int64_t> lengthOr = POP::getScalarIndexValue(lengthAttr);
  if (lengthOr.isError()) {
    emitError(
        {*errorLoc,
         Error(Twine("'data_to_str' length didn't resolve to a constant: ") +
               lengthOr.getError())});
    return failure();
  }

  size_t numBytes = *lengthOr;
  if (!numBytes)
    return {StringAttr::get("", StringType::get(mlirCtx))};

  MemRefAttr pointerAttr =
      dyn_cast<MemRefAttr>(StructExtractAttr::get(part, 0));
  if (!pointerAttr) {
    emitError({*errorLoc, "'data_to_str' did not narrow to a constant"});
    return failure();
  }

  // Check to see if we have a memref(interp.memory_handle(...)) because
  // we can just immediately fold it in common cases without materializing the
  // memory.
  // We don't handle index/offset yet.
  if (auto result =
          getBytesOf(pointerAttr.getModel().getMemory()[pointerAttr.getIndex()],
                     numBytes)) {
    if (pointerAttr.getOffset() == 0)
      return result;
  }

  // Reset memory upon exit.
  auto resetState = llvm::scope_exit([&] {
    if (reset)
      state->reset();
  });

  if (ErrorOrSuccess err = state->internalizeMemory(pointerAttr)) {
    emitError({*errorLoc, "'data_to_str' failed to read data"});
    return failure();
  }

  size_t address = cast<PointerAttr>(pointerAttr).getAddr();
  Type byteType = IntegerType::get(mlirCtx, 8);

  // Read each of the bytes into 'result' one at a time.  If any fail,
  // just bail out.
  std::string result;
  while (numBytes) {
    ErrorOr<TypedAttr> attrOr =
        state->readAttributeFromMemory(address, byteType);
    if (attrOr.isError() || !isa<IntegerAttr>(attrOr.get())) {
      emitError({*errorLoc, "'data_to_str' failed to read data"});
      return failure();
    }
    result.push_back((char)cast<IntegerAttr>(attrOr.get()).getInt());
    ++address;
    --numBytes;
  }

  // Success!
  return {StringAttr::get(result, StringType::get(mlirCtx))};
}

/// Evaluate POC::DataToStr "data_to_str" operator.
FailureOr<TypedAttr> IREvaluatorContext::evaluateDataToStr(ParamOperatorAttr op,
                                                           bool reset) {
  FailureOr<StringAttr> result = evaluateStringPart(op.getOperand(0), reset);
  if (failed(result))
    return failure();

  // Extra string parts, which will be a ParamListAttr of type
  // !kgen.param_list<>
  ParamListAttr extrasAttr = dyn_cast<ParamListAttr>(op.getOperand(1));
  if (!extrasAttr) {
    emitError(
        {*errorLoc, "'data_to_str' did not narrow to a variadic constant"});
    return failure();
  }

  // If there are no extra parts then we're done.
  if (extrasAttr.getValues().empty())
    return TypedAttr(*result);

  // Otherwise, we need to evaluate the extra parts and concatenate them.
  std::string concatStr = result->str();
  for (TypedAttr extra : extrasAttr.getValues()) {
    FailureOr<StringAttr> extraResult = evaluateStringPart(extra, reset);
    if (failed(extraResult))
      return failure();
    concatStr += extraResult->str();
  }
  return TypedAttr(StringAttr::get(concatStr, StringType::get(mlirCtx)));
}
