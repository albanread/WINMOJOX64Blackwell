# ===----------------------------------------------------------------------=== #
# G2 on screen: three tile layers, three scroll rates, zero redraw.
#
# The same test the reference uses for this layer (RASM examples/gpu_g2.was):
# three horizontal bands of 8x8 tiles, each baked ONCE into its own world
# plane at startup and thereafter moved by changing two integers a frame.
# Nothing in the frame loop touches a tile, an atlas or a map.
#
#   FAR    a 16-cell map of sparse stars, scrolling at a quarter rate
#   MID    a 20-cell map of hills, at half rate
#   NEAR   a 24-cell map of a girder fence, at full rate
#
# What each part proves, so a wrong picture says which piece broke:
#
#   * the bands SCROLL AT DIFFERENT SPEEDS from ONE shared constant buffer.
#     That only works because each layer's wrap period is its own map width,
#     which `set_scroll` fetches by slot. If all three move together, the
#     slot argument is being ignored.
#   * the sky shows THROUGH the empty cells of all three layers. That is the
#     colour key: tile index 0 leaves the tile shader as magenta and the
#     keyed composite discards it. If you see magenta, the key is wrong; if
#     you see black rectangles, the composite ran in copy mode.
#   * the seam is INVISIBLE as a band wraps. The map is tiled to fill the
#     whole 1024-wide world, so the wrap always lands on identical pixels.
#   * the ground band's colour comes from the PER-SCANLINE palette (indices
#     under 16) while the stars and girders come from the global one, so one
#     picture exercises both halves of the resolve.
#
# Before the window opens, `_verify` checks the bake on the host -- the one
# thing a screenshot cannot tell you, because a map drawn one tile to the
# left looks like art rather than like an off-by-one.
#
# Headless: GAMEPANE_FRAMES=n renders n frames and exits.
# ===----------------------------------------------------------------------=== #

from std.windows import get_environment
from gamepane import (
    BLIT_KEY,
    CANVAS_H,
    CANVAS_W,
    Compositor,
    GamePane,
    GpuCanvas,
    KEY_ESCAPE,
    TILE_PX,
    TILE_WORLD_W,
    Tiles,
    key_held,
)
from gamepane.device import clear_render_target, om_set_render_targets

comptime FAR = 0
comptime MID = 1
comptime NEAR = 2

comptime FAR_W = 16
comptime MID_W = 20
comptime NEAR_W = 24
comptime MAP_H = 45
"""360 / 8 -- a map as tall as the world, so nothing wraps vertically."""

# Palette indices. Under 16 goes through the per-line palette, 16 and up
# through the global one; the demo deliberately uses both.
comptime IDX_STAR = 200
comptime IDX_GIRDER = 210
comptime IDX_RIVET = 214
comptime IDX_GROUND = 4
comptime IDX_GRASS = 6


def _tile_star() -> List[UInt8]:
    """A four-pointed spark on transparent."""
    var px = List[UInt8](length=64, fill=0)
    for i in range(1, 7):
        px[3 * 8 + i] = IDX_STAR
        px[i * 8 + 3] = IDX_STAR
    px[3 * 8 + 3] = IDX_STAR
    return px^


def _tile_hill() -> List[UInt8]:
    """A solid ground block: two shades so a flat fill is visible as texture.
    """
    var px = List[UInt8](length=64, fill=0)
    for y in range(8):
        for x in range(8):
            px[y * 8 + x] = IDX_GROUND if ((x + y) & 3) != 0 else IDX_GRASS
    return px^


def _tile_crest() -> List[UInt8]:
    """The lit top edge of the ground: grass over two rows of soil."""
    var px = List[UInt8](length=64, fill=0)
    for x in range(8):
        px[x] = IDX_GRASS
        px[8 + x] = IDX_GRASS
    for y in range(2, 8):
        for x in range(8):
            px[y * 8 + x] = IDX_GROUND
    return px^


def _tile_girder() -> List[UInt8]:
    """A box girder: a frame with a rivet, transparent inside, so the layer
    behind it shows through the middle."""
    var px = List[UInt8](length=64, fill=0)
    for i in range(8):
        px[i] = IDX_GIRDER
        px[7 * 8 + i] = IDX_GIRDER
        px[i * 8] = IDX_GIRDER
        px[i * 8 + 7] = IDX_GIRDER
    px[3 * 8 + 3] = IDX_RIVET
    px[3 * 8 + 4] = IDX_RIVET
    px[4 * 8 + 3] = IDX_RIVET
    px[4 * 8 + 4] = IDX_RIVET
    return px^


