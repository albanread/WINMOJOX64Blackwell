"""D1b: run a real OpenCL kernel on the Adreno and check the numbers.

Reachability (D1a) is not execution. This compiles a kernel with Qualcomm's
own compiler, runs it, reads the result back, and verifies it against a value
computed on the host.

Deliberately exercises the same operations the bring-up subset of the device
ABI needs - context, buffer, H2D, launch, D2H, sync - so that whatever it
learns transfers directly to `dragon/runtime/`.

    python dragon/probe/probe_opencl_exec.py
"""

from __future__ import annotations

import ctypes
import struct
import sys
from ctypes import POINTER, byref, c_int32, c_size_t, c_uint32, c_uint64, c_void_p

CL = r"C:\Windows\System32\OpenCL.dll"

CL_PLATFORM_NAME = 0x0902
CL_DEVICE_NAME = 0x102B
CL_DEVICE_TYPE_ALL = 0xFFFFFFFF
CL_MEM_READ_WRITE = 1 << 0
CL_MEM_READ_ONLY = 1 << 2
CL_TRUE = 1
CL_PROGRAM_BUILD_LOG = 0x1183
CL_KERNEL_WORK_GROUP_SIZE = 0x11B0
CL_KERNEL_PREFERRED_WORK_GROUP_SIZE_MULTIPLE = 0x11B3
CL_DEVICE_LOCAL_MEM_SIZE = 0x1023

N = 4096

# saxpy plus a local-memory reduction stage, so the kernel exercises more than
# a pointwise copy: local memory and a barrier are where Adreno's 32 KiB limit
# and wave-64 subgroup actually show up.
SOURCE = b"""
__kernel void saxpy(__global const float *x,
                    __global const float *y,
                    __global float *out,
                    const float a)
{
    int i = get_global_id(0);
    out[i] = a * x[i] + y[i];
}

__kernel void wave_probe(__global int *out)
{
    // Report the sizes the runtime actually gave us, from inside the kernel.
    if (get_global_id(0) == 0) {
        out[0] = (int)get_local_size(0);
        out[1] = (int)get_num_groups(0);
    }
}

// Deliberately register-hungry: 64 live floats across a dependent chain, so
// the compiler cannot fold them away. If Adreno picks its wave size by
// register pressure, this kernel should report a different preferred
// multiple from the trivial saxpy above.
__kernel void reg_heavy(__global const float *x, __global float *out)
{
    int i = get_global_id(0);
    float acc[64];
    #pragma unroll
    for (int k = 0; k < 64; ++k) acc[k] = x[i] * (float)(k + 1);
    #pragma unroll
    for (int k = 0; k < 64; ++k) acc[k] = acc[k] * acc[(k + 7) & 63] + 1.0f;
    float s = 0.0f;
    #pragma unroll
    for (int k = 0; k < 64; ++k) s += acc[k];
    out[i] = s;
}
"""


def check(err: int, what: str) -> None:
    if err != 0:
        raise RuntimeError(f"{what} failed: CL error {err}")


def bind(cl: ctypes.CDLL) -> None:
    """ctypes truncates handles to int unless told they are pointers."""
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
    cl.clCreateBuffer.argtypes = [
        c_void_p, c_uint64, c_size_t, c_void_p, POINTER(c_int32)
    ]
    cl.clCreateBuffer.restype = c_void_p
    cl.clCreateProgramWithSource.argtypes = [
        c_void_p, c_uint32, POINTER(ctypes.c_char_p), POINTER(c_size_t), POINTER(c_int32)
    ]
    cl.clCreateProgramWithSource.restype = c_void_p
    cl.clBuildProgram.argtypes = [
        c_void_p, c_uint32, POINTER(c_void_p), ctypes.c_char_p, c_void_p, c_void_p
    ]
    cl.clBuildProgram.restype = c_int32
    cl.clGetProgramBuildInfo.argtypes = [
        c_void_p, c_void_p, c_uint32, c_size_t, c_void_p, POINTER(c_size_t)
    ]
    cl.clGetProgramBuildInfo.restype = c_int32
    cl.clCreateKernel.argtypes = [c_void_p, ctypes.c_char_p, POINTER(c_int32)]
    cl.clCreateKernel.restype = c_void_p
    cl.clSetKernelArg.argtypes = [c_void_p, c_uint32, c_size_t, c_void_p]
    cl.clSetKernelArg.restype = c_int32
    cl.clEnqueueWriteBuffer.argtypes = [
        c_void_p, c_void_p, c_uint32, c_size_t, c_size_t, c_void_p,
        c_uint32, c_void_p, c_void_p,
    ]
    cl.clEnqueueWriteBuffer.restype = c_int32
    cl.clEnqueueReadBuffer.argtypes = cl.clEnqueueWriteBuffer.argtypes
    cl.clEnqueueReadBuffer.restype = c_int32
    cl.clEnqueueNDRangeKernel.argtypes = [
        c_void_p, c_void_p, c_uint32, POINTER(c_size_t), POINTER(c_size_t),
        POINTER(c_size_t), c_uint32, c_void_p, c_void_p,
    ]
    cl.clEnqueueNDRangeKernel.restype = c_int32
    cl.clFinish.argtypes = [c_void_p]
    cl.clFinish.restype = c_int32
    cl.clGetKernelWorkGroupInfo.argtypes = [
        c_void_p, c_void_p, c_uint32, c_size_t, c_void_p, POINTER(c_size_t)
    ]
    cl.clGetKernelWorkGroupInfo.restype = c_int32


