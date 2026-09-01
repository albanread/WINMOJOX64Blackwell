# ===----------------------------------------------------------------------=== #
# Conway's Game of Life -- a native Win32 version, in Mojo.
#
# What a minimal Life doesn't do, and this does:
#   * pause and resume, and single-step while paused
#   * draw cells with the mouse (and erase with shift or the right button),
#     with mouse capture so a drag that leaves the window keeps drawing
#   * colour cells by AGE -- newborns burn white-hot, survivors settle through
#     cyan and green to deep blue, and cells that die leave a fading ember
#     trail, so you can see the structure of a pattern rather than a flat mask
#   * clear, randomise, and speed control, with live stats in the title bar
#
# Rendering is a BGRA buffer pushed into the window's device context by
# StretchDIBits, which is the shortest honest path from CPU-computed pixels to
# the screen on Windows: no swap chain, no D3D device, no COM, and nothing that
# can be lost and need recreating. The buffer is stretched to the client
# rectangle, so the window resizes and the mouse mapping follows. That blit is
# `std.windows.gui.present_bgra` -- this file no longer spells StretchDIBits.
#
# The window, its class, the message loop, `RECT`, `BITMAPINFOHEADER` and the
# UTF-16 conversion all come from `std.windows.gui` and `std.windows.core`.
# What is left in this file is Life: the rule, the colouring, the mouse, the
# keys, and the evidence that the picture reached the glass. If you are reading
# this to learn how a Win32 window is made, read `std/windows/gui.mojo`; if you
# are reading it to learn what to do with one, read on.
#
# Every Windows-shaped thing here -- which DLL exports each entry point, every
# constant, the size of PAINTSTRUCT -- is a query against windows_api.db. There
# is not a hand-declared DLL name, message number, or struct size in the file.
#
# Run it:
#     main.exe                     interactive
#     main.exe --selftest          check three known patterns, then open the
#                                  window, read its pixels back, and close
#     main.exe --selftest --ms N   as above, holding the window open N ms
# ===----------------------------------------------------------------------=== #

from std.ffi import c_int
from std.collections import Span
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.random import random_ui64, seed
from std.sys import argv
from std.sys.info import size_of
from std.sys._com import com_addr
from std.sys._winkb import (
    winkb_constant,
    winkb_db_schema_version,
    winkb_struct_size,
)
from std.windows import (
    WideString,
    performance_counter,
    performance_frequency,
)
from std.windows.gui import (
    BITMAPINFOHEADER,
    RECT,
    Window,
    WindowClass,
    WndProc,
    default_handler,
    present_bgra,
    quit,
    run,
    win32,
)


comptime CELL = 6  # pixels per cell, including a one-pixel gutter
comptime GRID_W = 180
comptime GRID_H = 120
comptime WIN_W = GRID_W * CELL  # 1080
comptime WIN_H = GRID_H * CELL  # 720
comptime CELLS = GRID_W * GRID_H
comptime PIXELS = WIN_W * WIN_H
comptime MAX_AGE = 64

comptime TICK_TIMER_ID = 1
comptime TICK_MS = 16  # the clock; `speed` decides how many ticks per step


# ===----------------------------------------------------------------------===#
# The state the window carries
#
# `WNDCLASSEXW`, `MSG`, `RECT` and `BITMAPINFOHEADER` used to be declared here,
# each with its own compile-time size assertion. They live in
# `std.windows.gui` now, asserted once, and this file imports the two it still
# touches. `win32[]` and a pair of hand-rolled `wide()` helpers went the same
# way -- `WideString` is a real UTF-16 conversion and the copies here were
# Latin-1 wearing a hat.
# ===----------------------------------------------------------------------===#


@fieldwise_init
struct Life(Defaultable, Copyable, Movable):
    """Everything the window knows.

    A window procedure is captureless -- Windows calls it, so it holds nothing
    and must fetch what it needs from the one pointer a window can keep. This
    is that thing, on the heap, reached through GWLP_USERDATA.

    The five buffers are addresses rather than pointers because `Pointer` is
    non-nullable, so an address of zero cannot be spelled; they are turned into
    pointers only where they are used.
    """

    var alive: Int  # UInt8*   one byte per cell, 0 or 1
    var scratch: Int  # UInt8*   next generation, then swapped with `alive`
    var age: Int  # UInt16*  generations survived, capped at MAX_AGE
    var decay: Int  # UInt8*   ember left by a cell that has just died
    var frame: Int  # UInt32*  BGRA pixels, WIN_W x WIN_H

    var gen: Int
    var running: Int
    var speed: Int  # step every `speed` ticks: bigger is slower
    var subtick: Int
    var dirty: Int  # something changed that the picture does not show yet
    var retitle: Int  # a state change the title must show at once
    var painted: Int  # frames actually blitted, for the self-test
    var ticks: Int
    var step_us: Int  # last evolve + render, microseconds
    var hz: Int  # performance counter frequency

    var close_at: Int  # tick to self-destruct on; 0 means never
    var sample_at: Int  # tick to read the window's own pixels back on
    var sampled: Int

    def __init__(out self):
        self.alive = 0
        self.scratch = 0
        self.age = 0
        self.decay = 0
        self.frame = 0
        self.gen = 0
        self.running = 1
        self.speed = 3
        self.subtick = 0
        self.dirty = 1
        self.retitle = 1
        self.painted = 0
        self.ticks = 0
        self.step_us = 0
        self.hz = 1
        self.close_at = 0
        self.sample_at = 0
        self.sampled = 0


