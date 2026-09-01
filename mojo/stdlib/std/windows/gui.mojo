"""Windows, message loops, and getting pixels on screen.

The rest of `std.windows` is about what a program can ask the machine --
files, the registry, the console, the clipboard. This is the part where a
program has a window.

It exists because nine of the shipped examples had each written it out again.
Every one of them declared `WNDCLASSEXW` and `MSG` from scratch, wrote its own
`wide()` that only handled ASCII, and six of them hand-rolled the same
`BITMAPINFO` and `StretchDIBits` blit. That is not a style problem. Each copy
is a chance to get a field offset wrong, and a wrong field offset in a
`WNDCLASSEXW` is a window that does not appear with no error to explain it.

Everything here is asserted against the Windows metadata at compile time, so a
struct that has drifted from the SDK fails the build rather than the program.

WHAT THIS IS NOT. It is not a widget library and it is not a framework. There
is no layout, no controls, no event objects, no inheritance. A Windows program
is a class, a window, a procedure and a loop; this supplies the four of them
and gets out of the way. `examples/win32/life` is what using it looks like.

    from std.windows.gui import Window, WindowClass, pump, present_bgra

    fn on_message(hwnd: Int, message: UInt32, w: Int, l: Int) -> Int:
        ...

    def main() raises:
        var klass = WindowClass("MyWindow", on_message)
        var window = Window(klass, "My program", 1024, 640)
        window.show()
        while pump():
            present_bgra(window.handle, pixels, WIDTH, HEIGHT)
"""

from std.ffi import c_int
from std.memory import Pointer
from std.sys._win32 import Win32Module
from std.sys._winkb import (
    winkb_constant,
    winkb_function_dll,
    winkb_struct_size,
)

from std.sys.info import size_of
from std.python._cpython import _fn_ptr_as_opaque
from std.windows.core import WideString


# ===----------------------------------------------------------------------===#
# Entry points
# ===----------------------------------------------------------------------===#


def win32[Sig: TrivialRegisterPassable, name: StaticString]() raises -> Sig:
    """A Win32 entry point, typed, from whichever DLL the metadata names.

    The DLL is not written down anywhere: `winkb_function_dll` knows that
    `CreateWindowExW` is in USER32 and `StretchDIBits` is in GDI32, and a
    misspelled name is a compile error rather than a null at run time.

    The signature must be spelled in full. An under-declared one compiles and
    then corrupts the call, because the ABI has already been decided by the
    time anybody notices an argument is missing.

    Parameters:
        Sig: The full thin C-ABI signature.
        name: The exported function, for example "CreateWindowExW".

    Returns:
        The entry point, ready to call.

    Raises:
        If the module does not load or the export is absent.
    """
    return Win32Module(String(winkb_function_dll[name]())).function[Sig](
        String(name)
    )


# ===----------------------------------------------------------------------===#
# The structures Windows passes by pointer
#
# Every one is checked against the metadata at compile time. `Defaultable,
# Copyable, Movable` and never `TrivialRegisterPassable`: on a struct this
# size the latter changes how fields are laid out and passed, and the failure
# is silent -- `cbSize` reads back as rubbish and RegisterClassExW refuses a
# class that looks correct in the source.
# ===----------------------------------------------------------------------===#


@fieldwise_init
struct WNDCLASSEXW(Defaultable, Copyable, Movable):
    """A window class, as `RegisterClassExW` wants it."""

    var cbSize: UInt32
    var style: UInt32
    var lpfnWndProc: Int
    var cbClsExtra: Int32
    var cbWndExtra: Int32
    var hInstance: Int
    var hIcon: Int
    var hCursor: Int
    var hbrBackground: Int
    var lpszMenuName: Int
    var lpszClassName: Int
    var hIconSm: Int

    def __init__(out self):
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
struct MSG(Defaultable, Copyable, Movable):
    """One message from the queue."""

    var hwnd: Int
    var message: UInt32
    var wParam: Int
    var lParam: Int
    var time: UInt32
    var ptX: Int32
    var ptY: Int32
    var lPrivate: UInt32

    def __init__(out self):
        self.hwnd = 0
        self.message = 0
        self.wParam = 0
        self.lParam = 0
        self.time = 0
        self.ptX = 0
        self.ptY = 0
        self.lPrivate = 0


@fieldwise_init
struct RECT(Defaultable, ImplicitlyCopyable, Movable):
    """A rectangle, in the order Windows stores it."""

    var left: Int32
    var top: Int32
    var right: Int32
    var bottom: Int32

    def __init__(out self):
        self.left = 0
        self.top = 0
        self.right = 0
        self.bottom = 0

    def width(self) -> Int:
        """How wide it is.

        Returns:
            The width in pixels.
        """
        return Int(self.right - self.left)

    def height(self) -> Int:
        """How tall it is.

        Returns:
            The height in pixels.
        """
        return Int(self.bottom - self.top)


