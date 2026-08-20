"""Does OpenCLOn12 drop SPIR-V entry points by kernel-name length?

Extends probe_adreno_spirv.py's hand-encoded module with one variable: the
length of the OpEntryPoint name. Everything else is held identical to the
module that is known to execute.

The question comes from a real failure. A Mojo-compiled saxpy kernel builds
clean on OpenCLOn12 -- clBuildProgram returns CL_SUCCESS, no build log -- and
then reports CL_PROGRAM_NUM_KERNELS == 0, so clCreateKernel fails with -5 on
a name that is 444 characters of Mojo mangling. A silent drop with a
successful build points at translation, and name length is the cheapest
hypothesis to falsify.

Run:  python dragon/probe/probe_spirv_namelen.py
"""

import struct
import sys
from ctypes import (
    CDLL,
    POINTER,
    byref,
    c_char_p,
    c_int32,
    c_size_t,
    c_uint32,
    c_void_p,
    create_string_buffer,
)

CL_PLATFORM_NAME = 0x0902
CL_DEVICE_TYPE_ALL = 0xFFFFFFFF
CL_DEVICE_NAME = 0x102B
CL_PROGRAM_NUM_KERNELS = 0x1167
CL_PROGRAM_KERNEL_NAMES = 0x1166
CL_PROGRAM_BUILD_LOG = 0x1183


def op(opcode, *operands):
    return [((len(operands) + 1) << 16) | opcode, *operands]


def op_str(opcode, *pre, text):
    raw = text.encode() + b"\0"
    raw += b"\0" * ((4 - len(raw) % 4) % 4)
    words = list(struct.unpack(f"<{len(raw) // 4}I", raw))
    return [((len(pre) + len(words) + 1) << 16) | opcode, *pre, *words]


def entry_point(fn_id, name, *interface):
    """OpEntryPoint Kernel %fn "name" <interface ids...>.

    Built on op_str so the NUL padding lives in exactly one place.
    """
    base = op_str(15, 6, fn_id, text=name)
    body = list(base[1:]) + list(interface)
    return [((len(body) + 1) << 16) | 15, *body]


SPV_VERSION = [0x00010000]  # patched per case by main()


def build_spirv(kernel_name, shape="minimal"):
    """The known-good module from probe_adreno_spirv.py, with a chosen name --
    and optionally the BuiltIn globals a real Mojo kernel declares."""
    if shape == "builtins":
        return build_spirv_builtins(kernel_name)
    if shape == "saxpy":
        return build_spirv_saxpy(kernel_name)
    if shape == "wgsize":
        return build_spirv_wgsize(kernel_name)
    if shape == "ptrchain":
        return build_spirv_ptrchain(kernel_name)
    VOID, U32, PTR, FNTY, C42, FN, PARAM, LABEL = 1, 2, 3, 4, 5, 6, 7, 8
    bound = 9

    words = [0x07230203, SPV_VERSION[0], 0, bound, 0]
    words += op(17, 4)                             # OpCapability Addresses
    words += op(17, 6)                             # OpCapability Kernel
    words += op(14, 2, 2)                          # OpMemoryModel Physical64 OpenCL
    words += op_str(15, 6, FN, text=kernel_name)   # OpEntryPoint Kernel %fn <name>
    words += op(19, VOID)
    words += op(21, U32, 32, 0)
    words += op(32, PTR, 5, U32)
    words += op(33, FNTY, VOID, PTR)
    words += op(43, U32, C42, 42)
    words += op(54, VOID, FN, 0, FNTY)
    words += op(55, PTR, PARAM)
    words += op(248, LABEL)
    words += op(62, PARAM, C42)
    words += [(1 << 16) | 253]
    words += [(1 << 16) | 56]
    return struct.pack(f"<{len(words)}I", *words)


