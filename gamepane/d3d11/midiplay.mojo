"""General MIDI playback of an ABC tune through the Windows GS synth.

The Mac backend's answer to "a choir, not a chip" is AVMIDIPlayer with the
system soundbank; the Windows answer here is `midiStreamOut` with the
Microsoft GS Wavetable Synth -- the schedule handed to the driver whole,
on its own clock, exactly as abcplayer's winmidi.mojo proved on this
machine. The parse happens on the caller's thread; the driver plays.

The schedule is built from the parser's `Event`s directly -- they carry
ticks, which is the unit the MIDI stream wants -- with a note-off
generated for every note's duration, note-offs first at a tie so a note
that ends exactly where the next begins cannot cut it.

One stream at a time: starting a tune stops the one before. The event and
header allocations are raw on purpose -- `midiStreamOut` is asynchronous
and reads that memory long after this call returns -- and are freed only
when the stream stops.

The signature is gamepane's `midiplay.mojo`: same `play_tune_gm(source)
raises -> Bool`, same one-player rule, same "music not being a reason to
stop" contract. Only the machine under it differs.
"""

from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.sys._com import com_addr
from std.sys._winkb import (
    winkb_constant,
    winkb_field_offset,
    winkb_struct_size,
)
from std.sys.info import size_of
from std.sys._globals import named_global
from std.windows.core import win32

from gamepane.abc.parse import parse_abc
from gamepane.abc.model import Tune, EV_NOTE, TICKS_PER_QUARTER
from gamepane.abc.schedule import resolve_ties
from gamepane.abc.midi import channel_for


comptime EVENT_STRIDE = winkb_field_offset["MIDIEVENT", "dwParms"]()
comptime MIDIPROP_SET = winkb_constant["MIDIPROP_SET"]()
comptime MIDIPROP_TIMEDIV = winkb_constant["MIDIPROP_TIMEDIV"]()
comptime MIDIPROP_TEMPO = winkb_constant["MIDIPROP_TEMPO"]()
comptime MEVT_SHORTMSG = winkb_constant["MEVT_SHORTMSG"]()
comptime MMSYSERR_NOERROR = winkb_constant["MMSYSERR_NOERROR"]()

comptime EVENTS_PER_HEADER = 5000
comptime MAX_HEADERS = 8

def _check_layouts():
    comptime assert EVENT_STRIDE == 12, (
        "a short MIDIEVENT is three DWORDs; the metadata disagrees"
    )




# The one stream, and its allocations, reachable by name: stop has to find
# them from wherever the game's thread ends up.
comptime g_gm_stream = named_global["gamepane.gm_stream", Int]
comptime g_gm_events = named_global["gamepane.gm_events", Int]
comptime g_gm_headers = named_global["gamepane.gm_headers", Int]
comptime g_gm_header_count = named_global["gamepane.gm_header_count", Int]


@fieldwise_init
struct MIDIPROP(Defaultable, Copyable, Movable):
    """MIDIPROPTIMEDIV and MIDIPROPTEMPO are the same two words."""

    var cbStruct: UInt32
    var dwValue: UInt32

    def __init__(out self):
        self.cbStruct = 0
        self.dwValue = 0


def _poke32(base: Int, offset: Int, value: Int):
    var p = Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=base)
    p[unsafe_offset = offset // 4] = UInt32(value)


def _poke64(base: Int, offset: Int, value: Int):
    var p = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=base)
    p[unsafe_offset = offset // 8] = value


def _us_per_quarter(tune: Tune) -> Int:
    """The tempo in microseconds a quarter note lasts.

    Q: names a beat that is not necessarily a quarter note, so the bpm is
    converted against whatever note value it counts.
    """
    let per_beat_ticks = (
        TICKS_PER_QUARTER * 4 * tune.tempo_num
    ) // tune.tempo_den
    if tune.tempo_bpm > 0 and per_beat_ticks > 0:
        return (60000000 * TICKS_PER_QUARTER) // (
            tune.tempo_bpm * per_beat_ticks
        )
    return 500000


