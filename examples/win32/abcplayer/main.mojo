# ===----------------------------------------------------------------------=== #
# An ABC player, in Mojo, with two ways to make the sound.
#
#   --chip    three chip voices: pulse, saw, noise, filter (the fun one)
#   --midi    Windows' own synthesiser, General MIDI (the dull, correct one)
#   --write=  a Standard MIDI File, and no playing at all
#
# Both backends read one schedule. That is the point of the design: the tune
# is compiled to a list of "at this moment, do this", and the only thing a
# backend decides is what "this" means and who owns the clock. Nothing about
# the music -- the parse, the repeats, the ties, the ordering, the tie-break
# that puts a note-off before a note-on at the same instant -- is written
# twice, so nothing about it can differ between them.
#
# The Windows underneath this is `std.windows`, not a private copy of it.
# `std.windows.audio` opens the render stream and owns the ring; `RenderStream`
# is the whole eight-step WASAPI open, and `abc_fill` below is this program's
# only contribution to the audio deadline. `std.windows.gui` registers the
# window class, and `std.windows.core` converts every string that crosses into
# UTF-16. What is left in this directory is the ABC player: the parser, the
# schedule, the chip, the MIDI stream and the panel.
#
# What the port had to change, and why, in one place:
#
#   * CoreAudio calls a render callback on a thread it owns. WASAPI hands you
#     a ring buffer and an event and expects you to be the thread. That is
#     `RenderStream.write`, in the stdlib now; what survives here is the
#     callback itself, as a `RenderFill` -- and `render_scheduled`, which is
#     the callback, did not change at all.
#   * `MusicDeviceMIDIEvent` takes a sample offset into the buffer being
#     rendered, so the Mac's MIDI backend gets sample-exact timing out of the
#     same callback. Windows' synthesiser is a device, not a unit we can pull
#     into our buffer, and there is no offset to give. `midiStreamOut` is the
#     Windows shape of the same idea: hand over the whole tick-stamped list
#     and let the driver's clock place it. That is why a `Step` carries its
#     tick as well as its sample.
#   * The window is one thread with one loop. `MsgWaitForMultipleObjects`
#     waits on the audio event and the message queue at once, so there is no
#     audio thread, no lock, and no cross-thread anything.
#
#   abcplayer.exe                        the window, live keyboard
#   abcplayer.exe tunes/carolan.abc      the window, playing that tune
#   abcplayer.exe tunes/ode.abc --midi   the same through the system synth
#   abcplayer.exe t.abc --write=out.mid  a Standard MIDI File, no window
#   abcplayer.exe t.abc --selftest       no window: check the pitches, measure
#                                        the timing, play, and prove it was
#                                        heard by reading the endpoint's own
#                                        peak meter
#   abcplayer.exe t.abc --selftest --seconds N   as above, for N seconds
#   abcplayer.exe --ms N                 open the window and close it after N
#                                        milliseconds, for an unattended run
#
#   SPACE play/pause   Q or ESC quit   click a tune, then Play
#   the letter keys play, in Logic Pro's Musical Typing layout
# ===----------------------------------------------------------------------=== #

from std.collections.optional import Optional
from std.ffi import c_int
from std.memory import Pointer, MutUntrackedOrigin, OpaquePointer
from std.memory.alloc import unsafe_alloc
from std.python._cpython import _fn_ptr_as_opaque
from std.sys import argv
from std.sys._com import ComPtr, com_addr
from std.sys._winkb import (
    winkb_constant,
    winkb_db_schema_version,
    winkb_field_offset,
    winkb_struct_size,
)
from std.sys.com import Apartment, Com, co_create
from std.sys.info import size_of
from std.windows import performance_counter, performance_frequency
from std.windows.audio import (
    RenderFill, RenderStream, default_render_meter,
)
from std.windows.core import WideString, from_wide, win32
from std.windows.gui import (
    MSG,
    RECT,
    WNDCLASSEXW,
    WindowClass,
    WndProc,
    default_handler,
    quit,
)

from chip import (
    P, chip_new, chip_free, get, put, route_filter, set_adsr, set_volume,
    set_wave, PLAYER_BASE, SAMPLE_RATE, WAVE_PULSE,
)
from chipplay import (
    flatten_schedule, render_scheduled,
    SC_ADDR, SC_COUNT, SC_CURSOR, SC_SAMPLE, SC_END, SC_LOOP, SC_PAUSE,
    SC_DONE, SC_VOICE_NOTE, STEP_SLOTS,
)
from model import Tune, EV_NOTE
from parse import parse_abc
from repeats import expand_repeats
from schedule import (
    Step, SE_NOTE_ON, build_schedule, resolve_ties, ticks_per_beat,
    tick_to_sample,
)
from smf import write_midi
from ui import (
    App, AppPtr, Box, WIN_W, WIN_H, SCOPE_LEN,
    BACKEND_CHIP, BACKEND_MIDI, MODE_LIVE, MODE_TUNE,
    CMD_QUIT, CMD_PLAY, CMD_STOP, CMD_PAUSE, CMD_ADD,
    ui_init, apply_params, all_notes_off, draw_screen, click, drag, release,
    key_down, key_up, make_font, semitone_for,
)
import wasapi
from win32 import check_layouts
import winmidi


# The ring the fill loop asks WASAPI for. Big enough that a tune being parsed
# on this same thread -- which takes a millisecond or two -- cannot starve the
# speaker, and small enough that pressing pause is not heard a moment later.
comptime BUFFER_MS = 120


# ===----------------------------------------------------------------------===#
# Tunes on disk
# ===----------------------------------------------------------------------===#


def basename(path: String) -> String:
    """The last component, under either separator.

    Windows takes both, and a path typed at a Git Bash prompt has forward
    slashes while one produced by the directory scan has backslashes -- so a
    player that split on only one of them would list the same file twice.
    """
    var b = path.as_bytes()
    var cut = -1
    for i in range(len(b)):
        if b[i] == UInt8(92) or b[i] == UInt8(47):
            cut = i
    if cut < 0:
        return path
    return String(path[byte = cut + 1 : len(b)])


