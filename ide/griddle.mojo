"""Griddle -- a Mojo IDE for Windows, written in win-mojo.

Milestone 0.1: the window. It opens dark-chromed, survives resize, and exits
zero. Everything else in `IDE-DESIGN.md` hangs off this one HWND -- the rail,
the sidebar, the grid and the panes are all drawn into it by one Direct2D
pass, because a layout engine is precisely the thing the design refuses.

Run it:

    mojo build --no-optimization -I mojo/stdlib -o build/griddle.exe \\
        ide/griddle.mojo

`--seconds N` closes the window on its own after N seconds, and
`--selftest` resizes it and reports the client area before and after, which
is how the check drives it with nobody at the keyboard. The app inspects
itself rather than being inspected: a window created from a build harness is
not always on the interactive desktop, so cross-process EnumWindows can come
up empty for a window that plainly exists.
"""

from std.sys import argv

from std.ffi import c_int
from std.memory import Pointer
from std.python._cpython import _fn_ptr_as_opaque
from std.sys.info import size_of
from std.sys._win32 import Win32Module
from std.sys._winkb import winkb_constant, winkb_struct_size

from ide.win32 import MSG, RECT, WNDCLASSEXW, WndProcType, wide, win32


# ===----------------------------------------------------------------------===#
# The window procedure
#
# Windows calls this, so it is a captureless C-ABI function: it cannot hold
# anything resolved in advance and has to find what it needs each time. That
# is the whole reason it re-opens user32 rather than being handed a pointer.
# ===----------------------------------------------------------------------===#


@export("griddle_wndproc")
def griddle_wndproc(
    hwnd: Int, message: UInt32, wparam: Int, lparam: Int
) abi("C") -> Int:
    try:
        # Closing the window ends the program: without this the loop waits
        # forever for messages from a window that no longer exists.
        if message == UInt32(winkb_constant["WM_DESTROY"]()):
            var PostQuitMessage = win32[
                def (c_int) thin abi("C") -> NoneType, "PostQuitMessage"
            ]()
            _ = PostQuitMessage(c_int(0))
            return 0

        var DefWindowProcW = win32[WndProcType, "DefWindowProcW"]()
        return DefWindowProcW(hwnd, message, wparam, lparam)
    except:
        # A raise cannot cross back into Windows. Answering zero is the
        # documented "handled" reply and keeps the window alive; the
        # alternative is unwinding through a foreign frame.
        return 0


# ===----------------------------------------------------------------------===#
# Startup
# ===----------------------------------------------------------------------===#


def dark_titlebar(hwnd: Int) raises -> Int32:
    """Ask the DWM for a dark caption, so the frame matches the editor.

    A light title bar over a dark editor is the tell of a port that stopped
    at "it opens". The attribute is advisory -- older Windows 10 builds
    simply ignore it -- so a failure here is not fatal. The HRESULT is
    returned rather than swallowed, because "the call was made" and "Windows
    accepted it" are different claims and only the second one is worth
    printing.

    Args:
        hwnd: The window to darken.

    Returns:
        The HRESULT; zero means the caption is dark.
    """
    var DwmSetWindowAttribute = win32[
        def (Int, UInt32, Pointer[Int32, MutAnyOrigin], UInt32) thin abi("C")
        -> Int32,
        "DwmSetWindowAttribute",
    ]()
    var enabled = Int32(1)
    return DwmSetWindowAttribute(
        hwnd,
        UInt32(winkb_constant["DWMWA_USE_IMMERSIVE_DARK_MODE"]()),
        Pointer(to=enabled).unsafe_origin_cast[MutAnyOrigin](),
        UInt32(size_of[Int32]()),
    )


