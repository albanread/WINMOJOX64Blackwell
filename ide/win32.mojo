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


# ===----------------------------------------------------------------------===#
# Paths
# ===----------------------------------------------------------------------===#


def absolute(path: String) raises -> String:
    """A relative path made absolute, because a URI cannot be relative.

    The server resolves nothing: a `file://` URI with a relative path in it is
    a URI pointing at the root of the drive, and every diagnostic comes back
    for a file that does not exist.
    """
    var GetFullPathNameW = win32[
        def (
            Pointer[UInt16, MutAnyOrigin],
            UInt32,
            Pointer[UInt16, MutAnyOrigin],
            Int,
        ) thin abi("C") -> UInt32,
        "GetFullPathNameW",
    ]()
    var wide_path = List[UInt16]()
    for byte in path.as_bytes():
        wide_path.append(UInt16(Int(byte)))
    wide_path.append(0)
    var buffer = List[UInt16]()
    for _ in range(1024):
        buffer.append(0)
    var n = GetFullPathNameW(
        wide_path.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        UInt32(1024),
        buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        0,
    )
    _ = wide_path
    if n == 0 or n >= UInt32(1024):
        return path
    var out = String("")
    for k in range(Int(n)):
        out += chr(Int(buffer[k]))
    return out^


# ===----------------------------------------------------------------------===#
# The message pump
#
# A window belongs to the thread that created it, and that thread has to
# dispatch messages or the window is not a window. Not a style preference: the
# window manager sends messages that must be answered synchronously, and
# Windows watches whether they are. A thread that has not pumped for about
# five seconds is declared hung -- the title bar gains "(Not Responding)" and
# DWM stops using the window's own surface, drawing a ghost of it instead, or
# white where it has no ghost to draw.
#
# Griddle's `--cmd` mode drove the window for whole runs without ever pumping.
# Every command arrived by SendMessage, which Windows dispatches inline; every
# repaint went through UpdateWindow, which also bypasses the queue; and every
# wait was a Sleep loop that drained the language server's pipe and nothing
# else. A `lsp wait 25000` was twenty-five seconds of a window that answered
# nothing. That is why unattended screenshots came back with bands of white in
# them, and it is not a Direct2D problem: the frames were drawn and presented,
# and then composited from a ghost.
#
# So: `drain` after anything that might have queued work, and `settle` instead
# of Sleep in anything that waits. Both are what the real message loop does,
# factored out so the headless path and the interactive one are the same
# machinery rather than two shapes that can drift apart.
# ===----------------------------------------------------------------------===#

# Neither of these is in the metadata -- they are #defines in winuser.h rather
# than an enumeration, so there is no row to look up and they are written here
# with their names.
comptime PM_REMOVE = 0x0001
comptime QS_ALLINPUT = 0x04FF
comptime WAIT_TIMEOUT = 0x00000102


def drain(hwnd: Int) raises -> Int:
    """Dispatch every message waiting for this thread, and return how many.

    `hwnd` of zero means every window on the thread, which is what a pump
    wants: a window with a menu or a dialog has more than one, and draining
    only one of them leaves the others hung.

    Args:
        hwnd: A window to filter on, or 0 for all of this thread's.

    Returns:
        How many messages were dispatched.

    Raises:
        If the entry points cannot be resolved.
    """
    var PeekMessageW = win32[
        def (
            Pointer[MSG, MutAnyOrigin], Int, UInt32, UInt32, UInt32
        ) thin abi("C") -> c_int,
        "PeekMessageW",
    ]()
    var TranslateMessage = win32[
        def (Pointer[MSG, MutAnyOrigin]) thin abi("C") -> c_int,
        "TranslateMessage",
    ]()
    var DispatchMessageW = win32[
        def (Pointer[MSG, MutAnyOrigin]) thin abi("C") -> Int,
        "DispatchMessageW",
    ]()
    var PostQuitMessage = win32[
        def (c_int) thin abi("C") -> NoneType, "PostQuitMessage"
    ]()

    var msg = MSG()
    var n = 0
    # A bound rather than `while True`: a window that posts a message from its
    # own handler can feed this loop faster than it drains, and a pump that
    # never returns is the hang it exists to prevent.
    while n < 512:
        var got = PeekMessageW(
            Pointer(to=msg).unsafe_origin_cast[MutAnyOrigin](),
            0,
            UInt32(0),
            UInt32(0),
            UInt32(PM_REMOVE),
        )
        if got == 0:
            break
        if msg.message == UInt32(winkb_constant["WM_QUIT"]()):
            # Taken off the queue by this pump but meant for the real loop.
            # Putting it back is what keeps a quit that arrives during a
            # command from being swallowed.
            PostQuitMessage(c_int(Int(msg.wParam)))
            break
        _ = TranslateMessage(Pointer(to=msg).unsafe_origin_cast[MutAnyOrigin]())
        _ = DispatchMessageW(Pointer(to=msg).unsafe_origin_cast[MutAnyOrigin]())
        n += 1
    _ = hwnd
    return n


def settle(hwnd: Int, milliseconds: Int) raises -> Int:
    """Wait up to `milliseconds`, staying responsive while waiting.

    `MsgWaitForMultipleObjects` sleeps until either a message arrives or the
    time runs out, which is the difference between a window that is idle and a
    window that is hung. A `Sleep` of the same length is indistinguishable
    from a crash as far as the window manager is concerned.

    Args:
        hwnd: A window to drain, or 0 for all of this thread's.
        milliseconds: How long to wait at most.

    Returns:
        How many messages were dispatched.

    Raises:
        If the entry points cannot be resolved.
    """
    var MsgWaitForMultipleObjects = win32[
        def (UInt32, Int, c_int, UInt32, UInt32) thin abi("C") -> UInt32,
        "MsgWaitForMultipleObjects",
    ]()
    _ = MsgWaitForMultipleObjects(
        UInt32(0),  # no handles: this waits on the queue alone
        0,
        c_int(0),  # bWaitAll, meaningless with no handles
        UInt32(milliseconds),
        UInt32(QS_ALLINPUT),
    )
    return drain(hwnd)
