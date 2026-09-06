"""The window, the pump, and polled input -- the D3D11 backend's GamePane.

The Windows answer to the Metal backend's `NSWindow` + `CAMetalLayer` +
`GameView` class. The frame contract is the same one the design states:
the game owns the loop, `pump()` drains events and says whether to keep
going, `begin_frame` synchronises the kernel stream before anything reads
pane bytes, and `end_frame` presents. `GAMEPANE_FRAMES` and
`GAMEPANE_DUMP` mean exactly what they mean on the Metal side, so the two
ports run the same headless harness.

Two platform differences are worth naming. First, input codes: the api
tier's codes are macOS virtual key codes because that is what the one
backend spoke, and the design's rule is that a second platform maps its
own codes to them -- so the pump translates `VK_*` and the game never
changes. Second, the pane is a real window whose client area is the
viewport; the swap chain is created once at the size the pane asks for,
and a resize leaves the picture at the pane's size rather than rescaling
the swap chain -- v1, and stated rather than discovered.
"""

from max.gpu.host import DeviceContext
from std.ffi import c_int
from std.memory import Pointer, OpaquePointer
from std.memory.alloc import unsafe_alloc
from std.sys._com import com_addr, com_method_of
from std.sys._globals import named_global
from std.sys._winkb import winkb_constant, winkb_struct_size
from std.sys.info import size_of
from std.windows import (
    get_environment,
    performance_counter,
    performance_frequency,
)
from std.windows.gui import (
    BITMAPINFOHEADER,
    MSG,
    RECT,
    Window,
    WindowClass,
    default_handler,
    win32,
)

from .device import (
    create_device_and_swapchain,
    create_render_target_view,
    get_back_buffer,
)


# ── input state, shared with the window procedure ────────────────────────────
#
# A window procedure is captureless -- Windows calls it -- so the held-key
# block and the mouse record live in one allocation whose address a
# named_global carries. There is one game window per process, which is the
# same reason the Metal backend reached for named_globals: a method the
# runtime calls captures nothing.

comptime _HELD_PTR = named_global["gamepane.d3d11.held", Int]
comptime _MOUSE_PTR = named_global["gamepane.d3d11.mouse", Int]


def _ensure_input_state():
    if _HELD_PTR()[] == 0:
        var held = unsafe_alloc[UInt8](128, alignment=1)
        for i in range(128):
            held[unsafe_offset=i] = 0
        _HELD_PTR()[] = Int(held)
    if _MOUSE_PTR()[] == 0:
        # x, y as Float64, then buttons: bit 0 left, bit 1 right.
        var mouse = unsafe_alloc[Float64](3, alignment=8)
        mouse.unsafe_offset(0)[] = 0.0
        mouse.unsafe_offset(1)[] = 0.0
        mouse.unsafe_offset(2)[] = 0.0
        _MOUSE_PTR()[] = Int(mouse)


def key_held(code: Int) -> Bool:
    """Whether the key with this api-tier code is down, as of the last pump.

    The api's codes are the macOS virtual key codes the Metal backend
    reports; the pump translates `VK_*` into them, which is the design's
    rule -- a second platform maps its codes, and a game does not change.
    """
    if _HELD_PTR()[] == 0:
        return False
    if code < 0 or code >= 128:
        return False
    var held = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=_HELD_PTR()[]
    )
    return held[unsafe_offset=code] != 0


def mouse_state() -> Tuple[Float64, Float64, Bool, Bool]:
    """(x, y, left, right), normalised 0..1 with y from the TOP."""
    if _MOUSE_PTR()[] == 0:
        return (0.0, 0.0, False, False)
    var mouse = Pointer[Float64, MutUntrackedOrigin](
        unsafe_from_address=_MOUSE_PTR()[]
    )
    var buttons = Int(mouse.unsafe_offset(2)[])
    return (
        mouse.unsafe_offset(0)[],
        mouse.unsafe_offset(1)[],
        (buttons & 1) != 0,
        (buttons & 2) != 0,
    )


def any_key_held() -> Bool:
    """Is ANY key down? An attract mode needs this and nothing else: it is
    not interested in which key woke the cabinet up, only that somebody
    touched it."""
    if _HELD_PTR()[] == 0:
        return False
    var held = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=_HELD_PTR()[]
    )
    for i in range(128):
        if held[unsafe_offset=i] != 0:
            return True
    return False