def add_tune(app: AppPtr, path: String):
    var name = basename(path)
    for i in range(len(app[].paths)):
        # By NAME, not by path: `tunes/ode.abc` from the command line and the
        # absolute path the directory scan produces are the same file spelled
        # two ways, and listing it twice is confusing rather than harmless.
        if app[].paths[i] == path or basename(app[].paths[i]) == name:
            return
    app[].paths.append(path)
    app[].names.append(name)
    if app[].sel < 0:
        app[].sel = len(app[].names) - 1


def tune_index(app: AppPtr, name: String) -> Int:
    for i in range(len(app[].paths)):
        if basename(app[].paths[i]) == name:
            return i
    return -1


def scan_tunes(app: AppPtr, folder: String) raises:
    """Whatever is in a tunes/ folder, so the list is never empty.

    FindFirstFileW and FindNextFileW, with WIN32_FIND_DATAW never declared,
    only sized -- the one field this needs is the file name, at the offset the
    metadata records.
    """
    var FindFirstFileW = win32[
        def (
            Pointer[UInt16, MutAnyOrigin], Pointer[UInt8, MutAnyOrigin]
        ) thin abi("C") -> Int,
        "FindFirstFileW",
    ]()
    var FindNextFileW = win32[
        def (
            Int, Pointer[UInt8, MutAnyOrigin]
        ) thin abi("C") -> c_int,
        "FindNextFileW",
    ]()
    var FindClose = win32[def (Int) thin abi("C") -> c_int, "FindClose"]()

    var pattern = WideString(folder + String("\\*.abc"))
    var data = List[UInt8](
        length=winkb_struct_size["WIN32_FIND_DATAW"](), fill=0
    )
    var at = data.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    var handle = FindFirstFileW(pattern.unsafe_ptr(), at)
    _ = pattern
    if handle == 0 or handle == -1:
        return
    # cFileName is 260 UTF-16 units at the offset the metadata records, and
    # `from_wide` is what turns them back into a Mojo string. A folk tune
    # called `bourrée.abc` is not an edge case, and neither is one whose name
    # a Windows user typed with an emoji in it -- both are one code unit per
    # character exactly never.
    var name_at = winkb_field_offset["WIN32_FIND_DATAW", "cFileName"]()
    var name_ptr = Pointer[UInt16, MutAnyOrigin](
        unsafe_from_address=Int(at) + name_at
    )
    while True:
        var name = from_wide(name_ptr)
        if len(name.as_bytes()) > 0:
            add_tune(app, folder + String("\\") + name)
        if FindNextFileW(handle, at) == c_int(0):
            break
    _ = FindClose(handle)
    _ = data


# ===----------------------------------------------------------------------===#
# Loading a tune into whichever backend is running
# ===----------------------------------------------------------------------===#


def go_live(app: AppPtr, mut midi: winmidi.MidiOut) raises:
    """No schedule, so nothing drives the voices but the keyboard.

    SC_ADDR must stay non-zero -- render_scheduled fills silence when it is
    null -- and SC_END goes far away so the round-at-the-end never fires and
    gates the live notes off underneath you.
    """
    var st = P(unsafe_from_address=app[].chip)
    put(st, PLAYER_BASE + SC_PAUSE, 1)
    all_notes_off(app)
    put(st, PLAYER_BASE + SC_COUNT, 0)
    put(st, PLAYER_BASE + SC_CURSOR, 0)
    put(st, PLAYER_BASE + SC_SAMPLE, 0)
    put(st, PLAYER_BASE + SC_LOOP, 0)
    put(st, PLAYER_BASE + SC_END, 1 << 60)
    put(st, PLAYER_BASE + SC_DONE, 0)
    for v in range(3):
        put(st, PLAYER_BASE + SC_VOICE_NOTE + v, -1)
    if app[].backend == BACKEND_MIDI:
        winmidi.stop(midi)
    app[].mode = MODE_LIVE
    app[].loaded = -1
    app[].paused = 0
    app[].pos_samples = 0
    apply_params(app)
    put(st, PLAYER_BASE + SC_PAUSE, 0)


def play_tune(app: AppPtr, index: Int, mut midi: winmidi.MidiOut) raises:
    """Parse, schedule and hand it to whichever backend is running.

    The chip backend is paused across the swap: the fill loop writes silence
    while SC_PAUSE is set and never looks at SC_ADDR, which is the whole
    handoff. Nothing else is needed, because nothing else is shared.
    """
    if index < 0 or index >= len(app[].paths):
        return
    var path = app[].paths[index]
    var text = String("")
    try:
        with open(path, "r") as f:
            text = f.read()
    except:
        app[].status = String("could not read ") + basename(path)
        return

    var tune = Tune()
    parse_abc(text, tune)
    expand_repeats(tune)
    resolve_ties(tune)

    var notes = 0
    for i in range(len(tune.events)):
        if tune.events[i].kind == EV_NOTE and tune.events[i].velocity > 0:
            notes += 1

    var steps = List[Step]()
    build_schedule(tune, SAMPLE_RATE, steps)
    if len(steps) == 0:
        app[].status = String("nothing to play in ") + basename(path)
        return

    var st = P(unsafe_from_address=app[].chip)
    put(st, PLAYER_BASE + SC_PAUSE, 1)
    all_notes_off(app)
    for v in range(3):
        put(st, PLAYER_BASE + SC_VOICE_NOTE + v, -1)

    var last = 0
    for i in range(len(steps)):
        if steps[i].sample > last:
            last = steps[i].sample
    app[].end_samples = last + SAMPLE_RATE

    if app[].backend == BACKEND_MIDI:
        var queued = winmidi.load(midi, steps, tune)
        app[].end_ticks = midi.total_ticks
        var per_beat = ticks_per_beat(tune)
        var bpm = tune.tempo_bpm if tune.tempo_bpm > 0 else 120
        app[].end_samples = tick_to_sample(
            midi.total_ticks, bpm, per_beat, SAMPLE_RATE
        )
        app[].status = String(queued) + String(" events queued")
    else:
        # The previous schedule was ours and nothing else points at it.
        var old = get(st, PLAYER_BASE + SC_ADDR)
        if old != 0:
            Pointer[Int, MutUntrackedOrigin](
                unsafe_from_address=old
            ).unsafe_free()
        put(st, PLAYER_BASE + SC_ADDR, 0)
        _ = flatten_schedule(steps, st)
        put(st, PLAYER_BASE + SC_LOOP, 1)
        put(st, PLAYER_BASE + SC_DONE, 0)
        app[].status = String("playing")

    var sub = String("")
    if len(tune.composer.as_bytes()) > 0:
        sub += tune.composer + String("   -   ")
    sub += String(len(tune.voices)) + String(" voices   -   ")
    sub += String(notes) + String(" notes   -   ")
    sub += String(tune.tempo_bpm) + String(" bpm")
    app[].title = (
        tune.title if len(tune.title.as_bytes()) > 0 else basename(path)
    )
    app[].subtitle = sub^
    app[].mode = MODE_TUNE
    app[].loaded = index
    app[].paused = 0
    app[].starved = 0
    put(st, PLAYER_BASE + SC_PAUSE, 0)


