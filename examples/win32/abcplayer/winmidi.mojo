# The other backend: the synthesiser Windows already has.
#
# `--midi` on the Mac hands each event to Apple's DLS synth through
# `MusicDeviceMIDIEvent`, which takes a sample offset inside the buffer being
# rendered -- so the note lands on the sample it was written for, and the MIDI
# backend gets exactly the timing the chip backend gets, from the same
# schedule, in the same callback.
#
# Windows has no such call. The system synthesiser is a MIDI *device*, not an
# audio unit that can be pulled into a buffer we own, so there is no buffer to
# offset into. `midiOutShortMsg` sends a message now, and "now" from a loop
# that wakes every ten milliseconds is a tenth of a semiquaver at 120bpm --
# audible, and worse, variable.
#
# The Windows answer is to stop sending events and hand over the schedule.
# `midiStreamOut` takes a whole array of tick-stamped events and the driver
# plays them against its own clock, which is what MusicDeviceMIDIEvent's
# offset argument is really asking for. So the two backends still share one
# schedule -- that is why a `Step` carries its tick as well as its sample --
# and the difference is only who owns the clock: this program for the chip,
# the MIDI driver for this.
#
# It also means an honest limit, stated here rather than discovered: the
# resolution is the driver's timer, not the sample. Windows' software
# synthesiser schedules on a one-millisecond tick, so a note can land up to
# about a millisecond from where it was written, against the chip backend's
# exactly-one-sample.

from std.ffi import c_int
from std.memory import Pointer, MutUntrackedOrigin
from std.memory.alloc import unsafe_alloc
from std.sys._com import com_addr
from std.sys._winkb import (
    winkb_constant,
    winkb_field_offset,
    winkb_struct_size,
)
from std.sys.info import size_of

from model import Tune, TICKS_PER_QUARTER
from schedule import Step, SE_NOTE_ON, SE_NOTE_OFF, SE_CHIP
from win32 import win32, wide_of


# A MIDIEVENT is three DWORDs followed by a flexible array of parameter
# words. The metadata records the struct as 16 bytes because it counts one
# element of that array; a short message has none, and its stride is 12. The
# assertion below is how that is checked rather than asserted by a comment:
# dwParms begins where a short event ends.
comptime EVENT_STRIDE = winkb_field_offset["MIDIEVENT", "dwParms"]()

comptime MIDIPROP_SET = winkb_constant["MIDIPROP_SET"]()
comptime MIDIPROP_TIMEDIV = winkb_constant["MIDIPROP_TIMEDIV"]()
comptime MIDIPROP_TEMPO = winkb_constant["MIDIPROP_TEMPO"]()
comptime MEVT_SHORTMSG = winkb_constant["MEVT_SHORTMSG"]()
comptime MHDR_DONE = winkb_constant["MHDR_DONE"]()
comptime TIME_TICKS = winkb_constant["TIME_TICKS"]()
comptime MMSYSERR_NOERROR = winkb_constant["MMSYSERR_NOERROR"]()

# One header may describe at most 64 KB of events, so a long tune is queued as
# several. Eight of these hold sixteen thousand notes, which is more than any
# ABC file in the wild.
comptime EVENTS_PER_HEADER = 5000
comptime MAX_HEADERS = 8


@fieldwise_init
struct MIDIPROP(Defaultable, Copyable, Movable):
    """MIDIPROPTIMEDIV and MIDIPROPTEMPO are the same two words."""

    var cbStruct: UInt32
    var dwValue: UInt32

    def __init__(out self):
        self.cbStruct = 0
        self.dwValue = 0


@fieldwise_init
struct MidiOut(Defaultable, ImplicitlyCopyable, Copyable, Movable):
    """An open stream and the buffers the driver is reading from.

    The event bytes and the headers are raw allocations rather than Lists
    because `midiStreamOut` is asynchronous: the driver reads this memory long
    after the call returns, so it has to sit still at a fixed address until
    the stream is stopped and every header unprepared.
    """

    var stream: Int          # HMIDISTRM
    var events: Int          # the MIDIEVENT bytes
    var event_bytes: Int
    var headers: Int         # MAX_HEADERS contiguous MIDIHDR blocks
    var header_count: Int
    var total_ticks: Int
    var playing: Bool
    var paused: Bool

    def __init__(out self):
        self.stream = 0
        self.events = 0
        self.event_bytes = 0
        self.headers = 0
        self.header_count = 0
        self.total_ticks = 1
        self.playing = False
        self.paused = False


