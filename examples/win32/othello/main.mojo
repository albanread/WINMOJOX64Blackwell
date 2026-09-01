# ===----------------------------------------------------------------------=== #
# Othello on a green felt board, with four computer players -- a native Win32
# version, in Mojo, ported from the Cocoa original.
#
# A port of a Common Lisp demo, and an excuse to answer a question honestly:
# where does a GPU help a board game, and where does it not?
#
#   * Alpha-beta does NOT want a GPU. Its whole advantage is skipping branches
#     that cannot matter, which makes the work each thread does depend on what
#     the others found -- the opposite of what the hardware is for. Four ply on
#     an 8x8 board is 143 microseconds of CPU here. Nothing to accelerate.
#
#   * Monte-Carlo playouts DO. Play the position out at random a few thousand
#     times per candidate move and count the wins: every game is independent,
#     holds its whole state in two registers, and runs the same instructions as
#     its neighbours. Measured on this machine, 16,384 playouts take 485 ms on
#     the CPU and 9 ms on the T1000 -- 49x, and the difference between a strong
#     player that stalls and one that answers while your hand is still on the
#     mouse. (Built with optimisation those become 57 ms and 1.7 ms: 34x. The
#     host flag reaches the CPU player and not the PTX kernel, so the ratio
#     depends on the build and the README quotes both.)
#
# So the Master level is a GPU player and the others are not, which is the
# useful answer rather than the flattering one. `--selftest` measures all of
# that on the machine it is run on rather than asking you to believe the
# paragraph above, and checks the rules against the published perft numbers
# first -- a move generator that is subtly wrong plays a game that looks
# entirely normal.
#
# The board is drawn into a BGRA buffer and pushed into the window's device
# context by StretchDIBits, exactly as `life/` does: no swap chain, no D3D
# device, no COM, nothing that can be lost and need recreating. The two status
# lines are GDI text drawn on top of that blit, which is the one thing the
# pixel buffer is a bad tool for.
#
# The loop is a hand-rolled PeekMessageW pump rather than the blocking
# GetMessageW loop `life/` uses, for the reason `fluid/` gives: the pump owns
# the CUDA context and its two buffers as ordinary locals, so the window
# procedure -- which Windows calls, and which can therefore capture nothing --
# never has to reach a DeviceContext. The procedure paints and nothing else.
#
# Every Windows-shaped thing here -- which DLL exports each entry point, every
# constant, the size of PAINTSTRUCT -- is a query against windows_api.db. There
# is not a hand-declared DLL name, message number, or struct size in the file.
#
# Run it:
#     othello.exe                 you are black, white is Advanced
#     othello.exe --selftest      perft, CPU-vs-GPU agreement, timings; no
#                                 window, and a nonzero exit if anything fails
#     othello.exe --match 6       six games, Master (GPU) vs Advanced, no window
#     othello.exe --demo          the window, with the computer playing both
#     othello.exe --ms N          close after N ms, reading the window's own
#                                 pixels back first and comparing them to the
#                                 buffer we computed
#     othello.exe --no-gpu        pretend there is no CUDA device
#     othello.exe --level N       start at level N (0 Beginner .. 3 Master)
# ===----------------------------------------------------------------------=== #

from std.ffi import c_int
from std.math import sqrt
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.python._cpython import _fn_ptr_as_opaque
from std.sys import argv
from std.sys.info import size_of
from std.sys._com import com_addr
from std.sys._win32 import Win32Module
from std.sys._winkb import (
    winkb_constant,
    winkb_db_schema_version,
    winkb_function_dll,
    winkb_struct_size,
)
from std.windows import performance_counter, performance_frequency

from examples.win32.othello.board import (
    bit,
    flips_for,
    legal_moves,
    lowest,
    perft,
    perft_expected,
    popcount,
    square,
    start_black,
    start_white,
)
from examples.win32.othello.ai import (
    GpuPlayouts,
    LEVEL_ADVANCED,
    LEVEL_BEGINNER,
    LEVEL_INTERMEDIATE,
    LEVEL_MASTER,
    PLAYOUTS_PER_MOVE,
    best_by_playouts_cpu,
    best_by_search,
    level_name,
    next_random,
    nth_bit,
    open_gpu,
    playout,
)


# The board is drawn at one buffer pixel per screen pixel and the window is not
# resizable, so a click maps to a square by division and the GDI text below the
# board lands where this file says it does. `life/` stretches its buffer to the
# client rectangle instead, which is right for a picture and wrong for a board:
# a half-scaled disc is ugly and a stretched font is worse.
comptime CELL = 64
comptime MARGIN = 24
comptime BOARD = CELL * 8  # 512
comptime STATUS_H = 62
comptime WIN_W = BOARD + MARGIN * 2  # 560
comptime WIN_H = MARGIN + BOARD + STATUS_H  # 598
comptime PIXELS = WIN_W * WIN_H

comptime DISC_R = Float32(CELL) * 0.42
comptime HINT_R = Float32(7.0)
comptime STATUS_LINE_1 = MARGIN + BOARD + 12
comptime STATUS_LINE_2 = MARGIN + BOARD + 38
comptime LINE_CAP = 128  # UTF-16 units per status line

comptime TICK_TIMER_ID = 1

# Master on the CPU gets eight times fewer playouts than Master on the GPU.
# That is not a fudge to make the GPU look good -- it is what fits in the time
# a person will wait for a move, and it is exactly the point the example makes.
comptime CPU_PLAYOUTS = 512


