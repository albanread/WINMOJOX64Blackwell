# ===----------------------------------------------------------------------=== #
# Mandelbrot on the Adreno X1-45, in a window, zooming.
#
#     ./examples/win32/build.sh adreno_mandelbrot --target-accelerator adreno-x1
#     ./bazel-bin/examples/win32/adreno_mandelbrot.exe
#
# The Julia demo was honest about cheating: the picture came out of a pixel
# shader, so the GPU was doing the work but Mojo was only describing it in
# HLSL. This is the other way round. Every pixel is computed by a Mojo kernel
# compiled to SPIR-V and executed on the Adreno through OpenCL; Direct3D is
# reduced to a texture upload and a fullscreen triangle, and the only HLSL
# left is a colour ramp.
#
# saxpy proved the pipeline but almost nothing about the compiler: no branch,
# no loop, every work-item identical. Mandelbrot is the opposite shape -- a
# data-dependent loop whose trip count runs from 1 to MAX_ITER per work-item,
# which is where work-items in a wavefront diverge and where SPIR-V's
# structured control flow has to hold up.
#
# Before the window opens the same computation runs on the CPU and the two are
# compared. A picture that looks right is not evidence: a Mandelbrot set is
# recognisable long before it is correct.
# ===----------------------------------------------------------------------=== #

from max.gpu.host import DeviceContext
from std.ffi import c_int, OwnedDLHandle
from std.gpu.primitives import block_dim, block_idx, thread_idx
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
from std.windows import performance_counter, performance_frequency


comptime WIDTH = 960
comptime HEIGHT = 720
comptime PIXELS = WIDTH * HEIGHT
comptime MAX_ITER = 512
comptime BLOCK = 64


# ===----------------------------------------------------------------------=== #
# The kernel. This is the whole point of the demo.
# ===----------------------------------------------------------------------=== #


def mandelbrot_kernel(
    escape: Pointer[Float32, MutAnyOrigin],
    center_x: Float32,
    center_y: Float32,
    scale: Float32,
):
    var index = block_idx.x * block_dim.x + thread_idx.x
    if index < PIXELS:
        var px = index % WIDTH
        var py = index // WIDTH
        var cx = center_x + (Float32(px) - Float32(WIDTH) * 0.5) * scale
        var cy = center_y + (Float32(py) - Float32(HEIGHT) * 0.5) * scale

        # One loop exit, not a `break` inside the body: SPIR-V wants
        # structured control flow, and a single condition is the shape the
        # backend structurizes without inventing a merge block.
        var zx = Float32(0)
        var zy = Float32(0)
        var n = 0
        while n < MAX_ITER and zx * zx + zy * zy <= Float32(4):
            var next_zx = zx * zx - zy * zy + cx
            zy = Float32(2) * zx * zy + cy
            zx = next_zx
            n += 1

        escape.unsafe_offset(index)[] = Float32(n)


def mandelbrot_host(
    escape: Pointer[Float32, MutAnyOrigin],
    center_x: Float32,
    center_y: Float32,
    scale: Float32,
):
    """The identical arithmetic on the CPU.

    Deliberately spelled the same way in the same order with the same Float32
    rounding at every step: the comparison only means something if the CPU is
    doing the identical sequence.

    Args:
        escape: Destination for the per-pixel escape counts.
        center_x: Real coordinate of the view's centre.
        center_y: Imaginary coordinate of the view's centre.
        scale: Complex-plane units per pixel.
    """
    for index in range(PIXELS):
        var px = index % WIDTH
        var py = index // WIDTH
        var cx = center_x + (Float32(px) - Float32(WIDTH) * 0.5) * scale
        var cy = center_y + (Float32(py) - Float32(HEIGHT) * 0.5) * scale

        var zx = Float32(0)
        var zy = Float32(0)
        var n = 0
        while n < MAX_ITER and zx * zx + zy * zy <= Float32(4):
            var next_zx = zx * zx - zy * zy + cx
            zy = Float32(2) * zx * zy + cy
            zx = next_zx
            n += 1

        escape.unsafe_offset(index)[] = Float32(n)


