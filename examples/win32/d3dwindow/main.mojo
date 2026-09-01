# A window, cleared and presented through Direct3D 11, from Mojo on Windows
# ARM64. The smallest of the Win32 examples: one window, one swap chain, one
# colour a frame.
#
# The window, its class, its procedure and its message loop are NOT here any
# more. They come from std.windows.gui, which is where the ninth copy of
# WNDCLASSEXW went to die. What is left in this file is Direct3D and nothing
# else -- which is what the example was always supposed to be about.
#
# Nothing below is a hand-written number. Struct layouts, field offsets, the
# back buffer's interface IID, every COM vtable slot and every DXGI enumerator
# are queries against the Win32 metadata, so a wrong one is a compile error
# naming the source line rather than a black window at run time.
#
# Origin rules, learned the hard way (see structptr.mojo):
#   - a fully declared signature spells Mojo-owned pointers over AnyOrigin,
#     and the call site casts to AnyOrigin, which keeps the aliasing;
#   - Untracked is only for pointers Windows hands us.
# The third rule -- that a VARIADIC call takes Pointer(to=local) with its true
# origin and no cast -- no longer applies anywhere in this file, because there
# are no variadic calls left. win32[] gives every entry point a real signature,
# which is the better trade: an under-declared variadic call compiles and then
# corrupts itself, and this one cannot be spelled wrong.

from std.ffi import c_int
from std.memory import Pointer, OpaquePointer
from std.sys.info import size_of
from std.sys._com import com_method_of, _guid_bytes
from std.sys._winkb import (
    winkb_constant,
    winkb_field_offset,
    winkb_interface_iid,
    winkb_struct_size,
)
from std.windows.gui import (
    Window,
    WindowClass,
    default_handler,
    pump,
    quit,
    win32,
)


# DXGI_SWAP_CHAIN_DESC flattened: the nested DXGI_MODE_DESC, DXGI_RATIONAL and
# DXGI_SAMPLE_DESC written out as fields. This one stays local. It is the
# subject of the example, and a Direct3D structure sitting in a module about
# windows and message loops would make that module worse, not this file
# shorter.
#
# Big structs are not register-passable. Claiming otherwise does not fail to
# compile -- it silently writes fields to the wrong places.
@fieldwise_init
struct DXGI_SWAP_CHAIN_DESC(Defaultable, Copyable, Movable):
    var Width: UInt32
    var Height: UInt32
    var RefreshRateNumerator: UInt32
    var RefreshRateDenominator: UInt32
    var Format: UInt32
    var ScanlineOrdering: UInt32
    var Scaling: UInt32
    var SampleCount: UInt32
    var SampleQuality: UInt32
    var BufferUsage: UInt32
    var BufferCount: UInt32
    var OutputWindow: Int  # at 48, after 4 bytes of padding
    var Windowed: Int32
    var SwapEffect: UInt32
    var Flags: UInt32

    def __init__(out self):
        self.Width = 0
        self.Height = 0
        self.RefreshRateNumerator = 0
        self.RefreshRateDenominator = 0
        self.Format = 0
        self.ScanlineOrdering = 0
        self.Scaling = 0
        self.SampleCount = 0
        self.SampleQuality = 0
        self.BufferUsage = 0
        self.BufferCount = 0
        self.OutputWindow = 0
        self.Windowed = 0
        self.SwapEffect = 0
        self.Flags = 0


@export("d3dwindow_wndproc")
def d3dwindow_wndproc(
    hwnd: Int, message: UInt32, wparam: Int, lparam: Int
) abi("C") -> Int:
    """Stop when the window goes away; let Windows have the rest.

    The version before this one named DefWindowProcW itself as the class
    procedure, so closing the window destroyed it and the loop carried on
    presenting to a handle that no longer existed. Four lines of Mojo fix
    that, and they have to live here: what a program does with a message is
    the program, not the library.

    Never raises. Unwinding through a Windows stack frame is undefined
    behaviour, so every failure is swallowed here.
    """
    try:
        if message == UInt32(winkb_constant["WM_DESTROY"]()):
            quit(0)
            return 0
        return default_handler(hwnd, message, wparam, lparam)
    except:
        return 0


