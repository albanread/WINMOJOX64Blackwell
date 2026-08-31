"""The smallest Direct2D window that can be wrong.

Registers a class, shows a window, makes an ID2D1HwndRenderTarget, clears it
to red, and asks the target whether it was allowed to present. Nothing else --
no menu, no DWM attributes, no text, no document. If this reports OCCLUDED
then nothing Griddle does is the cause.
"""

from std.ffi import c_int
from std.memory import Pointer
from std.python._cpython import _fn_ptr_as_opaque
from std.sys._com import com_addr, com_method_of
from std.sys._winkb import winkb_constant
from std.sys.com import Com
from std.sys.info import size_of

from ide.chrome import (
    D2D_COLOR_F,
    D2D_SIZE_U,
    D2D1_HWND_RENDER_TARGET_PROPERTIES,
    D2D1_RENDER_TARGET_PROPERTIES,
    iid_bytes,
)
from ide.win32 import MSG, RECT, WNDCLASSEXW, WndProcType, wide, win32
from ide.screenshot import capture


@export("minimal_wndproc")
def minimal_wndproc(
    hwnd: Int, message: UInt32, wparam: Int, lparam: Int
) abi("C") -> Int:
    try:
        var DefWindowProcW = win32[
            def (Int, UInt32, Int, Int) thin abi("C") -> Int, "DefWindowProcW"
        ]()
        return DefWindowProcW(hwnd, message, wparam, lparam)
    except:
        return 0


def main() raises:
    var SetProcessDpiAwarenessContext = win32[
        def (Int) thin abi("C") -> c_int, "SetProcessDpiAwarenessContext"
    ]()
    var GetLastError = win32[def () thin abi("C") -> UInt32, "GetLastError"]()
    var ok = SetProcessDpiAwarenessContext(-4)
    print("dpi-aware call ->", Int(ok), "lasterror", Int(GetLastError()))
    var GetDC0 = win32[def (Int) thin abi("C") -> Int, "GetDC"]()
    var GetDeviceCaps = win32[
        def (Int, c_int) thin abi("C") -> c_int, "GetDeviceCaps"
    ]()
    var dc0 = GetDC0(0)
    print(
        "HORZRES", Int(GetDeviceCaps(dc0, c_int(8))),
        "DESKTOPHORZRES", Int(GetDeviceCaps(dc0, c_int(118))),
        "LOGPIXELSX", Int(GetDeviceCaps(dc0, c_int(88))),
    )

    var GetModuleHandleW = win32[
        def (Int) thin abi("C") -> Int, "GetModuleHandleW"
    ]()
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
    var GetClientRect = win32[
        def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
        "GetClientRect",
    ]()

    var hInstance = GetModuleHandleW(0)
    var class_name = wide("MinimalD2D")
    var title = wide("MinimalD2D")
    var proc: WndProcType = minimal_wndproc
    var wc = WNDCLASSEXW()
    wc.cbSize = UInt32(size_of[WNDCLASSEXW]())
    wc.lpfnWndProc = Int(_fn_ptr_as_opaque(proc))
    wc.hInstance = hInstance
    wc.lpszClassName = Int(class_name.unsafe_ptr())
    _ = RegisterClassExW(Pointer(to=wc).unsafe_origin_cast[MutAnyOrigin]())

    var hwnd = CreateWindowExW(
        UInt32(0),
        class_name.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        title.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        UInt32(winkb_constant["WS_OVERLAPPEDWINDOW"]()),
        c_int(200), c_int(200), c_int(800), c_int(600),
        0, 0, hInstance, 0,
    )
    print("window", hwnd)
    _ = ShowWindow(hwnd, c_int(winkb_constant["SW_SHOW"]()))

    var rc = RECT()
    _ = GetClientRect(hwnd, Pointer(to=rc).unsafe_origin_cast[MutAnyOrigin]())
    var w = Int(rc.right - rc.left)
    var h = Int(rc.bottom - rc.top)

    var D2D1CreateFactory = win32[
        def (
            UInt32, Int, Int, Pointer[Int, MutAnyOrigin]
        ) thin abi("C") -> Int32,
        "D2D1CreateFactory",
    ]()
    var iid = iid_bytes["ID2D1Factory"]()
    var factory_ptr = Int(0)
    var hr = D2D1CreateFactory(
        0, Int(iid.unsafe_ptr()), 0,
        Pointer(to=factory_ptr).unsafe_origin_cast[MutAnyOrigin](),
    )
    _ = iid
    print("factory hr", hr, "ptr", factory_ptr)

    var rt_props = D2D1_RENDER_TARGET_PROPERTIES()
    rt_props.dpiX = 96.0
    rt_props.dpiY = 96.0
    var hp = D2D1_HWND_RENDER_TARGET_PROPERTIES()
    hp.hwnd = hwnd
    hp.pixelSize = D2D_SIZE_U(UInt32(w), UInt32(h))
    var target = Int(0)
    var factory = Com[StaticString("ID2D1Factory")](borrowed=factory_ptr)
    _ = factory.CreateHwndRenderTarget(
        com_addr(rt_props), com_addr(hp), com_addr(target)
    )
    print("target", target, "size", w, "x", h)

    var this = OpaquePointer[MutUntrackedOrigin](unsafe_from_address=target)
    for i in range(3):
        com_method_of[
            def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> NoneType,
            "ID2D1HwndRenderTarget", "BeginDraw",
        ](this)(this)
        var red = D2D_COLOR_F.rgb(0xFF0000)
        com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin],
                Pointer[D2D_COLOR_F, MutAnyOrigin],
            ) thin abi("C") -> NoneType,
            "ID2D1HwndRenderTarget", "Clear",
        ](this)(this, com_addr(red))
        _ = red
        var end = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], Int, Int
            ) thin abi("C") -> Int32,
            "ID2D1HwndRenderTarget", "EndDraw",
        ](this)(this, 0, 0)
        var state = com_method_of[
            def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> UInt32,
            "ID2D1HwndRenderTarget", "CheckWindowState",
        ](this)(this)
        print("frame", i, "enddraw", end, "state", Int(state), "(1=OCCLUDED)")

    var n = capture(hwnd, String("E:/Mojo/WINMOJOX64Blackwell/build/minimal.png"))
    print("wrote", n, "bytes")