# ===----------------------------------------------------------------------=== #
# Win32 / Direct3D 11 scaffolding, lifted from d3djulia.mojo.
# ===----------------------------------------------------------------------=== #


@fieldwise_init
struct WNDCLASSEXW(Copyable, Defaultable, Movable):
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
struct DXGI_SWAP_CHAIN_DESC(Copyable, Defaultable, Movable):
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
    var Windowed: c_int
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
struct D3D11_TEXTURE2D_DESC(Copyable, Defaultable, Movable):
    """The texture the Adreno's output lands in. Layout checked against winkb.
    """

    var Width: UInt32
    var Height: UInt32
    var MipLevels: UInt32
    var ArraySize: UInt32
    var Format: UInt32
    var SampleCount: UInt32
    var SampleQuality: UInt32
    var Usage: UInt32
    var BindFlags: UInt32
    var CPUAccessFlags: UInt32
    var MiscFlags: UInt32

    def __init__(out self):
        self.Width = 0
        self.Height = 0
        self.MipLevels = 0
        self.ArraySize = 0
        self.Format = 0
        self.SampleCount = 0
        self.SampleQuality = 0
        self.Usage = 0
        self.BindFlags = 0
        self.CPUAccessFlags = 0
        self.MiscFlags = 0


@fieldwise_init
struct D3D11_VIEWPORT(Copyable, Defaultable, Movable):
    var TopLeftX: Float32
    var TopLeftY: Float32
    var Width: Float32
    var Height: Float32
    var MinDepth: Float32
    var MaxDepth: Float32

    def __init__(out self):
        self.TopLeftX = 0
        self.TopLeftY = 0
        self.Width = 0
        self.Height = 0
        self.MinDepth = 0
        self.MaxDepth = 0


@fieldwise_init
struct MSG(Copyable, Defaultable, Movable):
    var hwnd: Int
    var message: UInt32
    var wParam: Int
    var lParam: Int
    var time: UInt32
    var ptx: Int32
    var pty: Int32
    var private: UInt32

    def __init__(out self):
        self.hwnd = 0
        self.message = 0
        self.wParam = 0
        self.lParam = 0
        self.time = 0
        self.ptx = 0
        self.pty = 0
        self.private = 0


def wide(s: StaticString) -> List[UInt16]:
    var out = List[UInt16]()
    for byte in s.as_bytes():
        out.append(UInt16(byte))
    out.append(0)
    return out^


def cstr(s: StaticString) -> List[UInt8]:
    var out = List[UInt8]()
    for byte in s.as_bytes():
        out.append(byte)
    out.append(0)
    return out^


comptime WM_DESTROY: UInt32 = 0x0002
comptime WM_CLOSE: UInt32 = 0x0010
comptime WM_QUIT: UInt32 = 0x0012
comptime WM_ERASEBKGND: UInt32 = 0x0014
comptime WM_KEYDOWN: UInt32 = 0x0100

comptime WndProcType = def (Int, UInt32, Int, Int) thin abi("C") -> Int


@export("mojo_wndproc")
def mojo_wndproc(hwnd: Int, message: UInt32, wparam: Int, lparam: Int) abi(
    "C"
) -> Int:
    if message == WM_DESTROY:
        try:
            _ = Win32Module("user32.dll").function[
                def (c_int) thin abi("C") -> NoneType
            ]("PostQuitMessage")(c_int(0))
        except:
            pass
        return 0
    if message == WM_KEYDOWN and wparam == 27:  # Escape
        try:
            _ = Win32Module("user32.dll").function[
                def (Int, UInt32, Int, Int) thin abi("C") -> Int
            ]("PostMessageW")(hwnd, WM_CLOSE, Int(0), Int(0))
        except:
            pass
        return 0
    # Never erase: the whole client area is redrawn every frame, and letting
    # Windows paint the background first is what makes it flicker.
    if message == WM_ERASEBKGND:
        return 1
    try:
        return Win32Module("user32.dll").function[
            def (Int, UInt32, Int, Int) thin abi("C") -> Int
        ]("DefWindowProcW")(hwnd, message, wparam, lparam)
    except:
        return 0


