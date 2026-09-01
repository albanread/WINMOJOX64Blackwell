# A window, cleared and presented through Direct3D 11, from Mojo on Windows
# ARM64. Struct layouts are checked against the Win32 metadata by the
# compiler; COM vtable slots are queries against the same metadata.
#
# Origin rules, learned the hard way (see structptr.mojo):
#   - variadic calls take Pointer(to=local) with its TRUE origin, no cast;
#   - declared COM signatures spell Mojo-owned pointers over AnyOrigin and
#     call sites cast to AnyOrigin, which keeps the aliasing;
#   - Untracked is only for pointers Windows hands us.

from std.ffi import c_int, OwnedDLHandle
from std.memory import Pointer, OpaquePointer
from std.sys.info import size_of
from std.sys._winkb import winkb_struct_size
from std.sys._com import com_method_of


# Big structs are not register-passable. Claiming otherwise does not fail to
# compile -- it silently writes fields to the wrong places.
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


# DXGI_SWAP_CHAIN_DESC flattened: the nested DXGI_MODE_DESC, DXGI_RATIONAL and
# DXGI_SAMPLE_DESC written out as fields. Natural alignment puts OutputWindow
# at 48, as Windows expects; the comptime assert below holds it to that.
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


@fieldwise_init
struct MSG(Defaultable, Copyable, Movable):
    var hwnd: Int
    var message: UInt32
    var _pad: UInt32
    var wParam: Int
    var lParam: Int
    var time: UInt32
    var pt_x: Int32
    var pt_y: Int32

    def __init__(out self):
        self.hwnd = 0
        self.message = 0
        self._pad = 0
        self.wParam = 0
        self.lParam = 0
        self.time = 0
        self.pt_x = 0
        self.pt_y = 0


def wide(s: StaticString) -> List[UInt16]:
    """A NUL-terminated UTF-16 buffer for the W-suffixed entry points."""
    var out = List[UInt16]()
    for byte in s.as_bytes():
        out.append(UInt16(Int(byte)))
    out.append(0)
    return out^


def hex_nibble(c: UInt8) -> Int:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return Int(c) - ord("0")
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return Int(c) - ord("a") + 10
    return Int(c) - ord("A") + 10


def guid_bytes(text: StaticString) -> List[UInt8]:
    """The 16 bytes COM expects for a textual GUID.

    Not text order: the first three groups are little-endian integers, the
    last eight bytes literal. Wrong order yields E_NOINTERFACE, which looks
    like an unsupported interface rather than a mangled identifier.
    """
    var digits = List[UInt8]()
    for byte in text.as_bytes():
        if byte != UInt8(ord("-")):
            digits.append(byte)

    var raw = List[UInt8]()
    for i in range(16):
        raw.append(
            UInt8(hex_nibble(digits[i * 2]) * 16 + hex_nibble(digits[i * 2 + 1]))
        )

    var out = List[UInt8]()
    out.append(raw[3])
    out.append(raw[2])
    out.append(raw[1])
    out.append(raw[0])
    out.append(raw[5])
    out.append(raw[4])
    out.append(raw[7])
    out.append(raw[6])
    for i in range(8, 16):
        out.append(raw[i])
    return out^


