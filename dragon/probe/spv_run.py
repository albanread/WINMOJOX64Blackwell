"""Load a .spv through OpenCLOn12 exactly as dragonrt does, step by step:
ingest, build, create the entry-point kernel (name parsed from the module),
and - when the signature is the saxpy shape (3 buffers + float) - launch and
verify the arithmetic on the host.

    python spv_run.py <module.spv> [--no-launch]
"""

from __future__ import annotations

import ctypes
import struct
import sys
from ctypes import POINTER, byref, c_int32, c_size_t, c_uint32, c_uint64, c_void_p

CL_PLATFORM_NAME = 0x0902
CL_DEVICE_NAME = 0x102B
CL_DEVICE_TYPE_ALL = 0xFFFFFFFF
CL_MEM_READ_WRITE = 1 << 0
CL_TRUE = 1
CL_PROGRAM_BUILD_LOG = 0x1183
CL_CONTEXT_PLATFORM = 0x1084

N = 4096
BLOCK = 64
A = 2.5


def entry_point_name(words):
    i = 5
    while i < len(words):
        wc, op = words[i] >> 16, words[i] & 0xFFFF
        if op == 15:  # OpEntryPoint
            raw = b""
            j = i + 3
            while j < i + wc:
                raw += struct.pack("<I", words[j])
                j += 1
                if 0 in raw[-4:]:
                    break
            return raw.split(b"\x00")[0]
        i += wc
    return None


