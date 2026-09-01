# The window: a tune list, a voice editor, and a playable keyboard.
#
# Everything here draws itself. There is no button control and no trackbar --
# the panel is a few dozen rectangles and a hit test, which is less code than
# creating and wiring that many child windows, and it keeps the whole
# interface in one place you can read.
#
# The keyboard layout is Logic Pro's and GarageBand's "Musical Typing". The
# Mac chose it because it is the mapping a Mac musician already has in their
# fingers; it is kept here because it is also just a good mapping, and because
# a person who knows both machines should not have to learn it twice:
#
#       W E   T Y U   O P          <- the black keys, in their piano positions
#      A S D F G H J K L ;         <- the white keys, from C
#
#   Z / X   octave down / up        C / V   level down / up
#   Tab     sustain                 Space   play / pause the tune
#
# Z X C V are free for that job precisely because they are not note keys.
#
# Nothing here touches the schedule the audio loop is walking. Live notes are
# register writes -- set a frequency, raise a gate -- and the fill loop reads
# those registers on its own clock. A torn read costs one frame of one
# oscillator, where a lock would cost a click in the speaker.
#
# The one visible difference from the Mac version is the arithmetic. Cocoa
# measures from the bottom of the window and this measures from the top, so
# the Mac's `box()` helper -- which existed only to do that subtraction in one
# place -- is gone, and every rectangle below is written the way it is read.

from std.ffi import c_int
from std.memory import Pointer, MutUntrackedOrigin, OpaquePointer
from std.sys._com import com_addr
from std.sys._winkb import winkb_constant

from chip import (
    P, get, put, vget, vput, set_wave, set_adsr, set_filter, route_filter,
    set_volume, set_pulse_width, set_freq_hz, gate_on, gate_off,
    PLAYER_BASE, SAMPLE_RATE, V_WAVE, V_PW, V_FILT,
    S_CUTOFF, S_RES, S_FMODE, S_VOL,
    WAVE_TRI, WAVE_SAW, WAVE_PULSE, WAVE_NOISE, FILT_LP, FILT_BP, FILT_HP,
)
from chipplay import (
    SC_PAUSE, SC_VOICE_NOTE, midi_to_hz, record_adsr, CHIP_ADSR,
)
from win32 import win32, wide_of, RECT
import winmidi


comptime WIN_W = 980
comptime WIN_H = 660

comptime BACKEND_CHIP = 0
comptime BACKEND_MIDI = 1

comptime MODE_LIVE = 0
comptime MODE_TUNE = 1

comptime CMD_QUIT = 1
comptime CMD_PLAY = 2       # load and play the selected tune
comptime CMD_STOP = 4       # back to live mode
comptime CMD_PAUSE = 8
comptime CMD_ADD = 16       # run a file dialog; the message loop does it

comptime SCOPE_LEN = 1024

# Per voice: wave, A, D, S, R, pulse width, filter routing.
comptime PV_STRIDE = 8
comptime PV_WAVE = 0
comptime PV_A = 1
comptime PV_D = 2
comptime PV_S = 3
comptime PV_R = 4
comptime PV_PW = 5
comptime PV_FILT = 6
comptime PG_CUTOFF = 24
comptime PG_RES = 25
comptime PG_FMODE = 26
comptime PG_VOL = 27
comptime PARAM_SLOTS = 28


struct App(Movable):
    """Everything the window knows.

    A window procedure is captureless -- Windows calls it, so it holds nothing
    and must fetch what it needs from the one pointer a window can keep. This
    is that thing, on the heap, reached through GWLP_USERDATA. The Mac version
    spread the same state over a dozen process globals because a Cocoa
    selector has nowhere else to look; Windows offers a slot per window, which
    is better, so this port uses it.
    """

    var chip: Int              # the chip's state block, as an address
    var hwnd: Int
    var backend: Int
    var cmd: Int               # flags the message loop acts on and clears

    var paths: List[String]
    var names: List[String]
    var status: String
    var title: String
    var subtitle: String
    var home_subtitle: String  # what the header says when no tune is loaded
    var params: List[Int]
    var held: List[Int]        # the note each voice is holding, live

    var sel: Int               # selected tune, -1 for none
    var loaded: Int            # the tune actually playing, -1 for none
    var octave: Int
    var sustain: Int
    var mode: Int
    var drag: Int              # which slider the mouse has, -1 for none

    var font_title: Int
    var font_body: Int
    var font_small: Int

    var scope: Int             # Float32 ring the fill loop copies into
    var scope_pos: Int
    var pos_samples: Int       # progress, in samples, whichever backend
    var end_samples: Int
    var end_ticks: Int         # the same end in ticks, for the MIDI backend
    var paused: Int
    var starved: Int           # wakes that found the ring empty
    var out_peak: Float64      # the loudest sample WE produced

    var memdc: Int             # the back buffer this window paints into
    var membmp: Int
    var midi_stream: Int       # the HMIDISTRM, so the keys play in --midi too

    def __init__(out self):
        self.chip = 0
        self.hwnd = 0
        self.backend = BACKEND_CHIP
        self.cmd = 0
        self.paths = List[String]()
        self.names = List[String]()
        self.status = String("ready")
        self.title = String("ABC player")
        self.subtitle = String("")
        self.home_subtitle = String("")
        self.params = List[Int]()
        self.held = List[Int]()
        self.sel = -1
        self.loaded = -1
        self.octave = 4
        self.sustain = 0
        self.mode = MODE_LIVE
        self.drag = -1
        self.font_title = 0
        self.font_body = 0
        self.font_small = 0
        self.scope = 0
        self.scope_pos = 0
        self.pos_samples = 0
        self.end_samples = 1
        self.end_ticks = 1
        self.paused = 0
        self.starved = 0
        self.out_peak = 0.0
        self.memdc = 0
        self.membmp = 0
        self.midi_stream = 0


