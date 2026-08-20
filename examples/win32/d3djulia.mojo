# An animated Julia set in a pixel shader, from Mojo on Windows ARM64 -- now
# with a real window procedure written in Mojo and a real message loop.
#
# The flicker the first versions had turned out to be flip-model Present
# unbinding the render target: bound once before the loop, every alternate
# Draw went into an unbound pipeline, and the display ping-ponged between the
# image and undefined buffer contents. The binding is reissued per frame.
# The Mojo window procedure below ALSO keeps GDI off the window (refusing
# WM_ERASEBKGND, validating WM_PAINT without painting) -- correct and
# necessary, but it was not the flicker; the diagnosis took two passes.
#
# Frame rate is locked to ~60 by syncing to the display's actual refresh rate
# (read from DEVMODEW -- by field offset, without declaring the 272-byte
# struct) and presenting every refresh/60 vblanks.
#
# Everything Windows-shaped is queried from the metadata: struct sizes and
# field offsets, all vtable slots, the GetBuffer IID, which DLLs export
# D3DCompile and EnumDisplaySettingsW. No hardcoded slots, sizes, or GUIDs.

from std.ffi import c_int, OwnedDLHandle
from std.math import cos, sin
from std.memory import Pointer, OpaquePointer
from std.python._cpython import _fn_ptr_as_opaque
from std.sys.info import size_of
from std.sys._com import ComPtr, _guid_bytes, com_method_of
from std.sys._win32 import Win32Module
from std.sys._winkb import (
    winkb_field_offset,
    winkb_function_dll,
    winkb_interface_iid,
    winkb_struct_size,
)


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
    var OutputWindow: Int
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
struct D3D11_BUFFER_DESC(Defaultable, Copyable, Movable):
    var ByteWidth: UInt32
    var Usage: UInt32
    var BindFlags: UInt32
    var CPUAccessFlags: UInt32
    var MiscFlags: UInt32
    var StructureByteStride: UInt32

    def __init__(out self):
        self.ByteWidth = 0
        self.Usage = 0
        self.BindFlags = 0
        self.CPUAccessFlags = 0
        self.MiscFlags = 0
        self.StructureByteStride = 0


@fieldwise_init
struct D3D11_VIEWPORT(Defaultable, Copyable, Movable):
    var TopLeftX: Float32
    var TopLeftY: Float32
    var Width: Float32
    var Height: Float32
    var MinDepth: Float32
    var MaxDepth: Float32

    def __init__(out self):
        self.TopLeftX = 0.0
        self.TopLeftY = 0.0
        self.Width = 0.0
        self.Height = 0.0
        self.MinDepth = 0.0
        self.MaxDepth = 0.0


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
    var out = List[UInt16]()
    for byte in s.as_bytes():
        out.append(UInt16(Int(byte)))
    out.append(0)
    return out^


def cstr(s: StaticString) -> List[UInt8]:
    var out = List[UInt8]()
    for byte in s.as_bytes():
        out.append(byte)
    out.append(0)
    return out^


# ===----------------------------------------------------------------------===#
# The window procedure. Windows calls this; it is a plain C function whose
# state, had it needed any, would travel through the window's user data.
# ===----------------------------------------------------------------------===#

comptime WM_DESTROY: UInt32 = 0x0002
comptime WM_PAINT: UInt32 = 0x000F
comptime WM_CLOSE: UInt32 = 0x0010
comptime WM_QUIT: UInt32 = 0x0012
comptime WM_ERASEBKGND: UInt32 = 0x0014

comptime WndProcType = def (Int, UInt32, Int, Int) thin abi("C") -> Int


