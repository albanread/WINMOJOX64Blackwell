"""Layer 2's data and arithmetic: definitions, instances, animation, hit
testing, and the quad transform -- none of which needs a GPU.

Sprites are **composited by the GPU, not blitted**. Nothing here writes into
the indexed pane's planes: a sprite is a textured quad drawn in its own
render pass with source-alpha blending over whatever the layers below
already put on the drawable. That is what buys per-instance scale, rotation
and alpha for free, and what keeps a moving sprite from having to erase and
redraw the background it covered.

The quad transform lives in this tier because it is arithmetic. It is done
on the CPU, per instance, exactly as the Rust does it -- scale by
half-extents, rotate, subtract the scroll, map to NDC -- rather than in the
vertex shader. That costs one small draw call per sprite instead of a single
instanced draw, which is the right trade at the sprite counts a v1 needs and
the wrong one at hundreds; the comment is here so the next person knows it
was a choice.

Positions are **world** coordinates, the same space the indexed pane's
planes live in, anchored at the sprite's CENTRE rather than its top-left --
a natural pivot for rotation, and the reason `hit` is symmetric about x.
"""

from std.math import cos, sin


comptime SPRITE_COLORS = 16
"""A sprite has its own 16-colour palette. Index 0 is transparent, as
everywhere else in the pane."""


@fieldwise_init
struct SpriteBitmap(Copyable, Movable):
    """A parsed sprite frame: dimensions and one index byte per pixel,
    width-packed (the backend re-packs to its own stride)."""

    var width: Int
    var height: Int
    var pixels: List[UInt8]


def parse_sprite_rows(rows: String) raises -> SpriteBitmap:
    """`/`-separated rows of hex digits, `.` a synonym for 0.

    `IndexedPane.mod`'s `DefineSprite` text format exactly, so a sprite can
    be written as a string literal in the middle of a game:

        ".0ff0./0ffff0/ffffff/.ffff./..ff.."

    Raises on anything malformed -- empty, or ragged. Ragged is the one
    worth being strict about: a row one character short shifts every pixel
    after it and produces a sprite that looks *nearly* right, which is far
    harder to see than a refusal.
    """
    var lines = rows.split("/")
    if len(lines) == 0:
        raise Error("sprite: no rows")
    # byte_length, not len: rows are ASCII hex digits and dots, so
    # bytes and characters coincide -- and Mojo will not guess which
    # one `len` meant.
    var width = lines[0].byte_length()
    if width == 0:
        raise Error("sprite: the first row is empty")
    var pixels = List[UInt8]()
    for li in range(len(lines)):
        var line = lines[li]
        if line.byte_length() != width:
            raise Error(
                "sprite: row "
                + String(li)
                + " is "
                + String(line.byte_length())
                + " wide, the first is "
                + String(width)
            )
        for c in line.codepoints():
            var v = Int(c.to_u32())
            if v == ord("."):
                pixels.append(0)
            elif v >= ord("0") and v <= ord("9"):
                pixels.append(UInt8(v - ord("0")))
            elif v >= ord("a") and v <= ord("f"):
                pixels.append(UInt8(v - ord("a") + 10))
            elif v >= ord("A") and v <= ord("F"):
                pixels.append(UInt8(v - ord("A") + 10))
            else:
                raise Error("sprite: '" + String(c) + "' is not a hex digit")
    return SpriteBitmap(width, len(lines), pixels^)


@fieldwise_init
struct SpriteInstance(Copyable, Movable):
    """One placed sprite. World-space centre, and everything the GPU draw
    needs to know about it."""

    var definition: Int
    var x: Float64
    var y: Float64
    var scale: Float64
    var rotation_degrees: Float64
    var alpha: Float64
    var frame: Int
    var visible: Bool
    var animate_fps: Float64
    var anim_accum_secs: Float64

    def __init__(out self, definition: Int, x: Float64, y: Float64):
        self.definition = definition
        self.x = x
        self.y = y
        self.scale = 1.0
        self.rotation_degrees = 0.0
        self.alpha = 1.0
        self.frame = 0
        self.visible = True
        self.animate_fps = 0.0
        self.anim_accum_secs = 0.0

    def advance(mut self, dt: Float64, frame_count: Int):
        """Move the animation on by `dt` seconds.

        A `while`, not an `if`: a frame that took long enough to cross two
        periods should advance two frames, or an animation slows down
        whenever the machine does.
        """
        if self.animate_fps <= 0.0 or frame_count <= 1:
            return
        self.anim_accum_secs += dt
        let period = 1.0 / self.animate_fps
        while self.anim_accum_secs >= period:
            self.anim_accum_secs -= period
            self.frame = (self.frame + 1) % frame_count


def sprites_overlap(
    ax: Float64, ay: Float64, aw: Float64, ah: Float64,
    bx: Float64, by: Float64, bw: Float64, bh: Float64,
) -> Bool:
    """Axis-aligned overlap of two centre-anchored, already-scaled boxes.

    Strict inequalities: two boxes that share only an edge do not overlap,
    which is what stops a sprite resting exactly on another from reading as
    a collision every frame.
    """
    return (
        ax - aw / 2.0 < bx + bw / 2.0
        and ax + aw / 2.0 > bx - bw / 2.0
        and ay - ah / 2.0 < by + bh / 2.0
        and ay + ah / 2.0 > by - bh / 2.0
    )


def quad_vertices(
    inst: SpriteInstance,
    def_width: Int,
    def_height: Int,
    scroll_x: Float64,
    scroll_y: Float64,
    viewport_w: Float64,
    viewport_h: Float64,
) -> List[Float32]:
    """Four vertices as `{float2 pos; float2 uv;}`, ready for
    `setVertexBytes:`.

    Triangle-strip order -- top-left, top-right, bottom-left, bottom-right
    -- which is why there are four vertices and no index buffer.

    Scale, then rotate, then subtract the scroll, then map to NDC. The
    order matters: rotating after the scroll would swing the sprite around
    the screen's origin instead of its own centre.
    """
    let hw = Float64(def_width) * inst.scale / 2.0
    let hh = Float64(def_height) * inst.scale / 2.0
    let theta = inst.rotation_degrees * 3.141592653589793 / 180.0
    let ct = cos(theta)
    let st = sin(theta)
    let cx = inst.x - scroll_x
    let cy = inst.y - scroll_y

    var corners = List[Float64]()
    corners.append(-hw); corners.append(-hh); corners.append(0.0); corners.append(0.0)
    corners.append(hw);  corners.append(-hh); corners.append(1.0); corners.append(0.0)
    corners.append(-hw); corners.append(hh);  corners.append(0.0); corners.append(1.0)
    corners.append(hw);  corners.append(hh);  corners.append(1.0); corners.append(1.0)

    var out = List[Float32]()
    for i in range(4):
        let lx = corners[i * 4 + 0]
        let ly = corners[i * 4 + 1]
        let rx = lx * ct - ly * st
        let ry = lx * st + ly * ct
        let sx = cx + rx
        let sy = cy + ry
        out.append(Float32((sx / viewport_w) * 2.0 - 1.0))
        out.append(Float32(1.0 - (sy / viewport_h) * 2.0))
        out.append(Float32(corners[i * 4 + 2]))
        out.append(Float32(corners[i * 4 + 3]))
    return out^
