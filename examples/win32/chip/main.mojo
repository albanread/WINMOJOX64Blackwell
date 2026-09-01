# ===----------------------------------------------------------------------=== #
# CHIP -- a chip-tune synthesiser with a window, in Mojo, on Win32.
#
# The point of this example is the thread boundary.
#
# There are two threads and they never wait for each other. One of them is
# Windows': the message loop, pumping WM_PAINT and WM_CHAR, drawing thirty
# times a second, allowed to allocate and allowed to fail. The other one is
# the audio thread, whose whole life is `wake, fill, release`, on a deadline
# the speaker enforces, where allocating is a bad idea, taking a lock is a
# worse one, and raising reports nothing to anybody -- it just leaves the ring
# empty, which is a hole you can hear.
#
# Mojo is on both sides of that, with nothing hand-written to bridge them:
#
#   * a `def` declared `thin abi("C")` IS a C function pointer. So
#     `chip_audio_thread` below is handed straight to `CreateThread` as an
#     LPTHREAD_START_ROUTINE, `chip_wndproc` straight to `RegisterClassExW` as
#     a WNDPROC, and `chip_fill` straight into the stream loop as the thing it
#     calls on the deadline. No shim, no C file in the build, no thunk.
#   * a `def` without `raises` is the non-raising kind, and the compiler holds
#     it to that. Everything reachable from `chip_fill` -- the whole
#     synthesiser and the whole player routine -- is declared that way, which
#     turns "the audio path must not raise" from a comment into a rule the
#     build enforces.
#
# The audio path allocates nothing after startup. All chip state lives in one
# flat block whose address is the only thing the audio thread is given, which
# is why there is no global holding the chip and why two of these could run at
# once. The window reads that same block to draw the meters, with no lock
# between them: a torn read costs one wrong pixel for one frame, where a held
# lock would cost a click in the speaker.
#
# The screen is the C64's own palette, because it seemed rude to do otherwise.
#
#     main.exe                       the built-in tune
#     main.exe tunes\ode.abc         an ABC tune
#     main.exe --selftest --ms 4000  check the arithmetic, play, prove it was
#                                    audible, close
#     main.exe --buffer-ms 0         ask for the engine's smallest ring
#     main.exe --stall 120           miss one deadline on purpose
#     main.exe --freeze 3000         block the WINDOW thread for three
#                                    seconds and watch the sound not care
#
#     SPACE pause   1 2 3 mute a voice   < > cutoff   - + resonance
#     F filter mode   Q quit
# ===----------------------------------------------------------------------=== #

from std.ffi import c_int, external_call
from std.memory import Pointer, OpaquePointer
from std.memory.alloc import unsafe_alloc
from std.python._cpython import _fn_ptr_as_opaque
from std.sys import argv
from std.sys._com import ComPtr, com_addr
from std.sys._winkb import (
    winkb_constant,
    winkb_db_schema_version,
    winkb_struct_size,
)
from std.sys.com import Apartment
from std.sys.info import size_of

from abc import install_abc, parse_abc
from chip import (
    FILT_BP,
    FILT_HP,
    FILT_LP,
    PLAYER_BASE,
    P,
    S_CUTOFF,
    S_FMODE,
    S_FRAME,
    S_RATE,
    S_RES,
    Tick,
    V_ENV,
    V_LFSR,
    V_STEP,
    V_WAVE,
    WAVE_NOISE,
    WAVE_PULSE,
    WAVE_SAW,
    WAVE_TRI,
    chip_free,
    chip_new,
    chip_render,
    gate_on,
    get,
    put,
    route_filter,
    set_filter,
    set_freq_hz,
    set_freq_reg,
    set_wave,
    vget,
    vput,
)
from font import draw_text, font_rom
from tune import (
    build_demo,
    instrument_bass,
    instrument_lead,
    midi_hz,
    player_attach,
    player_tick,
)
from wasapi import (
    MixFormat,
    ST_ERROR,
    ST_FILL_US,
    ST_FRAMES,
    ST_GAPMAX_US,
    ST_GAP_US,
    ST_LOAD_PPM,
    ST_PEAK,
    ST_PEAKMAX,
    ST_QUIT,
    ST_RUNNING,
    ST_STALL_MS,
    ST_UNDERRUNS,
    ST_WAKES,
    Stream,
    activate,
    co_task_free,
    default_render_device,
    endpoint_id,
    initialize_stream,
    mix_format_address,
    open_enumerator,
    read_mix_format,
    render_client,
    run_stream,
    win32,
)


# ── The interface's own slots ───────────────────────────────────────────────
# The tail of the chip's player region is unused by the player, so the parts
# the interface owns live there. That keeps the audio thread reachable from
# one pointer: it is handed the chip, and everything hangs off that. The
# stream's own slots (ST_*) are further along, declared in wasapi.mojo.

comptime UI_SCOPE = PLAYER_BASE + 64  # address of the scope ring buffer
comptime UI_SCOPE_POS = PLAYER_BASE + 65
comptime UI_PAUSE = PLAYER_BASE + 66
comptime UI_MUTE = PLAYER_BASE + 68  # three slots, one per voice
comptime UI_SAVED_WAVE = PLAYER_BASE + 72  # what a muted voice was playing

comptime SCOPE_LEN = 1024

comptime WIN_W = 800
comptime WIN_H = 500
comptime PIXELS = WIN_W * WIN_H
comptime BORDER = 24

comptime TICK_TIMER_ID = 1
comptime TICK_MS = 33  # thirty frames a second, and the audio ignores it

comptime DEFAULT_BUFFER_MS = 60


# ===----------------------------------------------------------------------===#
# The audio side
# ===----------------------------------------------------------------------===#


