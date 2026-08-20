"""Which OpenCL platforms on this box can ingest - and EXECUTE - SPIR-V?

Field report from the compiler team (2026-08-19): mojo build emits real
SPIR-V, dragonrt loads and copies, and kernel load dies - the native QUALCOMM
driver advertises no cl_khr_il_program and an empty CL_DEVICE_IL_VERSION.
OpenCLOn12 (Microsoft's D3D12 layer) advertises ingestion and reaches the
same Adreno.

This probe settles what "advertises" is worth: for EVERY platform exposing an
Adreno device it queries the IL capability, then attempts to run a minimal
hand-encoded OpenCL-flavor SPIR-V module (kernel k(global uint* p){*p=42;})
and reads the 42 back. Route 2 of the kernel-load decision lives or dies on
the OpenCLOn12 row.

Hand-encoding keeps the probe dependency-free and the module auditable here.

    python dragon/probe/probe_adreno_spirv.py
"""

from __future__ import annotations

import ctypes
import struct
import sys
from ctypes import POINTER, byref, c_int32, c_size_t, c_uint32, c_uint64, c_void_p

CL_PLATFORM_NAME = 0x0902
CL_DEVICE_NAME = 0x102B
CL_DEVICE_EXTENSIONS = 0x1030
CL_DEVICE_IL_VERSION = 0x105B
CL_DEVICE_ADDRESS_BITS = 0x100D
CL_DEVICE_TYPE_ALL = 0xFFFFFFFF
CL_MEM_READ_WRITE = 1 << 0
CL_TRUE = 1
CL_PROGRAM_BUILD_LOG = 0x1183


def bind(cl):
    cl.clGetPlatformIDs.argtypes = [c_uint32, POINTER(c_void_p), POINTER(c_uint32)]
    cl.clGetPlatformIDs.restype = c_int32
    for fn in (cl.clGetPlatformInfo, cl.clGetDeviceInfo):
        fn.argtypes = [c_void_p, c_uint32, c_size_t, c_void_p, POINTER(c_size_t)]
        fn.restype = c_int32
    cl.clGetDeviceIDs.argtypes = [
        c_void_p, c_uint64, c_uint32, POINTER(c_void_p), POINTER(c_uint32)
    ]
    cl.clGetDeviceIDs.restype = c_int32
    cl.clCreateContext.argtypes = [
        c_void_p, c_uint32, POINTER(c_void_p), c_void_p, c_void_p, POINTER(c_int32)
    ]
    cl.clCreateContext.restype = c_void_p
    cl.clCreateCommandQueue.argtypes = [c_void_p, c_void_p, c_uint64, POINTER(c_int32)]
    cl.clCreateCommandQueue.restype = c_void_p
    cl.clCreateBuffer.argtypes = [c_void_p, c_uint64, c_size_t, c_void_p, POINTER(c_int32)]
    cl.clCreateBuffer.restype = c_void_p
    cl.clBuildProgram.argtypes = [c_void_p, c_uint32, POINTER(c_void_p), ctypes.c_char_p,
                                  c_void_p, c_void_p]
    cl.clBuildProgram.restype = c_int32
    cl.clGetProgramBuildInfo.argtypes = [c_void_p, c_void_p, c_uint32, c_size_t,
                                         c_void_p, POINTER(c_size_t)]
    cl.clGetProgramBuildInfo.restype = c_int32
    cl.clCreateKernel.argtypes = [c_void_p, ctypes.c_char_p, POINTER(c_int32)]
    cl.clCreateKernel.restype = c_void_p
    cl.clSetKernelArg.argtypes = [c_void_p, c_uint32, c_size_t, c_void_p]
    cl.clSetKernelArg.restype = c_int32
    cl.clEnqueueNDRangeKernel.argtypes = [c_void_p, c_void_p, c_uint32, POINTER(c_size_t),
                                          POINTER(c_size_t), POINTER(c_size_t), c_uint32,
                                          c_void_p, c_void_p]
    cl.clEnqueueNDRangeKernel.restype = c_int32
    cl.clEnqueueReadBuffer.argtypes = [c_void_p, c_void_p, c_uint32, c_size_t, c_size_t,
                                       c_void_p, c_uint32, c_void_p, c_void_p]
    cl.clEnqueueReadBuffer.restype = c_int32
    cl.clFinish.argtypes = [c_void_p]
    cl.clFinish.restype = c_int32


