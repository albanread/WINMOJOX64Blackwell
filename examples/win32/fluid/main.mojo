# ===----------------------------------------------------------------------=== #
# Fluid -- a native Windows app written entirely in Mojo.
#
# Stable Fluids (Jos Stam, SIGGRAPH 1999). Drag the mouse and coloured dye
# swirls through a velocity field that is advected along itself and then made
# divergence-free by a Jacobi pressure solve. Every kernel is Mojo, compiled to
# PTX and run on the NVIDIA GPU through the CUDA driver; the finished BGRA
# frame is handed to GDI. There is no shader anywhere in the pipeline and no
# hand-declared Win32: every entry point, constant and structure size below
# comes out of the windows_api.db metadata.
#
# The solver is `solver.mojo`, and `fluid_smoke.mojo` runs THE SAME kernels
# headless and checks them -- mass conservation to under 1%, post-projection
# divergence inside +/-0.05, a rendered frame that is not black. Run that first
# if this ever looks wrong; it separates "the physics broke" from "the window
# broke", which from a black window are indistinguishable.
#
# WHY THIS EXAMPLE EXISTS, beyond being nice to look at: nvidia_mandelbrot is
# one dispatch per frame, so it measures the kernel and says nothing at all
# about launch cost. A fluids step is 37 dependent dispatches -- advect the
# velocity along itself, take its divergence, thirty Jacobi sweeps on the
# pressure, subtract its gradient, then carry three dye channels on the
# corrected field. That makes per-dispatch overhead the dominant term, and it
# is the first example here that can see it. Measured on the T1000, warm: the
# solver's own step is 9.4 ms and a whole frame -- 44 dispatches, the readback
# and the blit -- is 12.1 ms, which is 82 fps.
#
#     ./build/fluid.exe                    # drag to paint
#     FLUID_AUTOSHOT=90 ./build/fluid.exe  # run 90 frames, prove the pixels
#                                          # landed, save fluid-0.png, exit
#
# [space] pause  [c] clear  [r] rain  [s] save a shot  [Esc] quit
# ===----------------------------------------------------------------------=== #

from examples.win32.fluid.png import write_png
from examples.win32.fluid.solver import (
    BLOCK,
    DYE_FADE,
    H,
    N,
    PIXELS,
    PIX_GRID,
    VEL_FADE,
    W,
    WIN_H,
    WIN_W,
    advect_dye,
    dispatches_per_step,
    fluid_step,
    hue_rgb,
    render_kernel,
    splat,
)
from max.gpu.host import DeviceContext
from std.ffi import c_int
from std.memory import Pointer, alloc
from std.python._cpython import _fn_ptr_as_opaque
from std.sys.info import size_of
from std.sys._com import com_addr
from std.sys._win32 import Win32Module
from std.sys._winkb import (
    winkb_constant,
    winkb_function_dll,
    winkb_struct_size,
)
from std.windows import performance_counter, performance_frequency


def win32[Sig: TrivialRegisterPassable, name: StaticString]() raises -> Sig:
    """A Win32 entry point, typed, from whichever DLL the metadata names.

    Parameters:
        Sig: The full thin C-ABI signature. Spell every argument -- an
            under-declared signature compiles and then corrupts the call.
        name: The exported function, e.g. "CreateWindowExW".

    Returns:
        The entry point, callable.

    Raises:
        If the module or the export cannot be found.
    """
    return Win32Module(String(winkb_function_dll[name]())).function[Sig](
        String(name)
    )


# ===----------------------------------------------------------------------=== #
# Windows structures. NOT TrivialRegisterPassable: claiming that of a big
# struct does not fail to compile, it silently writes fields to the wrong
# places. Every layout is asserted against the metadata in `main`.
# ===----------------------------------------------------------------------=== #


@fieldwise_init
struct WNDCLASSEXW(Copyable, Defaultable, Movable):
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
struct MSG(Copyable, Defaultable, Movable):
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
struct RECT(Copyable, Defaultable, Movable):
    var left: Int32
    var top: Int32
    var right: Int32
    var bottom: Int32

    def __init__(out self):
        self.left = 0
        self.top = 0
        self.right = 0
        self.bottom = 0