@fieldwise_init
struct POINT(Defaultable, ImplicitlyCopyable, Movable):
    """A point, in the order Windows stores it."""

    var x: Int32
    var y: Int32

    def __init__(out self):
        self.x = 0
        self.y = 0


comptime WndProc = def (Int, UInt32, Int, Int) thin abi("C") -> Int
"""The window procedure's type.

Named once so a class registration and the procedure it names cannot drift
apart. Windows calls it, so it is captureless, C-ABI, and must never raise --
unwinding through a Windows stack frame is undefined behaviour.
"""


# ===----------------------------------------------------------------------===#
# A window
# ===----------------------------------------------------------------------===#


struct WindowClass(Movable):
    """A registered window class.

    Registration happens once per class name per process, and Windows keeps
    the class until the process ends, so this does not unregister: a class
    outliving its `WindowClass` is correct rather than a leak.
    """

    var name: WideString
    var atom: Int

    def __init__(out self, name: StringSlice, procedure: WndProc) raises:
        """Register a class.

        Args:
            name: The class name, unique within the process.
            procedure: The window procedure Windows will call.

        Raises:
            If the class cannot be registered.
        """
        comptime assert (
            size_of[WNDCLASSEXW]() == winkb_struct_size["WNDCLASSEXW"]()
        ), "WNDCLASSEXW does not match this Windows SDK"

        var GetModuleHandleW = win32[
            def (Int) thin abi("C") -> Int, "GetModuleHandleW"
        ]()
        var RegisterClassExW = win32[
            def (Pointer[WNDCLASSEXW, MutAnyOrigin]) thin abi("C") -> UInt16,
            "RegisterClassExW",
        ]()
        var LoadCursorW = win32[
            def (Int, Int) thin abi("C") -> Int, "LoadCursorW"
        ]()

        self.name = WideString(name)
        var klass = WNDCLASSEXW()
        klass.cbSize = UInt32(size_of[WNDCLASSEXW]())
        # Redraw on either axis changing: a program that draws from the window
        # size has to be asked again when the size changes.
        klass.style = UInt32(
            winkb_constant["CS_HREDRAW"]() | winkb_constant["CS_VREDRAW"]()
        )
        klass.lpfnWndProc = Int(_fn_ptr_as_opaque(procedure))
        klass.hInstance = GetModuleHandleW(0)
        # An arrow, so the class has a cursor at all. A class whose hCursor is
        # zero is one Windows never sets a cursor for, and whatever the last
        # SetCursor anywhere said stays said.
        klass.hCursor = LoadCursorW(0, winkb_constant["IDC_ARROW"]())
        klass.lpszClassName = Int(self.name.unsafe_ptr())

        var atom = RegisterClassExW(
            Pointer(to=klass).unsafe_origin_cast[MutAnyOrigin]()
        )
        if atom == 0:
            raise Error("RegisterClassExW failed for " + String(name))
        self.atom = Int(atom)


