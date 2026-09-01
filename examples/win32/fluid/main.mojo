# ===----------------------------------------------------------------------=== #
# Fluid -- a native Windows app written entirely in Mojo.
#
# Stable Fluids (Jos Stam, SIGGRAPH 1999). Drag the mouse and coloured dye
# swirls through a velocity field that is advected along itself and then made
# divergence-free by a Jacobi pressure solve. Every kernel is Mojo, compiled to
# PTX and run on the NVIDIA GPU through the CUDA driver; the finished BGRA
# frame is handed to GDI. There is no shader anywhere in the pipeline and no
# hand-declared Win32: the window, the class, the structures and the blit come
# from `std.windows.gui`, and every entry point this file still resolves for
# itself comes out of the windows_api.db metadata through `win32[]`.
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

from png import write_png
from solver import (
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
from std.collections import Span
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.sys.info import size_of
from std.sys._com import com_addr
from std.sys._winkb import winkb_constant, winkb_struct_size
from std.windows import (
    get_environment,
    performance_counter,
    performance_frequency,
)
from std.windows.core import WideString

# Everything a Windows program does the same way every Windows program does
# it. `WindowClass` and `Window` register and create; `present_bgra` is the
# StretchDIBits blit; `MSG`, `RECT` and `BITMAPINFOHEADER` are the structures,
# already checked against the metadata inside the module, so this file
# declares -- and therefore has to assert -- none of them.
from std.windows.gui import (
    BITMAPINFOHEADER,
    MSG,
    RECT,
    Window,
    WindowClass,
    default_handler,
    present_bgra,
    quit,
    win32,
)


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
            # BeginPaint is what CLEARS the update region, and EndPaint closes
            # it. `present_bgra` draws through a device context of its own,
            # which is fine and is not a substitute for this pair: skip them
            # and Windows re-sends WM_PAINT immediately, forever.
            var hdc = BeginPaint(hwnd, ps_ptr)
            if stored != 0 and hdc != 0:
                var scene = Pointer[Scene, MutAnyOrigin](
                    unsafe_from_address=stored
                )
                if scene[].pixels != 0:
                    present_bgra(
                        hwnd,
                        Span[UInt32, MutAnyOrigin](
                            unsafe_ptr = Pointer[UInt32, MutAnyOrigin](
                                unsafe_from_address = scene[].pixels
                            ),
                            length = scene[].width * scene[].height,
                        ),
                        scene[].width,
                        scene[].height,
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
            quit(0)
            return 0

        return default_handler(hwnd, message, wparam, lparam)
    except:
        return 0


# ===----------------------------------------------------------------------=== #
# Proving the pixels landed.
#
# That every call returned S_OK is not evidence that anything is on screen.
# This reads the window's OWN client area back through a DIB section, which is
# `present_bgra`'s machinery pointed the other way, and reports what is
# actually there. It stays here rather than in `std.windows.gui` because it is
# a diagnostic for this demo -- it prints the ink's bounding box, which is a
# sentence about dye rather than about windows.
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
    var width = rc.width()
    var height = rc.height()
    if width <= 0 or height <= 0:
        print("  readback: the window has no client area")
        return 0

    var hdc = GetDC(hwnd)
    var mem = CreateCompatibleDC(hdc)
    var bmi = BITMAPINFOHEADER()
    bmi.biSize = UInt32(size_of[BITMAPINFOHEADER]())
    bmi.biWidth = Int32(width)
    bmi.biHeight = Int32(-height)  # top-down, as present_bgra writes
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


def env_int(name: StringSlice, fallback: Int) raises -> Int:
    """Read a small non-negative integer out of the environment.

    Through `std.windows.get_environment`, which is GetEnvironmentVariableW
    decoded properly, rather than getenv: this tree's rule is that a Windows
    facility is reached through the metadata.
    """
    var text = get_environment(name)
    if text.byte_length() == 0:
        return fallback
    var value = 0
    for byte in text.as_bytes():
        var ch = Int(byte)
        if ch < 48 or ch > 57:
            return fallback
        value = value * 10 + (ch - 48)
    return value


# ===----------------------------------------------------------------------=== #


def main() raises:
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
    # The class and the window are `std.windows.gui`'s: it registers with
    # CS_HREDRAW | CS_VREDRAW and an arrow cursor, and creates a
    # WS_OVERLAPPEDWINDOW, which is exactly what this wants.
    var klass = WindowClass("MojoFluidWindow", fluid_wndproc)

    # A window is created at its OUTER size, which is not the size a program
    # drawing pixels cares about, so ask Windows what frame the style adds
    # rather than adding a remembered 16 and 39.
    var AdjustWindowRect = win32[
        def (Pointer[RECT, MutAnyOrigin], UInt32, c_int) thin abi("C") -> c_int,
        "AdjustWindowRect",
    ]()
    var want = RECT(Int32(0), Int32(0), Int32(WIN_W), Int32(WIN_H))
    _ = AdjustWindowRect(
        com_addr(want),
        UInt32(winkb_constant["WS_OVERLAPPEDWINDOW"]()),
        c_int(0),
    )

    var window = Window(
        klass,
        "Fluid - Stable Fluids, every kernel a Mojo kernel",
        want.width(),
        want.height(),
    )
    var hwnd = window.handle

    var InvalidateRect = win32[
        def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
    ]()
    var UpdateWindow = win32[def (Int) thin abi("C") -> c_int, "UpdateWindow"]()
    var SetWindowLongPtrW = win32[
        def (Int, c_int, Int) thin abi("C") -> Int, "SetWindowLongPtrW"
    ]()
    var SetWindowTextW = win32[
        def (Int, Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> c_int,
        "SetWindowTextW",
    ]()
    var DestroyWindow = win32[
        def (Int) thin abi("C") -> c_int, "DestroyWindow"
    ]()
    var SetCapture = win32[def (Int) thin abi("C") -> Int, "SetCapture"]()
    var ReleaseCapture = win32[def () thin abi("C") -> c_int, "ReleaseCapture"]()

    # The window procedure reaches the pixels through the one pointer Windows
    # keeps for us. Emplaced, not assigned: `store[] = value` would destroy
    # whatever the allocator last had in that memory first.
    var store = unsafe_alloc[Scene](1, alignment=8)
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

    window.show()

    # The client is very probably exactly WIN_W x WIN_H, but a DPI setting can
    # make it something else and dragging the window's corner certainly does,
    # and a mouse mapped with the wrong scale paints in the wrong place. So
    # this is re-read every frame rather than measured once: present_bgra
    # already scales the picture to whatever the client rect is, and the
    # pointer has to follow it.
    var to_grid_x = Float32(W) / Float32(WIN_W)
    var to_grid_y = Float32(H) / Float32(WIN_H)
    var opened = window.client_size()
    print("  client", opened.width(), "x", opened.height())

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
    # This is NOT `std.windows.gui.pump()`, and deliberately. That one handles
    # every waiting message and tells the caller only whether to keep going,
    # which is the right shape for a program whose procedure does the work.
    # Here the procedure cannot: it is captureless, and dispatching a kernel
    # from it would need the DeviceContext and its twelve buffers reachable
    # from a C-ABI callback. So this loop reads `msg.message` itself before
    # dispatching, and every one of them stays an ordinary local in `main`.
    #
    # PeekMessageW rather than GetMessageW for the same reason `pump` uses it:
    # this window animates, so it must never block waiting for input. It must
    # also never Sleep -- a thread that has not pumped for about five seconds
    # is declared hung and DWM starts drawing a ghost of the window instead of
    # the window.
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

    comptime PM_REMOVE = UInt32(winkb_constant["PM_REMOVE"]())
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
        # because present_bgra scales to the client rect, and the mouse has to
        # follow with it.
        var client = window.client_size()
        if client.width() > 0:
            to_grid_x = Float32(W) / Float32(client.width())
        if client.height() > 0:
            to_grid_y = Float32(H) / Float32(client.height())

        while (
            PeekMessageW(com_addr(msg), 0, UInt32(0), UInt32(0), PM_REMOVE)
            != 0
        ):
            # PeekMessageW REMOVES WM_QUIT from the queue, so the loop has to
            # notice it here -- DispatchMessageW will not do it.
            if msg.message == WM_QUIT:
                running = False
                break

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
            var caption = WideString(
                String("Fluid - ") + String(fps) + " fps   [space] pause"
                " [c] clear  [r] rain  [s] shot"
            )
            _ = SetWindowTextW(hwnd, caption.unsafe_ptr())
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