@fieldwise_init
struct BITMAPINFOHEADER(Copyable, Defaultable, Movable):
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


@fieldwise_init
struct Scene(Copyable, Defaultable, Movable):
    """What the window procedure can reach.

    A window procedure is captureless -- Windows calls it, so it cannot close
    over `main`'s locals. This lives on the heap and its address is stored in
    the window's GWLP_USERDATA slot, which is the only channel there is.
    """

    var pixels: Int
    var width: Int
    var height: Int
    var painted: Int

    def __init__(out self):
        self.pixels = 0
        self.width = 0
        self.height = 0
        self.painted = 0


def wide(s: StaticString) -> List[UInt16]:
    """A NUL-terminated UTF-16 buffer for the W-suffixed entry points."""
    var out = List[UInt16]()
    for byte in s.as_bytes():
        out.append(UInt16(Int(byte)))
    out.append(0)
    return out^


def wide_str(s: String) -> List[UInt16]:
    """The same, for a string built at run time. ASCII only, which every
    caller here is."""
    var out = List[UInt16]()
    for byte in s.as_bytes():
        out.append(UInt16(Int(byte)))
    out.append(0)
    return out^


# ===----------------------------------------------------------------------=== #
# Presenting a CPU buffer: one call.
#
# The GPU writes 960x720 BGRA words into pinned host memory and GDI blits them
# straight into the window. No swap chain, no device, no COM, and nothing that
# can report the window occluded and present nothing -- which is what the
# Direct2D path on this machine sometimes does.
# ===----------------------------------------------------------------------=== #


def blit(hdc: Int, scene: Scene, dest_w: Int, dest_h: Int) raises:
    """Push the frame into a device context, scaled to the client rect."""
    var StretchDIBits = win32[
        def (
            Int,  # HDC
            c_int, c_int, c_int, c_int,  # xDest, yDest, DestW, DestH
            c_int, c_int, c_int, c_int,  # xSrc, ySrc, SrcW, SrcH
            Pointer[UInt32, MutAnyOrigin],  # lpBits
            Pointer[BITMAPINFOHEADER, MutAnyOrigin],  # lpbmi
            UInt32,  # iUsage
            UInt32,  # rop
        ) thin abi("C") -> c_int,
        "StretchDIBits",
    ]()

    var bmi = BITMAPINFOHEADER()
    bmi.biSize = UInt32(size_of[BITMAPINFOHEADER]())
    bmi.biWidth = Int32(scene.width)
    # Negative height asks GDI for a TOP-DOWN DIB: row 0 is the top row, which
    # is the order the render kernel writes. A positive height means bottom-up
    # and the fluid arrives upside down.
    bmi.biHeight = Int32(-scene.height)
    bmi.biPlanes = 1
    bmi.biBitCount = 32
    bmi.biCompression = UInt32(winkb_constant["BI_RGB"]())

    var bits = Pointer[UInt32, MutAnyOrigin](unsafe_from_address=scene.pixels)
    _ = StretchDIBits(
        hdc,
        c_int(0), c_int(0), c_int(dest_w), c_int(dest_h),
        c_int(0), c_int(0), c_int(scene.width), c_int(scene.height),
        bits,
        com_addr(bmi),
        UInt32(winkb_constant["DIB_RGB_COLORS"]()),
        UInt32(winkb_constant["SRCCOPY"]()),
    )
    _ = bmi


comptime WndProcType = def (Int, UInt32, Int, Int) thin abi("C") -> Int


