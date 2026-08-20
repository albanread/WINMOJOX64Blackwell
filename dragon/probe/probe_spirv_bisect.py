"""Bisect the real Mojo-emitted SPIR-V module against OpenCLOn12.

probe_spirv_namelen.py exonerated every hypothesis reachable by hand-encoding
a lookalike: name length (444 chars), BuiltIn globals, the real argument
signature, a Constant-decorated WorkgroupSize, and SPIR-V 1.4 are all callable
when we build them ourselves. So the cause is something in the actual module
that a reconstruction does not capture -- which means bisecting the bytes.

Feed it a module captured with DRAGONRT_DUMP_SPV:

    python dragon/probe/probe_spirv_bisect.py <file.spv>

It first confirms the harness reproduces the failure, then removes one class
of instruction at a time and retries, reporting which removal makes the kernel
creatable. The SPIR-V stream is (wordcount << 16 | opcode) all the way down,
so dropping an instruction is a slice -- no SPIRV-Tools needed.
"""

import struct
import sys
from ctypes import (
    CDLL,
    CFUNCTYPE,
    POINTER,
    byref,
    c_int32,
    c_size_t,
    c_uint32,
    c_void_p,
    create_string_buffer,
)

CL_PLATFORM_NAME = 0x0902
CL_DEVICE_TYPE_ALL = 0xFFFFFFFF
CL_CONTEXT_PLATFORM = 0x1084
CL_PROGRAM_BUILD_LOG = 0x1183

OP_NAME = 5
OP_DECORATE = 71
OP_SOURCE = 3
OP_EXEC_MODE = 16
DECOR_CONSTANT = 22
DECOR_FUNCPARAM = 38


def words_of(blob):
    return list(struct.unpack("<%dI" % (len(blob) // 4), blob))


def blob_of(words):
    return struct.pack("<%dI" % len(words), *words)


def instructions(words):
    """Yield (index, length, opcode) for each instruction after the header."""
    i = 5
    while i < len(words):
        ln = words[i] >> 16
        if ln == 0:
            break
        yield i, ln, words[i] & 0xFFFF
        i += ln


def entry_name(words):
    for i, ln, opc in instructions(words):
        if opc == 15:  # OpEntryPoint: model, fn, then the literal name
            raw = blob_of(words[i + 3 : i + ln])
            return raw.split(b"\0")[0].decode(errors="replace")
    return None


def strip(words, predicate):
    """Copy the module without instructions the predicate selects."""
    out = list(words[:5])
    for i, ln, opc in instructions(words):
        if predicate(opc, words[i : i + ln]):
            continue
        out.extend(words[i : i + ln])
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    blob = open(sys.argv[1], "rb").read()
    words = words_of(blob)
    name = entry_name(words)
    print("module:  %s (%d bytes)" % (sys.argv[1].split("\\")[-1], len(blob)))
    print("version: %d.%d" % ((words[1] >> 16) & 0xFF, (words[1] >> 8) & 0xFF))
    print("entry:   %s..." % (name[:60] if name else "(none)"))

    cl = CDLL("OpenCL.dll")
    cl.clGetExtensionFunctionAddressForPlatform.argtypes = [c_void_p, c_void_p]
    cl.clGetExtensionFunctionAddressForPlatform.restype = c_void_p
    cl.clCreateContext.restype = c_void_p
    cl.clCreateKernel.restype = c_void_p

    pn = c_uint32()
    cl.clGetPlatformIDs(0, None, byref(pn))
    plats = (c_void_p * pn.value)()
    cl.clGetPlatformIDs(pn, plats, None)

    il_create = plat = None
    for p in plats:
        addr = cl.clGetExtensionFunctionAddressForPlatform(
            c_void_p(p), b"clCreateProgramWithILKHR"
        )
        if addr:
            ILFn = CFUNCTYPE(c_void_p, c_void_p, c_void_p, c_size_t, POINTER(c_int32))
            il_create, plat = ILFn(addr), p
            break
    if not il_create:
        print("no IL-capable platform")
        return 1

    dn = c_uint32()
    cl.clGetDeviceIDs(c_void_p(plat), CL_DEVICE_TYPE_ALL, 0, None, byref(dn))
    devs = (c_void_p * dn.value)()
    cl.clGetDeviceIDs(c_void_p(plat), CL_DEVICE_TYPE_ALL, dn, devs, None)
    devs1 = (c_void_p * 1)(devs[0])
    props = (c_void_p * 3)(c_void_p(CL_CONTEXT_PLATFORM), c_void_p(plat), c_void_p(0))
    err = c_int32()
    ctx = cl.clCreateContext(props, 1, devs1, None, None, byref(err))
    if not ctx:
        print("clCreateContext failed: %d" % err.value)
        return 1

    def attempt(mod_words, label):
        spv = blob_of(mod_words)
        prog = il_create(ctx, spv, len(spv), byref(err))
        if not prog:
            return "%-34s IL rejected (%d)" % (label, err.value)
        rc = cl.clBuildProgram(c_void_p(prog), 1, devs1, None, None, None)
        if rc != 0:
            n = c_size_t()
            cl.clGetProgramBuildInfo(
                c_void_p(prog), devs[0], CL_PROGRAM_BUILD_LOG, 0, None, byref(n)
            )
            log = create_string_buffer(n.value or 1)
            if n.value:
                cl.clGetProgramBuildInfo(
                    c_void_p(prog), devs[0], CL_PROGRAM_BUILD_LOG, n, log, None
                )
            cl.clReleaseProgram(c_void_p(prog))
            return "%-34s build failed (%d) %s" % (
                label, rc, log.value.decode(errors="replace")[:80]
            )
        kern = cl.clCreateKernel(c_void_p(prog), name.encode(), byref(err))
        ok = bool(kern)
        if kern:
            cl.clReleaseKernel(c_void_p(kern))
        cl.clReleaseProgram(c_void_p(prog))
        return "%-34s %s" % (label, "CALLABLE" if ok else "clCreateKernel %d" % err.value)

    print()
    print(attempt(words, "as emitted"))

    trials = [
        ("without OpName", lambda o, w: o == OP_NAME),
        ("without OpSource", lambda o, w: o == OP_SOURCE),
        ("without OpExecutionMode", lambda o, w: o == OP_EXEC_MODE),
        (
            "without Constant decorations",
            lambda o, w: o == OP_DECORATE and len(w) > 2 and w[2] == DECOR_CONSTANT,
        ),
        (
            "without FuncParamAttr",
            lambda o, w: o == OP_DECORATE and len(w) > 2 and w[2] == DECOR_FUNCPARAM,
        ),
        ("without any OpDecorate", lambda o, w: o == OP_DECORATE),
        (
            "without debug (Name+Source)",
            lambda o, w: o in (OP_NAME, OP_SOURCE),
        ),
    ]
    for label, pred in trials:
        print(attempt(strip(words, pred), label))

    # Version downgrade, orthogonal to instruction stripping.
    for v, tag in ((0x00010000, "1.0"), (0x00010200, "1.2")):
        w2 = list(words)
        w2[1] = v
        print(attempt(w2, "as emitted, version %s" % tag))

    return 0


if __name__ == "__main__":
    sys.exit(main())