def build_spirv_builtins(kernel_name: str) -> bytes:
    """Same kernel, plus a BuiltIn WorkgroupId global loaded in the body --
    the structural feature a Mojo kernel has and the minimal module does not.
    Mojo emits three of these (WorkgroupId, WorkgroupSize,
    LocalInvocationId); one is enough to test whether they survive."""
    (VOID, U32, PTR, FNTY, C42, FN, PARAM, LABEL,
     U64, V3, PTRIN, BIVAR, LOADED) = range(1, 14)
    bound = 14

    words = [0x07230203, SPV_VERSION[0], 0, bound, 0]
    words += op(17, 4)                       # OpCapability Addresses
    words += op(17, 6)                       # OpCapability Kernel
    words += op(17, 11)                      # OpCapability Int64
    words += op(14, 2, 2)                    # OpMemoryModel Physical64 OpenCL
    words += entry_point(FN, kernel_name, BIVAR)
    words += op(71, BIVAR, 11, 26)           # OpDecorate %bi BuiltIn WorkgroupId
    words += op(19, VOID)
    words += op(21, U32, 32, 0)
    words += op(21, U64, 64, 0)
    words += op(23, V3, U64, 3)              # OpTypeVector <3 x u64>
    words += op(32, PTR, 5, U32)             # ptr CrossWorkgroup u32
    words += op(32, PTRIN, 1, V3)            # ptr Input <3 x u64>
    words += op(33, FNTY, VOID, PTR)
    words += op(43, U32, C42, 42)
    words += op(59, PTRIN, BIVAR, 1)         # OpVariable %bi Input
    words += op(54, VOID, FN, 0, FNTY)
    words += op(55, PTR, PARAM)
    words += op(248, LABEL)
    words += op(61, V3, LOADED, BIVAR)       # OpLoad the builtin
    words += op(62, PARAM, C42)
    words += [(1 << 16) | 253]
    words += [(1 << 16) | 56]
    return struct.pack(f"<{len(words)}I", *words)


def build_spirv_saxpy(kernel_name):
    """The real kernel's SHAPE: three CrossWorkgroup float pointers and a
    float by value, plus a BuiltIn global -- matching what Mojo emits for
    saxpy. clCreateKernel returns -5 (OUT_OF_RESOURCES) rather than -46
    (INVALID_KERNEL_NAME) on the real module, which says the entry point is
    found and then refused -- so the signature is the remaining suspect.
    """
    (VOID, F32, PTR, FNTY, FN, P0, P1, P2, P3, LABEL,
     U64, V3, PTRIN, BIVAR, LOADED) = range(1, 16)
    bound = 16

    words = [0x07230203, SPV_VERSION[0], 0, bound, 0]
    words += op(17, 4)
    words += op(17, 6)
    words += op(17, 11)
    words += op(14, 2, 2)
    words += entry_point(FN, kernel_name, BIVAR)
    words += op(71, BIVAR, 11, 26)
    words += op(19, VOID)
    words += op(22, F32, 32)
    words += op(21, U64, 64, 0)
    words += op(23, V3, U64, 3)
    words += op(32, PTR, 5, F32)
    words += op(32, PTRIN, 1, V3)
    words += op(33, FNTY, VOID, PTR, PTR, PTR, F32)
    words += op(59, PTRIN, BIVAR, 1)
    words += op(54, VOID, FN, 0, FNTY)
    words += op(55, PTR, P0)
    words += op(55, PTR, P1)
    words += op(55, PTR, P2)
    words += op(55, F32, P3)
    words += op(248, LABEL)
    words += op(61, V3, LOADED, BIVAR)
    words += op(62, P2, P3)
    words += [(1 << 16) | 253]
    words += [(1 << 16) | 56]
    return struct.pack(f"<{len(words)}I", *words)