comptime LifePtr = Pointer[Life, MutAnyOrigin]


def bytes_at(addr: Int) -> Pointer[UInt8, MutUntrackedOrigin]:
    """Memory Windows and the allocator own, not Mojo -- hence Untracked."""
    return Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)


def words_at(addr: Int) -> Pointer[UInt16, MutUntrackedOrigin]:
    return Pointer[UInt16, MutUntrackedOrigin](unsafe_from_address=addr)


def dwords_at(addr: Int) -> Pointer[UInt32, MutUntrackedOrigin]:
    return Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=addr)


# ===----------------------------------------------------------------------===#
# The simulation
# ===----------------------------------------------------------------------===#


def evolve(life: LifePtr):
    """One generation, on a wrapped torus so gliders sail off one edge and
    back in at the other.

    Age and decay ride along with the rule: a cell that survives gets older, a
    cell that dies resets to nothing and leaves an ember behind. That is the
    whole of the colouring -- the rule itself is the ordinary one.
    """
    var alive = bytes_at(life[].alive)
    var nxt = bytes_at(life[].scratch)
    var age = words_at(life[].age)
    var decay = bytes_at(life[].decay)

    for y in range(GRID_H):
        var up = (y + GRID_H - 1) % GRID_H * GRID_W
        var mid = y * GRID_W
        var dn = (y + 1) % GRID_H * GRID_W
        for x in range(GRID_W):
            var l = (x + GRID_W - 1) % GRID_W
            var r = (x + 1) % GRID_W
            var n = (
                Int(alive[unsafe_offset = up + l])
                + Int(alive[unsafe_offset = up + x])
                + Int(alive[unsafe_offset = up + r])
                + Int(alive[unsafe_offset = mid + l])
                + Int(alive[unsafe_offset = mid + r])
                + Int(alive[unsafe_offset = dn + l])
                + Int(alive[unsafe_offset = dn + x])
                + Int(alive[unsafe_offset = dn + r])
            )
            var i = mid + x
            var was = alive[unsafe_offset=i] != UInt8(0)
            var now = (was and (n == 2 or n == 3)) or ((not was) and n == 3)
            nxt[unsafe_offset=i] = UInt8(1) if now else UInt8(0)
            if now:
                var a = age[unsafe_offset=i]
                if a < UInt16(MAX_AGE):
                    age[unsafe_offset=i] = a + UInt16(1)
            else:
                age[unsafe_offset=i] = UInt16(0)
                if was:
                    decay[unsafe_offset=i] = UInt8(200)  # a fresh ember

    # Swap the two grids by swapping the addresses -- no copying.
    var a = life[].alive
    life[].alive = life[].scratch
    life[].scratch = a

    # Fade the embers.
    var d = bytes_at(life[].decay)
    for i in range(CELLS):
        var v = d[unsafe_offset=i]
        if v > UInt8(0):
            d[unsafe_offset=i] = v - UInt8(8) if v > UInt8(8) else UInt8(0)

    life[].gen += 1


def chan(v: Int) -> UInt32:
    """One colour channel, clamped.

    The ramps below run a parameter past the end of a channel at their
    extremes; without the clamp that wraps, and a deep-blue survivor flashes
    an impossible green for one generation.
    """
    if v < 0:
        return UInt32(0)
    if v > 255:
        return UInt32(255)
    return UInt32(v)


def pack(b: Int, g: Int, r: Int) -> UInt32:
    """One BGRA pixel as a little-endian 32-bit word: 0xAARRGGBB."""
    return (
        chan(b) | (chan(g) << 8) | (chan(r) << 16) | (UInt32(255) << 24)
    )


def background() -> UInt32:
    return pack(14, 12, 11)