def main() raises:
    # Windows describes its own structures; a disagreement is a build
    # failure here rather than corruption at the first call.
    comptime assert (
        size_of[WNDCLASSEXW]() == winkb_struct_size["WNDCLASSEXW"]()
    ), "WNDCLASSEXW does not match Windows"
    comptime assert (
        size_of[MSG]() == winkb_struct_size["MSG"]()
    ), "MSG does not match Windows"

    # `--seconds N`: close on our own, for unattended runs.
    var seconds = 0
    var selftest = False
    var args = argv()
    for i in range(len(args)):
        if args[i] == "--seconds" and i + 1 < len(args):
            seconds = Int(args[i + 1])
        if args[i] == "--selftest":
            selftest = True

    var GetModuleHandleW = win32[
        def (Int) thin abi("C") -> Int, "GetModuleHandleW"
    ]()
    var GetLastError = win32[def () thin abi("C") -> UInt32, "GetLastError"]()
    var RegisterClassExW = win32[
        def (Pointer[WNDCLASSEXW, MutAnyOrigin]) thin abi("C") -> UInt16,
        "RegisterClassExW",
    ]()
    var CreateWindowExW = win32[
        def (
            UInt32, Pointer[UInt16, MutAnyOrigin],
            Pointer[UInt16, MutAnyOrigin], UInt32,
            c_int, c_int, c_int, c_int, Int, Int, Int, Int,
        ) thin abi("C") -> Int,
        "CreateWindowExW",
    ]()
    var ShowWindow = win32[
        def (Int, c_int) thin abi("C") -> c_int, "ShowWindow"
    ]()
    var GetMessageW = win32[
        def (
            Pointer[MSG, MutAnyOrigin], Int, UInt32, UInt32
        ) thin abi("C") -> c_int,
        "GetMessageW",
    ]()
    var TranslateMessage = win32[
        def (Pointer[MSG, MutAnyOrigin]) thin abi("C") -> c_int,
        "TranslateMessage",
    ]()
    var DispatchMessageW = win32[
        def (Pointer[MSG, MutAnyOrigin]) thin abi("C") -> Int,
        "DispatchMessageW",
    ]()

    var hInstance = GetModuleHandleW(0)
    var class_name = wide("GriddleWindow")
    var title = wide("Griddle")

    var proc: WndProcType = griddle_wndproc
    var wc = WNDCLASSEXW()
    wc.cbSize = UInt32(size_of[WNDCLASSEXW]())
    # Redraw the whole client area on either axis changing, because the grid
    # is laid out by arithmetic on the window size.
    wc.style = UInt32(
        winkb_constant["CS_HREDRAW"]() | winkb_constant["CS_VREDRAW"]()
    )
    wc.lpfnWndProc = Int(_fn_ptr_as_opaque(proc))
    wc.hInstance = hInstance
    wc.lpszClassName = Int(class_name.unsafe_ptr())

    if RegisterClassExW(Pointer(to=wc).unsafe_origin_cast[MutAnyOrigin]()) == 0:
        raise Error(
            "RegisterClassExW failed, GetLastError = " + String(GetLastError())
        )

    var hwnd = CreateWindowExW(
        UInt32(0),
        class_name.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        title.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        UInt32(winkb_constant["WS_OVERLAPPEDWINDOW"]()),
        c_int(winkb_constant["CW_USEDEFAULT"]()),
        c_int(winkb_constant["CW_USEDEFAULT"]()),
        c_int(1200),
        c_int(800),
        0,
        0,
        hInstance,
        0,
    )
    if hwnd == 0:
        raise Error(
            "CreateWindowExW failed, GetLastError = " + String(GetLastError())
        )

    # Before the window is shown, so it never flashes light chrome.
    var dark = dark_titlebar(hwnd)
    _ = ShowWindow(hwnd, c_int(winkb_constant["SW_SHOW"]()))
    print(
        "griddle: window", hwnd, "open  dark-titlebar hr =", dark,
        "(0 = accepted)",
    )

    if selftest:
        # Resize through the same call a user's drag ends in, and read the
        # client area back from Windows on both sides of it. "It opened" and
        # "it survives being resized" are different claims; this one is the
        # second, and the grid's whole layout is arithmetic on these numbers.
        var GetClientRect = win32[
            def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
            "GetClientRect",
        ]()
        var SetWindowPos = win32[
            def (
                Int, Int, c_int, c_int, c_int, c_int, UInt32
            ) thin abi("C") -> c_int,
            "SetWindowPos",
        ]()
        var rc = RECT()
        _ = GetClientRect(hwnd, Pointer(to=rc).unsafe_origin_cast[MutAnyOrigin]())
        print("griddle: client", rc.right - rc.left, "x", rc.bottom - rc.top)
        # SWP_NOZORDER, so the window keeps its place in the stack.
        _ = SetWindowPos(hwnd, 0, c_int(80), c_int(80), c_int(640), c_int(480),
                         UInt32(winkb_constant["SWP_NOZORDER"]()))
        var rc2 = RECT()
        _ = GetClientRect(hwnd, Pointer(to=rc2).unsafe_origin_cast[MutAnyOrigin]())
        print(
            "griddle: client", rc2.right - rc2.left, "x",
            rc2.bottom - rc2.top, "after resize",
        )
        var IsWindow = win32[def (Int) thin abi("C") -> c_int, "IsWindow"]()
        print("griddle: alive after resize:", IsWindow(hwnd) != 0)

    if seconds > 0:
        # Unattended: a timer whose tick destroys the window, so the timed
        # exit rejoins the human one at WM_DESTROY -- the same quit message,
        # the same clean-up, no second path to keep working.
        var SetTimer = win32[
            def (Int, Int, UInt32, Int) thin abi("C") -> Int, "SetTimer"
        ]()
        _ = SetTimer(hwnd, 1, UInt32(seconds * 1000), 0)
        print("griddle: closing in", seconds, "second(s)")

    # The message loop. GetMessageW blocks, which is right for an editor:
    # idle costs no CPU, and the D2D redraw is driven by WM_PAINT rather than
    # by spinning. It answers 0 for WM_QUIT and -1 for an error.
    var msg = MSG()
    while True:
        var got = GetMessageW(Pointer(to=msg).unsafe_origin_cast[MutAnyOrigin](), 0, 0, 0)
        if got == 0:
            break
        if got == -1:
            raise Error(
                "GetMessageW failed, GetLastError = " + String(GetLastError())
            )
        # A timer tick means the unattended run is over; destroy the window
        # and let WM_DESTROY post the quit exactly as a real close would.
        if msg.message == UInt32(winkb_constant["WM_TIMER"]()):
            var DestroyWindow = win32[
                def (Int) thin abi("C") -> c_int, "DestroyWindow"
            ]()
            _ = DestroyWindow(hwnd)
            continue
        _ = TranslateMessage(Pointer(to=msg).unsafe_origin_cast[MutAnyOrigin]())
        _ = DispatchMessageW(Pointer(to=msg).unsafe_origin_cast[MutAnyOrigin]())

    print("griddle: closed cleanly")