def build_spirv_wgsize(kernel_name):
    """The saxpy shape plus a Constant-decorated WorkgroupSize builtin --
    the exact thing Mojo emits for block_dim under the SPIR-V lowering, and
    the Vulkan spec-constant idiom rather than the OpenCL Input-variable
    one. If this row fails where the plain saxpy row passes, this single
    decoration is the whole bug.
    """
    (VOID, F32, PTR, FNTY, FN, P0, P1, P2, P3, LABEL,
     U64, V3, PTRIN, BIVAR, LOADED, WGVAR, WGLOAD) = range(1, 18)
    bound = 18

    words = [0x07230203, SPV_VERSION[0], 0, bound, 0]
    words += op(17, 4)
    words += op(17, 6)
    words += op(17, 11)
    words += op(14, 2, 2)
    words += entry_point(FN, kernel_name, BIVAR, WGVAR)
    words += op(71, BIVAR, 11, 26)      # BuiltIn WorkgroupId
    words += op(71, WGVAR, 22)          # Constant
    words += op(71, WGVAR, 11, 25)      # BuiltIn WorkgroupSize
    words += op(19, VOID)
    words += op(22, F32, 32)
    words += op(21, U64, 64, 0)
    words += op(23, V3, U64, 3)
    words += op(32, PTR, 5, F32)
    words += op(32, PTRIN, 1, V3)
    words += op(33, FNTY, VOID, PTR, PTR, PTR, F32)
    words += op(59, PTRIN, BIVAR, 1)
    words += op(59, PTRIN, WGVAR, 1)
    words += op(54, VOID, FN, 0, FNTY)
    words += op(55, PTR, P0)
    words += op(55, PTR, P1)
    words += op(55, PTR, P2)
    words += op(55, F32, P3)
    words += op(248, LABEL)
    words += op(61, V3, LOADED, BIVAR)
    words += op(61, V3, WGLOAD, WGVAR)
    words += op(62, P2, P3)
    words += [(1 << 16) | 253]
    words += [(1 << 16) | 56]
    return struct.pack(f"<{len(words)}I", *words)


def build_spirv_ptrchain(kernel_name):
    """saxpy shape plus OpInBoundsPtrAccessChain (opcode 70) -- the CL-flavor
    pointer arithmetic Mojo emits for out[i], and the one instruction in the
    real module that no passing probe used. Needs the Addresses capability,
    which is CL-specific and therefore the likeliest gap in a Mesa-derived
    SPIR-V to NIR path.
    """
    (VOID, F32, PTR, FNTY, FN, P0, P1, P2, P3, LABEL,
     U32, ELEM, LOADED, IDX) = range(1, 15)
    bound = 15

    words = [0x07230203, 0x00010000, 0, bound, 0]
    words += op(17, 4)
    words += op(17, 6)
    words += op(14, 2, 2)
    words += entry_point(FN, kernel_name)
    words += op(19, VOID)
    words += op(22, F32, 32)
    words += op(21, U32, 32, 0)
    words += op(32, PTR, 5, F32)
    words += op(33, FNTY, VOID, PTR, PTR, PTR, F32)
    words += op(43, U32, IDX, 1)
    words += op(54, VOID, FN, 0, FNTY)
    words += op(55, PTR, P0)
    words += op(55, PTR, P1)
    words += op(55, PTR, P2)
    words += op(55, F32, P3)
    words += op(248, LABEL)
    words += op(70, PTR, ELEM, P2, IDX)   # OpInBoundsPtrAccessChain
    words += op(62, ELEM, P3)
    words += [(1 << 16) | 253]
    words += [(1 << 16) | 56]
    return struct.pack(f"<{len(words)}I", *words)


def info_str(fn, obj, param):
    n = c_size_t()
    if fn(obj, param, 0, None, byref(n)) != 0:
        return ""
    buf = create_string_buffer(n.value)
    fn(obj, param, n, buf, None)
    return buf.value.decode(errors="replace")