comptime AppPtr = Pointer[App, MutAnyOrigin]


def ui_init(app: AppPtr):
    """Every list starts at its full length, so nothing indexes past the end.
    """
    while len(app[].held) < 3:
        app[].held.append(-1)
    while len(app[].params) < PARAM_SLOTS:
        app[].params.append(0)
    for v in range(3):
        var b = v * PV_STRIDE
        app[].params[b + PV_WAVE] = WAVE_PULSE if v == 0 else WAVE_SAW
        app[].params[b + PV_A] = 0
        app[].params[b + PV_D] = 7
        app[].params[b + PV_S] = 11
        app[].params[b + PV_R] = 5
        app[].params[b + PV_PW] = 1400
        app[].params[b + PV_FILT] = 1
    app[].params[PG_CUTOFF] = 1500
    app[].params[PG_RES] = 6
    app[].params[PG_FMODE] = FILT_LP
    app[].params[PG_VOL] = 14


def chip_of(app: AppPtr) -> P:
    return P(unsafe_from_address=app[].chip)


def apply_params(app: AppPtr):
    """Push every parameter into the chip's registers."""
    if app[].chip == 0:
        return
    var st = chip_of(app)
    for v in range(3):
        var b = v * PV_STRIDE
        set_wave(st, v, app[].params[b + PV_WAVE])
        set_adsr(
            st, v, app[].params[b + PV_A], app[].params[b + PV_D],
            app[].params[b + PV_S], app[].params[b + PV_R],
        )
        record_adsr(
            st, v, app[].params[b + PV_A], app[].params[b + PV_D],
            app[].params[b + PV_S], app[].params[b + PV_R],
        )
        set_pulse_width(st, v, app[].params[b + PV_PW])
        route_filter(st, v, app[].params[b + PV_FILT] != 0)
    set_filter(
        st, app[].params[PG_CUTOFF], app[].params[PG_RES],
        app[].params[PG_FMODE],
    )
    set_volume(st, app[].params[PG_VOL])


# ── Musical typing ──────────────────────────────────────────────────────────


fn semitone_for(c: Int) -> Int:
    """Logic Pro's Musical Typing layout. -1 for a key that is not a note.

    The home row is the white keys from C and the row above holds the black
    keys where a piano puts them -- which is why R and I are gaps: there is no
    black key between E and F, or between B and C.
    """
    # a s d f g h j k l ;   ->  C D E F G A B C D E
    if c == 97: return 0        # a
    if c == 115: return 2       # s
    if c == 100: return 4       # d
    if c == 102: return 5       # f
    if c == 103: return 7       # g
    if c == 104: return 9       # h
    if c == 106: return 11      # j
    if c == 107: return 12      # k
    if c == 108: return 14      # l
    if c == 59: return 16       # ;
    # w e   t y u   o p     ->  C# D#  F# G# A#  C# D#
    if c == 119: return 1       # w
    if c == 101: return 3       # e
    if c == 116: return 6       # t
    if c == 121: return 8       # y
    if c == 117: return 10      # u
    if c == 111: return 13      # o
    if c == 112: return 15      # p
    return -1


def note_on(app: AppPtr, midi: Int) raises:
    """Sound a note on a free voice, stealing the oldest if there is none.

    Both backends, because a keyboard that works in one mode and not in the
    other is a keyboard people stop trusting. In `--midi` there is no voice
    stealing to do -- the system synthesiser has dozens -- but the note is
    still parked in a `held` slot so the drawn keyboard can light it.
    """
    if app[].chip == 0:
        return
    var st = chip_of(app)
    var slot = -1
    for v in range(3):
        if app[].held[v] < 0:
            slot = v
            break
    if slot < 0:
        # Every voice is busy. Take voice 0: it is the one that has been
        # sounding longest, and a chip with three oscillators has to drop
        # something.
        slot = 0
        gate_off(st, slot)
    app[].held[slot] = midi
    if app[].backend == BACKEND_MIDI:
        winmidi.short_msg(app[].midi_stream, 0x90, midi, 96)
        return
    set_freq_hz(st, slot, midi_to_hz(midi))
    # gate_on, not a bare V_GATE write. A gate is TWO registers: the gate bit
    # and the envelope phase. Setting the bit alone leaves the envelope in
    # ENV_IDLE, so the oscillator runs and the envelope multiplies it to
    # nothing -- a key that is audibly dead while every register looks right.
    gate_on(st, slot)