# ===----------------------------------------------------------------------===#
# The render callback
#
# This is the whole of what this program puts on the audio deadline, and it is
# all that is left of a fill loop that used to be sixty lines. `RenderStream`
# asks how much of the ring has drained, claims exactly that, calls this for
# that many mono samples, fans them out into the engine's format and releases
# -- so what remains here is the part that is about music.
#
# `RenderFill` is declared without `raises` and the compiler holds this to it:
# nothing below can allocate, lock, do I/O or throw. The App pointer arrives
# through `user`, which is the audio side's GWLP_USERDATA -- a C function
# pointer is captureless and has nowhere else to keep anything.
# ===----------------------------------------------------------------------===#


@export("abc_fill")
def abc_fill(
    user: OpaquePointer[MutUntrackedOrigin],
    dest: Pointer[Float32, MutUntrackedOrigin],
    frames: Int,
) abi("C") -> NoneType:
    var app = AppPtr(unsafe_from_address=Int(user))
    var st = P(unsafe_from_address=app[].chip)
    if app[].paused != 0 or app[].backend == BACKEND_MIDI:
        for i in range(frames):
            dest[unsafe_offset=i] = Float32(0.0)
    else:
        render_scheduled(st, dest, frames)
        # The loudest thing this program produced, which is a different claim
        # from the endpoint's meter: that one hears the whole machine, so a
        # run that made no sound at all can still meter whatever else is
        # playing. Both numbers together are the honest evidence.
        var peak = app[].out_peak
        for i in range(frames):
            var v = Float64(dest[unsafe_offset=i])
            if v < 0.0:
                v = -v
            if v > peak:
                peak = v
        app[].out_peak = peak

    # A copy for the scope. Unsynchronised on purpose, and here there is not
    # even another thread to be unsynchronised with -- the window is painted
    # from the same loop, so the worst case is a sweep drawn one wake stale.
    if app[].scope != 0:
        var scope = Pointer[Float32, MutUntrackedOrigin](
            unsafe_from_address=app[].scope
        )
        var pos = app[].scope_pos
        for i in range(frames):
            scope[unsafe_offset=pos] = dest[unsafe_offset=i]
            pos += 1
            if pos >= SCOPE_LEN:
                pos = 0
        app[].scope_pos = pos
    return None


# ===----------------------------------------------------------------------===#
# The window procedure. Windows calls this, so it is a captureless C-ABI
# function that must never raise -- unwinding through a Windows frame is
# undefined -- and every failure is caught here.
# ===----------------------------------------------------------------------===#


def stored_app(hwnd: Int) raises -> Int:
    var GetWindowLongPtrW = win32[
        def (Int, c_int) thin abi("C") -> Int, "GetWindowLongPtrW"
    ]()
    return GetWindowLongPtrW(hwnd, c_int(winkb_constant["GWLP_USERDATA"]()))


def signed16(v: Int) -> Int:
    """One half of a packed mouse point, sign-extended.

    `lParam` packs a point as two 16-bit halves, and they are SIGNED: a drag
    that leaves the window to the left reports a negative x, which read
    unsigned becomes 65,000-odd and lands on nothing.
    """
    var x = v & 0xFFFF
    if x >= 0x8000:
        x -= 0x10000
    return x


