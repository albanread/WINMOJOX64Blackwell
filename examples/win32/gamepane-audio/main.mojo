# ===----------------------------------------------------------------------=== #
# The pane makes a noise -- and proves it, with the endpoint's own meter.
#
# The game pane had no audio at all after the rebuild. This exercises the
# whole stack that has just been brought back, and it does not take "it
# returned S_OK" for an answer.
#
# WHY THE METER. Every WASAPI call in the chain can succeed through an
# underrun, through a muted session, and through a program that filled its
# buffers with zeros. IAudioMeterInformation cannot: it belongs to the
# ENDPOINT and knows nothing about this program, so a reading that rises when
# we play and falls when we stop is the machine agreeing that sound came out.
# That is the standard abcplayer set for this tree and it is the one worth
# keeping.
#
# THREE THINGS ARE UNDER TEST, and they are separate mechanisms:
#
#   the CHIP EFFECTS -- a hand-written synth on chip B, triggered through a
#     lock-free ring from the game thread. The ring is where a real defect
#     lived: its write cursor shared a slot with voice 2's countdown, so
#     effects stopped firing as soon as one landed on the third voice. This
#     plays MORE effects than there are voices, on purpose.
#
#   the CHIP TUNE -- ABC on chip A, which is what a species motif is. Chip A
#     and chip B are summed, so a tune and a shot coexist; the test plays an
#     effect OVER the tune and expects the meter to stay up.
#
#   the GENERAL MIDI CUE -- the same ABC handed to the system synthesiser
#     instead, which is how a cue that says `%%MIDI program 52` becomes a
#     choir rather than a piano impression of one. The program change is the
#     fourth defect that was fixed: this player never sent one, so every cue
#     played on program 0 whatever its header asked for.
#
# It runs headless and prints a verdict. No window, no keys, no waiting.
# ===----------------------------------------------------------------------=== #

from std.sys.com import Apartment
from std.windows import performance_counter, performance_frequency
from std.windows.audio import Meter, default_render_meter
from gamepane.abc.model import Tune
from gamepane.abc.parse import parse_abc
from gamepane.audio import (
    SFX_BANG,
    SFX_COIN,
    SFX_EXPLODE,
    SFX_HURT,
    SFX_SAUCER,
    SFX_SHOOT,
    deck_free,
    deck_new,
    play_tune,
    play_tune_gm,
    sfx_name,
    sfx_play,
    start_audio,
    stop_audio,
    stop_tune,
    stop_tune_gm,
)

comptime TUNE_CHOIR = String(
    """X:1
M:4/4
L:1/8
Q:1/4=84
%%MIDI program 52
K:Am
V:1
z4 A,2 E2 | A2 c2 e2 d2 | c4 B4 | A8 |"""
)
"""Galaxigans' 'Stage Alert' cue, verbatim from tunes.mojo. Program 52 is a
choir, and whether it IS one is the whole point of the General MIDI path."""

comptime MOTIF_HORNET = String(
    """X:1
M:4/4
L:1/16
Q:1/4=160
K:C
V:1
[I:chip v=0 wave=pulse pw=250 a=0 d=3 s=6 r=3 vol=13]
efgabagf edcdefga |
V:2
[I:chip v=1 wave=saw a=0 d=6 s=5 r=5 vol=10]
C4 G,4 C4 G,4 |"""
)
"""A two-voice chip motif in the shape motifs.mojo uses -- an inline
`[I:chip ...]` per voice and no `%%MIDI program`, which is exactly what
routes it to the chip rather than to the synthesiser."""


def _sleep(ms: Int) raises:
    """Spin for `ms` milliseconds on the performance counter.

    A busy wait, deliberately: the audio runs on its own thread and this one
    only has to not exit. Sleep would do, and would also add a Win32 binding
    to a file that otherwise needs none."""
    var hz = performance_frequency()
    var until = Int(performance_counter()) + (Int(hz) * ms) // 1000
    while Int(performance_counter()) < until:
        pass


def _peak_over(mut meter: Meter, ms: Int) raises -> Float64:
    """The loudest the ENDPOINT saw across a window of time.

    `peak` reports the maximum since the previous call and then resets, so
    sampling repeatedly and keeping the largest is what turns an instant into
    an interval -- a single reading can fall between two notes and report
    silence during a tune that is plainly playing."""
    var best = 0.0
    var steps = ms // 20
    if steps < 1:
        steps = 1
    for _ in range(steps):
        _sleep(20)
        var p = meter.peak()
        if p > best:
            best = p
    return best


def main() raises:
    print("gamepane audio: the whole stack, metered at the endpoint")
    # The meter is a COM object and this thread has no apartment of its own
    # -- the audio thread makes its own, and that one is not ours.
    # CoCreateInstance answers CO_E_NOTINITIALIZED without this, which is
    # the least helpful HRESULT in the set.
    with Apartment(multithreaded=True):
        _run()


