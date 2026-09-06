# ===----------------------------------------------------------------------=== #
# The noise the pane makes.
#
# TWO SOUND PATHS, and a game uses both without thinking about it:
#
#   THE CHIP  a hand-written 6581-flavoured synth -- three voices, ADSR, a
#             state-variable filter -- rendered into the WASAPI stream by a
#             dedicated thread. There are TWO of them: chip A carries the
#             music and chip B the effects, summed and halved into one mono
#             buffer, which is why a shot never cuts a tune. This is the path
#             the per-species motifs run on.
#
#   THE SYNTH the system General MIDI synthesiser, driven through
#             midiStreamOut. The chip ignores `%%MIDI program` because a chip
#             has no choir; this is the other answer to the same ABC, and it
#             is what makes a cue that says "program 52" actually a choir.
#
# The whole stack is the deleted pane's, brought across and repaired. Four
# defects were found in it by reading rather than by listening, and all four
# are fixed here -- each one is commented at the place it was:
#
#   * the trigger ring's write cursor shared a slot with voice 2's countdown,
#     so an effect playing made the ring stop firing;
#   * the mixing scratch was 4096 samples and the 90ms pre-roll asks for 4320
#     at 48kHz, so the very first fill overran it;
#   * CreateThread was declared with five parameters instead of six, leaving
#     kernel32 to read a garbage lpThreadId off the stack;
#   * the General MIDI player never sent a program change, so every cue
#     played on piano whatever its `%%MIDI program` line said.
#
# The sample rate is READ from the endpoint and never assumed, which the
# stdlib asks for in those words and the old code did not do.
# ===----------------------------------------------------------------------=== #

from .chip import (
    CLOCK_PAL,
    ENV_ATTACK,
    ENV_DECAY,
    ENV_IDLE,
    ENV_RELEASE,
    ENV_SUSTAIN,
    FILT_BP,
    FILT_HP,
    FILT_LP,
    FRAME_SAMPLES,
    P,
    PLAYER_BASE,
    PLAYER_SLOTS,
    SAMPLE_RATE,
    S_BAND,
    S_CUTOFF,
    S_DIRTY,
    S_F,
    S_FMODE,
    S_FRAME,
    S_LOW,
    S_Q,
    S_RES,
    S_TICK,
    S_VOL,
    TOTAL_SLOTS,
    Tick,
    V_ACC,
    V_AINC,
    V_BASE,
    V_DINC,
    V_ENV,
    V_FILT,
    V_GATE,
    V_LFSR,
    V_PHASE,
    V_PREV,
    V_PW,
    V_RINC,
    V_RING,
    V_STEP,
    V_STRIDE,
    V_SUS,
    V_SYNC,
    V_WAVE,
    WAVE_NOISE,
    WAVE_PULSE,
    WAVE_SAW,
    WAVE_TRI,
    chip_free,
    chip_new,
    chip_render,
    fget,
    fput,
    gate_off,
    gate_on,
    get,
    put,
    route_filter,
    set_adsr,
    set_filter,
    set_freq_hz,
    set_freq_reg,
    set_pulse_width,
    set_volume,
    set_wave,
    vget,
    vput,
)
from .sfx import (
    SFX_BANG,
    SFX_BLIP,
    SFX_BOSS_HUM,
    SFX_CLICK,
    SFX_COIN,
    SFX_COUNT,
    SFX_EXPLODE,
    SFX_HURT,
    SFX_JUMP,
    SFX_POWERUP,
    SFX_SAUCER,
    SFX_SHOOT,
    SFX_ZAP,
    sfx_frame,
    sfx_frames,
    sfx_name,
    sfx_start,
    sfx_stop,
)
from .voices import (
    Instrument,
    active_voices,
    allocate_voice,
    is_voice_active,
    midi_to_hz,
    note_off,
    note_on,
    set_instrument,
)
from .wav import WAV_HEADER_BYTES, read_wav, wav_bytes, write_wav
from .deck import (
    deck_free,
    deck_new,
    music_chip,
    pending_triggers,
    play_tune,
    set_muted,
    sfx_chip,
    sfx_play,
    start_audio,
    stop_audio,
    stop_tune,
)
from .midi import play_tune_gm, stop_tune_gm