def main() raises:
    # The one layout this file still declares, checked against Windows itself
    # by the compiler. WNDCLASSEXW and MSG used to be checked here too; they
    # are checked in std.windows.gui now, once, for every example.
    comptime assert (
        size_of[DXGI_SWAP_CHAIN_DESC]()
        == winkb_struct_size["DXGI_SWAP_CHAIN_DESC"]()
    ), "DXGI_SWAP_CHAIN_DESC does not match Windows"
    # A size assert does not prove a field is in the right PLACE: swap two
    # equally sized fields and the size is unchanged. OutputWindow is the one
    # that matters -- an HWND read from the wrong offset is a swap chain
    # bound to nothing, and it fails silently.
    comptime assert (
        winkb_field_offset["DXGI_SWAP_CHAIN_DESC", "OutputWindow"]() == 48
    ), "DXGI_SWAP_CHAIN_DESC.OutputWindow moved; re-flatten the struct"

    # -- the window ---------------------------------------------------------
    # Three lines where there were forty. WindowClass fills in cbSize, the
    # redraw-on-resize style, the module handle and an arrow cursor; Window
    # converts the title through the real UTF-16 conversion rather than the
    # ASCII-only wide() this file used to carry.
    var klass = WindowClass("MojoD3DWindow", d3dwindow_wndproc)
    var window = Window(klass, "Mojo + Direct3D 11 on Windows ARM64", 800, 600)
    window.show()
    print("window    ->", window.handle, "(class atom", String(klass.atom) + ")")

    # -- the device and swap chain ------------------------------------------
    # The buffer is sized from the CLIENT rectangle, not from the 800x600
    # asked for above: that number is the outer size, borders and title bar
    # included, and it is not the area anything is drawn into. Getting this
    # wrong costs nothing on a solid clear and is a stretched, soft image the
    # moment there is a texture.
    var client = window.client_size()
    var desc = DXGI_SWAP_CHAIN_DESC()
    desc.Width = UInt32(client.width())
    desc.Height = UInt32(client.height())
    desc.RefreshRateNumerator = 60
    desc.RefreshRateDenominator = 1
    desc.Format = UInt32(winkb_constant["DXGI_FORMAT_B8G8R8A8_UNORM"]())
    desc.SampleCount = 1
    desc.BufferUsage = UInt32(
        winkb_constant["DXGI_USAGE_RENDER_TARGET_OUTPUT"]()
    )
    # FLIP_DISCARD needs two buffers or more; one is a validation failure.
    desc.BufferCount = 2
    desc.OutputWindow = window.handle
    desc.Windowed = 1
    desc.SwapEffect = UInt32(winkb_constant["DXGI_SWAP_EFFECT_FLIP_DISCARD"]())

    var create_device = win32[
        def (
            Int,  # pAdapter
            UInt32,  # DriverType
            Int,  # Software
            UInt32,  # Flags
            Int,  # pFeatureLevels
            UInt32,  # FeatureLevels
            UInt32,  # SDKVersion
            Pointer[DXGI_SWAP_CHAIN_DESC, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
            Pointer[UInt32, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "D3D11CreateDeviceAndSwapChain",
    ]()

    # Four separate out-parameters, each a plain local. pFeatureLevel is a
    # UInt32 out-parameter and is declared as one: Windows writes four bytes
    # there, and an Int that happens to have been zeroed only looks correct.
    var swapchain_addr: Int = 0
    var device_addr: Int = 0
    var level: UInt32 = 0
    var context_addr: Int = 0

    var hr = create_device(
        0,
        UInt32(winkb_constant["D3D_DRIVER_TYPE_HARDWARE"]()),
        0,
        UInt32(0),
        0,
        UInt32(0),
        UInt32(winkb_constant["D3D11_SDK_VERSION"]()),
        Pointer(to=desc).unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=swapchain_addr).unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=device_addr).unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=level).unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=context_addr).unsafe_origin_cast[MutAnyOrigin](),
    )
    print("D3D11CreateDeviceAndSwapChain hr =", hr, " feature level =", level)
    if hr != 0 or swapchain_addr == 0:
        raise Error("Direct3D device creation failed")

    # Interface pointers come FROM Windows: untracked is their documented
    # origin -- they alias no value the compiler manages.
    var swapchain = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=swapchain_addr
    )
    var device = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=device_addr
    )
    var context = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=context_addr
    )

    # -- back buffer and render target view ---------------------------------
    # The IID is a query, not a literal. A GUID typed out by hand is 32 hex
    # digits in an order that is not the order it is written in, and getting
    # it wrong yields E_NOINTERFACE -- which reads as "this object does not
    # support that interface" rather than "you mistyped the interface".
    var iid = _guid_bytes(winkb_interface_iid["ID3D11Texture2D"]())
    var backbuf_addr: Int = 0

    var get_buffer = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            Pointer[UInt8, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "IDXGISwapChain",
        "GetBuffer",
    ](swapchain)
    var hr2 = get_buffer(
        swapchain,
        UInt32(0),
        iid.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=backbuf_addr).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr2 != 0:
        raise Error("GetBuffer failed, hr = " + String(hr2))
    print("back buffer ->", backbuf_addr)

    var rtv_addr: Int = 0
    var create_rtv = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            Int,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreateRenderTargetView",
    ](device)
    var hr3 = create_rtv(
        device,
        backbuf_addr,
        Int(0),
        Pointer(to=rtv_addr).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr3 != 0:
        raise Error("CreateRenderTargetView failed, hr = " + String(hr3))
    print("render target view ->", rtv_addr)

    # -- draw ---------------------------------------------------------------
    var clear = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            Pointer[Float32, MutAnyOrigin],
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "ClearRenderTargetView",
    ](context)
    var present = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], UInt32, UInt32
        ) thin abi("C") -> c_int,
        "IDXGISwapChain",
        "Present",
    ](swapchain)

    var colour = List[Float32](length=4, fill=0.0)
    var frames = 0

    for i in range(180):
        # A slow teal-to-green fade, so it is visibly being drawn each frame.
        var t = Float32(i) / 180.0
        colour[0] = 0.10
        colour[1] = 0.30 + 0.50 * t
        colour[2] = 0.55 - 0.25 * t
        colour[3] = 1.0

        _ = clear(
            context,
            rtv_addr,
            colour.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        )
        var phr = present(swapchain, UInt32(1), UInt32(0))
        if phr != 0:
            raise Error("Present failed, hr = " + String(phr))
        frames += 1

        # Every message waiting, without blocking, and False once WM_QUIT has
        # arrived. A window that stops taking messages is one Windows calls
        # hung; whatever else a frame does, it has to come back here.
        if not pump():
            break

    print("presented", frames, "frames")

    var Sleep = win32[def (UInt32) thin abi("C") -> NoneType, "Sleep"]()
    var DestroyWindow = win32[
        def (Int) thin abi("C") -> c_int, "DestroyWindow"
    ]()
    _ = Sleep(UInt32(300))
    _ = DestroyWindow(window.handle)
    print("done")
