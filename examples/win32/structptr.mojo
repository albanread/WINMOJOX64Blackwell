# The minimal struct-by-pointer test. One struct, one API, three idioms, so
# the passing and failing spellings sit side by side.
#
# GlobalMemoryStatusEx is the ideal probe: it reads a field the caller must
# set (dwLength -- the WNDCLASSEXW cbSize pattern), rejects the call with
# ERROR_INVALID_PARAMETER if the pointer or layout is wrong, and writes 64
# bytes back on success. Both directions of the ABI in one call.

from std.ffi import c_int, OwnedDLHandle
from std.memory import Pointer
from std.sys.info import size_of
from std.sys._winkb import winkb_struct_size


@fieldwise_init
struct MEMORYSTATUSEX(Defaultable, Copyable, Movable):
    var dwLength: UInt32
    var dwMemoryLoad: UInt32
    var ullTotalPhys: UInt64
    var ullAvailPhys: UInt64
    var ullTotalPageFile: UInt64
    var ullAvailPageFile: UInt64
    var ullTotalVirtual: UInt64
    var ullAvailVirtual: UInt64
    var ullAvailExtendedVirtual: UInt64

    def __init__(out self):
        self.dwLength = 0
        self.dwMemoryLoad = 0
        self.ullTotalPhys = 0
        self.ullAvailPhys = 0
        self.ullTotalPageFile = 0
        self.ullAvailPageFile = 0
        self.ullTotalVirtual = 0
        self.ullAvailVirtual = 0
        self.ullAvailExtendedVirtual = 0


def main() raises:
    comptime assert (
        size_of[MEMORYSTATUSEX]() == winkb_struct_size["MEMORYSTATUSEX"]()
    ), "MEMORYSTATUSEX does not match Windows"

    var kernel32 = OwnedDLHandle("kernel32.dll")
    var GlobalMemoryStatusEx = kernel32.get_function[c_int](
        "GlobalMemoryStatusEx"
    )

    # -- Idiom 1: true origin, inferred by the variadic call. --------------
    # This is what the stdlib itself does (clock_gettime, stat, getline):
    # Pointer(to=local), no cast. The pointer's origin IS origin_of(m1), so
    # the lifetime checker knows the callee's writes land in m1.
    var m1 = MEMORYSTATUSEX()
    m1.dwLength = UInt32(size_of[MEMORYSTATUSEX]())
    var ok1 = GlobalMemoryStatusEx(Pointer(to=m1))
    print(
        "true origin      -> ok =", ok1,
        " load =", m1.dwMemoryLoad, "%",
        " totalPhys =", m1.ullTotalPhys >> 30, "GB",
    )

    # -- Idiom 2: cast to MutUntrackedOrigin. ------------------------------
    # The origin docs: an untracked origin "promises the reference aliases no
    # value the compiler is managing". That promise is false here -- it DOES
    # alias m2 -- so the compiler may hand the callee a temporary and never
    # read it back. The sentinel detects whether m2 ever saw the write.
    var m2 = MEMORYSTATUSEX()
    m2.dwLength = UInt32(size_of[MEMORYSTATUSEX]())
    m2.dwMemoryLoad = 12345  # sentinel
    var ok2 = GlobalMemoryStatusEx(
        Pointer(to=m2).unsafe_origin_cast[MutUntrackedOrigin]()
    )
    print(
        "untracked cast   -> ok =", ok2,
        " load =", m2.dwMemoryLoad,
        " (12345 means the write never reached m2)",
    )

    # -- Idiom 3: declared signature over MutAnyOrigin. --------------------
    # What the COM dispatcher's Sig should say for pointer parameters that
    # receive Mojo-owned memory. Does Pointer[T, origin_of(m3)] convert?
    var m3 = MEMORYSTATUSEX()
    m3.dwLength = UInt32(size_of[MEMORYSTATUSEX]())
    comptime Sig = def (
        Pointer[MEMORYSTATUSEX, MutAnyOrigin]
    ) thin abi("C") -> c_int
    var addr = kernel32.get_symbol[NoneType]("GlobalMemoryStatusEx")
    if not addr:
        raise Error("symbol not found")
    var entry = addr.value()
    var proc = Pointer(to=entry).unsafe_bitcast[Sig]()[]
    # No implicit origin conversion exists, so the call site must cast --
    # but to AnyOrigin, which KEEPS the aliasing ("might access any memory
    # value"), not to Untracked, which denies it.
    var ok3 = proc(Pointer(to=m3).unsafe_origin_cast[MutAnyOrigin]())
    print(
        "MutAnyOrigin sig -> ok =", ok3,
        " load =", m3.dwMemoryLoad, "%",
        " totalPhys =", m3.ullTotalPhys >> 30, "GB",
    )