@export("mojo_wndproc")
def mojo_wndproc(
    hwnd: Int, message: UInt32, wparam: Int, lparam: Int
) abi("C") -> Int:
    # Must never raise -- unwinding through a Windows frame is undefined --
    # so everything is caught here. Win32Module hits the process cache, which
    # is what makes calling it from inside a message callback reasonable.
    try:
        var user32 = Win32Module("user32.dll")

        if message == WM_ERASEBKGND:
            # The flicker fix, part one: claim the background is handled so
            # GDI never clears the window out from under the swap chain.
            return 1

        if message == WM_PAINT:
            # Part two: validate without painting. BeginPaint would give GDI
            # a surface DWM then fights the DXGI frames with.
            var ValidateRect = user32.function[
                def (Int, Int) thin abi("C") -> c_int
            ]("ValidateRect")
            _ = ValidateRect(hwnd, Int(0))
            return 0

        if message == WM_CLOSE:
            var DestroyWindow = user32.function[
                def (Int) thin abi("C") -> c_int
            ]("DestroyWindow")
            _ = DestroyWindow(hwnd)
            return 0

        if message == WM_DESTROY:
            var PostQuitMessage = user32.function[
                def (c_int) thin abi("C") -> NoneType
            ]("PostQuitMessage")
            _ = PostQuitMessage(c_int(0))
            return 0

        var DefWindowProcW = user32.function[WndProcType]("DefWindowProcW")
        return DefWindowProcW(hwnd, message, wparam, lparam)
    except:
        return 0


# ===----------------------------------------------------------------------===#
# Shaders
# ===----------------------------------------------------------------------===#

comptime HLSL: StaticString = """
struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; };

VSOut vsmain(uint id : SV_VertexID) {
    VSOut o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    o.uv = uv;
    return o;
}

cbuffer Params : register(b0) { float4 p; };  // x,y: c   z: aspect   w: time

float4 psmain(VSOut i) : SV_Target {
    float2 z = float2((i.uv.x * 2.0 - 1.0) * p.z, i.uv.y * 2.0 - 1.0) * 1.6;
    float2 c = float2(p.x, p.y);
    float m = 0.0;
    bool escaped = false;
    [loop] for (int k = 0; k < 200; k++) {
        z = float2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
        float r2 = dot(z, z);
        if (r2 > 16.0) {
            m = (float)k - log2(log2(r2)) + 4.0;
            escaped = true;
            break;
        }
    }
    if (!escaped)
        return float4(0.02, 0.01, 0.05, 1.0);
    float3 col = 0.5
        + 0.5 * cos(6.28318 * (m * 0.012 + p.w * 0.03
                               + float3(0.00, 0.33, 0.67)));
    return float4(col, 1.0);
}
"""


def blob_ptr(blob: ComPtr) raises -> Int:
    return com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> Int,
        "ID3DBlob",
        "GetBufferPointer",
    ](blob.interface())(blob.interface())


def blob_size(blob: ComPtr) raises -> Int:
    return com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> Int,
        "ID3DBlob",
        "GetBufferSize",
    ](blob.interface())(blob.interface())


def blob_text(blob: ComPtr) raises -> String:
    var ptr = blob_ptr(blob)
    var n = blob_size(blob)
    var bytes = List[UInt8]()
    var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=ptr)
    for i in range(n):
        bytes.append(src.unsafe_offset(i)[])
    return String(unsafe_from_utf8=Span(bytes))


def compile_shader(
    compile_fn: def (
        Int, Int, Int, Int, Int, Int, Int, UInt32, UInt32,
        Pointer[Int, MutAnyOrigin],
        Pointer[Int, MutAnyOrigin],
    ) thin abi("C") -> Int32,
    source: StaticString,
    entry: StaticString,
    target: StaticString,
) raises -> ComPtr[StaticString("ID3DBlob")]:
    var src = cstr(source)
    var entry_c = cstr(entry)
    var target_c = cstr(target)
    var code_addr: Int = 0
    var errors_addr: Int = 0

    var hr = compile_fn(
        Int(src.unsafe_ptr()),
        len(src) - 1,
        Int(0),
        Int(0),
        Int(0),
        Int(entry_c.unsafe_ptr()),
        Int(target_c.unsafe_ptr()),
        UInt32(0),
        UInt32(0),
        Pointer(to=code_addr).unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=errors_addr).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr != 0:
        var message = String("(no error blob)")
        if errors_addr != 0:
            var errors = ComPtr[StaticString("ID3DBlob")](adopt=errors_addr)
            message = blob_text(errors)
        raise Error("HLSL " + String(entry) + " failed: " + message)
    return ComPtr[StaticString("ID3DBlob")](adopt=code_addr)