def paint(app: AppPtr, hwnd: Int) raises:
    """WM_PAINT, through a back buffer.

    The panel is about ninety filled rectangles and sixty runs of text. Drawn
    straight into the window's device context that is ninety visible steps;
    into a bitmap and blitted once, it is one. The buffer is made on the first
    paint and kept, because the window cannot be resized.
    """
    var BeginPaint = win32[
        def (Int, Pointer[UInt8, MutAnyOrigin]) thin abi("C") -> Int,
        "BeginPaint",
    ]()
    var EndPaint = win32[
        def (Int, Pointer[UInt8, MutAnyOrigin]) thin abi("C") -> c_int,
        "EndPaint",
    ]()
    var CreateCompatibleDC = win32[
        def (Int) thin abi("C") -> Int, "CreateCompatibleDC"
    ]()
    var CreateCompatibleBitmap = win32[
        def (Int, c_int, c_int) thin abi("C") -> Int, "CreateCompatibleBitmap"
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

    # PAINTSTRUCT is never declared here, only sized, from the metadata -- it
    # is a box this code never looks inside.
    var ps = List[UInt8](length=winkb_struct_size["PAINTSTRUCT"](), fill=0)
    var ps_ptr = ps.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    var hdc = BeginPaint(hwnd, ps_ptr)
    if hdc != 0:
        if app[].memdc == 0:
            app[].memdc = CreateCompatibleDC(hdc)
            app[].membmp = CreateCompatibleBitmap(hdc, c_int(WIN_W), c_int(WIN_H))
            _ = SelectObject(app[].memdc, app[].membmp)
        draw_screen(app[].memdc, app)
        _ = BitBlt(
            hdc, c_int(0), c_int(0), c_int(WIN_W), c_int(WIN_H),
            app[].memdc, c_int(0), c_int(0),
            UInt32(winkb_constant["SRCCOPY"]()),
        )
    # BeginPaint cleared the update region; EndPaint closes it. Skip either
    # and Windows re-sends WM_PAINT immediately, forever.
    _ = EndPaint(hwnd, ps_ptr)
    _ = ps


@export("abc_wndproc")
def abc_wndproc(
    hwnd: Int, message: UInt32, wparam: Int, lparam: Int
) abi("C") -> Int:
    try:
        # Refuse the background erase: the whole client area is redrawn every
        # paint, and letting GDI clear it first is what makes it flicker.
        if message == UInt32(winkb_constant["WM_ERASEBKGND"]()):
            return 1

        var stored = stored_app(hwnd)
        if stored == 0:
            # Messages arrive during CreateWindowExW, before there is anything
            # to point at.
            return default_handler(hwnd, message, wparam, lparam)
        var app = AppPtr(unsafe_from_address=stored)

        if message == UInt32(winkb_constant["WM_PAINT"]()):
            paint(app, hwnd)
            return 0

        if message == UInt32(winkb_constant["WM_LBUTTONDOWN"]()):
            var SetCapture = win32[def (Int) thin abi("C") -> Int, "SetCapture"]()
            var SetFocus = win32[def (Int) thin abi("C") -> Int, "SetFocus"]()
            # Capture, so a drag that leaves the window keeps moving the
            # slider rather than stopping at the frame.
            _ = SetCapture(hwnd)
            # Without this the keyboard messages go somewhere else.
            _ = SetFocus(hwnd)
            click(app, signed16(lparam), signed16(lparam >> 16))
            return 0

        if message == UInt32(winkb_constant["WM_MOUSEMOVE"]()):
            if (wparam & winkb_constant["MK_LBUTTON"]()) != 0:
                drag(app, signed16(lparam), signed16(lparam >> 16))
            return 0

        if message == UInt32(winkb_constant["WM_LBUTTONUP"]()):
            var ReleaseCapture = win32[
                def () thin abi("C") -> c_int, "ReleaseCapture"
            ]()
            _ = ReleaseCapture()
            release(app)
            return 0

        # Typed characters arrive as WM_CHAR, which TranslateMessage produces:
        # Windows has already applied the keyboard layout by then, so what
        # turns up is the character the person meant -- including tab as 9 and
        # escape as 27, which is why neither needs a virtual-key case.
        if message == UInt32(winkb_constant["WM_CHAR"]()):
            # lParam bit 30 is the previous key state: set means this is the
            # auto-repeat, and a repeated note-on would re-strike the envelope
            # thirty times a second.
            key_down(app, wparam & 0xFFFF, (lparam & 0x40000000) != 0)
            return 0

        if message == UInt32(winkb_constant["WM_KEYUP"]()):
            # There is no WM_CHAR for a key going up, so the virtual-key code
            # is translated here. A-Z arrive as their capitals whatever the
            # shift state, and the semicolon is OEM_1 on this layout.
            var vk = wparam & 0xFF
            var c = vk
            if vk >= 65 and vk <= 90:
                c = vk + 32
            elif vk == winkb_constant["VK_OEM_1"]():
                c = 59
            key_up(app, c)
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
            # PostQuitMessage.
            quit(0)
            return 0

        return default_handler(hwnd, message, wparam, lparam)
    except:
        return 0


# ===----------------------------------------------------------------------===#
# Evidence
#
# A call that returned S_OK is not evidence that a sound was made -- in shared
# mode every call returns S_OK straight through an underrun. So --selftest
# asks the endpoint's own peak meter, which belongs to the device and knows
# nothing about this program, and fails if it never moved.
# ===----------------------------------------------------------------------===#


def pitch_check() raises -> Int:
    """The two things the Mac port had to fix, checked rather than believed.

    The C++ this descends from had key signatures that did nothing and
    accidental parsing that could never run, so every tune played in C major.
    Both are cheap to check and neither needs a sound card: `K:D` sharpens F
    and C, `^G` sharpens a G that the key does not touch, and a natural sign
    holds for the rest of ITS BAR and no longer.

    Expected, as MIDI note numbers:  F#5 F#5 G#5 A5 | F5 F5 | F#5
                                     66  66  68  69 | 65 65 | 66
    """
    var text = String(
        "X:1\nT:pitch\nM:4/4\nL:1/8\nQ:1/4=120\nK:D\n"
        "FF ^GA | =F2 F2 | F4 |\n"
    )
    var tune = Tune()
    parse_abc(text, tune)
    expand_repeats(tune)
    resolve_ties(tune)

    var want = List[Int]()
    want.append(66)     # F, sharpened by K:D
    want.append(66)
    want.append(68)     # ^G, an accidental the key does not supply
    want.append(69)     # A, untouched by K:D
    want.append(65)     # =F, natural
    want.append(65)     # F again, still natural: the accidental holds
    want.append(66)     # F in the NEXT bar: the key signature again

    var got = List[Int]()
    for i in range(len(tune.events)):
        if tune.events[i].kind == EV_NOTE and tune.events[i].velocity > 0:
            got.append(tune.events[i].midi)

    var line = String("  pitches:")
    for i in range(len(got)):
        line += String(" ") + String(got[i])
    print(line)
    if len(got) != len(want):
        print("  FAIL: expected", len(want), "notes, parsed", len(got))
        return 1
    for i in range(len(want)):
        if got[i] != want[i]:
            print(
                "  FAIL: note", i, "is", got[i], "and should be", want[i]
            )
            return 1
    print("  key signature, accidentals and the bar reset: ok")
    return 0


def timing_check() raises -> Int:
    """Does an event land on the sample it was written for?

    This is the claim the whole design exists to make, so it is measured
    rather than asserted. Four quarter notes at 120bpm are rendered offline
    through the same `render_scheduled` the speaker uses, in 512-frame blocks
    -- a size chosen because it does NOT divide the note length, so every
    onset after the first falls somewhere in the middle of a block. The onset
    is then found in the output signal, not in the scheduler's own bookkeeping:
    the envelope is exactly zero between notes and non-zero from the first
    sample of one, so the first non-zero sample IS the onset, with no
    threshold to argue about.
    """
    var text = String(
        "X:1\nT:metronome\nM:4/4\nL:1/4\nQ:1/4=120\nK:C\nCCCC|\n"
    )
    var tune = Tune()
    parse_abc(text, tune)
    expand_repeats(tune)
    resolve_ties(tune)
    var steps = List[Step]()
    build_schedule(tune, SAMPLE_RATE, steps)

    var st = chip_new()
    set_wave(st, 0, WAVE_PULSE)
    # Fastest attack, full sustain, fastest release: a square edge at both
    # ends, so the onset is where the envelope leaves zero and nowhere else.
    set_adsr(st, 0, 0, 9, 15, 0)
    route_filter(st, 0, False)
    set_volume(st, 15)
    _ = flatten_schedule(steps, st)
    put(st, PLAYER_BASE + SC_LOOP, 0)

    var expected = List[Int]()
    for i in range(len(steps)):
        if steps[i].kind == SE_NOTE_ON:
            expected.append(steps[i].sample)

    comptime BLOCK = 512
    var scratch = unsafe_alloc[Float32](BLOCK, alignment=64)
    var buf = Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=Int(scratch)
    )
    var measured = List[Int]()
    var quiet = True
    var at = 0
    var limit = expected[len(expected) - 1] + SAMPLE_RATE
    while at < limit and len(measured) < len(expected):
        render_scheduled(st, buf, BLOCK)
        for i in range(BLOCK):
            var v = buf[unsafe_offset=i]
            if v == Float32(0.0):
                quiet = True
            elif quiet:
                measured.append(at + i)
                quiet = False
        at += BLOCK
    scratch.unsafe_free()
    chip_free(st)

    var worst = 0
    var line_a = String("  scheduled")
    var line_b = String("  measured ")
    for i in range(len(expected)):
        line_a += String("  ") + String(expected[i])
        if i < len(measured):
            line_b += String("  ") + String(measured[i])
            var d = measured[i] - expected[i]
            if d < 0:
                d = -d
            if d > worst:
                worst = d
        else:
            line_b += String("  --")
    print("  blocks of", BLOCK, "frames, which does not divide the note")
    print(line_a)
    print(line_b)
    print(
        "  worst error", worst, "samples =",
        Float64(worst) * 1000.0 / Float64(SAMPLE_RATE), "ms",
    )
    if len(measured) != len(expected):
        print("  FAIL: found", len(measured), "onsets, expected", len(expected))
        return 1
    if worst > 1:
        print("  FAIL: an event landed more than one sample from its place")
        return 1
    return 0


