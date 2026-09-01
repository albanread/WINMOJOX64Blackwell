# Standard MIDI File output.
#
# This is the unglamorous half, and it is also the half that proves the model
# is right. A MIDI file is a public format with other readers: if the tune
# opens in a notation program with the right pitches, the right lengths and
# the bar lines in the right places, then the parser and the tick arithmetic
# are correct, and no amount of listening to a synthesiser could establish
# the same thing.
#
# The tick resolution is already MIDI's own -- 480 per quarter note -- so
# durations transfer with no conversion and no rounding. That is not a
# coincidence; it is why 480 was chosen in the model.

from std.ffi import c_int
from std.memory import Pointer, MutUntrackedOrigin
from std.sys._com import com_addr
from std.sys._winkb import winkb_constant

from model import (
    Tune, Event, EV_NOTE, TICKS_PER_QUARTER, F_GCHORD,
)
from win32 import win32, wide_of


def put_byte(mut buf: List[UInt8], value: Int):
    buf.append(UInt8(value & 0xFF))


def put_u16(mut buf: List[UInt8], value: Int):
    put_byte(buf, value >> 8)
    put_byte(buf, value)


def put_u32(mut buf: List[UInt8], value: Int):
    put_byte(buf, value >> 24)
    put_byte(buf, value >> 16)
    put_byte(buf, value >> 8)
    put_byte(buf, value)


def put_varlen(mut buf: List[UInt8], value: Int):
    """MIDI's variable-length quantity: seven bits a byte, high bit as "more".

    Written back to front into a small stack, because the encoding produces
    the least significant group first and the file wants the most significant.
    """
    var v = value
    if v < 0:
        v = 0
    var stack = List[Int]()
    stack.append(v & 0x7F)
    v = v >> 7
    while v > 0:
        stack.append((v & 0x7F) | 0x80)
        v = v >> 7
    for i in range(len(stack)):
        put_byte(buf, stack[len(stack) - 1 - i])


def put_text(mut buf: List[UInt8], text: String):
    let b = text.as_bytes()
    for i in range(len(b)):
        buf.append(b[i])


def channel_for(index: Int) -> Int:
    """Voices get channels in order, skipping 9 -- which is percussion, and
    would turn a melody into a drum solo."""
    var c = index
    if c >= 9:
        c += 1
    if c > 15:
        c = 15
    return c


