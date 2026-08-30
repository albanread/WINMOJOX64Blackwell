"""Griddle -- a Mojo IDE for Windows, written in win-mojo.

Milestone 0.1: the window. It opens dark-chromed, survives resize, and exits
zero. Everything else in `IDE-DESIGN.md` hangs off this one HWND -- the rail,
the sidebar, the grid and the panes are all drawn into it by one Direct2D
pass, because a layout engine is precisely the thing the design refuses.

Run it:

    mojo build --no-optimization -I mojo/stdlib -o build/griddle.exe \\
        ide/griddle.mojo

`--ms N` closes the window on its own after N milliseconds -- milliseconds
because a second is far too coarse both ways: a check wants to be quick, and
a person watching wants time to see the thing rather than a flash. `--cmd "<verb>"` sends one command to our own window and prints the answer,
which is how the agent surface is checked with no second process involved --
a self-send dispatches straight into the window procedure, so it exercises
the whole path (message, handler, dispatcher, reply) without needing a
caller that shares our desktop. And `--selftest` resizes it and reports the client area before and after, which
is how the check drives it with nobody at the keyboard. The app inspects
itself rather than being inspected: a window created from a build harness is
not always on the interactive desktop, so cross-process EnumWindows can come
up empty for a window that plainly exists.
"""

from std.os import getenv
from std.sys import argv

from std.ffi import c_int
from std.memory import Pointer
from std.python._cpython import _fn_ptr_as_opaque
from std.sys.info import size_of
from std.sys._win32 import Win32Module
from std.sys._winkb import winkb_constant, winkb_struct_size
from std.sys.com import Apartment

from std.memory import alloc

from ide.agent import agent_command
from ide.chrome import Chrome, bring_up, draw, release
from ide.drop import register as register_drop, revoke as revoke_drop
from ide.menu import build as build_menu
from ide.win32 import (
    COPYDATASTRUCT,
    MSG,
    RECT,
    WNDCLASSEXW,
    WndProcType,
    wide,
    win32,
)


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
        # A command from outside. Windows has already copied the bytes into
        # this process, so the pointer is ours to read for the length of
        # this call and no longer.
        if message == UInt32(winkb_constant["WM_COPYDATA"]()):
            var cds = Pointer[COPYDATASTRUCT, MutAnyOrigin](
                unsafe_from_address=lparam
            )
            var bytes = Pointer[UInt8, MutAnyOrigin](
                unsafe_from_address=cds[].lpData
            )
            var request = String("")
            for i in range(Int(cds[].cbData)):
                request += chr(Int(bytes.unsafe_offset(i)[]))
            # First line names the file the answer goes in; the rest is the
            # command. Answering into a file is what lets a caller be a
            # shell script with no window of its own -- see ide/agent.mojo.
            var newline = request.find("\n")
            if newline < 0:
                return 0
            var reply_path = String(request[byte=:newline]).strip()
            var command = String(request[byte=newline + 1 :])
            # A verb that raises is still an answer. Reporting "the window
            # did not accept the command" tells the caller nothing about
            # what went wrong, and the outer handler cannot say more because
            # it has already lost the error.
            var reply = String("")
            try:
                reply = agent_command(hwnd, command)
            except err:
                reply = String("error: ") + String(err)
            with open(reply_path, "w") as f:
                f.write(reply)
            return 1

        # Everything visible is drawn here. The chrome's interfaces live in
        # the window's user data because this procedure is captureless --
        # Windows calls it, so it can hold nothing and must fetch what it
        # needs from the one place a window can keep something.
        if message == UInt32(winkb_constant["WM_PAINT"]()):
            var GetWindowLongPtrW = win32[
                def (Int, c_int) thin abi("C") -> Int, "GetWindowLongPtrW"
            ]()
            var stored = GetWindowLongPtrW(
                hwnd, c_int(winkb_constant["GWLP_USERDATA"]())
            )
            if stored != 0:
                var GetClientRect = win32[
                    def (
                        Int, Pointer[RECT, MutAnyOrigin]
                    ) thin abi("C") -> c_int,
                    "GetClientRect",
                ]()
                var rc = RECT()
                _ = GetClientRect(
                    hwnd, Pointer(to=rc).unsafe_origin_cast[MutAnyOrigin]()
                )
                var chrome = Pointer[Chrome, MutAnyOrigin](
                    unsafe_from_address=stored
                )
                # A paint that fails half-way leaves a window that looks
                # merely unfinished, with nothing said. Report it: a silent
                # partial paint is the hardest kind of bug to see.
                try:
                    draw(
                        chrome[],
                        Int(rc.right - rc.left),
                        Int(rc.bottom - rc.top),
                    )
                except err:
                    print("griddle: paint failed:", String(err))
            # Validate the whole window: the update region must be cleared or
            # Windows sends WM_PAINT again immediately, forever.
            var ValidateRect = win32[
                def (Int, Int) thin abi("C") -> c_int, "ValidateRect"
            ]()
            _ = ValidateRect(hwnd, 0)
            return 0

        # A menu item was chosen -- by a person or by the agent, which sends
        # the same command the menu does.
        if message == UInt32(winkb_constant["WM_COMMAND"]()):
            if (wparam & 0xFFFF) == 1001:  # File > Exit
                var DestroyWindow = win32[
                    def (Int) thin abi("C") -> c_int, "DestroyWindow"
                ]()
                _ = DestroyWindow(hwnd)
            return 0

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


