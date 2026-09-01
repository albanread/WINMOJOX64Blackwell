# ===----------------------------------------------------------------------=== #
# Fernwind — a meadow of ferns computed by the GPU, swaying in the wind.
#
# The honest way to grow a Barnsley fern is the chaos game: one point chasing
# itself through four affine maps, a few hundred thousand times, plotted as it
# goes. That is one thread's work, and the picture IS the accumulation -- which
# is exactly why a fern drawn that way cannot move. Erase it and you erase the
# only copy of the fern.
#
# This is the fractal-flame answer instead. Twenty-four thousand GPU threads
# each run their OWN short chaos game -- a burn-in of twelve steps to land on
# the attractor before anyone is allowed to see them, then 280 plotted ones --
# and their hits meet in four shared density buffers through ATOMIC ADDS. Just
# under seven million points a frame, a fresh meadow from scratch every frame.
#
# Redrawing from scratch is what buys the animation. Nothing is accumulated
# across frames, so the MAPS are free to change, and the wind lives in the
# mathematics rather than in a displacement applied afterwards: each fern's
# climb map is rotated a fraction of a degree by a gusting wind field, and
# because that map applies RECURSIVELY up the plant, a uniform rotation
# compounds into a progressive bend. Stems lean, tips whip. Nobody wrote a
# bend; a rotation of one 2x2 matrix did it.
#
#   click        plant a fern where you clicked -- lower is nearer, so bigger
#   space        still the air
#   r            reseed the landscape
#   q / Esc      quit, as does closing the window
#
# The lawn and the cloud sky are painted once per landscape by the CPU and
# uploaded; a second kernel composites the fern densities over that backdrop
# with a saturating curve, so density does the shading and nothing blows out.
#
# WHY THIS RUNS AT ALL ON THIS MACHINE. The Mac original lowers its atomics
# through the AIR backend. Here they go through NVPTX onto a T1000 -- Turing,
# sm_75 -- and everything above rests on global-memory atomic adds not losing
# increments there. That is not assumed: `atomics_hold()` below proves it on
# the actual device before the window is allowed to open, and says so. Nothing
# else in this program needs sm_80: no bf16, no tensor cores, no async copy.
# Float32 arithmetic, a data-dependent loop, and four `red.global.add`s.
#
# Presentation is the proven Windows route from `nvidia_mandelbrot`: the shade
# kernel writes finished BGRA, it is read back once, uploaded into a
# B8G8R8A8_UNORM texture, and a fullscreen triangle puts it on the swap chain.
# The only HLSL in the file is a texture fetch.
#
#   FERNWIND_FRAMES=N   render N frames and exit -- how this was tested
#   FERNWIND_DUMP=path  write the final frame as raw BGRA on the way out
# ===----------------------------------------------------------------------=== #

from max.gpu.host import DeviceContext
from std.atomic import Atomic
from std.ffi import c_int
from std.gpu import global_idx
from std.math import cos, sin
from std.memory import Pointer, OpaquePointer, alloc
from std.os import getenv
from std.python._cpython import _fn_ptr_as_opaque
from std.sys.info import size_of
from std.sys._com import ComPtr, com_addr, _guid_bytes, com_method_of
from std.sys._win32 import Win32Module
from std.sys._winkb import (
    winkb_constant,
    winkb_field_offset,
    winkb_function_dll,
    winkb_interface_iid,
    winkb_struct_size,
)
from std.windows import performance_counter, performance_frequency


comptime W = 1024
comptime H = 640
comptime PIXELS = W * H

comptime MAX_FERNS = 24
comptime SEED_FERNS = 12
comptime HORIZON = Float64(H) * 0.55

# The flame: streams x plotted iterations = points per frame, and the tone
# curve's K moves with it -- coverage is n/(n+K), so halving the density and
# halving K leaves every pixel at the opacity it had.
#
# The Mac original plots 280 per stream, 6.9 M points a frame, because an M4
# has the budget for it. A T1000 does not, and measurement says exactly why:
# the chaos-game arithmetic is 9.5 ms a frame, and the four atomic adds on top
# of it are 51. Atomic throughput is the whole cost, it is very nearly linear
# in the number of adds issued, and it is a property of this card rather than
# anything a rewrite fixes -- packing the three colour channels into one
# 64-bit atomic was tried and saved 15%, because a u64 atomic costs about what
# two u32 ones do. So the point count comes down instead, K comes down with
# it, and the picture is the same picture at twice the frame rate.
comptime STREAMS = 24576
comptime ITERS = 140
comptime BURN = 12
comptime TONE_K = Float32(1.5)
comptime BLOCK = 256
comptime GRID = (STREAMS + BLOCK - 1) // BLOCK
comptime PIX_GRID = (PIXELS + BLOCK - 1) // BLOCK

# Per-fern parameter record, in Float32 slots. Header: [0] fern count,
# [1] frame seed. Ferns start at slot 8, stride 40:
#   +0 base_x  +1 base_y  +2 scale  +3 flip  +4 r  +5 g  +6 b
#   +7 lean_c  +8 lean_s
#   +9 .. +36  four maps x (a, b, c, d, e, f, cumulative p)
comptime PARAM_HEAD = 8
comptime PARAM_STRIDE = 40
comptime PARAM_FLOATS = PARAM_HEAD + MAX_FERNS * PARAM_STRIDE

comptime BLADES = 14000
comptime NCX = 9
comptime NCY = 5
comptime NFX = 25
comptime NFY = 13

# The self-check, before anything is built on it.
comptime PROBE_THREADS = 65536
comptime PROBE_SLOTS = 256
comptime PROBE_HITS = 16
comptime PROBE_GRID = (PROBE_THREADS + BLOCK - 1) // BLOCK


# ===----------------------------------------------------------------------=== #
# Win32: every entry point typed, and the DLL comes from the metadata rather
# than from somebody's memory.
# ===----------------------------------------------------------------------=== #


def win32[
    Sig: TrivialRegisterPassable, name: StaticString
]() raises -> Sig:
    """A Win32 entry point, typed, from whichever DLL the metadata names.

    Parameters:
        Sig: The full thin C-ABI signature. Spell every argument -- an
            under-declared signature compiles and then corrupts the call.
        name: The exported function, e.g. "CreateWindowExW".

    Returns:
        The entry point, callable.

    Raises:
        If the metadata does not name the function, or the DLL will not load.
    """
    return Win32Module(String(winkb_function_dll[name]())).function[Sig](
        String(name)
    )