def note_off(app: AppPtr, midi: Int) raises:
    if app[].chip == 0 or app[].sustain != 0:
        return
    var st = chip_of(app)
    for v in range(3):
        if app[].held[v] == midi:
            if app[].backend == BACKEND_MIDI:
                winmidi.short_msg(app[].midi_stream, 0x80, midi, 0)
            else:
                gate_off(st, v)
            app[].held[v] = -1


def all_notes_off(app: AppPtr) raises:
    if app[].chip == 0:
        return
    var st = chip_of(app)
    for v in range(3):
        if app[].backend == BACKEND_MIDI and app[].held[v] >= 0:
            winmidi.short_msg(app[].midi_stream, 0x80, app[].held[v], 0)
        gate_off(st, v)
        app[].held[v] = -1


def key_down(app: AppPtr, c: Int, repeat: Bool) raises:
    """One key press. Every effect is a register write or a command flag."""
    if repeat:
        return
    var semi = semitone_for(c)
    if semi >= 0:
        if app[].mode == MODE_TUNE:
            return          # the tune owns the voices
        note_on(app, app[].octave * 12 + 12 + semi)
        return

    if c == 122:            # z -- octave down
        if app[].octave > 0:
            app[].octave -= 1
    elif c == 120:          # x -- octave up
        if app[].octave < 8:
            app[].octave += 1
    elif c == 99:           # c -- level down
        if app[].params[PG_VOL] > 0:
            app[].params[PG_VOL] = app[].params[PG_VOL] - 1
            apply_params(app)
    elif c == 118:          # v -- level up
        if app[].params[PG_VOL] < 15:
            app[].params[PG_VOL] = app[].params[PG_VOL] + 1
            apply_params(app)
    elif c == 9:            # tab -- sustain
        var was = app[].sustain
        app[].sustain = 0 if was != 0 else 1
        if was != 0:
            all_notes_off(app)
    elif c == 32:           # space -- play or pause
        if app[].mode == MODE_TUNE:
            app[].cmd = app[].cmd | CMD_PAUSE
        else:
            app[].cmd = app[].cmd | CMD_PLAY
    elif c == 27 or c == 113:   # esc, q
        app[].cmd = app[].cmd | CMD_QUIT


def key_up(app: AppPtr, c: Int) raises:
    var semi = semitone_for(c)
    if semi >= 0 and app[].mode == MODE_LIVE:
        note_off(app, app[].octave * 12 + 12 + semi)


# ── Drawing primitives ──────────────────────────────────────────────────────


@fieldwise_init
struct Box(ImplicitlyCopyable, Copyable, Movable):
    """A rectangle in client coordinates, by its top-left corner."""

    var x: Int
    var y: Int
    var w: Int
    var h: Int

    fn holds(self, px: Int, py: Int) -> Bool:
        return (
            px >= self.x
            and px < self.x + self.w
            and py >= self.y
            and py < self.y + self.h
        )


fn rgb(r: Int, g: Int, b: Int) -> UInt32:
    """A COLORREF. Windows packs it 0x00BBGGRR, the opposite way round from
    the way everyone writes a colour down."""
    return UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16)


comptime INK = rgb(228, 232, 240)
comptime DIM = rgb(128, 138, 158)
comptime ACCENT = rgb(120, 220, 160)
comptime BACKDROP = rgb(18, 20, 26)
comptime WELL = rgb(30, 34, 44)
comptime FACE = rgb(34, 39, 50)
comptime FACE_ON = rgb(52, 60, 76)
comptime DEAD = rgb(96, 104, 120)
comptime SCOPE_BG = rgb(10, 12, 16)


def fill_box(hdc: Int, b: Box, colour: UInt32) raises:
    """One filled rectangle.

    A brush per rectangle rather than a cached palette: the whole panel is
    about ninety of these at thirty frames a second, which is nothing, and a
    cache of GDI objects is a leak waiting for the first early `return`.
    """
    var CreateSolidBrush = win32[
        def (UInt32) thin abi("C") -> Int, "CreateSolidBrush"
    ]()
    var FillRect = win32[
        def (Int, Pointer[RECT, MutAnyOrigin], Int) thin abi("C") -> c_int,
        "FillRect",
    ]()
    var DeleteObject = win32[def (Int) thin abi("C") -> c_int, "DeleteObject"]()
    var r = RECT()
    r.left = Int32(b.x)
    r.top = Int32(b.y)
    r.right = Int32(b.x + b.w)
    r.bottom = Int32(b.y + b.h)
    var brush = CreateSolidBrush(colour)
    _ = FillRect(hdc, com_addr(r), brush)
    _ = DeleteObject(brush)
    _ = r