def main() raises:
    # Layouts checked against Windows itself, by the compiler.
    comptime assert (
        size_of[WNDCLASSEXW]() == winkb_struct_size["WNDCLASSEXW"]()
    ), "WNDCLASSEXW does not match Windows"
    comptime assert (
        size_of[DXGI_SWAP_CHAIN_DESC]()
        == winkb_struct_size["DXGI_SWAP_CHAIN_DESC"]()
    ), "DXGI_SWAP_CHAIN_DESC does not match Windows"
    comptime assert (
        size_of[MSG]() == winkb_struct_size["MSG"]()
    ), "MSG does not match Windows"

    var user32 = OwnedDLHandle("user32.dll")
    var kernel32 = OwnedDLHandle("kernel32.dll")
    var d3d11 = OwnedDLHandle("d3d11.dll")

    var GetModuleHandleW = kernel32.get_function[Int]("GetModuleHandleW")
    var GetLastError = kernel32.get_function[UInt32]("GetLastError")
    var Sleep = kernel32.get_function[NoneType]("Sleep")
    var RegisterClassExW = user32.get_function[UInt16]("RegisterClassExW")
    var CreateWindowExW = user32.get_function[Int]("CreateWindowExW")
    var ShowWindow = user32.get_function[c_int]("ShowWindow")
    var PeekMessageW = user32.get_function[c_int]("PeekMessageW")
    var DispatchMessageW = user32.get_function[Int]("DispatchMessageW")
    var DestroyWindow = user32.get_function[c_int]("DestroyWindow")
    var create_device = d3d11.get_function[c_int](
        "D3D11CreateDeviceAndSwapChain"
    )

    var def_proc = user32.get_symbol[NoneType]("DefWindowProcW")
    if not def_proc:
        raise Error("DefWindowProcW not found")

    var hInstance = GetModuleHandleW(Int(0))
    var class_name = wide("MojoD3DWindow")
    var title = wide("Mojo + Direct3D 11 on Windows ARM64")

    # -- the window ---------------------------------------------------------
    var wc = WNDCLASSEXW()
    wc.cbSize = UInt32(size_of[WNDCLASSEXW]())
    wc.style = 0x0003  # CS_HREDRAW | CS_VREDRAW
    wc.lpfnWndProc = Int(def_proc.value())
    wc.hInstance = hInstance
    wc.lpszClassName = Int(class_name.unsafe_ptr())

    # True origin, no cast: the variadic call infers the pointer's real
    # origin, so the checker knows the callee reads wc and keeps it alive and
    # in memory. This is the idiom the stdlib uses at every libc boundary.
    var atom = RegisterClassExW(Pointer(to=wc))
    if atom == 0:
        raise Error(
            "RegisterClassExW failed, GetLastError = " + String(GetLastError())
        )

    var hwnd = CreateWindowExW(
        UInt32(0),
        class_name.unsafe_ptr(),
        title.unsafe_ptr(),
        UInt32(0x00CF0000),  # WS_OVERLAPPEDWINDOW
        c_int(120),
        c_int(120),
        c_int(800),
        c_int(600),
        Int(0),
        Int(0),
        hInstance,
        Int(0),
    )
    if hwnd == 0:
        raise Error("CreateWindowExW failed")
    _ = ShowWindow(hwnd, c_int(5))  # SW_SHOW
    print("window    ->", hwnd, "(class atom", String(atom) + ")")

    # -- the device and swap chain ------------------------------------------
    var desc = DXGI_SWAP_CHAIN_DESC()
    desc.Width = 800
    desc.Height = 600
    desc.RefreshRateNumerator = 60
    desc.RefreshRateDenominator = 1
    desc.Format = 87  # DXGI_FORMAT_B8G8R8A8_UNORM
    desc.SampleCount = 1
    desc.BufferUsage = 32  # DXGI_USAGE_RENDER_TARGET_OUTPUT
    desc.BufferCount = 2
    desc.OutputWindow = hwnd
    desc.Windowed = 1
    desc.SwapEffect = 4  # DXGI_SWAP_EFFECT_FLIP_DISCARD

    # Four separate out-parameters, each a plain local with its true origin.
    var swapchain_addr: Int = 0
    var device_addr: Int = 0
    var level: Int = 0
    var context_addr: Int = 0

    var hr = create_device(
        Int(0),  # pAdapter
        UInt32(1),  # D3D_DRIVER_TYPE_HARDWARE
        Int(0),  # Software
        UInt32(0),  # Flags
        Int(0),  # pFeatureLevels
        UInt32(0),  # FeatureLevels
        UInt32(7),  # D3D11_SDK_VERSION
        Pointer(to=desc),
        Pointer(to=swapchain_addr),
        Pointer(to=device_addr),
        Pointer(to=level),
        Pointer(to=context_addr),
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
    var iid = guid_bytes("6f15aaf2-d208-4e89-9ab4-489535d34f9c")  # ID3D11Texture2D
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
    var msg = MSG()
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

        while PeekMessageW(
            Pointer(to=msg), Int(0), UInt32(0), UInt32(0), UInt32(1)
        ) != 0:
            _ = DispatchMessageW(Pointer(to=msg))

    print("presented", frames, "frames")
    _ = Sleep(UInt32(300))
    _ = DestroyWindow(hwnd)
    print("done")