@fieldwise_init
struct WNDCLASSEXW(Defaultable, Copyable, Movable):
    """Not register-passable. Claiming otherwise does not fail to compile --
    it silently writes the fields to the wrong places."""

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
struct DXGI_SWAP_CHAIN_DESC(Defaultable, Copyable, Movable):
    """Flattened: the nested DXGI_MODE_DESC, DXGI_RATIONAL and
    DXGI_SAMPLE_DESC are written out, and the size is asserted."""

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
struct D3D11_TEXTURE2D_DESC(Defaultable, Copyable, Movable):
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
struct D3D11_VIEWPORT(Defaultable, Copyable, Movable):
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


def wide(s: StaticString) -> List[UInt16]:
    """A NUL-terminated UTF-16 buffer for the W-suffixed entry points."""
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


# ===----------------------------------------------------------------------=== #
# Input. Windows calls the procedure; it only sets flags, and the frame loop
# acts on them -- the same division the Mac original uses, for the same
# reason: nothing that touches the GPU may happen inside a window callback.
# ===----------------------------------------------------------------------=== #

comptime CMD_CLICK = 1
comptime CMD_PAUSE = 2
comptime CMD_RESET = 4
comptime CMD_QUIT = 8


@fieldwise_init
struct Commands(Defaultable, Copyable, Movable):
    """What the window procedure is allowed to say to the frame loop.

    It lives on the heap and the window carries its address in GWLP_USERDATA,
    because the procedure Windows calls is captureless: it cannot see a local
    in `main`, and it is handed nothing but the window handle.
    """

    var cmd: Int
    var click_x: Int
    var click_y: Int

    def __init__(out self):
        self.cmd = 0
        self.click_x = 0
        self.click_y = 0


comptime WndProcType = def (Int, UInt32, Int, Int) thin abi("C") -> Int


@export("fernwind_wndproc")
def fernwind_wndproc(
    hwnd: Int, message: UInt32, wparam: Int, lparam: Int
) abi("C") -> Int:
    # Windows calls this, so it must never raise: unwinding through a Windows
    # frame is undefined. Everything is caught here and the `except` returns.
    try:
        # Refuse the background erase. The whole client area is redrawn every
        # frame from the swap chain, and letting GDI clear it first is what
        # makes it flicker.
        if message == UInt32(winkb_constant["WM_ERASEBKGND"]()):
            return 1

        # Direct3D has already presented, so validate without painting:
        # BeginPaint would hand GDI a surface DWM then fights the DXGI frames
        # with. The update region must be cleared all the same, or Windows
        # re-sends WM_PAINT immediately, forever.
        if message == UInt32(winkb_constant["WM_PAINT"]()):
            var ValidateRect = win32[
                def (Int, Int) thin abi("C") -> c_int, "ValidateRect"
            ]()
            _ = ValidateRect(hwnd, 0)
            return 0

        var GetWindowLongPtrW = win32[
            def (Int, c_int) thin abi("C") -> Int, "GetWindowLongPtrW"
        ]()
        var stored = GetWindowLongPtrW(
            hwnd, c_int(winkb_constant["GWLP_USERDATA"]())
        )

        if stored != 0 and message == UInt32(
            winkb_constant["WM_LBUTTONDOWN"]()
        ):
            # lParam packs the point as two SIGNED 16-bit halves, and they
            # are signed for a reason: a press that arrives from off the left
            # edge reports a negative x, which read unsigned becomes 65,000.
            var px = lparam & 0xFFFF
            if px >= 0x8000:
                px -= 0x10000
            var py = (lparam >> 16) & 0xFFFF
            if py >= 0x8000:
                py -= 0x10000

            # The swap chain is a fixed 1024x640 and DXGI scales it into
            # whatever the client area happens to be, so a window the person
            # has dragged smaller is showing a shrunken meadow. The click
            # arrives in client pixels and has to be mapped back into meadow
            # pixels, or a fern is planted somewhere other than under the
            # pointer -- and the further from native the window is, the
            # further off it lands.
            var GetClientRect = win32[
                def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
                "GetClientRect",
            ]()
            var rc = RECT()
            _ = GetClientRect(hwnd, com_addr(rc))
            var cw = Int(rc.right - rc.left)
            var ch = Int(rc.bottom - rc.top)
            if cw > 0 and ch > 0:
                px = px * W // cw
                py = py * H // ch

            var state = Pointer[Commands, MutAnyOrigin](
                unsafe_from_address=stored
            )
            state[].click_x = px
            state[].click_y = py
            state[].cmd |= CMD_CLICK
            # Without this the keys go nowhere after the first click.
            var SetFocus = win32[def (Int) thin abi("C") -> Int, "SetFocus"]()
            _ = SetFocus(hwnd)
            return 0

        if stored != 0 and message == UInt32(winkb_constant["WM_KEYDOWN"]()):
            var state = Pointer[Commands, MutAnyOrigin](
                unsafe_from_address=stored
            )
            if wparam == winkb_constant["VK_SPACE"]():
                state[].cmd |= CMD_PAUSE
            elif wparam == winkb_constant["VK_R"]():
                state[].cmd |= CMD_RESET
            elif (
                wparam == winkb_constant["VK_Q"]()
                or wparam == winkb_constant["VK_ESCAPE"]()
            ):
                state[].cmd |= CMD_QUIT
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
# The fern: four affine maps, and the shape is entirely in the numbers.
# Map 1 is the climb -- the one the wind gets to bend.
# ===----------------------------------------------------------------------=== #


@fieldwise_init
struct Affine(ImplicitlyCopyable, Movable):
    """An affine map: x' = a x + b y + e, y' = c x + d y + f, taken with p."""

    var a: Float64
    var b: Float64
    var c: Float64
    var d: Float64
    var e: Float64
    var f: Float64
    var p: Float64


def barnsley() -> List[Affine]:
    var maps = List[Affine]()
    maps.append(Affine(0.00, 0.00, 0.00, 0.16, 0.0, 0.00, 0.01))
    maps.append(Affine(0.85, 0.04, -0.04, 0.85, 0.0, 1.60, 0.85))
    maps.append(Affine(0.20, -0.26, 0.23, 0.22, 0.0, 1.60, 0.07))
    maps.append(Affine(-0.15, 0.28, 0.26, 0.24, 0.0, 0.44, 0.07))
    return maps^