@export("chip_fill")
def chip_fill(
    st: P, dest: Pointer[Float32, MutUntrackedOrigin], frames: Int
) abi("C") -> NoneType:
    """Produce `frames` mono samples. Called from the stream loop, on the
    deadline.

    This is what the Mac version's `AURenderCallback` became. There, CoreAudio
    owned a thread and called this; here the program owns the thread and the
    stream loop calls it. It is the same function pointer either way, and the
    same rules apply to its body: everything it touches was allocated before
    the stream started, there is no lock, and it cannot raise -- the signature
    says so and the compiler agrees.
    """
    if get(st, UI_PAUSE) != 0:
        for i in range(frames):
            dest[unsafe_offset=i] = Float32(0.0)
        return None

    var tick: Tick = player_tick
    chip_render(st, dest, frames, tick)

    # Hand the drawing side something to show. A plain ring buffer with no
    # synchronisation: the reader may catch a half-written sweep and draw one
    # frame with a seam in it, which is the correct trade for a scope.
    var scope_addr = get(st, UI_SCOPE)
    if scope_addr != 0:
        var scope = Pointer[Float32, MutUntrackedOrigin](
            unsafe_from_address=scope_addr
        )
        var pos = get(st, UI_SCOPE_POS)
        for i in range(frames):
            scope[unsafe_offset=pos] = dest[unsafe_offset=i]
            pos += 1
            if pos >= SCOPE_LEN:
                pos = 0
        put(st, UI_SCOPE_POS, pos)
    return None


@fieldwise_init
struct AudioLink(Copyable, Movable):
    """Everything the audio thread is given, in one heap block.

    A thread procedure gets exactly one pointer, the same way a window
    procedure does, so this is the audio side's equivalent of GWLP_USERDATA.
    The interface pointers are addresses rather than `ComPtr`s because the
    main thread owns them and releases them: an owning wrapper on this side
    would Release a second time on the way out.
    """

    var chip: Int
    var client: Int
    var render: Int
    var meter: Int
    var mono: Int  # Float32*, one scratch buffer of ring size
    var fmt: MixFormat
    var stream: Stream


comptime AudioLinkPtr = Pointer[AudioLink, MutAnyOrigin]
comptime ThreadProc = def (Int) thin abi("C") -> UInt32


def audio_body(link: AudioLinkPtr) raises:
    """The audio thread's real work, in a function that may report failure."""
    # Every thread that touches COM must initialise it for itself. The MTA,
    # deliberately: this thread owns no window and pumps no messages, and an
    # STA whose messages are never pumped is where cross-apartment calls go to
    # hang. WASAPI's objects are in-process and thread-agile, so a pointer
    # created on the window thread is callable here with no marshalling.
    with Apartment(multithreaded=True):
        # Tell the scheduler this is audio. Without it this is an ordinary
        # thread competing with everything else on the machine; with it the
        # Multimedia Class Scheduler gives it the guaranteed slice it needs to
        # make a 10 ms deadline. A failure here is not fatal -- the loop still
        # runs, just less reliably -- so it is not checked.
        var av_set = win32[
            def (
                Pointer[UInt16, MutAnyOrigin], Pointer[UInt32, MutAnyOrigin]
            ) thin abi("C") -> Int,
            "AvSetMmThreadCharacteristicsW",
        ]()
        var av_revert = win32[
            def (Int) thin abi("C") -> Int32,
            "AvRevertMmThreadCharacteristics",
        ]()
        var task_name = wide("Pro Audio")
        var task_index = UInt32(0)
        var av = av_set(
            task_name.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            com_addr(task_index),
        )
        _ = task_name
        print(
            "audio thread:",
            "MMCSS 'Pro Audio'" if av != 0 else "ordinary priority (MMCSS"
            " declined)",
        )

        var fill = chip_fill
        run_stream(
            P(unsafe_from_address=link[].chip),
            link[].client,
            link[].render,
            link[].meter,
            link[].stream,
            link[].fmt,
            link[].mono,
            fill,
        )

        if av != 0:
            _ = av_revert(av)


@export("chip_audio_thread")
def chip_audio_thread(param: Int) abi("C") -> UInt32:
    """The LPTHREAD_START_ROUTINE Windows calls. It must not let anything out.

    Unwinding out of a thread procedure is undefined the same way unwinding
    out of a window procedure is, so the whole body is caught here -- and the
    report goes to stdout rather than through a return value, because by the
    time this catches anything the window is the only thing still listening
    and it has no way to ask.
    """
    try:
        audio_body(AudioLinkPtr(unsafe_from_address=param))
    except e:
        print("audio thread stopped:", e)
        var link = AudioLinkPtr(unsafe_from_address=param)
        var st = P(unsafe_from_address=link[].chip)
        put(st, ST_RUNNING, 0)
        if get(st, ST_ERROR) == 0:
            put(st, ST_ERROR, 1)
    return UInt32(0)


# ===----------------------------------------------------------------------===#
# Windows structures. Layouts are asserted against the metadata in main();
# claiming a size that is wrong would not fail to compile, it would silently
# write fields to the wrong places.
# ===----------------------------------------------------------------------===#


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
struct Screen(Defaultable, Copyable, Movable):
    """Everything the window knows.

    A window procedure is captureless -- Windows calls it, so it holds nothing
    and must fetch what it needs from the one pointer a window can keep. This
    is that thing, on the heap, reached through GWLP_USERDATA.
    """

    var chip: Int  # the state block; also all the audio thread has
    var frame: Int  # UInt32*  BGRA pixels, WIN_W x WIN_H
    var rom: Int  # UInt8*   the character ROM
    var ticks: Int
    var painted: Int
    var close_at_ms: Int  # GetTickCount64 value to self-destruct on; 0 = never
    var freeze_ms: Int  # block this thread once, on purpose, for --freeze

    def __init__(out self):
        self.chip = 0
        self.frame = 0
        self.rom = 0
        self.ticks = 0
        self.painted = 0
        self.close_at_ms = 0
        self.freeze_ms = 0


comptime ScreenPtr = Pointer[Screen, MutAnyOrigin]
comptime WndProcType = def (Int, UInt32, Int, Int) thin abi("C") -> Int


def wide(s: StaticString) -> List[UInt16]:
    """A NUL-terminated UTF-16 buffer for the W-suffixed entry points."""
    var out = List[UInt16]()
    for byte in s.as_bytes():
        out.append(UInt16(Int(byte)))
    out.append(0)
    return out^


def wide_of(s: String) -> List[UInt16]:
    """The same, for text built at run time -- the window title."""
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


# ===----------------------------------------------------------------------===#
# The screen
#
# The VIC-II's sixteen colours. Only a few are needed, but the blue-on-blue is
# the whole look and the light green is what a monitor's phosphor did to a
# bright line.
# ===----------------------------------------------------------------------===#