def clear_input():
    """Every key up, every button up. The stuck-key hazard on focus change
    is not a Windows speciality, but it is not the game's either --
    WM_KILLFOCUS is handled the way the Metal backend handles resignKey."""
    if _HELD_PTR()[] != 0:
        var held = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=_HELD_PTR()[]
        )
        for i in range(128):
            held[unsafe_offset=i] = 0
    if _MOUSE_PTR()[] != 0:
        var mouse = Pointer[Float64, MutUntrackedOrigin](
            unsafe_from_address=_MOUSE_PTR()[]
        )
        mouse.unsafe_offset(2)[] = 0.0


# The translation table, VK code -> api-tier code. Written out rather than
# computed: macOS's codes are not in numeric order past 3, which is why the
# api spells them out too. A game that declares a key this table has not
# met is a game for the next sprint, and `key_held` answers False honestly.
def _mac_code(vk: Int) -> Int:
    if vk == 0x25:
        return 123  # left
    if vk == 0x27:
        return 124  # right
    if vk == 0x28:
        return 125  # down
    if vk == 0x26:
        return 126  # up
    if vk == 0x20:
        return 49  # space
    if vk == 0x1B:
        return 53  # escape
    if vk == 0x0D:
        return 36  # return
    if vk == 0x31:
        return 18  # 1
    if vk == 0x32:
        return 19  # 2
    if vk == 0x33:
        return 20  # 3
    if vk == 0x34:
        return 21  # 4
    if vk == 0x35:
        return 23  # 5
    if vk == 0x36:
        return 22  # 6
    if vk == 0x41:
        return 0  # A
    if vk == 0x53:
        return 1  # S
    if vk == 0x44:
        return 2  # D
    if vk == 0x5A:
        return 6  # Z
    if vk == 0x58:
        return 7  # X
    if vk == 0x51:
        return 12  # Q
    if vk == 0x57:
        return 13  # W
    if vk == 0x45:
        return 14  # E
    if vk == 0x52:
        return 15  # R
    return -1


# The window procedure. Windows calls it, so it must never raise, and
# everything it touches lives behind the two named_globals above.
@export("gamepane_wndproc")
def gamepane_wndproc(
    hwnd: Int, message: UInt32, wparam: Int, lparam: Int
) abi("C") -> Int:
    try:
        var wm_keydown = UInt32(winkb_constant["WM_KEYDOWN"]())
        var wm_keyup = UInt32(winkb_constant["WM_KEYUP"]())
        var wm_syskeydown = UInt32(winkb_constant["WM_SYSKEYDOWN"]())
        var wm_syskeyup = UInt32(winkb_constant["WM_SYSKEYUP"]())
        var wm_killfocus = UInt32(winkb_constant["WM_KILLFOCUS"]())
        var wm_close = UInt32(winkb_constant["WM_CLOSE"]())

        if message == wm_close:
            var destroy = win32[
                def (Int) thin abi("C") -> c_int, "DestroyWindow"
            ]()
            _ = destroy(hwnd)
            return 0

        if message == wm_killfocus:
            clear_input()
            return 0

        if (
            message == wm_keydown
            or message == wm_syskeydown
            or message == wm_keyup
            or message == wm_syskeyup
        ):
            if _HELD_PTR()[] != 0:
                var held = Pointer[UInt8, MutUntrackedOrigin](
                    unsafe_from_address=_HELD_PTR()[]
                )
                var down = message == wm_keydown or message == wm_syskeydown
                var mac = _mac_code(Int(wparam & 0xFF))
                if mac >= 0:
                    held[unsafe_offset=mac] = UInt8(1 if down else 0)
                # ESC from a fullscreen pane would otherwise beep.
                if message == wm_syskeydown and Int(wparam) == 0x1B:
                    return 0

        var wm_mousemove = UInt32(winkb_constant["WM_MOUSEMOVE"]())
        var wm_lbuttondown = UInt32(winkb_constant["WM_LBUTTONDOWN"]())
        var wm_lbuttonup = UInt32(winkb_constant["WM_LBUTTONUP"]())
        var wm_rbuttondown = UInt32(winkb_constant["WM_RBUTTONDOWN"]())
        var wm_rbuttonup = UInt32(winkb_constant["WM_RBUTTONUP"]())
        if (
            message == wm_mousemove
            or message == wm_lbuttondown
            or message == wm_lbuttonup
            or message == wm_rbuttondown
            or message == wm_rbuttonup
        ):
            if _MOUSE_PTR()[] != 0:
                var mouse = Pointer[Float64, MutUntrackedOrigin](
                    unsafe_from_address=_MOUSE_PTR()[]
                )
                # lParam packs two SIGNED 16-bit halves. Normalised 0..1
                # needs the client rect, queried per event: a resized
                # window still means the same fraction.
                var px = lparam & 0xFFFF
                if px >= 0x8000:
                    px -= 0x10000
                var py = (lparam >> 16) & 0xFFFF
                if py >= 0x8000:
                    py -= 0x10000
                var get_client = win32[
                    def (
                        Int, Pointer[RECT, MutAnyOrigin]
                    ) thin abi("C") -> c_int,
                    "GetClientRect",
                ]()
                var rc = RECT()
                _ = get_client(hwnd, com_addr(rc))
                var w = Float64(rc.width())
                var h = Float64(rc.height())
                if w > 0:
                    mouse.unsafe_offset(0)[] = Float64(px) / w
                if h > 0:
                    # y from the TOP, the pane's convention, which happens
                    # to be lParam's too.
                    mouse.unsafe_offset(1)[] = Float64(py) / h
                var buttons = Int(mouse.unsafe_offset(2)[])
                if message == wm_lbuttondown:
                    buttons |= 1
                elif message == wm_lbuttonup:
                    buttons &= ~1
                elif message == wm_rbuttondown:
                    buttons |= 2
                elif message == wm_rbuttonup:
                    buttons &= ~2
                mouse.unsafe_offset(2)[] = Float64(buttons)

        return default_handler(hwnd, message, wparam, lparam)
    except:
        return 0