# Our own close timer's id. Named because the loop must be able to tell it
# from every other timer in the process: the runtime sets thread timers of
# its own, and a WM_TIMER that is not ours must not be read as "shut down".
comptime CLOSE_TIMER_ID = 0x6721


def env_or(name: StringSlice, fallback: StringSlice) -> String:
    """An environment variable, or a fallback when it is unset."""
    try:
        var value = getenv(String(name))
        if value.byte_length() > 0:
            return value
    except:
        pass
    return String(fallback)


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
    var close_ms = 0
    var selftest = False
    var command = String("")
    var trace = False
    var args = argv()
    for i in range(len(args)):
        if args[i] == "--ms" and i + 1 < len(args):
            close_ms = Int(args[i + 1])
        if args[i] == "--selftest":
            selftest = True
        if args[i] == "--trace":
            trace = True
        if args[i] == "--cmd" and i + 1 < len(args):
            command = String(args[i + 1])

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
    # Publish the window handle. A second process could FindWindowW our
    # class instead, and a person's tooling may well prefer to -- but a file
    # needs no window station in common with us, which a build harness
    # launching Griddle does not always have. One line, no failure mode.
    var handle_path = String(env_or("TEMP", ".")) + "\\griddle.hwnd"
    with open(handle_path, "w") as f:
        f.write(String(hwnd))

    # The menu first: it takes height from the client area, and the chrome's
    # layout is arithmetic on whatever is left.
    build_menu(hwnd)

    # Direct2D, before the window is shown, so the first paint has something
    # to draw with. The chrome outlives this scope -- the window procedure
    # picks it up on every WM_PAINT -- so it is heap-allocated and the window
    # is told where it lives.
    var rc0 = RECT()
    var GetClientRect0 = win32[
        def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
        "GetClientRect",
    ]()
    _ = GetClientRect0(hwnd, Pointer(to=rc0).unsafe_origin_cast[MutAnyOrigin]())
    var chrome_store = alloc[Chrome](1, alignment=8)
    chrome_store[] = bring_up(
        hwnd, Int(rc0.right - rc0.left), Int(rc0.bottom - rc0.top)
    )
    var SetWindowLongPtrW = win32[
        def (Int, c_int, Int) thin abi("C") -> Int, "SetWindowLongPtrW"
    ]()
    _ = SetWindowLongPtrW(
        hwnd, c_int(winkb_constant["GWLP_USERDATA"]()), Int(chrome_store)
    )

    # Drag and drop. OleInitialize (not CoInitializeEx) is what the drag
    # subsystem requires, and the apartment stays open for the life of the
    # window -- revoking happens before it closes.
    var ole = Apartment(ole=True)
    ole.__enter__()
    var drop = register_drop(hwnd)
    chrome_store[].drop_target = drop.address()

    var dark = dark_titlebar(hwnd)
    _ = ShowWindow(hwnd, c_int(winkb_constant["SW_SHOW"]()))
    print(
        "griddle: window", hwnd, "open  dark-titlebar hr =", dark,
        "(0 = accepted)",
    )

    if command.byte_length() > 0:
        # Ask ourselves, through the real message path. SendMessage to our
        # own window dispatches inline -- Windows calls the procedure
        # directly rather than queueing -- so this exercises the transport,
        # the handler and the dispatcher without a message loop and without
        # a second process. It is also why the check needs no second
        # desktop: nothing here crosses a process boundary.
        var SendMessageW = win32[
            def (
                Int, UInt32, Int, Pointer[COPYDATASTRUCT, MutAnyOrigin]
            ) thin abi("C") -> Int,
            "SendMessageW",
        ]()
        var reply_path = String(env_or("TEMP", ".")) + "\\griddle-selfcmd.txt"
        var payload = reply_path + "\n" + command
        var bytes = payload.as_bytes()
        var cds = COPYDATASTRUCT()
        cds.cbData = UInt32(len(bytes))
        cds.lpData = Int(bytes.unsafe_ptr())
        var accepted = SendMessageW(
            hwnd,
            UInt32(winkb_constant["WM_COPYDATA"]()),
            0,
            Pointer(to=cds).unsafe_origin_cast[MutAnyOrigin](),
        )
        _ = payload
        if accepted != 1:
            raise Error("the window did not accept the command")
        with open(reply_path, "r") as f:
            print(f.read(), end="")
        print()
        return

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

        # Can anything find us by class name? The agent surface depends on a
        # second process doing exactly this, so ask from inside first: if we
        # cannot find ourselves, the class name is wrong, not the observer.
        var FindWindowW = win32[
            def (
                Pointer[UInt16, MutAnyOrigin], Int
            ) thin abi("C") -> Int,
            "FindWindowW",
        ]()
        var probe = wide("GriddleWindow")
        var found = FindWindowW(
            probe.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](), 0
        )
        _ = probe
        print("griddle: FindWindowW('GriddleWindow') ->", found,
              "(ours is", String(hwnd) + ")")

    if close_ms > 0:
        # Unattended: a timer whose tick destroys the window, so the timed
        # exit rejoins the human one at WM_DESTROY -- the same quit message,
        # the same clean-up, no second path to keep working.
        var SetTimer = win32[
            def (Int, Int, UInt32, Int) thin abi("C") -> Int, "SetTimer"
        ]()
        _ = SetTimer(hwnd, CLOSE_TIMER_ID, UInt32(close_ms), 0)
        print("griddle: closing in", close_ms, "ms")

    # The message loop. GetMessageW blocks, which is right for an editor:
    # idle costs no CPU, and the D2D redraw is driven by WM_PAINT rather than
    # by spinning. It answers 0 for WM_QUIT and -1 for an error.
    var msg = MSG()
    while True:
        var got = GetMessageW(Pointer(to=msg).unsafe_origin_cast[MutAnyOrigin](), 0, 0, 0)
        if got == 0:
            break
        if trace:
            print("griddle: msg", msg.message, "hwnd", msg.hwnd)
        if got == -1:
            raise Error(
                "GetMessageW failed, GetLastError = " + String(GetLastError())
            )
        # OUR timer means the unattended run is over; destroy the window and
        # let WM_DESTROY post the quit exactly as a real close would. The
        # identity checks are not defensive padding: the runtime posts
        # thread-level timers (WM_TIMER with a null hwnd) all by itself, and
        # treating one of those as the close signal shut the window within a
        # second of opening -- which reads exactly like "the window does not
        # stay up" and is nothing of the kind.
        if (
            msg.message == UInt32(winkb_constant["WM_TIMER"]())
            and msg.hwnd == hwnd
            and msg.wParam == CLOSE_TIMER_ID
        ):
            var DestroyWindow = win32[
                def (Int) thin abi("C") -> c_int, "DestroyWindow"
            ]()
            _ = DestroyWindow(hwnd)
            continue
        _ = TranslateMessage(Pointer(to=msg).unsafe_origin_cast[MutAnyOrigin]())
        _ = DispatchMessageW(Pointer(to=msg).unsafe_origin_cast[MutAnyOrigin]())

    # Give the target back before the window goes: OLE holds a reference to
    # it, and revoking is what returns that one.
    revoke_drop(hwnd)
    _ = drop
    ole.__exit__()
    release(chrome_store[])
    chrome_store.unsafe_free()
    print("griddle: closed cleanly")