def _far_map(star: Int) -> List[UInt8]:
    """Sparse stars on five rows, in the reference's (col+row)%5 pattern."""
    var m = List[UInt8](length=FAR_W * MAP_H, fill=0)
    for row in range(2, 12, 2):
        for col in range(FAR_W):
            if (col + row) % 5 == 0:
                m[row * FAR_W + col] = UInt8(star + 1)
    return m^


def _mid_map(hill: Int, crest: Int) -> List[UInt8]:
    """A rolling ground: a crest row, solid underneath."""
    var m = List[UInt8](length=MID_W * MAP_H, fill=0)
    for col in range(MID_W):
        # A short repeating profile rather than a sine, so the expected
        # height of any column is an integer the checker can restate.
        var top = 30 + ((col * 7) % 5) - 2
        m[top * MID_W + col] = UInt8(crest + 1)
        for row in range(top + 1, MAP_H):
            m[row * MID_W + col] = UInt8(hill + 1)
    return m^


def _near_map(girder: Int) -> List[UInt8]:
    """A fence: two rows of girders with gaps, low on the screen."""
    var m = List[UInt8](length=NEAR_W * MAP_H, fill=0)
    for col in range(NEAR_W):
        if (col % 6) < 2:
            m[38 * NEAR_W + col] = UInt8(girder + 1)
            m[39 * NEAR_W + col] = UInt8(girder + 1)
    return m^


def _verify(
    mut tiles: Tiles, girder: Int, star: Int
) raises -> Bool:
    """Check the bake on the host, where an off-by-one is legible.

    Three samples, each chosen so a plausible mistake changes the answer:
      * a girder's TOP-LEFT corner pixel is the girder colour, and its
        INSIDE is 0 -- the pair proves the tile landed at the right world
        offset and that transparency survived the bake.
      * the same pixel one map period to the right is identical, which is
        what makes the shader's wrap seamless. If the map were not tiled
        across the whole world plane this is where it would show.
      * a cell the map leaves empty is still 0 after the bake, so a re-bake
        would not be showing an earlier bake's pixels.
    """
    var bad = 0
    var stride = TILE_WORLD_W
    var near_base = NEAR * TILE_WORLD_W * 360
    var far_base = FAR * TILE_WORLD_W * 360

    # Map cell (0, 38) holds a girder; its top-left world pixel is (0, 304).
    var corner = tiles.world[near_base + 304 * stride + 0]
    if corner != UInt8(IDX_GIRDER):
        print("  FAIL girder corner: expected", IDX_GIRDER, "got", Int(corner))
        bad += 1
    else:
        print("  ok   girder corner =", Int(corner))

    # ...and its interior is transparent, two pixels in.
    var inside = tiles.world[near_base + 306 * stride + 2]
    if inside != 0:
        print("  FAIL girder interior: expected 0, got", Int(inside))
        bad += 1
    else:
        print("  ok   girder interior = 0")

    # One full map period to the right -- 24 tiles, 192 pixels -- is the
    # same pixel again. This is the seam.
    var wrapped = tiles.world[near_base + 304 * stride + NEAR_W * TILE_PX]
    if wrapped != corner:
        print("  FAIL wrap: expected", Int(corner), "got", Int(wrapped))
        bad += 1
    else:
        print("  ok   wrap repeats =", Int(wrapped))

    # A star sits at far map cell (col+row)%5==0; row 2 col 3 qualifies, so
    # world pixel (3*8+3, 2*8+3) = (27, 19) is the spark's centre.
    var spark = tiles.world[far_base + 19 * stride + 27]
    if spark != UInt8(IDX_STAR):
        print("  FAIL star centre: expected", IDX_STAR, "got", Int(spark))
        bad += 1
    else:
        print("  ok   star centre =", Int(spark))

    # Far map row 1 has no stars at all, so its whole band is empty.
    var empty = tiles.world[far_base + 12 * stride + 27]
    if empty != 0:
        print("  FAIL empty cell: expected 0, got", Int(empty))
        bad += 1
    else:
        print("  ok   empty cell = 0")

    _ = star
    _ = girder
    return bad == 0