# ── the pane ────────────────────────────────────────────────────────────────


@fieldwise_init
struct Frame(Copyable, Movable):
    """One frame in flight. `valid` is the Metal contract's no-drawable
    slot; on Windows a frame is always viable and it is never False."""

    var valid: Bool


struct GamePane(Movable):
    """A window, a Direct3D 11 swap chain, and the loop around them."""

    var window: Window
    var width: Int
    var height: Int
    var swapchain: Int
    var device: Int
    var context: Int
    var rtv: Int
    var backbuffer: Int
    var ctx: DeviceContext
    var last_ns: Int
    var dt_secs: Float64
    var frames: Int
    var frame_limit: Int
    """GAMEPANE_FRAMES: render this many, then stop. 0 means run until
    closed."""
    var dump_path: String
    """GAMEPANE_DUMP: write the last frame here as raw BGRA."""

    def __init__(out self, title: String, width: Int, height: Int) raises:
        _ensure_input_state()
        self.width = width
        self.height = height
        self.frames = 0
        self.dt_secs = 1.0 / 60.0
        self.last_ns = Int(performance_counter())
        self.ctx = DeviceContext(api="cuda")

        var limit = 0
        let fenv = get_environment("GAMEPANE_FRAMES")
        _ = fenv
        if fenv.byte_length() > 0:
            # A small non-negative integer out of the environment; anything
            # else means run until closed, which is also the default.
            var value = 0
            var ok = True
            for byte in fenv.as_bytes():
                var ch = Int(byte)
                if ch < 48 or ch > 57:
                    ok = False
                    break
                value = value * 10 + (ch - 48)
            if ok:
                limit = value
        self.frame_limit = limit
        var dump = get_environment("GAMEPANE_DUMP")
        self.dump_path = String(dump)

        var klass = WindowClass(String("MojoGamePane"), gamepane_wndproc)
        self.window = Window(klass, title, width, height)
        var hwnd = self.window.handle

        var debug_env = get_environment("GAMEPANE_DEBUG")
        var debug_layer = 0
        if debug_env == "1":
            debug_layer = 1
        var created = create_device_and_swapchain(
            hwnd, width, height, debug_layer == 1
        )
        self.swapchain = created[0]
        self.device = created[1]
        self.context = created[2]
        self.backbuffer = get_back_buffer(self.swapchain)
        self.rtv = create_render_target_view(self.device, self.backbuffer)

        self.window.show()

    def pump(mut self) raises -> Bool:
        """Drain every pending event, then say whether to keep going.

        False once the window is closed, or once GAMEPANE_FRAMES have been
        presented.
        """
        if self.frame_limit > 0 and self.frames >= self.frame_limit:
            return False

        var peek = win32[
            def (
                Pointer[MSG, MutAnyOrigin], Int, UInt32, UInt32, UInt32
            ) thin abi("C") -> c_int,
            "PeekMessageW",
        ]()
        var translate = win32[
            def (Pointer[MSG, MutAnyOrigin]) thin abi("C") -> c_int,
            "TranslateMessage",
        ]()
        var dispatch = win32[
            def (Pointer[MSG, MutAnyOrigin]) thin abi("C") -> Int,
            "DispatchMessageW",
        ]()
        comptime PM_REMOVE = UInt32(winkb_constant["PM_REMOVE"]())
        comptime WM_QUIT = UInt32(winkb_constant["WM_QUIT"]())

        var msg = MSG()
        while peek(com_addr(msg), 0, UInt32(0), UInt32(0), PM_REMOVE) != 0:
            if msg.message == WM_QUIT:
                return False
            _ = translate(com_addr(msg))
            _ = dispatch(com_addr(msg))

        var now = Int(performance_counter())
        var hz = performance_frequency()
        var elapsed = Float64(now - self.last_ns) / Float64(hz)
        # A first frame, or a stall behind a breakpoint, must not hand the
        # game a dt it will integrate into a teleport.
        if elapsed <= 0.0 or elapsed > 0.25:
            elapsed = 1.0 / 60.0
        self.dt_secs = elapsed
        self.last_ns = now
        return True

    def dt(self) -> Float64:
        """Seconds since the previous frame, clamped to something sane."""
        return self.dt_secs

    def frame_count(self) -> Int:
        return self.frames

    def aspect(self) -> Float32:
        return Float32(self.width) / Float32(self.height)

    def begin_frame(mut self) raises -> Frame:
        """Open the frame.

        THE ORDERING RULE, the same sentence the Metal backend writes:
        blits are enqueued on the runtime's stream and the frame is
        presented on the swap chain's own path -- two submission paths to
        the same GPU with nothing implicitly ordering them. So every
        enqueued kernel is completed here, before anything reads the pane
        bytes the kernels were writing. At retro resolutions the
        synchronise is microseconds.
        """
        self.ctx.synchronize()
        return Frame(True)

    def end_frame(mut self, frame: Frame) raises:
        """Present, and -- on the last frame of a harness run -- write the
        finished image out for whoever is checking it."""
        if not frame.valid:
            return
        var present = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], UInt32, UInt32
            ) thin abi("C") -> c_int,
            "IDXGISwapChain",
            "Present",
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.swapchain))
        var hr = present(
            OpaquePointer[MutUntrackedOrigin](
                unsafe_from_address=self.swapchain
            ),
            UInt32(1),
            UInt32(0),
        )
        # OCCLUDED -- a hidden window presents nothing -- is not a failure;
        # the signed HRESULT says so rather than an error code.
        _ = hr

        self.frames += 1
        # Dump AFTER Present: the BitBlt reads the DWM-composed screen,
        # which is only honest once the frame has actually been shown.
        # (A staging-copy of the back buffer was tried first and read
        # black: FLIP_DISCARD makes the back buffer's contents undefined
        # after Present.)
        if (
            self.frame_limit > 0
            and self.frames >= self.frame_limit
            and self.dump_path.byte_length() > 0
        ):
            self._dump()

    def clear(mut self, frame: Frame):
        """The ground, and nothing else -- layer 0 when there is no layer 0.
        On this backend the swap chain starts every frame undefined, so
        clear is OMSetRenderTargets + ClearRenderTargetView, once."""
        from .device import clear_render_target, om_set_render_targets

        if not frame.valid:
            return
        om_set_render_targets(self.context, self.rtv)
        clear_render_target(self.context, self.rtv, 0.0, 0.0, 0.0)

    def present(mut self) raises:
        """Show a frame with nothing in it -- begin and end. The one-liner
        for a pane with no layers yet, and G1's own test on this platform
        too."""
        let frame = self.begin_frame()
        self.end_frame(frame)

    def close(mut self):
        """The window is gone; the process's D3D references die with it.
        The COM-apartment ordering promises belong to the audio sprint,
        which is not here yet."""
        pass

    def _dump(mut self) raises:
        """The presented frame, read back off the actual window.

        A staging-texture copy of the back buffer was tried first and reads
        black under a flip-model swap chain: after Present, the back
        buffer's contents are the runtime's business. The SCREEN is the
        truth a person sees, so the readback blits the window's own client
        area into a DIB and writes those rows -- the same raw-BGRA contract
        the Metal dump keeps, pitch included."""
        var hwnd = self.window.handle
        var GetDC = win32[
            def (Int) thin abi("C") -> Int, "GetDC"
        ]()
        var ReleaseDC = win32[
            def (Int, Int) thin abi("C") -> c_int, "ReleaseDC"
        ]()
        var CreateCompatibleDC = win32[
            def (Int) thin abi("C") -> Int, "CreateCompatibleDC"
        ]()
        var CreateDIBSection = win32[
            def (
                Int, Pointer[BITMAPINFOHEADER, MutAnyOrigin], UInt32,
                Pointer[Int, MutAnyOrigin], Int, UInt32,
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
        var DeleteObject = win32[
            def (Int) thin abi("C") -> c_int, "DeleteObject"
        ]()
        var DeleteDC = win32[
            def (Int) thin abi("C") -> c_int, "DeleteDC"
        ]()

        var hdc = GetDC(hwnd)
        var mem = CreateCompatibleDC(hdc)
        var bmi = BITMAPINFOHEADER()
        bmi.biSize = UInt32(size_of[BITMAPINFOHEADER]())
        bmi.biWidth = Int32(self.width)
        bmi.biHeight = Int32(-self.height)  # top-down
        bmi.biPlanes = 1
        bmi.biBitCount = 32
        bmi.biCompression = UInt32(winkb_constant["BI_RGB"]())
        var bits: Int = 0
        var dib = CreateDIBSection(
            hdc,
            com_addr(bmi),
            UInt32(winkb_constant["DIB_RGB_COLORS"]()),
            com_addr(bits),
            0,
            UInt32(0),
        )
        if dib != 0 and bits != 0:
            var old = SelectObject(mem, dib)
            _ = BitBlt(
                mem,
                c_int(0), c_int(0), c_int(self.width), c_int(self.height),
                hdc,
                c_int(0), c_int(0),
                UInt32(winkb_constant["SRCCOPY"]()),
            )
            var px = Pointer[UInt32, MutAnyOrigin](
                unsafe_from_address=bits
            )
            var out = List[UInt8](
                length=self.width * self.height * 4, fill=0
            )
            for y in range(self.height):
                for x in range(self.width):
                    var word = px[unsafe_offset = y * self.width + x]
                    var o = (y * self.width + x) * 4
                    out[o] = UInt8(word & 0xFF)
                    out[o + 1] = UInt8((word >> 8) & 0xFF)
                    out[o + 2] = UInt8((word >> 16) & 0xFF)
                    out[o + 3] = UInt8((word >> 24) & 0xFF)
            _ = SelectObject(mem, old)
            _ = DeleteObject(dib)
            self._write_dump(out)
        _ = DeleteDC(mem)
        _ = ReleaseDC(hwnd, hdc)

    def _write_dump(mut self, rows: List[UInt8]) raises:
        var create_file = win32[
            def (
                Pointer[UInt16, MutAnyOrigin],
                UInt32,
                UInt32,
                Int,
                UInt32,
                UInt32,
                Int,
            ) thin abi("C") -> Int,
            "CreateFileW",
        ]()
        var wide = List[UInt16](length=self.dump_path.byte_length() + 1, fill=0)
        var i = 0
        for byte in self.dump_path.as_bytes():
            wide[i] = UInt16(byte)
            i += 1
        var handle = create_file(
            wide.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            UInt32(0x40000000),  # GENERIC_WRITE
            0,
            0,
            UInt32(2),  # CREATE_ALWAYS
            UInt32(0x80),  # FILE_ATTRIBUTE_NORMAL
            0,
        )
        if handle == -1 or handle == 0:
            raise Error("dump: could not open " + String(self.dump_path))
        var write_file = win32[
            def (
                Int,
                Pointer[UInt8, ImmUnsafeAnyOrigin],
                UInt32,
                Pointer[UInt32, MutAnyOrigin],
                Int,
            ) thin abi("C") -> c_int,
            "WriteFile",
        ]()
        var written = UInt32(0)
        _ = write_file(
            handle,
            rows.unsafe_ptr().as_imm().unsafe_origin_cast[ImmUnsafeAnyOrigin](),
            UInt32(len(rows)),
            com_addr(written),
            0,
        )
        var close_handle = win32[
            def (Int) thin abi("C") -> c_int, "CloseHandle"
        ]()
        _ = close_handle(handle)

