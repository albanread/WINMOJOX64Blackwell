"""The twelve effects, as chip recipes -- and nothing that knows about an
audio device.

Each effect is a small program for one chip voice: a waveform, an ADSR, a
starting pitch, and a per-frame routine that runs at 50 Hz on the chip's own
player hook. That is how these sounded on the machines they come from: the
sweep in a laser is the pitch register being written every raster frame, not
an envelope on a filter.

Indices 0..11, matching the Rust's `play_sound(preset)`. An index outside
that range is a short click rather than a trap -- a game that computes an
effect number and gets it wrong should make a noise, not stop.
"""

from .audio import (
    P, vput, vget, put, get,
    WAVE_TRI, WAVE_SAW, WAVE_PULSE, WAVE_NOISE,
    FILT_LP, FILT_BP, FILT_HP,
    set_freq_hz, set_pulse_width, set_wave, set_adsr, gate_on, gate_off,
    set_filter, route_filter,
    V_BASE, V_STRIDE,
)


comptime SFX_COUNT = 12

comptime SFX_COIN = 0
comptime SFX_JUMP = 1
comptime SFX_ZAP = 2
comptime SFX_SHOOT = 3
comptime SFX_EXPLODE = 4
comptime SFX_POWERUP = 5
comptime SFX_HURT = 6
comptime SFX_CLICK = 7
comptime SFX_BANG = 8
comptime SFX_BLIP = 9
comptime SFX_SAUCER = 10
comptime SFX_BOSS_HUM = 11


def sfx_name(index: Int) -> String:
    if index == 0: return String("coin")
    if index == 1: return String("jump")
    if index == 2: return String("zap")
    if index == 3: return String("shoot")
    if index == 4: return String("explode")
    if index == 5: return String("powerup")
    if index == 6: return String("hurt")
    if index == 7: return String("click")
    if index == 8: return String("bang")
    if index == 9: return String("blip")
    if index == 10: return String("saucer")
    if index == 11: return String("boss_hum")
    return String("click")


def sfx_frames(index: Int) -> Int:
    """How many 50 Hz frames the effect lasts, after which the voice gates
    off. A held effect -- `saucer`, `boss_hum` -- still ends: a game that
    wants a drone loops it, rather than relying on a note that never
    stops."""
    if index == SFX_COIN: return 12
    if index == SFX_JUMP: return 14
    if index == SFX_ZAP: return 12
    if index == SFX_SHOOT: return 8
    if index == SFX_EXPLODE: return 30
    if index == SFX_POWERUP: return 22
    if index == SFX_HURT: return 16
    if index == SFX_CLICK: return 3
    if index == SFX_BANG: return 20
    if index == SFX_BLIP: return 5
    if index == SFX_SAUCER: return 40
    if index == SFX_BOSS_HUM: return 45
    return 3


