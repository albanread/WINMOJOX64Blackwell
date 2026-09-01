# ===----------------------------------------------------------------------=== #
# Ferns -- a landscape of Barnsley ferns, growing live in a Win32 window.
#
# A dozen ferns in different shades of green, each an iterated function system
# played as the chaos game: one point chased through four affine maps, tens of
# thousands of times, plotted where it lands. Every frame each fern grows by a
# few hundred points, so the landscape assembles in front of you -- stems
# first, then fronds, then the fine leaf texture as points pile up. Farther
# ferns are smaller, dimmer and bluer. They grow out of a procedural lawn --
# fourteen thousand individual grass blades, taller and greener up close --
# under a dusk sky whose clouds come from two octaves of value noise.
#
# Everything is drawn by the CPU into one BGRA buffer. The buffer reaches the
# screen through GDI: a top-down DIB and a single StretchDIBits inside
# WM_PAINT. No Direct3D, no Direct2D, no swap chain, no device to lose --
# which for a picture the CPU has already finished is the whole of what is
# needed. When the landscape is fully grown it holds for a moment, then a new
# one seeds, sky and lawn and all.
#
#   click    plant a fern where you clicked -- lower on screen means closer,
#            so it comes up bigger
#   space    pause the growing
#   r        clear the ground and reseed
#   q / esc  quit, as does closing the window
#
# Nothing Windows-shaped is written by hand, and almost none of it is written
# here. The window, its class, the structures Windows passes by pointer, and
# the typed entry-point lookup all come from `std.windows.gui`; which DLL
# exports each function and every constant comes from windows_api.db, and
# PAINTSTRUCT is never declared at all, only sized. The three shared structs
# this program hands to Windows on its own -- MSG, RECT, BITMAPINFOHEADER --
# are re-asserted against the metadata in main(), so a stdlib layout that has
# drifted from this SDK fails the build here rather than the picture.
#
# What stays local is what the example is about: the chaos game and the
# ferns, the lawn and the noise sky, the WM_TIMER frame clock that is not an
# ordinary message loop, and a blit that asks GDI to HALFTONE a resized fern
# rather than throw fronds away.
#
# FERNS_FRAMES=N grows for N frames, reads the window's own client area back
# out to prove the pixels landed, and exits -- what an unattended harness (or
# a reviewer with no screen) needs. FERNS_DUMP=path writes the final frame as
# raw BGRA on the way out.
# ===----------------------------------------------------------------------=== #

from std.ffi import c_int
from std.memory import Pointer, Span, alloc
from std.os import getenv
from std.sys._com import com_addr
from std.sys._winkb import (
    winkb_constant,
    winkb_db_schema_version,
    winkb_struct_size,
)
from std.sys.info import size_of
from std.windows import (
    WideString,
    performance_counter,
    performance_frequency,
    raise_last_error,
)
from std.windows.gui import (
    BITMAPINFOHEADER,
    MSG,
    RECT,
    Window,
    WindowClass,
    default_handler,
    quit,
    win32,
)


comptime W = 1024
comptime H = 640
comptime PIXELS = W * H

comptime MAX_FERNS = 24
comptime SEED_FERNS = 12

# Every fern finishes in about the same number of frames regardless of size,
# so the landscape matures together rather than the big ones dragging on.
comptime GROW_FRAMES = 600
comptime HOLD_FRAMES = 300  # a grown landscape lingers ~5 s, then reseeds

# Where the ground meets the sky. Integer rows, so the sky loop and the depth
# arithmetic cannot disagree about which row the horizon is.
comptime SKY_ROWS = (H * 55) // 100
comptime HORIZON = Float64(SKY_ROWS)

comptime BLADES = 14000

# The cloud lattices: value noise, bilinearly interpolated. Coarse carries the
# cloud masses, fine breaks their edges up.
comptime NCX = 9
comptime NCY = 5
comptime NFX = 25
comptime NFY = 13

comptime TICK_ID = 1
comptime TICK_MS = 15  # the system tick is ~15.6 ms, so this is "every tick"

# Flags the window procedure raises and the frame loop lowers. Bits, so two
# things happening in one frame do not lose each other.
comptime CMD_CLICK = 1
comptime CMD_PAUSE = 2
comptime CMD_RESET = 4
comptime CMD_QUIT = 8


# ===----------------------------------------------------------------------===#
# The one structure this program declares. `WNDCLASSEXW`, `MSG`, `RECT` and
# `BITMAPINFOHEADER` used to be written out here too; they are the same four
# structures in every Win32 program, so they live in `std.windows.gui` now and
# are imported above.
# ===----------------------------------------------------------------------===#


@fieldwise_init
struct Scene(Defaultable, Copyable, Movable):
    """Everything a captureless window procedure has to be able to reach.

    Windows calls the procedure, so it captures nothing; this lives on the
    heap and its address is the one thing a window can be asked to keep
    (GWLP_USERDATA). The procedure paints from `pixels` and raises bits in
    `cmd`; the frame loop, which owns the landscape, lowers them again.
    """

    var pixels: Int  # the BGRA buffer, W x H
    var painted: Int  # WM_PAINTs actually served
    var cmd: Int  # CMD_* bits raised by the procedure
    var click_x: Int  # in buffer pixels, not client pixels
    var click_y: Int

    def __init__(out self):
        self.pixels = 0
        self.painted = 0
        self.cmd = 0
        self.click_x = 0
        self.click_y = 0