def bytes_at(address: Int) -> Pointer[UInt8, MutUntrackedOrigin]:
    return Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=address)


def poke32(address: Int, offset: Int, value: Int):
    """One little-endian 32-bit word, at a byte offset the metadata gave us."""
    var p = bytes_at(address + offset)
    p[unsafe_offset=0] = UInt8(value & 0xFF)
    p[unsafe_offset=1] = UInt8((value >> 8) & 0xFF)
    p[unsafe_offset=2] = UInt8((value >> 16) & 0xFF)
    p[unsafe_offset=3] = UInt8((value >> 24) & 0xFF)


def peek32(address: Int, offset: Int) -> Int:
    var p = bytes_at(address + offset)
    return (
        Int(p[unsafe_offset=0])
        | (Int(p[unsafe_offset=1]) << 8)
        | (Int(p[unsafe_offset=2]) << 16)
        | (Int(p[unsafe_offset=3]) << 24)
    )


def poke64(address: Int, offset: Int, value: Int):
    var p = bytes_at(address + offset)
    for i in range(8):
        p[unsafe_offset=i] = UInt8((value >> (8 * i)) & 0xFF)


def channel_for(voice: Int) -> Int:
    """A voice number becomes a MIDI channel, skipping 9.

    Channel 9 is percussion in General MIDI: a melody sent there is a drum
    solo. Voices past the sixteen channels fold onto the last one, which is
    what a synthesiser with sixteen channels has to do.
    """
    var c = voice - 1
    if c < 0:
        c = 0
    if c >= 9:
        c += 1
    if c > 15:
        c = 15
    return c


def device_name() raises -> String:
    """The first output device's name, for the header line."""
    var midiOutGetNumDevs = win32[
        def () thin abi("C") -> UInt32, "midiOutGetNumDevs"
    ]()
    if midiOutGetNumDevs() == UInt32(0):
        return String("")
    var midiOutGetDevCapsW = win32[
        def (Int, Pointer[UInt8, MutAnyOrigin], UInt32) thin abi("C") -> UInt32,
        "midiOutGetDevCapsW",
    ]()
    var caps = List[UInt8](
        length=winkb_struct_size["MIDIOUTCAPSW"](), fill=0
    )
    var rc = midiOutGetDevCapsW(
        0,
        caps.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        UInt32(len(caps)),
    )
    if rc != UInt32(MMSYSERR_NOERROR):
        return String("")
    # szPname is 32 UTF-16 units at the offset the metadata records.
    var at = winkb_field_offset["MIDIOUTCAPSW", "szPname"]()
    var name = String("")
    for i in range(32):
        var lo = Int(caps[at + i * 2])
        var hi = Int(caps[at + i * 2 + 1])
        var unit = lo | (hi << 8)
        if unit == 0:
            break
        name += chr(unit)
    return name^


def us_per_quarter(tune: Tune) -> Int:
    """The tempo, in the units both the stream and a MIDI file want.

    Q: names a beat that is not necessarily a quarter note -- `Q:3/8=60` is a
    real marking -- so the bpm is converted against whatever note value it
    counts rather than assumed.
    """
    let per_beat_ticks = (
        TICKS_PER_QUARTER * 4 * tune.tempo_num
    ) // tune.tempo_den
    if tune.tempo_bpm > 0 and per_beat_ticks > 0:
        return (60000000 * TICKS_PER_QUARTER) // (
            tune.tempo_bpm * per_beat_ticks
        )
    return 500000