@always_inline
def rgb(r: Int, g: Int, b: Int) -> UInt32:
    """One BGRA pixel as a little-endian 32-bit word: 0xAARRGGBB."""
    return (
        UInt32(b & 255)
        | (UInt32(g & 255) << 8)
        | (UInt32(r & 255) << 16)
        | (UInt32(255) << 24)
    )


def c64_blue() -> UInt32:
    return rgb(64, 49, 141)


def c64_light_blue() -> UInt32:
    return rgb(120, 105, 196)


def c64_light_green() -> UInt32:
    return rgb(148, 224, 137)


def c64_yellow() -> UInt32:
    return rgb(191, 206, 114)


def c64_light_red() -> UInt32:
    return rgb(184, 105, 98)


def c64_black() -> UInt32:
    return rgb(0, 0, 0)


def fill_rect(frame_addr: Int, x: Int, y: Int, w: Int, h: Int, colour: UInt32):
    """A clipped rectangle in the BGRA buffer."""
    var frame = Pointer[UInt32, MutUntrackedOrigin](
        unsafe_from_address=frame_addr
    )
    var x0 = 0 if x < 0 else x
    var y0 = 0 if y < 0 else y
    var x1 = x + w
    var y1 = y + h
    if x1 > WIN_W:
        x1 = WIN_W
    if y1 > WIN_H:
        y1 = WIN_H
    for py in range(y0, y1):
        var base = py * WIN_W
        for px in range(x0, x1):
            frame[unsafe_offset = base + px] = colour


def text(
    scr: ScreenPtr, x: Int, y: Int, s: String, scale: Int, colour: UInt32
):
    draw_text(
        Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=scr[].frame),
        WIN_W,
        WIN_H,
        scr[].rom,
        x,
        y,
        s,
        scale,
        colour,
    )


def wave_name(wave: Int) -> String:
    """The waveform bits, spelled the way the register reads."""
    if wave == 0:
        return String("---- ")
    var s = String("")
    s += "T" if (wave & WAVE_TRI) != 0 else "."
    s += "S" if (wave & WAVE_SAW) != 0 else "."
    s += "P" if (wave & WAVE_PULSE) != 0 else "."
    s += "N" if (wave & WAVE_NOISE) != 0 else "."
    return s + " "


def note_name(step: Int, rate: Int) raises -> String:
    """Turn a voice's frequency back into a note name, for the display.

    The chip has no idea what note it is playing -- it has a step size. Going
    backwards is a logarithm, and this is a display, so it counts instead:
    multiply up from C-1 until it passes.
    """
    if step <= 0:
        return String("--- ")
    # step = freq_reg * CLOCK * 256 / rate, and freq_reg = hz * 2^24 / CLOCK,
    # so hz = step * rate / 2^32.
    var hz = Float64(step) * Float64(rate) / 4294967296.0
    if hz < 20.0:
        return String("--- ")
    var midi = 0
    var probe = 8.1757989156  # C-1
    while probe * 1.0293022366 < hz and midi < 127:
        probe *= 1.0594630943592953
        midi += 1
    var names = String("C C#D D#E F F#G G#A A#B ")
    var pc = midi % 12
    var octave = midi // 12 - 1
    var head = String(names[byte = pc * 2 : pc * 2 + 2])
    return head + String(octave) + String(" ")


