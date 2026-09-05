"""The platform-neutral surface. Nothing here may import a backend."""

from .input import (
    KEY_LEFT, KEY_RIGHT, KEY_DOWN, KEY_UP, KEY_SPACE, KEY_ESCAPE,
    KEY_A, KEY_S, KEY_D, KEY_W, KEY_Z, KEY_X, KEY_RETURN,
    KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6,
    MAX_KEY_CODE, MouseState, GamepadState,
)

from .shader import ShaderParams, SHADER_PARAM_COUNT, STARFIELD
from .direct import Palette, PALETTE_SIZE, stride_for, buffer_len_for

from .indexed import (
    Plane, NUM_BUFFERS, FRONT, BACK, TRANSPARENT, GLOBAL_COLORS, LINE_COLORS,
    palette_entries, palette_global_base, palette_line_entry,
    palette_global_entry, hsv_to_rgb, clamp_scroll,
)

from .blit import BlitRect, clip_blit, OP_AND, OP_OR, OP_XOR

from .sprites import (
    SpriteBitmap, SpriteInstance, parse_sprite_rows, sprites_overlap,
    quad_vertices, SPRITE_COLORS,
)

from .text import (
    RgbaCanvas, glyph_for, text_cols, text_rows,
    GLYPH_W, GLYPH_H, GLYPH_ADVANCE, CELL_W, CELL_H, CELL_BYTES,
    FLAG_TRANSPARENT_BG,
)

# The chip. Exported by name rather than with a star so the surface a game
# sees is a decision rather than an accident -- and so `audio.mojo` can keep
# its internal register slots internal.
from .audio import (
    P, CLOCK_PAL, SAMPLE_RATE, FRAME_SAMPLES,
    WAVE_TRI, WAVE_SAW, WAVE_PULSE, WAVE_NOISE,
    FILT_LP, FILT_BP, FILT_HP,
    ENV_IDLE, ENV_ATTACK, ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE,
    Tick, PLAYER_BASE, PLAYER_SLOTS, TOTAL_SLOTS,
    chip_new, chip_free, chip_render,
    set_freq_reg, set_freq_hz, set_pulse_width, set_wave, set_adsr,
    gate_on, gate_off, set_filter, route_filter, set_volume,
    get, put, fget, fput, vget, vput,
    V_BASE, V_STRIDE, V_ACC, V_STEP, V_PW, V_WAVE, V_GATE, V_ENV, V_PHASE,
    V_LFSR, V_RING, V_SYNC, V_FILT, V_PREV, V_AINC, V_DINC, V_SUS, V_RINC,
    S_TICK, S_CUTOFF, S_RES, S_FMODE, S_VOL, S_FRAME, S_DIRTY,
    S_LOW, S_BAND, S_F, S_Q,
)

from .sfx import (
    SFX_COUNT, SFX_COIN, SFX_JUMP, SFX_ZAP, SFX_SHOOT, SFX_EXPLODE,
    SFX_POWERUP, SFX_HURT, SFX_CLICK, SFX_BANG, SFX_BLIP, SFX_SAUCER,
    SFX_BOSS_HUM, sfx_name, sfx_frames, sfx_start, sfx_frame, sfx_stop,
)

from .voices import (
    Instrument, midi_to_hz, set_instrument, note_on, note_off,
    is_voice_active, active_voices, allocate_voice,
)
from .wav import wav_bytes, write_wav, read_wav, WAV_HEADER_BYTES

from .particles import (
    particle_colour, burst_velocity, PARTICLE_COLOURS_PER_DEF,
)
