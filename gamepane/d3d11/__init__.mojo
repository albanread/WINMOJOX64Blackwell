"""The Direct3D 11 backend -- the only gamepane tier that touches a
window, a swap chain, or the display.

The same surface `gamepane.metal` exports on the Cocoa port, with the
platform's answers in place of Metal's: a flip-model swap chain for the
CAMetalLayer, HLSL for MSL, device-mapped pinned allocations for unified
memory, and one `UpdateSubresource` per pane per frame for the linear
texture view. Games written against `gamepane.api` do not change.
"""

from .window import (
    GamePane, Frame, key_held, mouse_state, clear_input, any_key_held,
)
from .layers import (
    ShaderPane, DirectPane, IndexedPane,
    SHADER_HEADER, DIRECT_SHADER, INDEXED_SHADER,
)
from .sprites import Sprites, SpriteDef, SPRITE_VERTEX, SPRITE_PIXEL
from .text import TextOverlay, TEXT_VERTEX, TEXT_PIXEL
from .particles import ParticleField, particles_step_kernel
from .blitter import (
    blit_copy_kernel, blit_transparent_kernel, blit_minterm_kernel,
    blit_fill_kernel, blit_grid, BLOCK, Blitter,
)
from .device import device_ptr, host_ptr
from .midiplay import play_tune_gm, stop_tune_gm
from .audio import (
    deck_new, deck_free, music_chip, sfx_chip, set_muted, set_music_tick,
    play_tune, stop_tune, sfx_play,
    pending_triggers, dropped_triggers, drain_triggers, advance_effects,
    start_audio, stop_audio, RING_SIZE, MAX_BUFFER,
)
