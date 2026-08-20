"""D1 probe: can a native ARM64 process reach each Snapdragon compute surface?

Read-only. Loads vendor runtimes via ctypes and asks them what they are.
No build system, no Mojo - this is meant to run before anything else works.

    python dragon/probe/probe_surfaces.py
"""

from __future__ import annotations

import ctypes
import os
import platform
import sys
from ctypes import POINTER, byref, c_char_p, c_size_t, c_uint32, c_uint64, c_void_p

DRIVER_STORE = r"C:\Windows\System32\DriverStore\FileRepository"
ADRENO_PKG = "qcdx8380.inf_arm64_3555a260d521ff65"
QAIRT_DIR = r"C:\Program Files (x86)\GenieX CLI\qairt\htp-files"

OK, BAD, INFO = "  [ok]", "  [--]", "     "


def head(title: str) -> None:
    print(f"\n{title}\n{'-' * len(title)}")


# --------------------------------------------------------------------------
# OpenCL
# --------------------------------------------------------------------------

CL_PLATFORM_NAME, CL_PLATFORM_VERSION = 0x0902, 0x0901
CL_DEVICE_NAME, CL_DEVICE_VERSION = 0x102B, 0x102C
CL_DEVICE_MAX_COMPUTE_UNITS = 0x1002
CL_DEVICE_MAX_WORK_GROUP_SIZE = 0x1004
CL_DEVICE_LOCAL_MEM_SIZE = 0x1023
CL_DEVICE_GLOBAL_MEM_SIZE = 0x101F
CL_DEVICE_MAX_CLOCK_FREQUENCY = 0x100C
CL_DEVICE_TYPE_ALL = 0xFFFFFFFF


def _cl_bind(cl) -> None:
    """ctypes must be told the handle types, or it truncates them to int."""
    cl.clGetPlatformIDs.argtypes = [c_uint32, POINTER(c_void_p), POINTER(c_uint32)]
    cl.clGetPlatformIDs.restype = ctypes.c_int32
    for fn in (cl.clGetPlatformInfo, cl.clGetDeviceInfo):
        fn.argtypes = [c_void_p, c_uint32, c_size_t, c_void_p, POINTER(c_size_t)]
        fn.restype = ctypes.c_int32
    cl.clGetDeviceIDs.argtypes = [
        c_void_p, c_uint64, c_uint32, POINTER(c_void_p), POINTER(c_uint32)
    ]
    cl.clGetDeviceIDs.restype = ctypes.c_int32


def _cl_str(fn, obj, param: int) -> str:
    n = c_size_t()
    if fn(c_void_p(obj), param, 0, None, byref(n)) != 0:
        return "?"
    buf = ctypes.create_string_buffer(n.value)
    if fn(c_void_p(obj), param, n.value, buf, None) != 0:
        return "?"
    return buf.value.decode(errors="replace")


def _cl_num(fn, obj, param: int, ctype) -> int | None:
    v = ctype()
    if fn(c_void_p(obj), param, ctypes.sizeof(ctype), byref(v), None) != 0:
        return None
    return v.value


def probe_icd_driver(path: str) -> bool:
    """The vendor .dll is an ICD driver, not a loader. Confirm which it is."""
    if not os.path.exists(path):
        print(f"{BAD} OpenCL_adreno.dll: not present")
        return False
    try:
        lib = ctypes.CDLL(path)
    except OSError as e:
        print(f"{BAD} OpenCL_adreno.dll: load failed - {e}")
        return False
    icd = hasattr(lib, "clIcdGetPlatformIDsKHR")
    loader = hasattr(lib, "clGetPlatformIDs")
    print(
        f"{OK} OpenCL_adreno.dll: loads; ICD entry={'yes' if icd else 'no'},"
        f" loader entry={'yes' if loader else 'no'}"
    )
    return icd or loader


def probe_opencl(path: str, label: str) -> bool:
    """Enumerate OpenCL platforms through one specific loader."""
    if not os.path.exists(path):
        print(f"{BAD} {label}: not present at {path}")
        return False
    try:
        cl = ctypes.CDLL(path)
    except OSError as e:
        print(f"{BAD} {label}: load failed - {e}")
        return False

    _cl_bind(cl)
    n = c_uint32()
    if cl.clGetPlatformIDs(0, None, byref(n)) != 0 or n.value == 0:
        # The documented trap: the generic loader finds no registered ICD.
        print(f"{BAD} {label}: loaded, but enumerates 0 platforms")
        return False

    plats = (c_void_p * n.value)()
    cl.clGetPlatformIDs(n.value, plats, None)
    print(f"{OK} {label}: {n.value} platform(s)")

    found_device = False
    for p in plats[: n.value]:
        name = _cl_str(cl.clGetPlatformInfo, p, CL_PLATFORM_NAME)
        ver = _cl_str(cl.clGetPlatformInfo, p, CL_PLATFORM_VERSION)
        note = ""
        if "QUALCOMM" in name.upper():
            note = "   <-- native Adreno driver, use this one"
        elif "ON12" in name.upper().replace(" ", ""):
            note = "   <-- D3D12 translation layer, avoid"
        print(f"{INFO} platform: {name}  ({ver}){note}")

        dn = c_uint32()
        if cl.clGetDeviceIDs(p, CL_DEVICE_TYPE_ALL, 0, None, byref(dn)) != 0 or dn.value == 0:
            continue
        devs = (c_void_p * dn.value)()
        cl.clGetDeviceIDs(p, CL_DEVICE_TYPE_ALL, dn.value, devs, None)

        for d in devs[: dn.value]:
            found_device = True
            gi = _cl_num(cl.clGetDeviceInfo, d, CL_DEVICE_GLOBAL_MEM_SIZE, c_uint64)
            lo = _cl_num(cl.clGetDeviceInfo, d, CL_DEVICE_LOCAL_MEM_SIZE, c_uint64)
            print(f"{INFO}   device: {_cl_str(cl.clGetDeviceInfo, d, CL_DEVICE_NAME)}")
            print(f"{INFO}     {_cl_str(cl.clGetDeviceInfo, d, CL_DEVICE_VERSION)}")
            print(
                f"{INFO}     CUs={_cl_num(cl.clGetDeviceInfo, d, CL_DEVICE_MAX_COMPUTE_UNITS, c_uint32)}"
                f"  clock={_cl_num(cl.clGetDeviceInfo, d, CL_DEVICE_MAX_CLOCK_FREQUENCY, c_uint32)}MHz"
                f"  maxWG={_cl_num(cl.clGetDeviceInfo, d, CL_DEVICE_MAX_WORK_GROUP_SIZE, c_size_t)}"
            )
            print(
                f"{INFO}     local={lo // 1024 if lo else '?'}KiB"
                f"  global={gi // (1024**3) if gi else '?'}GiB"
            )
    return found_device