# ===----------------------------------------------------------------------===#
# Add...
# ===----------------------------------------------------------------------===#


@fieldwise_init
struct FilterSpec(Defaultable, Copyable, Movable):
    """COMDLG_FILTERSPEC: two wide strings, a label and a pattern."""

    var pszName: Int
    var pszSpec: Int

    def __init__(out self):
        self.pszName = 0
        self.pszSpec = 0


# The metadata carries this coclass by name but not its value -- every
# guid-kind row in the database has a NULL value -- so, exactly as with the
# device enumerator in wasapi.mojo, it is spelled once here and nowhere else.
comptime CLSID_FileOpenDialog = StaticString(
    "dc1c5a9c-e88a-4dde-a5a1-60f82a20aef7"
)


def open_panel(
    app: AppPtr,
    mut speaker: Optional[RenderStream],
    user: OpaquePointer[MutUntrackedOrigin],
) raises:
    """The common file dialog, for a tune that is not in `tunes/`.

    The stream is STOPPED first and restarted after, and that is not tidiness.
    `IModalWindow::Show` runs its own message loop and does not return until
    the user is finished, so for as long as the dialog is open this program's
    fill loop is not running. A ring nobody is filling is not silence: it is a
    starved stream, which repeats whatever was last in the buffer. Stopping
    the client is the honest way to be quiet for a while, and it is also the
    price of the single-threaded design -- an audio thread would have kept
    playing.
    """
    comptime assert (
        size_of[FilterSpec]() == winkb_struct_size["COMDLG_FILTERSPEC"]()
    ), "COMDLG_FILTERSPEC does not match Windows"

    var was_running = False
    if speaker:
        was_running = speaker.value().running
    if was_running:
        speaker.value().stop()
        # Stop does not empty the ring, it stops draining it. Without the
        # Reset, restarting asks GetBuffer for a ring that is still mostly
        # occupied, and the answer is AUDCLNT_E_BUFFER_TOO_LARGE -- which took
        # the program with it before this line existed. It is also the bug
        # `std.windows.audio` records, and `spikes/win32/audio_smoke.mojo`
        # reproduces it on purpose.
        speaker.value().reset()

    var dialog = co_create[CLSID_FileOpenDialog, "IFileOpenDialog"]()
    var d = Com[StaticString("IFileOpenDialog")](of=dialog)

    var label = WideString("ABC tunes")
    var pattern = WideString("*.abc")
    var spec = FilterSpec(
        Int(label.unsafe_ptr()), Int(pattern.unsafe_ptr())
    )
    _ = d.SetFileTypes(UInt32(1), com_addr(spec))
    var caption = WideString("Add a tune")
    _ = d.SetTitle(caption.unsafe_ptr())
    _ = d.SetOptions(UInt32(winkb_constant["FOS_FORCEFILESYSTEM"]()))

    var chosen = String("")
    try:
        # Show raises on cancel -- the user pressing Escape comes back as
        # HRESULT_FROM_WIN32(ERROR_CANCELLED), which is a failure code and so
        # an exception here. It is not an error; it is an answer.
        _ = d.Show(app[].hwnd)
        var item_address: Int = 0
        _ = d.GetResult(com_addr(item_address))
        if item_address != 0:
            var item = ComPtr[StaticString("IShellItem")](adopt=item_address)
            var text_address: Int = 0
            _ = Com[StaticString("IShellItem")](of=item).GetDisplayName(
                Int32(winkb_constant["SIGDN_FILESYSPATH"]()),
                com_addr(text_address),
            )
            if text_address != 0:
                # A path is exactly the string a `chr()` loop over code units
                # gets wrong, and this one arrives from a file picker the user
                # drove: `from_wide` is the boundary this library already owns.
                chosen = from_wide(
                    Pointer[UInt16, MutAnyOrigin](
                        unsafe_from_address=text_address
                    )
                )
                _ = win32[
                    def (Int) thin abi("C") -> NoneType, "CoTaskMemFree"
                ]()(text_address)
    except err:
        app[].status = String("no file chosen")

    _ = label
    _ = pattern
    _ = caption

    if len(chosen.as_bytes()) > 0:
        add_tune(app, chosen)
        var want = tune_index(app, basename(chosen))
        if want >= 0:
            app[].sel = want
        app[].status = String("added ") + basename(chosen)

    if was_running:
        # `start` primes the ring itself, filling only what is FREE, so the
        # hand-written pre-roll that used to live here -- allocate, GetBuffer
        # the whole ring, render, fan out, release -- is gone.
        var fill = abc_fill
        speaker.value().start(fill, user)


