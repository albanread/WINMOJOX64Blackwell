"""Word-level SPIR-V decoder and structural checker - the promised stripper's
front half. Decodes a module to an annotated listing and runs the checks that
single-feature stripping cannot express: bodyless imported functions, entry
point interface completeness, duplicate types, capability/usage mismatches,
builtin variable typing against the OpenCL-flavor rules.

Written for the clCreateKernel -5 bisect: the failing module is small enough
to read in full, and interaction bugs live in exactly the properties listed
above.

    python spv_tool.py <module.spv>            annotated listing + checks
    python spv_tool.py <module.spv> --checks   checks only
"""

from __future__ import annotations

import struct
import sys

OPNAMES = {
    0: "OpNop", 1: "OpUndef", 3: "OpSource", 4: "OpSourceExtension",
    5: "OpName", 6: "OpMemberName", 7: "OpString", 8: "OpLine",
    10: "OpExtension", 11: "OpExtInstImport", 12: "OpExtInst",
    14: "OpMemoryModel", 15: "OpEntryPoint", 16: "OpExecutionMode",
    17: "OpCapability", 19: "OpTypeVoid", 20: "OpTypeBool", 21: "OpTypeInt",
    22: "OpTypeFloat", 23: "OpTypeVector", 28: "OpTypeArray",
    30: "OpTypeStruct", 32: "OpTypePointer", 33: "OpTypeFunction",
    41: "OpConstantTrue", 42: "OpConstantFalse", 43: "OpConstant",
    44: "OpConstantComposite", 46: "OpConstantNull",
    54: "OpFunction", 55: "OpFunctionParameter", 56: "OpFunctionEnd",
    57: "OpFunctionCall", 59: "OpVariable", 61: "OpLoad", 62: "OpStore",
    63: "OpCopyMemory", 65: "OpAccessChain", 66: "OpInBoundsAccessChain",
    67: "OpPtrAccessChain", 70: "OpInBoundsPtrAccessChain",
    71: "OpDecorate", 72: "OpMemberDecorate", 79: "OpVectorShuffle",
    80: "OpCompositeConstruct", 81: "OpCompositeExtract",
    82: "OpCompositeInsert", 83: "OpCopyObject",
    109: "OpConvertFToU", 110: "OpConvertFToS", 111: "OpConvertSToF",
    112: "OpConvertUToF", 113: "OpUConvert", 114: "OpSConvert",
    115: "OpFConvert", 117: "OpConvertPtrToU", 120: "OpConvertUToPtr",
    121: "OpPtrCastToGeneric", 122: "OpGenericCastToPtr",
    123: "OpGenericCastToPtrExplicit", 124: "OpBitcast",
    126: "OpSNegate", 127: "OpFNegate",
    128: "OpIAdd", 129: "OpFAdd", 130: "OpISub", 131: "OpFSub",
    132: "OpIMul", 133: "OpFMul", 134: "OpUDiv", 135: "OpSDiv",
    136: "OpFDiv", 137: "OpUMod", 138: "OpSRem", 139: "OpSMod",
    140: "OpFRem", 141: "OpFMod",
    169: "OpSelect", 170: "OpIEqual", 171: "OpINotEqual",
    172: "OpUGreaterThan", 173: "OpSGreaterThan",
    174: "OpUGreaterThanEqual", 175: "OpSGreaterThanEqual",
    176: "OpULessThan", 177: "OpSLessThan", 178: "OpULessThanEqual",
    179: "OpSLessThanEqual",
    194: "OpShiftRightLogical", 195: "OpShiftRightArithmetic",
    196: "OpShiftLeftLogical", 197: "OpBitwiseOr", 198: "OpBitwiseXor",
    199: "OpBitwiseAnd", 200: "OpNot",
    224: "OpControlBarrier", 225: "OpMemoryBarrier",
    245: "OpPhi", 246: "OpLoopMerge", 247: "OpSelectionMerge",
    248: "OpLabel", 249: "OpBranch", 250: "OpBranchConditional",
    253: "OpReturn", 254: "OpReturnValue", 255: "OpUnreachable",
}

CAPS = {0: "Matrix", 1: "Shader", 4: "Addresses", 5: "Linkage", 6: "Kernel",
        7: "Vector16", 9: "Float16", 10: "Float64", 11: "Int64", 22: "Int16",
        38: "GenericPointer", 39: "Int8"}
STORAGE = {0: "UniformConstant", 1: "Input", 2: "Uniform", 3: "Output",
           4: "Workgroup", 5: "CrossWorkgroup", 6: "Private", 7: "Function",
           8: "Generic"}