# ===----------------------------------------------------------------------===#
# The fern itself: four affine maps, and the shape is in the numbers. Map 0 is
# the stem, map 1 the climb, maps 2 and 3 the two lowest fronds.
# ===----------------------------------------------------------------------===#


@fieldwise_init
struct Affine(Defaultable, ImplicitlyCopyable, Movable):
    """One map: x' = a x + b y + e, y' = c x + d y + f, with probability p."""

    var a: Float64
    var b: Float64
    var c: Float64
    var d: Float64
    var e: Float64
    var f: Float64
    var p: Float64

    def __init__(out self):
        self.a = 0.0
        self.b = 0.0
        self.c = 0.0
        self.d = 0.0
        self.e = 0.0
        self.f = 0.0
        self.p = 0.0


def barnsley() -> List[Affine]:
    var maps = List[Affine]()
    maps.append(Affine(0.00, 0.00, 0.00, 0.16, 0.0, 0.00, 0.01))
    maps.append(Affine(0.85, 0.04, -0.04, 0.85, 0.0, 1.60, 0.85))
    maps.append(Affine(0.20, -0.26, 0.23, 0.22, 0.0, 1.60, 0.07))
    maps.append(Affine(-0.15, 0.28, 0.26, 0.24, 0.0, 0.44, 0.07))
    return maps^