def display_refresh_hz(user32: OwnedDLHandle) raises -> Int:
    """The current display mode's refresh rate, read from DEVMODEW by field
    offset -- the struct is 272 bytes and never declared."""
    var EnumDisplaySettingsW = user32.get_function[c_int](
        "EnumDisplaySettingsW"
    )

    comptime DM_BYTES = winkb_struct_size["DEVMODEW"]()
    var devmode = List[UInt8](length=DM_BYTES, fill=0)

    # dmSize must hold the struct size before the call.
    comptime DM_SIZE_AT = winkb_field_offset["DEVMODEW", "dmSize"]()
    devmode.unsafe_ptr().unsafe_offset(DM_SIZE_AT).unsafe_bitcast[UInt16]()[] = (
        UInt16(DM_BYTES)
    )

    # ENUM_CURRENT_SETTINGS is (DWORD)-1.
    var ok = EnumDisplaySettingsW(
        Int(0), UInt32(0xFFFFFFFF), devmode.unsafe_ptr()
    )
    if ok == 0:
        return 60  # a sane default if the query fails

    comptime FREQ_AT = winkb_field_offset["DEVMODEW", "dmDisplayFrequency"]()
    var hz = Int(
        devmode.unsafe_ptr().unsafe_offset(FREQ_AT).unsafe_bitcast[UInt32]()[]
    )
    return hz if hz > 0 else 60