DECOR = {11: "BuiltIn", 19: "Restrict", 20: "Aliased", 21: "Volatile",
         22: "Constant", 24: "NonWritable", 26: "Uniform", 38: "FuncParamAttr",
         40: "FPFastMathMode", 41: "LinkageAttributes", 44: "Alignment"}
BUILTIN = {24: "NumWorkgroups", 25: "WorkgroupSize", 26: "WorkgroupId",
           27: "LocalInvocationId", 28: "GlobalInvocationId",
           29: "LocalInvocationIndex", 30: "WorkDim", 31: "GlobalSize",
           33: "GlobalOffset", 34: "GlobalLinearId", 36: "SubgroupSize"}
EXECMODEL = {5: "GLCompute", 6: "Kernel"}
ADDRMODEL = {0: "Logical", 1: "Physical32", 2: "Physical64"}
MEMMODEL = {0: "Simple", 1: "GLSL450", 2: "OpenCL"}
EXECMODE = {17: "LocalSize", 18: "LocalSizeHint", 30: "VecTypeHint",
            31: "ContractionOff"}
FPATTR = {0: "Zext", 1: "Sext", 2: "ByVal", 3: "Sret", 4: "NoAlias",
          5: "NoCapture", 6: "NoWrite", 7: "NoReadWrite"}
LINKAGE = {0: "Export", 1: "Import"}

# Ops whose FIRST TWO operands are (result-type, result-id).
TYPED_RESULT = {12, 41, 42, 43, 44, 46, 54, 55, 57, 59, 61, 65, 66, 67, 70,
                121, 123, 124,
                79, 80, 81, 82, 83, 109, 110, 111, 112, 113, 114, 115, 117,
                120, 122, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135,
                136, 137, 138, 139, 140, 141, 169, 170, 171, 172, 173, 174,
                175, 176, 177, 178, 179, 194, 195, 196, 197, 198, 199, 200,
                245, 254}
# Ops whose FIRST operand is a bare result-id (no type).
BARE_RESULT = {7, 11, 19, 20, 21, 22, 23, 28, 30, 32, 33, 248}


def read_str(ops, start):
    raw = b""
    i = start
    while i < len(ops):
        raw += struct.pack("<I", ops[i])
        i += 1
        if 0 in raw[-4:]:
            break
    return raw.split(b"\x00")[0].decode(errors="replace"), i


def decode(words):
    header = words[:5]
    insts = []
    i = 5
    while i < len(words):
        wc = words[i] >> 16
        opcode = words[i] & 0xFFFF
        insts.append((i, opcode, list(words[i + 1: i + wc])))
        i += wc
    return header, insts