def draw_text(
    hdc: Int, text: String, x: Int, y: Int, font: Int, colour: UInt32
) raises:
    var SelectObject = win32[
        def (Int, Int) thin abi("C") -> Int, "SelectObject"
    ]()
    var SetTextColor = win32[
        def (Int, UInt32) thin abi("C") -> UInt32, "SetTextColor"
    ]()
    var SetBkMode = win32[def (Int, c_int) thin abi("C") -> c_int, "SetBkMode"]()
    var TextOutW = win32[
        def (
            Int, c_int, c_int, Pointer[UInt16, MutAnyOrigin], c_int
        ) thin abi("C") -> c_int,
        "TextOutW",
    ]()
    var buf = wide_of(text)
    var old = SelectObject(hdc, font) if font != 0 else 0
    # TRANSPARENT, or every label paints a rectangle of the last background
    # colour over whatever it sits on -- which here is a filled bar.
    _ = SetBkMode(hdc, c_int(winkb_constant["TRANSPARENT"]()))
    _ = SetTextColor(hdc, colour)
    _ = TextOutW(
        hdc,
        c_int(x),
        c_int(y),
        buf.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        c_int(len(buf) - 1),
    )
    if font != 0:
        _ = SelectObject(hdc, old)
    _ = buf


def make_font(px: Int, bold: Bool) raises -> Int:
    """A monospaced face at a pixel height.

    A negative height asks for the character height rather than the cell
    height, which is what "11 pixels" means to anyone reading this. Consolas
    is named, and Windows falls back to whatever DEFAULT_CHARSET|FIXED_PITCH
    finds if the machine has not got it.
    """
    var CreateFontW = win32[
        def (
            c_int, c_int, c_int, c_int, c_int,
            UInt32, UInt32, UInt32,
            UInt32, UInt32, UInt32, UInt32, UInt32,
            Pointer[UInt16, MutAnyOrigin],
        ) thin abi("C") -> Int,
        "CreateFontW",
    ]()
    var face = wide_of(String("Consolas"))
    var f = CreateFontW(
        c_int(-px), c_int(0), c_int(0), c_int(0),
        c_int(winkb_constant["FW_BOLD"]() if bold else winkb_constant["FW_NORMAL"]()),
        UInt32(0), UInt32(0), UInt32(0),
        UInt32(winkb_constant["DEFAULT_CHARSET"]()),
        UInt32(winkb_constant["OUT_DEFAULT_PRECIS"]()),
        UInt32(winkb_constant["CLIP_DEFAULT_PRECIS"]()),
        UInt32(winkb_constant["CLEARTYPE_QUALITY"]()),
        UInt32(
            winkb_constant["FIXED_PITCH"]() | winkb_constant["FF_MODERN"]()
        ),
        face.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
    )
    _ = face
    return f


fn note_name(midi: Int) -> String:
    if midi < 0:
        return String("---")
    var names = String("C C#D D#E F F#G G#A A#B ")
    var pc = midi % 12
    var octave = midi // 12 - 1
    return names[byte = pc * 2 : pc * 2 + 2] + String(octave)


fn format_time(samples: Int) -> String:
    var total = samples // SAMPLE_RATE
    var minutes = total // 60
    var seconds = total % 60
    var s = String(minutes) + String(":")
    if seconds < 10:
        s += String("0")
    return s + String(seconds)


# ── Layout ──────────────────────────────────────────────────────────────────

comptime LIST_X = 20
comptime LIST_W = 268
comptime LIST_TOP = 96
comptime ROW_H = 22
comptime ROWS = 14
comptime BTN_TOP = LIST_TOP + ROW_H * ROWS + 10
comptime BTN_H = 26

comptime PANEL_X = 306
comptime PANEL_W = 654
comptime SCOPE_TOP = 96
comptime SCOPE_H = 86
comptime EDIT_TOP = 232

comptime KEYS_X = 20
comptime KEYS_TOP = 452
comptime WHITE_W = 62
comptime WHITE_H = 148
comptime BLACK_W = 38
comptime BLACK_H = 92

# Three voices, all on screen. The chip has three and no more, and a patch is
# the relationship BETWEEN them -- which voice carries the melody, which one
# is the noise channel -- so hiding two behind a tab hides the thing you are
# actually editing. The globals sit in their own block to the right, because
# cutoff and resonance belong to the one filter all three share, and a slider
# that looks per-voice and is not is worse than no label at all.

comptime VCOL_W = 214
comptime BAR_TOP = EDIT_TOP + 56
comptime BAR_H = 70
comptime BAR_W = 26
comptime BAR_GAP = 38

# To the right of the keyboard, which is ten white keys wide and leaves this
# column empty.
comptime FILT_X = KEYS_X + 10 * WHITE_W + 28
comptime GLOB_TOP = KEYS_TOP
comptime GS_W = 150
comptime GS_H = 16


fn vcol_x(v: Int) -> Int:
    return PANEL_X + v * VCOL_W