def one_decimal(micros: Int) -> String:
    """Microseconds as milliseconds with one place, without a float format."""
    var us = 0 if micros < 0 else micros
    return String(us // 1000) + "." + String((us % 1000) // 100)


def tenths(parts_per_thousand: Int) -> String:
    """Parts per thousand as a percentage with one place."""
    var v = 0 if parts_per_thousand < 0 else parts_per_thousand
    return String(v // 10) + "." + String(v % 10)


def render_screen(scr: ScreenPtr) raises:
    """Paint the whole window into the BGRA buffer.

    Everything read out of the chip here is being written by the audio thread
    at the same moment, and nothing is locked. The worst case is one frame
    showing a number from a microsecond ago.
    """
    var st = P(unsafe_from_address=scr[].chip)
    var rate = get(st, S_RATE)

    # The border, and the screen inside it.
    fill_rect(scr[].frame, 0, 0, WIN_W, WIN_H, c64_light_blue())
    fill_rect(
        scr[].frame,
        BORDER,
        BORDER,
        WIN_W - 2 * BORDER,
        WIN_H - 2 * BORDER,
        c64_blue(),
    )

    var left = BORDER + 16

    text(
        scr,
        left,
        40,
        String("**** MOJO CHIP SYNTHESISER ****"),
        2,
        c64_light_blue(),
    )

    var paused = get(st, UI_PAUSE) != 0
    var status = (
        String("3 VOICES  ")
        + String(rate)
        + " HZ  FRAME "
        + String(get(st, S_FRAME))
    )
    if paused:
        status += "  [PAUSED]"
    text(scr, left, 66, status, 2, c64_light_blue())

    # The evidence line: what the deadline actually cost. WAKE is the gap
    # between the device's wakeups, LOAD is the fraction of that gap spent
    # inside the synthesiser, PEAK is the endpoint's own meter -- the
    # machine's answer to "is sound leaving this program" -- and MISS counts
    # wakes that found the ring already empty, which is the only evidence an
    # underrun leaves anywhere.
    var audio = (
        String("WAKE ")
        + one_decimal(get(st, ST_GAP_US))
        + "MS  LOAD "
        + tenths(get(st, ST_LOAD_PPM))
        + "%  PEAK "
        + String(get(st, ST_PEAK) // 100)
        + "%  MISS "
        + String(get(st, ST_UNDERRUNS))
    )
    if get(st, ST_RUNNING) == 0:
        audio = String("AUDIO STOPPED")
    text(scr, left, 92, audio, 2, c64_yellow())

    # ── The scope ───────────────────────────────────────────────────────────
    var scope_x = left
    var scope_y = 122
    var scope_w = WIN_W - 2 * BORDER - 32
    var scope_h = 132
    fill_rect(scr[].frame, scope_x, scope_y, scope_w, scope_h, c64_black())

    var mid = scope_y + scope_h // 2
    # The zero line, so a silent scope still reads as a scope.
    fill_rect(scr[].frame, scope_x, mid, scope_w, 1, rgb(40, 60, 40))

    var scope_addr = get(st, UI_SCOPE)
    if scope_addr != 0:
        var scope = Pointer[Float32, MutUntrackedOrigin](
            unsafe_from_address=scope_addr
        )
        var points = scope_w // 2
        for i in range(points):
            var s = Float64(scope[unsafe_offset = (i * SCOPE_LEN) // points])
            var h = Int(s * Float64(scope_h // 2 - 4))
            # Drawn from the centre outwards so the trace has body, the way a
            # phosphor scope does at low sweep speeds.
            var top = mid
            var height = h
            if h < 0:
                top = mid + h
                height = -h
            if height < 2:
                height = 2
            fill_rect(
                scr[].frame,
                scope_x + i * 2,
                top,
                2,
                height,
                c64_light_green(),
            )

    # ── The voices ──────────────────────────────────────────────────────────
    text(
        scr,
        left,
        268,
        String("VOICE  WAVE  NOTE   ENVELOPE"),
        2,
        c64_light_blue(),
    )
    for v in range(3):
        var y = 294 + v * 28
        var muted = get(st, UI_MUTE + v) != 0
        var ink = c64_light_red() if muted else c64_yellow()
        var env = vget(st, v, V_ENV) >> 16
        var line = String(" ") + String(v + 1) + String("     ")
        line += wave_name(vget(st, v, V_WAVE))
        line += String(" ") + note_name(vget(st, v, V_STEP), rate)
        text(scr, left, y, line, 2, ink)

        # The envelope, as a bar. This is read while the audio thread is
        # writing it; the worst case is one frame of a stale number.
        var bar_x = left + 18 * 16
        var bar_w = 296
        fill_rect(scr[].frame, bar_x, y + 1, bar_w, 14, rgb(30, 24, 80))
        if env > 0:
            var filled = bar_w * env // 255
            fill_rect(
                scr[].frame,
                bar_x,
                y + 1,
                filled,
                14,
                c64_light_red() if muted else c64_light_green(),
            )
        if muted:
            text(scr, bar_x + bar_w + 12, y, String("MUTE"), 2, c64_light_red())

    # ── The filter ──────────────────────────────────────────────────────────
    var mode = get(st, S_FMODE)
    var mode_name = String("OFF")
    if mode == FILT_LP:
        mode_name = String("LOW")
    elif mode == FILT_BP:
        mode_name = String("BAND")
    elif mode == FILT_HP:
        mode_name = String("HIGH")
    text(
        scr,
        left,
        390,
        String("FILTER ")
        + mode_name
        + String("  CUTOFF ")
        + String(get(st, S_CUTOFF))
        + String("  RES ")
        + String(get(st, S_RES)),
        2,
        c64_light_blue(),
    )

    text(
        scr,
        left,
        452,
        String(
            "SPACE PAUSE  1 2 3 MUTE  < > CUTOFF  - + RES  F FILTER  Q QUIT"
        ),
        1,
        c64_light_blue(),
    )


def blit(hdc: Int, scr: ScreenPtr, dest_w: Int, dest_h: Int) raises:
    """Push the CPU buffer into a device context, scaled to the client rect."""
    var StretchDIBits = win32[
        def (
            Int,
            c_int, c_int, c_int, c_int,
            c_int, c_int, c_int, c_int,
            Pointer[UInt32, MutAnyOrigin],
            Pointer[BITMAPINFOHEADER, MutAnyOrigin],
            UInt32,
            UInt32,
        ) thin abi("C") -> c_int,
        "StretchDIBits",
    ]()

    var bmi = BITMAPINFOHEADER()
    bmi.biSize = UInt32(size_of[BITMAPINFOHEADER]())
    bmi.biWidth = Int32(WIN_W)
    # A NEGATIVE height asks GDI for a top-down DIB: row 0 is the top row,
    # which is the order everybody computes pixels in. Positive means
    # bottom-up, and the picture arrives upside down.
    bmi.biHeight = Int32(-WIN_H)
    bmi.biPlanes = 1
    bmi.biBitCount = 32
    bmi.biCompression = UInt32(winkb_constant["BI_RGB"]())

    _ = StretchDIBits(
        hdc,
        c_int(0), c_int(0), c_int(dest_w), c_int(dest_h),
        c_int(0), c_int(0), c_int(WIN_W), c_int(WIN_H),
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=scr[].frame),
        com_addr(bmi),
        UInt32(winkb_constant["DIB_RGB_COLORS"]()),
        UInt32(winkb_constant["SRCCOPY"]()),
    )
    _ = bmi


# ===----------------------------------------------------------------------===#
# The window procedure. Windows calls this, so it is a captureless C-ABI
# function that must never raise -- unwinding through a Windows frame is
# undefined -- and every failure is caught here.
#
# Note what the key handler does NOT do: it does not stop the stream, take a
# lock, or hand anything across. It edits chip registers, which is precisely
# what the player routine does fifty times a second on the other thread, so
# there is nothing here the audio side is not already prepared for.
# ===----------------------------------------------------------------------===#


def stored_screen(hwnd: Int) raises -> Int:
    var GetWindowLongPtrW = win32[
        def (Int, c_int) thin abi("C") -> Int, "GetWindowLongPtrW"
    ]()
    return GetWindowLongPtrW(hwnd, c_int(winkb_constant["GWLP_USERDATA"]()))


@export("chip_wndproc")
def chip_wndproc(
    hwnd: Int, message: UInt32, wparam: Int, lparam: Int
) abi("C") -> Int:
    try:
        # Refuse the background erase: the whole client area is redrawn every
        # paint, and letting GDI clear it first is what makes it flicker.
        if message == UInt32(winkb_constant["WM_ERASEBKGND"]()):
            return 1

        var stored = stored_screen(hwnd)
        if stored == 0:
            # Messages arrive during CreateWindowExW, before there is anything
            # to point at.
            var Def0 = win32[WndProcType, "DefWindowProcW"]()
            return Def0(hwnd, message, wparam, lparam)
        var scr = ScreenPtr(unsafe_from_address=stored)
        var st = P(unsafe_from_address=scr[].chip)

        if message == UInt32(winkb_constant["WM_PAINT"]()):
            var BeginPaint = win32[
                def (Int, Pointer[UInt8, MutAnyOrigin]) thin abi("C") -> Int,
                "BeginPaint",
            ]()
            var EndPaint = win32[
                def (Int, Pointer[UInt8, MutAnyOrigin]) thin abi("C") -> c_int,
                "EndPaint",
            ]()
            var GetClientRect = win32[
                def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
                "GetClientRect",
            ]()
            # PAINTSTRUCT is never declared here, only sized, from the
            # metadata -- it is a box this code never looks inside.
            var ps = List[UInt8](
                length = winkb_struct_size["PAINTSTRUCT"](), fill=0
            )
            var ps_ptr = ps.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
            var hdc = BeginPaint(hwnd, ps_ptr)
            if hdc != 0:
                var rc = RECT()
                _ = GetClientRect(hwnd, com_addr(rc))
                blit(
                    hdc, scr, Int(rc.right - rc.left), Int(rc.bottom - rc.top)
                )
                scr[].painted += 1
            _ = EndPaint(hwnd, ps_ptr)
            _ = ps
            return 0

        if message == UInt32(winkb_constant["WM_TIMER"]()):
            if wparam == TICK_TIMER_ID:
                var InvalidateRect = win32[
                    def (Int, Int, c_int) thin abi("C") -> c_int,
                    "InvalidateRect",
                ]()
                scr[].ticks += 1

                # --freeze: stop the window thread dead, once, and see what
                # it does to the sound. The answer is nothing -- the paint
                # count stops advancing and the wake count does not. This is
                # the whole claim of the example, made falsifiable.
                if scr[].freeze_ms > 0 and scr[].ticks > 8:
                    var ms = scr[].freeze_ms
                    scr[].freeze_ms = 0
                    var painted_before = scr[].painted
                    var wakes_before = get(st, ST_WAKES)
                    var Sleep = win32[
                        def (UInt32) thin abi("C") -> NoneType, "Sleep"
                    ]()
                    Sleep(UInt32(ms))
                    print(
                        "froze the window thread for",
                        ms,
                        "ms: paints",
                        painted_before,
                        "->",
                        scr[].painted,
                        " audio wakes",
                        wakes_before,
                        "->",
                        get(st, ST_WAKES),
                        " underruns",
                        get(st, ST_UNDERRUNS),
                    )

                render_screen(scr)
                # Ask for a repaint; never paint from here. WM_PAINT is where
                # the window's own device context is valid, and the one place
                # that knows how big the client area currently is.
                _ = InvalidateRect(hwnd, 0, c_int(0))
                # A wall clock, not a tick count. WM_TIMER is a request, not
                # a promise: a slow paint pushes the next one out, so counting
                # ticks would make --ms mean something else on every machine.
                if scr[].close_at_ms != 0:
                    var GetTickCount64 = win32[
                        def () thin abi("C") -> Int, "GetTickCount64"
                    ]()
                    if GetTickCount64() >= scr[].close_at_ms:
                        var DestroyWindow = win32[
                            def (Int) thin abi("C") -> c_int, "DestroyWindow"
                        ]()
                        _ = DestroyWindow(hwnd)
            return 0

        if message == UInt32(winkb_constant["WM_SIZE"]()):
            var InvalidateRect = win32[
                def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
            ]()
            _ = InvalidateRect(hwnd, 0, c_int(0))
            return 0

        # ── Keyboard ─────────────────────────────────────────────────────
        # Typed characters arrive as WM_CHAR, which the message loop's
        # TranslateMessage produces: Windows has already applied the keyboard
        # layout by then, so what turns up is the character the person meant.
        if message == UInt32(winkb_constant["WM_CHAR"]()):
            var ch = wparam & 0xFFFF
            if ch == ord("q") or ch == ord("Q"):
                var PostMessageW = win32[
                    def (Int, UInt32, Int, Int) thin abi("C") -> c_int,
                    "PostMessageW",
                ]()
                _ = PostMessageW(
                    hwnd, UInt32(winkb_constant["WM_CLOSE"]()), 0, 0
                )
            elif ch == ord(" "):
                put(st, UI_PAUSE, 0 if get(st, UI_PAUSE) != 0 else 1)
            elif ch >= ord("1") and ch <= ord("3"):
                var v = ch - ord("1")
                if get(st, UI_MUTE + v) != 0:
                    put(st, UI_MUTE + v, 0)
                    vput(st, v, V_WAVE, get(st, UI_SAVED_WAVE + v))
                else:
                    put(st, UI_MUTE + v, 1)
                    put(st, UI_SAVED_WAVE + v, vget(st, v, V_WAVE))
                    # Silence is no waveform selected, which is what the
                    # register means -- not a volume of zero, which the chip
                    # does not have per voice.
                    vput(st, v, V_WAVE, 0)
            elif ch == ord(",") or ch == ord("<"):
                set_filter(
                    st, get(st, S_CUTOFF) - 64, get(st, S_RES), get(st, S_FMODE)
                )
            elif ch == ord(".") or ch == ord(">"):
                set_filter(
                    st, get(st, S_CUTOFF) + 64, get(st, S_RES), get(st, S_FMODE)
                )
            elif ch == ord("-"):
                var r = get(st, S_RES) - 1
                if r < 0:
                    r = 0
                set_filter(st, get(st, S_CUTOFF), r, get(st, S_FMODE))
            elif ch == ord("=") or ch == ord("+"):
                var r = get(st, S_RES) + 1
                if r > 15:
                    r = 15
                set_filter(st, get(st, S_CUTOFF), r, get(st, S_FMODE))
            elif ch == ord("f") or ch == ord("F"):
                var mode = get(st, S_FMODE)
                var next = FILT_LP
                if mode == FILT_LP:
                    next = FILT_BP
                elif mode == FILT_BP:
                    next = FILT_HP
                set_filter(st, get(st, S_CUTOFF), get(st, S_RES), next)
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
            # Tell the audio thread to leave BEFORE the message loop ends, so
            # it has the whole of the shutdown to notice. main() waits for it.
            put(st, ST_QUIT, 1)
            var PostQuitMessage = win32[
                def (c_int) thin abi("C") -> NoneType, "PostQuitMessage"
            ]()
            _ = PostQuitMessage(c_int(0))
            return 0

        var DefWindowProcW = win32[WndProcType, "DefWindowProcW"]()
        return DefWindowProcW(hwnd, message, wparam, lparam)
    except:
        return 0


# ===----------------------------------------------------------------------===#
# Evidence
#
# A synthesiser that runs without complaining is not evidence that it is
# right, and a stream that returns S_OK is not evidence that anything was
# heard. These are the checks whose answers are exact.
# ===----------------------------------------------------------------------===#


def check_chip(rate: Int) raises -> Int:
    """Returns the number of failures."""
    var bad = 0

    # Pitch, both ways. A4 is 440 Hz by definition, and the frequency register
    # the chip ends up holding has to read back as A4 -- which exercises the
    # 24.8 fixed point in both directions, including the sample rate.
    var a4 = midi_hz(69)
    var pitch_ok = a4 > 439.999 and a4 < 440.001
    var st = chip_new(rate)
    set_freq_hz(st, 0, 440.0)
    # The names table pads every name to two characters, so A4 reads "A 4 ".
    var name = note_name(vget(st, 0, V_STEP), rate)
    if name != String("A 4 "):
        pitch_ok = False
    print("  pitch   midi 69 -> 440 Hz -> register -> '" + name + "':",
          "ok" if pitch_ok else "FAIL")
    if not pitch_ok:
        bad += 1

    # The noise LFSR must never reach zero, which is a fixed point of the
    # shift: if it ever does, the noise is silence for the rest of the run.
    set_wave(st, 0, WAVE_NOISE)
    set_freq_reg(st, 0, 0x2000)
    gate_on(st, 0)
    var buf = external_call["calloc", P](Int(rate), Int(4)).unsafe_bitcast[
        Float32
    ]()
    var silent: Tick = quiet_tick
    var lfsr_ok = True
    for _ in range(4):
        chip_render(st, buf, rate, silent)
        if vget(st, 0, V_LFSR) == 0:
            lfsr_ok = False
    print("  noise   23-bit LFSR never reaches zero over 4 s:",
          "ok" if lfsr_ok else "FAIL")
    if not lfsr_ok:
        bad += 1

    # The filter's stability. Cutoff 1700 with resonance 5 is the pair that
    # diverged on the Mac before recompute_filter learned that f and q are not
    # independent; the state goes to infinity and then to NaN, which is
    # sticky -- every sample after it is NaN too and the synth is silent for
    # good. A NaN cannot be caught by the output clamp, so the check is for
    # samples that are neither out of range nor unequal to themselves.
    set_filter(st, 1700, 5, FILT_LP)
    set_wave(st, 0, WAVE_SAW)
    set_freq_hz(st, 0, 110.0)
    route_filter(st, 0, True)
    gate_on(st, 0)
    var filter_ok = True
    for _ in range(2):
        chip_render(st, buf, rate, silent)
        for i in range(0, rate, 97):
            var v = Float64(buf[unsafe_offset=i])
            if v != v or v > 1.0 or v < -1.0:
                filter_ok = False
    print("  filter  cutoff 1700 res 5 stays finite and in range for 2 s:",
          "ok" if filter_ok else "FAIL")
    if not filter_ok:
        bad += 1

    external_call["free", NoneType](buf.unsafe_bitcast[NoneType]())
    chip_free(st)
    return bad


@export("chip_quiet_tick")
def quiet_tick(st: P) abi("C") -> NoneType:
    """A player routine that plays nothing, for the checks."""
    return None


def check_abc(name: String, rate: Int) raises -> Int:
    """Parse a bundled tune and report what came out. Zero events is a
    failure: an ABC file that parses to nothing is indistinguishable from one
    that was never read.

    The file is looked for beside the example and from the repository root,
    because both are places somebody sensibly runs this from.
    """
    var source: String
    var path = String("tunes/") + name
    try:
        with open(path, "r") as f:
            source = f.read()
    except:
        var second = String("examples/win32/chip/tunes/") + name
        try:
            with open(second, "r") as f:
                source = f.read()
            path = second^
        except:
            print("  abc     " + name + ": not found (skipped)")
            return 0
    var tune = parse_abc(source)
    var st = chip_new(rate)
    var score = install_abc(st, tune)
    var total = 0
    for v in range(3):
        total += tune.count[v]
    print(
        "  abc     "
        + path
        + ": '"
        + tune.title
        + "', "
        + String(total)
        + " events across "
        + String(tune.count[0])
        + "/"
        + String(tune.count[1])
        + "/"
        + String(tune.count[2])
        + ":",
        "ok" if score != 0 and total > 0 else "FAIL",
    )
    chip_free(st)
    if score == 0 or total == 0:
        return 1
    return 0


# ===----------------------------------------------------------------------===#


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

    var tune_path = String("")
    var selftest = False
    var hold_ms = 0  # 0 means "stay open until asked to close"
    var buffer_ms = DEFAULT_BUFFER_MS
    var stall_ms = 0
    var freeze_ms = 0
    var args = argv()
    for i in range(len(args)):
        var a = String(args[i])
        if a == "--selftest":
            selftest = True
        elif a == "--ms" and i + 1 < len(args):
            hold_ms = Int(args[i + 1])
        elif a == "--buffer-ms" and i + 1 < len(args):
            buffer_ms = Int(args[i + 1])
        elif a == "--stall" and i + 1 < len(args):
            stall_ms = Int(args[i + 1])
        elif a == "--freeze" and i + 1 < len(args):
            freeze_ms = Int(args[i + 1])
        elif i > 0 and not a.startswith("--"):
            var previous = String(args[i - 1])
            if not (
                previous == "--ms"
                or previous == "--buffer-ms"
                or previous == "--stall"
                or previous == "--freeze"
            ):
                tune_path = a^

    # A checked run must terminate on its own; an ordinary one stays open
    # until somebody closes it.
    if selftest and hold_ms == 0:
        hold_ms = 6000

    print("metadata schema:", winkb_db_schema_version())

    # Declare DPI awareness BEFORE any window exists, or it is ignored.
    # Without it Windows lies to the process about the size of everything and
    # then bilinearly upscales whatever it draws -- which on an 8x8 character
    # ROM is the difference between hard edges and a grey smear.
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

    # The window thread's apartment. The MTA rather than the STA: this program
    # registers no OLE drop target and hosts no in-place server, the WASAPI
    # objects are agile, and the MTA is what lets the audio thread call
    # through pointers created here without a proxy.
    with Apartment(multithreaded=True):
        # ── The device, opened here and not on the audio thread ───────────
        # Everything that allocates, blocks, or can fail happens on this side
        # of the boundary, before any deadline exists -- the same rule the Mac
        # version follows by doing its AudioUnit setup in main(). What crosses
        # to the other thread is a stream that is already open and a block of
        # memory that is already allocated.
        var enumerator = open_enumerator()
        var device = default_render_device(enumerator.address())
        print("endpoint:", endpoint_id(device.address()))

        var client = activate["IAudioClient"](device.address())
        var meter = activate["IAudioMeterInformation"](device.address())

        var format_address = mix_format_address(client.address())
        var fmt = read_mix_format(format_address)
        print(
            "mix format:",
            fmt.rate,
            "Hz,",
            fmt.channels,
            "channels,",
            fmt.bits,
            "bit,",
            "float" if fmt.is_float else "int16",
        )

        var stream = initialize_stream(
            client.address(), format_address, buffer_ms
        )
        co_task_free(format_address)
        print(
            "device period:",
            Float64(stream.default_period_us) / 1000.0,
            "ms default,",
            Float64(stream.minimum_period_us) / 1000.0,
            "ms minimum",
        )
        print(
            "ring:",
            stream.buffer_frames,
            "frames =",
            Float64(stream.buffer_frames * 1000) / Float64(fmt.rate),
            "ms",
        )

        var render = render_client(client.address())

        # ── The chip, at the mixer's rate ────────────────────────────────
        var st = chip_new(fmt.rate)

        if selftest:
            print("chip checks:")
            var bad = check_chip(fmt.rate)
            bad += check_abc(String("scale.abc"), fmt.rate)
            bad += check_abc(String("ode.abc"), fmt.rate)
            if bad != 0:
                raise Error(
                    String(bad) + " chip check(s) failed"
                )

        # A named .abc file replaces the built-in tune. The parse happens
        # here, before the stream is started: it allocates and it can raise,
        # and the fill may do neither.
        var loaded = String("built-in")
        if len(tune_path.as_bytes()) > 0:
            var source: String
            try:
                with open(tune_path, "r") as f:
                    source = f.read()
            except:
                raise Error("could not read " + tune_path)
            var parsed = parse_abc(source)
            var score = install_abc(st, parsed)
            if score == 0:
                raise Error("no notes found in " + tune_path)
            # An ABC tune says nothing about timbre, so the voices get the
            # standing arrangement: melody, bass, and anything left over.
            instrument_lead(st, 0)
            instrument_bass(st, 1)
            instrument_lead(st, 2)
            set_filter(st, 1200, 8, FILT_LP)
            player_attach(st, score, True)
            var title = String(parsed.title)
            loaded = title^ if len(parsed.title.as_bytes()) > 0 else tune_path
        else:
            _ = build_demo(st)
        print("playing:", loaded)

        if stall_ms > 0:
            put(st, ST_STALL_MS, stall_ms)

        # ── Buffers, all of them allocated before a sample is rendered ───
        put(
            st,
            UI_SCOPE,
            Int(external_call["calloc", P](Int(SCOPE_LEN), Int(4))),
        )
        var mono = Int(
            external_call["calloc", P](Int(stream.buffer_frames), Int(4))
        )
        var frame_buf = unsafe_alloc[UInt32](PIXELS, alignment=64)
        var rom = font_rom()

        var store = unsafe_alloc[Screen](1, alignment=8)
        # Emplaced, not assigned: `store[] = value` would destroy what was
        # there first, and what is there is whatever the allocator last had.
        store.unsafe_write(Screen())
        var scr = ScreenPtr(unsafe_from_address=Int(store))
        scr[].chip = Int(st)
        scr[].frame = Int(frame_buf)
        scr[].rom = rom

        var link = unsafe_alloc[AudioLink](1, alignment=8)
        link.unsafe_write(
            AudioLink(
                Int(st),
                client.address(),
                render.address(),
                meter.address(),
                mono,
                fmt.copy(),
                stream.copy(),
            )
        )

        # ── The window ───────────────────────────────────────────────────
        var GetModuleHandleW = win32[
            def (Int) thin abi("C") -> Int, "GetModuleHandleW"
        ]()
        var GetLastError = win32[
            def () thin abi("C") -> UInt32, "GetLastError"
        ]()
        var LoadCursorW = win32[
            def (Int, Int) thin abi("C") -> Int, "LoadCursorW"
        ]()
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
        var UpdateWindow = win32[
            def (Int) thin abi("C") -> c_int, "UpdateWindow"
        ]()
        var SetWindowLongPtrW = win32[
            def (Int, c_int, Int) thin abi("C") -> Int, "SetWindowLongPtrW"
        ]()
        var SetTimer = win32[
            def (Int, Int, UInt32, Int) thin abi("C") -> Int, "SetTimer"
        ]()
        var KillTimer = win32[def (Int, Int) thin abi("C") -> c_int, "KillTimer"]()
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
            def (Pointer[MSG, MutAnyOrigin]) thin abi("C") -> Int,
            "DispatchMessageW",
        ]()

        var hInstance = GetModuleHandleW(0)
        var class_name = wide("MojoChipWindow")
        var title_text = wide_of(String("CHIP - ") + loaded)

        var proc: WndProcType = chip_wndproc
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
                "RegisterClassExW failed, GetLastError = "
                + String(GetLastError())
            )

        # CreateWindowExW takes the OUTER size, so ask Windows how much frame
        # the style adds rather than guessing at a border width.
        comptime STYLE = winkb_constant["WS_OVERLAPPEDWINDOW"]()
        var want = RECT()
        want.left = 0
        want.top = 0
        want.right = Int32(WIN_W)
        want.bottom = Int32(WIN_H)
        _ = AdjustWindowRectEx(com_addr(want), UInt32(STYLE), c_int(0), UInt32(0))

        var hwnd = CreateWindowExW(
            UInt32(0),
            class_name.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            title_text.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            UInt32(STYLE),
            c_int(80), c_int(80),
            c_int(Int(want.right - want.left)),
            c_int(Int(want.bottom - want.top)),
            0, 0, hInstance, 0,
        )
        if hwnd == 0:
            raise Error(
                "CreateWindowExW failed, GetLastError = "
                + String(GetLastError())
            )
        _ = class_name
        _ = title_text

        # --ms closes the window on its own clock, with or without the
        # checks, so an unattended run always terminates.
        if hold_ms > 0:
            var GetTickCount64 = win32[
                def () thin abi("C") -> Int, "GetTickCount64"
            ]()
            scr[].close_at_ms = GetTickCount64() + (
                hold_ms if hold_ms > 500 else 500
            )

        scr[].freeze_ms = freeze_ms
        render_screen(scr)
        _ = SetWindowLongPtrW(
            hwnd, c_int(winkb_constant["GWLP_USERDATA"]()), Int(store)
        )
        _ = ShowWindow(hwnd, c_int(winkb_constant["SW_SHOW"]()))
        _ = UpdateWindow(hwnd)
        _ = SetTimer(hwnd, TICK_TIMER_ID, UInt32(TICK_MS), 0)

        # ── The audio thread ─────────────────────────────────────────────
        # A Mojo `def` declared `thin abi("C")` is an LPTHREAD_START_ROUTINE.
        # Nothing is wrapped, generated, or bridged: the address of the
        # function goes into CreateThread and Windows calls it.
        #
        # Started last, once the window is up and nothing between here and the
        # message loop can fail. Starting it earlier would mean a thread
        # calling through interface pointers that a raise on this side is
        # about to release, and there is no `finally` to close that window
        # with -- so the window is arranged not to exist.
        var CreateThread = win32[
            def (Int, Int, Int, Int, UInt32, Int) thin abi("C") -> Int,
            "CreateThread",
        ]()
        var WaitForSingleObject = win32[
            def (Int, UInt32) thin abi("C") -> UInt32, "WaitForSingleObject"
        ]()
        var CloseHandle = win32[def (Int) thin abi("C") -> Int32, "CloseHandle"]()

        var thread_proc: ThreadProc = chip_audio_thread
        var thread = CreateThread(
            0,
            0,
            Int(_fn_ptr_as_opaque(thread_proc)),
            Int(link),
            UInt32(0),
            0,
        )
        if thread == 0:
            raise Error("CreateThread failed")

        print(
            "CHIP.  SPACE pause . 1 2 3 mute . < > cutoff . - + resonance ."
            " F filter . Q quit"
        )

        # ── The loop ─────────────────────────────────────────────────────
        # GetMessageW blocks, so a window nobody is touching costs nothing --
        # and the audio does not care what this loop does, which is the whole
        # claim this example makes. Drag the window around: the sound does not
        # stutter, because it is not on this thread's clock.
        var msg = MSG()
        while True:
            var got = GetMessageW(com_addr(msg), 0, 0, 0)
            if got == 0:
                break
            if got == -1:
                # Not a raise: the audio thread is running and holding the
                # interface pointers this scope releases on the way out, so
                # leaving the loop normally is the only shutdown that is safe.
                print("GetMessageW failed, GetLastError =", GetLastError())
                break
            _ = TranslateMessage(com_addr(msg))
            _ = DispatchMessageW(com_addr(msg))

        _ = KillTimer(hwnd, TICK_TIMER_ID)

        # ── Shutdown, in the only order that works ────────────────────────
        # The audio thread is still inside the loop, calling through the same
        # interface pointers this scope is about to release. So: ask it to
        # stop, wait for it to actually have stopped, and only then let go of
        # anything it was using. Releasing first is a use-after-free with a
        # stack that mentions nothing but ole32.
        put(st, ST_QUIT, 1)
        var waited = WaitForSingleObject(thread, UInt32(5000))
        if waited != UInt32(winkb_constant["WAIT_OBJECT_0"]()):
            print("the audio thread did not stop; leaving it alone")
        _ = CloseHandle(thread)
        _ = CloseHandle(stream.event)

        var wakes = get(st, ST_WAKES)
        print("frames painted", scr[].painted, " audio wakes", wakes)
        print(
            "audio: frames written",
            get(st, ST_FRAMES),
            "=",
            Float64(get(st, ST_FRAMES)) / Float64(fmt.rate),
            "s",
        )
        if wakes > 0:
            print(
                "wake gap: last",
                Float64(get(st, ST_GAP_US)) / 1000.0,
                "ms  worst",
                Float64(get(st, ST_GAPMAX_US)) / 1000.0,
                "ms   fill",
                Float64(get(st, ST_FILL_US)) / 1000.0,
                "ms =",
                Float64(get(st, ST_LOAD_PPM)) / 10.0,
                "% of it",
            )
        print("underruns (wakes that found the ring empty):",
              get(st, ST_UNDERRUNS))
        var peak = Float64(get(st, ST_PEAKMAX)) / 10000.0
        print("endpoint peak meter reached", peak)
        if get(st, ST_ERROR) != 0:
            print("the audio thread reported a fault, code", get(st, ST_ERROR))

        # Everything the audio thread borrowed is released here, innermost
        # first: the render client is a service of the client, the client is a
        # service of the device, the device came from the enumerator. All of
        # it before CoUninitialize, which the Apartment scope runs on the way
        # out -- releasing a COM pointer after the apartment is gone is a
        # crash in ole32 with no useful stack. Mojo destroys at last use, so
        # the order is forced rather than hoped for.
        _ = render^
        _ = meter^
        _ = client^
        _ = device^
        _ = enumerator^

        external_call["free", NoneType](
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=mono)
        )
        external_call["free", NoneType](
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=get(st, UI_SCOPE))
        )
        external_call["free", NoneType](
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=rom)
        )
        frame_buf.unsafe_free()
        store.unsafe_free()
        link.unsafe_free()

        if selftest:
            if wakes == 0:
                raise Error("the audio thread never woke: nothing played")
            if peak <= 0.0:
                raise Error(
                    "the endpoint's peak meter never moved: nothing reached"
                    " the device"
                )
            print("AUDIBLE: the device metered our samples")

        chip_free(st)
    print("done")