def build_midi(tune: Tune, mut out: List[UInt8]):
    """A format 1 file: a tempo track, then one track per voice."""
    var tracks = 1 + len(tune.voices)

    put_text(out, String("MThd"))
    put_u32(out, 6)
    put_u16(out, 1)                      # format 1
    put_u16(out, tracks)
    put_u16(out, TICKS_PER_QUARTER)

    # ── Track 0: the tempo map ──────────────────────────────────────────────
    var head = List[UInt8]()
    if len(tune.title.as_bytes()) > 0:
        put_varlen(head, 0)
        put_byte(head, 0xFF)
        put_byte(head, 0x03)             # sequence/track name
        put_varlen(head, len(tune.title.as_bytes()))
        put_text(head, tune.title)
    # Microseconds per quarter note. The tempo is given against whatever note
    # value Q: named, so it is converted to a quarter here.
    let per_beat_ticks = (TICKS_PER_QUARTER * 4 * tune.tempo_num) // tune.tempo_den
    var us_per_quarter = 500000
    if tune.tempo_bpm > 0 and per_beat_ticks > 0:
        us_per_quarter = (
            60000000 * TICKS_PER_QUARTER
        ) // (tune.tempo_bpm * per_beat_ticks)
    put_varlen(head, 0)
    put_byte(head, 0xFF)
    put_byte(head, 0x51)
    put_byte(head, 0x03)
    put_byte(head, us_per_quarter >> 16)
    put_byte(head, us_per_quarter >> 8)
    put_byte(head, us_per_quarter)
    put_varlen(head, 0)
    put_byte(head, 0xFF)
    put_byte(head, 0x2F)                 # end of track
    put_byte(head, 0x00)

    put_text(out, String("MTrk"))
    put_u32(out, len(head))
    for i in range(len(head)):
        out.append(head[i])

    # ── One track per voice ─────────────────────────────────────────────────
    for vi in range(len(tune.voices)):
        let voice = tune.voices[vi].number
        let channel = channel_for(vi)
        var body = List[UInt8]()

        if len(tune.voices[vi].name.as_bytes()) > 0:
            put_varlen(body, 0)
            put_byte(body, 0xFF)
            put_byte(body, 0x03)
            put_varlen(body, len(tune.voices[vi].name.as_bytes()))
            put_text(body, tune.voices[vi].name)

        put_varlen(body, 0)
        put_byte(body, 0xC0 | channel)   # program change
        put_byte(body, tune.voices[vi].instrument)

        # Note on and off, interleaved in time order. Gathering them into one
        # list and sorting is what keeps a chord's members from being written
        # as three separate overlapping runs.
        var times = List[Int]()
        var kinds = List[Int]()
        var notes = List[Int]()
        var vels = List[Int]()
        for i in range(len(tune.events)):
            let ev = tune.events[i]
            if ev.kind != EV_NOTE or ev.voice != voice or ev.velocity <= 0:
                continue
            times.append(ev.tick)
            kinds.append(1)
            notes.append(ev.midi)
            vels.append(ev.velocity)
            times.append(ev.tick + ev.duration)
            kinds.append(0)
            notes.append(ev.midi)
            vels.append(0)

        # Insertion sort by time, offs first at equal times. The lists are one
        # voice's worth of notes, and they arrive nearly sorted already.
        for a in range(1, len(times)):
            # `var`, not `let`. A `let` here names the list slot rather than
            # copying out of it, and the shifting loop below writes over that
            # very slot -- so the value being placed changes underneath the
            # comparison and the sort quietly loses entries.
            var t = times[a]
            var k = kinds[a]
            var nn = notes[a]
            var vv = vels[a]
            var b = a - 1
            while b >= 0 and (
                times[b] > t or (times[b] == t and kinds[b] > k)
            ):
                times[b + 1] = times[b]
                kinds[b + 1] = kinds[b]
                notes[b + 1] = notes[b]
                vels[b + 1] = vels[b]
                b -= 1
            times[b + 1] = t
            kinds[b + 1] = k
            notes[b + 1] = nn
            vels[b + 1] = vv

        var last_tick = 0
        for i in range(len(times)):
            put_varlen(body, times[i] - last_tick)
            last_tick = times[i]
            if kinds[i] == 1:
                put_byte(body, 0x90 | channel)
                put_byte(body, notes[i])
                put_byte(body, vels[i])
            else:
                put_byte(body, 0x80 | channel)
                put_byte(body, notes[i])
                put_byte(body, 0)

        put_varlen(body, 0)
        put_byte(body, 0xFF)
        put_byte(body, 0x2F)
        put_byte(body, 0x00)

        put_text(out, String("MTrk"))
        put_u32(out, len(body))
        for i in range(len(body)):
            out.append(body[i])


def write_midi(tune: Tune, path: String) raises -> Bool:
    """Write the tune to a .mid file. Returns whether it got there.

    CreateFileW and WriteFile rather than the C runtime's fopen: a MIDI file
    is bytes, and Windows' own file API has no text mode to forget to turn
    off. An `fopen` without the "b" would translate every 0x0A in a delta
    time into a carriage return and a line feed, and the file would open in a
    notation program as garbage from the first bar that lasted ten ticks.
    """
    var bytes = List[UInt8]()
    build_midi(tune, bytes)
    if len(bytes) == 0:
        return False

    var CreateFileW = win32[
        def (
            Pointer[UInt16, MutAnyOrigin],
            UInt32, UInt32, Int, UInt32, UInt32, Int,
        ) thin abi("C") -> Int,
        "CreateFileW",
    ]()
    var WriteFile = win32[
        def (
            Int, Pointer[UInt8, MutAnyOrigin], UInt32,
            Pointer[UInt32, MutAnyOrigin], Int,
        ) thin abi("C") -> c_int,
        "WriteFile",
    ]()
    var CloseHandle = win32[def (Int) thin abi("C") -> c_int, "CloseHandle"]()

    var wpath = wide_of(path)
    var handle = CreateFileW(
        wpath.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        UInt32(winkb_constant["GENERIC_WRITE"]()),
        UInt32(0),
        0,
        UInt32(winkb_constant["CREATE_ALWAYS"]()),
        UInt32(winkb_constant["FILE_ATTRIBUTE_NORMAL"]()),
        0,
    )
    _ = wpath
    # INVALID_HANDLE_VALUE is -1, not 0: a zero test here reports success on
    # every path that does not exist.
    if handle == 0 or handle == -1:
        return False

    var written = UInt32(0)
    var ok = WriteFile(
        handle,
        bytes.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        UInt32(len(bytes)),
        com_addr(written),
        0,
    )
    _ = CloseHandle(handle)
    return ok != c_int(0) and Int(written) == len(bytes)