struct Window(Movable):
    """A top-level window.

    Not destroyed on drop. A window's lifetime belongs to Windows and to its
    own procedure -- WM_DESTROY is what ends it -- and a Mojo value going out
    of scope is not a reason to take somebody's window away.
    """

    var handle: Int
    var title: WideString

    def __init__(
        out self,
        mut klass: WindowClass,
        title: StringSlice,
        width: Int = 1024,
        height: Int = 640,
    ) raises:
        """Create a window of the given class.

        The size asked for is the OUTER size, which is what
        `CreateWindowExW` takes and is not what a program drawing pixels
        wants. Use `client_size` afterwards rather than assuming: the border
        and the title bar are not the same thickness on every machine, and
        with `CW_USEDEFAULT` the final size is not settled until the window
        is shown.

        Args:
            klass: A registered class.
            title: The title bar text.
            width: The outer width.
            height: The outer height.

        Raises:
            If the window cannot be created.
        """
        var CreateWindowExW = win32[
            def (
                UInt32,
                Pointer[UInt16, MutAnyOrigin],
                Pointer[UInt16, MutAnyOrigin],
                UInt32,
                c_int,
                c_int,
                c_int,
                c_int,
                Int,
                Int,
                Int,
                Int,
            ) thin abi("C") -> Int,
            "CreateWindowExW",
        ]()
        var GetModuleHandleW = win32[
            def (Int) thin abi("C") -> Int, "GetModuleHandleW"
        ]()

        self.title = WideString(title)
        var use_default = winkb_constant["CW_USEDEFAULT"]()
        self.handle = CreateWindowExW(
            0,
            klass.name.unsafe_ptr(),
            self.title.unsafe_ptr(),
            UInt32(winkb_constant["WS_OVERLAPPEDWINDOW"]()),
            c_int(use_default),
            c_int(use_default),
            c_int(width),
            c_int(height),
            0,
            0,
            GetModuleHandleW(0),
            0,
        )
        if self.handle == 0:
            raise Error("CreateWindowExW failed")

    def show(self) raises:
        """Put it on screen and ask for the first paint.

        Raises:
            If an entry point cannot be resolved.
        """
        var ShowWindow = win32[
            def (Int, c_int) thin abi("C") -> c_int, "ShowWindow"
        ]()
        var UpdateWindow = win32[
            def (Int) thin abi("C") -> c_int, "UpdateWindow"
        ]()
        _ = ShowWindow(self.handle, c_int(winkb_constant["SW_SHOW"]()))
        _ = UpdateWindow(self.handle)

    def client_size(self) raises -> RECT:
        """The drawable area, which is smaller than the window.

        Returns:
            The client rectangle, whose left and top are always zero.

        Raises:
            If GetClientRect cannot be resolved.
        """
        var GetClientRect = win32[
            def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
            "GetClientRect",
        ]()
        var rc = RECT()
        _ = GetClientRect(
            self.handle, Pointer(to=rc).unsafe_origin_cast[MutAnyOrigin]()
        )
        return rc^


# ===----------------------------------------------------------------------===#
# The loop
# ===----------------------------------------------------------------------===#


def pump() raises -> Bool:
    """Handle every message waiting, without blocking.

    For a program with something to do between frames -- a simulation, an
    animation, a game. It returns as soon as the queue is empty so the caller
    can get on with the next frame.

    A window that stops taking messages is a window Windows calls hung, and
    after five seconds it draws a ghost of it and offers to close the program.
    Whatever else a frame does, it has to come back here.

    Returns:
        False when WM_QUIT has arrived and the program should stop.

    Raises:
        If an entry point cannot be resolved.
    """
    comptime assert (
        size_of[MSG]() == winkb_struct_size["MSG"]()
    ), "MSG does not match this Windows SDK"

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

    var message = MSG()
    var pointer = Pointer(to=message).unsafe_origin_cast[MutAnyOrigin]()
    while PeekMessageW(
        pointer, 0, 0, 0, UInt32(winkb_constant["PM_REMOVE"]())
    ) != 0:
        if message.message == UInt32(winkb_constant["WM_QUIT"]()):
            return False
        _ = TranslateMessage(pointer)
        _ = DispatchMessageW(pointer)
    return True


def run() raises -> Int:
    """Wait for messages until the program is asked to quit.

    For a program with nothing to do between them -- an editor, a dialog, a
    tool. It sleeps in the kernel while the queue is empty, which is the
    difference between an idle program at zero per cent and one at a hundred.

    Returns:
        The exit code from WM_QUIT.

    Raises:
        If an entry point cannot be resolved.
    """
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

    var message = MSG()
    var pointer = Pointer(to=message).unsafe_origin_cast[MutAnyOrigin]()
    # GetMessageW answers 0 for WM_QUIT and -1 for an error, and -1 is why
    # this is not `while GetMessageW(...) != 0`: that spins forever on a bad
    # window handle.
    while True:
        var got = GetMessageW(pointer, 0, 0, 0)
        if got == 0:
            return Int(message.wParam)
        if got == -1:
            raise Error("GetMessageW failed")
        _ = TranslateMessage(pointer)
        _ = DispatchMessageW(pointer)


def quit(code: Int = 0) raises:
    """Ask the loop to stop.

    Args:
        code: The exit code.

    Raises:
        If PostQuitMessage cannot be resolved.
    """
    var PostQuitMessage = win32[
        def (c_int) thin abi("C") -> NoneType, "PostQuitMessage"
    ]()
    PostQuitMessage(c_int(code))


def default_handler(
    hwnd: Int, message: UInt32, wparam: Int, lparam: Int
) raises -> Int:
    """What Windows does with a message the program did not want.

    Every window procedure must end in this. A message dropped instead of
    passed on is a window that cannot be moved, closed or resized.

    Args:
        hwnd: The window.
        message: The message.
        wparam: Its first parameter.
        lparam: Its second.

    Returns:
        Whatever the default handling returns.

    Raises:
        If DefWindowProcW cannot be resolved.
    """
    var DefWindowProcW = win32[
        def (Int, UInt32, Int, Int) thin abi("C") -> Int, "DefWindowProcW"
    ]()
    return DefWindowProcW(hwnd, message, wparam, lparam)