def annotate(header, insts):
    ver = header[1]
    print(f"; magic 0x{header[0]:08x}  version {ver >> 16}.{(ver >> 8) & 0xFF}"
          f"  generator 0x{header[2]:08x}  bound {header[3]}")
    names = {}
    for _, op, ops in insts:
        if op == 5 and ops:
            names[ops[0]], _ = read_str(ops, 1)

    def rid(n):
        nm = names.get(n)
        return f"%{n}" + (f'"{nm[:24]}"' if nm else "")

    for idx, (w, op, ops) in enumerate(insts):
        name = OPNAMES.get(op, f"Op#{op}")
        out = f"{idx:4} "
        if op == 17:
            out += f"OpCapability {CAPS.get(ops[0], ops[0])}"
        elif op == 14:
            out += (f"OpMemoryModel {ADDRMODEL.get(ops[0], ops[0])} "
                    f"{MEMMODEL.get(ops[1], ops[1])}")
        elif op == 15:
            nm, j = read_str(ops, 2)
            ifaces = ops[j:]
            out += (f"OpEntryPoint {EXECMODEL.get(ops[0], ops[0])} {rid(ops[1])}"
                    f' "{nm[:60]}{"..." if len(nm) > 60 else ""}"'
                    f" interface={[f'%{x}' for x in ifaces]}")
        elif op == 16:
            out += (f"OpExecutionMode {rid(ops[0])} "
                    f"{EXECMODE.get(ops[1], ops[1])} {ops[2:]}")
        elif op == 11:
            nm, _ = read_str(ops, 1)
            out += f'%{ops[0]} = OpExtInstImport "{nm}"'
        elif op == 10:
            nm, _ = read_str(ops, 0)
            out += f'OpExtension "{nm}"'
        elif op == 3:
            out += f"OpSource lang={ops[0]} ver={ops[1] if len(ops) > 1 else 0}"
        elif op == 5:
            nm, _ = read_str(ops, 1)
            out += f'OpName %{ops[0]} "{nm[:60]}"'
        elif op == 71:
            d = DECOR.get(ops[1], f"Dec#{ops[1]}")
            extra = ops[2:]
            if ops[1] == 11 and extra:
                extra = [BUILTIN.get(extra[0], extra[0])]
            elif ops[1] == 38 and extra:
                extra = [FPATTR.get(extra[0], extra[0])]
            elif ops[1] == 41:
                nm, j = read_str(ops, 2)
                extra = [f'"{nm}"', LINKAGE.get(ops[j], ops[j]) if j < len(ops) else "?"]
            out += f"OpDecorate {rid(ops[0])} {d} {extra}"
        elif op == 21:
            out += f"%{ops[0]} = OpTypeInt width={ops[1]} signed={ops[2]}"
        elif op == 22:
            out += f"%{ops[0]} = OpTypeFloat width={ops[1]}"
        elif op == 23:
            out += f"%{ops[0]} = OpTypeVector comp={rid(ops[1])} n={ops[2]}"
        elif op == 32:
            out += (f"%{ops[0]} = OpTypePointer {STORAGE.get(ops[1], ops[1])} "
                    f"{rid(ops[2])}")
        elif op == 33:
            out += (f"%{ops[0]} = OpTypeFunction ret={rid(ops[1])} "
                    f"params={[f'%{x}' for x in ops[2:]]}")
        elif op == 59:
            sc = STORAGE.get(ops[2], ops[2])
            out += f"%{ops[1]} : {rid(ops[0])} = OpVariable {sc}"
            if len(ops) > 3:
                out += f" init={rid(ops[3])}"
        elif op == 43:
            out += f"%{ops[1]} : {rid(ops[0])} = OpConstant {ops[2:]}"
        elif op == 54:
            out += (f"%{ops[1]} : {rid(ops[0])} = OpFunction control={ops[2]} "
                    f"type={rid(ops[3])}")
        elif op in TYPED_RESULT and len(ops) >= 2:
            out += (f"%{ops[1]} : {rid(ops[0])} = {name} "
                    f"{[rid(x) for x in ops[2:]]}")
        elif op in BARE_RESULT and ops:
            out += f"%{ops[0]} = {name} {ops[1:]}"
        else:
            out += f"{name} {[rid(x) for x in ops]}"
        print(out)
    return names