struct Rng(Movable):
    """Random numbers: xorshift64* on the host, deterministic -- the same
    meadow every run, so a landscape can be described and found again."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next(mut self) -> Float64:
        self.state ^= self.state >> 12
        self.state ^= self.state << 25
        self.state ^= self.state >> 27
        var x = self.state * 2685821657736338717
        return Float64(x >> 11) / Float64(1 << 53)


@fieldwise_init
struct Fern(ImplicitlyCopyable, Movable):
    """One plant's standing state. The bend is recomputed from the wind every
    frame, so nothing in here moves except by being recalculated."""

    var base_x: Float64
    var base_y: Float64
    var scale: Float64
    var lean0: Float64  # the fern's own resting lean, radians
    var flip: Float64
    var r: Int
    var g: Int
    var b: Int
    var phase: Float64  # where this fern sits in the travelling gusts
    var supple: Float64  # how much the wind moves it; taller bends more


def make_fern(mut rng: Rng, base_x: Float64, base_y: Float64) -> Fern:
    """Depth does the design work: how far below the horizon a fern stands
    sets its size, its brightness and its blue-shift, so the meadow recedes."""
    var t = (base_y - HORIZON) / (Float64(H) - HORIZON)
    if t < 0.0:
        t = 0.0
    elif t > 1.0:
        t = 1.0
    var scale = 5.0 + t * 16.0 + rng.next() * 2.0
    var dim = 0.45 + 0.55 * t
    var g_ = Int((120.0 + rng.next() * 135.0) * dim)
    var r_ = Int((15.0 + rng.next() * 75.0) * dim)
    var b_ = Int((25.0 + rng.next() * 65.0 + (1.0 - t) * 45.0) * dim)
    var lean0 = (rng.next() - 0.5) * 0.20
    var flip = 1.0 if rng.next() < 0.5 else -1.0
    var phase = base_x * 0.006 + rng.next() * 0.8
    var supple = 0.55 + 0.45 * t + rng.next() * 0.25
    return Fern(base_x, base_y, scale, lean0, flip, r_, g_, b_, phase, supple)


# ===----------------------------------------------------------------------=== #
# The kernels.
# ===----------------------------------------------------------------------=== #


def chaos_kernel(
    nacc: Pointer[UInt32, MutAnyOrigin],
    racc: Pointer[UInt32, MutAnyOrigin],
    gacc: Pointer[UInt32, MutAnyOrigin],
    bacc: Pointer[UInt32, MutAnyOrigin],
    params: Pointer[Float32, MutAnyOrigin],
):
    """One thread, one short chaos game.

    The stream picks its fern by thread id, burns in unplotted so that its
    point is ON the attractor before anyone sees it, then plots its stretch
    with four atomic adds per hit: a count, and the fern's colour weighted in,
    so overlapping ferns blend by evidence rather than by draw order.

    Every thread in a warp takes a different branch at every step -- the map
    is chosen by a random roll -- so this is the divergent shape, and the
    atomics land wherever the attractor sends them.
    """
    var idx = Int(global_idx.x)
    if idx >= STREAMS:
        return
    var nf = Int(params.unsafe_offset(0)[])
    if nf <= 0:
        return
    var seed = UInt32(Int(params.unsafe_offset(1)[]))
    var fern = idx % nf
    var at = PARAM_HEAD + fern * PARAM_STRIDE

    var base_x = params.unsafe_offset(at + 0)[]
    var base_y = params.unsafe_offset(at + 1)[]
    var scale = params.unsafe_offset(at + 2)[]
    var flip = params.unsafe_offset(at + 3)[]
    var cr = UInt32(Int(params.unsafe_offset(at + 4)[]))
    var cg = UInt32(Int(params.unsafe_offset(at + 5)[]))
    var cb = UInt32(Int(params.unsafe_offset(at + 6)[]))
    var lean_c = params.unsafe_offset(at + 7)[]
    var lean_s = params.unsafe_offset(at + 8)[]

    # A stream's randomness must differ per thread AND per frame, or every
    # frame replots the same points and the flame strobes instead of shimmers.
    var state = UInt32(idx) * UInt32(2654435761) ^ seed
    state = state | 1
    state ^= state << 13
    state ^= state >> 17
    state ^= state << 5

    var x = Float32(0)
    var y = Float32(0)
    for step in range(BURN + ITERS):
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        var roll = Float32(state >> 8) * Float32(5.9604645e-08)  # 1/2^24

        # Cumulative probabilities were prepared on the host, so choosing a
        # map is three compares and no adds.
        var m = at + 9
        if roll > params.unsafe_offset(m + 6)[]:
            m += 7
            if roll > params.unsafe_offset(m + 6)[]:
                m += 7
                if roll > params.unsafe_offset(m + 6)[]:
                    m += 7
        var nx = (
            params.unsafe_offset(m + 0)[] * x
            + params.unsafe_offset(m + 1)[] * y
            + params.unsafe_offset(m + 4)[]
        )
        var ny = (
            params.unsafe_offset(m + 2)[] * x
            + params.unsafe_offset(m + 3)[] * y
            + params.unsafe_offset(m + 5)[]
        )
        x = nx
        y = ny
        if step < BURN:
            continue

        # IFS space to the meadow: flip, lean about the base, scale, stand.
        var fx = x * flip * scale
        var fy = y * scale
        var px = Int(base_x + fx * lean_c + fy * lean_s)
        var py = Int(base_y - fy * lean_c + fx * lean_s)
        if px < 0 or px >= W or py < 0 or py >= H:
            continue
        var pat = py * W + px
        _ = Atomic.fetch_add(nacc.unsafe_offset(pat), UInt32(1))
        _ = Atomic.fetch_add(racc.unsafe_offset(pat), cr)
        _ = Atomic.fetch_add(gacc.unsafe_offset(pat), cg)
        _ = Atomic.fetch_add(bacc.unsafe_offset(pat), cb)


def shade_kernel(
    frame: Pointer[UInt32, MutAnyOrigin],
    backdrop: Pointer[UInt32, MutAnyOrigin],
    nacc: Pointer[UInt32, MutAnyOrigin],
    racc: Pointer[UInt32, MutAnyOrigin],
    gacc: Pointer[UInt32, MutAnyOrigin],
    bacc: Pointer[UInt32, MutAnyOrigin],
):
    """Densities over the backdrop, straight to BGRA.

    The MEAN of the accumulated colour is the fern's true shade wherever ferns
    overlap. Coverage n/(n+K) is a curve density can push toward opaque but
    never past it, so the spine goes solid, the wisps stay wisps, and nothing
    blows out to white however many streams happen to land on one pixel.
    """
    var idx = Int(global_idx.x)
    if idx >= PIXELS:
        return
    var back = backdrop.unsafe_offset(idx)[]
    var n = nacc.unsafe_offset(idx)[]
    if n == 0:
        frame.unsafe_offset(idx)[] = back
        return
    var dens = Float32(Int(n))
    var a = dens / (dens + TONE_K)
    var mr = Float32(Int(racc.unsafe_offset(idx)[])) / dens
    var mg = Float32(Int(gacc.unsafe_offset(idx)[])) / dens
    var mb = Float32(Int(bacc.unsafe_offset(idx)[])) / dens
    var br = Float32(Int((back >> 16) & 0xFF))
    var bg = Float32(Int((back >> 8) & 0xFF))
    var bb = Float32(Int(back & 0xFF))
    var outr = UInt32(Int(br + (mr - br) * a))
    var outg = UInt32(Int(bg + (mg - bg) * a))
    var outb = UInt32(Int(bb + (mb - bb) * a))
    frame.unsafe_offset(idx)[] = (
        outb | (outg << 8) | (outr << 16) | (UInt32(255) << 24)
    )


def probe_kernel(
    counters: Pointer[UInt32, MutAnyOrigin],
    weighted: Pointer[UInt32, MutAnyOrigin],
):
    """Sixty-five thousand threads hammering 256 slots, sixteen times each.

    The whole program is built on increments not going missing when thousands
    of streams hit the same pixel of a fern's spine in the same instant. If
    the backend lowered these as a load-add-store instead of an atomic the
    picture would still look like a fern -- just quietly, undetectably thin.
    So it is counted instead of assumed.
    """
    var idx = Int(global_idx.x)
    if idx >= PROBE_THREADS:
        return
    var state = UInt32(idx) * UInt32(2654435761) | 1
    for k in range(PROBE_HITS):
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        var slot = Int(state % UInt32(PROBE_SLOTS))
        _ = Atomic.fetch_add(counters.unsafe_offset(slot), UInt32(1))
        _ = Atomic.fetch_add(weighted.unsafe_offset(slot), UInt32(7))
        _ = k


# ===----------------------------------------------------------------------=== #
# The backdrop: cloud sky and lawn, painted by the CPU once per landscape.
# ===----------------------------------------------------------------------=== #


def _lattice(mut rng: Rng, nx: Int, ny: Int) -> List[Float64]:
    var out = List[Float64]()
    for _k in range(nx * ny):
        out.append(rng.next())
    return out^


def _bilerp(
    lat: List[Float64], nx: Int, ny: Int, u: Float64, v: Float64
) -> Float64:
    var x = u * Float64(nx - 1)
    var y = v * Float64(ny - 1)
    var xi = Int(x)
    var yi = Int(y)
    if xi >= nx - 1:
        xi = nx - 2
    if yi >= ny - 1:
        yi = ny - 2
    var fx = x - Float64(xi)
    var fy = y - Float64(yi)
    fx = fx * fx * (3.0 - 2.0 * fx)
    fy = fy * fy * (3.0 - 2.0 * fy)
    var a = lat[yi * nx + xi]
    var b = lat[yi * nx + xi + 1]
    var c = lat[(yi + 1) * nx + xi]
    var d = lat[(yi + 1) * nx + xi + 1]
    return (a * (1.0 - fx) + b * fx) * (1.0 - fy) + (
        c * (1.0 - fx) + d * fx
    ) * fy


def paint_backdrop(host: Pointer[UInt32, MutAnyOrigin], mut rng: Rng):
    """Dusk sky with value-noise clouds, then the lawn: fourteen thousand
    blades, taller and brighter the nearer they stand, painted back to front.
    """
    var coarse = _lattice(rng, NCX, NCY)
    var fine = _lattice(rng, NFX, NFY)

    for py in range(H):
        if Float64(py) < HORIZON:
            var t = Float64(py) / HORIZON
            var r = 10.0 + t * 36.0
            var g = 12.0 + t * 28.0
            var b = 34.0 + t * 24.0
            for px in range(W):
                var u = Float64(px) / Float64(W)
                var n = 0.65 * _bilerp(
                    coarse, NCX, NCY, u, t
                ) + 0.35 * _bilerp(fine, NFX, NFY, u, t)
                var cloud = (n - 0.52) / 0.30
                if cloud < 0.0:
                    cloud = 0.0
                elif cloud > 1.0:
                    cloud = 1.0
                cloud = cloud * cloud * (3.0 - 2.0 * cloud)
                cloud *= 0.75 - 0.55 * t
                var cr = r + (96.0 - r) * cloud
                var cg = g + (100.0 - g) * cloud
                var cb = b + (122.0 - b) * cloud
                host.unsafe_offset(py * W + px)[] = (
                    UInt32(Int(cb))
                    | (UInt32(Int(cg)) << 8)
                    | (UInt32(Int(cr)) << 16)
                    | (UInt32(255) << 24)
                )
        else:
            var t = (Float64(py) - HORIZON) / (Float64(H) - HORIZON)
            var r = Int(16.0 - t * 7.0)
            var g = Int(26.0 - t * 9.0)
            var b = Int(13.0 - t * 6.0)
            var pixel = (
                UInt32(b)
                | (UInt32(g) << 8)
                | (UInt32(r) << 16)
                | (UInt32(255) << 24)
            )
            for px in range(W):
                host.unsafe_offset(py * W + px)[] = pixel

    for k in range(BLADES):
        var depth = Float64(k) / Float64(BLADES)
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
                var lit = 0.72 + 0.42 * a
                host.unsafe_offset(py * W + px)[] = (
                    UInt32(Int(br * lit))
                    | (UInt32(Int(gr * lit)) << 8)
                    | (UInt32(Int(rr * lit)) << 16)
                    | (UInt32(255) << 24)
                )
            i += 1.0


# ===----------------------------------------------------------------------=== #
# Presentation. The shade kernel already produced finished BGRA, so the only
# HLSL left in the whole program is a texture fetch.
# ===----------------------------------------------------------------------=== #

comptime HLSL: StaticString = """
Texture2D<float4> meadow : register(t0);