def open_stream(mut m: MidiOut) raises:
    """Open device 0 and set its time division. No tune yet."""
    comptime assert EVENT_STRIDE == 12, (
        "a short MIDIEVENT is three DWORDs; the metadata disagrees"
    )
    comptime assert (
        size_of[MIDIPROP]() == winkb_struct_size["MIDIPROPTIMEDIV"]()
        and size_of[MIDIPROP]() == winkb_struct_size["MIDIPROPTEMPO"]()
    ), "MIDIPROPTIMEDIV and MIDIPROPTEMPO are not the shape declared here"
    var midiOutGetNumDevs = win32[
        def () thin abi("C") -> UInt32, "midiOutGetNumDevs"
    ]()
    if midiOutGetNumDevs() == UInt32(0):
        raise Error("this machine has no MIDI output device")

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
    # dwCallback 0 with no CALLBACK_* flag is "tell me nothing": this player
    # asks the stream where it has got to rather than being told, so there is
    # no window, no thread and no callback to get wrong.
    var rc = midiStreamOpen(
        com_addr(handle), com_addr(device), UInt32(1), 0, 0, UInt32(0)
    )
    if rc != UInt32(MMSYSERR_NOERROR):
        raise Error("midiStreamOpen failed, mmsyserr = " + String(Int(rc)))
    m.stream = handle

    # The stream's tick is the model's tick. 480 per quarter note is what the
    # parser has counted in from the first bar, so nothing is converted and
    # nothing rounds.
    var midiStreamProperty = win32[
        def (Int, Pointer[MIDIPROP, MutAnyOrigin], UInt32) thin abi("C") -> UInt32,
        "midiStreamProperty",
    ]()
    var timediv = MIDIPROP()
    timediv.cbStruct = UInt32(size_of[MIDIPROP]())
    timediv.dwValue = UInt32(TICKS_PER_QUARTER)
    rc = midiStreamProperty(
        handle, com_addr(timediv), UInt32(MIDIPROP_SET | MIDIPROP_TIMEDIV)
    )
    if rc != UInt32(MMSYSERR_NOERROR):
        raise Error("could not set the stream's time division")
    _ = timediv


def set_tempo(m: MidiOut, us: Int) raises:
    var midiStreamProperty = win32[
        def (Int, Pointer[MIDIPROP, MutAnyOrigin], UInt32) thin abi("C") -> UInt32,
        "midiStreamProperty",
    ]()
    var tempo = MIDIPROP()
    tempo.cbStruct = UInt32(size_of[MIDIPROP]())
    tempo.dwValue = UInt32(us)
    _ = midiStreamProperty(
        m.stream, com_addr(tempo), UInt32(MIDIPROP_SET | MIDIPROP_TEMPO)
    )
    _ = tempo