struct Rng(Movable):
    """Random numbers from xorshift64*, deterministic: the same landscape
    grows on every run,
    which is what lets a harness assert anything about the picture."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next(mut self) -> Float64:
        self.state ^= self.state >> 12
        self.state ^= self.state << 25
        self.state ^= self.state >> 27
        var x = self.state * UInt64(2685821657736338717)
        return Float64(x >> 11) / 9007199254740992.0


@fieldwise_init
struct Fern(Defaultable, ImplicitlyCopyable, Movable):
    """One plant: where it stands, how big, what shade, and how far it has
    grown. The chaos-game point (x, y) is the whole growing state -- the
    picture so far lives in the framebuffer, not here."""

    var base_x: Float64  # where the stem meets the ground, in pixels
    var base_y: Float64
    var scale: Float64  # pixels per IFS unit; the fern is ~10 units tall
    var lean_c: Float64  # cos/sin of a small lean, applied about the base
    var lean_s: Float64
    var flip: Float64  # +-1: half the ferns face the other way
    var r: Int  # the fern's full colour, reached by accumulation
    var g: Int
    var b: Int
    var x: Float64  # the chaos-game point, in IFS coordinates
    var y: Float64
    var plotted: Int
    var target: Int
    var delay: Int  # frames to wait before sprouting

    def __init__(out self):
        self.base_x = 0.0
        self.base_y = 0.0
        self.scale = 0.0
        self.lean_c = 1.0
        self.lean_s = 0.0
        self.flip = 1.0
        self.r = 0
        self.g = 0
        self.b = 0
        self.x = 0.0
        self.y = 0.0
        self.plotted = 0
        self.target = 0
        self.delay = 0


def make_fern(mut rng: Rng, base_x: Float64, base_y: Float64) -> Fern:
    """A fern for a spot on the ground. Depth does the design work: how far
    below the horizon it stands sets its size, brightness and blue-shift, so
    nearer ferns come up bigger and greener."""
    var t = (base_y - HORIZON) / (Float64(H) - HORIZON)  # 0 far .. 1 near
    if t < 0.0:
        t = 0.0
    elif t > 1.0:
        t = 1.0
    var scale = 5.0 + t * 16.0 + rng.next() * 2.0
    var dim = 0.45 + 0.55 * t
    # A shade of green per fern: yellow-greens up close, dusty blue-greens in
    # the distance.
    var g_ = Int((120.0 + rng.next() * 135.0) * dim)
    var r_ = Int((15.0 + rng.next() * 75.0) * dim)
    var b_ = Int((25.0 + rng.next() * 65.0 + (1.0 - t) * 45.0) * dim)
    var lean = (rng.next() - 0.5) * 0.24
    var lc = 1.0 - lean * lean * 0.5  # cos, small-angle
    var ls = lean
    var flip = 1.0
    if rng.next() >= 0.5:
        flip = -1.0
    # Bigger ferns need more points to fill; everyone matures together.
    var target = Int(scale * scale * 380.0)
    var delay = Int(rng.next() * 150.0)
    return Fern(
        base_x,
        base_y,
        scale,
        lc,
        ls,
        flip,
        r_,
        g_,
        b_,
        0.0,
        0.0,
        0,
        target,
        delay,
    )


# ===----------------------------------------------------------------------===#
# The world the ferns grow into.
# ===----------------------------------------------------------------------===#


def _lattice(mut rng: Rng, nx: Int, ny: Int) -> List[Float64]:
    var out = List[Float64]()
    for _k in range(nx * ny):
        out.append(rng.next())
    return out^


def _col_cell(nx: Int) -> List[Int]:
    """Which lattice column each screen column falls in.

    Every scanline samples the lattice at the same W horizontal positions, so
    the cell index and the smoothed fraction are the same for every row.
    Hoisting them out of the sky loop is what keeps a reseed from being a
    visible stall: the inner loop is then four array reads and six multiplies.
    """
    var out = List[Int]()
    for px in range(W):
        var x = (Float64(px) / Float64(W)) * Float64(nx - 1)
        var xi = Int(x)
        if xi >= nx - 1:
            xi = nx - 2
        out.append(xi)
    return out^


def _col_frac(nx: Int) -> List[Float64]:
    """The smoothstepped fraction across that cell, per screen column."""
    var out = List[Float64]()
    for px in range(W):
        var x = (Float64(px) / Float64(W)) * Float64(nx - 1)
        var xi = Int(x)
        if xi >= nx - 1:
            xi = nx - 2
        var fx = x - Float64(xi)
        # Smoothstep the fraction, or the lattice shows through as diamonds.
        out.append(fx * fx * (3.0 - 2.0 * fx))
    return out^


def paint_backdrop(pixels: Pointer[UInt32, MutUntrackedOrigin], mut rng: Rng):
    """The world the ferns grow into, painted once per landscape.

    A dusk sky, deep indigo at the top warming toward the horizon, with clouds
    from two octaves of value noise -- a coarse lattice for the masses, a fine
    one to roughen their edges, faded out near the horizon where real clouds
    thin into haze. Below it, bare earth and then the lawn: thousands of
    individual grass blades, each with its own height, lean and slightly
    different green, taller and brighter the nearer they stand. The ferns are
    plotted over all of it, frame by frame.
    """
    var coarse = _lattice(rng, NCX, NCY)
    var fine = _lattice(rng, NFX, NFY)

    var ccell = _col_cell(NCX)
    var cfrac = _col_frac(NCX)
    var fcell = _col_cell(NFX)
    var ffrac = _col_frac(NFX)

    # ---- sky ----------------------------------------------------------------
    for py in range(SKY_ROWS):
        var t = Float64(py) / HORIZON  # 0 top .. 1 horizon

        # The lattice row is fixed for a whole scanline; only the column
        # varies, and that was precomputed.
        var cy = t * Float64(NCY - 1)
        var cyi = Int(cy)
        if cyi >= NCY - 1:
            cyi = NCY - 2
        var cf0 = cy - Float64(cyi)
        var cfy = cf0 * cf0 * (3.0 - 2.0 * cf0)

        var fy_ = t * Float64(NFY - 1)
        var fyi = Int(fy_)
        if fyi >= NFY - 1:
            fyi = NFY - 2
        var ff0 = fy_ - Float64(fyi)
        var ffy = ff0 * ff0 * (3.0 - 2.0 * ff0)

        # Dusk gradient: indigo up high, a warm grey band low.
        var r = 10.0 + t * 36.0
        var g = 12.0 + t * 28.0
        var b = 34.0 + t * 24.0
        var thin = 0.75 - 0.55 * t

        for px in range(W):
            var ci = cyi * NCX + ccell[px]
            var cfx = cfrac[px]
            var ca = coarse[ci]
            var cb = coarse[ci + 1]
            var cc = coarse[ci + NCX]
            var cd = coarse[ci + NCX + 1]
            var cn = (ca + (cb - ca) * cfx) * (1.0 - cfy) + (
                cc + (cd - cc) * cfx
            ) * cfy

            var fi = fyi * NFX + fcell[px]
            var ffx = ffrac[px]
            var fa = fine[fi]
            var fb = fine[fi + 1]
            var fc = fine[fi + NFX]
            var fd = fine[fi + NFX + 1]
            var fnn = (fa + (fb - fa) * ffx) * (1.0 - ffy) + (
                fc + (fd - fc) * ffx
            ) * ffy

            var n = 0.65 * cn + 0.35 * fnn
            # Only the upper range of the noise is cloud; the rest stays sky.
            # Smoothstep the edge, and thin everything toward the horizon.
            var cloud = (n - 0.52) / 0.30
            if cloud < 0.0:
                cloud = 0.0
            elif cloud > 1.0:
                cloud = 1.0
            cloud = cloud * cloud * (3.0 - 2.0 * cloud) * thin

            # Moonlit grey, blended over the gradient.
            var pr = Int(r + (96.0 - r) * cloud)
            var pg = Int(g + (100.0 - g) * cloud)
            var pb = Int(b + (122.0 - b) * cloud)
            pixels.unsafe_offset(py * W + px)[] = UInt32(
                0xFF000000 | (pr << 16) | (pg << 8) | pb
            )

    # ---- bare earth ---------------------------------------------------------
    # Dark moss, darker with nearness, so the gaps between blades read as
    # shadow rather than void.
    for py in range(SKY_ROWS, H):
        var t = (Float64(py) - HORIZON) / (Float64(H) - HORIZON)
        var r = Int(16.0 - t * 7.0)
        var g = Int(26.0 - t * 9.0)
        var b = Int(13.0 - t * 6.0)
        var pixel = UInt32(0xFF000000 | (r << 16) | (g << 8) | b)
        for px in range(W):
            pixels.unsafe_offset(py * W + px)[] = pixel

    # ---- the lawn -----------------------------------------------------------
    # Back to front, so near blades overpaint far ones the way nearness does.
    for k in range(BLADES):
        var depth = Float64(k) / Float64(BLADES)  # 0 far .. 1 near
        var by = HORIZON + 2.0 + depth * (Float64(H) - HORIZON - 3.0)
        var bx = rng.next() * Float64(W)
        var t = (by - HORIZON) / (Float64(H) - HORIZON)
        var h = 2.0 + t * 11.0 + rng.next() * 3.0
        var lean = (rng.next() - 0.5) * 4.0
        var dim = 0.40 + 0.60 * t
        var gr = (44.0 + rng.next() * 66.0) * dim
        var rr = (9.0 + rng.next() * 24.0) * dim
        var br = (11.0 + rng.next() * 26.0) * dim
        var i = 0.0
        while i < h:
            var a = i / h
            var px = Int(bx + lean * a * a)
            var py = Int(by - i)
            if px >= 0 and px < W and py >= 0 and py < H:
                # Tips catch the light.
                var lit = 0.72 + 0.42 * a
                pixels.unsafe_offset(py * W + px)[] = UInt32(
                    0xFF000000
                    | (Int(rr * lit) << 16)
                    | (Int(gr * lit) << 8)
                    | Int(br * lit)
                )
            i += 1.0


def plot(
    pixels: Pointer[UInt32, MutUntrackedOrigin],
    px: Int,
    py: Int,
    r: Int,
    g: Int,
    b: Int,
):
    """One chaos-game hit: the pixel moves a quarter of the way to the fern's
    own colour.

    Density does the shading -- a wisp brushed once stays mostly backdrop, a
    spine hit hundreds of times converges to the full shade and stops there.
    The first version added saturating increments and dense regions blew out
    to white; converging can overshoot nothing, and it occludes correctly
    whether the pixel underneath was dark sky or a bright grass tip.
    """
    if px < 0 or px >= W or py < 0 or py >= H:
        return
    var at = pixels.unsafe_offset(py * W + px)
    var old = at[]
    var ob = Int(old & 0xFF)
    var og = Int((old >> 8) & 0xFF)
    var orr = Int((old >> 16) & 0xFF)

    var db = b - ob
    var step_b = db // 4
    if step_b == 0 and db != 0:
        step_b = 1 if db > 0 else -1
    var dg = g - og
    var step_g = dg // 4
    if step_g == 0 and dg != 0:
        step_g = 1 if dg > 0 else -1
    var dr = r - orr
    var step_r = dr // 4
    if step_r == 0 and dr != 0:
        step_r = 1 if dr > 0 else -1

    at[] = UInt32(
        0xFF000000
        | ((orr + step_r) << 16)
        | ((og + step_g) << 8)
        | (ob + step_b)
    )


# ===----------------------------------------------------------------------===#
# Presentation: one top-down DIB, one StretchDIBits.
#
# `std.windows.gui.present_bgra` does the same DIB in three fewer lines and is
# what a program with nothing to say about scaling should call. This is not
# that program, and the two differences are the reason it stays here:
#
#   * It takes the HDC BeginPaint handed it, rather than opening a second
#     device context on a window that is already inside a paint.
#   * It asks for STRETCH_HALFTONE. A stretch mode belongs to the DC, so it
#     cannot be set from outside on a DC the callee opens and closes; and the
#     default mode drops rows and columns, which on a fern means whole fronds.
#
# At the size the window opens with, source and destination are equal and no
# stretching happens at all -- so this differs from `present_bgra` only once
# somebody drags the corner, which is exactly when it matters.
# ===----------------------------------------------------------------------===#


def blit(hdc: Int, pixels: Int, dest_w: Int, dest_h: Int) raises:
    """Push the CPU buffer into a device context, scaled to the client rect."""
    var StretchDIBits = win32[
        def (
            Int,  # HDC
            c_int, c_int, c_int, c_int,  # xDest, yDest, wDest, hDest
            c_int, c_int, c_int, c_int,  # xSrc,  ySrc,  wSrc,  hSrc
            Pointer[UInt32, MutAnyOrigin],  # lpBits
            Pointer[BITMAPINFOHEADER, MutAnyOrigin],  # lpbmi
            UInt32,  # iUsage
            UInt32,  # rop
        ) thin abi("C") -> c_int,
        "StretchDIBits",
    ]()

    var bmi = BITMAPINFOHEADER()
    bmi.biSize = UInt32(size_of[BITMAPINFOHEADER]())
    bmi.biWidth = Int32(W)
    # Negative height asks GDI for a TOP-DOWN DIB: row 0 is the top row, which
    # is how everyone computes pixels. A positive height means bottom-up and
    # the picture arrives upside down.
    bmi.biHeight = Int32(-H)
    bmi.biPlanes = 1
    bmi.biBitCount = 32
    bmi.biCompression = UInt32(winkb_constant["BI_RGB"]())

    # A window the reader has resized is not the buffer's size any more, and
    # GDI's default stretch simply drops rows and columns -- a fern reduced
    # that way loses whole fronds to the decimation. HALFTONE averages
    # instead, at a cost only paid when the two sizes actually differ. MSDN
    # requires the brush origin be reset after selecting it, or brush-based
    # drawing on the same DC misaligns.
    if dest_w != W or dest_h != H:
        var SetStretchBltMode = win32[
            def (Int, c_int) thin abi("C") -> c_int, "SetStretchBltMode"
        ]()
        var SetBrushOrgEx = win32[
            def (Int, c_int, c_int, Int) thin abi("C") -> c_int, "SetBrushOrgEx"
        ]()
        _ = SetStretchBltMode(hdc, c_int(winkb_constant["STRETCH_HALFTONE"]()))
        _ = SetBrushOrgEx(hdc, c_int(0), c_int(0), 0)

    var bits = Pointer[UInt32, MutAnyOrigin](unsafe_from_address=pixels)
    _ = StretchDIBits(
        hdc,
        c_int(0),
        c_int(0),
        c_int(dest_w),
        c_int(dest_h),
        c_int(0),
        c_int(0),
        c_int(W),
        c_int(H),
        bits,
        com_addr(bmi),
        UInt32(winkb_constant["DIB_RGB_COLORS"]()),
        UInt32(winkb_constant["SRCCOPY"]()),
    )
    _ = bmi


# ===----------------------------------------------------------------------===#
# The window procedure. Windows calls this, so it is a captureless C-ABI
# function that must never raise -- unwinding through a Windows frame is
# undefined -- and everything is caught here. Its handlers only raise flags;
# the frame loop, which owns the landscape, is what acts on them.
# ===----------------------------------------------------------------------===#

def _scene_of(hwnd: Int) raises -> Int:
    var GetWindowLongPtrW = win32[
        def (Int, c_int) thin abi("C") -> Int, "GetWindowLongPtrW"
    ]()
    return GetWindowLongPtrW(hwnd, c_int(winkb_constant["GWLP_USERDATA"]()))


@export("ferns_wndproc")
def ferns_wndproc(
    hwnd: Int, message: UInt32, wparam: Int, lparam: Int
) abi("C") -> Int:
    try:
        # Refuse the background erase: the whole client area is redrawn every
        # frame, and letting GDI clear it first is what makes it flicker.
        if message == UInt32(winkb_constant["WM_ERASEBKGND"]()):
            return 1

        if message == UInt32(winkb_constant["WM_PAINT"]()):
            var stored = _scene_of(hwnd)
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
                length=winkb_struct_size["PAINTSTRUCT"](), fill=0
            )
            var ps_ptr = ps.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
            var hdc = BeginPaint(hwnd, ps_ptr)
            if stored != 0 and hdc != 0:
                var scene = Pointer[Scene, MutAnyOrigin](
                    unsafe_from_address=stored
                )
                var GetClientRect = win32[
                    def (
                        Int, Pointer[RECT, MutAnyOrigin]
                    ) thin abi("C") -> c_int,
                    "GetClientRect",
                ]()
                var rc = RECT()
                _ = GetClientRect(hwnd, com_addr(rc))
                blit(hdc, scene[].pixels, rc.width(), rc.height())
                scene[].painted += 1
            _ = EndPaint(hwnd, ps_ptr)
            _ = ps
            return 0

        if message == UInt32(winkb_constant["WM_LBUTTONDOWN"]()):
            # lParam packs the point as two SIGNED 16-bit halves, and they
            # are signed: a drag that leaves the window to the left reports a
            # negative x, which read unsigned becomes 65,000-odd.
            var cx = lparam & 0xFFFF
            if cx >= 0x8000:
                cx -= 0x10000
            var cy = (lparam >> 16) & 0xFFFF
            if cy >= 0x8000:
                cy -= 0x10000

            # Click position is in client pixels; the landscape is in buffer
            # pixels, and StretchDIBits has been scaling between them.
            var GetClientRect = win32[
                def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
                "GetClientRect",
            ]()
            var rc = RECT()
            _ = GetClientRect(hwnd, com_addr(rc))
            var cw = rc.width()
            var ch = rc.height()
            var stored = _scene_of(hwnd)
            if stored != 0 and cw > 0 and ch > 0:
                var scene = Pointer[Scene, MutAnyOrigin](
                    unsafe_from_address=stored
                )
                scene[].click_x = cx * W // cw
                scene[].click_y = cy * H // ch
                scene[].cmd |= CMD_CLICK
            # Without this, keys go to whatever had focus before the click.
            var SetFocus = win32[def (Int) thin abi("C") -> Int, "SetFocus"]()
            _ = SetFocus(hwnd)
            return 0

        if message == UInt32(winkb_constant["WM_CHAR"]()):
            # Windows has already done the keyboard layout by the time this
            # arrives, so what turns up is the character the person meant.
            var unit = wparam & 0xFFFF
            var stored = _scene_of(hwnd)
            if stored != 0:
                var scene = Pointer[Scene, MutAnyOrigin](
                    unsafe_from_address=stored
                )
                if unit == 32:
                    scene[].cmd |= CMD_PAUSE
                elif unit == ord("r") or unit == ord("R"):
                    scene[].cmd |= CMD_RESET
                elif unit == ord("q") or unit == ord("Q"):
                    scene[].cmd |= CMD_QUIT
            return 0

        if message == UInt32(winkb_constant["WM_KEYDOWN"]()):
            # Escape is not a character, so it never reaches WM_CHAR.
            if wparam == winkb_constant["VK_ESCAPE"]():
                var stored = _scene_of(hwnd)
                if stored != 0:
                    var scene = Pointer[Scene, MutAnyOrigin](
                        unsafe_from_address=stored
                    )
                    scene[].cmd |= CMD_QUIT
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


# ===----------------------------------------------------------------------===#
# Unattended proof: copy the window's own client area back out.
# ===----------------------------------------------------------------------===#


def readback(hwnd: Int) raises:
    """What is actually on the window, sampled -- not what the calls returned.

    A DIB section, a BitBlt out of the window's own DC, and a handful of
    samples printed. Sky at the top, lawn at the bottom: if the middle rows
    are not darker-and-greener than the top ones the landscape is not there.
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
    var w = rc.width()
    var h = rc.height()
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
        c_int(0),
        c_int(0),
        c_int(w),
        c_int(h),
        windc,
        c_int(0),
        c_int(0),
        UInt32(winkb_constant["SRCCOPY"]()),
    )

    var got = Pointer[UInt32, MutAnyOrigin](unsafe_from_address=bits)
    print("readback: client", w, "x", h, "-- 0x00RRGGBB down the middle:")
    var distinct = 0
    var seen = List[Int]()
    for i in range(9):
        var x = w // 2
        var y = (h - 1) * i // 8
        var v = Int(got.unsafe_offset(y * w + x)[]) & 0xFFFFFF
        print("   row", y, "->", hex(v))
        var fresh = True
        for j in range(len(seen)):
            if seen[j] == v:
                fresh = False
        if fresh:
            seen.append(v)
            distinct += 1
    print("  ", distinct, "distinct colours in 9 samples")

    _ = SelectObject(memdc, old)
    _ = DeleteObject(hbmp)
    _ = DeleteDC(memdc)
    _ = ReleaseDC(hwnd, windc)