struct VSOut { float4 pos : SV_Position; };

// No vertex buffer: three vertices whose positions are synthesised from the
// vertex id, which is the cheapest way to cover a screen.
VSOut vsmain(uint id : SV_VertexID) {
    VSOut o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    return o;
}

float4 psmain(VSOut i) : SV_Target {
    return meadow.Load(int3((int)i.pos.x, (int)i.pos.y, 0));
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
        com_addr(code_addr),
        com_addr(errors_addr),
    )
    # The three buffers must outlive the call that reads them.
    _ = src
    _ = entry_name
    _ = target
    if hr != 0:
        var detail = String("(no message)")
        if errors_addr != 0:
            detail = blob_text(
                ComPtr[StaticString("ID3DBlob")](adopt=errors_addr)
            )
        raise Error("D3DCompile(" + String(entry) + ") failed: " + detail)
    return ComPtr[StaticString("ID3DBlob")](adopt=code_addr)


def display_refresh_hz() raises -> Int:
    """The primary display's refresh rate, for the present interval.

    Returns:
        The refresh rate in hertz, or 60 if it cannot be read.

    Raises:
        If the settings query cannot be made at all.
    """
    comptime DM_BYTES = winkb_struct_size["DEVMODEW"]()
    comptime DM_SIZE_AT = winkb_field_offset["DEVMODEW", "dmSize"]()
    comptime FREQ_AT = winkb_field_offset["DEVMODEW", "dmDisplayFrequency"]()

    # DEVMODEW is never declared here, only sized: it is 272 bytes of fields
    # this program does not care about, and two it does.
    var settings = List[UInt8](length=DM_BYTES, fill=0)
    var base = settings.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    base.unsafe_offset(DM_SIZE_AT).unsafe_bitcast[UInt16]()[] = UInt16(DM_BYTES)

    var EnumDisplaySettingsW = win32[
        def (Int, UInt32, Pointer[UInt8, MutAnyOrigin]) thin abi("C") -> c_int,
        "EnumDisplaySettingsW",
    ]()
    # ENUM_CURRENT_SETTINGS is (DWORD)-1.
    if EnumDisplaySettingsW(0, UInt32(0xFFFFFFFF), base) == 0:
        return 60
    var hz = Int(base.unsafe_offset(FREQ_AT).unsafe_bitcast[UInt32]()[])
    _ = settings
    return hz if hz > 1 else 60


