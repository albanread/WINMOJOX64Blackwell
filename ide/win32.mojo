"""The IDE's Win32 layer: every call typed, every number from the metadata.

The standing rule for Griddle is that nothing here is hand-declared. A
function's DLL comes from `windows_api.db` rather than a string somebody
remembered; a constant comes from the same database rather than a hex
literal copied out of a header; a struct's size is asserted against what
Windows actually says at compile time. The database has 46,250 interface
methods and every Win32 export with its DLL, so there is no reason to guess,
and guessing is how a port acquires the bug where one field moved in a
service pack.

The one thing this file cannot make typed is the window procedure itself:
Windows calls it, so it must be a captureless C-ABI function with no way to
carry anything resolved in advance. The tree's established answer -- an
`@export`ed `def` that re-opens `user32` inside itself -- is what
`griddle.mojo` uses, and it needs no hand-declared prototype either.
"""

from std.ffi import c_int
from std.memory import Pointer
from std.sys.info import size_of
from std.sys._com import com_addr
from std.sys._win32 import Win32Module
from std.sys._winkb import (
    winkb_constant,
    winkb_function_dll,
    winkb_struct_size,
)


# ===----------------------------------------------------------------------===#
# Entry points
# ===----------------------------------------------------------------------===#


def win32[
    Sig: TrivialRegisterPassable, name: StaticString
]() raises -> Sig:
    """A Win32 entry point, typed, from whichever DLL the metadata names.

    Parameters:
        Sig: The full thin C-ABI signature. Spell every argument -- an
            under-declared signature compiles and then corrupts the call.
        name: The exported function, e.g. "CreateWindowExW".

    Returns:
        The entry point, ready to call.

    Raises:
        If the module does not load or the export is absent.
    """
    return Win32Module(String(winkb_function_dll[name]())).function[Sig](
        String(name)
    )


# ===----------------------------------------------------------------------===#
# Strings
# ===----------------------------------------------------------------------===#


def wide(s: StaticString) -> List[UInt16]:
    """A NUL-terminated UTF-16 buffer for the W-suffixed entry points.

    ASCII only, which every string this IDE passes to Windows at startup is
    (class names, window titles). Real user text reaches Windows through the
    text store, which speaks UTF-16 natively.

    Args:
        s: The text.

    Returns:
        Its UTF-16 code units, NUL-terminated.
    """
    var out = List[UInt16]()
    for byte in s.as_bytes():
        out.append(UInt16(Int(byte)))
    out.append(0)
    return out^


# ===----------------------------------------------------------------------===#
# Structures Windows fills in
#
# Layouts are asserted against the metadata at compile time, so a mismatch is
# a build failure rather than a memory-corruption mystery.
# ===----------------------------------------------------------------------===#


@fieldwise_init
struct WNDCLASSEXW(Defaultable, Copyable, Movable):
    """The window class, as `RegisterClassExW` expects it."""

    var cbSize: UInt32
    var style: UInt32
    var lpfnWndProc: Int
    var cbClsExtra: c_int
    var cbWndExtra: c_int
    var hInstance: Int
    var hIcon: Int
    var hCursor: Int
    var hbrBackground: Int
    var lpszMenuName: Int
    var lpszClassName: Int
    var hIconSm: Int

    def __init__(out self):
        """An all-zero class, ready to have its fields set."""
        self.cbSize = 0
        self.style = 0
        self.lpfnWndProc = 0
        self.cbClsExtra = 0
        self.cbWndExtra = 0
        self.hInstance = 0
        self.hIcon = 0
        self.hCursor = 0
        self.hbrBackground = 0
        self.lpszMenuName = 0
        self.lpszClassName = 0
        self.hIconSm = 0


@fieldwise_init
struct RECT(Defaultable, ImplicitlyCopyable, Movable):
    """A rectangle, as the window APIs report one."""

    var left: Int32
    var top: Int32
    var right: Int32
    var bottom: Int32

    def __init__(out self):
        """An empty rectangle."""
        self.left = 0
        self.top = 0
        self.right = 0
        self.bottom = 0


@fieldwise_init
struct POINT(Defaultable, ImplicitlyCopyable, Movable):
    """A point, as the window APIs take one."""

    var x: Int32
    var y: Int32

    def __init__(out self):
        """The origin."""
        self.x = 0
        self.y = 0


@fieldwise_init
struct MSG(Defaultable, Copyable, Movable):
    """One message, as the loop receives it."""

    var hwnd: Int
    var message: UInt32
    var wParam: Int
    var lParam: Int
    var time: UInt32
    var ptX: Int32
    var ptY: Int32
    var lPrivate: UInt32

    def __init__(out self):
        """An empty message."""
        self.hwnd = 0
        self.message = 0
        self.wParam = 0
        self.lParam = 0
        self.time = 0
        self.ptX = 0
        self.ptY = 0
        self.lPrivate = 0


@fieldwise_init
struct COPYDATASTRUCT(Defaultable, Copyable, Movable):
    """The payload of a WM_COPYDATA message.

    Windows copies `cbData` bytes from `lpData` into the receiving process
    before the handler runs, which is the whole point of the message: the
    pointer is never dereferenced across the process boundary.
    """

    var dwData: Int
    var cbData: UInt32
    var lpData: Int

    def __init__(out self):
        """An empty payload."""
        self.dwData = 0
        self.cbData = 0
        self.lpData = 0