def info_str(fn, obj, param):
    n = c_size_t()
    if fn(c_void_p(obj), param, 0, None, byref(n)) != 0:
        return ""
    buf = ctypes.create_string_buffer(n.value)
    fn(c_void_p(obj), param, n.value, buf, None)
    return buf.value.decode(errors="replace")


# --------------------------------------------------------------------------
# Minimal OpenCL-flavor SPIR-V:  kernel void k(global uint *p) { *p = 42; }
# --------------------------------------------------------------------------

def op(opcode, *operands):
    words = [((1 + len(operands)) << 16) | opcode]
    words.extend(operands)
    return words


def op_str(opcode, *pre, text):
    raw = text.encode() + b"\x00"
    raw += b"\x00" * ((4 - len(raw) % 4) % 4)
    lit = list(struct.unpack(f"<{len(raw)//4}I", raw))
    words = [((1 + len(pre) + len(lit)) << 16) | opcode]
    words.extend(pre)
    words.extend(lit)
    return words


def build_spirv(address_bits: int) -> bytes:
    VOID, U32, PTR, FNTY, C42, FN, PARAM, LABEL = 1, 2, 3, 4, 5, 6, 7, 8
    bound = 9
    physical = 2 if address_bits == 64 else 1  # Physical64 : Physical32

    words = [0x07230203, 0x00010000, 0, bound, 0]  # magic, v1.0, gen, bound, 0
    words += op(17, 4)                    # OpCapability Addresses
    words += op(17, 6)                    # OpCapability Kernel
    words += op(14, physical, 2)          # OpMemoryModel Physical{32,64} OpenCL
    words += op_str(15, 6, FN, text="k")  # OpEntryPoint Kernel %fn "k"
    words += op(19, VOID)                 # OpTypeVoid
    words += op(21, U32, 32, 0)           # OpTypeInt 32 unsigned
    words += op(32, PTR, 5, U32)          # OpTypePointer CrossWorkgroup u32
    words += op(33, FNTY, VOID, PTR)      # OpTypeFunction void(ptr)
    words += op(43, U32, C42, 42)         # OpConstant u32 42
    words += op(54, VOID, FN, 0, FNTY)    # OpFunction
    words += op(55, PTR, PARAM)           # OpFunctionParameter
    words += op(248, LABEL)               # OpLabel
    words += op(62, PARAM, C42)           # OpStore %param %c42
    words += [(1 << 16) | 253]            # OpReturn
    words += [(1 << 16) | 56]             # OpFunctionEnd
    return struct.pack(f"<{len(words)}I", *words)