def load(mut m: MidiOut, steps: List[Step], tune: Tune) raises -> Int:
    """Turn the schedule into a queued MIDI stream. Returns events queued.

    The same `List[Step]` the chip backend flattens into its own memory --
    same events, same order, same tie-break -- read through `tick` instead of
    through `sample`.
    """
    stop(m)
    set_tempo(m, us_per_quarter(tune))

    var count = 0
    for i in range(len(steps)):
        # A chip register change means nothing to a General MIDI synth: it is
        # an instruction to an oscillator this backend does not have. Dropped
        # rather than approximated, because there is no honest approximation.
        if steps[i].kind != SE_CHIP:
            count += 1
    if count == 0:
        return 0
    if count > EVENTS_PER_HEADER * MAX_HEADERS:
        count = EVENTS_PER_HEADER * MAX_HEADERS

    var total_bytes = count * EVENT_STRIDE
    var block = unsafe_alloc[UInt8](total_bytes, alignment=64)
    var base = Int(block)
    var last_tick = 0
    var written = 0
    var latest = 0
    for i in range(len(steps)):
        if written >= count:
            break
        if steps[i].kind == SE_CHIP:
            continue
        var tick = steps[i].tick
        if tick < last_tick:
            tick = last_tick        # the sort guarantees this, belt and braces
        var channel = channel_for(steps[i].voice)
        var status = 0x80 | channel
        var data2 = 0
        if steps[i].kind == SE_NOTE_ON:
            status = 0x90 | channel
            data2 = steps[i].velocity & 0x7F
        var at = base + written * EVENT_STRIDE
        poke32(at, 0, tick - last_tick)
        poke32(at, 4, 0)                       # dwStreamID, always 0
        # The high byte is the event type; the low three are the short
        # message, exactly as midiOutShortMsg would take it.
        poke32(
            at,
            8,
            (MEVT_SHORTMSG << 24)
            | status
            | ((steps[i].midi & 0x7F) << 8)
            | (data2 << 16),
        )
        last_tick = tick
        latest = tick
        written += 1

    m.events = base
    m.event_bytes = total_bytes
    m.total_ticks = latest + TICKS_PER_QUARTER * 2 if latest > 0 else 1

    # ── The headers ──────────────────────────────────────────────────────
    var hdr_size = winkb_struct_size["MIDIHDR"]()
    var headers = unsafe_alloc[UInt8](hdr_size * MAX_HEADERS, alignment=64)
    for i in range(hdr_size * MAX_HEADERS):
        headers[unsafe_offset=i] = UInt8(0)
    m.headers = Int(headers)

    var midiOutPrepareHeader = win32[
        def (Int, Int, UInt32) thin abi("C") -> UInt32, "midiOutPrepareHeader"
    ]()
    var midiStreamOut = win32[
        def (Int, Int, UInt32) thin abi("C") -> UInt32, "midiStreamOut"
    ]()

    var done = 0
    var nheaders = 0
    while done < written and nheaders < MAX_HEADERS:
        var chunk = written - done
        if chunk > EVENTS_PER_HEADER:
            chunk = EVENTS_PER_HEADER
        var h = m.headers + nheaders * hdr_size
        # Every field written at the offset the metadata records, into a block
        # that is only ever sized by the metadata. MIDIHDR is a box this code
        # does not look inside.
        poke64(h, winkb_field_offset["MIDIHDR", "lpData"](),
               base + done * EVENT_STRIDE)
        poke32(h, winkb_field_offset["MIDIHDR", "dwBufferLength"](),
               chunk * EVENT_STRIDE)
        poke32(h, winkb_field_offset["MIDIHDR", "dwBytesRecorded"](),
               chunk * EVENT_STRIDE)
        var rc = midiOutPrepareHeader(m.stream, h, UInt32(hdr_size))
        if rc != UInt32(MMSYSERR_NOERROR):
            raise Error("midiOutPrepareHeader failed: " + String(Int(rc)))
        rc = midiStreamOut(m.stream, h, UInt32(hdr_size))
        if rc != UInt32(MMSYSERR_NOERROR):
            raise Error("midiStreamOut failed: " + String(Int(rc)))
        done += chunk
        nheaders += 1
    m.header_count = nheaders

    var midiStreamRestart = win32[
        def (Int) thin abi("C") -> UInt32, "midiStreamRestart"
    ]()
    _ = midiStreamRestart(m.stream)
    m.playing = True
    m.paused = False
    return written


def short_msg(stream: Int, status: Int, data1: Int, data2: Int) raises:
    """One MIDI message, right now, on the stream's own handle.

    A stream is a queue of scheduled events; this is the other door into the
    same device, and it is what makes the drawn keyboard live in `--midi`. An
    HMIDISTRM is an HMIDIOUT as far as midiOutShortMsg is concerned, so a note
    played by hand lands between the tune's scheduled ones rather than needing
    a second device opened alongside.
    """
    if stream == 0:
        return
    var midiOutShortMsg = win32[
        def (Int, UInt32) thin abi("C") -> UInt32, "midiOutShortMsg"
    ]()
    _ = midiOutShortMsg(
        stream,
        UInt32(
            (status & 0xFF) | ((data1 & 0x7F) << 8) | ((data2 & 0x7F) << 16)
        ),
    )