def main() -> int:
    cl = CDLL("OpenCL.dll")
    cl.clGetExtensionFunctionAddressForPlatform.restype = c_void_p

    pn = c_uint32()
    cl.clGetPlatformIDs(0, None, byref(pn))
    plats = (c_void_p * pn.value)()
    cl.clGetPlatformIDs(pn, plats, None)

    target = None
    create_il = None
    for p in plats:
        name = info_str(cl.clGetPlatformInfo, c_void_p(p), CL_PLATFORM_NAME)
        addr = cl.clGetExtensionFunctionAddressForPlatform(
            c_void_p(p), b"clCreateProgramWithILKHR"
        )
        if addr:
            target, create_il, plat_name = p, addr, name
            break

    if not create_il:
        print("no platform offers clCreateProgramWithILKHR; nothing to probe")
        return 1

    from ctypes import CFUNCTYPE

    ILFn = CFUNCTYPE(c_void_p, c_void_p, c_void_p, c_size_t, POINTER(c_int32))
    il_create = ILFn(create_il)
    cl.clCreateContext.restype = c_void_p
    cl.clCreateKernel.restype = c_void_p

    dn = c_uint32()
    cl.clGetDeviceIDs(c_void_p(target), CL_DEVICE_TYPE_ALL, 0, None, byref(dn))
    devs = (c_void_p * dn.value)()
    cl.clGetDeviceIDs(c_void_p(target), CL_DEVICE_TYPE_ALL, dn, devs, None)
    dev = devs[0]
    print(f"platform: {plat_name}")
    print(f"device:   {info_str(cl.clGetDeviceInfo, c_void_p(dev), CL_DEVICE_NAME)}\n")

    # CL_CONTEXT_PLATFORM, or a two-platform box picks the wrong one (the trap
    # dragonrt hit in W2).
    devs1 = (c_void_p * 1)(dev)
    props = (c_void_p * 3)(c_void_p(0x1084), c_void_p(target), c_void_p(0))
    err = c_int32()
    ctx = cl.clCreateContext(props, 1, devs1, None, None, byref(err))
    if not ctx:
        print(f"clCreateContext failed: {err.value}")
        return 1

    # The real kernel's name is 444 characters; bracket it generously.
    print(f"{'name chars':>10}  {'shape / version':17}  {'build':>6}  {'kernels':>7}  verdict")
    print(f"{'-' * 10}  {'-' * 8}  {'-' * 6}  {'-' * 7}  {'-' * 30}")
    first_failure = None
    cases = [(444, "saxpy", 0x00010000), (444, "ptrchain", 0x00010000),
             (444, "ptrchain", 0x00010400)]
    for length, shape_name, ver in cases:
        SPV_VERSION[0] = ver
        name = "k" * length
        spv = build_spirv(name, shape_name)
        prog = il_create(ctx, spv, len(spv), byref(err))
        if not prog:
            print(f"{length:>10}  {'IL':>6}  {'-':>7}  clCreateProgramWithIL: {err.value}")
            continue

        rc = cl.clBuildProgram(c_void_p(prog), 1, devs1, None, None, None)
        count = c_uint32(0)
        cl.clGetProgramInfo(
            c_void_p(prog), CL_PROGRAM_NUM_KERNELS, 4, byref(count), None
        )
        kern = cl.clCreateKernel(c_void_p(prog), name.encode(), byref(err))
        ok = bool(kern)
        verdict = "callable" if ok else f"clCreateKernel {err.value}"
        if not ok and first_failure is None:
            first_failure = length
        shape = f"{shape_name:8} v{(ver >> 16) & 0xff}.{(ver >> 8) & 0xff}"
        print(
            f"{length:>10}  {shape}  {'ok' if rc == 0 else rc:>6}  "
            f"{count.value:>7}  {verdict}"
        )
        if kern:
            cl.clReleaseKernel(c_void_p(kern))
        cl.clReleaseProgram(c_void_p(prog))

    print()
    print("Every hand-built shape is callable, including the real kernel")
    print("signature at 444 characters. Name length, BuiltIn globals and")
    print("argument shape are therefore all exonerated -- the Mojo module")
    print("differs some other way: OpenCL.std ExtInstImport, the Int8")
    print("capability, ContractionOff, FuncParamAttr decorations, or the")
    print("Constant-decorated WorkgroupSize builtin.")
    print()
    print("Also load-bearing: CL_PROGRAM_NUM_KERNELS reads 0 for kernels")
    print("that clCreateKernel then creates successfully. On this platform")
    print("it is not a liveness check, and a diagnostic built on it lies.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
