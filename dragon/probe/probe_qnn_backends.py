"""W4.0a: which QNN backends actually work on this machine?

QAIRT ships QnnCpu, QnnGpu and QnnHtp for aarch64-windows-msvc - one graph API
across all three Snapdragon processors. If that holds up in practice it covers
both the NPU and the GPU without writing two runtimes.

This loads each backend, negotiates its interface, and reports what it says it
is. Read-only; it does not build or execute a graph yet.

    python dragon/probe/probe_qnn_backends.py
"""

from __future__ import annotations

import ctypes
import os
import platform
import sys
from ctypes import POINTER, byref, c_char_p, c_uint32, c_uint64

SDK = os.environ.get("QNN_SDK_ROOT", r"C:\Qualcomm\AIStack\qairt\2.42.0.251225")
LIBDIR = os.path.join(SDK, "lib", "aarch64-windows-msvc")

# The bundle GenieX ships, kept for comparison - it is a different version and
# version skew is the thing most likely to bite us later.
GENIEX = r"C:\Program Files (x86)\GenieX CLI\qairt\htp-files"

BACKENDS = [
    ("QnnCpu.dll", "Oryon CPU"),
    ("QnnGpu.dll", "Adreno GPU"),
    ("QnnHtp.dll", "Hexagon NPU (HTP)"),
    ("QnnIr.dll", "IR / serialisation"),
    ("QnnSaver.dll", "Saver (records calls)"),
]


class QnnVersion(ctypes.Structure):
    _fields_ = [("major", c_uint32), ("minor", c_uint32), ("patch", c_uint32)]

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"


class QnnApiVersion(ctypes.Structure):
    _fields_ = [("core", QnnVersion), ("backend", QnnVersion)]


class QnnInterface(ctypes.Structure):
    """Prefix of QnnInterface_t. The trailing union of function tables is not
    modelled - identity and version is all this probe needs, and guessing at
    the table layout is exactly how you get plausible garbage."""

    _fields_ = [
        ("backendId", c_uint32),
        ("providerName", c_char_p),
        ("apiVersion", QnnApiVersion),
    ]


# Verbatim from QnnCommon.h lines 58-64 of QAIRT 2.42.0.251225. An earlier
# version of this map was written from memory and was shifted by one, which
# mislabelled every backend while looking entirely plausible. Read the header.
BACKEND_IDS = {
    0: "NULL", 1: "REFERENCE", 2: "SAVER", 3: "CPU", 4: "GPU", 5: "DSP", 6: "HTP",
}


def probe(path: str, label: str) -> dict | None:
    if not os.path.exists(path):
        print(f"  [--] {label:<20} not present")
        return None
    try:
        lib = ctypes.CDLL(path)
    except OSError as e:
        print(f"  [--] {label:<20} load failed: {getattr(e, 'winerror', e)}")
        return None
    try:
        fn = lib.QnnInterface_getProviders
    except AttributeError:
        print(f"  [--] {label:<20} no QnnInterface_getProviders")
        return None

    fn.restype = c_uint64
    fn.argtypes = [POINTER(POINTER(POINTER(QnnInterface))), POINTER(c_uint32)]
    providers = POINTER(POINTER(QnnInterface))()
    count = c_uint32()
    err = fn(byref(providers), byref(count))
    if err != 0 or count.value == 0:
        print(f"  [--] {label:<20} getProviders err=0x{err:x} count={count.value}")
        return None

    p = providers[0].contents
    name = p.providerName.decode(errors="replace") if p.providerName else "?"
    bid = BACKEND_IDS.get(p.backendId, "not in QnnCommon.h")
    print(
        f"  [ok] {label:<20} {name:<18} id={p.backendId} ({bid})"
        f"  core={p.apiVersion.core} backend={p.apiVersion.backend}"
    )
    return {
        "name": name,
        "backendId": p.backendId,
        "core": str(p.apiVersion.core),
        "backend": str(p.apiVersion.backend),
    }


def main() -> int:
    print(f"host: {platform.machine()}   python: {platform.python_version()}")
    if platform.machine().lower() not in ("arm64", "aarch64"):
        print("  [--] not a native ARM64 process - results below are meaningless")
        return 2
    if not os.path.isdir(LIBDIR):
        print(f"QNN_SDK_ROOT not usable: {LIBDIR} missing")
        return 2

    os.add_dll_directory(LIBDIR)
    print(f"\nSDK {os.path.basename(SDK)}  ({LIBDIR})")
    got = {}
    for dll, label in BACKENDS:
        r = probe(os.path.join(LIBDIR, dll), label)
        if r:
            got[dll] = r

    # Version skew against the runtime already installed by GenieX.
    if os.path.isdir(GENIEX):
        print(f"\nGenieX-bundled runtime  ({GENIEX})")
        os.add_dll_directory(GENIEX)
        old = probe(os.path.join(GENIEX, "QnnHtp.dll"), "Hexagon NPU (HTP)")
        new = got.get("QnnHtp.dll")
        if old and new and (old["core"], old["backend"]) != (new["core"], new["backend"]):
            print(
                f"\n  Version skew: SDK HTP core={new['core']}/backend={new['backend']}"
                f" vs bundled core={old['core']}/backend={old['backend']}."
            )
            print("  The package number is NOT the API version: package")
            print("  2.42.0.251225 declares QNN_API_VERSION 2.32.0 in QnnCommon.h,")
            print("  so the GenieX bundle is the NEWER API of the two. Build against")
            print("  the SDK headers and run against the SDK's own DLLs so header and")
            print("  runtime match - context binaries are version-sensitive.")

    print("\nSummary")
    have_gpu = "QnnGpu.dll" in got
    have_htp = "QnnHtp.dll" in got
    if have_gpu and have_htp:
        print("  Both GPU and NPU answer through the SAME QNN interface.")
        print("  One graph API can therefore target Adreno and Hexagon without")
        print("  writing two separate runtimes. Still to prove: that each can")
        print("  actually build and execute a graph, and at what speed.")
    else:
        missing = [n for n, h in (("GPU", have_gpu), ("HTP", have_htp)) if not h]
        print(f"  Missing: {', '.join(missing)} - the single-API plan does not hold.")
    return 0 if (have_gpu and have_htp) else 1


if __name__ == "__main__":
    sys.exit(main())