# ===----------------------------------------------------------------------=== #
# Entry points, typed, from whichever DLL the metadata names.
# ===----------------------------------------------------------------------=== #


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
    """The same, for text built at run time.

    One byte to one unit would be Latin-1 rather than UTF-8, so this walks
    codepoints and encodes anything above the basic plane as a surrogate pair.
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


# ===----------------------------------------------------------------------=== #
# Structures. Layouts are asserted against Windows at compile time; claiming
# TrivialRegisterPassable on any of these would not fail to compile, it would
# silently write fields to the wrong places.
# ===----------------------------------------------------------------------=== #


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


@fieldwise_init
struct BITMAPINFOHEADER(Defaultable, Copyable, Movable):
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
struct Scene(Defaultable, Copyable, Movable):
    """Everything the window procedure is allowed to know.

    The procedure paints: the finished pixels, the two lines of text under the
    board, and the fonts to draw them with. It knows nothing about the game,
    the search or the GPU -- the pump owns all three as locals, which is the
    whole reason for the pump.

    Addresses rather than pointers because `Pointer` is non-nullable, so an
    address of zero cannot be spelled; they become pointers where they are used.
    """

    var pixels: Int  # UInt32*, WIN_W x WIN_H, BGRA
    var line1: Int  # UInt16*, the score and level
    var count1: Int
    var line2: Int  # UInt16*, what just happened
    var count2: Int
    var font1: Int  # HFONT
    var font2: Int  # HFONT
    var painted: Int

    def __init__(out self):
        self.pixels = 0
        self.line1 = 0
        self.count1 = 0
        self.line2 = 0
        self.count2 = 0
        self.font1 = 0
        self.font2 = 0
        self.painted = 0


comptime ScenePtr = Pointer[Scene, MutAnyOrigin]
comptime Ptr32 = Pointer[UInt32, MutUntrackedOrigin]
comptime Ptr16 = Pointer[UInt16, MutUntrackedOrigin]


def dwords_at(addr: Int) -> Ptr32:
    """Memory Windows and the allocator own, not Mojo -- hence Untracked."""
    return Ptr32(unsafe_from_address=addr)


def words_at(addr: Int) -> Ptr16:
    return Ptr16(unsafe_from_address=addr)


# ===----------------------------------------------------------------------=== #
# Colour
# ===----------------------------------------------------------------------=== #


def chan(v: Int) -> UInt32:
    """One colour channel, clamped. The ramps below run past both ends."""
    if v < 0:
        return UInt32(0)
    if v > 255:
        return UInt32(255)
    return UInt32(v)


def pack(b: Int, g: Int, r: Int) -> UInt32:
    """One BGRA pixel as a little-endian 32-bit word: 0xAARRGGBB."""
    return chan(b) | (chan(g) << 8) | (chan(r) << 16) | (UInt32(255) << 24)


def mix(under: UInt32, over: UInt32, alpha: Int) -> UInt32:
    """`over` laid on `under` at alpha/256. Used for anti-aliased edges,
    disc shading, shadows and the translucent move hints -- one operation
    covers all four, so the disc rasteriser below needs no special cases."""
    var a = alpha
    if a <= 0:
        return under
    if a >= 256:
        return over
    var inv = 256 - a
    var b = (Int(under & 0xFF) * inv + Int(over & 0xFF) * a) >> 8
    var g = (Int((under >> 8) & 0xFF) * inv + Int((over >> 8) & 0xFF) * a) >> 8
    var r = (
        Int((under >> 16) & 0xFF) * inv + Int((over >> 16) & 0xFF) * a
    ) >> 8
    return pack(b, g, r)


def chrome() -> UInt32:
    return pack(24, 22, 20)


def felt_at(x: Int, y: Int) -> UInt32:
    """The green felt: a base colour, darkened towards the edges, dithered.

    The vignette and the dither are what stop 262,144 identical pixels from
    reading as a flat green rectangle. Both are cheap and both are computed
    once, into the background buffer, not per frame.
    """
    var half = Float32(BOARD // 2)
    var dx = (Float32(x) - Float32(MARGIN) - half) / half
    var dy = (Float32(y) - Float32(MARGIN) - half) / half
    var shade = Float32(1.0) - Float32(0.13) * (dx * dx + dy * dy)
    # A hash of the position, not a random number: the felt must look the same
    # every time the background is rebuilt, or a rebuild would flicker.
    var h = (UInt32(x) * UInt32(73856093)) ^ (UInt32(y) * UInt32(19349663))
    var n = Int((h >> 7) % UInt32(7)) - 3
    return pack(
        Int(Float32(60) * shade) + n,
        Int(Float32(110) * shade) + n,
        Int(Float32(45) * shade) + n,
    )


# ===----------------------------------------------------------------------=== #
# Drawing
# ===----------------------------------------------------------------------=== #


def cell_centre(row: Int, col: Int) -> Tuple[Float32, Float32]:
    return (
        Float32(MARGIN + col * CELL) + Float32(CELL) * 0.5,
        Float32(MARGIN + row * CELL) + Float32(CELL) * 0.5,
    )


def fill_disc(
    frame: Ptr32,
    cx: Float32,
    cy: Float32,
    r: Float32,
    edge: UInt32,
    centre: UInt32,
    strength: Int,
):
    """An anti-aliased disc, shaded from `centre` to `edge` by a light source
    up and to the left.

    Coverage is the signed distance to the rim clamped into one pixel, which
    is the cheapest thing that does not look like a staircase. The shading is
    what makes a disc read as a piece rather than a circle: a flat black
    ellipse on green felt looks like a hole in the board.

    Args:
        frame: The BGRA buffer.
        cx: Centre, x.
        cy: Centre, y.
        r: Radius in pixels.
        edge: Colour at the rim.
        centre: Colour under the highlight.
        strength: Overall opacity, 0 to 256 -- 256 for a disc, less for a
            shadow or a hint.
    """
    var x0 = Int(cx - r) - 1
    var x1 = Int(cx + r) + 2
    var y0 = Int(cy - r) - 1
    var y1 = Int(cy + r) + 2
    if x0 < 0:
        x0 = 0
    if y0 < 0:
        y0 = 0
    if x1 > WIN_W:
        x1 = WIN_W
    if y1 > WIN_H:
        y1 = WIN_H

    for y in range(y0, y1):
        var row = y * WIN_W
        for x in range(x0, x1):
            var dx = Float32(x) + Float32(0.5) - cx
            var dy = Float32(y) + Float32(0.5) - cy
            var d = sqrt(dx * dx + dy * dy)
            var cov = r + Float32(0.5) - d
            if cov <= Float32(0):
                continue
            if cov > Float32(1):
                cov = Float32(1)
            # Distance from a highlight sitting above and left of centre.
            var hx = dx + r * Float32(0.34)
            var hy = dy + r * Float32(0.38)
            var t = Float32(1) - sqrt(hx * hx + hy * hy) / (r * Float32(1.3))
            if t < Float32(0):
                t = Float32(0)
            var col = mix(edge, centre, Int(t * t * Float32(256.0)))
            var a = Int(cov * Float32(strength))
            frame[unsafe_offset = row + x] = mix(
                frame[unsafe_offset = row + x], col, a
            )


def stroke_ring(
    frame: Ptr32, cx: Float32, cy: Float32, r: Float32, col: UInt32
):
    """A one-and-a-half pixel ring, anti-aliased the same way -- the marker
    on the square the computer has just played."""
    var x0 = Int(cx - r) - 2
    var x1 = Int(cx + r) + 3
    var y0 = Int(cy - r) - 2
    var y1 = Int(cy + r) + 3
    if x0 < 0:
        x0 = 0
    if y0 < 0:
        y0 = 0
    if x1 > WIN_W:
        x1 = WIN_W
    if y1 > WIN_H:
        y1 = WIN_H
    for y in range(y0, y1):
        var row = y * WIN_W
        for x in range(x0, x1):
            var dx = Float32(x) + Float32(0.5) - cx
            var dy = Float32(y) + Float32(0.5) - cy
            var d = sqrt(dx * dx + dy * dy) - r
            if d < Float32(0):
                d = -d
            var cov = Float32(1.4) - d
            if cov <= Float32(0):
                continue
            if cov > Float32(1):
                cov = Float32(1)
            frame[unsafe_offset = row + x] = mix(
                frame[unsafe_offset = row + x], col, Int(cov * Float32(230.0))
            )


def build_background(bg: Ptr32):
    """The chrome, the felt, the grid and the four star points -- everything
    that never changes.

    Built once and copied over the frame buffer at the start of every redraw.
    A move changes at most a dozen squares, but recomputing the vignette and
    the dither for a quarter of a million pixels on every move would be the
    most expensive thing in the program by a wide margin.
    """
    var back = chrome()
    for i in range(PIXELS):
        bg[unsafe_offset=i] = back

    # A dark surround under the felt, so the board has an edge rather than
    # dissolving into the window background.
    var surround = pack(30, 40, 26)
    for y in range(MARGIN - 4, MARGIN + BOARD + 4):
        for x in range(MARGIN - 4, MARGIN + BOARD + 4):
            bg[unsafe_offset = y * WIN_W + x] = surround

    for y in range(MARGIN, MARGIN + BOARD):
        for x in range(MARGIN, MARGIN + BOARD):
            bg[unsafe_offset = y * WIN_W + x] = felt_at(x, y)

    # Grid lines darken the felt rather than replacing it, so the vignette
    # runs through them and they do not read as a separate object.
    var ink = pack(0, 0, 0)
    for i in range(9):
        var o = i * CELL
        for k in range(BOARD):
            var vx = MARGIN + o
            if vx >= MARGIN + BOARD:
                vx = MARGIN + BOARD - 1
            var vi = (MARGIN + k) * WIN_W + vx
            bg[unsafe_offset=vi] = mix(bg[unsafe_offset=vi], ink, 80)
            var hy = MARGIN + o
            if hy >= MARGIN + BOARD:
                hy = MARGIN + BOARD - 1
            var hi = hy * WIN_W + MARGIN + k
            bg[unsafe_offset=hi] = mix(bg[unsafe_offset=hi], ink, 80)

    # The four star points a real board has, at the corners of the middle
    # sixteen squares.
    for a in range(2):
        for b in range(2):
            var col = 2 + a * 4
            var row = 2 + b * 4
            fill_disc(
                bg,
                Float32(MARGIN + col * CELL),
                Float32(MARGIN + row * CELL),
                Float32(3.5),
                ink,
                ink,
                150,
            )


def render(
    bg: Ptr32,
    frame: Ptr32,
    black: UInt64,
    white: UInt64,
    hints: UInt64,
    last: UInt64,
):
    """One picture of the position.

    Shadows are drawn for every disc before any disc is drawn. Done per disc
    they would fall on top of the neighbour drawn just before, which on a
    crowded board is most of them.
    """
    for i in range(PIXELS):
        frame[unsafe_offset=i] = bg[unsafe_offset=i]

    var occupied = black | white
    var shadow = pack(0, 0, 0)
    for i in range(64):
        if (occupied & bit(i)) != 0:
            var c = cell_centre(i // 8, i % 8)
            fill_disc(
                frame, c[0] + 2.0, c[1] + 3.0, DISC_R, shadow, shadow, 70
            )

    for i in range(64):
        var m = bit(i)
        var c = cell_centre(i // 8, i % 8)
        if (black & m) != 0:
            fill_disc(
                frame, c[0], c[1], DISC_R, pack(16, 14, 14), pack(86, 84, 92)
            , 256)
        elif (white & m) != 0:
            fill_disc(
                frame,
                c[0],
                c[1],
                DISC_R,
                pack(196, 200, 206),
                pack(248, 250, 252),
                256,
            )
        elif (hints & m) != 0:
            # Small, so it reads as advice rather than as a disc already down.
            var hint = pack(120, 190, 150)
            fill_disc(frame, c[0], c[1], HINT_R, hint, hint, 150)

    if last != 0:
        for i in range(64):
            if (last & bit(i)) != 0:
                var c = cell_centre(i // 8, i % 8)
                stroke_ring(
                    frame, c[0], c[1], DISC_R + Float32(3.0), pack(70, 190, 240)
                )


def store_line(dst: Int, text: String) -> Int:
    """Encode a status line into its fixed UTF-16 buffer.

    Fixed, and written in place, because the window procedure reads it during
    WM_PAINT and Windows decides when that happens: a `List` rebuilt on the
    pump's side would move the storage under the painter.

    Returns:
        The number of UTF-16 units, which is what TextOutW wants.
    """
    var p = words_at(dst)
    var n = 0
    for c in text.codepoints():
        var v = Int(c)
        if v >= 0x10000:
            if n + 2 >= LINE_CAP:
                break
            var u = v - 0x10000
            p[unsafe_offset=n] = UInt16(0xD800 + (u >> 10))
            p[unsafe_offset = n + 1] = UInt16(0xDC00 + (u & 0x3FF))
            n += 2
        else:
            if n + 1 >= LINE_CAP:
                break
            p[unsafe_offset=n] = UInt16(v)
            n += 1
    p[unsafe_offset=n] = 0
    return n


# ===----------------------------------------------------------------------=== #
# Getting the buffer onto the window
# ===----------------------------------------------------------------------=== #


def blit(hdc: Int, pixels: Int, dest_w: Int, dest_h: Int) raises:
    """Push the CPU buffer into a device context."""
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
    bmi.biWidth = Int32(WIN_W)
    # A NEGATIVE height asks GDI for a top-down DIB: row 0 is the top row,
    # which is the order the board is computed in. Positive means bottom-up,
    # and the picture arrives upside down -- which for an 8x8 board that is
    # nearly symmetric is a bug you can stare straight through.
    bmi.biHeight = Int32(-WIN_H)
    bmi.biPlanes = 1
    bmi.biBitCount = 32
    bmi.biCompression = UInt32(winkb_constant["BI_RGB"]())

    _ = StretchDIBits(
        hdc,
        c_int(0), c_int(0), c_int(dest_w), c_int(dest_h),
        c_int(0), c_int(0), c_int(WIN_W), c_int(WIN_H),
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=pixels),
        com_addr(bmi),
        UInt32(winkb_constant["DIB_RGB_COLORS"]()),
        UInt32(winkb_constant["SRCCOPY"]()),
    )
    _ = bmi


def draw_status(hdc: Int, scene: ScenePtr, scale_x: Int, scale_y: Int) raises:
    """The two lines under the board, as GDI text on top of the blit.

    Text is the one thing a hand-written rasteriser has no business doing: a
    font, hinting and ClearType are already in the box, and TextOutW on the
    device context the blit just wrote to composites over it correctly.
    """
    var SetBkMode = win32[
        def (Int, c_int) thin abi("C") -> c_int, "SetBkMode"
    ]()
    var SetTextColor = win32[
        def (Int, UInt32) thin abi("C") -> UInt32, "SetTextColor"
    ]()
    var SelectObject = win32[
        def (Int, Int) thin abi("C") -> Int, "SelectObject"
    ]()
    var TextOutW = win32[
        def (
            Int, c_int, c_int, Pointer[UInt16, MutAnyOrigin], c_int
        ) thin abi("C") -> c_int,
        "TextOutW",
    ]()

    _ = SetBkMode(hdc, c_int(winkb_constant["TRANSPARENT"]()))
    var old = 0
    if scene[].font1 != 0:
        old = SelectObject(hdc, scene[].font1)
    # COLORREF is 0x00BBGGRR -- the opposite order to the BGRA words above,
    # which is a fine way to spend twenty minutes wondering why the text is
    # blue.
    _ = SetTextColor(hdc, UInt32(0x00E6EFF2))
    _ = TextOutW(
        hdc,
        c_int(MARGIN * scale_x // WIN_W),
        c_int(STATUS_LINE_1 * scale_y // WIN_H),
        Pointer[UInt16, MutAnyOrigin](unsafe_from_address=scene[].line1),
        c_int(scene[].count1),
    )
    if scene[].font2 != 0:
        _ = SelectObject(hdc, scene[].font2)
    _ = SetTextColor(hdc, UInt32(0x00A0B0A8))
    _ = TextOutW(
        hdc,
        c_int(MARGIN * scale_x // WIN_W),
        c_int(STATUS_LINE_2 * scale_y // WIN_H),
        Pointer[UInt16, MutAnyOrigin](unsafe_from_address=scene[].line2),
        c_int(scene[].count2),
    )
    if old != 0:
        _ = SelectObject(hdc, old)


# ===----------------------------------------------------------------------=== #
# The window procedure. Windows calls this, so it is a captureless C-ABI
# function that must never raise -- unwinding through a Windows frame is
# undefined -- and every failure is caught here.
#
# It paints and it closes. Input is read in the pump instead, which is what
# keeps the CUDA context an ordinary local in `main`.
# ===----------------------------------------------------------------------=== #

comptime WndProcType = def (Int, UInt32, Int, Int) thin abi("C") -> Int


@export("othello_wndproc")
def othello_wndproc(
    hwnd: Int, message: UInt32, wparam: Int, lparam: Int
) abi("C") -> Int:
    try:
        # Refuse the background erase: the whole client area is redrawn every
        # paint, and letting GDI clear it first is what makes it flicker.
        if message == UInt32(winkb_constant["WM_ERASEBKGND"]()):
            return 1

        if message == UInt32(winkb_constant["WM_PAINT"]()):
            var GetWindowLongPtrW = win32[
                def (Int, c_int) thin abi("C") -> Int, "GetWindowLongPtrW"
            ]()
            var BeginPaint = win32[
                def (Int, Pointer[UInt8, MutAnyOrigin]) thin abi("C") -> Int,
                "BeginPaint",
            ]()
            var EndPaint = win32[
                def (Int, Pointer[UInt8, MutAnyOrigin]) thin abi("C") -> c_int,
                "EndPaint",
            ]()
            var GetClientRect = win32[
                def (
                    Int, Pointer[RECT, MutAnyOrigin]
                ) thin abi("C") -> c_int,
                "GetClientRect",
            ]()
            var stored = GetWindowLongPtrW(
                hwnd, c_int(winkb_constant["GWLP_USERDATA"]())
            )
            # PAINTSTRUCT is never declared here, only sized, from the
            # metadata -- it is a box this code never looks inside.
            var ps = List[UInt8](
                length = winkb_struct_size["PAINTSTRUCT"](), fill=0
            )
            var ps_ptr = ps.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
            var hdc = BeginPaint(hwnd, ps_ptr)
            if stored != 0 and hdc != 0:
                var scene = ScenePtr(unsafe_from_address=stored)
                if scene[].pixels != 0:
                    var rc = RECT()
                    _ = GetClientRect(hwnd, com_addr(rc))
                    var w = Int(rc.right - rc.left)
                    var h = Int(rc.bottom - rc.top)
                    blit(hdc, scene[].pixels, w, h)
                    draw_status(hdc, scene, w, h)
                    scene[].painted += 1
            # BeginPaint cleared the update region; EndPaint closes it. Skip
            # both and Windows re-sends WM_PAINT immediately, forever.
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
            # This is what puts WM_QUIT on the queue and ends the pump. A
            # window that closes but whose process hangs is always a missing
            # PostQuitMessage.
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
# The game, as the pump sees it
# ===----------------------------------------------------------------------=== #


def settle_turn(
    black: UInt64, white: UInt64, turn_in: Bool
) -> Tuple[Bool, Bool]:
    """Pass for a player with no move, and end the game when neither has one.

    Returns:
        (whose turn it is now, whether the game is over).
    """
    var turn = turn_in
    for _ in range(2):
        var own = black if turn else white
        var opp = white if turn else black
        if legal_moves(own, opp) != 0:
            return (turn, False)
        if legal_moves(opp, own) == 0:
            return (turn, True)
        turn = not turn
    return (turn, False)


def square_name(move: UInt64) -> String:
    """The square in the notation everybody writes Othello games in: columns
    a to h from the left, rows 1 to 8 from the top."""
    for i in range(64):
        if (move & bit(i)) != 0:
            var col = i % 8
            var row = i // 8
            return String(chr(ord("a") + col)) + String(row + 1)
    return String("--")


def computer_move_cpu(
    black: UInt64, white: UInt64, black_to_move: Bool, level: Int, seed: UInt64
) -> UInt64:
    """Everything but Master-with-a-GPU, which needs the context the pump owns.
    """
    var own = black if black_to_move else white
    var opp = white if black_to_move else black
    if level == LEVEL_BEGINNER:
        var moves = legal_moves(own, opp)
        if moves == 0:
            return 0
        var count = popcount(moves)
        return nth_bit(moves, Int(next_random(seed | 1) % UInt64(count)))
    if level == LEVEL_INTERMEDIATE:
        return best_by_search(own, opp, 3, False)
    if level == LEVEL_ADVANCED:
        return best_by_search(own, opp, 4, True)
    # Master with no GPU: the same playouts, eight times fewer of them.
    return best_by_playouts_cpu(black, white, black_to_move, seed, CPU_PLAYOUTS)


def choose_move(
    gpu: Optional[GpuPlayouts],
    black: UInt64,
    white: UInt64,
    black_to_move: Bool,
    level: Int,
    seed: UInt64,
) raises -> UInt64:
    """The one place that decides which of the four players is thinking.

    The window's pump and the headless match door both come through here, so
    "Master" cannot mean the GPU in one and something else in the other.

    Args:
        gpu: The device, if this machine has one.
        black: Black's discs.
        white: White's discs.
        black_to_move: Whose move this is.
        level: Which player is choosing.
        seed: This move's random stream.

    Returns:
        One bit, or zero when the player has no move.
    """
    if level == LEVEL_MASTER:
        if gpu:
            return gpu.value().best(black, white, black_to_move, seed)
        return best_by_playouts_cpu(
            black, white, black_to_move, seed, CPU_PLAYOUTS
        )
    return computer_move_cpu(black, white, black_to_move, level, seed)


# ===----------------------------------------------------------------------=== #
# Evidence
#
# A game that looks normal is not evidence that the rules are right, and a
# picture that looks right is not evidence that it reached the screen. Three
# separate checks, none of which can be passed by a program that merely fails
# quietly.
# ===----------------------------------------------------------------------=== #


def run_selftest(use_gpu: Bool) raises -> Int:
    """The rules, the two players, and the timings the argument rests on.

    Returns:
        The number of checks that failed.
    """
    var bad = 0
    var hz = performance_frequency()

    print("rules -- perft from the opening position:")
    var b = start_black()
    var w = start_white()
    for depth in range(1, 8):
        var t0 = performance_counter()
        var got = perft(b, w, depth)
        var us = (performance_counter() - t0) * 1000000 // hz
        var want = perft_expected(depth)
        var ok = got == want
        if not ok:
            bad += 1
        print(
            "  perft",
            depth,
            "=",
            got,
            " expected",
            want,
            " ",
            "ok" if ok else "FAIL",
            " (",
            us,
            "us )",
        )

    print()
    print("search -- alpha-beta, the level that does not want a GPU:")
    for depth in range(3, 7):
        var t0 = performance_counter()
        var mv = best_by_search(b, w, depth, True)
        var us = (performance_counter() - t0) * 1000000 // hz
        print("  depth", depth, "->", square_name(mv), " ", us, "us")

    print()
    print("playouts -- the level that does:")
    var seed = UInt64(0x1234_5678_9ABC_DEF1)
    var t0 = performance_counter()
    var cpu_move = best_by_playouts_cpu(b, w, True, seed, PLAYOUTS_PER_MOVE)
    var cpu_us = (performance_counter() - t0) * 1000000 // hz
    var moves = popcount(legal_moves(b, w))
    print(
        "  CPU ",
        moves * PLAYOUTS_PER_MOVE,
        "playouts ->",
        square_name(cpu_move),
        " ",
        cpu_us // 1000,
        "ms",
    )

    if not use_gpu:
        print("  GPU  skipped (--no-gpu)")
        return bad

    var maybe = open_gpu()
    if not maybe:
        print("  GPU  no CUDA device -- Master would fall back to the CPU")
        return bad

    print("  GPU ", maybe.value().name())
    # The first launch pays for the PTX build, which is not what the timing
    # below is about; and one launch on a GPU this small is dominated by
    # whether the clocks happened to be boosted, so time five and divide.
    var gpu_move = maybe.value().best(b, w, True, seed)
    var t1 = performance_counter()
    for _ in range(5):
        _ = maybe.value().best(b, w, True, seed)
    var gpu_us = (performance_counter() - t1) * 1000000 // hz // 5
    # One decimal place, by hand: this is the number the whole example is
    # about, and "40x" versus "4x" is the difference between an argument and
    # a rounding error.
    var ratio = cpu_us * 10 // gpu_us
    print(
        "  GPU ",
        moves * PLAYOUTS_PER_MOVE,
        "playouts ->",
        square_name(gpu_move),
        " ",
        gpu_us // 1000,
        "ms   speedup",
        String(ratio // 10) + "." + String(ratio % 10) + "x",
    )

    # The cheap correctness check worth doing whenever the same algorithm
    # exists twice: two different machines, the same dice, the same answer.
    var agree = gpu_move == cpu_move
    print("  both pick the same move:", "ok" if agree else "FAIL")
    if not agree:
        bad += 1

    # And the same thing from three midgame positions, because the opening is
    # symmetric and a bug that ignores half the board can survive it.
    var probe_black = b
    var probe_white = w
    var turn = True
    var rng = UInt64(99991)
    for step in range(9):
        rng = next_random(rng)
        var own = probe_black if turn else probe_white
        var opp = probe_white if turn else probe_black
        var ms = legal_moves(own, opp)
        if ms == 0:
            break
        var pick = nth_bit(ms, Int(rng % UInt64(popcount(ms))))
        var f = flips_for(own, opp, pick)
        if turn:
            probe_black = probe_black | pick | f
            probe_white = probe_white ^ f
        else:
            probe_white = probe_white | pick | f
            probe_black = probe_black ^ f
        turn = not turn
        if step % 3 == 2:
            var g = maybe.value().best(probe_black, probe_white, turn, rng)
            var c = best_by_playouts_cpu(
                probe_black, probe_white, turn, rng, PLAYOUTS_PER_MOVE
            )
            var same = g == c
            print(
                "  after",
                step + 1,
                "random moves, both pick",
                square_name(g),
                "/",
                square_name(c),
                " ",
                "ok" if same else "FAIL",
            )
            if not same:
                bad += 1
    return bad


def play_one_game(
    gpu: Optional[GpuPlayouts], seed: UInt64, verbose: Bool
) raises -> Int:
    """Master (black) against Advanced (white). Returns black's margin."""
    var black = start_black()
    var white = start_white()
    var turn = True
    var rng = seed | 1
    var over = False
    while not over:
        var settled = settle_turn(black, white, turn)
        turn = settled[0]
        over = settled[1]
        if over:
            break
        rng = next_random(rng)
        var move = choose_move(
            gpu,
            black,
            white,
            turn,
            LEVEL_MASTER if turn else LEVEL_ADVANCED,
            rng,
        )
        if move == 0:
            break
        var own = black if turn else white
        var opp = white if turn else black
        var f = flips_for(own, opp, move)
        if turn:
            black = black | move | f
            white = white ^ f
        else:
            white = white | move | f
            black = black ^ f
        turn = not turn
    var b = popcount(black)
    var w = popcount(white)
    if verbose:
        print("    black", b, " white", w)
    return b - w


