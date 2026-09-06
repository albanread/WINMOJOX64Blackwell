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
    KEY_1,
    KEY_2,
    KEY_3,
    KEY_4,
    KEY_A,
    KEY_D,
    KEY_DOWN,
    KEY_ESCAPE,
    KEY_LEFT,
    KEY_RETURN,
    KEY_RIGHT,
    KEY_S,
    KEY_SPACE,
    KEY_UP,
    KEY_W,
    KEY_X,
    KEY_Z,
)
from .window import GamePane, Frame, key_held, any_key_held, mouse_state