# --------------------------------------------------------------------------
# QNN / QAIRT  (Hexagon HTP)
# --------------------------------------------------------------------------


class QnnVersion(ctypes.Structure):
    _fields_ = [("major", c_uint32), ("minor", c_uint32), ("patch", c_uint32)]

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"


class QnnApiVersion(ctypes.Structure):
    _fields_ = [("core", QnnVersion), ("backend", QnnVersion)]


class QnnSystemInterface(ctypes.Structure):
    """Prefix of QnnSystemInterface_t.

    Deliberately distinct from QnnInterface below: the system struct has a
    single systemApiVersion where the backend struct has a core+backend pair.
    Reading one with the other's layout yields plausible-looking garbage.
    """

    _fields_ = [
        ("backendId", c_uint32),
        ("providerName", c_char_p),
        ("systemApiVersion", QnnVersion),
    ]


class QnnInterface(ctypes.Structure):
    """Prefix of QnnInterface_t - enough to read identity and version.

    The trailing union of function tables is deliberately not modelled;
    we only need to prove the provider exists and report what it is.
    """

    _fields_ = [
        ("backendId", c_uint32),
        ("providerName", c_char_p),
        ("apiVersion", QnnApiVersion),
    ]


def probe_qnn(dll: str, symbol: str, label: str, struct=None) -> bool:
    path = os.path.join(QAIRT_DIR, dll)
    if not os.path.exists(path):
        print(f"{BAD} {label}: not present at {path}")
        return False
    try:
        lib = ctypes.CDLL(path)
    except OSError as e:
        print(f"{BAD} {label}: load failed - {e}")
        return False

    try:
        get_providers = getattr(lib, symbol)
    except AttributeError:
        print(f"{BAD} {label}: loaded, but {symbol} is missing")
        return False

    struct = struct or QnnInterface
    get_providers.restype = c_uint64
    get_providers.argtypes = [POINTER(POINTER(POINTER(struct))), POINTER(c_uint32)]

    providers = POINTER(POINTER(struct))()
    count = c_uint32()
    err = get_providers(byref(providers), byref(count))
    if err != 0 or count.value == 0:
        print(f"{BAD} {label}: {symbol} returned err=0x{err:x} count={count.value}")
        return False

    print(f"{OK} {label}: {count.value} provider(s)")
    for i in range(count.value):
        p = providers[i].contents
        name = p.providerName.decode(errors="replace") if p.providerName else "?"
        if hasattr(p, "systemApiVersion"):
            ver = f"systemApi={p.systemApiVersion}"
        else:
            ver = f"coreApi={p.apiVersion.core}  backendApi={p.apiVersion.backend}"
        print(f"{INFO} {name}  backendId={p.backendId}  {ver}")
    return True


# --------------------------------------------------------------------------

def main() -> int:
    print(f"host: {platform.machine()}  python: {platform.python_version()}")
    if platform.machine().lower() not in ("arm64", "aarch64"):
        print(f"{BAD} not a native ARM64 process - results below are meaningless")

    adreno_dir = os.path.join(DRIVER_STORE, ADRENO_PKG)
    for d in (adreno_dir, QAIRT_DIR):
        if os.path.isdir(d):
            os.add_dll_directory(d)

    head("Adreno GPU - OpenCL")
    # Both loaders, on purpose: the difference between them IS the finding.
    generic = probe_opencl(r"C:\Windows\System32\OpenCL.dll", "generic OpenCL.dll (ICD loader)")
    probe_icd_driver(os.path.join(adreno_dir, "OpenCL_adreno.dll"))

    head("Hexagon NPU - QNN / QAIRT")
    system = probe_qnn(
        "QnnSystem.dll", "QnnSystemInterface_getProviders", "QnnSystem.dll",
        struct=QnnSystemInterface,
    )
    htp = probe_qnn("QnnHtp.dll", "QnnInterface_getProviders", "QnnHtp.dll")

    head("Summary")
    for label, got in (
        ("Adreno OpenCL", generic),
        ("Hexagon QNN system", system),
        ("Hexagon QNN HTP", htp),
    ):
        print(f"{OK if got else BAD} {label}")
    return 0 if generic and htp else 1


if __name__ == "__main__":
    sys.exit(main())