fn wave_box(v: Int, i: Int) -> Box:
    return Box(vcol_x(v) + 6 + i * 50, EDIT_TOP + 22, 46, 18)


fn bar_box(v: Int, k: Int) -> Box:
    return Box(vcol_x(v) + 6 + k * BAR_GAP, BAR_TOP, BAR_W, BAR_H)


fn filt_box(v: Int) -> Box:
    return Box(vcol_x(v) + 6, EDIT_TOP + 164, 120, 18)


fn gslider_box(i: Int) -> Box:
    return Box(FILT_X, GLOB_TOP + 26 + i * 26, GS_W, GS_H)


fn fmode_box(i: Int) -> Box:
    return Box(FILT_X + i * 52, GLOB_TOP + 112, 46, 20)


fn white_box(i: Int) -> Box:
    return Box(KEYS_X + i * WHITE_W, KEYS_TOP, WHITE_W - 2, WHITE_H)


fn black_after(i: Int) -> Int:
    """Which white key each black key sits after."""
    if i == 0: return 0
    if i == 1: return 1
    if i == 2: return 3
    if i == 3: return 4
    if i == 4: return 5
    if i == 5: return 7
    return 8


fn black_box(i: Int) -> Box:
    return Box(
        KEYS_X + (black_after(i) + 1) * WHITE_W - BLACK_W // 2 - 1,
        KEYS_TOP, BLACK_W, BLACK_H,
    )


comptime BUTTONS = 4


fn btn_box(i: Int) -> Box:
    var w = (LIST_W - 6 * (BUTTONS - 1)) // BUTTONS
    return Box(LIST_X + i * (w + 6), BTN_TOP, w, BTN_H)


fn row_box(i: Int) -> Box:
    return Box(LIST_X, LIST_TOP + i * ROW_H, LIST_W, ROW_H - 2)


fn bar_label(k: Int) -> String:
    if k == 0: return String("A")
    if k == 1: return String("D")
    if k == 2: return String("S")
    if k == 3: return String("R")
    return String("pw")


fn bar_max(k: Int) -> Int:
    return 4095 if k == 4 else 15


fn bar_field(k: Int) -> Int:
    if k == 0: return PV_A
    if k == 1: return PV_D
    if k == 2: return PV_S
    if k == 3: return PV_R
    return PV_PW


def bar_value(app: AppPtr, v: Int, k: Int) -> Int:
    """Read the chip, not the UI's copy of it.

    A tune's [I:chip ...] directives move these registers while it plays, so a
    panel drawn from the parameter list would show what the user last set
    while the chip did something else -- a display that is confidently wrong.
    """
    if app[].chip == 0:
        return app[].params[v * PV_STRIDE + bar_field(k)]
    var st = chip_of(app)
    if k == 4:
        return vget(st, v, V_PW)
    return get(st, PLAYER_BASE + CHIP_ADSR + v * 4 + k)


def bar_set(app: AppPtr, v: Int, k: Int, value: Int):
    var x = value
    if x < 0:
        x = 0
    if x > bar_max(k):
        x = bar_max(k)
    app[].params[v * PV_STRIDE + bar_field(k)] = x
    apply_params(app)


fn gs_label(i: Int) -> String:
    if i == 0: return String("cutoff")
    if i == 1: return String("resonance")
    return String("level")


fn gs_max(i: Int) -> Int:
    return 2047 if i == 0 else 15


fn gs_slot(i: Int) -> Int:
    if i == 0: return PG_CUTOFF
    if i == 1: return PG_RES
    return PG_VOL


def gs_value(app: AppPtr, i: Int) -> Int:
    if app[].chip == 0:
        return app[].params[gs_slot(i)]
    var st = chip_of(app)
    if i == 0:
        return get(st, S_CUTOFF)
    if i == 1:
        return get(st, S_RES)
    return get(st, S_VOL)


def gs_set(app: AppPtr, i: Int, value: Int):
    var x = value
    if x < 0:
        x = 0
    if x > gs_max(i):
        x = gs_max(i)
    app[].params[gs_slot(i)] = x
    apply_params(app)


fn wave_bit(i: Int) -> Int:
    if i == 0: return WAVE_TRI
    if i == 1: return WAVE_SAW
    if i == 2: return WAVE_PULSE
    return WAVE_NOISE


fn wave_name(i: Int) -> String:
    if i == 0: return String("tri")
    if i == 1: return String("saw")
    if i == 2: return String("pulse")
    return String("noise")


fn fmode_bit(i: Int) -> Int:
    if i == 0: return FILT_LP
    if i == 1: return FILT_BP
    return FILT_HP


fn fmode_name(i: Int) -> String:
    if i == 0: return String("LP")
    if i == 1: return String("BP")
    return String("HP")


fn white_semi(i: Int) -> Int:
    if i == 0: return 0
    if i == 1: return 2
    if i == 2: return 4
    if i == 3: return 5
    if i == 4: return 7
    if i == 5: return 9
    if i == 6: return 11
    if i == 7: return 12
    if i == 8: return 14
    return 16