@export("fluid_wndproc")
def fluid_wndproc(
    hwnd: Int, message: UInt32, wparam: Int, lparam: Int
) abi("C") -> Int:
    # Windows calls this, so it must never raise -- unwinding through a
    # Windows frame is undefined. Everything is inside the try and the except
    # returns a value. Win32Module hits a process-lifetime cache, so resolving
    # entry points here is a map lookup, not a LoadLibrary.
    try:
        # Refuse the background erase: the whole client area is redrawn every
        # frame, and letting GDI clear it first is what makes it flicker.
        if message == UInt32(winkb_constant["WM_ERASEBKGND"]()):
            return 1

        if message == UInt32(winkb_constant["WM_PAINT"]()):
            var GetWindowLongPtrW = win32[
                def (Int, c_int) thin abi("C") -> Int, "GetWindowLongPtrW"
            ]()
            var stored = GetWindowLongPtrW(
                hwnd, c_int(winkb_constant["GWLP_USERDATA"]())
            )
            var BeginPaint = win32[
                def (Int, Pointer[UInt8, MutAnyOrigin]) thin abi("C") -> Int,
                "BeginPaint",
            ]()
            var EndPaint = win32[
                def (Int, Pointer[UInt8, MutAnyOrigin]) thin abi("C") -> c_int,
                "EndPaint",
            ]()
            # PAINTSTRUCT is never declared -- only sized, from the metadata.
            var ps = List[UInt8](
                length = winkb_struct_size["PAINTSTRUCT"](), fill=0
            )
            var ps_ptr = ps.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
            var hdc = BeginPaint(hwnd, ps_ptr)
            if stored != 0 and hdc != 0:
                var scene = Pointer[Scene, MutAnyOrigin](
                    unsafe_from_address=stored
                )
                if scene[].pixels != 0:
                    var GetClientRect = win32[
                        def (
                            Int, Pointer[RECT, MutAnyOrigin]
                        ) thin abi("C") -> c_int,
                        "GetClientRect",
                    ]()
                    var rc = RECT()
                    _ = GetClientRect(hwnd, com_addr(rc))
                    blit(
                        hdc,
                        scene[],
                        Int(rc.right - rc.left),
                        Int(rc.bottom - rc.top),
                    )
                    scene[].painted += 1
            _ = EndPaint(hwnd, ps_ptr)
            _ = ps
            return 0

        if message == UInt32(winkb_constant["WM_CLOSE"]()):
            var DestroyWindow = win32[
                def (Int) thin abi("C") -> c_int, "DestroyWindow"
            ]()
            _ = DestroyWindow(hwnd)
            return 0

        if message == UInt32(winkb_constant["WM_DESTROY"]()):
            var PostQuitMessage = win32[
                def (c_int) thin abi("C") -> NoneType, "PostQuitMessage"
            ]()
            _ = PostQuitMessage(c_int(0))
            return 0

        var DefWindowProcW = win32[WndProcType, "DefWindowProcW"]()
        return DefWindowProcW(hwnd, message, wparam, lparam)
    except:
        return 0


# ===----------------------------------------------------------------------=== #
# Proving the pixels landed.
#
# That every call returned S_OK is not evidence that anything is on screen.
# This reads the window's OWN client area back through a DIB section, which is
# the same machinery `blit` uses pointed the other way, and reports what is
# actually there.
# ===----------------------------------------------------------------------=== #