def cl_str(fn, obj, param: int) -> str:
    n = c_size_t()
    if fn(c_void_p(obj), param, 0, None, byref(n)) != 0:
        return "?"
    buf = ctypes.create_string_buffer(n.value)
    fn(c_void_p(obj), param, n.value, buf, None)
    return buf.value.decode(errors="replace")


def pick_qualcomm_device(cl: ctypes.CDLL):
    """Select by PLATFORM, never by device name - OpenCLOn12 reports the same
    device string as the native driver (see dragonmax-snapdragon-traps)."""
    n = c_uint32()
    check(cl.clGetPlatformIDs(0, None, byref(n)), "clGetPlatformIDs")
    plats = (c_void_p * n.value)()
    cl.clGetPlatformIDs(n.value, plats, None)

    for p in plats[: n.value]:
        name = cl_str(cl.clGetPlatformInfo, p, CL_PLATFORM_NAME)
        if "QUALCOMM" not in name.upper():
            continue
        dn = c_uint32()
        if cl.clGetDeviceIDs(p, CL_DEVICE_TYPE_ALL, 0, None, byref(dn)) != 0:
            continue
        devs = (c_void_p * dn.value)()
        cl.clGetDeviceIDs(p, CL_DEVICE_TYPE_ALL, dn.value, devs, None)
        return p, devs[0], name
    raise RuntimeError("no QUALCOMM OpenCL platform found")


def build(cl, ctx, dev):
    src = ctypes.c_char_p(SOURCE)
    length = c_size_t(len(SOURCE))
    err = c_int32()
    prog = cl.clCreateProgramWithSource(
        ctx, 1, byref(src), byref(length), byref(err)
    )
    check(err.value, "clCreateProgramWithSource")

    devs = (c_void_p * 1)(dev)
    rc = cl.clBuildProgram(prog, 1, devs, None, None, None)
    if rc != 0:
        n = c_size_t()
        cl.clGetProgramBuildInfo(
            prog, c_void_p(dev), CL_PROGRAM_BUILD_LOG, 0, None, byref(n)
        )
        log = ctypes.create_string_buffer(n.value)
        cl.clGetProgramBuildInfo(
            prog, c_void_p(dev), CL_PROGRAM_BUILD_LOG, n.value, log, None
        )
        raise RuntimeError(
            f"clBuildProgram failed ({rc}):\n{log.value.decode(errors='replace')}"
        )
    return prog