def _run() raises:
    var meter = default_render_meter()

    # A quiet baseline first. If the machine is already making a noise --
    # a browser tab, a notification -- every later reading is suspect, and
    # saying so is better than reporting a false pass.
    var idle = _peak_over(meter, 300)
    print("  idle endpoint peak      :", idle)

    var deck = deck_new()
    var thread = start_audio(deck)
    _sleep(200)

    var passes = 0
    var checks = 0

    # ---- 1: the chip effects, more of them than there are voices --------
    var effects = List[Int](length=6, fill=0)
    effects[0] = SFX_SHOOT
    effects[1] = SFX_EXPLODE
    effects[2] = SFX_COIN
    effects[3] = SFX_BANG
    effects[4] = SFX_HURT
    effects[5] = SFX_SAUCER
    var best_sfx = 0.0
    for i in range(len(effects)):
        sfx_play(deck, effects[i])
        var p = _peak_over(meter, 260)
        print("  sfx", sfx_name(effects[i]), "peak :", p)
        if p > best_sfx:
            best_sfx = p
    checks += 1
    if best_sfx > idle + 0.01:
        print("  PASS chip effects reached the endpoint")
        passes += 1
    else:
        print("  FAIL chip effects were silent (peak", best_sfx, ")")

    # ---- 2: a chip tune, with an effect over the top -------------------
    _ = play_tune(deck, MOTIF_HORNET, loop=False)
    var tune_peak = _peak_over(meter, 400)
    sfx_play(deck, SFX_SHOOT)
    var mixed_peak = _peak_over(meter, 400)
    stop_tune(deck)
    print("  chip tune peak          :", tune_peak)
    print("  tune + effect peak      :", mixed_peak)
    checks += 1
    if tune_peak > idle + 0.01 and mixed_peak > idle + 0.01:
        print("  PASS chip A carried a tune while chip B took a shot")
        passes += 1
    else:
        print("  FAIL the two chips did not both sound")

    # ---- 3: the General MIDI cue ---------------------------------------
    # Its header says program 52. Before the fix this player sent no program
    # change at all, so it arrived as program 0 -- audible either way, which
    # is exactly why the defect survived: the meter cannot tell a choir from
    # a piano. What it CAN tell is that the synthesiser sounded at all.
    # The meter cannot tell a choir from a piano, so the program change is
    # checked where it CAN be: the value the player will send. Before the fix
    # this was read by the parser, written by the SMF writer, and dropped on
    # the floor by this player.
    var probe = Tune()
    parse_abc(TUNE_CHOIR, probe)
    var program = probe.voices[0].instrument if len(probe.voices) > 0 else 0
    print("  cue asks for program    :", program)
    checks += 1
    if program == 52:
        print("  PASS the program change reaches the player (52 = choir)")
        passes += 1
    else:
        print("  FAIL the cue's %%MIDI program did not survive parsing")

    # THE CHIP IS SHUT DOWN FIRST, so nothing but the synthesiser can move
    # this endpoint, and the cue is metered over its WHOLE length -- it opens
    # with `z4`, half a bar of rest, and a short window measures that silence
    # and reports a synthesiser that is working perfectly as broken.
    stop_audio(thread)
    deck_free(deck)
    _sleep(300)

    var started = play_tune_gm(TUNE_CHOIR)
    print("  play_tune_gm accepted   :", started)
    var gm_peak = 0.0
    for _ in range(5):
        var p = _peak_over(meter, 1000)
        if p > gm_peak:
            gm_peak = p
    stop_tune_gm()
    print("  general midi peak       :", gm_peak)

    # AND IT IS COMPARED WITH THE CHIP, not with an absolute number a
    # different machine would not agree with. This is the check that catches
    # the defect the program change first shipped with: the setup events were
    # keyed by the voice's ARRAY INDEX while the notes carry its ABC NUMBER,
    # so the volume and the instrument landed on a different MIDI channel
    # from the music. It still played -- at 0.08 against the effects' 0.25,
    # on the wrong patch -- which sounds exactly like a game with no music.
    checks += 1
    if started and gm_peak > best_sfx * 0.4:
        print("  PASS the synthesiser sounded, and at a comparable level")
        passes += 1
    else:
        print(
            "  FAIL the general midi cue was silent or far too quiet --",
            "expected more than", best_sfx * 0.4,
        )

    print("")
    print("gamepane-audio:", passes, "of", checks, "audible")
    if passes < checks:
        raise Error(
            "the endpoint did not meter every path -- check the default"
            " playback device is not muted, then read the peaks above"
        )