def stop_tune_gm() raises:
    """Stop the stream, unprepare every header, free what was allocated."""
    let stream = g_gm_stream()[]
    if stream == 0:
        return
    var midiStreamStop = win32[
        def (Int) thin abi("C") -> UInt32, "midiStreamStop"
    ]()
    _ = midiStreamStop(stream)
    var midiOutUnprepareHeader = win32[
        def (Int, Int, UInt32) thin abi("C") -> UInt32,
        "midiOutUnprepareHeader",
    ]()
    let hdr_size = winkb_struct_size["MIDIHDR"]()
    let headers = g_gm_headers()[]
    let count = g_gm_header_count()[]
    for i in range(count):
        _ = midiOutUnprepareHeader(
            stream, headers + i * hdr_size, UInt32(hdr_size)
        )
    var midiOutClose = win32[
        def (Int) thin abi("C") -> UInt32, "midiOutClose"
    ]()
    _ = midiOutClose(stream)
    if headers != 0:
        var hp = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=headers
        )
        hp.unsafe_free()
    let events = g_gm_events()[]
    if events != 0:
        var ep = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=events
        )
        ep.unsafe_free()
    g_gm_stream()[] = 0
    g_gm_events()[] = 0
    g_gm_headers()[] = 0
    g_gm_header_count()[] = 0