def cell_color(age: UInt16, decay: UInt8) -> UInt32:
    """Colour tells you the cell's history.

    A newborn burns white; over its first generations it cools through cyan to
    green; a long survivor settles into deep blue. A cell that has just died
    leaves an ember that fades to the background. So a glider reads as a
    bright head with a warm tail, and a still life sits quiet and blue.
    """
    if age == UInt16(0):
        if decay == UInt8(0):
            return pack(22, 18, 16)
        var d = Int(decay)
        # An ember: dim orange-red, fading out.
        return pack(16 + d // 8, 24 + d // 4, 40 + d // 2)

    var a = Int(age)
    if a <= 2:
        return pack(235, 250, 255)  # newborn: white-hot
    if a <= 6:
        var t = (a - 2) * 255 // 4  # cooling: white -> cyan
        return pack(235, 250 - t // 6, 255 - t)
    if a <= 20:
        var t = (a - 6) * 255 // 14  # cyan -> green
        return pack(235 - t, 250, 40)
    var t = (a - 20) * 255 // (MAX_AGE - 20)  # settled: green -> deep blue
    if t > 255:
        t = 255
    return pack(40 + t // 2, 250 - t, 40 + t // 3)


def render(life: LifePtr):
    """Paint the grid into the BGRA frame buffer, one CELL x CELL block per
    cell.

    Only the (CELL-1) x (CELL-1) interior is written. The last row and column
    of every block are the gutter that keeps the lattice legible, they are
    always the background colour, and the buffer was filled with that colour
    once at start-up -- so a third of the writes a naive version does are
    writes of a value that is already there.
    """
    var alive = bytes_at(life[].alive)
    var age = words_at(life[].age)
    var decay = bytes_at(life[].decay)
    var frame = dwords_at(life[].frame)
    var bg = background()

    for cy in range(GRID_H):
        var py0 = cy * CELL
        for cx in range(GRID_W):
            var i = cy * GRID_W + cx
            var live = alive[unsafe_offset=i] != UInt8(0)
            var ember = decay[unsafe_offset=i] != UInt8(0)
            var color = bg
            if live or ember:
                color = cell_color(
                    age[unsafe_offset=i], decay[unsafe_offset=i]
                )
            var px0 = cx * CELL
            for dy in range(CELL - 1):
                var row = (py0 + dy) * WIN_W + px0
                for dx in range(CELL - 1):
                    frame[unsafe_offset = row + dx] = color


def fill_background(life: LifePtr):
    var frame = dwords_at(life[].frame)
    var bg = background()
    for i in range(PIXELS):
        frame[unsafe_offset=i] = bg


def clear_grid(life: LifePtr):
    var alive = bytes_at(life[].alive)
    var age = words_at(life[].age)
    var decay = bytes_at(life[].decay)
    for i in range(CELLS):
        alive[unsafe_offset=i] = UInt8(0)
        age[unsafe_offset=i] = UInt16(0)
        decay[unsafe_offset=i] = UInt8(0)
    life[].gen = 0
    life[].dirty = 1


def randomize(life: LifePtr):
    var alive = bytes_at(life[].alive)
    var age = words_at(life[].age)
    var decay = bytes_at(life[].decay)
    for i in range(CELLS):
        var on = random_ui64(0, 4) == UInt64(0)
        alive[unsafe_offset=i] = UInt8(1) if on else UInt8(0)
        age[unsafe_offset=i] = UInt16(1) if on else UInt16(0)
        decay[unsafe_offset=i] = UInt8(0)
    life[].gen = 0
    life[].dirty = 1


def population(life: LifePtr) -> Int:
    var alive = bytes_at(life[].alive)
    var n = 0
    for i in range(CELLS):
        if alive[unsafe_offset=i] != UInt8(0):
            n += 1
    return n


def embers(life: LifePtr) -> Int:
    """Dead cells still showing a trail -- they are painted too, so the
    self-test has to count them to predict how much of the window is lit."""
    var alive = bytes_at(life[].alive)
    var decay = bytes_at(life[].decay)
    var n = 0
    for i in range(CELLS):
        if alive[unsafe_offset=i] == UInt8(0) and decay[unsafe_offset=i] != (
            UInt8(0)
        ):
            n += 1
    return n


def set_cell(life: LifePtr, x: Int, y: Int, on: Bool):
    if x < 0 or x >= GRID_W or y < 0 or y >= GRID_H:
        return
    var alive = bytes_at(life[].alive)
    var age = words_at(life[].age)
    var i = y * GRID_W + x
    alive[unsafe_offset=i] = UInt8(1) if on else UInt8(0)
    age[unsafe_offset=i] = UInt16(1) if on else UInt16(0)


def get_cell(life: LifePtr, x: Int, y: Int) -> Bool:
    if x < 0 or x >= GRID_W or y < 0 or y >= GRID_H:
        return False
    return bytes_at(life[].alive)[unsafe_offset = y * GRID_W + x] != UInt8(0)


# ===----------------------------------------------------------------------===#
# Drawing cells with the mouse
# ===----------------------------------------------------------------------===#


def paint_cell(life: LifePtr, cx: Int, cy: Int, erase: Bool):
    """A 2x2 dab, so drawing feels like a pen rather than a pixel hunt."""
    if cx < 0 or cx >= GRID_W or cy < 0 or cy >= GRID_H:
        return
    var alive = bytes_at(life[].alive)
    var age = words_at(life[].age)
    var decay = bytes_at(life[].decay)
    for dy in range(2):
        for dx in range(2):
            var x = cx + dx
            var y = cy + dy
            if x >= GRID_W or y >= GRID_H:
                continue
            var i = y * GRID_W + x
            if erase:
                alive[unsafe_offset=i] = UInt8(0)
                age[unsafe_offset=i] = UInt16(0)
            else:
                alive[unsafe_offset=i] = UInt8(1)
                if age[unsafe_offset=i] == UInt16(0):
                    age[unsafe_offset=i] = UInt16(1)
                decay[unsafe_offset=i] = UInt8(0)
    life[].dirty = 1


def paint_at_client(
    life: LifePtr, hwnd: Int, px: Int, py: Int, erase: Bool
) raises:
    """Map a point in the client area to a cell.

    The frame buffer is stretched to whatever size the client area is, so the
    mapping has to go through the client rectangle rather than assume 1:1 --
    otherwise drawing lands somewhere else the moment the window is resized.
    """
    var GetClientRect = win32[
        def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
        "GetClientRect",
    ]()
    var rc = RECT()
    _ = GetClientRect(hwnd, com_addr(rc))
    var w = rc.width()
    var h = rc.height()
    if w <= 0 or h <= 0 or px < 0 or py < 0 or px >= w or py >= h:
        return
    paint_cell(life, (px * WIN_W // w) // CELL, (py * WIN_H // h) // CELL, erase)


# ===----------------------------------------------------------------------===#
# Getting the buffer onto the window
# ===----------------------------------------------------------------------===#


def show(life: LifePtr, hwnd: Int) raises:
    """Push the CPU buffer at the window, scaled to whatever size it is now.

    `present_bgra` is the shared blit: a top-down 32-bit DIB stretched to the
    client rectangle by `StretchDIBits`. This example used to spell that out,
    including the negative height that makes it top-down, which is the single
    most-copied twenty lines across these examples and the one most likely to
    come out upside down.

    It takes a `Span`, not a pointer, so a buffer whose length disagrees with
    the width and height it was told is refused here rather than read off the
    end of by the graphics driver.
    """
    present_bgra(
        hwnd,
        Span(unsafe_ptr=dwords_at(life[].frame), length=PIXELS),
        WIN_W,
        WIN_H,
    )


def update_title(life: LifePtr, hwnd: Int) raises:
    var SetWindowTextW = win32[
        def (Int, Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> c_int,
        "SetWindowTextW",
    ]()
    var state = "running" if life[].running != 0 else "paused"
    var text = (
        String("Life - gen ")
        + String(life[].gen)
        + "  pop "
        + String(population(life))
        + "  "
        + state
        + "  speed "
        + String(31 - life[].speed)
        + "  step "
        + String(life[].step_us)
        + " us   [space] pause  [drag] draw  [shift/right drag] erase"
        + "  [.] step  [r] random  [c] clear  [ [ ] ] speed"
    )
    # `WideString` is a real UTF-8 to UTF-16 conversion through
    # MultiByteToWideChar. The version this replaces walked codepoints by
    # hand; the one before that assigned bytes to code units, which is
    # Latin-1, and would have mangled the first non-ASCII character anybody
    # put in a title.
    var buf = WideString(text)
    _ = SetWindowTextW(hwnd, buf.unsafe_ptr())
    _ = buf^


def advance(life: LifePtr, hwnd: Int) raises:
    """One clock tick: maybe a generation, and a repaint if anything changed.
    """
    var InvalidateRect = win32[
        def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
    ]()

    life[].ticks += 1
    var stepped = False
    if life[].running != 0:
        life[].subtick += 1
        if life[].subtick >= life[].speed:
            life[].subtick = 0
            stepped = True

    if stepped or life[].dirty != 0:
        life[].dirty = 0
        var t0 = performance_counter()
        if stepped:
            evolve(life)
        render(life)
        life[].step_us = (
            (performance_counter() - t0) * 1000000 // life[].hz
        )
        # Ask for a repaint; never paint from here. WM_PAINT is where the
        # window's own device context is valid, and the one place that knows
        # how big the client area currently is.
        _ = InvalidateRect(hwnd, 0, c_int(0))

    # The title is statistics, not the picture, so it runs on its own slower
    # clock -- refreshing it sixty times a second makes the non-client area
    # churn for no gain. It is deliberately OUTSIDE the block above: the first
    # version updated the title only when the picture changed, so pressing
    # space stopped the simulation and left the title reading "running", which
    # reads exactly like a key that did nothing. `retitle` is the other half:
    # a state change has to show at once rather than up to a fifth of a second
    # later.
    if life[].retitle != 0 or life[].ticks % 12 == 0:
        life[].retitle = 0
        update_title(life, hwnd)


# ===----------------------------------------------------------------------===#
# The window procedure. Windows calls this, so it is a captureless C-ABI
# function that must never raise -- unwinding through a Windows frame is
# undefined -- and every failure is caught here.
#
# The type is `std.windows.gui.WndProc`, named once there so a class
# registration and the procedure it names cannot drift apart.
# ===----------------------------------------------------------------------===#


def stored_life(hwnd: Int) raises -> Int:
    var GetWindowLongPtrW = win32[
        def (Int, c_int) thin abi("C") -> Int, "GetWindowLongPtrW"
    ]()
    return GetWindowLongPtrW(hwnd, c_int(winkb_constant["GWLP_USERDATA"]()))


def signed16(v: Int) -> Int:
    """One half of a packed mouse point, sign-extended.

    `lParam` packs a point as two 16-bit halves, and they are SIGNED: a drag
    that leaves the window to the left reports a negative x, which read
    unsigned becomes 65,000-odd.
    """
    var x = v & 0xFFFF
    if x >= 0x8000:
        x -= 0x10000
    return x


@export("life_wndproc")
def life_wndproc(
    hwnd: Int, message: UInt32, wparam: Int, lparam: Int
) abi("C") -> Int:
    try:
        # Refuse the background erase: the whole client area is redrawn every
        # paint, and letting GDI clear it first is what makes it flicker.
        if message == UInt32(winkb_constant["WM_ERASEBKGND"]()):
            return 1

        var stored = stored_life(hwnd)
        if stored == 0:
            # Messages arrive during CreateWindowExW, before there is anything
            # to point at.
            return default_handler(hwnd, message, wparam, lparam)
        var life = LifePtr(unsafe_from_address=stored)

        if message == UInt32(winkb_constant["WM_PAINT"]()):
            var BeginPaint = win32[
                def (Int, Pointer[UInt8, MutAnyOrigin]) thin abi("C") -> Int,
                "BeginPaint",
            ]()
            var EndPaint = win32[
                def (Int, Pointer[UInt8, MutAnyOrigin]) thin abi("C") -> c_int,
                "EndPaint",
            ]()
            # PAINTSTRUCT is never declared here, only sized, from the
            # metadata -- it is a box this code never looks inside.
            var ps = List[UInt8](
                length=winkb_struct_size["PAINTSTRUCT"](), fill=0
            )
            var ps_ptr = ps.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
            var hdc = BeginPaint(hwnd, ps_ptr)
            if hdc != 0:
                # `present_bgra` fetches its own device context and asks the
                # window how big it is, so the handle BeginPaint returned goes
                # unused. The pair is still required: BeginPaint is what
                # clears the update region and EndPaint is what closes it, and
                # a WM_PAINT that does neither is re-sent immediately,
                # forever. That is the one thing painting through a borrowed
                # DC does not do for you.
                show(life, hwnd)
                life[].painted += 1
            _ = EndPaint(hwnd, ps_ptr)
            _ = ps
            return 0

        if message == UInt32(winkb_constant["WM_TIMER"]()):
            if wparam == TICK_TIMER_ID:
                advance(life, hwnd)
                if life[].sample_at != 0 and life[].ticks >= life[].sample_at:
                    if life[].sampled == 0:
                        life[].sampled = 1
                        readback(life, hwnd)
                if life[].close_at != 0 and life[].ticks >= life[].close_at:
                    var DestroyWindow = win32[
                        def (Int) thin abi("C") -> c_int, "DestroyWindow"
                    ]()
                    _ = DestroyWindow(hwnd)
            return 0

        if message == UInt32(winkb_constant["WM_SIZE"]()):
            # The buffer is stretched to the client rect, so nothing has to be
            # reallocated -- but the window needs repainting at the new size.
            var InvalidateRect = win32[
                def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
            ]()
            _ = InvalidateRect(hwnd, 0, c_int(0))
            return 0

        # ── Mouse ────────────────────────────────────────────────────────
        # Left draws, right erases, and shift with either erases. The
        # modifier arrives in wParam on mouse messages, already decoded --
        # no GetKeyState needed.
        if (
            message == UInt32(winkb_constant["WM_LBUTTONDOWN"]())
            or message == UInt32(winkb_constant["WM_RBUTTONDOWN"]())
        ):
            var SetCapture = win32[
                def (Int) thin abi("C") -> Int, "SetCapture"
            ]()
            var SetFocus = win32[def (Int) thin abi("C") -> Int, "SetFocus"]()
            # Capture, so a drag that leaves the window keeps drawing rather
            # than stopping at the frame.
            _ = SetCapture(hwnd)
            # Without this the keyboard messages go somewhere else.
            _ = SetFocus(hwnd)
            var erase = (
                message == UInt32(winkb_constant["WM_RBUTTONDOWN"]())
                or (wparam & winkb_constant["MK_SHIFT"]()) != 0
            )
            paint_at_client(
                life, hwnd, signed16(lparam), signed16(lparam >> 16), erase
            )
            return 0

        if message == UInt32(winkb_constant["WM_MOUSEMOVE"]()):
            var left = (wparam & winkb_constant["MK_LBUTTON"]()) != 0
            var right = (wparam & winkb_constant["MK_RBUTTON"]()) != 0
            if left or right:
                var erase = right or (
                    wparam & winkb_constant["MK_SHIFT"]()
                ) != 0
                paint_at_client(
                    life, hwnd, signed16(lparam), signed16(lparam >> 16), erase
                )
            return 0

        if (
            message == UInt32(winkb_constant["WM_LBUTTONUP"]())
            or message == UInt32(winkb_constant["WM_RBUTTONUP"]())
        ):
            var ReleaseCapture = win32[
                def () thin abi("C") -> c_int, "ReleaseCapture"
            ]()
            _ = ReleaseCapture()
            return 0

        # ── Keyboard ─────────────────────────────────────────────────────
        # Typed characters arrive as WM_CHAR, which the message loop's
        # TranslateMessage produces: Windows has already applied the keyboard
        # layout by then, so what turns up is the character the person meant.
        if message == UInt32(winkb_constant["WM_CHAR"]()):
            var ch = wparam & 0xFFFF
            if ch == ord(" "):
                life[].running = 0 if life[].running != 0 else 1
            elif ch == ord("c") or ch == ord("C"):
                clear_grid(life)
            elif ch == ord("r") or ch == ord("R"):
                randomize(life)
            elif ch == ord("."):
                # A single step, which is what makes pause useful.
                evolve(life)
            elif ch == ord("]"):
                if life[].speed > 1:
                    life[].speed -= 1
            elif ch == ord("["):
                if life[].speed < 30:
                    life[].speed += 1
            else:
                return 0
            # Every key above changes something the picture or the statistics
            # show, and every one of them should be visible before the next
            # keystroke rather than at the next generation.
            life[].dirty = 1
            life[].retitle = 1
            return 0

        if message == UInt32(winkb_constant["WM_KEYDOWN"]()):
            if wparam == winkb_constant["VK_ESCAPE"]():
                var PostMessageW = win32[
                    def (Int, UInt32, Int, Int) thin abi("C") -> c_int,
                    "PostMessageW",
                ]()
                _ = PostMessageW(
                    hwnd, UInt32(winkb_constant["WM_CLOSE"]()), 0, 0
                )
            return 0

        if message == UInt32(winkb_constant["WM_CLOSE"]()):
            var DestroyWindow = win32[
                def (Int) thin abi("C") -> c_int, "DestroyWindow"
            ]()
            _ = DestroyWindow(hwnd)
            return 0

        if message == UInt32(winkb_constant["WM_DESTROY"]()):
            # This is what puts WM_QUIT on the queue and ends the loop. A
            # window that closes but whose process hangs is always a missing
            # PostQuitMessage -- which is what `quit` is.
            quit(0)
            return 0

        return default_handler(hwnd, message, wparam, lparam)
    except:
        return 0


# ===----------------------------------------------------------------------===#
# Evidence
#
# A picture that looks right is not evidence, and neither is a call that
# returned without complaining. Two checks: the rule is exercised on three
# patterns whose behaviour is known exactly, and the window's own pixels are
# copied back out and counted.
# ===----------------------------------------------------------------------===#


def check_patterns(life: LifePtr) -> Int:
    """Returns the number of failures.

    A glider is the strongest cheap check there is: it is periodic in four
    generations AND displaced by one cell diagonally, so a wrong neighbour
    count, a wrong wrap, or an off-by-one in the index all break it, and the
    expected answer is exact rather than approximate.
    """
    var bad = 0

    # A glider, which must reappear one cell down and one cell right.
    clear_grid(life)
    set_cell(life, 21, 20, True)
    set_cell(life, 22, 21, True)
    set_cell(life, 20, 22, True)
    set_cell(life, 21, 22, True)
    set_cell(life, 22, 22, True)
    for _ in range(4):
        evolve(life)
    var glider_ok = population(life) == 5
    if not get_cell(life, 22, 21):
        glider_ok = False
    if not get_cell(life, 23, 22):
        glider_ok = False
    if not get_cell(life, 21, 23):
        glider_ok = False
    if not get_cell(life, 22, 23):
        glider_ok = False
    if not get_cell(life, 23, 23):
        glider_ok = False
    print("  glider  period 4, displaced (1,1):", "ok" if glider_ok else "FAIL")
    if not glider_ok:
        bad += 1

    # A blinker: horizontal, vertical, horizontal.
    clear_grid(life)
    set_cell(life, 60, 40, True)
    set_cell(life, 61, 40, True)
    set_cell(life, 62, 40, True)
    evolve(life)
    var blink_ok = (
        population(life) == 3
        and get_cell(life, 61, 39)
        and get_cell(life, 61, 40)
        and get_cell(life, 61, 41)
    )
    evolve(life)
    if not (
        population(life) == 3
        and get_cell(life, 60, 40)
        and get_cell(life, 61, 40)
        and get_cell(life, 62, 40)
    ):
        blink_ok = False
    print("  blinker period 2:", "ok" if blink_ok else "FAIL")
    if not blink_ok:
        bad += 1

    # A block, which must not move at all.
    clear_grid(life)
    set_cell(life, 100, 60, True)
    set_cell(life, 101, 60, True)
    set_cell(life, 100, 61, True)
    set_cell(life, 101, 61, True)
    for _ in range(8):
        evolve(life)
    var block_ok = (
        population(life) == 4
        and get_cell(life, 100, 60)
        and get_cell(life, 101, 60)
        and get_cell(life, 100, 61)
        and get_cell(life, 101, 61)
    )
    print("  block   still after 8:", "ok" if block_ok else "FAIL")
    if not block_ok:
        bad += 1

    clear_grid(life)
    return bad


def readback(life: LifePtr, hwnd: Int) raises:
    """Copy the window's own client area back out and count what is lit.

    A DIB section, a BitBlt out of the window's device context, and a count of
    pixels that are not the background colour. The predicted count is exact:
    every live cell and every ember paints a (CELL-1) x (CELL-1) interior, and
    nothing else in the window is anything but background.
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
        c_int(0), c_int(0), c_int(w), c_int(h),
        windc,
        c_int(0), c_int(0),
        UInt32(winkb_constant["SRCCOPY"]()),
    )

    var got = dwords_at(bits)
    var bg = Int(background()) & 0xFFFFFF
    var lit = 0
    var colours = 0
    var seen = List[Int]()
    for i in range(w * h):
        var v = Int(got[unsafe_offset=i]) & 0xFFFFFF
        if v != bg:
            lit += 1
            if colours < 12:
                var known = False
                for j in range(len(seen)):
                    if seen[j] == v:
                        known = True
                if not known:
                    seen.append(v)
                    colours += 1

    var live = population(life)
    var ember = embers(life)
    var predicted = (live + ember) * (CELL - 1) * (CELL - 1)
    print("readback: client", w, "x", h, "  (buffer", WIN_W, "x", WIN_H, ")")
    print("   live cells", live, " embers", ember)
    print("   lit pixels", lit, " predicted", predicted)
    if w == WIN_W and h == WIN_H:
        print("   1:1, so those two should agree exactly")
    else:
        print("   the buffer was stretched, so expect them to differ")
    print("   distinct non-background colours seen (capped at 12):", colours)
    for j in range(len(seen)):
        print("     ", hex(seen[j]))

    _ = SelectObject(memdc, old)
    _ = DeleteObject(hbmp)
    _ = DeleteDC(memdc)
    _ = ReleaseDC(hwnd, windc)


# ===----------------------------------------------------------------------===#


def main() raises:
    # The four struct-size assertions that used to open this function are in
    # `std.windows.gui` now, next to the structs they guard, where they are
    # checked once instead of once per example.
    var selftest = False
    var hold_ms = 3000
    var args = argv()
    for i in range(len(args)):
        if args[i] == "--selftest":
            selftest = True
        if args[i] == "--ms" and i + 1 < len(args):
            hold_ms = Int(args[i + 1])

    # Declare DPI awareness BEFORE any window exists, or it is ignored.
    #
    # Without this Windows lies to the process about the size of everything and
    # then bilinearly upscales whatever it draws. On a 150% display that turns
    # a 1080x720 buffer into 1620x1080 physical pixels, which blurs a lattice
    # whose whole point is a one-pixel gutter. Declaring awareness means one
    # pixel in the buffer is one pixel on the glass -- and that the readback
    # below can demand exact agreement rather than "close enough".
    var SetProcessDpiAwarenessContext = win32[
        def (Int) thin abi("C") -> c_int, "SetProcessDpiAwarenessContext"
    ]()
    if (
        SetProcessDpiAwarenessContext(
            winkb_constant["DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2"]()
        )
        == 0
    ):
        # Older Windows has only the all-or-nothing switch.
        var SetProcessDPIAware = win32[
            def () thin abi("C") -> c_int, "SetProcessDPIAware"
        ]()
        _ = SetProcessDPIAware()

    # The rest of what `main` calls directly. Creating the window, registering
    # its class and running the loop are `std.windows.gui`'s now; what is left
    # is the geometry correction, the timer, and the pointer Windows keeps for
    # the procedure.
    var LoadCursorW = win32[def (Int, Int) thin abi("C") -> Int, "LoadCursorW"]()
    var SetClassLongPtrW = win32[
        def (Int, c_int, Int) thin abi("C") -> Int, "SetClassLongPtrW"
    ]()
    var AdjustWindowRectEx = win32[
        def (
            Pointer[RECT, MutAnyOrigin], UInt32, c_int, UInt32
        ) thin abi("C") -> c_int,
        "AdjustWindowRectEx",
    ]()
    var SetWindowLongPtrW = win32[
        def (Int, c_int, Int) thin abi("C") -> Int, "SetWindowLongPtrW"
    ]()
    var SetTimer = win32[
        def (Int, Int, UInt32, Int) thin abi("C") -> Int, "SetTimer"
    ]()
    var KillTimer = win32[
        def (Int, Int) thin abi("C") -> c_int, "KillTimer"
    ]()

    # ── State, on the heap ───────────────────────────────────────────────
    # It must outlive main's locals and be reachable from a captureless
    # window procedure, and it is handed to Windows, so Mojo does not own it.
    var alive_buf = unsafe_alloc[UInt8](CELLS, alignment=64)
    var scratch_buf = unsafe_alloc[UInt8](CELLS, alignment=64)
    var age_buf = unsafe_alloc[UInt16](CELLS, alignment=64)
    var decay_buf = unsafe_alloc[UInt8](CELLS, alignment=64)
    var frame_buf = unsafe_alloc[UInt32](PIXELS, alignment=64)

    var store = unsafe_alloc[Life](1, alignment=8)
    # Emplaced, not assigned: `store[] = value` would destroy what was there
    # first, and what is there is whatever the allocator last had.
    store.unsafe_write(Life())
    var life = LifePtr(unsafe_from_address=Int(store))
    life[].alive = Int(alive_buf)
    life[].scratch = Int(scratch_buf)
    life[].age = Int(age_buf)
    life[].decay = Int(decay_buf)
    life[].frame = Int(frame_buf)
    life[].hz = performance_frequency()

    # The scratch grid is read by nothing before evolve writes it, but leaving
    # a page of allocator leftovers in a buffer that gets swapped in is the
    # kind of thing that shows up as a ghost pattern once in fifty runs.
    var scratch0 = bytes_at(life[].scratch)
    for i in range(CELLS):
        scratch0[unsafe_offset=i] = UInt8(0)
    clear_grid(life)
    fill_background(life)

    print("metadata schema:", winkb_db_schema_version())
    print("grid", GRID_W, "x", GRID_H, " cell", CELL, " buffer", WIN_W, "x", WIN_H)

    if selftest:
        # A fixed seed so the numbers a check compares are reproducible.
        seed(1)
        print("pattern checks:")
        var bad = check_patterns(life)
        if bad != 0:
            raise Error("Life rule is wrong: " + String(bad) + " check(s) failed")
    else:
        seed()

    randomize(life)
    render(life)

    # ── The window ───────────────────────────────────────────────────────
    # A class and a window, from `std.windows.gui`. The class registration
    # that used to be here -- twelve fields, a cbSize, and a size assertion --
    # is the same twelve fields for every program that has a window, so it is
    # written once there. `WndProc` is the procedure's type, named in the same
    # module as `default_handler`, so the two cannot drift apart.
    var proc: WndProc = life_wndproc
    var klass = WindowClass("MojoLifeWindow", proc)

    # CreateWindowExW takes the OUTER size, so ask Windows how much frame a
    # WS_OVERLAPPEDWINDOW adds rather than guessing at a border width.
    comptime STYLE = winkb_constant["WS_OVERLAPPEDWINDOW"]()
    var want = RECT()
    want.left = 0
    want.top = 0
    want.right = Int32(WIN_W)
    want.bottom = Int32(WIN_H)
    _ = AdjustWindowRectEx(com_addr(want), UInt32(STYLE), c_int(0), UInt32(0))

    var window = Window(klass, "Life", want.width(), want.height())
    var hwnd = window.handle

    # The shared class asks Windows for an arrow, because a class whose
    # hCursor is zero is one Windows never sets a cursor for at all. This
    # window is a drawing surface and wants a crosshair. The cursor is a
    # property of the CLASS, and a class property is settable after
    # registration as well as inside it -- GCLP_HCURSOR is that slot, and
    # SetClassLongPtrW names the class through one of its windows.
    _ = SetClassLongPtrW(
        hwnd,
        c_int(winkb_constant["GCLP_HCURSOR"]()),
        LoadCursorW(0, winkb_constant["IDC_CROSS"]()),
    )

    # AdjustWindowRectEx answers for the SYSTEM dpi, which is not necessarily
    # this window's monitor's, and the frame also depends on the theme. So
    # measure what actually came out and correct it once, rather than trusting
    # the arithmetic -- that is what makes the blit exactly 1:1, and what lets
    # the self-test demand an exact pixel count instead of a plausible one.
    #
    # The same call places the window, because `Window` asks for
    # CW_USEDEFAULT and this example would rather be at a known corner.
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
    var have = window.client_size()
    var outer = RECT()
    _ = GetWindowRect(hwnd, com_addr(outer))
    _ = SetWindowPos(
        hwnd, 0, c_int(60), c_int(60),
        c_int(outer.width() + WIN_W - have.width()),
        c_int(outer.height() + WIN_H - have.height()),
        UInt32(
            winkb_constant["SWP_NOZORDER"]()
            | winkb_constant["SWP_NOACTIVATE"]()
        ),
    )

    if selftest:
        var ticks = hold_ms // TICK_MS
        if ticks < 20:
            ticks = 20
        life[].sample_at = ticks * 2 // 3
        life[].close_at = ticks

    _ = SetWindowLongPtrW(
        hwnd, c_int(winkb_constant["GWLP_USERDATA"]()), Int(store)
    )
    window.show()
    update_title(life, hwnd)
    _ = SetTimer(hwnd, TICK_TIMER_ID, UInt32(TICK_MS), 0)

    # ── The loop ─────────────────────────────────────────────────────────
    # `gui.run` is the blocking loop: GetMessageW, TranslateMessage,
    # DispatchMessageW, and the -1 case that a `while GetMessageW(...) != 0`
    # spins on forever. Blocking is the right one here -- the clock is a
    # WM_TIMER, so a paused simulation costs nothing -- and TranslateMessage
    # is what turns WM_KEYDOWN into the WM_CHAR the key handling reads.
    _ = run()

    _ = KillTimer(hwnd, TICK_TIMER_ID)
    print("generations", life[].gen, " frames painted", life[].painted)

    alive_buf.unsafe_free()
    scratch_buf.unsafe_free()
    age_buf.unsafe_free()
    decay_buf.unsafe_free()
    frame_buf.unsafe_free()
    store.unsafe_free()
    print("done")