def readback(hwnd: Int) raises -> Int:
    """Print samples of the window's client area. Returns the non-black count.
    """
    var GetClientRect = win32[
        def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
        "GetClientRect",
    ]()
    var GetDC = win32[def (Int) thin abi("C") -> Int, "GetDC"]()
    var ReleaseDC = win32[def (Int, Int) thin abi("C") -> c_int, "ReleaseDC"]()
    var CreateCompatibleDC = win32[
        def (Int) thin abi("C") -> Int, "CreateCompatibleDC"
    ]()
    var CreateDIBSection = win32[
        def (
            Int,  # HDC
            Pointer[BITMAPINFOHEADER, MutAnyOrigin],  # pbmi
            UInt32,  # usage
            Pointer[Int, MutAnyOrigin],  # ppvBits (void**)
            Int,  # hSection
            UInt32,  # offset
        ) thin abi("C") -> Int,
        "CreateDIBSection",
    ]()
    var SelectObject = win32[
        def (Int, Int) thin abi("C") -> Int, "SelectObject"
    ]()
    var BitBlt = win32[
        def (
            Int, c_int, c_int, c_int, c_int, Int, c_int, c_int, UInt32
        ) thin abi("C") -> c_int,
        "BitBlt",
    ]()
    var DeleteObject = win32[def (Int) thin abi("C") -> c_int, "DeleteObject"]()
    var DeleteDC = win32[def (Int) thin abi("C") -> c_int, "DeleteDC"]()

    var rc = RECT()
    _ = GetClientRect(hwnd, com_addr(rc))
    var width = Int(rc.right - rc.left)
    var height = Int(rc.bottom - rc.top)
    if width <= 0 or height <= 0:
        print("  readback: the window has no client area")
        return 0

    var hdc = GetDC(hwnd)
    var mem = CreateCompatibleDC(hdc)
    var bmi = BITMAPINFOHEADER()
    bmi.biSize = UInt32(size_of[BITMAPINFOHEADER]())
    bmi.biWidth = Int32(width)
    bmi.biHeight = Int32(-height)  # top-down again
    bmi.biPlanes = 1
    bmi.biBitCount = 32
    bmi.biCompression = UInt32(winkb_constant["BI_RGB"]())

    var bits_addr: Int = 0
    var dib = CreateDIBSection(
        hdc,
        com_addr(bmi),
        UInt32(winkb_constant["DIB_RGB_COLORS"]()),
        com_addr(bits_addr),
        0,
        UInt32(0),
    )
    var count = 0
    if dib != 0 and bits_addr != 0:
        var old = SelectObject(mem, dib)
        _ = BitBlt(
            mem,
            c_int(0), c_int(0), c_int(width), c_int(height),
            hdc,
            c_int(0), c_int(0),
            UInt32(winkb_constant["SRCCOPY"]()),
        )
        var px = Pointer[UInt32, MutAnyOrigin](unsafe_from_address=bits_addr)
        var brightest = UInt32(0)
        var bright_x = 0
        var bright_y = 0
        var min_x = width
        var max_x = -1
        var min_y = height
        var max_y = -1
        for y in range(height):
            for x in range(width):
                var v = px[unsafe_offset = y * width + x] & UInt32(0xFFFFFF)
                if v == 0:
                    continue
                count += 1
                if x < min_x:
                    min_x = x
                if x > max_x:
                    max_x = x
                if y < min_y:
                    min_y = y
                if y > max_y:
                    max_y = y
                if v > brightest:
                    brightest = v
                    bright_x = x
                    bright_y = y
        print(
            "  readback: client",
            width,
            "x",
            height,
            "-",
            count,
            "non-black pixels",
        )
        if count > 0:
            # Where the dye is, rather than five fixed samples that a rising
            # plume walks straight past.
            print(
                "     brightest",
                hex(Int(brightest)),
                "at",
                bright_x,
                ",",
                bright_y,
            )
            print(
                "     ink spans x",
                min_x,
                "..",
                max_x,
                " y",
                min_y,
                "..",
                max_y,
            )
        _ = SelectObject(mem, old)
        _ = DeleteObject(dib)
    else:
        print("  readback: CreateDIBSection failed")
    _ = DeleteDC(mem)
    _ = ReleaseDC(hwnd, hdc)
    _ = bmi
    return count


def env_int(name: StaticString, fallback: Int) raises -> Int:
    """Read a small non-negative integer out of the environment.

    Through GetEnvironmentVariableW rather than getenv, because this tree's
    rule is that a Windows facility is reached through the metadata.
    """
    var GetEnvironmentVariableW = win32[
        def (
            Pointer[UInt16, MutAnyOrigin],
            Pointer[UInt16, MutAnyOrigin],
            UInt32,
        ) thin abi("C") -> UInt32,
        "GetEnvironmentVariableW",
    ]()
    var wname = wide(name)
    var buffer = List[UInt16](length=32, fill=0)
    var n = GetEnvironmentVariableW(
        wname.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        UInt32(32),
    )
    _ = wname
    if n == 0 or n >= 32:
        return fallback
    var value = 0
    var seen = False
    for i in range(Int(n)):
        var ch = Int(buffer[i])
        if ch < 48 or ch > 57:
            return fallback
        value = value * 10 + (ch - 48)
        seen = True
    _ = buffer
    return value if seen else fallback


# ===----------------------------------------------------------------------=== #