def selftest_fill(app: AppPtr, a: wasapi.Audio, mono: Int) raises:
    """One wake: write exactly what has drained, and not one frame more.

    Everything here is what the Mac does inside CoreAudio's callback, with the
    same no-allocation, no-locking contract -- the difference is only that
    this function is called by a loop we own rather than by the system.
    """
    var pad = a.padding()
    if pad == 0:
        # The only reporter of starvation there is. Every call in this
        # function returns S_OK through an underrun; the window shows this
        # number so a hole in the sound has a name.
        app[].starved += 1
    var avail = a.frames - pad
    if avail <= 0:
        return
    var address = a.get_buffer(avail)
    if address == 0:
        return

    var st = P(unsafe_from_address=app[].chip)
    var buf = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=mono)
    if app[].paused != 0 or app[].backend == BACKEND_MIDI:
        for i in range(avail):
            buf[unsafe_offset=i] = Float32(0.0)
    else:
        render_scheduled(st, buf, avail)
        # The loudest thing this program produced, which is a different claim
        # from the endpoint's meter: that one hears the whole machine, so a
        # run that made no sound at all can still meter whatever else is
        # playing. Both numbers together are the honest evidence.
        for i in range(avail):
            var v = Float64(buf[unsafe_offset=i])
            if v < 0.0:
                v = -v
            if v > app[].out_peak:
                app[].out_peak = v
    a.fan_out(address, mono, avail)
    a.release_buffer(avail)

    # A copy for the scope. Unsynchronised on purpose, and here there is not
    # even another thread to be unsynchronised with -- the window is painted
    # from the same loop, so the worst case is a sweep drawn one wake stale.
    if app[].scope != 0:
        var scope = Pointer[Float32, MutUntrackedOrigin](
            unsafe_from_address=app[].scope
        )
        var pos = app[].scope_pos
        for i in range(avail):
            scope[unsafe_offset=pos] = buf[unsafe_offset=i]
            pos += 1
            if pos >= SCOPE_LEN:
                pos = 0
        app[].scope_pos = pos


def selftest(
    app: AppPtr, seconds: Float64, mut midi: winmidi.MidiOut
) raises -> Int:
    var failures = 0
    print("pitch check:")
    failures += pitch_check()
    print("timing check:")
    failures += timing_check()
    print("sound check:")
    var hz = performance_frequency()
    var deadline = performance_counter() + Int(seconds * Float64(hz))

    with Apartment(multithreaded=True):
        if app[].backend == BACKEND_MIDI:
            # No render stream: the synthesiser has its own path to the
            # speakers. Only the meter is opened, and only to listen.
            var a = wasapi.open_meter()
            var peak = 0.0
            var sleep_ms = win32[
                def (UInt32) thin abi("C") -> NoneType, "Sleep"
            ]()
            while performance_counter() < deadline:
                sleep_ms(UInt32(10))
                var p = a.peak()
                if p > peak:
                    peak = p
            print("  midi stream position:", winmidi.position_ticks(midi),
                  "ticks of", midi.total_ticks)
            print("  endpoint peak meter reached", peak)
            if peak <= 0.0:
                print("  FAIL: nothing reached the device")
                failures += 1
            else:
                print("  AUDIBLE: the device metered the synthesiser")
            a.close()
        else:
            var a = wasapi.open_output(BUFFER_MS)
            print(" ", wasapi.describe(a))
            if a.rate != SAMPLE_RATE:
                print(
                    "  NOTE: the engine runs at", a.rate,
                    "and the chip at", SAMPLE_RATE,
                    "-- the tune will play at the wrong pitch",
                )
            var mono = unsafe_alloc[Float32](a.frames, alignment=64)
            var first = a.get_buffer(a.frames)
            render_scheduled(
                P(unsafe_from_address=app[].chip),
                Pointer[Float32, MutUntrackedOrigin](
                    unsafe_from_address=Int(mono)
                ),
                a.frames,
            )
            a.fan_out(first, Int(mono), a.frames)
            a.release_buffer(a.frames)
            a.start()

            var wait = win32[
                def (Int, UInt32) thin abi("C") -> UInt32, "WaitForSingleObject"
            ]()
            var peak = 0.0
            var wakes = 0
            while performance_counter() < deadline:
                if wait(a.event, UInt32(500)) != UInt32(
                    winkb_constant["WAIT_OBJECT_0"]()
                ):
                    print("  FAIL: the audio event never arrived")
                    failures += 1
                    break
                wakes += 1
                var p = a.peak()
                if p > peak:
                    peak = p
                selftest_fill(app, a, Int(mono))
            a.stop()
            print(
                "  wakes", wakes, " underruns", app[].starved,
                " played", Float64(get(
                    P(unsafe_from_address=app[].chip), PLAYER_BASE + SC_SAMPLE
                )) / Float64(SAMPLE_RATE), "s",
            )
            print("  our own samples peaked at", app[].out_peak)
            print("  endpoint peak meter reached", peak)
            if app[].out_peak <= 0.0:
                print("  FAIL: the synthesiser produced silence")
                failures += 1
            if peak <= 0.0:
                print("  FAIL: nothing reached the device")
                failures += 1
            if app[].out_peak > 0.0 and peak > 0.0:
                print("  AUDIBLE: we made samples and the device metered them")
            if app[].starved > 0:
                print("  FAIL: the ring was found empty", app[].starved, "times")
                failures += 1
            mono.unsafe_free()
            a.close()
    return failures


# ===----------------------------------------------------------------------===#