def play_tune_gm(source: String) raises -> Bool:
    """Play an ABC tune once through the system General MIDI synth.

    False when the tune has no notes, there is no MIDI device, or winmm
    refuses -- a game carries on either way, music not being a reason to
    stop."""
    comptime assert (
        size_of[MIDIPROP]() == winkb_struct_size["MIDIPROPTIMEDIV"]()
        and size_of[MIDIPROP]() == winkb_struct_size["MIDIPROPTEMPO"]()
    ), "MIDIPROPTIMEDIV and MIDIPROPTEMPO are not the shape declared here"

    _check_layouts()

    # ── parse ────────────────────────────────────────────────────────────
    var tune = Tune()
    parse_abc(source, tune)
    resolve_ties(tune)

    # Every note as (tick, voice, midi, velocity) plus its note-off at
    # tick + duration. Ticks are the MIDI stream's own unit; converting a
    # sample schedule back to them would only round.
    var all = List[Tuple[Int, Int, Int, Int]]()
    for i in range(len(tune.events)):
        let ev = tune.events[i]
        if ev.kind != EV_NOTE:
            continue
        all.append((ev.tick, ev.voice, ev.midi, 0))
        all.append((ev.tick, ev.voice, ev.midi, ev.velocity))
        var j = len(all) - 1
        # Swap so the note-off precedes the note-on at the same tick.
        var t = all[j]
        all[j] = all[j - 1]
        all[j - 1] = t
        all.append((ev.tick + ev.duration, ev.voice, ev.midi, 0))
    if len(all) == 0:
        return False

    # Insertion sort by tick; note-off first at a tie. The lists are
    # small (a game cue is a few hundred events), and List has no sort.
    for i in range(len(all)):
        var j = i
        while j > 0:
            let a = all[j]
            let b = all[j - 1]
            var before = a[0] < b[0]
            if a[0] == b[0] and a[3] == 0 and b[3] != 0:
                before = True
            if not before:
                break
            var t = all[j]
            all[j] = all[j - 1]
            all[j - 1] = t
            j -= 1

    var count = len(all)
    if count > EVENTS_PER_HEADER * MAX_HEADERS:
        count = EVENTS_PER_HEADER * MAX_HEADERS

    # ── the stream ─────────────────────────────────────────────────────
    var midiOutGetNumDevs = win32[
        def () thin abi("C") -> UInt32, "midiOutGetNumDevs"
    ]()
    if midiOutGetNumDevs() == UInt32(0):
        return False
    stop_tune_gm()
    var midiStreamOpen = win32[
        def (
            Pointer[Int, MutAnyOrigin],
            Pointer[UInt32, MutAnyOrigin],
            UInt32, Int, Int, UInt32,
        ) thin abi("C") -> UInt32,
        "midiStreamOpen",
    ]()
    var handle: Int = 0
    var device = UInt32(0)
    # dwCallback 0 with no CALLBACK_* flag: tell me nothing; nothing here
    # needs to be told.
    var rc = midiStreamOpen(
        com_addr(handle), com_addr(device), UInt32(1), 0, 0, UInt32(0)
    )
    if rc != UInt32(MMSYSERR_NOERROR):
        return False

    var midiStreamProperty = win32[
        def (
            Int, Pointer[MIDIPROP, MutAnyOrigin], UInt32
        ) thin abi("C") -> UInt32,
        "midiStreamProperty",
    ]()
    var timediv = MIDIPROP()
    timediv.cbStruct = UInt32(size_of[MIDIPROP]())
    timediv.dwValue = UInt32(TICKS_PER_QUARTER)
    rc = midiStreamProperty(
        handle, com_addr(timediv), UInt32(MIDIPROP_SET | MIDIPROP_TIMEDIV)
    )
    if rc != UInt32(MMSYSERR_NOERROR):
        var midiOutClose = win32[
            def (Int) thin abi("C") -> UInt32, "midiOutClose"
        ]()
        _ = midiOutClose(handle)
        return False
    var tempo = MIDIPROP()
    tempo.cbStruct = UInt32(size_of[MIDIPROP]())
    tempo.dwValue = UInt32(_us_per_quarter(tune))
    _ = midiStreamProperty(
        handle, com_addr(tempo), UInt32(MIDIPROP_SET | MIDIPROP_TEMPO)
    )

    # ── pack the events ────────────────────────────────────────────────
    var block = unsafe_alloc[UInt8](count * EVENT_STRIDE, alignment=64)
    var base = Int(block)
    var last_tick = 0
    for i in range(count):
        var tick = all[i][0]
        if tick < last_tick:
            tick = last_tick
        let channel = channel_for(all[i][1])
        var status = 0x80 | channel
        var data2 = all[i][3] & 0x7F
        if data2 != 0:
            status = 0x90 | channel
        var at = base + i * EVENT_STRIDE
        _poke32(at, 0, tick - last_tick)
        _poke32(at, 4, 0)
        _poke32(
            at,
            8,
            (MEVT_SHORTMSG << 24)
            | status
            | ((all[i][2] & 0x7F) << 8)
            | (data2 << 16),
        )
        last_tick = tick

    # ── the headers ────────────────────────────────────────────────────
    var hdr_size = winkb_struct_size["MIDIHDR"]()
    var headers = unsafe_alloc[UInt8](hdr_size * MAX_HEADERS, alignment=64)
    for i in range(hdr_size * MAX_HEADERS):
        headers[unsafe_offset=i] = UInt8(0)
    var midiOutPrepareHeader = win32[
        def (Int, Int, UInt32) thin abi("C") -> UInt32,
        "midiOutPrepareHeader",
    ]()
    var midiStreamOut = win32[
        def (Int, Int, UInt32) thin abi("C") -> UInt32, "midiStreamOut"
    ]()

    var done = 0
    var nheaders = 0
    while done < count and nheaders < MAX_HEADERS:
        var chunk = count - done
        if chunk > EVENTS_PER_HEADER:
            chunk = EVENTS_PER_HEADER
        var h = Int(headers) + nheaders * hdr_size
        _poke64(
            h, winkb_field_offset["MIDIHDR", "lpData"](),
            base + done * EVENT_STRIDE,
        )
        _poke32(
            h, winkb_field_offset["MIDIHDR", "dwBufferLength"](),
            chunk * EVENT_STRIDE,
        )
        _poke32(
            h, winkb_field_offset["MIDIHDR", "dwBytesRecorded"](),
            chunk * EVENT_STRIDE,
        )
        rc = midiOutPrepareHeader(handle, h, UInt32(hdr_size))
        if rc != UInt32(MMSYSERR_NOERROR):
            var close_it = win32[
                def (Int) thin abi("C") -> UInt32, "midiOutClose"
            ]()
            _ = close_it(handle)
            var bp = Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=base
            )
            bp.unsafe_free()
            var hp2 = Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=Int(headers)
            )
            hp2.unsafe_free()
            return False
        rc = midiStreamOut(handle, h, UInt32(hdr_size))
        if rc != UInt32(MMSYSERR_NOERROR):
            g_gm_stream()[] = handle
            g_gm_events()[] = base
            g_gm_headers()[] = Int(headers)
            g_gm_header_count()[] = nheaders
            stop_tune_gm()
            return False
        done += chunk
        nheaders += 1

    var midiStreamRestart = win32[
        def (Int) thin abi("C") -> UInt32, "midiStreamRestart"
    ]()
    _ = midiStreamRestart(handle)

    g_gm_stream()[] = handle
    g_gm_events()[] = base
    g_gm_headers()[] = Int(headers)
    g_gm_header_count()[] = nheaders
    return True