fn black_semi(i: Int) -> Int:
    if i == 0: return 1
    if i == 1: return 3
    if i == 2: return 6
    if i == 3: return 8
    if i == 4: return 10
    if i == 5: return 13
    return 15


fn white_letter(i: Int) -> String:
    var row = String("ASDFGHJKL;")
    return String(row[byte = i : i + 1])


fn black_letter(i: Int) -> String:
    var row = String("WETYUOP")
    return String(row[byte = i : i + 1])


# ── The screen ──────────────────────────────────────────────────────────────


def draw_button(
    hdc: Int, app: AppPtr, b: Box, label: String, on: Bool, enabled: Bool
) raises:
    fill_box(hdc, b, FACE_ON if on else FACE)
    draw_text(
        hdc, label, b.x + 8, b.y + 3, app[].font_small,
        INK if enabled else DEAD,
    )


def draw_bar(hdc: Int, app: AppPtr, v: Int, k: Int) raises:
    """A vertical bar, the way a synth shows an envelope."""
    var b = bar_box(v, k)
    var val = bar_value(app, v, k)
    fill_box(hdc, b, WELL)
    var frac = Float64(val) / Float64(bar_max(k))
    if frac > 1.0:
        frac = 1.0
    var lit = Int(Float64(BAR_H) * frac)
    if lit > 0:
        # Filled from the BOTTOM: the top of the lit part is the top of the
        # box plus what is missing, which is the one place this port has to
        # think about the flip at all.
        fill_box(hdc, Box(b.x, b.y + BAR_H - lit, BAR_W, lit), ACCENT)
    draw_text(hdc, bar_label(k), b.x + 8, b.y + BAR_H + 3, app[].font_small, DIM)
    draw_text(hdc, String(val), b.x - 2, b.y + BAR_H + 17, app[].font_small, INK)


def draw_gslider(hdc: Int, app: AppPtr, i: Int) raises:
    var b = gslider_box(i)
    var val = gs_value(app, i)
    fill_box(hdc, b, WELL)
    var frac = Float64(val) / Float64(gs_max(i))
    if frac > 1.0:
        frac = 1.0
    var lit = Int(Float64(GS_W) * frac)
    if lit > 0:
        fill_box(hdc, Box(b.x, b.y, lit, GS_H), ACCENT)
    draw_text(hdc, gs_label(i), b.x + GS_W + 10, b.y + 1, app[].font_small, DIM)
    draw_text(hdc, String(val), b.x + GS_W + 96, b.y + 1, app[].font_small, INK)


def draw_keyboard(hdc: Int, app: AppPtr) raises:
    var base = app[].octave * 12 + 12
    var sounding = List[Int]()
    for v in range(3):
        sounding.append(app[].held[v])

    for i in range(10):
        var b = white_box(i)
        var midi = base + white_semi(i)
        var lit = False
        for k in range(len(sounding)):
            if sounding[k] == midi:
                lit = True
        fill_box(hdc, b, ACCENT if lit else rgb(226, 230, 238))
        # Below the black keys, not above them. The black keys are drawn on
        # top and are BLACK_H tall, so a label near the top of a white key is
        # painted over on every white key that has a black one beside it --
        # which is seven of the ten.
        draw_text(
            hdc, white_letter(i), b.x + WHITE_W // 2 - 6, b.y + BLACK_H + 14,
            app[].font_small, rgb(70, 78, 92),
        )
        if white_semi(i) % 12 == 0:
            draw_text(
                hdc, note_name(midi), b.x + 6, b.y + WHITE_H - 20,
                app[].font_small, rgb(150, 158, 176),
            )

    for i in range(7):
        var b = black_box(i)
        var midi = base + black_semi(i)
        var lit = False
        for k in range(len(sounding)):
            if sounding[k] == midi:
                lit = True
        fill_box(hdc, b, rgb(90, 170, 125) if lit else rgb(24, 27, 34))
        draw_text(
            hdc, black_letter(i), b.x + BLACK_W // 2 - 4, b.y + BLACK_H - 22,
            app[].font_small, rgb(190, 198, 212),
        )