def atomics_hold(mut ctx: DeviceContext) raises -> Bool:
    """Proves global-memory atomic adds on this device before anything else.

    Args:
        ctx: The accelerator, already open.

    Returns:
        True when every increment was accounted for.

    Raises:
        If the device rejects the launch.
    """
    var counters = ctx.enqueue_create_buffer[DType.uint32](PROBE_SLOTS)
    var weighted = ctx.enqueue_create_buffer[DType.uint32](PROBE_SLOTS)
    var host_n = ctx.enqueue_create_host_buffer[DType.uint32](PROBE_SLOTS)
    var host_w = ctx.enqueue_create_host_buffer[DType.uint32](PROBE_SLOTS)
    ctx.synchronize()

    ctx.enqueue_memset(counters, UInt32(0))
    ctx.enqueue_memset(weighted, UInt32(0))
    ctx.enqueue_function[probe_kernel](
        counters, weighted, grid_dim=PROBE_GRID, block_dim=BLOCK
    )
    host_n.enqueue_copy_from(counters)
    host_w.enqueue_copy_from(weighted)
    ctx.synchronize()

    var total = 0
    var total_w = 0
    for i in range(PROBE_SLOTS):
        total += Int(host_n[i])
        total_w += Int(host_w[i])
    var want = PROBE_THREADS * PROBE_HITS

    print(
        "atomics       ",
        total,
        "of",
        want,
        "increments survived,",
        total_w,
        "of",
        want * 7,
        "weighted",
    )
    return total == want and total_w == want * 7


# ===----------------------------------------------------------------------=== #