def position_ticks(m: MidiOut) raises -> Int:
    """Where the driver has got to, in the model's own ticks."""
    if m.stream == 0 or not m.playing:
        return 0
    var midiStreamPosition = win32[
        def (Int, Pointer[UInt8, MutAnyOrigin], UInt32) thin abi("C") -> UInt32,
        "midiStreamPosition",
    ]()
    var mmtime = List[UInt8](length=winkb_struct_size["MMTIME"](), fill=0)
    var at = mmtime.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    # wType is in-out: it asks for ticks and the driver confirms what it gave.
    poke32(Int(at), winkb_field_offset["MMTIME", "wType"](), TIME_TICKS)
    var rc = midiStreamPosition(m.stream, at, UInt32(len(mmtime)))
    var value = 0
    if rc == UInt32(MMSYSERR_NOERROR):
        # The union follows wType; for TIME_TICKS its first word is the count.
        value = peek32(Int(at), winkb_field_offset["MMTIME", "u"]())
    _ = mmtime
    return value


def all_done(m: MidiOut) -> Bool:
    """Whether the driver has handed every queued header back."""
    if m.headers == 0 or m.header_count == 0:
        return False
    var hdr_size = winkb_struct_size["MIDIHDR"]()
    var flags_at = winkb_field_offset["MIDIHDR", "dwFlags"]()
    for i in range(m.header_count):
        var f = peek32(m.headers + i * hdr_size, flags_at)
        if (f & MHDR_DONE) == 0:
            return False
    return True


def replay(mut m: MidiOut) raises:
    """Queue the same headers again, which is how a tune loops here.

    A header the driver has finished with comes back marked MHDR_DONE, and it
    is still prepared -- so looping is clearing that one bit and handing the
    same memory over again. Nothing is reallocated and no event is rebuilt.
    """
    if m.stream == 0 or m.header_count == 0:
        return
    var hdr_size = winkb_struct_size["MIDIHDR"]()
    var flags_at = winkb_field_offset["MIDIHDR", "dwFlags"]()
    var midiStreamOut = win32[
        def (Int, Int, UInt32) thin abi("C") -> UInt32, "midiStreamOut"
    ]()
    for i in range(m.header_count):
        var h = m.headers + i * hdr_size
        poke32(h, flags_at, peek32(h, flags_at) & ~MHDR_DONE)
        _ = midiStreamOut(m.stream, h, UInt32(hdr_size))
    var midiStreamRestart = win32[
        def (Int) thin abi("C") -> UInt32, "midiStreamRestart"
    ]()
    _ = midiStreamRestart(m.stream)


def pause(mut m: MidiOut, on: Bool) raises:
    if m.stream == 0 or not m.playing:
        return
    if on:
        _ = win32[def (Int) thin abi("C") -> UInt32, "midiStreamPause"]()(
            m.stream
        )
    else:
        _ = win32[def (Int) thin abi("C") -> UInt32, "midiStreamRestart"]()(
            m.stream
        )
    m.paused = on


def stop(mut m: MidiOut) raises:
    """Stop, reset, unprepare and let go of the event memory.

    midiOutReset is not optional: it is what lifts every note the stream had
    sounding. Skip it and stopping a tune leaves whatever was down still
    ringing, which on a software synthesiser means forever.
    """
    if m.stream == 0:
        return
    if m.playing:
        _ = win32[def (Int) thin abi("C") -> UInt32, "midiStreamStop"]()(
            m.stream
        )
        _ = win32[def (Int) thin abi("C") -> UInt32, "midiOutReset"]()(
            m.stream
        )
    var hdr_size = winkb_struct_size["MIDIHDR"]()
    if m.headers != 0:
        var unprepare = win32[
            def (Int, Int, UInt32) thin abi("C") -> UInt32,
            "midiOutUnprepareHeader",
        ]()
        for i in range(m.header_count):
            _ = unprepare(m.stream, m.headers + i * hdr_size, UInt32(hdr_size))
        bytes_at(m.headers).unsafe_free()
        m.headers = 0
    m.header_count = 0
    if m.events != 0:
        bytes_at(m.events).unsafe_free()
        m.events = 0
    m.playing = False
    m.paused = False


def close(mut m: MidiOut) raises:
    stop(m)
    if m.stream != 0:
        _ = win32[def (Int) thin abi("C") -> UInt32, "midiStreamClose"]()(
            m.stream
        )
        m.stream = 0