# ===----------------------------------------------------------------------===#
# Pixels
# ===----------------------------------------------------------------------===#


@fieldwise_init
struct BITMAPINFOHEADER(Defaultable, Copyable, Movable):
    """The header describing a device-independent bitmap."""

    var biSize: UInt32
    var biWidth: Int32
    var biHeight: Int32
    var biPlanes: UInt16
    var biBitCount: UInt16
    var biCompression: UInt32
    var biSizeImage: UInt32
    var biXPelsPerMeter: Int32
    var biYPelsPerMeter: Int32
    var biClrUsed: UInt32
    var biClrImportant: UInt32

    def __init__(out self):
        self.biSize = 0
        self.biWidth = 0
        self.biHeight = 0
        self.biPlanes = 0
        self.biBitCount = 0
        self.biCompression = 0
        self.biSizeImage = 0
        self.biXPelsPerMeter = 0
        self.biYPelsPerMeter = 0
        self.biClrUsed = 0
        self.biClrImportant = 0


def present_bgra[
    origin: MutOrigin
](
    hwnd: Int,
    pixels: Span[UInt32, origin],
    width: Int,
    height: Int,
) raises:
    """Put a buffer of BGRA pixels on a window, scaled to fill it.

    The buffer is one 32-bit word per pixel, blue in the low byte, top row
    first -- which is the layout every drawing routine in the examples
    produces and the one Windows calls a top-down DIB.

    Top-down is why the height passed to `StretchDIBits` is NEGATIVE. A
    positive height means bottom-up, which is the older convention and the
    reason a first attempt at this comes out upside down.

    Scaled rather than one-to-one: the window can be any size the person
    dragged it to, and a simulation grid is whatever the program chose.

    A `Span` rather than a pointer, so the buffer carries its own length and
    a picture whose size does not match its dimensions is refused here rather
    than read past the end of by the graphics driver.

    Parameters:
        origin: The buffer's origin (inferred).

    Args:
        hwnd: The window to draw on.
        pixels: The buffer, exactly `width * height` words.
        width: The buffer's width in pixels.
        height: The buffer's height in pixels.

    Raises:
        If the buffer is not `width * height` words, or an entry point cannot
        be resolved.
    """
    if len(pixels) != width * height:
        raise Error(
            "present_bgra: the buffer holds "
            + String(len(pixels))
            + " pixels, and "
            + String(width)
            + "x"
            + String(height)
            + " needs "
            + String(width * height)
        )
    comptime assert (
        size_of[BITMAPINFOHEADER]() == winkb_struct_size["BITMAPINFOHEADER"]()
    ), "BITMAPINFOHEADER does not match this Windows SDK"

    var GetDC = win32[def (Int) thin abi("C") -> Int, "GetDC"]()
    var ReleaseDC = win32[def (Int, Int) thin abi("C") -> c_int, "ReleaseDC"]()
    var StretchDIBits = win32[
        def (
            Int,
            c_int,
            c_int,
            c_int,
            c_int,
            c_int,
            c_int,
            c_int,
            c_int,
            Pointer[UInt32, MutAnyOrigin],
            Pointer[BITMAPINFOHEADER, MutAnyOrigin],
            UInt32,
            UInt32,
        ) thin abi("C") -> c_int,
        "StretchDIBits",
    ]()
    var GetClientRect = win32[
        def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
        "GetClientRect",
    ]()

    var rc = RECT()
    _ = GetClientRect(hwnd, Pointer(to=rc).unsafe_origin_cast[MutAnyOrigin]())

    var header = BITMAPINFOHEADER()
    header.biSize = UInt32(size_of[BITMAPINFOHEADER]())
    header.biWidth = Int32(width)
    header.biHeight = Int32(-height)  # negative: top row first
    header.biPlanes = 1
    header.biBitCount = 32
    header.biCompression = UInt32(winkb_constant["BI_RGB"]())

    var dc = GetDC(hwnd)
    if dc == 0:
        return
    _ = StretchDIBits(
        dc,
        c_int(0),
        c_int(0),
        c_int(rc.width()),
        c_int(rc.height()),
        c_int(0),
        c_int(0),
        c_int(width),
        c_int(height),
        pixels.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=header).unsafe_origin_cast[MutAnyOrigin](),
        UInt32(winkb_constant["DIB_RGB_COLORS"]()),
        UInt32(winkb_constant["SRCCOPY"]()),
    )
    _ = ReleaseDC(hwnd, dc)