def main() raises:
    # Without this Windows reports a smaller desktop than there is, lets the
    # process draw at that size and stretches the result -- a soft meadow, and
    # clicks that land somewhere other than where they were aimed. -4 is
    # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2; it is a sentinel handle
    # value rather than an enumerator, so it is not in the metadata to be
    # looked up, and this is the only place it can be written.
    try:
        var SetProcessDpiAwarenessContext = win32[
            def (Int) thin abi("C") -> c_int,
            "SetProcessDpiAwarenessContext",
        ]()
        _ = SetProcessDpiAwarenessContext(-4)
    except:
        pass

    # Windows describes its own structures. A disagreement is a build failure
    # here rather than corruption at the first call.
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
        size_of[DXGI_SWAP_CHAIN_DESC]()
        == winkb_struct_size["DXGI_SWAP_CHAIN_DESC"]()
    ), "DXGI_SWAP_CHAIN_DESC does not match Windows"
    comptime assert (
        size_of[D3D11_TEXTURE2D_DESC]()
        == winkb_struct_size["D3D11_TEXTURE2D_DESC"]()
    ), "D3D11_TEXTURE2D_DESC does not match Windows"
    comptime assert (
        size_of[D3D11_VIEWPORT]() == winkb_struct_size["D3D11_VIEWPORT"]()
    ), "D3D11_VIEWPORT does not match Windows"

    var frame_limit = 0
    var door = getenv("FERNWIND_FRAMES")
    if door != "":
        frame_limit = Int(door)

    var hz_counter = performance_frequency()

    # ---- the accelerator, and the fact everything rests on ------------------
    var ctx = DeviceContext(api="cuda")
    print("Fernwind —", ctx.name())
    print(
        "flame         ",
        STREAMS,
        "streams x",
        ITERS,
        "plotted points =",
        STREAMS * ITERS // 1000000,
        "M points per frame",
    )
    if not atomics_hold(ctx):
        raise Error(
            "global atomic adds lose increments on this device -- the whole"
            " design rests on them, so this refuses to draw a picture it"
            " cannot vouch for"
        )
    print("              ", "all present, so the density buffers are sound")

    var nacc = ctx.enqueue_create_buffer[DType.uint32](PIXELS)
    var racc = ctx.enqueue_create_buffer[DType.uint32](PIXELS)
    var gacc = ctx.enqueue_create_buffer[DType.uint32](PIXELS)
    var bacc = ctx.enqueue_create_buffer[DType.uint32](PIXELS)
    var backdrop = ctx.enqueue_create_buffer[DType.uint32](PIXELS)
    var frame_dev = ctx.enqueue_create_buffer[DType.uint32](PIXELS)
    var params_dev = ctx.enqueue_create_buffer[DType.float32](PARAM_FLOATS)

    # Pinned host staging. `frame_host` is what the texture upload reads from,
    # so nothing is copied on the CPU between the readback and the upload.
    var frame_host = ctx.enqueue_create_host_buffer[DType.uint32](PIXELS)
    var back_host = ctx.enqueue_create_host_buffer[DType.uint32](PIXELS)
    var params_host = ctx.enqueue_create_host_buffer[DType.float32](
        PARAM_FLOATS
    )
    ctx.synchronize()

    var back_ptr = back_host.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()

    # ---- the window ---------------------------------------------------------
    var GetModuleHandleW = win32[
        def (Int) thin abi("C") -> Int, "GetModuleHandleW"
    ]()
    var GetLastError = win32[def () thin abi("C") -> UInt32, "GetLastError"]()
    var LoadCursorW = win32[def (Int, Int) thin abi("C") -> Int, "LoadCursorW"]()
    var RegisterClassExW = win32[
        def (Pointer[WNDCLASSEXW, MutAnyOrigin]) thin abi("C") -> UInt16,
        "RegisterClassExW",
    ]()
    var AdjustWindowRectEx = win32[
        def (
            Pointer[RECT, MutAnyOrigin], UInt32, c_int, UInt32
        ) thin abi("C") -> c_int,
        "AdjustWindowRectEx",
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
    var SetWindowLongPtrW = win32[
        def (Int, c_int, Int) thin abi("C") -> Int, "SetWindowLongPtrW"
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
    var DestroyWindow = win32[
        def (Int) thin abi("C") -> c_int, "DestroyWindow"
    ]()

    var hInstance = GetModuleHandleW(0)
    var class_name = wide("MojoFernwindWindow")
    var title = wide(
        "Fernwind - a GPU meadow swaying - click plants, space stills, r reseeds"
    )
    var proc: WndProcType = fernwind_wndproc

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

    # The client area must be exactly W x H, or the swap chain and the window
    # disagree and DXGI stretches the meadow. AdjustWindowRectEx asks Windows
    # how much frame this style needs rather than guessing at 16 and 39.
    comptime STYLE = winkb_constant["WS_OVERLAPPEDWINDOW"]()
    var want = RECT(0, 0, Int32(W), Int32(H))
    _ = AdjustWindowRectEx(com_addr(want), UInt32(STYLE), c_int(0), UInt32(0))
    var win_w = Int(want.right - want.left)
    var win_h = Int(want.bottom - want.top)

    var hwnd = CreateWindowExW(
        UInt32(0),
        class_name.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        title.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        UInt32(STYLE),
        c_int(90), c_int(90), c_int(win_w), c_int(win_h),
        0, 0, hInstance, 0,
    )
    if hwnd == 0:
        raise Error(
            "CreateWindowExW failed, GetLastError = " + String(GetLastError())
        )
    # The class name and title buffers must outlive the calls that read them.
    _ = class_name
    _ = title

    # Emplaced, not assigned: `store[] = value` destroys what was there first,
    # and what is there is whatever the allocator last had.
    var store = alloc[Commands](1, alignment=8)
    store.unsafe_write(Commands())
    _ = SetWindowLongPtrW(
        hwnd, c_int(winkb_constant["GWLP_USERDATA"]()), Int(store)
    )

    _ = ShowWindow(hwnd, c_int(winkb_constant["SW_SHOW"]()))
    _ = UpdateWindow(hwnd)

    # ---- Direct3D 11 --------------------------------------------------------
    var create_device = win32[
        def (
            Int, UInt32, Int, UInt32, Int, UInt32, UInt32,
            Pointer[DXGI_SWAP_CHAIN_DESC, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> Int32,
        "D3D11CreateDeviceAndSwapChain",
    ]()
    var D3DCompile = win32[
        def (
            Int, Int, Int, Int, Int, Int, Int, UInt32, UInt32,
            Pointer[Int, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> Int32,
        "D3DCompile",
    ]()

    var desc = DXGI_SWAP_CHAIN_DESC()
    desc.Width = UInt32(W)
    desc.Height = UInt32(H)
    desc.RefreshRateNumerator = 60
    desc.RefreshRateDenominator = 1
    desc.Format = 87  # DXGI_FORMAT_B8G8R8A8_UNORM
    desc.SampleCount = 1
    desc.BufferUsage = 32  # DXGI_USAGE_RENDER_TARGET_OUTPUT
    desc.BufferCount = 2
    desc.OutputWindow = hwnd
    desc.Windowed = 1
    desc.SwapEffect = 4  # DXGI_SWAP_EFFECT_FLIP_DISCARD

    # Four separate out-parameters need four separate locals: several mutable
    # pointers into one object in one call is "aliasing values passed mutably".
    var swapchain_addr: Int = 0
    var device_addr: Int = 0
    var level: Int = 0
    var context_addr: Int = 0
    var hr = create_device(
        0, UInt32(1), 0, UInt32(0), 0, UInt32(0), UInt32(7),
        com_addr(desc),
        com_addr(swapchain_addr),
        com_addr(device_addr),
        com_addr(level),
        com_addr(context_addr),
    )
    _ = desc
    if hr != 0 or swapchain_addr == 0:
        raise Error("Direct3D device creation failed, hr = " + String(hr))

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
            ) thin abi("C") -> Int32,
            "IDXGISwapChain",
            "GetBuffer",
        ](swapchain)(
            swapchain,
            UInt32(0),
            iid_texture.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            com_addr(backbuf_addr),
        )
        != 0
    ):
        raise Error("GetBuffer failed")
    _ = iid_texture
    var backbuffer = ComPtr[StaticString("ID3D11Texture2D")](
        adopt=backbuf_addr
    )

    var rtv_addr: Int = 0
    if (
        com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], Int, Int,
                Pointer[Int, MutAnyOrigin],
            ) thin abi("C") -> Int32,
            "ID3D11Device",
            "CreateRenderTargetView",
        ](device)(device, backbuf_addr, 0, com_addr(rtv_addr))
        != 0
    ):
        raise Error("CreateRenderTargetView failed")

    # The texture the finished meadow lands in. B8G8R8A8_UNORM is exactly the
    # word the shade kernel wrote, so the pixel shader is one Load.
    var tex_desc = D3D11_TEXTURE2D_DESC()
    tex_desc.Width = UInt32(W)
    tex_desc.Height = UInt32(H)
    tex_desc.MipLevels = 1
    tex_desc.ArraySize = 1
    tex_desc.Format = 87  # DXGI_FORMAT_B8G8R8A8_UNORM
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
            ) thin abi("C") -> Int32,
            "ID3D11Device",
            "CreateTexture2D",
        ](device)(device, com_addr(tex_desc), 0, com_addr(tex_addr))
        != 0
    ):
        raise Error("CreateTexture2D failed")
    _ = tex_desc
    var texture = ComPtr[StaticString("ID3D11Texture2D")](adopt=tex_addr)

    var srv_addr: Int = 0
    if (
        com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], Int, Int,
                Pointer[Int, MutAnyOrigin],
            ) thin abi("C") -> Int32,
            "ID3D11Device",
            "CreateShaderResourceView",
        ](device)(
            device,
            tex_addr,
            0,  # NULL desc: the whole resource, in its own format
            com_addr(srv_addr),
        )
        != 0
    ):
        raise Error("CreateShaderResourceView failed")

    var vs_blob = compile_shader(D3DCompile, HLSL, "vsmain", "vs_5_0")
    var ps_blob = compile_shader(D3DCompile, HLSL, "psmain", "ps_5_0")

    var vs_addr: Int = 0
    if (
        com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], Int, Int, Int,
                Pointer[Int, MutAnyOrigin],
            ) thin abi("C") -> Int32,
            "ID3D11Device",
            "CreateVertexShader",
        ](device)(
            device, blob_ptr(vs_blob), blob_size(vs_blob), 0,
            com_addr(vs_addr),
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
            ) thin abi("C") -> Int32,
            "ID3D11Device",
            "CreatePixelShader",
        ](device)(
            device, blob_ptr(ps_blob), blob_size(ps_blob), 0,
            com_addr(ps_addr),
        )
        != 0
    ):
        raise Error("CreatePixelShader failed")
    var pshader = ComPtr[StaticString("ID3D11PixelShader")](adopt=ps_addr)

    # ---- pipeline state that never changes ---------------------------------
    var viewport = D3D11_VIEWPORT()
    viewport.Width = Float32(W)
    viewport.Height = Float32(H)
    viewport.MaxDepth = 1.0
    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            Pointer[D3D11_VIEWPORT, MutAnyOrigin],
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "RSSetViewports",
    ](context)(context, UInt32(1), com_addr(viewport))

    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int, Int, UInt32
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "VSSetShader",
    ](context)(context, vs_addr, 0, UInt32(0))

    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int, Int, UInt32
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "PSSetShader",
    ](context)(context, ps_addr, 0, UInt32(0))

    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], UInt32, UInt32,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "PSSetShaderResources",
    ](context)(context, UInt32(0), UInt32(1), com_addr(srv_addr))

    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], UInt32
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "IASetPrimitiveTopology",
    ](context)(context, UInt32(4))  # TRIANGLELIST

    var update = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,                            # pDstResource
            UInt32,                         # DstSubresource
            Int,                            # pDstBox (NULL)
            Pointer[UInt8, MutAnyOrigin],   # pSrcData
            UInt32,                         # SrcRowPitch, in BYTES
            UInt32,                         # SrcDepthPitch
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
        ) thin abi("C") -> Int32,
        "IDXGISwapChain",
        "Present",
    ](swapchain)

    var hz = display_refresh_hz()
    var interval = (hz + 30) // 60
    if interval < 1:
        interval = 1

    # ---- the meadow ---------------------------------------------------------
    var maps = barnsley()
    var rng = Rng(0x5EED)
    var ferns = List[Fern]()
    var landscape = 0
    var need_seed = True
    var next_slot = 0

    print()
    print("click plants a fern · space stills the air · r reseeds · q quits")
    if frame_limit != 0:
        print("FERNWIND_FRAMES =", frame_limit, "— will close itself")

    var msg = MSG()
    var frames = 0
    var running = True
    var still = False
    var occluded = 0
    var t = 0.0  # wind time, in seconds
    var loop_start = performance_counter()
    var last_tick = loop_start

    while running:
        while (
            PeekMessageW(com_addr(msg), 0, UInt32(0), UInt32(0), UInt32(1))
            != 0
        ):
            # PeekMessageW REMOVES WM_QUIT from the queue, so the loop has to
            # test for it: DispatchMessageW will not do it for you.
            if msg.message == UInt32(winkb_constant["WM_QUIT"]()):
                running = False
            else:
                _ = TranslateMessage(com_addr(msg))
                _ = DispatchMessageW(com_addr(msg))
        if not running:
            break

        var pending = store[].cmd
        if pending != 0:
            store[].cmd = 0
            if (pending & CMD_CLICK) != 0:
                var fern = make_fern(
                    rng, Float64(store[].click_x), Float64(store[].click_y)
                )
                if len(ferns) < MAX_FERNS:
                    ferns.append(fern)
                else:
                    ferns[next_slot] = fern
                    next_slot = (next_slot + 1) % MAX_FERNS
            if (pending & CMD_PAUSE) != 0:
                still = not still
            if (pending & CMD_RESET) != 0:
                need_seed = True
            if (pending & CMD_QUIT) != 0:
                _ = DestroyWindow(hwnd)

        if need_seed:
            need_seed = False
            landscape += 1
            next_slot = 0
            ferns.clear()
            paint_backdrop(back_ptr, rng)
            backdrop.enqueue_copy_from(back_host)
            for k in range(SEED_FERNS):
                var bx = (Float64(k) + 0.18 + rng.next() * 0.64) * (
                    Float64(W) / Float64(SEED_FERNS)
                )
                var by = HORIZON + 12.0 + rng.next() * (
                    Float64(H) - HORIZON - 24.0
                )
                ferns.append(make_fern(rng, bx, by))
            ctx.synchronize()
            print("landscape", landscape, "—", len(ferns), "ferns")

        # ---- the wind, and this frame's parameters --------------------------
        # Gusts travel across the meadow: each fern reads the field a little
        # later the further right it stands. The climb map is rotated by the
        # local wind, and recursion turns that uniform rotation into a
        # progressive bend up the plant.
        #
        # The Mac original steps `t` by a fixed 1/60 because its frame budget
        # is never in question. Here the step is the frame that actually
        # elapsed, clamped: a T1000 does not always hold 60, and a fixed step
        # would put the wind into slow motion rather than dropping frames of
        # it, which looks like a bug and is one.
        var now = performance_counter()
        var dt = Float64(now - last_tick) / Float64(hz_counter)
        last_tick = now
        if dt > 0.0667:
            dt = 0.0667
        if not still:
            t += dt

        params_host[0] = Float32(len(ferns))
        params_host[1] = Float32(frames % 8388608)
        for i in range(len(ferns)):
            var fern = ferns[i]
            var local = t - fern.phase
            var gust = 0.6 + 0.4 * sin(local * 0.31 + 1.2)
            var wind = gust * (
                0.5 * sin(local * 0.9)
                + 0.3 * sin(local * 2.3 + 0.8)
                + 0.2 * sin(local * 0.13)
            )
            var lean = fern.lean0 + wind * 0.10 * fern.supple
            var bend = (
                wind * 0.030 + 0.010 * sin(local * 3.1)
            ) * fern.supple * fern.flip
            var bc = cos(bend)
            var bs = sin(bend)
            var at = PARAM_HEAD + i * PARAM_STRIDE
            params_host[at + 0] = Float32(fern.base_x)
            params_host[at + 1] = Float32(fern.base_y)
            params_host[at + 2] = Float32(fern.scale)
            params_host[at + 3] = Float32(fern.flip)
            params_host[at + 4] = Float32(fern.r)
            params_host[at + 5] = Float32(fern.g)
            params_host[at + 6] = Float32(fern.b)
            params_host[at + 7] = Float32(cos(lean))
            params_host[at + 8] = Float32(sin(lean))
            var acc = 0.0
            for m in range(4):
                var src = maps[m]
                var a = src.a
                var b = src.b
                var c = src.c
                var d = src.d
                var e = src.e
                var f = src.f
                if m == 1:
                    # R(bend) after the climb map: the linear part and the
                    # translation both rotate, and the root stays put.
                    a = bc * src.a - bs * src.c
                    b = bc * src.b - bs * src.d
                    c = bs * src.a + bc * src.c
                    d = bs * src.b + bc * src.d
                    e = bc * src.e - bs * src.f
                    f = bs * src.e + bc * src.f
                acc += src.p
                var ma = at + 9 + m * 7
                params_host[ma + 0] = Float32(a)
                params_host[ma + 1] = Float32(b)
                params_host[ma + 2] = Float32(c)
                params_host[ma + 3] = Float32(d)
                params_host[ma + 4] = Float32(e)
                params_host[ma + 5] = Float32(f)
                params_host[ma + 6] = Float32(acc)

        # ---- the frame, computed from scratch --------------------------------
        params_dev.enqueue_copy_from(params_host)
        ctx.enqueue_memset(nacc, UInt32(0))
        ctx.enqueue_memset(racc, UInt32(0))
        ctx.enqueue_memset(gacc, UInt32(0))
        ctx.enqueue_memset(bacc, UInt32(0))
        ctx.enqueue_function[chaos_kernel](
            nacc, racc, gacc, bacc, params_dev,
            grid_dim=GRID, block_dim=BLOCK,
        )
        ctx.enqueue_function[shade_kernel](
            frame_dev, backdrop, nacc, racc, gacc, bacc,
            grid_dim=PIX_GRID, block_dim=BLOCK,
        )
        frame_host.enqueue_copy_from(frame_dev)
        ctx.synchronize()

        update(
            context,
            tex_addr,
            UInt32(0),
            0,
            frame_host.unsafe_ptr()
            .unsafe_bitcast[UInt8]()
            .unsafe_origin_cast[MutAnyOrigin](),
            UInt32(W * 4),
            UInt32(0),
        )

        # Flip-model Present UNBINDS the render target, so rebinding once
        # before the loop leaves every alternate frame drawing into nothing.
        set_targets(context, UInt32(1), com_addr(rtv_addr), 0)
        draw(context, UInt32(3), UInt32(0))

        # Declared Int32 so the sign survives: an HRESULT comes back in EAX,
        # and read into a 64-bit integer a failure code looks positive. Only
        # a negative code is a failure -- DXGI_STATUS_OCCLUDED (0x087A0001)
        # is a success that means "nobody can see this", which is a machine
        # state, not a bug, and is worth saying rather than dying of.
        var phr = present(swapchain, UInt32(interval), UInt32(0))
        if phr < 0:
            raise Error("Present failed, hr = " + String(phr))
        if phr != 0:
            occluded += 1

        frames += 1
        if frames % 240 == 0:
            var elapsed = Float64(
                performance_counter() - loop_start
            ) / Float64(hz_counter)
            print(
                "  frame", frames, "—",
                Int(Float64(frames) / elapsed), "fps",
            )
        if frame_limit != 0 and frames >= frame_limit:
            running = False

    var secs = Float64(performance_counter() - loop_start) / Float64(
        hz_counter
    )

    # Did anything actually get drawn? The backdrop is known, so counting the
    # pixels the ferns changed is a cheap, honest answer to "did the GPU put
    # a meadow there", and it does not depend on anybody looking at a screen.
    var inked = 0
    for k in range(PIXELS):
        if frame_host[k] != back_host[k]:
            inked += 1

    print()
    print(
        "swayed", landscape, "landscape(s) over", frames, "frames in",
        Int(secs * 1000.0), "ms",
    )
    if secs > 0.0:
        print("              ", Int(Float64(frames) / secs), "fps")
    print(
        "last frame     ",
        inked,
        "of",
        PIXELS,
        "pixels carry fern —",
        inked * 100 // PIXELS,
        "percent coverage",
    )
    if occluded != 0:
        print(
            "presentation   ",
            occluded,
            "of",
            frames,
            "frames were reported OCCLUDED and were not shown",
        )

    var dump = getenv("FERNWIND_DUMP")
    if dump != "":
        var bytes = List[UInt8](length=PIXELS * 4, fill=0)
        var dst = bytes.unsafe_ptr().unsafe_bitcast[UInt32]()
        for k in range(PIXELS):
            dst.unsafe_offset(k)[] = frame_host[k]
        # `with open(...)` would not close until this function returns, and a
        # write followed by anything touching the file gets a sharing
        # violation every time.
        var out = open(dump, "w")
        out.write_all(Span(bytes))
        out.close()
        print("dumped", W, "x", H, "BGRA to", dump)

    store.unsafe_free()
    _ = backbuffer^
    _ = texture^
    _ = vshader^
    _ = pshader^
    _ = vs_blob^
    _ = ps_blob^