def draw_scope(hdc: Int, app: AppPtr) raises:
    var sb = Box(PANEL_X, SCOPE_TOP, PANEL_W, SCOPE_H)
    fill_box(hdc, sb, SCOPE_BG)
    var mid = sb.y + SCOPE_H // 2
    fill_box(hdc, Box(sb.x, mid, PANEL_W, 1), rgb(38, 44, 54))
    if app[].backend == BACKEND_MIDI:
        # There is nothing to draw and saying so is better than a flat line
        # that looks like a bug: the synthesiser is in another process and
        # its samples never pass through this program.
        draw_text(
            hdc, String("no scope in --midi: the synthesiser's samples are"
                        " never in our buffer"),
            sb.x + 12, mid - 8, app[].font_small, rgb(70, 78, 92),
        )
        return
    if app[].scope == 0:
        return
    var scope = Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=app[].scope
    )
    var points = PANEL_W // 2
    for i in range(points):
        var s = Float64(scope[unsafe_offset = (i * SCOPE_LEN) // points])
        var h = Int(s * Float64(SCOPE_H // 2 - 4))
        var top = mid
        var height = h
        if h < 0:
            top = mid + h
            height = -h
        if height < 2:
            height = 2
        fill_box(hdc, Box(sb.x + i * 2, top, 2, height), ACCENT)


def draw_screen(hdc: Int, app: AppPtr) raises:
    fill_box(hdc, Box(0, 0, WIN_W, WIN_H), BACKDROP)

    # ── Header ──────────────────────────────────────────────────────────
    draw_text(hdc, app[].title, 22, 18, app[].font_title, INK)
    draw_text(hdc, app[].subtitle, 22, 44, app[].font_small, DIM)
    var mode_txt = String("LIVE - the keyboard plays")
    if app[].backend == BACKEND_MIDI:
        mode_txt = String("MIDI - the system synthesiser")
    if app[].mode != MODE_LIVE:
        mode_txt = String("PLAYING a tune")
        if app[].paused != 0:
            mode_txt = String("PAUSED")
    draw_text(
        hdc, mode_txt, PANEL_X + PANEL_W - 250, 18, app[].font_small, ACCENT
    )

    # ── Tunes ───────────────────────────────────────────────────────────
    draw_text(hdc, String("TUNES"), LIST_X, LIST_TOP - 18, app[].font_small, DIM)
    for i in range(ROWS):
        if i >= len(app[].names):
            break
        var b = row_box(i)
        if i == app[].sel:
            fill_box(hdc, b, FACE_ON)
        var mark = String("  ")
        if i == app[].loaded and app[].mode == MODE_TUNE:
            mark = String("> ")
        draw_text(
            hdc, mark + app[].names[i], b.x + 6, b.y + 3, app[].font_small,
            INK if i == app[].sel else DIM,
        )
    if len(app[].names) == 0:
        draw_text(
            hdc, String("  no .abc files beside the program"),
            LIST_X + 6, row_box(0).y + 3, app[].font_small, DIM,
        )

    draw_button(hdc, app, btn_box(0), String("Add"), False, True)
    draw_button(
        hdc, app, btn_box(1), String("Play"), app[].mode == MODE_TUNE,
        app[].sel >= 0,
    )
    draw_button(
        hdc, app, btn_box(2), String("Stop"), False, app[].mode == MODE_TUNE
    )
    draw_button(hdc, app, btn_box(3), String("Quit"), False, True)

    # ── Scope, and where the tune has got to ────────────────────────────
    draw_scope(hdc, app)
    if app[].mode == MODE_TUNE:
        var line = (
            format_time(app[].pos_samples)
            + String(" / ")
            + format_time(app[].end_samples)
        )
        if app[].paused != 0:
            line += String("   [paused]")
        if app[].starved > 0:
            # Never hidden. An underrun is silent everywhere else -- every
            # WASAPI call still returns S_OK through one -- so if the ring
            # was ever found empty, the window says so.
            line += String("   underruns: ") + String(app[].starved)
        draw_text(
            hdc, line, PANEL_X, SCOPE_TOP + SCOPE_H + 8, app[].font_small, INK
        )
        var bar = Box(PANEL_X + 220, SCOPE_TOP + SCOPE_H + 12, PANEL_W - 220, 8)
        fill_box(hdc, bar, rgb(34, 38, 48))
        if app[].end_samples > 0:
            var frac = Float64(app[].pos_samples) / Float64(app[].end_samples)
            if frac > 1.0:
                frac = 1.0
            var lit = Int(Float64(bar.w) * frac)
            if lit > 0:
                fill_box(hdc, Box(bar.x, bar.y, lit, 8), ACCENT)
    else:
        draw_text(
            hdc,
            String("octave ") + String(app[].octave)
            + String("    sustain ")
            + (String("on") if app[].sustain != 0 else String("off"))
            + String("    ") + app[].status,
            PANEL_X, SCOPE_TOP + SCOPE_H + 8, app[].font_small, DIM,
        )

    # ── Voice editor ────────────────────────────────────────────────────
    var st = chip_of(app)
    for v in range(3):
        var cx = vcol_x(v)
        var sounding = app[].held[v]
        if app[].mode == MODE_TUNE:
            sounding = get(st, PLAYER_BASE + SC_VOICE_NOTE + v)
        var head = String("VOICE ") + String(v + 1)
        if sounding >= 0:
            head += String("   ") + note_name(sounding)
        draw_text(
            hdc, head, cx + 6, EDIT_TOP, app[].font_small,
            INK if sounding >= 0 else DIM,
        )

        var wave_now = app[].params[v * PV_STRIDE + PV_WAVE]
        var filt_now = app[].params[v * PV_STRIDE + PV_FILT]
        if app[].chip != 0:
            wave_now = vget(st, v, V_WAVE)
            filt_now = vget(st, v, V_FILT)
        for i in range(4):
            draw_button(
                hdc, app, wave_box(v, i), wave_name(i),
                (wave_now & wave_bit(i)) != 0, True,
            )
        for k in range(5):
            draw_bar(hdc, app, v, k)
        draw_button(
            hdc, app, filt_box(v), String("through filter"), filt_now != 0, True
        )

    if app[].backend == BACKEND_MIDI:
        # Said once, next to the registers, rather than leaving a panel full
        # of live-looking controls to imply they are doing something.
        draw_text(
            hdc,
            String("the chip is not in the signal path in --midi:"
                   " these registers change nothing"),
            PANEL_X, EDIT_TOP + 198, app[].font_small, rgb(170, 120, 90),
        )
    draw_text(
        hdc, String("FILTER - all three voices"), FILT_X, GLOB_TOP,
        app[].font_small, DIM,
    )
    for i in range(3):
        draw_gslider(hdc, app, i)
    var fmode_now = app[].params[PG_FMODE]
    if app[].chip != 0:
        fmode_now = get(st, S_FMODE)
    for i in range(3):
        draw_button(
            hdc, app, fmode_box(i), fmode_name(i),
            (fmode_now & fmode_bit(i)) != 0, True,
        )

    # ── Keyboard ────────────────────────────────────────────────────────
    draw_keyboard(hdc, app)
    draw_text(
        hdc,
        String("Z X octave  .  C V level  .  TAB sustain  .  "
               "SPACE play/pause  .  Q quit"),
        KEYS_X, KEYS_TOP + WHITE_H + 8, app[].font_small, DIM,
    )


# ── Hit testing ─────────────────────────────────────────────────────────────


def click(app: AppPtr, x: Int, y: Int) raises:
    """One mouse-down, in client coordinates."""
    for i in range(BUTTONS):
        if btn_box(i).holds(x, y):
            if i == 0:
                app[].cmd = app[].cmd | CMD_ADD
            elif i == 1:
                app[].cmd = app[].cmd | CMD_PLAY
            elif i == 2:
                app[].cmd = app[].cmd | CMD_STOP
            else:
                app[].cmd = app[].cmd | CMD_QUIT
            return

    for i in range(ROWS):
        if i >= len(app[].names):
            break
        if row_box(i).holds(x, y):
            app[].sel = i
            return

    for v in range(3):
        var b = v * PV_STRIDE
        for i in range(4):
            if wave_box(v, i).holds(x, y):
                # The chip ANDs selected waveforms together, so these are
                # toggles rather than a radio group -- and clearing the last
                # one leaves silence, which is what the register means.
                app[].params[b + PV_WAVE] = app[].params[b + PV_WAVE] ^ wave_bit(i)
                apply_params(app)
                return
        if filt_box(v).holds(x, y):
            app[].params[b + PV_FILT] = 0 if app[].params[b + PV_FILT] != 0 else 1
            apply_params(app)
            return
        for k in range(5):
            if bar_box(v, k).holds(x, y):
                app[].drag = v * 5 + k
                drag(app, x, y)
                return

    for i in range(3):
        if fmode_box(i).holds(x, y):
            app[].params[PG_FMODE] = app[].params[PG_FMODE] ^ fmode_bit(i)
            apply_params(app)
            return

    for i in range(3):
        if gslider_box(i).holds(x, y):
            app[].drag = 15 + i
            drag(app, x, y)
            return

    # The drawn keys play too, so a mouse can find a note the letters hide.
    # Black first: they are drawn over the white ones and must be hit first.
    if app[].mode == MODE_LIVE:
        var base = app[].octave * 12 + 12
        for i in range(7):
            if black_box(i).holds(x, y):
                note_on(app, base + black_semi(i))
                return
        for i in range(10):
            if white_box(i).holds(x, y):
                note_on(app, base + white_semi(i))
                return


def drag(app: AppPtr, x: Int, y: Int) raises:
    """Bars fill upwards, so a bar reads y and a horizontal slider reads x."""
    var id = app[].drag
    if id < 0:
        return
    if id >= 15:
        var i = id - 15
        var b = gslider_box(i)
        var fx = Float64(x - b.x) / Float64(b.w)
        if fx < 0.0:
            fx = 0.0
        if fx > 1.0:
            fx = 1.0
        gs_set(app, i, Int(fx * Float64(gs_max(i)) + 0.5))
        return
    var v = id // 5
    var k = id % 5
    var b2 = bar_box(v, k)
    # Upwards: the bottom of the box is zero.
    var fy = Float64(b2.y + b2.h - y) / Float64(b2.h)
    if fy < 0.0:
        fy = 0.0
    if fy > 1.0:
        fy = 1.0
    bar_set(app, v, k, Int(fy * Float64(bar_max(k)) + 0.5))


def release(app: AppPtr) raises:
    app[].drag = -1
    # A note started with the mouse ends when the mouse does.
    if app[].mode == MODE_LIVE and app[].sustain == 0:
        all_notes_off(app)