def main() raises:
    comptime assert (
        size_of[WNDCLASSEXW]() == winkb_struct_size["WNDCLASSEXW"]()
    ), "WNDCLASSEXW does not match Windows"
    comptime assert (
        size_of[MSG]() == winkb_struct_size["MSG"]()
    ), "MSG does not match Windows"
    comptime assert (
        size_of[RECT]() == winkb_struct_size["RECT"]()
    ), "RECT does not match Windows"
    comptime assert (
        size_of[BITMAPINFOHEADER]()
        == winkb_struct_size["BITMAPINFOHEADER"]()
    ), "BITMAPINFOHEADER does not match Windows"

    print("Fluid -", W, "x", H, "sim,", WIN_W, "x", WIN_H, "window")

    # ---- the accelerator -------------------------------------------------
    var ctx = DeviceContext(api="cuda")
    # 37 for the step, two per dye channel (advect then copy back), and the
    # render. Counted, because the whole argument for this example is a
    # per-dispatch cost multiplied by this number.
    print("  GPU:", ctx.name(), "-", dispatches_per_step() + 3 * 2 + 1,
          "dispatches per frame")

    var u = ctx.enqueue_create_buffer[DType.float32](N)
    var v = ctx.enqueue_create_buffer[DType.float32](N)
    var u0 = ctx.enqueue_create_buffer[DType.float32](N)
    var v0 = ctx.enqueue_create_buffer[DType.float32](N)
    var dr = ctx.enqueue_create_buffer[DType.float32](N)
    var dg = ctx.enqueue_create_buffer[DType.float32](N)
    var db = ctx.enqueue_create_buffer[DType.float32](N)
    var scratch = ctx.enqueue_create_buffer[DType.float32](N)
    var div = ctx.enqueue_create_buffer[DType.float32](N)
    var pr = ctx.enqueue_create_buffer[DType.float32](N)
    var pr0 = ctx.enqueue_create_buffer[DType.float32](N)
    var frame = ctx.enqueue_create_buffer[DType.uint32](PIXELS)

    # Pinned host memory: the render kernel's output lands here and GDI reads
    # it directly, so nothing on the CPU touches a pixel between the readback
    # and the window.
    var host = ctx.enqueue_create_host_buffer[DType.uint32](PIXELS)
    ctx.synchronize()

    for buf in [u, v, dr, dg, db, pr]:
        ctx.enqueue_memset(buf, Float32(0))
    ctx.synchronize()

    # ---- the window ------------------------------------------------------
    var GetModuleHandleW = win32[
        def (Int) thin abi("C") -> Int, "GetModuleHandleW"
    ]()
    var GetLastError = win32[def () thin abi("C") -> UInt32, "GetLastError"]()
    var LoadCursorW = win32[def (Int, Int) thin abi("C") -> Int, "LoadCursorW"]()
    var RegisterClassExW = win32[
        def (Pointer[WNDCLASSEXW, MutAnyOrigin]) thin abi("C") -> UInt16,
        "RegisterClassExW",
    ]()
    var AdjustWindowRect = win32[
        def (Pointer[RECT, MutAnyOrigin], UInt32, c_int) thin abi("C") -> c_int,
        "AdjustWindowRect",
    ]()
    var CreateWindowExW = win32[
        def (
            UInt32,
            Pointer[UInt16, MutAnyOrigin],
            Pointer[UInt16, MutAnyOrigin],
            UInt32,
            c_int, c_int, c_int, c_int,
            Int, Int, Int, Int,
        ) thin abi("C") -> Int,
        "CreateWindowExW",
    ]()
    var ShowWindow = win32[
        def (Int, c_int) thin abi("C") -> c_int, "ShowWindow"
    ]()
    var UpdateWindow = win32[def (Int) thin abi("C") -> c_int, "UpdateWindow"]()
    var InvalidateRect = win32[
        def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
    ]()
    var SetWindowLongPtrW = win32[
        def (Int, c_int, Int) thin abi("C") -> Int, "SetWindowLongPtrW"
    ]()
    var GetClientRect = win32[
        def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
        "GetClientRect",
    ]()
    var SetWindowTextW = win32[
        def (Int, Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> c_int,
        "SetWindowTextW",
    ]()
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
    var DestroyWindow = win32[def (Int) thin abi("C") -> c_int, "DestroyWindow"]()
    var SetCapture = win32[def (Int) thin abi("C") -> Int, "SetCapture"]()
    var ReleaseCapture = win32[def () thin abi("C") -> c_int, "ReleaseCapture"]()

    var hInstance = GetModuleHandleW(0)
    var class_name = wide("MojoFluidWindow")
    var title = wide("Fluid - Stable Fluids, every kernel a Mojo kernel")
    var proc: WndProcType = fluid_wndproc

    var wc = WNDCLASSEXW()
    wc.cbSize = UInt32(size_of[WNDCLASSEXW]())
    wc.style = UInt32(
        winkb_constant["CS_HREDRAW"]() | winkb_constant["CS_VREDRAW"]()
    )
    wc.lpfnWndProc = Int(_fn_ptr_as_opaque(proc))
    wc.hInstance = hInstance
    wc.hCursor = LoadCursorW(0, winkb_constant["IDC_ARROW"]())
    wc.lpszClassName = Int(class_name.unsafe_ptr())
    if RegisterClassExW(com_addr(wc)) == 0:
        raise Error(
            "RegisterClassExW failed, GetLastError = " + String(GetLastError())
        )

    # CreateWindowExW is given the OUTER size, so ask Windows what frame a
    # WS_OVERLAPPEDWINDOW adds rather than adding a remembered 16 and 39.
    comptime STYLE = winkb_constant["WS_OVERLAPPEDWINDOW"]()
    var want = RECT(Int32(0), Int32(0), Int32(WIN_W), Int32(WIN_H))
    _ = AdjustWindowRect(com_addr(want), UInt32(STYLE), c_int(0))

    var hwnd = CreateWindowExW(
        UInt32(0),
        class_name.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        title.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        UInt32(STYLE),
        c_int(80), c_int(60),
        c_int(Int(want.right - want.left)),
        c_int(Int(want.bottom - want.top)),
        0, 0, hInstance, 0,
    )
    if hwnd == 0:
        raise Error(
            "CreateWindowExW failed, GetLastError = " + String(GetLastError())
        )
    # The class name and title buffers must outlive the calls that read them.
    _ = class_name
    _ = title

    # The window procedure reaches the pixels through the one pointer Windows
    # keeps for us. Emplaced, not assigned: `store[] = value` would destroy
    # whatever the allocator last had in that memory first.
    var store = alloc[Scene](1, alignment=8)
    store.unsafe_write(
        Scene(
            Int(host.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()),
            WIN_W,
            WIN_H,
            0,
        )
    )
    _ = SetWindowLongPtrW(
        hwnd, c_int(winkb_constant["GWLP_USERDATA"]()), Int(store)
    )

    _ = ShowWindow(hwnd, c_int(winkb_constant["SW_SHOW"]()))
    _ = UpdateWindow(hwnd)

    # The client is very probably exactly WIN_W x WIN_H, but a DPI setting can
    # make it something else and dragging the window's corner certainly does,
    # and a mouse mapped with the wrong scale paints in the wrong place. So
    # this is re-read every frame rather than measured once: StretchDIBits
    # already scales the picture to whatever the client rect is, and the
    # pointer has to follow it.
    var client = RECT()
    _ = GetClientRect(hwnd, com_addr(client))
    var to_grid_x = Float32(W) / Float32(WIN_W)
    var to_grid_y = Float32(H) / Float32(WIN_H)
    print("  client", Int(client.right - client.left), "x",
          Int(client.bottom - client.top))

    # ---- a puff to start with, so the window is never blank ---------------
    var hue = Float32(0.05)
    var c0 = hue_rgb(hue)
    splat(ctx, dr, Float32(W // 2), Float32(H // 2), Float32(18),
          c0[0] * Float32(2.0))
    splat(ctx, dg, Float32(W // 2), Float32(H // 2), Float32(18),
          c0[1] * Float32(2.0))
    splat(ctx, db, Float32(W // 2), Float32(H // 2), Float32(18),
          c0[2] * Float32(2.0))
    # Negative v is upward: row 0 is the top of the grid and of the window.
    splat(ctx, v, Float32(W // 2), Float32(H // 2 + 10), Float32(16),
          Float32(-14.0))
    ctx.synchronize()

    var autoshot = env_int("FLUID_AUTOSHOT", 0)
    print()
    print("Drag to paint.  [space] pause  [c] clear  [r] rain  [s] save shot"
          "  [Esc] quit")
    if autoshot > 0:
        print("FLUID_AUTOSHOT =", autoshot,
              "- will prove the pixels landed at that frame and exit")

    # ---- the loop --------------------------------------------------------
    # PeekMessageW rather than GetMessageW: this window animates, so it must
    # never block waiting for input. It must also never Sleep -- a thread that
    # has not pumped for about five seconds is declared hung and DWM starts
    # drawing a ghost of the window instead of the window.
    comptime PM_REMOVE = UInt32(0x0001)
    comptime WM_QUIT = UInt32(winkb_constant["WM_QUIT"]())
    comptime WM_MOUSEMOVE = UInt32(winkb_constant["WM_MOUSEMOVE"]())
    comptime WM_LBUTTONDOWN = UInt32(winkb_constant["WM_LBUTTONDOWN"]())
    comptime WM_LBUTTONUP = UInt32(winkb_constant["WM_LBUTTONUP"]())
    comptime WM_KEYDOWN = UInt32(winkb_constant["WM_KEYDOWN"]())
    comptime MK_LBUTTON = winkb_constant["MK_LBUTTON"]()

    var hz = performance_frequency()
    var loop_start = performance_counter()
    var msg = MSG()
    var running = True
    var paused = False
    var frames = 0
    var shots = 0
    var shot_wanted = False
    var drag_samples = 0
    var last_x = Float32(-1)
    var last_y = Float32(-1)

    while running:
        # The window can be resized under us at any time; the picture follows
        # because StretchDIBits scales to the client rect, and the mouse has
        # to follow with it.
        _ = GetClientRect(hwnd, com_addr(client))
        if client.right > client.left:
            to_grid_x = Float32(W) / Float32(Int(client.right - client.left))
        if client.bottom > client.top:
            to_grid_y = Float32(H) / Float32(Int(client.bottom - client.top))

        while (
            PeekMessageW(com_addr(msg), 0, UInt32(0), UInt32(0), PM_REMOVE)
            != 0
        ):
            # PeekMessageW REMOVES WM_QUIT from the queue, so the loop has to
            # notice it here -- DispatchMessageW will not do it.
            if msg.message == WM_QUIT:
                running = False
                break

            # Input is handled in the pump rather than in the window
            # procedure, which is what keeps the DeviceContext and its dozen
            # buffers ordinary locals in `main`. A procedure that dispatched
            # kernels would need every one of them reachable from a C-ABI
            # callback.
            if msg.message == WM_LBUTTONDOWN or msg.message == WM_MOUSEMOVE:
                var dragging = msg.message == WM_LBUTTONDOWN or (
                    (msg.wParam & MK_LBUTTON) != 0
                )
                if dragging:
                    # lParam packs the point as two SIGNED 16-bit halves, and
                    # they are signed: a drag that leaves the window to the
                    # left reports a negative x, which read unsigned becomes
                    # 65,000-odd.
                    var px = msg.lParam & 0xFFFF
                    if px >= 0x8000:
                        px -= 0x10000
                    var py = (msg.lParam >> 16) & 0xFFFF
                    if py >= 0x8000:
                        py -= 0x10000
                    var mx = Float32(px) * to_grid_x
                    var my = Float32(py) * to_grid_y
                    if msg.message == WM_LBUTTONDOWN:
                        last_x = mx
                        last_y = my
                        _ = SetCapture(hwnd)
                    if last_x >= Float32(0):
                        var vx = (mx - last_x) * Float32(6.0)
                        var vy = (my - last_y) * Float32(6.0)
                        var c = hue_rgb(hue)
                        hue += Float32(0.011)
                        splat(ctx, u, mx, my, Float32(9), vx)
                        splat(ctx, v, mx, my, Float32(9), vy)
                        splat(ctx, dr, mx, my, Float32(7), c[0] * Float32(0.6))
                        splat(ctx, dg, mx, my, Float32(7), c[1] * Float32(0.6))
                        splat(ctx, db, mx, my, Float32(7), c[2] * Float32(0.6))
                        drag_samples += 1
                    last_x = mx
                    last_y = my
            elif msg.message == WM_LBUTTONUP:
                last_x = Float32(-1)
                _ = ReleaseCapture()
            elif msg.message == WM_KEYDOWN:
                if msg.wParam == winkb_constant["VK_SPACE"]():
                    paused = not paused
                elif msg.wParam == ord("C"):
                    for buf in [dr, dg, db, u, v]:
                        ctx.enqueue_memset(buf, Float32(0))
                elif msg.wParam == ord("S"):
                    shot_wanted = True
                elif msg.wParam == ord("R"):
                    # A dozen coloured drops with a shove behind each.
                    for k in range(12):
                        var c = hue_rgb(hue)
                        hue += Float32(0.083)
                        var rx = Float32((k * 97 + frames * 31) % W)
                        var ry = Float32((k * 53 + frames * 17) % H)
                        splat(ctx, dr, rx, ry, Float32(10), c[0])
                        splat(ctx, dg, rx, ry, Float32(10), c[1])
                        splat(ctx, db, rx, ry, Float32(10), c[2])
                        splat(ctx, v, rx, ry, Float32(10), Float32(-9.0))
                elif msg.wParam == winkb_constant["VK_ESCAPE"]():
                    _ = DestroyWindow(hwnd)

            _ = TranslateMessage(com_addr(msg))
            _ = DispatchMessageW(com_addr(msg))
        if not running:
            break

        # ---- one fluid step ----------------------------------------------
        if not paused:
            fluid_step(ctx, u, v, u0, v0, div, pr, pr0, VEL_FADE)
            # Dye is passive: it rides the corrected field and does not affect
            # it. Three channels, one kernel, one shared scratch.
            advect_dye(ctx, dr, scratch, u, v, DYE_FADE)
            advect_dye(ctx, dg, scratch, u, v, DYE_FADE)
            advect_dye(ctx, db, scratch, u, v, DYE_FADE)

        # ---- shade and present -------------------------------------------
        ctx.enqueue_function[render_kernel](
            frame, dr, dg, db, grid_dim=PIX_GRID, block_dim=BLOCK
        )
        host.enqueue_copy_from(frame)
        ctx.synchronize()

        # All painting funnels through WM_PAINT so that an uncovered window
        # repaints from the same code that animates it. UpdateWindow makes
        # that paint happen now rather than whenever the queue empties.
        _ = InvalidateRect(hwnd, 0, c_int(0))
        _ = UpdateWindow(hwnd)
        frames += 1

        if autoshot > 0 and frames == autoshot:
            shot_wanted = True

        if shot_wanted:
            shot_wanted = False
            print()
            print("frame", frames, "-", drag_samples, "drag samples so far")
            # Two different questions, asked separately on purpose. The file
            # says what was computed; the readback says what is on the screen.
            # A demo that only ever checks the first can be black for a week.
            var landed = readback(hwnd)
            if landed == 0:
                print(
                    "  NOTHING IS ON SCREEN. The window is up and every call"
                    " succeeded, but the client area is black."
                )
            var path = String("fluid-") + String(shots) + ".png"
            # Saved from the same words that were just presented, so the file
            # and the window cannot disagree.
            if write_png(
                path,
                host.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
                WIN_W,
                WIN_H,
            ):
                print("  saved", path)
            else:
                print("  could not save", path)
            shots += 1

        if autoshot > 0 and frames == autoshot + 1:
            _ = DestroyWindow(hwnd)

        if frames % 120 == 0:
            var now = performance_counter()
            var us = (now - loop_start) * 1000000 // hz
            var fps = frames * 1000000 // us if us > 0 else 0
            # Also to stdout: the title bar is invisible to a run captured in
            # a log, which is every run that is not a person watching.
            print("  frame", frames, "-", fps, "fps,", store[].painted,
                  "paints")
            var caption = wide_str(
                String("Fluid - ") + String(fps) + " fps   [space] pause"
                " [c] clear  [r] rain  [s] shot"
            )
            _ = SetWindowTextW(
                hwnd, caption.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
            )
            _ = caption

    var total_us = (performance_counter() - loop_start) * 1000000 // hz
    print()
    print(
        "closed after",
        frames,
        "frames in",
        total_us // 1000,
        "ms =",
        frames * 1000000 // total_us if total_us > 0 else 0,
        "fps;",
        store[].painted,
        "of them reached the window;",
        drag_samples,
        "drag samples painted",
    )
    store.unsafe_free()
