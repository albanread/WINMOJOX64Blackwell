# ===----------------------------------------------------------------------=== #
# The game pane: a palette-indexed retro canvas on Direct3D 11.
#
# Ported from RASM's `gpu/` library, which is the working implementation of
# this design and the thing to check against when something looks wrong. The
# layering is the reference's:
#
#   G0  canvas   the index plane, the two palettes, the resolve pass   <- here
#   G1  blit     the alpha blend state
#   G2  tile     a parallax tile background
#   G3  sprite   the sprite atlas and the INSTANCED sprite pass
#   G5  text
#
# Only G0 is here so far, and it is proven on screen before the next layer
# starts. The previous port built all of it at once and none of it drew.
#
# Two rules carried from the reference, both of which the previous port
# broke and neither of which is negotiable:
#
#   * every device resource is created ONCE, in an init path. A view built
#     at bind time is what emptied a driver's memory.
#   * the rasterizer state is bound every frame, FILL_SOLID + CULL_NONE.
#     D3D11's default culls back faces and a full-screen triangle has no
#     face worth culling; leaving the default in place makes "does anything
#     draw" depend on a winding nobody wrote down.
# ===----------------------------------------------------------------------=== #

from .canvas import (
    CANVAS_H,
    CANVAS_W,
    GpuCanvas,
    PAL_GLOBAL,
    PAL_LINE,
)
from .keys import (
    ACT_COUNT,
    ACT_DOWN,
    ACT_FIRE,
    ACT_LEFT,
    ACT_PAUSE,
    ACT_QUIT,
    ACT_RESTART,
    ACT_RIGHT,
    ACT_UP,
    KEY_0,
    KEY_1,
    KEY_2,
    KEY_3,
    KEY_4,
    KEY_5,
    KEY_6,
    KEY_7,
    KEY_8,
    KEY_9,
    KEY_A,
    KEY_B,
    KEY_BACK,
    KEY_C,
    KEY_CONTROL,
    KEY_COUNT,
    KEY_D,
    KEY_DOWN,
    KEY_E,
    KEY_ESCAPE,
    KEY_F,
    KEY_F1,
    KEY_F2,
    KEY_F3,
    KEY_F4,
    KEY_F5,
    KEY_F6,
    KEY_F7,
    KEY_F8,
    KEY_F9,
    KEY_F10,
    KEY_F11,
    KEY_F12,
    KEY_G,
    KEY_H,
    KEY_I,
    KEY_J,
    KEY_K,
    KEY_L,
    KEY_LEFT,
    KEY_M,
    KEY_MENU,
    KEY_N,
    KEY_O,
    KEY_P,
    KEY_Q,
    KEY_R,
    KEY_RETURN,
    KEY_RIGHT,
    KEY_S,
    KEY_SHIFT,
    KEY_SPACE,
    KEY_T,
    KEY_TAB,
    KEY_U,
    KEY_UP,
    KEY_V,
    KEY_W,
    KEY_X,
    KEY_Y,
    KEY_Z,
    action_keys,
    key_name,
)
from .cosmos import (
    COSMOS_SHADER,
    Cosmos,
    SCENE_ALIEN,
    SCENE_AURORA,
    SCENE_BINARY,
    SCENE_BLACK_HOLE,
    SCENE_COUNT,
    SCENE_GALAXY,
    SCENE_GAS_GIANT,
    SCENE_MOON,
    SCENE_NEBULA,
    SCENE_NOVA,
    SCENE_PLASMA,
    SCENE_PULSAR,
    SCENE_WORMHOLE,
    scene_name,
)
from .compositor import (
    BLIT_ALPHA,
    BLIT_COPY,
    BLIT_KEY,
    Compositor,
    KEY_MAGENTA,
    Layer,
    POOL_SLOTS,
)
from .text import (
    FONT_ATLAS_H,
    FONT_ATLAS_W,
    GLYPH_CELL,
    PEN_ADVANCE,
    TXT_MAX_INST,
    Text,
    bake_font,
    font_table,
)
from .tiles import (
    TILE_ATLAS_DIM,
    TILE_PX,
    TILE_SLOTS,
    TILE_WORLD_H,
    TILE_WORLD_W,
    Tiles,
)
from .sprites import (
    SPR_ATLAS_DIM,
    SPR_MAX_INST,
    SPR_PAL_SLOTS,
    SPR_PAL_WIDE,
    Sprites,
)
from .buffers import GpuBuffer
from .blitter import (
    BlitRect,
    OP_AND,
    OP_OR,
    OP_XOR,
    Planes,
    SLOT_COUNT,
    SLOT_DATA_FIRST,
    clip_blit,
)
from .window import (
    Frame,
    GamePane,
    action,
    action_hit,
    any_key_held,
    clear_input,
    input_poll,
    key_down,
    key_held,
    key_hit,
    mouse_state,
    sim_action,
)
