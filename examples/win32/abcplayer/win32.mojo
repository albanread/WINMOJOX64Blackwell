# The handful of Windows-shaped things every other file here needs.
#
# There is not a hand-declared DLL name, message number, struct size or vtable
# slot anywhere in this example. `win32[...]` asks the metadata which library
# exports a name and types the call; the four structures below assert their
# own size against the metadata at compile time, so a layout that drifts from
# Windows fails the build rather than the picture.

from std.ffi import c_int
from std.memory import Pointer
from std.sys._win32 import Win32Module
from std.sys._winkb import winkb_function_dll, winkb_struct_size
from std.sys.info import size_of


def win32[Sig: TrivialRegisterPassable, name: StaticString]() raises -> Sig:
    """A Win32 entry point, typed, from whichever DLL the metadata names.

    Parameters:
        Sig: The full thin C-ABI signature. Spell every argument -- an
            under-declared signature compiles and then corrupts the call.
        name: The exported function, e.g. "CreateWindowExW".
    """
    return Win32Module(String(winkb_function_dll[name]())).function[Sig](
        String(name)
    )


def wide(s: StaticString) -> List[UInt16]:
    """A NUL-terminated UTF-16 buffer for the W-suffixed entry points."""
    var out = List[UInt16]()
    for byte in s.as_bytes():
        out.append(UInt16(Int(byte)))
    out.append(0)
    return out^


def wide_of(s: String) -> List[UInt16]:
    """The same, for text built at run time -- every label this UI draws.

    One byte to one unit would be Latin-1 rather than UTF-8, so this walks
    codepoints and encodes anything above the basic plane as a surrogate
    pair. The panel is ASCII today; a tune title from a folk collection very
    often is not, and the day one arrives is not the day to discover this.
    """
    var out = List[UInt16]()
    for c in s.codepoints():
        var v = Int(c)
        if v >= 0x10000:
            var u = v - 0x10000
            out.append(UInt16(0xD800 + (u >> 10)))
            out.append(UInt16(0xDC00 + (u & 0x3FF)))
        else:
            out.append(UInt16(v))
    out.append(0)
    return out^


@fieldwise_init
struct WNDCLASSEXW(Defaultable, Copyable, Movable):
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
struct RECT(Defaultable, Copyable, Movable):
    var left: Int32
    var top: Int32
    var right: Int32
    var bottom: Int32

    def __init__(out self):
        self.left = 0
        self.top = 0
        self.right = 0
        self.bottom = 0


def check_layouts():
    """Every declaration above, checked against Windows itself."""
    comptime assert (
        size_of[WNDCLASSEXW]() == winkb_struct_size["WNDCLASSEXW"]()
    ), "WNDCLASSEXW does not match Windows"
    comptime assert (
        size_of[MSG]() == winkb_struct_size["MSG"]()
    ), "MSG does not match Windows"
    comptime assert (
        size_of[RECT]() == winkb_struct_size["RECT"]()
    ), "RECT does not match Windows"