# ===----------------------------------------------------------------------===#
# Signatures
#
# Named once so the window procedure and the class registration cannot drift
# apart -- they must agree exactly or Windows calls into the wrong shape.
# ===----------------------------------------------------------------------===#

comptime WndProcType = def (Int, UInt32, Int, Int) thin abi("C") -> Int


@fieldwise_init
struct PROCESS_MEMORY_COUNTERS(Defaultable, Copyable, Movable):
    """What a process is holding, as PSAPI reports it."""

    var cb: UInt32
    var PageFaultCount: UInt32
    var PeakWorkingSetSize: Int
    var WorkingSetSize: Int
    var QuotaPeakPagedPoolUsage: Int
    var QuotaPagedPoolUsage: Int
    var QuotaPeakNonPagedPoolUsage: Int
    var QuotaNonPagedPoolUsage: Int
    var PagefileUsage: Int
    var PeakPagefileUsage: Int

    def __init__(out self):
        """Empty, ready to be filled in."""
        self.cb = 0
        self.PageFaultCount = 0
        self.PeakWorkingSetSize = 0
        self.WorkingSetSize = 0
        self.QuotaPeakPagedPoolUsage = 0
        self.QuotaPagedPoolUsage = 0
        self.QuotaPeakNonPagedPoolUsage = 0
        self.QuotaNonPagedPoolUsage = 0
        self.PagefileUsage = 0
        self.PeakPagefileUsage = 0


def private_bytes() raises -> Int:
    """How much memory this process has committed, in bytes.

    Private commit rather than working set. The working set is what is
    resident, which the operating system trims and grows for reasons of its
    own; a measurement of "how much did keeping a thousand undo states cost"
    wants what was asked for, not what is currently paged in.

    Returns:
        The commit charge in bytes, or zero if PSAPI declined.

    Raises:
        If the entry point cannot be resolved.
    """
    comptime assert (
        size_of[PROCESS_MEMORY_COUNTERS]()
        == winkb_struct_size["PROCESS_MEMORY_COUNTERS"]()
    ), "PROCESS_MEMORY_COUNTERS does not match Windows"

    var GetCurrentProcess = win32[
        def () thin abi("C") -> Int, "GetCurrentProcess"
    ]()
    var GetProcessMemoryInfo = win32[
        def (
            Int, Pointer[PROCESS_MEMORY_COUNTERS, MutAnyOrigin], UInt32
        ) thin abi("C") -> c_int,
        "GetProcessMemoryInfo",
    ]()
    var counters = PROCESS_MEMORY_COUNTERS()
    counters.cb = UInt32(size_of[PROCESS_MEMORY_COUNTERS]())
    if GetProcessMemoryInfo(
        GetCurrentProcess(),
        com_addr(counters),
        UInt32(size_of[PROCESS_MEMORY_COUNTERS]()),
    ) == 0:
        return 0
    return counters.PagefileUsage


# ===----------------------------------------------------------------------===#
# Scale
#
# Every measurement in the editor is written once, at 96 DPI, and multiplied
# through here. That is the whole scheme: the layout constants stay readable
# numbers a person can reason about (`RAIL_W = 52`), and exactly one function
# knows what a pixel is worth on the display the window is actually on.
#
# The zoom control the View menu will grow belongs here too. A person zooming
# in and a person moving the window to a denser display want the same thing --
# everything bigger by the same factor -- so zoom multiplies this rather than
# forking a second scale, and every rectangle in the program then follows for
# free. See IDE-DESIGN.md, the menu sprint.
# ===----------------------------------------------------------------------===#


def dpi_of(hwnd: Int) -> Int:
    """The dots per inch of the display this window is on.

    `GetDpiForWindow` needs the process to be per-monitor aware to answer
    honestly, which the manifest arranges; on a system-aware or unaware
    process it reports the system value instead, which is still better than
    assuming. It arrived in Windows 10 1607, so a machine older than that
    falls back to 96 rather than failing to start.

    Args:
        hwnd: The window.

    Returns:
        The DPI, or 96 if Windows will not say.

    Raises:
        Never in practice; the lookup is guarded.
    """
    try:
        var GetDpiForWindow = win32[
            def (Int) thin abi("C") -> UInt32, "GetDpiForWindow"
        ]()
        var dpi = Int(GetDpiForWindow(hwnd))
        if dpi >= 48:
            return dpi
    except:
        pass
    return 96


def dpi_scale(hwnd: Int) -> Float32:
    """Device pixels per design pixel for this window.

    1.0 on a 96 DPI display, 1.5 at 150%, 2.0 at 200%.

    Args:
        hwnd: The window.

    Returns:
        The factor every layout constant is multiplied by.

    Raises:
        Never in practice.
    """
    return Float32(dpi_of(hwnd)) / 96.0


def scaled(v: Int, scale: Float32) -> Float32:
    """A design pixel measurement in device pixels, rounded to a whole one.

    Rounded because these become the edges of filled rectangles and the
    positions of hairlines, and a hairline on a half pixel is drawn as two
    grey ones. The rounding is done once, here, so that two rectangles meant
    to meet still meet after scaling.

    Args:
        v: The measurement, written at 96 DPI.
        scale: What a design pixel is worth.

    Returns:
        The device-pixel measurement.
    """
    return Float32(Int(Float32(v) * scale + 0.5))