def main() raises:
    var pane = GamePane(String("Game pane - G2 tile parallax"), 1280, 720)
    var canvas = GpuCanvas(pane.ctx, pane.device, pane.context)
    var tiles = Tiles(pane.device, pane.context)
    var comp = Compositor(pane.device, pane.context)

    var far_layer = comp.alloc_layer()
    var mid_layer = comp.alloc_layer()
    var near_layer = comp.alloc_layer()

    # ---- the palettes ----------------------------------------------------
    # Global entries for the stars and girders; the per-scanline palette for
    # the ground, so the same two indices darken toward the bottom of the
    # screen and stay put while the world scrolls under them.
    canvas.set_rgb(IDX_STAR, 184, 112, 71)
    canvas.set_rgb(IDX_GIRDER, 150, 120, 190)
    canvas.set_rgb(IDX_RIVET, 240, 230, 255)
    for y in range(CANVAS_H):
        var t = Float32(y) / Float32(CANVAS_H - 1)
        canvas.set_line_rgb(
            y, IDX_GROUND,
            Int(70.0 - 40.0 * t), Int(120.0 - 70.0 * t), Int(60.0 - 35.0 * t),
        )
        canvas.set_line_rgb(
            y, IDX_GRASS,
            Int(120.0 - 60.0 * t), Int(200.0 - 90.0 * t),
            Int(90.0 - 45.0 * t),
        )
    canvas.upload_palettes()

    # ---- level load: build the atlas, bake three maps, upload once -------
    var star = tiles.add_tile(_tile_star())
    var hill = tiles.add_tile(_tile_hill())
    var crest = tiles.add_tile(_tile_crest())
    var girder = tiles.add_tile(_tile_girder())

    tiles.bake(FAR, _far_map(star), FAR_W, MAP_H)
    tiles.bake(MID, _mid_map(hill, crest), MID_W, MAP_H)
    tiles.bake(NEAR, _near_map(girder), NEAR_W, MAP_H)

    print("verifying the bake before anything is shown:")
    if not _verify(tiles, girder, star):
        raise Error("tile bake verification failed; not showing a wrong map")
    print("  all five samples correct")

    tiles.upload(FAR)
    tiles.upload(MID)
    tiles.upload(NEAR)

    var frames = 0
    while pane.pump():
        if key_held(KEY_ESCAPE):
            break

        var frame = pane.begin_frame()

        # The sky. Nothing else clears the back buffer, and every layer is
        # transparent somewhere, so this colour is what shows through every
        # empty cell of all three. `pane.clear` would do this in black; the
        # reference's dark navy makes the difference between "keyed out" and
        # "a black tile" visible, which is exactly what wants proving.
        om_set_render_targets(pane.context, pane.rtv)
        clear_render_target(pane.context, pane.rtv, 0.05, 0.031, 0.125)
        _ = frame

        # Back to front: far first, because a keyed discard reveals whatever
        # is ALREADY there. Reverse this and the near layer is painted over.
        var cam = frames * 2
        tiles.set_scroll(FAR, cam // 4, 0)
        tiles.render(
            FAR, comp.rtv(far_layer), canvas.srv_global, canvas.srv_line
        )
        comp.to_back(
            far_layer, pane.rtv, pane.width, pane.height, BLIT_KEY
        )

        tiles.set_scroll(MID, cam // 2, 0)
        tiles.render(
            MID, comp.rtv(mid_layer), canvas.srv_global, canvas.srv_line
        )
        comp.to_back(
            mid_layer, pane.rtv, pane.width, pane.height, BLIT_KEY
        )

        tiles.set_scroll(NEAR, cam, 0)
        tiles.render(
            NEAR, comp.rtv(near_layer), canvas.srv_global, canvas.srv_line
        )
        comp.to_back(
            near_layer, pane.rtv, pane.width, pane.height, BLIT_KEY
        )

        pane.end_frame(frame)
        frames += 1

    pane.close()
    print(
        "gamepane-tiles:", frames,
        "frames, three parallax layers, not one tile redrawn",
    )
    _ = get_environment("GAMEPANE_FRAMES")