def run_match(games: Int, use_gpu: Bool) raises:
    """The claim the Mac README makes -- that the playout player is not just
    faster but stronger -- played out rather than asserted."""
    var maybe = Optional[GpuPlayouts]()
    if use_gpu:
        maybe = open_gpu()
    if maybe:
        print("Master (GPU playouts,", PLAYOUTS_PER_MOVE, "per move) vs"
              " Advanced (alpha-beta, 4 ply)")
        print("  on", maybe.value().name())
    else:
        print("Master (CPU playouts,", CPU_PLAYOUTS, "per move) vs"
              " Advanced (alpha-beta, 4 ply)")
    var hz = performance_frequency()
    var t0 = performance_counter()
    var wins = 0
    var losses = 0
    var draws = 0
    for g in range(games):
        var margin = play_one_game(maybe, UInt64(g * 7919 + 13), False)
        if margin > 0:
            wins += 1
        elif margin < 0:
            losses += 1
        else:
            draws += 1
        print("  game", g + 1, ": Master by", margin, "discs")
    var ms = (performance_counter() - t0) * 1000 // hz
    print(
        "  Master",
        wins,
        "-",
        losses,
        "Advanced  (",
        draws,
        "drawn ) in",
        ms,
        "ms",
    )


def readback(hwnd: Int, pixels: Int) raises:
    """Copy the window's own client area back out and compare it, pixel for
    pixel, with the buffer we computed.

    Not a count of lit pixels: the blit is 1:1 and GDI copies 32-bit BGRA
    verbatim, so over the board area the two must agree EXACTLY, and a check
    that demands exactness cannot be passed by a window that is showing
    something plausible. The status strip is excluded because GDI drew text
    over it after the blit -- that difference is the evidence the text landed.
    """
    var GetDC = win32[def (Int) thin abi("C") -> Int, "GetDC"]()
    var ReleaseDC = win32[def (Int, Int) thin abi("C") -> c_int, "ReleaseDC"]()
    var CreateCompatibleDC = win32[
        def (Int) thin abi("C") -> Int, "CreateCompatibleDC"
    ]()
    var DeleteDC = win32[def (Int) thin abi("C") -> c_int, "DeleteDC"]()
    var DeleteObject = win32[def (Int) thin abi("C") -> c_int, "DeleteObject"]()
    var SelectObject = win32[
        def (Int, Int) thin abi("C") -> Int, "SelectObject"
    ]()
    var CreateDIBSection = win32[
        def (
            Int,
            Pointer[BITMAPINFOHEADER, MutAnyOrigin],
            UInt32,
            Pointer[Int, MutAnyOrigin],
            Int,
            UInt32,
        ) thin abi("C") -> Int,
        "CreateDIBSection",
    ]()
    var BitBlt = win32[
        def (
            Int, c_int, c_int, c_int, c_int, Int, c_int, c_int, UInt32
        ) thin abi("C") -> c_int,
        "BitBlt",
    ]()
    var GetClientRect = win32[
        def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
        "GetClientRect",
    ]()

    var rc = RECT()
    _ = GetClientRect(hwnd, com_addr(rc))
    var w = Int(rc.right - rc.left)
    var h = Int(rc.bottom - rc.top)
    if w <= 0 or h <= 0:
        print("readback: no client area")
        return

    var windc = GetDC(hwnd)
    var memdc = CreateCompatibleDC(windc)
    var bmi = BITMAPINFOHEADER()
    bmi.biSize = UInt32(size_of[BITMAPINFOHEADER]())
    bmi.biWidth = Int32(w)
    bmi.biHeight = Int32(-h)
    bmi.biPlanes = 1
    bmi.biBitCount = 32
    bmi.biCompression = UInt32(winkb_constant["BI_RGB"]())
    var bits: Int = 0
    var hbmp = CreateDIBSection(
        windc,
        com_addr(bmi),
        UInt32(winkb_constant["DIB_RGB_COLORS"]()),
        com_addr(bits),
        0,
        0,
    )
    _ = bmi
    if hbmp == 0 or bits == 0:
        print("readback: CreateDIBSection failed")
        _ = DeleteDC(memdc)
        _ = ReleaseDC(hwnd, windc)
        return

    var old = SelectObject(memdc, hbmp)
    _ = BitBlt(
        memdc,
        c_int(0), c_int(0), c_int(w), c_int(h),
        windc,
        c_int(0), c_int(0),
        UInt32(winkb_constant["SRCCOPY"]()),
    )

    var got = dwords_at(bits)
    var want = dwords_at(pixels)
    print("readback: client", w, "x", h, " (buffer", WIN_W, "x", WIN_H, ")")
    if w != WIN_W or h != WIN_H:
        print("   not 1:1, so an exact comparison would be meaningless")
    else:
        var board_rows = MARGIN + BOARD
        var same = 0
        var differ = 0
        for y in range(board_rows):
            for x in range(WIN_W):
                var i = y * WIN_W + x
                if (Int(got[unsafe_offset=i]) & 0xFFFFFF) == (
                    Int(want[unsafe_offset=i]) & 0xFFFFFF
                ):
                    same += 1
                else:
                    differ += 1
        print("   board area:", same, "pixels identical,", differ, "different")
        if differ == 0:
            print("   the window is showing exactly the buffer we computed")
        else:
            print("   THE WINDOW IS NOT SHOWING WHAT WE COMPUTED")

        var text_pixels = 0
        for y in range(board_rows, h):
            for x in range(WIN_W):
                var i = y * WIN_W + x
                if (Int(got[unsafe_offset=i]) & 0xFFFFFF) != (
                    Int(want[unsafe_offset=i]) & 0xFFFFFF
                ):
                    text_pixels += 1
        print(
            "   status strip:",
            text_pixels,
            "pixels differ from the buffer -- that is the GDI text",
        )
        if text_pixels == 0:
            print("   NO TEXT WAS DRAWN")

    _ = SelectObject(memdc, old)
    _ = DeleteObject(hbmp)
    _ = DeleteDC(memdc)
    _ = ReleaseDC(hwnd, windc)


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
        size_of[BITMAPINFOHEADER]() == winkb_struct_size["BITMAPINFOHEADER"]()
    ), "BITMAPINFOHEADER does not match Windows"

    var selftest = False
    var demo = False
    var use_gpu = True
    var match_games = 0
    var close_ms = 0
    var level = LEVEL_ADVANCED
    var args = argv()
    for i in range(len(args)):
        if args[i] == "--selftest":
            selftest = True
        elif args[i] == "--demo":
            demo = True
        elif args[i] == "--no-gpu":
            use_gpu = False
        elif args[i] == "--match" and i + 1 < len(args):
            match_games = Int(args[i + 1])
        elif args[i] == "--ms" and i + 1 < len(args):
            close_ms = Int(args[i + 1])
        elif args[i] == "--level" and i + 1 < len(args):
            level = Int(args[i + 1])

    print("metadata schema:", winkb_db_schema_version())

    if selftest:
        var bad = run_selftest(use_gpu)
        print()
        if bad != 0:
            raise Error(String(bad) + " check(s) failed")
        print("all checks passed")
        return

    if match_games > 0:
        run_match(match_games, use_gpu)
        return

    # ── The GPU, if this machine has one ─────────────────────────────────
    # Master falls back to CPU playouts when it does not, which is worth doing
    # rather than hiding the level or refusing to start: three of the four
    # players never wanted a GPU in the first place.
    var gpu = Optional[GpuPlayouts]()
    if use_gpu:
        gpu = open_gpu()
    if gpu:
        print("GPU:", gpu.value().name(), "--", PLAYOUTS_PER_MOVE,
              "playouts per candidate move")
    else:
        print("GPU: none -- Master will play", CPU_PLAYOUTS,
              "CPU playouts per move instead")

    # ── DPI, before any window exists ────────────────────────────────────
    # Without this Windows lies to the process about the size of everything and
    # then bilinearly upscales whatever it draws, which would turn the
    # anti-aliased discs into blurred ones and break the 1:1 blit the click
    # mapping and the readback both depend on.
    var SetProcessDpiAwarenessContext = win32[
        def (Int) thin abi("C") -> c_int, "SetProcessDpiAwarenessContext"
    ]()
    if (
        SetProcessDpiAwarenessContext(
            winkb_constant["DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2"]()
        )
        == 0
    ):
        var SetProcessDPIAware = win32[
            def () thin abi("C") -> c_int, "SetProcessDPIAware"
        ]()
        _ = SetProcessDPIAware()

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
    var CreateFontW = win32[
        def (
            Int32, Int32, Int32, Int32, Int32,
            UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
            Pointer[UInt16, MutAnyOrigin],
        ) thin abi("C") -> Int,
        "CreateFontW",
    ]()
    var GetStockObject = win32[
        def (c_int) thin abi("C") -> Int, "GetStockObject"
    ]()
    var DeleteObject = win32[def (Int) thin abi("C") -> c_int, "DeleteObject"]()
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
    var SetWindowTextW = win32[
        def (Int, Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> c_int,
        "SetWindowTextW",
    ]()
    var GetClientRect = win32[
        def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
        "GetClientRect",
    ]()
    var GetWindowRect = win32[
        def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
        "GetWindowRect",
    ]()
    var SetWindowPos = win32[
        def (
            Int, Int, c_int, c_int, c_int, c_int, UInt32
        ) thin abi("C") -> c_int,
        "SetWindowPos",
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
    var WaitMessage = win32[def () thin abi("C") -> c_int, "WaitMessage"]()
    var DestroyWindow = win32[def (Int) thin abi("C") -> c_int, "DestroyWindow"]()
    var SetTimer = win32[
        def (Int, Int, UInt32, Int) thin abi("C") -> Int, "SetTimer"
    ]()
    var KillTimer = win32[def (Int, Int) thin abi("C") -> c_int, "KillTimer"]()

    # ── Buffers, on the heap ─────────────────────────────────────────────
    var bg_buf = unsafe_alloc[UInt32](PIXELS, alignment=64)
    var frame_buf = unsafe_alloc[UInt32](PIXELS, alignment=64)
    var line1_buf = unsafe_alloc[UInt16](LINE_CAP, alignment=8)
    var line2_buf = unsafe_alloc[UInt16](LINE_CAP, alignment=8)

    var store = unsafe_alloc[Scene](1, alignment=8)
    # Emplaced, not assigned: `store[] = value` would destroy what was there
    # first, and what is there is whatever the allocator last had.
    store.unsafe_write(Scene())
    var scene = ScenePtr(unsafe_from_address=Int(store))
    scene[].pixels = Int(frame_buf)
    scene[].line1 = Int(line1_buf)
    scene[].line2 = Int(line2_buf)
    scene[].count1 = store_line(Int(line1_buf), String("Othello"))
    scene[].count2 = store_line(Int(line2_buf), String("starting"))

    var bg = dwords_at(Int(bg_buf))
    var frame = dwords_at(Int(frame_buf))
    var hz = performance_frequency()
    var t_bg = performance_counter()
    build_background(bg)
    print(
        "background built in",
        (performance_counter() - t_bg) * 1000 // hz,
        "ms",
    )

    # ── The window ───────────────────────────────────────────────────────
    var hInstance = GetModuleHandleW(0)
    var class_name = wide("MojoOthelloWindow")
    var title = wide("Othello")

    # A `def` cannot be handed to Windows directly: it goes through a thin
    # C-ABI fn value first, and the named type is shared with DefWindowProcW
    # so the two cannot drift.
    var proc: WndProcType = othello_wndproc

    var wc = WNDCLASSEXW()
    wc.cbSize = UInt32(size_of[WNDCLASSEXW]())
    wc.style = UInt32(
        winkb_constant["CS_HREDRAW"]() | winkb_constant["CS_VREDRAW"]()
    )
    wc.lpfnWndProc = Int(_fn_ptr_as_opaque(proc))
    wc.hInstance = hInstance
    # A hand, because every click in this window is on something.
    wc.hCursor = LoadCursorW(0, winkb_constant["IDC_HAND"]())
    wc.lpszClassName = Int(class_name.unsafe_ptr())
    if RegisterClassExW(com_addr(wc)) == 0:
        raise Error(
            "RegisterClassExW failed, GetLastError = " + String(GetLastError())
        )

    # Not resizable: the blit is 1:1, the click mapping is a division, and the
    # GDI text is placed in buffer coordinates. Take the thick frame and the
    # maximise box out of WS_OVERLAPPEDWINDOW and all three stay true.
    comptime STYLE = winkb_constant["WS_OVERLAPPEDWINDOW"]() & ~(
        winkb_constant["WS_THICKFRAME"]() | winkb_constant["WS_MAXIMIZEBOX"]()
    )
    var want = RECT(Int32(0), Int32(0), Int32(WIN_W), Int32(WIN_H))
    _ = AdjustWindowRect(com_addr(want), UInt32(STYLE), c_int(0))

    var hwnd = CreateWindowExW(
        UInt32(0),
        class_name.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        title.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        UInt32(STYLE),
        c_int(90), c_int(60),
        c_int(Int(want.right - want.left)),
        c_int(Int(want.bottom - want.top)),
        0, 0, hInstance, 0,
    )
    if hwnd == 0:
        raise Error(
            "CreateWindowExW failed, GetLastError = " + String(GetLastError())
        )
    _ = class_name
    _ = title

    # AdjustWindowRect answers for the SYSTEM dpi, which is not necessarily
    # this window's monitor's, and the frame also depends on the theme. So
    # measure what actually came out and correct it once rather than trusting
    # the arithmetic -- that is what makes the blit exactly 1:1, and what lets
    # the readback demand an exact match instead of a plausible one.
    var have = RECT()
    _ = GetClientRect(hwnd, com_addr(have))
    var dw = WIN_W - Int(have.right - have.left)
    var dh = WIN_H - Int(have.bottom - have.top)
    if dw != 0 or dh != 0:
        var outer = RECT()
        _ = GetWindowRect(hwnd, com_addr(outer))
        _ = SetWindowPos(
            hwnd, 0, c_int(0), c_int(0),
            c_int(Int(outer.right - outer.left) + dw),
            c_int(Int(outer.bottom - outer.top) + dh),
            UInt32(
                winkb_constant["SWP_NOMOVE"]()
                | winkb_constant["SWP_NOZORDER"]()
                | winkb_constant["SWP_NOACTIVATE"]()
            ),
        )

    # Two fonts, because the score and the commentary want different weights.
    # A negative height is a character height rather than a cell height, which
    # is the one everybody means.
    var face = wide("Segoe UI")
    var face_ptr = face.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    scene[].font1 = CreateFontW(
        Int32(-19), Int32(0), Int32(0), Int32(0),
        Int32(winkb_constant["FW_BOLD"]()),
        UInt32(0), UInt32(0), UInt32(0),
        UInt32(winkb_constant["DEFAULT_CHARSET"]()),
        UInt32(winkb_constant["OUT_DEFAULT_PRECIS"]()),
        UInt32(winkb_constant["CLIP_DEFAULT_PRECIS"]()),
        UInt32(winkb_constant["CLEARTYPE_QUALITY"]()),
        UInt32(
            winkb_constant["VARIABLE_PITCH"]() | winkb_constant["FF_SWISS"]()
        ),
        face_ptr,
    )
    scene[].font2 = CreateFontW(
        Int32(-14), Int32(0), Int32(0), Int32(0), Int32(400),
        UInt32(0), UInt32(0), UInt32(0),
        UInt32(winkb_constant["DEFAULT_CHARSET"]()),
        UInt32(winkb_constant["OUT_DEFAULT_PRECIS"]()),
        UInt32(winkb_constant["CLIP_DEFAULT_PRECIS"]()),
        UInt32(winkb_constant["CLEARTYPE_QUALITY"]()),
        UInt32(
            winkb_constant["VARIABLE_PITCH"]() | winkb_constant["FF_SWISS"]()
        ),
        face_ptr,
    )
    _ = face
    # If the face is missing, the stock GUI font is still a font.
    if scene[].font1 == 0:
        scene[].font1 = GetStockObject(
            c_int(winkb_constant["DEFAULT_GUI_FONT"]())
        )
    if scene[].font2 == 0:
        scene[].font2 = scene[].font1

    _ = SetWindowLongPtrW(
        hwnd, c_int(winkb_constant["GWLP_USERDATA"]()), Int(store)
    )
    _ = ShowWindow(hwnd, c_int(winkb_constant["SW_SHOW"]()))
    _ = UpdateWindow(hwnd)

    # ── The game ─────────────────────────────────────────────────────────
    var black = start_black()
    var white = start_white()
    var black_turn = True
    var over = False
    var last_move = UInt64(0)
    var last_ms = 0
    var thinking = False
    var moves_played = 0
    var rng = UInt64(performance_counter()) | 1
    var need_draw = True

    print()
    print("You are black. Click a square with a dot on it.")
    print("N new game   B I A M level   D demo   Q or Esc quit")
    print("level:", level_name(level))
    if demo:
        print("demo: the computer plays both sides")

    # A deadline needs a wake-up: the pump otherwise blocks in WaitMessage
    # until somebody touches the window, and nobody is going to.
    var deadline = 0
    if close_ms > 0:
        deadline = performance_counter() + close_ms * hz // 1000
        _ = SetTimer(hwnd, TICK_TIMER_ID, UInt32(100), 0)

    comptime PM_REMOVE = UInt32(winkb_constant["PM_REMOVE"]())
    comptime WM_QUIT = UInt32(winkb_constant["WM_QUIT"]())
    comptime WM_KEYDOWN = UInt32(winkb_constant["WM_KEYDOWN"]())
    comptime WM_LBUTTONDOWN = UInt32(winkb_constant["WM_LBUTTONDOWN"]())

    var msg = MSG()
    var running = True
    var did_readback = False
    while running:
        while (
            PeekMessageW(com_addr(msg), 0, UInt32(0), UInt32(0), PM_REMOVE) != 0
        ):
            # PeekMessageW REMOVES WM_QUIT from the queue, so the loop has to
            # notice it here -- DispatchMessageW will not do it.
            if msg.message == WM_QUIT:
                running = False
                break

            if msg.message == WM_LBUTTONDOWN and not over and not demo:
                # lParam packs the point as two SIGNED 16-bit halves: a click
                # dragged in from the left reports a negative x, which read
                # unsigned becomes 65,000-odd.
                var px = msg.lParam & 0xFFFF
                if px >= 0x8000:
                    px -= 0x10000
                var py = (msg.lParam >> 16) & 0xFFFF
                if py >= 0x8000:
                    py -= 0x10000
                var col = (px - MARGIN) // CELL
                var row = (py - MARGIN) // CELL
                if (
                    black_turn
                    and col >= 0
                    and col < 8
                    and row >= 0
                    and row < 8
                    and px >= MARGIN
                    and py >= MARGIN
                ):
                    var m = square(row, col)
                    if (legal_moves(black, white) & m) != 0:
                        var f = flips_for(black, white, m)
                        black = black | m | f
                        white = white ^ f
                        black_turn = False
                        last_move = m
                        moves_played += 1
                        print("  black plays", square_name(m))
                        var s = settle_turn(black, white, black_turn)
                        black_turn = s[0]
                        over = s[1]
                        need_draw = True

            elif msg.message == WM_KEYDOWN:
                var key = msg.wParam
                if key == winkb_constant["VK_ESCAPE"]() or key == ord("Q"):
                    _ = DestroyWindow(hwnd)
                elif key == ord("N"):
                    black = start_black()
                    white = start_white()
                    black_turn = True
                    over = False
                    last_move = 0
                    last_ms = 0
                    moves_played = 0
                    need_draw = True
                    print("  new game")
                elif key == ord("D"):
                    demo = not demo
                    need_draw = True
                    print("  demo:", demo)
                elif key == ord("B"):
                    level = LEVEL_BEGINNER
                    need_draw = True
                elif key == ord("I"):
                    level = LEVEL_INTERMEDIATE
                    need_draw = True
                elif key == ord("A"):
                    level = LEVEL_ADVANCED
                    need_draw = True
                elif key == ord("M"):
                    level = LEVEL_MASTER
                    need_draw = True

            _ = TranslateMessage(com_addr(msg))
            _ = DispatchMessageW(com_addr(msg))
        if not running:
            break

        # ---- the deadline, for an unattended run -------------------------
        # Checked here rather than at the foot of the loop: in demo mode the
        # foot is never reached, because choosing a move ends with `continue`.
        if deadline != 0 and performance_counter() >= deadline:
            if not did_readback:
                did_readback = True
                print()
                print("frames painted:", scene[].painted)
                readback(hwnd, Int(frame_buf))
                _ = DestroyWindow(hwnd)
            continue

        # ---- the picture, and the two lines under it ---------------------
        if need_draw:
            need_draw = False
            var hints = (
                legal_moves(black, white) if (black_turn and not over and not demo) else UInt64(0)
            )
            render(bg, frame, black, white, hints, last_move)

            var b = popcount(black)
            var w = popcount(white)
            var lvl = level_name(level)
            if level == LEVEL_MASTER:
                lvl += String(" (GPU)") if gpu else String(" (CPU)")
            scene[].count1 = store_line(
                Int(line1_buf),
                String("Black ")
                + String(b)
                + String("    White ")
                + String(w)
                + String("        ")
                + lvl,
            )

            var note = String("White to play")
            if over:
                if b > w:
                    note = String("Black wins by ") + String(b - w)
                elif w > b:
                    note = String("White wins by ") + String(w - b)
                else:
                    note = String("Drawn")
                note += String("   -   N for a new game")
            elif thinking:
                note = String("White is thinking...")
            elif demo:
                note = String("demo - the computer has both sides")
            elif black_turn:
                note = String("Your move")
            if last_move != 0 and not over and not thinking:
                note += String("    last ") + square_name(last_move)
                if last_ms > 0:
                    note += String(" (") + String(last_ms) + String(" ms)")
            scene[].count2 = store_line(Int(line2_buf), note)

            var caption = wide_of(
                String("Othello - black ")
                + String(b)
                + String(" white ")
                + String(w)
                + String(" - ")
                + lvl
                + String("   [N] new  [B I A M] level  [D] demo  [Esc] quit")
            )
            _ = SetWindowTextW(
                hwnd, caption.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
            )
            _ = caption

            # All painting funnels through WM_PAINT so that an uncovered
            # window repaints from the same code that animates it.
            # UpdateWindow makes that paint happen now rather than whenever
            # the queue next empties -- which matters here, because the very
            # next thing this loop does may be to think for a second.
            _ = InvalidateRect(hwnd, 0, c_int(0))
            _ = UpdateWindow(hwnd)

        # ---- the computer's move, on the thread that owns the GPU --------
        if not over and (demo or not black_turn):
            if not thinking:
                thinking = True
                need_draw = True
                continue  # show "thinking" BEFORE thinking, not after
            thinking = False
            rng = next_random(rng)
            var t0 = performance_counter()
            # Black in demo mode is always Master: the point of the demo is to
            # watch the playout player take the alpha-beta player apart.
            var move = choose_move(
                gpu,
                black,
                white,
                black_turn,
                LEVEL_MASTER if (demo and black_turn) else level,
                rng,
            )
            last_ms = (performance_counter() - t0) * 1000 // hz
            if move != 0:
                var own = black if black_turn else white
                var opp = white if black_turn else black
                var f = flips_for(own, opp, move)
                if black_turn:
                    black = black | move | f
                    white = white ^ f
                else:
                    white = white | move | f
                    black = black ^ f
                last_move = move
                moves_played += 1
                print(
                    "  ",
                    "black" if black_turn else "white",
                    "plays",
                    square_name(move),
                    "in",
                    last_ms,
                    "ms",
                )
                black_turn = not black_turn
            var s2 = settle_turn(black, white, black_turn)
            if s2[0] != black_turn:
                # The player who CANNOT move is the one whose turn it was --
                # `black_turn` still names them, because settle_turn returns
                # the turn it moved on to rather than changing it in place.
                print("  ", "black" if black_turn else "white", "passes")
            black_turn = s2[0]
            over = s2[1]
            need_draw = True
            continue

        # Nothing to do until somebody types or clicks. WaitMessage blocks
        # without burning a core, which GetMessageW would also do -- but this
        # loop has to own the GPU calls above, so it peeks and sleeps by hand.
        if not need_draw:
            _ = WaitMessage()

    if deadline != 0:
        _ = KillTimer(hwnd, TICK_TIMER_ID)
    print()
    print(
        "final: black",
        popcount(black),
        " white",
        popcount(white),
        " after",
        moves_played,
        "moves;",
        scene[].painted,
        "paints",
    )

    if scene[].font1 != 0:
        _ = DeleteObject(scene[].font1)
    if scene[].font2 != 0 and scene[].font2 != scene[].font1:
        _ = DeleteObject(scene[].font2)
    bg_buf.unsafe_free()
    frame_buf.unsafe_free()
    line1_buf.unsafe_free()
    line2_buf.unsafe_free()
    store.unsafe_free()
    print("done")