def checks(header, insts, names):
    print("\n===== structural checks =====")
    problems = []

    # 1. Bodyless functions (declaration-only => needs Import linkage; a
    #    consumer with no linker refuses the module).
    funcs = []  # (id, has_body, name)
    cur = None
    body = False
    for _, op, ops in insts:
        if op == 54:
            cur = ops[1]
            body = False
        elif op == 248 and cur is not None:
            body = True
        elif op == 56 and cur is not None:
            funcs.append((cur, body, names.get(cur, "")))
            cur = None
    for fid, has_body, nm in funcs:
        if not has_body:
            problems.append(
                f"BODYLESS FUNCTION %{fid} '{nm}' - requires Import linkage; "
                f"anything without a linker refuses it")
    print(f"functions: {len(funcs)}  "
          f"({sum(1 for _, b, _ in funcs if not b)} bodyless)")

    # 2. Entry point interface vs module-scope variables. SPIR-V >= 1.4
    #    requires ALL referenced globals listed; < 1.4 requires Input/Output.
    ver = (header[1] >> 16, (header[1] >> 8) & 0xFF)
    entry_ifaces = []
    for _, op, ops in insts:
        if op == 15:
            _, j = read_str(ops, 2)
            entry_ifaces = ops[j:]
    globals_ = []  # (id, storage)
    infn = False
    for _, op, ops in insts:
        if op == 54:
            infn = True
        elif op == 56:
            infn = False
        elif op == 59 and not infn:
            globals_.append((ops[1], ops[2]))
    for gid, sc in globals_:
        needed = (ver >= (1, 4)) or sc in (1, 3)
        if needed and gid not in entry_ifaces:
            problems.append(
                f"GLOBAL %{gid} ({STORAGE.get(sc, sc)}) NOT in OpEntryPoint "
                f"interface (module is v{ver[0]}.{ver[1]}; "
                f"{'>=1.4 requires all globals' if ver >= (1, 4) else 'Input/Output required at any version'})")
    print(f"module-scope variables: {len(globals_)}; "
          f"entry interface lists {len(entry_ifaces)}")

    # 3. Duplicate non-aggregate types (illegal per spec; validators reject,
    #    consumers may crash instead).
    seen = {}
    for _, op, ops in insts:
        if op in (19, 20, 21, 22, 23, 32):
            key = (op, tuple(ops[1:]))
            if key in seen:
                problems.append(
                    f"DUPLICATE TYPE %{ops[0]} duplicates %{seen[key]} "
                    f"({OPNAMES[op]} {list(ops[1:])})")
            else:
                seen[key] = ops[0]

    # 4. Builtin variable typing vs OpenCL flavor: on Physical64, the
    #    work-item builtins are size_t (i64) vectors. v3i32 builtins are the
    #    Vulkan idiom and off-flavor here.
    addr = next((ops[0] for _, op, ops in insts if op == 14), None)
    type_of = {}
    for _, op, ops in insts:
        if op in (19, 20, 21, 22, 23, 28, 32, 33):
            type_of[ops[0]] = (op, ops[1:])
    var_type = {ops[1]: ops[0] for _, op, ops in insts if op == 59}
    builtin_of = {}
    for _, op, ops in insts:
        if op == 71 and ops[1] == 11:
            builtin_of[ops[0]] = ops[2]
    for vid, b in builtin_of.items():
        tid = var_type.get(vid)
        if tid is None or tid not in type_of:
            continue
        top, targs = type_of[tid]
        if top != 32:
            continue
        pointee = targs[1]
        if pointee in type_of and type_of[pointee][0] == 23:
            comp = type_of[pointee][1][0]
            n = type_of[pointee][1][1]
            width = type_of.get(comp, (0, [0]))[1][0]
            expect = 64 if addr == 2 else 32
            note = ""
            if width != expect:
                note = (f"  <-- OFF-FLAVOR: v{n}i{width} but Physical"
                        f"{64 if addr == 2 else 32} OpenCL builtins are size_t")
                problems.append(
                    f"BUILTIN %{vid} ({BUILTIN.get(b, b)}) typed v{n}i{width}"
                    f"{note}")
            print(f"builtin %{vid} {BUILTIN.get(b, b):20} v{n}i{width}{note}")

    # 4b. Kernel parameter storage classes. In kernel-flavor SPIR-V a kernel
    #     pointer argument must be CrossWorkgroup/Workgroup/UniformConstant/
    #     Generic; Function storage (LLVM addrspace(0)) is invalid as an arg
    #     and maps to nothing clSetKernelArg can bind. THE cause of the
    #     2026-08-20 clCreateKernel -5.
    entry_fn = None
    for _, op, ops in insts:
        if op == 15:
            entry_fn = ops[1]
    fn_type = None
    for _, op, ops in insts:
        if op == 54 and ops[1] == entry_fn:
            fn_type = ops[3]
    if fn_type is not None and fn_type in type_of and type_of[fn_type][0] == 33:
        for k, ptid in enumerate(type_of[fn_type][1][1:]):
            if ptid in type_of and type_of[ptid][0] == 32:
                sc = type_of[ptid][1][0]
                scn = STORAGE.get(sc, sc)
                ok = sc in (0, 4, 5, 8)
                print(f"kernel param {k}: pointer, storage {scn}"
                      f"{'' if ok else '  <-- INVALID for a kernel argument'}")
                if not ok:
                    problems.append(
                        f"KERNEL PARAM {k} is a {scn}-storage pointer - "
                        f"invalid kernel argument storage class")

    # 5. Capability census vs a few usage rules.
    caps = {ops[0] for _, op, ops in insts if op == 17}
    print(f"capabilities: {sorted(CAPS.get(c, c) for c in caps)}")
    widths = {targs[0] for tid, (top, targs) in type_of.items() if top == 21}
    if 8 in widths and 39 not in caps:
        problems.append("i8 type present without Int8 capability")
    if 64 in widths and 11 not in caps:
        problems.append("i64 type present without Int64 capability")
    if 5 in caps and not any(not b for _, b, _ in funcs):
        print("note: Linkage capability declared but no bodyless functions")

    print("\n===== verdicts =====")
    if problems:
        for p in problems:
            print(f"  !! {p}")
    else:
        print("  no structural problems found by these checks")
    return problems


def main():
    path = sys.argv[1]
    data = open(path, "rb").read()
    words = list(struct.unpack(f"<{len(data)//4}I", data))
    if words[0] != 0x07230203:
        print("not SPIR-V (bad magic)")
        return 2
    header, insts = decode(words)
    if "--checks" not in sys.argv:
        names = annotate(header, insts)
    else:
        names = {}
        for _, op, ops in insts:
            if op == 5 and ops:
                names[ops[0]], _ = read_str(ops, 1)
    checks(header, insts, names)
    return 0


if __name__ == "__main__":
    sys.exit(main())