def main() raises:
    comptime assert (
        size_of[D3D11_BUFFER_DESC]() == winkb_struct_size["D3D11_BUFFER_DESC"]()
    ), "D3D11_BUFFER_DESC does not match Windows"
    comptime assert (
        size_of[D3D11_VIEWPORT]() == winkb_struct_size["D3D11_VIEWPORT"]()
    ), "D3D11_VIEWPORT does not match Windows"
    comptime assert (
        size_of[DXGI_SWAP_CHAIN_DESC]()
        == winkb_struct_size["DXGI_SWAP_CHAIN_DESC"]()
    ), "DXGI_SWAP_CHAIN_DESC does not match Windows"

    var user32 = OwnedDLHandle("user32.dll")
    var kernel32 = OwnedDLHandle("kernel32.dll")
    var d3d11 = OwnedDLHandle("d3d11.dll")

    var GetModuleHandleW = kernel32.get_function[Int]("GetModuleHandleW")
    var GetLastError = kernel32.get_function[UInt32]("GetLastError")
    var RegisterClassExW = user32.get_function[UInt16]("RegisterClassExW")
    var CreateWindowExW = user32.get_function[Int]("CreateWindowExW")
    var ShowWindow = user32.get_function[c_int]("ShowWindow")
    var PeekMessageW = user32.get_function[c_int]("PeekMessageW")
    var DispatchMessageW = user32.get_function[Int]("DispatchMessageW")
    var create_device = d3d11.get_function[c_int](
        "D3D11CreateDeviceAndSwapChain"
    )

    print("D3DCompile lives in", winkb_function_dll["D3DCompile"]())
    var compiler_dll = Win32Module("d3dcompiler_47.dll")
    var D3DCompile = compiler_dll.function[
        def (
            Int, Int, Int, Int, Int, Int, Int, UInt32, UInt32,
            Pointer[Int, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> Int32
    ]("D3DCompile")

    # -- the 60fps lock ------------------------------------------------------
    var hz = display_refresh_hz(user32)
    var interval = (hz + 30) // 60
    if interval < 1:
        interval = 1
    print(
        "display refresh", hz, "Hz -> present every", interval,
        "vblank(s) = ~", hz // interval, "fps",
    )

    # -- window, with the Mojo window procedure ------------------------------
    var hInstance = GetModuleHandleW(Int(0))
    var class_name = wide("MojoJuliaWindow")
    var title = wide("Julia set - Mojo pixel shader on Windows ARM64")

    var proc: WndProcType = mojo_wndproc

    var wc = WNDCLASSEXW()
    wc.cbSize = UInt32(size_of[WNDCLASSEXW]())
    wc.style = 0x0003
    wc.lpfnWndProc = Int(_fn_ptr_as_opaque(proc))
    wc.hInstance = hInstance
    wc.lpszClassName = Int(class_name.unsafe_ptr())

    if RegisterClassExW(Pointer(to=wc)) == 0:
        raise Error(
            "RegisterClassExW failed, GetLastError = " + String(GetLastError())
        )

    comptime WIDTH = 960
    comptime HEIGHT = 720
    var hwnd = CreateWindowExW(
        UInt32(0),
        class_name.unsafe_ptr(),
        title.unsafe_ptr(),
        UInt32(0x00CF0000),
        c_int(100),
        c_int(100),
        c_int(WIDTH),
        c_int(HEIGHT),
        Int(0),
        Int(0),
        hInstance,
        Int(0),
    )
    if hwnd == 0:
        raise Error("CreateWindowExW failed")
    _ = ShowWindow(hwnd, c_int(5))

    # -- device + swap chain -------------------------------------------------
    var desc = DXGI_SWAP_CHAIN_DESC()
    desc.Width = UInt32(WIDTH)
    desc.Height = UInt32(HEIGHT)
    desc.RefreshRateNumerator = 60
    desc.RefreshRateDenominator = 1
    desc.Format = 87
    desc.SampleCount = 1
    desc.BufferUsage = 32
    desc.BufferCount = 2
    desc.OutputWindow = hwnd
    desc.Windowed = 1
    desc.SwapEffect = 4  # FLIP_DISCARD

    var swapchain_addr: Int = 0
    var device_addr: Int = 0
    var level: Int = 0
    var context_addr: Int = 0
    var hr = create_device(
        Int(0),
        UInt32(1),
        Int(0),
        UInt32(0),
        Int(0),
        UInt32(0),
        UInt32(7),
        Pointer(to=desc),
        Pointer(to=swapchain_addr),
        Pointer(to=device_addr),
        Pointer(to=level),
        Pointer(to=context_addr),
    )
    if hr != 0 or swapchain_addr == 0:
        raise Error("Direct3D device creation failed")

    var swapchain = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=swapchain_addr
    )
    var device = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=device_addr
    )
    var context = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=context_addr
    )

    # -- back buffer + render target view ------------------------------------
    var backbuf_addr: Int = 0
    var iid_texture = _guid_bytes(winkb_interface_iid["ID3D11Texture2D"]())
    var hr2 = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            Pointer[UInt8, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "IDXGISwapChain",
        "GetBuffer",
    ](swapchain)(
        swapchain,
        UInt32(0),
        iid_texture.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=backbuf_addr).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr2 != 0:
        raise Error("GetBuffer failed")
    var backbuffer = ComPtr[StaticString("ID3D11Texture2D")](adopt=backbuf_addr)

    var rtv_addr: Int = 0
    var hr3 = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            Int,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreateRenderTargetView",
    ](device)(
        device,
        backbuf_addr,
        Int(0),
        Pointer(to=rtv_addr).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr3 != 0:
        raise Error("CreateRenderTargetView failed")

    # -- shaders -------------------------------------------------------------
    var vs_blob = compile_shader(D3DCompile, HLSL, "vsmain", "vs_5_0")
    var ps_blob = compile_shader(D3DCompile, HLSL, "psmain", "ps_5_0")
    print("shaders compiled")

    var vs_addr: Int = 0
    var hr4 = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            Int,
            Int,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreateVertexShader",
    ](device)(
        device,
        blob_ptr(vs_blob),
        blob_size(vs_blob),
        Int(0),
        Pointer(to=vs_addr).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr4 != 0:
        raise Error("CreateVertexShader failed")
    var vshader = ComPtr[StaticString("ID3D11VertexShader")](adopt=vs_addr)

    var ps_addr: Int = 0
    var hr5 = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            Int,
            Int,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreatePixelShader",
    ](device)(
        device,
        blob_ptr(ps_blob),
        blob_size(ps_blob),
        Int(0),
        Pointer(to=ps_addr).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr5 != 0:
        raise Error("CreatePixelShader failed")
    var pshader = ComPtr[StaticString("ID3D11PixelShader")](adopt=ps_addr)

    # -- constant buffer -----------------------------------------------------
    var cb_desc = D3D11_BUFFER_DESC()
    cb_desc.ByteWidth = 16
    cb_desc.Usage = 0
    cb_desc.BindFlags = 4

    var cbuf_addr: Int = 0
    var hr6 = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Pointer[D3D11_BUFFER_DESC, MutAnyOrigin],
            Int,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreateBuffer",
    ](device)(
        device,
        Pointer(to=cb_desc).unsafe_origin_cast[MutAnyOrigin](),
        Int(0),
        Pointer(to=cbuf_addr).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr6 != 0:
        raise Error("CreateBuffer failed")
    var cbuffer = ComPtr[StaticString("ID3D11Buffer")](adopt=cbuf_addr)

    # -- fixed pipeline state ------------------------------------------------
    var viewport = D3D11_VIEWPORT()
    viewport.Width = Float32(WIDTH)
    viewport.Height = Float32(HEIGHT)
    viewport.MaxDepth = 1.0

    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            Pointer[D3D11_VIEWPORT, MutAnyOrigin],
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "RSSetViewports",
    ](context)(
        context,
        UInt32(1),
        Pointer(to=viewport).unsafe_origin_cast[MutAnyOrigin](),
    )

    # Flip-model swap chains UNBIND the render target at Present -- rebinding
    # once before the loop leaves every alternate frame drawing into nothing,
    # which shows as hard flicker between the image and undefined buffer
    # contents. The binding must be reissued every frame.
    var set_targets = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            Pointer[Int, MutAnyOrigin],
            Int,
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "OMSetRenderTargets",
    ](context)

    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int, Int, UInt32
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "VSSetShader",
    ](context)(context, vs_addr, Int(0), UInt32(0))

    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int, Int, UInt32
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "PSSetShader",
    ](context)(context, ps_addr, Int(0), UInt32(0))

    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            UInt32,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "PSSetConstantBuffers",
    ](context)(
        context,
        UInt32(0),
        UInt32(1),
        Pointer(to=cbuf_addr).unsafe_origin_cast[MutAnyOrigin](),
    )

    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], UInt32
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "IASetPrimitiveTopology",
    ](context)(context, UInt32(4))

    var update = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            UInt32,
            Int,
            Pointer[Float32, MutAnyOrigin],
            UInt32,
            UInt32,
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "UpdateSubresource",
    ](context)
    var draw = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], UInt32, UInt32
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "Draw",
    ](context)
    var present = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], UInt32, UInt32
        ) thin abi("C") -> c_int,
        "IDXGISwapChain",
        "Present",
    ](swapchain)

    # -- the real message loop: run until the window is closed ---------------
    print("running until the window closes")
    var params = List[Float32](length=4, fill=0.0)
    var msg = MSG()
    var frames = 0
    var running = True

    while running:
        while PeekMessageW(
            Pointer(to=msg), Int(0), UInt32(0), UInt32(0), UInt32(1)
        ) != 0:
            if msg.message == WM_QUIT:
                running = False
            else:
                _ = DispatchMessageW(Pointer(to=msg))
        if not running:
            break

        # c rides just inside the cardioid boundary, where the sets are most
        # dramatic: theta at ~0.35 rad/s of locked-60 time.
        var theta = Float32(frames) * (0.35 / 60.0)
        var scale = Float32(0.985)
        params[0] = scale * (0.5 * cos(theta) - 0.25 * cos(2.0 * theta))
        params[1] = scale * (0.5 * sin(theta) - 0.25 * sin(2.0 * theta))
        params[2] = Float32(WIDTH) / Float32(HEIGHT)
        params[3] = theta

        update(
            context,
            cbuf_addr,
            UInt32(0),
            Int(0),
            params.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            UInt32(0),
            UInt32(0),
        )
        set_targets(
            context,
            UInt32(1),
            Pointer(to=rtv_addr).unsafe_origin_cast[MutAnyOrigin](),
            Int(0),
        )
        draw(context, UInt32(3), UInt32(0))
        var phr = present(swapchain, UInt32(interval), UInt32(0))
        if phr != 0:
            raise Error("Present failed, hr = " + String(phr))
        frames += 1

    print("window closed after", frames, "frames (", frames // 60, "s )")