def test_platform(cl, plat, create_il) -> str:
    dn = c_uint32()
    if cl.clGetDeviceIDs(plat, CL_DEVICE_TYPE_ALL, 0, None, byref(dn)) != 0 or not dn.value:
        return "no devices"
    devs = (c_void_p * dn.value)()
    cl.clGetDeviceIDs(plat, CL_DEVICE_TYPE_ALL, dn.value, devs, None)
    # Prefer the Adreno; never the Basic Render Driver - a pass on a software
    # rasteriser would prove nothing about the GPU.
    dev = None
    for d in devs[: dn.value]:
        if "Adreno" in info_str(cl.clGetDeviceInfo, d, CL_DEVICE_NAME):
            dev = d
            break
    if dev is None:
        return "no Adreno device on this platform"

    print(f"   device  : {info_str(cl.clGetDeviceInfo, dev, CL_DEVICE_NAME)}")
    il = info_str(cl.clGetDeviceInfo, dev, CL_DEVICE_IL_VERSION)
    exts = info_str(cl.clGetDeviceInfo, dev, CL_DEVICE_EXTENSIONS)
    bits = c_uint32()
    cl.clGetDeviceInfo(c_void_p(dev), CL_DEVICE_ADDRESS_BITS, 4, byref(bits), None)
    has_ext = "cl_khr_il_program" in exts
    print(f"   addr bits {bits.value} | IL_VERSION {il or repr('')} | cl_khr_il_program {has_ext}")

    if not il and not has_ext:
        return "NO SPIR-V ingestion"

    # Resolve ingestion per-platform. The loader's core clCreateProgramWithIL
    # slot AVs on this OpenCLOn12 (dispatch-table shape mismatch); the
    # per-platform extension pointer is the ICD-clean route.
    gexfa = cl.clGetExtensionFunctionAddressForPlatform
    gexfa.argtypes = [c_void_p, ctypes.c_char_p]
    gexfa.restype = c_void_p
    ILFN = ctypes.CFUNCTYPE(c_void_p, c_void_p, c_void_p, c_size_t, POINTER(c_int32))
    addr = gexfa(plat, b"clCreateProgramWithILKHR")
    if addr:
        create_il = ILFN(addr)
        print("   ingestion via clCreateProgramWithILKHR (platform extension ptr)")
    elif create_il:
        print("   ingestion via core clCreateProgramWithIL")
    else:
        return "IL advertised but no callable entry point"

    spv = build_spirv(bits.value)
    err = c_int32()
    devs1 = (c_void_p * 1)(dev)
    # With two platforms installed, clCreateContext(NULL props) is ambiguous
    # and OpenCLOn12 returns null. Name the platform explicitly.
    CL_CONTEXT_PLATFORM = 0x1084
    props = (ctypes.c_size_t * 3)(CL_CONTEXT_PLATFORM, ctypes.cast(plat, ctypes.c_void_p).value or 0, 0)
    cl.clCreateContext.argtypes = [POINTER(ctypes.c_size_t), c_uint32, POINTER(c_void_p),
                                   c_void_p, c_void_p, POINTER(c_int32)]
    ctx = cl.clCreateContext(props, 1, devs1, None, None, byref(err))
    if err.value != 0 or not ctx:
        return f"clCreateContext failed ({err.value})"
    q = cl.clCreateCommandQueue(ctx, c_void_p(dev), 0, byref(err))
    if err.value != 0 or not q:
        return f"clCreateCommandQueue failed ({err.value})"
    prog = create_il(ctx, spv, len(spv), byref(err))
    if err.value != 0 or not prog:
        return f"IL advertised but clCreateProgramWithIL failed ({err.value})"
    if cl.clBuildProgram(prog, 1, devs1, None, None, None) != 0:
        ln = c_size_t()
        cl.clGetProgramBuildInfo(prog, c_void_p(dev), CL_PROGRAM_BUILD_LOG, 0, None,
                                 byref(ln))
        log = ctypes.create_string_buffer(max(ln.value, 1))
        cl.clGetProgramBuildInfo(prog, c_void_p(dev), CL_PROGRAM_BUILD_LOG, ln.value,
                                 log, None)
        print(f"   build log: {log.value.decode(errors='replace')[:300]}")
        return "SPIR-V accepted but clBuildProgram FAILED"
    kern = cl.clCreateKernel(prog, b"k", byref(err))
    if err.value != 0:
        return f"built but clCreateKernel failed ({err.value})"
    buf = cl.clCreateBuffer(ctx, CL_MEM_READ_WRITE, 4, None, byref(err))
    hbuf = c_void_p(buf)
    cl.clSetKernelArg(kern, 0, ctypes.sizeof(c_void_p), byref(hbuf))
    gws = (c_size_t * 1)(1)
    rc = cl.clEnqueueNDRangeKernel(q, kern, 1, None, gws, None, 0, None, None)
    if rc != 0:
        return f"dispatch failed ({rc})"
    cl.clFinish(q)
    out = c_uint32(0)
    cl.clEnqueueReadBuffer(q, buf, CL_TRUE, 0, 4, byref(out), 0, None, None)
    cl.clFinish(q)
    print(f"   executed hand-encoded SPIR-V: read back {out.value} (want 42)")
    return "SPIR-V EXECUTES, verified" if out.value == 42 else f"ran, wrong result ({out.value})"


def main() -> int:
    cl = ctypes.CDLL(r"C:\Windows\System32\OpenCL.dll")
    bind(cl)
    try:
        create_il = cl.clCreateProgramWithIL
        create_il.argtypes = [c_void_p, c_void_p, c_size_t, POINTER(c_int32)]
        create_il.restype = c_void_p
    except AttributeError:
        create_il = None
        print("loader exports no clCreateProgramWithIL")

    n = c_uint32()
    cl.clGetPlatformIDs(0, None, byref(n))
    plats = (c_void_p * n.value)()
    cl.clGetPlatformIDs(n.value, plats, None)

    verdicts = {}
    for p in plats[: n.value]:
        name = info_str(cl.clGetPlatformInfo, p, CL_PLATFORM_NAME)
        print(f"\n== platform: {name}")
        verdicts[name] = test_platform(cl, p, create_il)

    print("\n===== per-platform verdicts =====")
    for k, v in verdicts.items():
        print(f"  {k:38} {v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