def main() raises:
    check_layouts()

    var backend = BACKEND_CHIP
    var write_to = String("")
    var first = String("")
    var run_selftest = False
    var test_seconds = 4.0
    var hold_ms = 0
    var args = argv()
    # `skip` is not decoration. An option that takes a value eats the next
    # argument, and without that the "5" of `--seconds 5` falls through to the
    # final branch and becomes the tune to play -- which then fails to open,
    # leaves the previous schedule running, and produces a self-test that
    # passes while playing nothing it was asked to.
    var skip = False
    for i in range(1, len(args)):
        if skip:
            skip = False
            continue
        var a = String(args[i])
        if a == "--midi":
            backend = BACKEND_MIDI
        elif a == "--chip":
            backend = BACKEND_CHIP
        elif a == "--selftest":
            run_selftest = True
        elif a == "--seconds" and i + 1 < len(args):
            test_seconds = Float64(Int(args[i + 1]))
            skip = True
        elif a == "--ms" and i + 1 < len(args):
            hold_ms = Int(args[i + 1])
            skip = True
        elif a.startswith("--write="):
            write_to = String(a[byte=8 : len(a.as_bytes())])
        elif a.startswith("--"):
            print("unknown option:", a)
        else:
            first = a

    # ── --write: parse, write, done. No audio, no window. ────────────────
    if len(write_to.as_bytes()) > 0:
        if len(first.as_bytes()) == 0:
            print("usage: abcplayer <tune.abc> --write=out.mid")
            return
        var text: String
        with open(first, "r") as f:
            text = f.read()
        var tune = Tune()
        parse_abc(text, tune)
        expand_repeats(tune)
        resolve_ties(tune)
        if write_midi(tune, write_to):
            print("wrote", write_to)
        else:
            print("could not write", write_to)
        return

    print("metadata schema:", winkb_db_schema_version())

    # ── State, on the heap ───────────────────────────────────────────────
    # It must outlive main's locals and be reachable from a captureless window
    # procedure, so it is allocated rather than declared.
    var store = unsafe_alloc[App](1, alignment=8)
    # Emplaced, not assigned: `store[] = value` would destroy what was there
    # first, and what is there is whatever the allocator last had.
    store.unsafe_write(App())
    var app = AppPtr(unsafe_from_address=Int(store))
    app[].backend = backend
    app[].chip = Int(chip_new())
    app[].scope = Int(unsafe_alloc[Float32](SCOPE_LEN, alignment=64))
    var scope0 = Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=app[].scope
    )
    for i in range(SCOPE_LEN):
        scope0[unsafe_offset=i] = Float32(0.0)
    ui_init(app)
    apply_params(app)

    # An empty schedule, so live mode renders the chip rather than silence.
    var st = P(unsafe_from_address=app[].chip)
    var empty = unsafe_alloc[Int](STEP_SLOTS + 8, alignment=64)
    for i in range(STEP_SLOTS + 8):
        empty[unsafe_offset=i] = 0
    put(st, PLAYER_BASE + SC_ADDR, Int(empty))
    put(st, PLAYER_BASE + SC_END, 1 << 60)

    # Nothing has struck a chip voice yet, and a slot left at its allocated
    # zero would read as MIDI note 0 -- which the panel would draw, in perfect
    # good faith, as a C in the octave below the piano.
    for v in range(3):
        put(st, PLAYER_BASE + SC_VOICE_NOTE + v, -1)

    var midi = winmidi.MidiOut()
    if backend == BACKEND_MIDI:
        winmidi.open_stream(midi)
        app[].midi_stream = midi.stream
        print("MIDI out:", winmidi.device_name())

    # The tunes folder beside the executable's own directory, then beside the
    # current one -- so the program works both from the repository root and
    # from inside the example.
    scan_tunes(app, String("examples\\win32\\abcplayer\\tunes"))
    scan_tunes(app, String("tunes"))
    if len(first.as_bytes()) > 0:
        # Select it BY NAME. The scan has usually already listed the same
        # file, so add_tune returns without appending and "the last entry" is
        # some other tune entirely -- which is how a named tune on the command
        # line ends up playing whatever sorted last.
        add_tune(app, first)
        var want = tune_index(app, basename(first))
        if want >= 0:
            app[].sel = want
    print("tunes found:", len(app[].names))

    # ── --selftest: no window, and a verdict ─────────────────────────────
    if run_selftest:
        if app[].sel >= 0:
            play_tune(app, app[].sel, midi)
            print("playing:", app[].title, "-", app[].subtitle)
        else:
            print("no tune to play")
        var bad = selftest(app, test_seconds, midi)
        winmidi.close(midi)
        chip_free(P(unsafe_from_address=app[].chip))
        empty.unsafe_free()
        if bad != 0:
            raise Error(String(bad) + " check(s) failed")
        print("selftest ok")
        return

    # ── The window ───────────────────────────────────────────────────────
    # Declare DPI awareness BEFORE any window exists, or it is ignored --
    # otherwise Windows lies about the size of everything and then bilinearly
    # upscales it, which turns a one-pixel gutter into a smear.
    var SetProcessDpiAwarenessContext = win32[
        def (Int) thin abi("C") -> c_int, "SetProcessDpiAwarenessContext"
    ]()
    if SetProcessDpiAwarenessContext(
        winkb_constant["DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2"]()
    ) == 0:
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
    var ShowWindow = win32[def (Int, c_int) thin abi("C") -> c_int, "ShowWindow"]()
    var UpdateWindow = win32[def (Int) thin abi("C") -> c_int, "UpdateWindow"]()
    var SetWindowLongPtrW = win32[
        def (Int, c_int, Int) thin abi("C") -> Int, "SetWindowLongPtrW"
    ]()
    var InvalidateRect = win32[
        def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
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
        def (Pointer[MSG, MutAnyOrigin]) thin abi("C") -> Int, "DispatchMessageW"
    ]()
    var MsgWait = win32[
        def (
            UInt32, Pointer[Int, MutAnyOrigin], c_int, UInt32, UInt32
        ) thin abi("C") -> UInt32,
        "MsgWaitForMultipleObjects",
    ]()
    var DestroyWindow = win32[def (Int) thin abi("C") -> c_int, "DestroyWindow"]()

    var hInstance = GetModuleHandleW(0)
    var class_name = WideString("MojoAbcPlayerWindow")
    var title = WideString("ABC player")

    # A `def` cannot be handed to Windows directly: it goes through a thin
    # C-ABI value first, and the named type is shared with DefWindowProcW so
    # the two cannot drift.
    var proc: WndProc = abc_wndproc

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

    # Fixed size, deliberately: every rectangle in the panel is a constant and
    # a hit test reads the same constants, so a resizable window would be a
    # layout engine nobody asked for. WS_OVERLAPPEDWINDOW minus the sizing
    # frame and the maximise box says exactly that to the user.
    comptime STYLE = (
        winkb_constant["WS_OVERLAPPEDWINDOW"]()
        & ~winkb_constant["WS_THICKFRAME"]()
        & ~winkb_constant["WS_MAXIMIZEBOX"]()
    )
    var want = RECT()
    want.right = Int32(WIN_W)
    want.bottom = Int32(WIN_H)
    _ = AdjustWindowRectEx(com_addr(want), UInt32(STYLE), c_int(0), UInt32(0))

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
    _ = class_name
    _ = title

    app[].hwnd = hwnd
    app[].font_title = make_font(17, True)
    app[].font_body = make_font(13, False)
    app[].font_small = make_font(12, False)
    _ = SetWindowLongPtrW(
        hwnd, c_int(winkb_constant["GWLP_USERDATA"]()), Int(store)
    )
    _ = ShowWindow(hwnd, c_int(winkb_constant["SW_SHOW"]()))
    _ = UpdateWindow(hwnd)

    # ── One thread, one loop ─────────────────────────────────────────────
    # The STA, because this thread owns a window. The audio spike verified
    # that WASAPI is happy on an STA -- its objects are in-process and
    # thread-agile -- and here the messages actually are pumped, which is the
    # thing an STA is owed.
    with Apartment(multithreaded=False):
        var speaker: Optional[RenderStream] = None
        var user = OpaquePointer[MutUntrackedOrigin](
            unsafe_from_address=Int(store)
        )
        if backend == BACKEND_CHIP:
            speaker = RenderStream(buffer_ms=BUFFER_MS)
            var fmt = speaker.value().format.copy()
            print(
                "mix format:", fmt.rate, "Hz,", fmt.channels, "channels,",
                fmt.bits, "bit,", "float" if fmt.is_float else "int16",
            )
            if fmt.rate != SAMPLE_RATE:
                print(
                    "NOTE: the engine runs at", fmt.rate,
                    "and the chip at", SAMPLE_RATE,
                    "-- the tune will play at the wrong pitch",
                )
            app[].home_subtitle = String(
                "chip - three voices - "
            ) + String(fmt.rate) + String(" Hz")
        else:
            app[].home_subtitle = String(
                "General MIDI - "
            ) + winmidi.device_name()
        app[].subtitle = app[].home_subtitle

        # The tune is loaded BEFORE the stream starts, not after. Reading and
        # parsing a file is tens of milliseconds of work in a build with no
        # optimisation, and doing it with the clock already running drains the
        # ring by exactly that much -- which is one underrun on the first note
        # of every run, and it showed up as one.
        if len(first.as_bytes()) > 0 and app[].sel >= 0:
            play_tune(app, app[].sel, midi)

        var fill: RenderFill = abc_fill
        if speaker:
            # `start` fills the ring through the callback before the clock
            # runs -- the pre-roll RenderStream insists on, preventing the
            # same first-period underrun the hand-written prime used to.
            speaker.value().start(fill, user)

        var handles = List[Int]()
        if speaker:
            handles.append(speaker.value().event)
        var nhandles = UInt32(len(handles))
        var handle_ptr = handles.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()

        var hz = performance_frequency()
        var started = performance_counter()
        var next_frame = started
        var frame_ticks = hz // 30
        var running = True
        var msg = MSG()

        while running:
            # Wait for the speaker OR for the user, whichever comes first.
            # This is the whole reason there is no audio thread: one call
            # blocks on both, so the loop is never late for either.
            var got = MsgWait(
                nhandles, handle_ptr, c_int(0), UInt32(50),
                UInt32(winkb_constant["QS_ALLINPUT"]()),
            )
            if speaker and got == UInt32(
                winkb_constant["WAIT_OBJECT_0"]()
            ):
                _ = speaker.value().write(fill, user)

            while PeekMessageW(
                com_addr(msg), 0, UInt32(0), UInt32(0),
                UInt32(winkb_constant["PM_REMOVE"]()),
            ) != c_int(0):
                if msg.message == UInt32(winkb_constant["WM_QUIT"]()):
                    running = False
                    break
                _ = TranslateMessage(com_addr(msg))
                _ = DispatchMessageW(com_addr(msg))
            if not running:
                break

            # ── Commands the window asked for ────────────────────────────
            # Read the flags out BEFORE clearing them, and act on them here
            # rather than in the window procedure: parsing a file is work that
            # can take a millisecond, and a window procedure is not the place
            # to spend one.
            if app[].cmd != 0:
                var quit = (app[].cmd & CMD_QUIT) != 0
                var want_play = (app[].cmd & CMD_PLAY) != 0
                var want_stop = (app[].cmd & CMD_STOP) != 0
                var want_pause = (app[].cmd & CMD_PAUSE) != 0
                var want_add = (app[].cmd & CMD_ADD) != 0
                app[].cmd = 0
                if quit:
                    _ = DestroyWindow(hwnd)
                    continue
                if want_add:
                    open_panel(app, speaker, user)
                if want_stop:
                    go_live(app, midi)
                    app[].title = String("ABC player")
                    app[].subtitle = app[].home_subtitle
                    app[].status = String("ready")
                if want_play:
                    play_tune(app, app[].sel, midi)
                if want_pause:
                    app[].paused = 0 if app[].paused != 0 else 1
                    if backend == BACKEND_MIDI:
                        winmidi.pause(midi, app[].paused != 0)

            # ── Where the tune has got to ────────────────────────────────
            if app[].mode == MODE_TUNE:
                if backend == BACKEND_MIDI:
                    var t = winmidi.position_ticks(midi)
                    if app[].end_ticks > 0:
                        app[].pos_samples = (
                            (t % app[].end_ticks) * app[].end_samples
                        ) // app[].end_ticks
                    # A header the driver has finished with comes back marked
                    # done; handing the same memory over again is how a tune
                    # repeats here.
                    if winmidi.all_done(midi):
                        winmidi.replay(midi)
                else:
                    app[].pos_samples = get(st, PLAYER_BASE + SC_SAMPLE)
                    app[].end_samples = get(st, PLAYER_BASE + SC_END)

            var now = performance_counter()
            if now >= next_frame:
                next_frame = now + frame_ticks
                _ = InvalidateRect(hwnd, 0, c_int(0))
            if hold_ms > 0 and now - started > hold_ms * hz // 1000:
                _ = DestroyWindow(hwnd)

        if speaker:
            speaker.value().stop()
        # The stream owns five COM pointers and must die inside this block: a
        # Release after CoUninitialize is a crash in ole32 with no stack.
        speaker = None

    winmidi.close(midi)
    print("underruns:", app[].starved)
    chip_free(P(unsafe_from_address=app[].chip))
    empty.unsafe_free()
    print("stopped.")