def main():
    path = sys.argv[1]
    data = open(path, "rb").read()
    words = list(struct.unpack(f"<{len(data)//4}I", data))
    name = entry_point_name(words)
    print(f"module : {path} ({len(data)} bytes)")
    print(f"entry  : {name.decode(errors='replace')[:80]}... ({len(name)} chars)")

    cl = ctypes.CDLL(r"C:\Windows\System32\OpenCL.dll")
    cl.clGetPlatformIDs.argtypes = [c_uint32, POINTER(c_void_p), POINTER(c_uint32)]
    cl.clGetPlatformInfo.argtypes = [c_void_p, c_uint32, c_size_t, c_void_p,
                                     POINTER(c_size_t)]
    cl.clGetDeviceIDs.argtypes = [c_void_p, c_uint64, c_uint32, POINTER(c_void_p),
                                  POINTER(c_uint32)]
    cl.clGetDeviceInfo.argtypes = [c_void_p, c_uint32, c_size_t, c_void_p,
                                   POINTER(c_size_t)]
    cl.clCreateContext.argtypes = [POINTER(ctypes.c_size_t), c_uint32,
                                   POINTER(c_void_p), c_void_p, c_void_p,
                                   POINTER(c_int32)]
    cl.clCreateContext.restype = c_void_p
    cl.clCreateCommandQueue.argtypes = [c_void_p, c_void_p, c_uint64,
                                        POINTER(c_int32)]
    cl.clCreateCommandQueue.restype = c_void_p
    cl.clCreateBuffer.argtypes = [c_void_p, c_uint64, c_size_t, c_void_p,
                                  POINTER(c_int32)]
    cl.clCreateBuffer.restype = c_void_p
    cl.clBuildProgram.argtypes = [c_void_p, c_uint32, POINTER(c_void_p),
                                  ctypes.c_char_p, c_void_p, c_void_p]
    cl.clGetProgramBuildInfo.argtypes = [c_void_p, c_void_p, c_uint32, c_size_t,
                                         c_void_p, POINTER(c_size_t)]
    cl.clCreateKernel.argtypes = [c_void_p, ctypes.c_char_p, POINTER(c_int32)]
    cl.clCreateKernel.restype = c_void_p
    cl.clSetKernelArg.argtypes = [c_void_p, c_uint32, c_size_t, c_void_p]
    cl.clEnqueueWriteBuffer.argtypes = [c_void_p, c_void_p, c_uint32, c_size_t,
                                        c_size_t, c_void_p, c_uint32, c_void_p,
                                        c_void_p]
    cl.clEnqueueReadBuffer.argtypes = cl.clEnqueueWriteBuffer.argtypes
    cl.clEnqueueNDRangeKernel.argtypes = [c_void_p, c_void_p, c_uint32,
                                          POINTER(c_size_t), POINTER(c_size_t),
                                          POINTER(c_size_t), c_uint32, c_void_p,
                                          c_void_p]
    cl.clFinish.argtypes = [c_void_p]
    cl.clGetExtensionFunctionAddressForPlatform.argtypes = [c_void_p,
                                                            ctypes.c_char_p]
    cl.clGetExtensionFunctionAddressForPlatform.restype = c_void_p

    np = c_uint32()
    cl.clGetPlatformIDs(0, None, byref(np))
    plats = (c_void_p * np.value)()
    cl.clGetPlatformIDs(np.value, plats, None)
    plat = dev = None
    for p in plats[: np.value]:
        n = c_size_t()
        cl.clGetPlatformInfo(p, CL_PLATFORM_NAME, 0, None, byref(n))
        buf = ctypes.create_string_buffer(n.value)
        cl.clGetPlatformInfo(p, CL_PLATFORM_NAME, n.value, buf, None)
        if b"OpenCLOn12" not in buf.value:
            continue
        nd = c_uint32()
        cl.clGetDeviceIDs(p, CL_DEVICE_TYPE_ALL, 0, None, byref(nd))
        devs = (c_void_p * nd.value)()
        cl.clGetDeviceIDs(p, CL_DEVICE_TYPE_ALL, nd.value, devs, None)
        for d in devs[: nd.value]:
            m = c_size_t()
            cl.clGetDeviceInfo(d, CL_DEVICE_NAME, 0, None, byref(m))
            nb = ctypes.create_string_buffer(m.value)
            cl.clGetDeviceInfo(d, CL_DEVICE_NAME, m.value, nb, None)
            if b"Adreno" in nb.value:
                plat, dev = p, d
                break
        if dev:
            break
    if not dev:
        print("no OpenCLOn12 Adreno")
        return 2

    err = c_int32()
    devs1 = (c_void_p * 1)(dev)
    props = (ctypes.c_size_t * 3)(CL_CONTEXT_PLATFORM,
                                  ctypes.cast(plat, ctypes.c_void_p).value, 0)
    ctx = cl.clCreateContext(props, 1, devs1, None, None, byref(err))
    q = cl.clCreateCommandQueue(ctx, c_void_p(dev), 0, byref(err))

    ILFN = ctypes.CFUNCTYPE(c_void_p, c_void_p, c_void_p, c_size_t,
                            POINTER(c_int32))
    create_il = ILFN(cl.clGetExtensionFunctionAddressForPlatform(
        plat, b"clCreateProgramWithILKHR"))

    prog = create_il(ctx, data, len(data), byref(err))
    print(f"ingest : {'ok' if err.value == 0 and prog else f'FAIL {err.value}'}")
    if err.value != 0:
        return 1
    rc = cl.clBuildProgram(prog, 1, devs1, None, None, None)
    if rc != 0:
        ln = c_size_t()
        cl.clGetProgramBuildInfo(prog, c_void_p(dev), CL_PROGRAM_BUILD_LOG, 0,
                                 None, byref(ln))
        log = ctypes.create_string_buffer(max(ln.value, 1))
        cl.clGetProgramBuildInfo(prog, c_void_p(dev), CL_PROGRAM_BUILD_LOG,
                                 ln.value, log, None)
        print(f"build  : FAIL {rc}\n{log.value.decode(errors='replace')[:400]}")
        return 1
    print("build  : ok")

    kern = cl.clCreateKernel(prog, name, byref(err))
    print(f"create : {'ok' if err.value == 0 and kern else f'FAIL {err.value}'}")
    if err.value != 0:
        return 1

    if "--no-launch" in sys.argv:
        return 0

    xs = [float(i) for i in range(N)]
    ys = [float(N - i) for i in range(N)]
    xh = struct.pack(f"{N}f", *xs)
    yh = struct.pack(f"{N}f", *ys)
    nb = N * 4
    bufs = []
    for init in (xh, yh, None):
        b = cl.clCreateBuffer(ctx, CL_MEM_READ_WRITE, nb, None, byref(err))
        bufs.append(b)
        if init is not None:
            cl.clEnqueueWriteBuffer(q, b, CL_TRUE, 0, nb, init, 0, None, None)
    for i, b in enumerate(bufs):
        h = c_void_p(b)
        cl.clSetKernelArg(kern, i, ctypes.sizeof(c_void_p), byref(h))
    a = ctypes.c_float(A)
    cl.clSetKernelArg(kern, 3, 4, byref(a))
    gws = (c_size_t * 1)(N)
    lws = (c_size_t * 1)(BLOCK)
    rc = cl.clEnqueueNDRangeKernel(q, kern, 1, None, gws, lws, 0, None, None)
    print(f"launch : {'ok' if rc == 0 else f'FAIL {rc}'}")
    if rc != 0:
        return 1
    cl.clFinish(q)
    out = ctypes.create_string_buffer(nb)
    cl.clEnqueueReadBuffer(q, bufs[2], CL_TRUE, 0, nb, out, 0, None, None)
    cl.clFinish(q)
    got = struct.unpack(f"{N}f", out.raw)
    bad = sum(1 for i in range(N) if abs(got[i] - (A * xs[i] + ys[i])) > 1e-3)
    print(f"verify : {N - bad}/{N} correct"
          f"  (out[0]={got[0]}, out[{N-1}]={got[N-1]})")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