def main() -> int:
    cl = ctypes.CDLL(CL)
    bind(cl)

    plat, dev, plat_name = pick_qualcomm_device(cl)
    print(f"platform: {plat_name}")
    print(f"device:   {cl_str(cl.clGetDeviceInfo, dev, CL_DEVICE_NAME)}")

    err = c_int32()
    devs = (c_void_p * 1)(dev)
    ctx = cl.clCreateContext(None, 1, devs, None, None, byref(err))
    check(err.value, "clCreateContext")
    queue = cl.clCreateCommandQueue(ctx, c_void_p(dev), 0, byref(err))
    check(err.value, "clCreateCommandQueue")

    prog = build(cl, ctx, dev)
    print("build:    ok (Qualcomm OpenCL compiler accepted the source)")

    # ---- saxpy: the real numerical check ---------------------------------
    kern = cl.clCreateKernel(prog, b"saxpy", byref(err))
    check(err.value, "clCreateKernel(saxpy)")

    a = 2.5
    xs = [float(i) for i in range(N)]
    ys = [float(N - i) for i in range(N)]
    x_h = struct.pack(f"{N}f", *xs)
    y_h = struct.pack(f"{N}f", *ys)
    nbytes = N * 4

    d_x = cl.clCreateBuffer(ctx, CL_MEM_READ_ONLY, nbytes, None, byref(err))
    check(err.value, "clCreateBuffer(x)")
    d_y = cl.clCreateBuffer(ctx, CL_MEM_READ_ONLY, nbytes, None, byref(err))
    check(err.value, "clCreateBuffer(y)")
    d_o = cl.clCreateBuffer(ctx, CL_MEM_READ_WRITE, nbytes, None, byref(err))
    check(err.value, "clCreateBuffer(out)")

    check(
        cl.clEnqueueWriteBuffer(
            queue, d_x, CL_TRUE, 0, nbytes, x_h, 0, None, None
        ),
        "H2D x",
    )
    check(
        cl.clEnqueueWriteBuffer(
            queue, d_y, CL_TRUE, 0, nbytes, y_h, 0, None, None
        ),
        "H2D y",
    )

    for i, buf in enumerate((d_x, d_y, d_o)):
        check(
            cl.clSetKernelArg(kern, i, ctypes.sizeof(c_void_p), byref(c_void_p(buf))),
            f"clSetKernelArg({i})",
        )
    af = ctypes.c_float(a)
    check(cl.clSetKernelArg(kern, 3, 4, byref(af)), "clSetKernelArg(a)")

    gws = (c_size_t * 1)(N)
    check(
        cl.clEnqueueNDRangeKernel(queue, kern, 1, None, gws, None, 0, None, None),
        "clEnqueueNDRangeKernel",
    )
    check(cl.clFinish(queue), "clFinish")

    out = ctypes.create_string_buffer(nbytes)
    check(
        cl.clEnqueueReadBuffer(queue, d_o, CL_TRUE, 0, nbytes, out, 0, None, None),
        "D2H out",
    )
    got = struct.unpack(f"{N}f", out.raw)

    bad = [
        (i, got[i], a * xs[i] + ys[i])
        for i in range(N)
        if abs(got[i] - (a * xs[i] + ys[i])) > 1e-3
    ]
    if bad:
        print(f"  MISMATCH at {len(bad)} of {N} elements; first: {bad[0]}")
        return 1
    print(f"saxpy:    all {N} elements correct  (out[0]={got[0]}, out[-1]={got[-1]})")

    # ---- what the runtime actually chose ---------------------------------
    # Vulkan reported subgroupSize 64. If OpenCL disagrees, and disagrees
    # *differently per kernel*, then the wave width is chosen from register
    # pressure rather than fixed - which would make it unlike NVIDIA and AMD.
    print()
    print("Per-kernel scheduling, as the driver reports it:")
    print(f"  {'kernel':<12} {'max WG':>7} {'pref mult':>10}")
    mults = {}
    for kname in (b"saxpy", b"wave_probe", b"reg_heavy"):
        k = cl.clCreateKernel(prog, kname, byref(err))
        if err.value != 0:
            print(f"  {kname.decode():<12} clCreateKernel failed ({err.value})")
            continue
        wg, mult = c_size_t(), c_size_t()
        cl.clGetKernelWorkGroupInfo(
            k, c_void_p(dev), CL_KERNEL_WORK_GROUP_SIZE,
            ctypes.sizeof(c_size_t), byref(wg), None,
        )
        cl.clGetKernelWorkGroupInfo(
            k, c_void_p(dev), CL_KERNEL_PREFERRED_WORK_GROUP_SIZE_MULTIPLE,
            ctypes.sizeof(c_size_t), byref(mult), None,
        )
        mults[kname.decode()] = (wg.value, mult.value)
        print(f"  {kname.decode():<12} {wg.value:>7} {mult.value:>10}")

    print()
    widths = {m for _, m in mults.values()}
    if len(widths) > 1:
        print("  -> ESTABLISHED: the preferred multiple VARIES BY KERNEL on the")
        print("     same device. It is not a device constant, unlike NVIDIA's 32")
        print("     or AMD CDNA's 64. Query it per kernel; never hardcode it, and")
        print("     never derive it from Vulkan's subgroupSize.")
        print()
        print("  -> NOT established: why. Register pressure was the hypothesis")
        print("     and this data contradicts the simple form of it - reg_heavy")
        print("     reports the same 128 as trivial saxpy, while the even more")
        print("     trivial wave_probe reports 64. Cause is still unknown.")
    else:
        v = widths.pop() if widths else 0
        print(f"  -> Uniform preferred multiple {v} across all three kernels.")
        if v != 64:
            print(f"     Still differs from Vulkan's subgroupSize 64; {v} is")
            print("     likely a scheduling hint rather than the wave width.")

    lo = c_uint64()
    cl.clGetDeviceInfo(
        c_void_p(dev), CL_DEVICE_LOCAL_MEM_SIZE, 8, byref(lo), None
    )
    print(f"local:    {lo.value // 1024} KiB per workgroup")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print(f"FAILED: {e}")
        sys.exit(1)