# The only shading left: escape count in, colour out. The set itself is
# computed on the Adreno; this just decides what it looks like.
comptime HLSL: StaticString = """
Texture2D<float> escapes : register(t0);

struct VSOut { float4 pos : SV_Position; };

VSOut vsmain(uint id : SV_VertexID) {
    VSOut o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    return o;
}

cbuffer Params : register(b0) { float4 p; };  // x: max_iter  y: phase

float4 psmain(VSOut i) : SV_Target {
    float n = escapes.Load(int3((int)i.pos.x, (int)i.pos.y, 0));
    if (n >= p.x)
        return float4(0.02, 0.01, 0.05, 1.0);
    float t = n / 64.0;
    float3 col = 0.5 + 0.5 * cos(6.28318 * (t + p.y
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
    compile: def (
        Int, Int, Int, Int, Int, Int, Int, UInt32, UInt32,
        Pointer[Int, MutAnyOrigin],
        Pointer[Int, MutAnyOrigin],
    ) thin abi("C") -> Int32,
    source: StaticString,
    entry: StaticString,
    profile: StaticString,
) raises -> ComPtr[StaticString("ID3DBlob")]:
    """Compiles one HLSL entry point at run time.

    Args:
        compile: `D3DCompile`, already resolved.
        source: The HLSL text.
        entry: The entry point's name.
        profile: The shader profile, e.g. "ps_5_0".

    Returns:
        The compiled bytecode blob.

    Raises:
        If compilation fails; the message is the compiler's own.
    """
    var src = cstr(source)
    var entry_name = cstr(entry)
    var target = cstr(profile)
    var code_addr: Int = 0
    var errors_addr: Int = 0

    var hr = compile(
        Int(src.unsafe_ptr()),
        len(src) - 1,
        Int(0),
        Int(0),
        Int(0),
        Int(entry_name.unsafe_ptr()),
        Int(target.unsafe_ptr()),
        UInt32(0),
        UInt32(0),
        Pointer(to=code_addr).unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=errors_addr).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr != 0:
        var detail = String("(no message)")
        if errors_addr != 0:
            detail = blob_text(ComPtr[StaticString("ID3DBlob")](adopt=errors_addr))
        raise Error("D3DCompile(" + String(entry) + ") failed: " + detail)
    return ComPtr[StaticString("ID3DBlob")](adopt=code_addr)


def display_refresh_hz(user32: OwnedDLHandle) raises -> Int:
    """The primary display's refresh rate, for the frame pacing.

    Args:
        user32: An open handle to user32.dll.

    Returns:
        The refresh rate in hertz, or 60 if it cannot be read.

    Raises:
        If the settings query cannot be made at all.
    """
    comptime DM_BYTES = winkb_struct_size["DEVMODEW"]()
    comptime DM_SIZE_AT = winkb_field_offset["DEVMODEW", "dmSize"]()
    comptime FREQ_AT = winkb_field_offset["DEVMODEW", "dmDisplayFrequency"]()

    var settings = List[UInt8](length=DM_BYTES, fill=0)
    var base = settings.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    base.unsafe_offset(DM_SIZE_AT).unsafe_bitcast[UInt16]()[] = UInt16(DM_BYTES)

    var EnumDisplaySettingsW = user32.get_function[c_int](
        "EnumDisplaySettingsW"
    )
    # ENUM_CURRENT_SETTINGS is (DWORD)-1.
    if EnumDisplaySettingsW(Int(0), UInt32(0xFFFFFFFF), base) == 0:
        return 60
    var hz = Int(base.unsafe_offset(FREQ_AT).unsafe_bitcast[UInt32]()[])
    return hz if hz > 1 else 60


# ===----------------------------------------------------------------------=== #


def main() raises:
    comptime assert (
        size_of[D3D11_TEXTURE2D_DESC]()
        == winkb_struct_size["D3D11_TEXTURE2D_DESC"]()
    ), "D3D11_TEXTURE2D_DESC does not match Windows"
    comptime assert (
        size_of[D3D11_VIEWPORT]() == winkb_struct_size["D3D11_VIEWPORT"]()
    ), "D3D11_VIEWPORT does not match Windows"
    comptime assert (
        size_of[DXGI_SWAP_CHAIN_DESC]()
        == winkb_struct_size["DXGI_SWAP_CHAIN_DESC"]()
    ), "DXGI_SWAP_CHAIN_DESC does not match Windows"

    # ---- the accelerator ------------------------------------------------
    var ctx = DeviceContext(api="adreno")
    var hz_counter = performance_frequency()

    var center_x = Float32(-0.743643887037151)
    var center_y = Float32(0.13182590420533)
    var scale = Float32(3.2) / Float32(WIDTH)

    var gpu_host = ctx.enqueue_create_host_buffer[DType.float32](PIXELS)
    var cpu_host = ctx.enqueue_create_host_buffer[DType.float32](PIXELS)
    ctx.synchronize()
    var gpu_dev = ctx.enqueue_create_buffer[DType.float32](PIXELS)

    comptime GRID = (PIXELS + BLOCK - 1) // BLOCK

    # Warm up: the first launch pays for the program build and kernel
    # creation, which is not what the timing below is about.
    ctx.enqueue_function[mandelbrot_kernel](
        gpu_dev, center_x, center_y, scale, grid_dim=GRID, block_dim=BLOCK
    )
    gpu_host.enqueue_copy_from(gpu_dev)
    ctx.synchronize()

    var gpu_start = performance_counter()
    ctx.enqueue_function[mandelbrot_kernel](
        gpu_dev, center_x, center_y, scale, grid_dim=GRID, block_dim=BLOCK
    )
    gpu_host.enqueue_copy_from(gpu_dev)
    ctx.synchronize()
    var gpu_us = (performance_counter() - gpu_start) * 1000000 // hz_counter

    var cpu_start = performance_counter()
    mandelbrot_host(
        cpu_host.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        center_x,
        center_y,
        scale,
    )
    var cpu_us = (performance_counter() - cpu_start) * 1000000 // hz_counter

    # ---- do the two agree? ----------------------------------------------
    # Not exactly, and it would be wrong to demand it. Escape-time is chaotic
    # exactly where the count is high: near the set, a one-ulp difference
    # amplifies every iteration, so a pixel the CPU holds to 512 can honestly
    # escape at 450 on hardware with different FMA contraction. Measured here:
    # of 691,200 pixels, ~1,700 differ, and every one is either high-count
    # (chaotic by construction) or a +/-1 flip at the escape radius.
    #
    # What a REAL codegen bug looks like is different: wrong arithmetic is
    # wrong everywhere, including the low-count far field where the count is
    # locally flat and utterly insensitive. So the check demands exactness
    # only there: pixels whose CPU count is low (< 256 of 512), whose
    # neighbourhood is flat (all neighbours within 1), and whose delta
    # exceeds the +/-1 threshold flip. Those must be zero.
    var cpu_ptr = cpu_host.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    var differ = 0
    var interior_differ = 0
    var worst = 0
    var interior_worst = 0
    var total_iters = 0
    for index in range(PIXELS):
        var g = Int(gpu_host[index])
        var c = Int(cpu_host[index])
        total_iters += c
        if g == c:
            continue
        differ += 1
        if abs(g - c) > worst:
            worst = abs(g - c)

        var px = index % WIDTH
        var py = index // WIDTH
        if abs(g - c) <= 1 or c >= 256:
            continue  # threshold flips and the chaotic near-set region
        var smooth = True
        if px > 0 and abs(Int(cpu_ptr.unsafe_offset(index - 1)[]) - c) > 1:
            smooth = False
        if px < WIDTH - 1 and abs(Int(cpu_ptr.unsafe_offset(index + 1)[]) - c) > 1:
            smooth = False
        if py > 0 and abs(Int(cpu_ptr.unsafe_offset(index - WIDTH)[]) - c) > 1:
            smooth = False
        if py < HEIGHT - 1 and abs(Int(cpu_ptr.unsafe_offset(index + WIDTH)[]) - c) > 1:
            smooth = False
        if smooth:
            interior_differ += 1
            if abs(g - c) > interior_worst:
                interior_worst = abs(g - c)
            if interior_differ <= 6:
                print(
                    "    interior mismatch at",
                    px,
                    ",",
                    py,
                    ": gpu",
                    g,
                    "cpu",
                    c,
                )

    print("grid          ", WIDTH, "x", HEIGHT, " max_iter", MAX_ITER)
    print("work          ", total_iters // 1000000, "M iterations,", total_iters // PIXELS, "mean per pixel")
    print("Adreno X1-45  ", gpu_us // 1000, "ms per frame (compute + readback)")
    print("Oryon, 1 core ", cpu_us // 1000, "ms")
    if gpu_us > 0:
        print("speedup       ", cpu_us * 10 // gpu_us, "/ 10")
    print(
        "agreement     ",
        differ,
        "of",
        PIXELS,
        "pixels differ (worst",
        worst,
        "iterations)",
    )
    print(
        "  of those,   ",
        interior_differ,
        "are low-count, locally-flat, delta>1 -- a codegen bug if nonzero",
    )
    if interior_differ != 0:
        raise Error("GPU and CPU disagree away from the boundary")

    # ---- the window -----------------------------------------------------
    var user32 = OwnedDLHandle("user32.dll")
    var kernel32 = OwnedDLHandle("kernel32.dll")
    var d3d11 = OwnedDLHandle("d3d11.dll")

    var GetModuleHandleW = kernel32.get_function[Int]("GetModuleHandleW")
    var RegisterClassExW = user32.get_function[UInt16]("RegisterClassExW")
    var CreateWindowExW = user32.get_function[Int]("CreateWindowExW")
    var ShowWindow = user32.get_function[c_int]("ShowWindow")
    var PeekMessageW = user32.get_function[c_int]("PeekMessageW")
    var DispatchMessageW = user32.get_function[Int]("DispatchMessageW")
    var create_device = d3d11.get_function[c_int](
        "D3D11CreateDeviceAndSwapChain"
    )

    var compiler_dll = Win32Module("d3dcompiler_47.dll")
    var D3DCompile = compiler_dll.function[
        def (
            Int, Int, Int, Int, Int, Int, Int, UInt32, UInt32,
            Pointer[Int, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> Int32
    ]("D3DCompile")

    var hz = display_refresh_hz(user32)
    var interval = (hz + 30) // 60
    if interval < 1:
        interval = 1

    var hInstance = GetModuleHandleW(Int(0))
    var class_name = wide("MojoMandelbrotWindow")
    var title = wide(
        "Mandelbrot - Mojo kernel on the Adreno X1-45 - Esc to close"
    )
    var proc: WndProcType = mojo_wndproc

    var wc = WNDCLASSEXW()
    wc.cbSize = UInt32(size_of[WNDCLASSEXW]())
    wc.style = 0x0003
    wc.lpfnWndProc = Int(_fn_ptr_as_opaque(proc))
    wc.hInstance = hInstance
    wc.lpszClassName = Int(class_name.unsafe_ptr())
    if RegisterClassExW(Pointer(to=wc)) == 0:
        raise Error("RegisterClassExW failed")

    var hwnd = CreateWindowExW(
        UInt32(0),
        class_name.unsafe_ptr(),
        title.unsafe_ptr(),
        UInt32(0x00CF0000),
        c_int(100),
        c_int(100),
        c_int(WIDTH + 16),
        c_int(HEIGHT + 39),
        Int(0),
        Int(0),
        hInstance,
        Int(0),
    )
    if hwnd == 0:
        raise Error("CreateWindowExW failed")
    _ = ShowWindow(hwnd, c_int(5))

    var desc = DXGI_SWAP_CHAIN_DESC()
    desc.Width = UInt32(WIDTH)
    desc.Height = UInt32(HEIGHT)
    desc.RefreshRateNumerator = 60
    desc.RefreshRateDenominator = 1
    desc.Format = 87  # B8G8R8A8_UNORM
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
    if (
        create_device(
            Int(0), UInt32(1), Int(0), UInt32(0), Int(0), UInt32(0), UInt32(7),
            Pointer(to=desc),
            Pointer(to=swapchain_addr),
            Pointer(to=device_addr),
            Pointer(to=level),
            Pointer(to=context_addr),
        )
        != 0
        or swapchain_addr == 0
    ):
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

    var backbuf_addr: Int = 0
    var iid_texture = _guid_bytes(winkb_interface_iid["ID3D11Texture2D"]())
    if (
        com_method_of[
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
        != 0
    ):
        raise Error("GetBuffer failed")
    var backbuffer = ComPtr[StaticString("ID3D11Texture2D")](adopt=backbuf_addr)

    var rtv_addr: Int = 0
    if (
        com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], Int, Int,
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
        != 0
    ):
        raise Error("CreateRenderTargetView failed")

    # ---- the texture the Adreno's output lands in ------------------------
    # R32_FLOAT holds the escape count as computed, so nothing on the CPU
    # touches the data between the device readback and the upload -- the
    # colour mapping happens in the pixel shader, where it is free.
    var tex_desc = D3D11_TEXTURE2D_DESC()
    tex_desc.Width = UInt32(WIDTH)
    tex_desc.Height = UInt32(HEIGHT)
    tex_desc.MipLevels = 1
    tex_desc.ArraySize = 1
    tex_desc.Format = 41  # R32_FLOAT
    tex_desc.SampleCount = 1
    tex_desc.Usage = 0  # DEFAULT
    tex_desc.BindFlags = 8  # SHADER_RESOURCE

    var tex_addr: Int = 0
    if (
        com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin],
                Pointer[D3D11_TEXTURE2D_DESC, MutAnyOrigin],
                Int,
                Pointer[Int, MutAnyOrigin],
            ) thin abi("C") -> c_int,
            "ID3D11Device",
            "CreateTexture2D",
        ](device)(
            device,
            Pointer(to=tex_desc).unsafe_origin_cast[MutAnyOrigin](),
            Int(0),
            Pointer(to=tex_addr).unsafe_origin_cast[MutAnyOrigin](),
        )
        != 0
    ):
        raise Error("CreateTexture2D failed")
    var texture = ComPtr[StaticString("ID3D11Texture2D")](adopt=tex_addr)

    var srv_addr: Int = 0
    if (
        com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], Int, Int,
                Pointer[Int, MutAnyOrigin],
            ) thin abi("C") -> c_int,
            "ID3D11Device",
            "CreateShaderResourceView",
        ](device)(
            device,
            tex_addr,
            Int(0),  # NULL desc: the whole resource, its own format
            Pointer(to=srv_addr).unsafe_origin_cast[MutAnyOrigin](),
        )
        != 0
    ):
        raise Error("CreateShaderResourceView failed")

    # ---- shaders and constant buffer ------------------------------------
    var vs_blob = compile_shader(D3DCompile, HLSL, "vsmain", "vs_5_0")
    var ps_blob = compile_shader(D3DCompile, HLSL, "psmain", "ps_5_0")

    var vs_addr: Int = 0
    if (
        com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], Int, Int, Int,
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
        != 0
    ):
        raise Error("CreateVertexShader failed")
    var vshader = ComPtr[StaticString("ID3D11VertexShader")](adopt=vs_addr)

    var ps_addr: Int = 0
    if (
        com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], Int, Int, Int,
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
        != 0
    ):
        raise Error("CreatePixelShader failed")
    var pshader = ComPtr[StaticString("ID3D11PixelShader")](adopt=ps_addr)

    var cb_desc = List[UInt8](length=winkb_struct_size["D3D11_BUFFER_DESC"](), fill=0)
    var cb_base = cb_desc.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    cb_base.unsafe_offset(
        winkb_field_offset["D3D11_BUFFER_DESC", "ByteWidth"]()
    ).unsafe_bitcast[UInt32]()[] = UInt32(16)
    cb_base.unsafe_offset(
        winkb_field_offset["D3D11_BUFFER_DESC", "BindFlags"]()
    ).unsafe_bitcast[UInt32]()[] = UInt32(4)  # CONSTANT_BUFFER

    var cbuf_addr: Int = 0
    if (
        com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin],
                Pointer[UInt8, MutAnyOrigin],
                Int,
                Pointer[Int, MutAnyOrigin],
            ) thin abi("C") -> c_int,
            "ID3D11Device",
            "CreateBuffer",
        ](device)(
            device,
            cb_base,
            Int(0),
            Pointer(to=cbuf_addr).unsafe_origin_cast[MutAnyOrigin](),
        )
        != 0
    ):
        raise Error("CreateBuffer failed")
    var cbuffer = ComPtr[StaticString("ID3D11Buffer")](adopt=cbuf_addr)

    # ---- fixed pipeline state -------------------------------------------
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
        context, UInt32(1), Pointer(to=viewport).unsafe_origin_cast[MutAnyOrigin]()
    )

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
            OpaquePointer[MutUntrackedOrigin], UInt32, UInt32,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "PSSetShaderResources",
    ](context)(
        context,
        UInt32(0),
        UInt32(1),
        Pointer(to=srv_addr).unsafe_origin_cast[MutAnyOrigin](),
    )

    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], UInt32, UInt32,
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
        def (OpaquePointer[MutUntrackedOrigin], UInt32) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "IASetPrimitiveTopology",
    ](context)(context, UInt32(4))

    var update = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            UInt32,
            Int,
            Pointer[UInt8, MutAnyOrigin],
            UInt32,
            UInt32,
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "UpdateSubresource",
    ](context)
    var set_targets = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], UInt32,
            Pointer[Int, MutAnyOrigin], Int,
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "OMSetRenderTargets",
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

    # ---- the loop --------------------------------------------------------
    print()
    print("window open; the Adreno recomputes every frame. Esc or close to stop.")

    var params = List[Float32](length=4, fill=0.0)
    var msg = MSG()
    var frames = 0
    var running = True
    var zoom = Float32(1.0)
    var loop_start = performance_counter()

    while running:
        while (
            PeekMessageW(Pointer(to=msg), Int(0), UInt32(0), UInt32(0), UInt32(1))
            != 0
        ):
            if msg.message == WM_QUIT:
                running = False
            else:
                _ = DispatchMessageW(Pointer(to=msg))
        if not running:
            break

        # Zoom in towards the seahorse valley, then snap back and repeat --
        # far enough in that Float32 starts to show its grain, which is
        # itself worth seeing.
        zoom *= Float32(1.012)
        if zoom > Float32(20000):
            zoom = Float32(1.0)
        ctx.enqueue_function[mandelbrot_kernel](
            gpu_dev,
            center_x,
            center_y,
            scale / zoom,
            grid_dim=GRID,
            block_dim=BLOCK,
        )
        gpu_host.enqueue_copy_from(gpu_dev)
        ctx.synchronize()

        update(
            context,
            tex_addr,
            UInt32(0),
            Int(0),
            gpu_host.unsafe_ptr()
            .unsafe_bitcast[UInt8]()
            .unsafe_origin_cast[MutAnyOrigin](),
            UInt32(WIDTH * 4),
            UInt32(0),
        )

        params[0] = Float32(MAX_ITER)
        params[1] = Float32(frames) * 0.004
        update(
            context,
            cbuf_addr,
            UInt32(0),
            Int(0),
            params.unsafe_ptr()
            .unsafe_bitcast[UInt8]()
            .unsafe_origin_cast[MutAnyOrigin](),
            UInt32(0),
            UInt32(0),
        )

        # Flip-model Present unbinds the render target, so rebind every frame
        # or every other frame draws into nothing.
        set_targets(
            context,
            UInt32(1),
            Pointer(to=rtv_addr).unsafe_origin_cast[MutAnyOrigin](),
            Int(0),
        )
        draw(context, UInt32(3), UInt32(0))
        if present(swapchain, UInt32(interval), UInt32(0)) != 0:
            raise Error("Present failed")
        frames += 1

    var elapsed_us = (performance_counter() - loop_start) * 1000000 // hz_counter
    print(
        "closed after",
        frames,
        "frames in",
        elapsed_us // 1000,
        "ms =",
        frames * 1000000 // elapsed_us if elapsed_us > 0 else 0,
        "fps, every frame computed on the Adreno",
    )