def one_dp(v: Float64) -> String:
    """One decimal place, because six of them is not a measurement."""
    var scaled = Int(v * 10.0 + 0.5)
    return String(scaled // 10) + "." + String(scaled % 10)


# ===----------------------------------------------------------------------===#


def main() raises:
    # `std.windows.gui` declares these and checks the two it uses itself. This
    # program hands all three to Windows on its own -- MSG to its own message
    # loop, RECT to GetClientRect and AdjustWindowRectEx, BITMAPINFOHEADER to
    # StretchDIBits and CreateDIBSection -- so it checks them here as well. A
    # struct that has drifted from this SDK then fails THIS build.
    comptime assert (
        size_of[MSG]() == winkb_struct_size["MSG"]()
    ), "MSG does not match Windows"
    comptime assert (
        size_of[RECT]() == winkb_struct_size["RECT"]()
    ), "RECT does not match Windows"
    comptime assert (
        size_of[BITMAPINFOHEADER]() == winkb_struct_size["BITMAPINFOHEADER"]()
    ), "BITMAPINFOHEADER does not match Windows"

    # FERNS_FRAMES=N: grow N frames, prove the pixels landed, and exit.
    var frame_limit = 0
    var door = getenv("FERNS_FRAMES")
    if door != "":
        frame_limit = Int(door)

    var SetProcessDPIAware = win32[
        def () thin abi("C") -> c_int, "SetProcessDPIAware"
    ]()
    var AdjustWindowRectEx = win32[
        def (
            Pointer[RECT, MutAnyOrigin], UInt32, c_int, UInt32
        ) thin abi("C") -> c_int,
        "AdjustWindowRectEx",
    ]()
    var SetWindowPos = win32[
        def (
            Int, Int, c_int, c_int, c_int, c_int, UInt32
        ) thin abi("C") -> c_int,
        "SetWindowPos",
    ]()
    var SetWindowTextW = win32[
        def (Int, Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> c_int,
        "SetWindowTextW",
    ]()
    var SetWindowLongPtrW = win32[
        def (Int, c_int, Int) thin abi("C") -> Int, "SetWindowLongPtrW"
    ]()
    var InvalidateRect = win32[
        def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
    ]()
    var SetTimer = win32[
        def (Int, Int, UInt32, Int) thin abi("C") -> Int, "SetTimer"
    ]()
    var GetMessageW = win32[
        def (
            Pointer[MSG, MutAnyOrigin], Int, UInt32, UInt32
        ) thin abi("C") -> c_int,
        "GetMessageW",
    ]()
    var TranslateMessage = win32[
        def (Pointer[MSG, MutAnyOrigin]) thin abi("C") -> c_int,
        "TranslateMessage",
    ]()
    var DispatchMessageW = win32[
        def (Pointer[MSG, MutAnyOrigin]) thin abi("C") -> Int, "DispatchMessageW"
    ]()
    var DestroyWindow = win32[def (Int) thin abi("C") -> c_int, "DestroyWindow"]()

    # Before any window exists: ask for real pixels rather than a blurry
    # upscale of logical ones. This display runs at 144 DPI. Deliberately not
    # in `std.windows.gui`: it is process-wide and irreversible, and a library
    # that changed it out from under a program would be doing harm.
    _ = SetProcessDPIAware()

    # `WindowClass` fills in and registers WNDCLASSEXW: the same style bits,
    # the same instance handle, the same arrow cursor this file used to spell
    # out, and it raises rather than returning zero.
    var klass = WindowClass("MojoFernsWindow", ferns_wndproc)

    # `Window` takes the OUTER size, because `CreateWindowExW` does. What this
    # program wants is an exact W x H CLIENT area, so the blit is one-to-one
    # and no scaling is in the way of the picture -- so ask Windows what frame
    # the style puts around one, rather than guessing how thick a border is.
    var want = RECT()
    want.right = Int32(W)
    want.bottom = Int32(H)
    _ = AdjustWindowRectEx(
        com_addr(want),
        UInt32(winkb_constant["WS_OVERLAPPEDWINDOW"]()),
        c_int(0),
        UInt32(0),
    )

    var window = Window(
        klass,
        "Ferns - click to plant, space pauses, r reseeds",
        want.width(),
        want.height(),
    )
    var hwnd = window.handle
    # `Window` opens at CW_USEDEFAULT, which cascades; this one is placed, so
    # the readback below is never sampling a window half off the screen.
    _ = SetWindowPos(
        hwnd,
        0,
        c_int(80),
        c_int(80),
        c_int(0),
        c_int(0),
        UInt32(
            winkb_constant["SWP_NOSIZE"]() | winkb_constant["SWP_NOZORDER"]()
        ),
    )
    # The window owns its own title; only the paused one is extra. A real
    # UTF-16 conversion, not a byte-per-character cast of ASCII.
    var title_paused = WideString("Ferns - PAUSED (space to resume)")

    # The pixels, on the heap: the window procedure reaches them through the
    # one pointer Windows keeps for us, and a local in main would be a local
    # the procedure has no way to see.
    var pixels = alloc[UInt32](PIXELS, alignment=32)
    var scene = alloc[Scene](1, alignment=8)
    # Emplaced, not assigned: `store[] = value` destroys what was there first,
    # and what is there is whatever the allocator last had.
    scene.unsafe_write(Scene(Int(pixels), 0, 0, 0, 0))
    _ = SetWindowLongPtrW(
        hwnd, c_int(winkb_constant["GWLP_USERDATA"]()), Int(scene)
    )

    var maps = barnsley()
    var rng = Rng(0x5EED)
    var ferns = alloc[Fern](MAX_FERNS, alignment=8)
    var fern_count = 0
    var next_slot = 0  # where a click plants once the meadow is full
    var landscape = 0
    var need_seed = True
    var paused = False
    var grown_for = 0
    var frames = 0

    var hz = performance_frequency()

    print("Ferns.  click plants . space pauses . r reseeds . q quits")
    print("metadata schema", winkb_db_schema_version(), "- buffer", W, "x", H)

    # The first landscape before the window is shown, so it opens onto a sky
    # rather than onto whatever the allocator left behind.
    var seed_start = performance_counter()
    paint_backdrop(pixels, rng)
    var seed_us = (performance_counter() - seed_start) * 1000000 // hz
    print("backdrop painted in", seed_us, "us")

    window.show()
    _ = SetTimer(hwnd, TICK_ID, UInt32(TICK_MS), 0)

    # Not `std.windows.gui.run()` and not `pump()`. `run()` blocks on
    # GetMessageW and hands every message straight to Windows, which leaves
    # nowhere to grow a frame; `pump()` never blocks, so the ferns would grow
    # as fast as the CPU allows and the fps line would measure the CPU rather
    # than the animation. This loop blocks like `run()` and then does its
    # frame work on its own WM_TIMER -- which is the example, so it stays.
    var loop_start = performance_counter()
    var msg = MSG()
    var sampled = False

    while True:
        var got = GetMessageW(com_addr(msg), 0, 0, 0)
        if got == 0:
            break
        if got == -1:
            raise_last_error("GetMessageW")

        # The runtime posts thread-level timers (WM_TIMER with a null hwnd) all
        # by itself, so the identity check is required, not defensive padding.
        var mine = (
            msg.message == UInt32(winkb_constant["WM_TIMER"]())
            and msg.hwnd == hwnd
            and msg.wParam == TICK_ID
        )
        if not mine:
            _ = TranslateMessage(com_addr(msg))
            _ = DispatchMessageW(com_addr(msg))
            continue

        # ---- flags, on the thread that owns the buffer ----------------------
        var pending = scene[].cmd
        if pending != 0:
            scene[].cmd = 0
            if (pending & CMD_CLICK) != 0:
                var planted = make_fern(
                    rng, Float64(scene[].click_x), Float64(scene[].click_y)
                )
                planted.delay = 0  # a planted fern sprouts now
                if fern_count < MAX_FERNS:
                    ferns.unsafe_offset(fern_count).unsafe_write(planted)
                    fern_count += 1
                else:
                    ferns.unsafe_offset(next_slot)[] = planted
                    next_slot = (next_slot + 1) % MAX_FERNS
                grown_for = 0
            if (pending & CMD_PAUSE) != 0:
                paused = not paused
                if paused:
                    _ = SetWindowTextW(hwnd, title_paused.unsafe_ptr())
                else:
                    _ = SetWindowTextW(hwnd, window.title.unsafe_ptr())
            if (pending & CMD_RESET) != 0:
                need_seed = True
            if (pending & CMD_QUIT) != 0:
                _ = DestroyWindow(hwnd)
                continue

        # ---- a fresh landscape ---------------------------------------------
        if need_seed:
            need_seed = False
            landscape += 1
            grown_for = 0
            fern_count = 0
            next_slot = 0
            paint_backdrop(pixels, rng)
            # A dozen spots along the ground band, shuffled in depth.
            for k in range(SEED_FERNS):
                var bx = (Float64(k) + 0.18 + rng.next() * 0.64) * (
                    Float64(W) / Float64(SEED_FERNS)
                )
                var by = HORIZON + 12.0 + rng.next() * (
                    Float64(H) - HORIZON - 24.0
                )
                ferns.unsafe_offset(fern_count).unsafe_write(
                    make_fern(rng, bx, by)
                )
                fern_count += 1
            print("landscape", landscape, "-", fern_count, "ferns")

        # ---- grow: a slice of each fern's points, plotted -------------------
        var all_grown = True
        if not paused:
            for i in range(fern_count):
                var f = ferns.unsafe_offset(i)
                if f[].delay > 0:
                    f[].delay -= 1
                    all_grown = False
                    continue
                if f[].plotted >= f[].target:
                    continue
                all_grown = False

                # The fern's fixed geometry, out of memory and into registers
                # before the inner loop touches it thousands of times.
                var base_x = f[].base_x
                var base_y = f[].base_y
                var sc = f[].scale
                var lc = f[].lean_c
                var ls = f[].lean_s
                var flip = f[].flip
                var cr = f[].r
                var cg = f[].g
                var cb = f[].b

                var steps = max(60, f[].target // GROW_FRAMES)
                var x = f[].x
                var y = f[].y
                for _step in range(steps):
                    # The chaos game: pick a map by weight, apply it.
                    var roll = rng.next()
                    var acc = 0.0
                    var chosen = 0
                    for m in range(len(maps)):
                        acc += maps[m].p
                        if roll <= acc:
                            chosen = m
                            break
                    var mp = maps[chosen]
                    var nx = mp.a * x + mp.b * y + mp.e
                    var ny = mp.c * x + mp.d * y + mp.f
                    x = nx
                    y = ny
                    # IFS space to the fern's spot: flip, lean about the base,
                    # scale, and stand it on the ground.
                    var fx = x * flip * sc
                    var fy = y * sc
                    var px = base_x + fx * lc + fy * ls
                    var py = base_y - fy * lc + fx * ls
                    plot(pixels, Int(px), Int(py), cr, cg, cb)

                f[].x = x
                f[].y = y
                f[].plotted += steps

        # A grown landscape lingers, then a new one seeds itself.
        if all_grown and not paused:
            grown_for += 1
            if grown_for >= HOLD_FRAMES:
                need_seed = True

        _ = InvalidateRect(hwnd, 0, c_int(0))
        frames += 1

        if frame_limit != 0:
            if frames == frame_limit - 1 and not sampled:
                sampled = True
                readback(hwnd)
            if frames >= frame_limit:
                _ = DestroyWindow(hwnd)

    var secs = Float64(performance_counter() - loop_start) / Float64(hz)
    print(
        "Grew",
        landscape,
        "landscape(s) over",
        frames,
        "frames in",
        one_dp(secs),
        "s (",
        one_dp(Float64(frames) / secs) if secs > 0.0 else "-",
        "fps ),",
        scene[].painted,
        "paints",
    )

    # The last frame, raw, for eyes that were not at the screen.
    var dump = getenv("FERNS_DUMP")
    if dump != "":
        var f = open(dump, "w")
        f.write_all(
            Span[UInt8, MutUntrackedOrigin](
                unsafe_ptr=pixels.unsafe_bitcast[UInt8](), length=PIXELS * 4
            )
        )
        # `with open(...)` does not close at the end of the block -- the handle
        # dies when the function returns, and a reader that comes next gets
        # ERROR_SHARING_VIOLATION. Close it here.
        f.close()
        print("dumped", W, "x", H, "BGRA to", dump)

    _ = title_paused
    _ = window^
    ferns.unsafe_free()
    pixels.unsafe_free()
    scene.unsafe_free()
