"""A voice bank over the chip: notes in, registers out.

The chip speaks in frequency registers and gate bits. A game speaks in
notes. This is the two-hundred-line gap between them, and it is deliberately
thin -- an instrument is a handful of register values, not an object, and
`note_on` is a pitch calculation and four register writes.

`is_voice_active` asks the ENVELOPE, not the gate: a voice whose gate went
low is still sounding through its release, and a bank that reported it idle
would let a game steal it mid-decay. That is the whole reason this function
exists rather than a `gate` flag.
"""

from .audio import (
    P, vget, set_freq_hz, set_pulse_width, set_wave, set_adsr,
    gate_on, gate_off, route_filter,
    V_ENV, V_GATE, WAVE_PULSE,
)


comptime MIDI_A4 = 69
comptime FREQ_A4 = 440.0


def midi_to_hz(midi: Int) -> Float64:
    """Equal temperament from A4 = 440. The chip's own frequency register is
    quantised, so the last few cents vanish anyway -- but they vanish the
    same way a real one's did."""
    var n = midi
    if n < 0:
        n = 0
    elif n > 127:
        n = 127
    var hz = FREQ_A4
    let steps = n - MIDI_A4
    # Repeated multiplication by the twelfth root of two, rather than a
    # power function: the chip's own tuning came out of a table and this
    # keeps the arithmetic as plain.
    let semitone = 1.0594630943592953
    if steps >= 0:
        for _ in range(steps):
            hz *= semitone
    else:
        for _ in range(-steps):
            hz /= semitone
    return hz


@fieldwise_init
struct Instrument(Copyable, Movable):
    """One voice's settings. Everything a note needs except its pitch."""

    var wave: Int
    var pulse_width: Int
    var attack: Int
    var decay: Int
    var sustain: Int
    var release: Int
    var filtered: Bool

    def __init__(out self, wave: Int):
        self.wave = wave
        self.pulse_width = 0x800
        self.attack = 0
        self.decay = 6
        self.sustain = 10
        self.release = 6
        self.filtered = False


def set_instrument(st: P, voice: Int, inst: Instrument) raises:
    """Load an instrument into a voice. Does not gate it."""
    set_wave(st, voice, inst.wave)
    set_pulse_width(st, voice, inst.pulse_width)
    set_adsr(st, voice, inst.attack, inst.decay, inst.sustain, inst.release)
    route_filter(st, voice, inst.filtered)


def note_on(st: P, voice: Int, midi: Int) raises:
    set_freq_hz(st, voice, midi_to_hz(midi))
    gate_on(st, voice)


def note_off(st: P, voice: Int) raises:
    gate_off(st, voice)


def is_voice_active(st: P, voice: Int) -> Bool:
    """Is this voice making a sound?

    The ENVELOPE, not the gate. A released voice is still sounding while its
    envelope falls, and a bank that reported it idle would let a game steal
    a note in the middle of its decay -- which is exactly the click a
    polyphonic allocator is supposed to avoid.
    """
    if voice < 0 or voice > 2:
        return False
    return vget(st, voice=voice, field=V_ENV) > 0


def active_voices(st: P) -> Int:
    var n = 0
    for v in range(3):
        if is_voice_active(st, v):
            n += 1
    return n


def allocate_voice(st: P) -> Int:
    """The first idle voice, or -1. A game that wants stealing policy can
    write its own; this one refuses rather than interrupting."""
    for v in range(3):
        if not is_voice_active(st, v):
            return v
    return -1