def sfx_start(st: P, voice: Int, index: Int) raises:
    """Set the voice up and gate it on. The per-frame movement is
    `sfx_frame` below; this is only the note-on."""
    var i = index
    if i < 0 or i >= SFX_COUNT:
        i = SFX_CLICK

    route_filter(st, voice, False)

    if i == SFX_COIN:
        # Two pulses a fifth apart: the second arrives at frame 4.
        set_wave(st, voice, WAVE_PULSE)
        set_pulse_width(st, voice, 0x600)
        set_adsr(st, voice, 0, 6, 0, 4)
        set_freq_hz(st, voice, 988.0)
    elif i == SFX_JUMP:
        set_wave(st, voice, WAVE_PULSE)
        set_pulse_width(st, voice, 0x400)
        set_adsr(st, voice, 0, 8, 8, 6)
        set_freq_hz(st, voice, 220.0)
    elif i == SFX_ZAP:
        set_wave(st, voice, WAVE_SAW)
        set_adsr(st, voice, 0, 5, 4, 4)
        set_freq_hz(st, voice, 1760.0)
    elif i == SFX_SHOOT:
        set_wave(st, voice, WAVE_SAW | WAVE_NOISE)
        set_adsr(st, voice, 0, 4, 0, 3)
        set_freq_hz(st, voice, 1200.0)
    elif i == SFX_EXPLODE:
        set_wave(st, voice, WAVE_NOISE)
        set_adsr(st, voice, 0, 12, 6, 10)
        set_freq_hz(st, voice, 900.0)
        route_filter(st, voice, True)
        set_filter(st, 2047, 4, FILT_LP)
    elif i == SFX_POWERUP:
        set_wave(st, voice, WAVE_PULSE)
        set_pulse_width(st, voice, 0x800)
        set_adsr(st, voice, 1, 6, 10, 6)
        set_freq_hz(st, voice, 262.0)
    elif i == SFX_HURT:
        set_wave(st, voice, WAVE_SAW | WAVE_NOISE)
        set_adsr(st, voice, 0, 8, 4, 6)
        set_freq_hz(st, voice, 330.0)
    elif i == SFX_CLICK:
        set_wave(st, voice, WAVE_NOISE)
        set_adsr(st, voice, 0, 2, 0, 2)
        set_freq_hz(st, voice, 3000.0)
    elif i == SFX_BANG:
        set_wave(st, voice, WAVE_NOISE)
        set_adsr(st, voice, 0, 9, 3, 9)
        set_freq_hz(st, voice, 1500.0)
        route_filter(st, voice, True)
        set_filter(st, 1400, 8, FILT_LP)
    elif i == SFX_BLIP:
        set_wave(st, voice, WAVE_TRI)
        set_adsr(st, voice, 0, 3, 0, 2)
        set_freq_hz(st, voice, 1320.0)
    elif i == SFX_SAUCER:
        # The warble IS the beat between two voices 6 Hz apart. This gates
        # the neighbouring voice too, which is why saucer and boss_hum are
        # the two effects that take two.
        set_wave(st, voice, WAVE_TRI)
        set_adsr(st, voice, 2, 0, 15, 8)
        set_freq_hz(st, voice, 600.0)
        let other = (voice + 1) % 3
        set_wave(st, other, WAVE_TRI)
        set_adsr(st, other, 2, 0, 15, 8)
        set_freq_hz(st, other, 606.0)
        gate_on(st, other)
    elif i == SFX_BOSS_HUM:
        set_wave(st, voice, WAVE_PULSE)
        set_pulse_width(st, voice, 0x800)
        set_adsr(st, voice, 3, 0, 15, 9)
        set_freq_hz(st, voice, 110.0)
        let other = (voice + 1) % 3
        set_wave(st, other, WAVE_PULSE)
        set_pulse_width(st, other, 0x800)
        set_adsr(st, other, 3, 0, 15, 9)
        set_freq_hz(st, other, 114.0)
        gate_on(st, other)

    gate_on(st, voice)


def sfx_frame(st: P, voice: Int, index: Int, frame: Int) raises:
    """One 50 Hz frame of the effect's movement, `frame` counting from 0.

    This is the part that makes these sound like a chip rather than like
    samples: the pitch register is written every frame, so a sweep is a
    staircase at 50 Hz and audibly so.
    """
    var i = index
    if i < 0 or i >= SFX_COUNT:
        i = SFX_CLICK
    let f = Float64(frame)

    if i == SFX_COIN:
        # A fifth up at frame 4, and hold.
        if frame == 4:
            set_freq_hz(st, voice, 1480.0)
    elif i == SFX_JUMP:
        set_freq_hz(st, voice, 220.0 + f * 55.0)
    elif i == SFX_ZAP:
        set_freq_hz(st, voice, 1760.0 - f * 120.0)
    elif i == SFX_SHOOT:
        set_freq_hz(st, voice, 1200.0 - f * 110.0)
    elif i == SFX_EXPLODE:
        set_freq_hz(st, voice, 900.0 - f * 25.0)
        var c = 2047 - frame * 60
        if c < 120:
            c = 120
        set_filter(st, c, 4, FILT_LP)
    elif i == SFX_POWERUP:
        set_freq_hz(st, voice, 262.0 * (1.0 + f * 0.10))
    elif i == SFX_HURT:
        set_freq_hz(st, voice, 330.0 - f * 14.0)
    elif i == SFX_BANG:
        set_freq_hz(st, voice, 1500.0 - f * 60.0)
        var c2 = 1400 - frame * 55
        if c2 < 100:
            c2 = 100
        set_filter(st, c2, 8, FILT_LP)
    elif i == SFX_BLIP:
        set_freq_hz(st, voice, 1320.0 + f * 90.0)
    # coin's second pulse, saucer's beat and boss_hum's beat need nothing
    # per frame: the detune does the work.


def sfx_stop(st: P, voice: Int, index: Int) raises:
    """Gate the effect off, including the partner voice the two-voice
    effects borrowed."""
    gate_off(st, voice)
    if index == SFX_SAUCER or index == SFX_BOSS_HUM:
        gate_off(st, (voice + 1) % 3)
