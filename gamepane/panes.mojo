# ===----------------------------------------------------------------------=== #
# The portable tier: four panes a game programmes against.
#
# Everything under this file is the Direct3D layer stack -- Cosmos, GpuCanvas,
# Sprites, Text -- and everything above it is a game. The layers are shaped by
# what Direct3D wants (a device, a context, an explicit render target view, a
# viewport somebody has to set). A game should not be shaped by any of that,
# and Galaxigans is not: it was written against the Metal pane and the same
# source has to run here.
#
# So these four keep the NAMES AND THE SHAPES the game already uses:
#
#   ShaderPane    layer 0   the procedural backdrop
#   IndexedPane   layer 1   the palette-indexed plane, per-scanline colour
#   Sprites       layer 2   a RETAINED pool of instances
#   TextOverlay   layer 3   the HUD
#
# Two differences from the Metal pane are real and are documented at the call
# rather than hidden: a constructor here takes the immediate context as well
# as the device, and a render takes the render target view. Direct3D has no
# ambient "current" anything, and pretending otherwise would mean this file
# holding a global -- which on this target is its own adventure.
#
# THE RETAINED/IMMEDIATE SPLIT IS THE POINT OF THE SPRITE ADAPTER. The layer
# underneath is immediate: `clear`, then `push` every visible sprite, then one
# DrawInstanced. A game wants the opposite -- place fifty-two instances once
# and thereafter move, hide and re-frame them by handle, because that is how
# game state is shaped. So this keeps the pool and does the pushing, and the
# fifty-two instances survive from `place` to the end of the process.
# ===----------------------------------------------------------------------=== #

from std.memory import Pointer
from .canvas import CANVAS_H, CANVAS_W, GpuCanvas
from .cosmos import Cosmos, SCENE_COUNT
from .device import set_viewport
from .plane import Plane
from .sprites import AtlasFrame, Sprites as SpriteAtlas
from .spritedata import SPRITE_COLORS, SpriteBitmap, parse_sprite_rows
from .text import Text
from max.gpu.host import DeviceContext

comptime TRANSPARENT = UInt8(0)


# ── layer 0 ─────────────────────────────────────────────────────────────


struct ShaderPane(Movable):
    """The procedural backdrop.

    ON THIS BACKEND THE SCENES ARE THE PANE. The Metal ShaderPane takes a
    fragment body as a string and prepends its own header, so a game carries
    its backdrop with it; here the twelve cosmos scenes came from RASM's
    Galaxigans already written in HLSL and already on Direct3D, so they live
    in `cosmos.mojo` and this selects between them. That is not a shortcut --
    it is the reference implementation of the same twelve scenes, and
    translating the Metal copy by hand would have been the shortcut.

    A game that wants a backdrop of its own writes another module beside
    `cosmos.mojo`; it does not hand a string through here, because a shader
    handed across at run time cannot be compiled at build time and a typo in
    it becomes a black screen rather than an error.
    """

    var pane: Cosmos

    def __init__(out self, device: Int, context: Int) raises:
        self.pane = Cosmos(device, context)

    def set_aspect(mut self, aspect: Float32):
        """Accepted and not used, and worth saying why rather than dropping
        the method.

        The Metal scenes take `u.aspect` as a uniform. RASM's take it as the
        literal 1.7778 inside each scene function, because the canvas is
        640x360 and every one of these backdrops was written for it. A game
        that calls this is not wrong and is not surprised; the picture simply
        does not depend on the answer."""
        _ = aspect

    def set_param(mut self, index: Int, value: Float32):
        """Parameter 0 is the scene, 0..11. The Metal pane has eight of these
        and the game uses exactly one of them, for exactly this."""
        if index == 0:
            self.pane.set_scene(Int(value + 0.5))

    def scene(self) -> Int:
        return self.pane.scene()

    def advance(mut self, dt: Float64):
        self.pane.advance(dt)

    def set_time(mut self, seconds: Float64):
        self.pane.set_time(seconds)

    def render(mut self, rtv: Int, back_w: Int, back_h: Int) raises:
        """First of the frame. Opaque, so it is the clear as well."""
        self.pane.render(rtv, back_w, back_h)


# ── layer 1 ─────────────────────────────────────────────────────────────


struct IndexedPane(Movable):
    """The palette-indexed plane, over the backdrop.

    Index 0 is transparent and the resolve discards it, so the cosmos shows
    through wherever the game has not drawn. Indices 1..15 resolve through
    the PER-SCANLINE palette and 16..255 through the global one, which is the
    split that makes a copper bar cost one palette row rather than a screen
    of pixels -- and the tractor beam is exactly that.

    The Metal pane keeps eight planes over a world larger than the viewport
    and scrolls between them. This one is a single 640x360 plane, because
    that is what the canvas underneath is and Galaxigans never scrolls: it
    asks for a world the same size as its viewport. A request for any other
    size raises here rather than quietly drawing something else.
    """

    var canvas: GpuCanvas
    var width: Int
    var height: Int

    def __init__(
        out self,
        ctx: DeviceContext,
        device: Int,
        context: Int,
        world_w: Int,
        world_h: Int,
        view_w: Int,
        view_h: Int,
    ) raises:
        if (
            world_w != CANVAS_W or world_h != CANVAS_H
            or view_w != CANVAS_W or view_h != CANVAS_H
        ):
            raise Error(
                "IndexedPane: this backend's plane is "
                + String(CANVAS_W) + "x" + String(CANVAS_H)
                + " and does not scroll"
            )
        self.canvas = GpuCanvas(ctx, device, context)
        # A layer, not a background: it must not clear what the cosmos drew,
        # and index 0 has to be a hole rather than a colour.
        self.canvas.set_overlay(True)
        self.width = world_w
        self.height = world_h
        self.canvas.cls(0)

    def set_rgb(mut self, index: Int, r: Int, g: Int, b: Int) raises:
        """A colour in the GLOBAL palette, 16..255."""
        if index < 16 or index > 255:
            raise Error(
                "set_rgb: index 0..15 are per-line -- use set_line_rgb"
            )
        self.canvas.set_rgb(index, r, g, b)

    def set_line_rgb(
        mut self, line: Int, index: Int, r: Int, g: Int, b: Int
    ) raises:
        """THE COPPER BAR: what index `index` means on scanline `line`.

        This is the one call that animates a tractor beam. The beam's pixels
        are written once, all of them index 1; this then rewrites what 1
        means, row by row, and the beam moves without a pixel being touched.
        """
        if index < 1 or index > 15:
            raise Error("set_line_rgb: index must be 1..15")
        if line < 0 or line >= self.height:
            raise Error("set_line_rgb: line is outside the viewport")
        self.canvas.set_line_rgb(line, index, r, g, b)

    def active_plane(mut self) -> Plane:
        """The writable plane: base, stride, width, height.

        The stride is the width here -- there is no texture alignment to
        round up to, because the bytes go through UpdateSubresource rather
        than through a mapped texture. `Plane` still carries the stride
        because a game that assumes `y * width + x` is a game that breaks on
        the next backend."""
        return Plane(
            self.canvas.idx.unsafe_ptr()
                .unsafe_origin_cast[MutUntrackedOrigin](),
            CANVAS_W,
            self.width,
            self.height,
        )

    def render(mut self, rtv: Int, back_w: Int, back_h: Int) raises:
        """Second of the frame, over the backdrop."""
        self.canvas.present(rtv, back_w, back_h)


# ── layer 2 ─────────────────────────────────────────────────────────────


@fieldwise_init
struct SpriteDef(Copyable, Movable):
    """One definition: where its frames live in the atlas, and its palette
    slot. A definition is shared -- forty aliens over fourteen species means
    forty instances pointing at fourteen of these."""

    var frames: List[Int]
    var w: Int
    var h: Int
    var slot: Int


@fieldwise_init
struct SpriteInstance(ImplicitlyCopyable, Copyable, Movable):
    """One placed sprite. A game holds the handle and nothing else."""

    var definition: Int
    var x: Float64
    var y: Float64
    var frame: Int
    var visible: Bool
    var alpha: Float32


struct Sprites(Movable):
    """A retained pool over the immediate atlas pass.

    Fifty-two instances are placed once and then moved, hidden and re-framed
    by handle for the rest of the process. `render` walks the pool and pushes
    the visible ones, so the whole fleet is still ONE DrawInstanced -- the
    pool is a convenience for the game, not a cost at the driver.
    """

    var atlas: SpriteAtlas
    var defs: List[SpriteDef]
    var instances: List[SpriteInstance]
    """Public, and written directly by exactly one caller: a game re-points
    an instance at a different definition to dress the fleet for a level.
    That is cheaper than redefining art and it is why the field is not
    private."""
    var next_slot: Int

    def __init__(out self, device: Int, context: Int) raises:
        self.atlas = SpriteAtlas(device, context)
        self.defs = List[SpriteDef]()
        self.instances = List[SpriteInstance]()
        self.next_slot = 0

    # ---- definitions ---------------------------------------------------
    def define_sprite(
        mut self, ctx: DeviceContext, rows: String
    ) raises -> Int:
        """Define a sprite from its text rows; returns the handle.

        `ctx` is accepted for source compatibility with the Metal pane, whose
        atlas lives in a device buffer. This backend uploads through the
        immediate context and does not need it."""
        _ = ctx
        var bmp = parse_sprite_rows(rows)
        var frames = List[Int]()
        frames.append(
            self.atlas.add_frame(bmp.width, bmp.height, bmp.pixels)
        )
        var slot = self.next_slot
        self.next_slot += 1
        self.defs.append(SpriteDef(frames^, bmp.width, bmp.height, slot))
        return len(self.defs) - 1

    def add_frame(
        mut self, ctx: DeviceContext, id: Int, rows: String
    ) raises -> Bool:
        """Append another frame to a definition.

        Its size must match the first frame's. A mismatch answers False
        rather than raising, which is the Metal pane's behaviour and is worth
        keeping: art is data, and a wrong row width should not take the
        process down."""
        _ = ctx
        var bmp = parse_sprite_rows(rows)
        if bmp.width != self.defs[id].w or bmp.height != self.defs[id].h:
            return False
        var f = self.atlas.add_frame(bmp.width, bmp.height, bmp.pixels)
        self.defs[id].frames.append(f)
        return True

    def sprite_rgb(
        mut self, id: Int, index: Int, r: Int, g: Int, b: Int
    ) raises:
        """A colour in this definition's own 16-entry palette."""
        if index < 1 or index >= SPRITE_COLORS:
            raise Error("sprite_rgb: colour index must be 1..15")
        self.atlas.set_palette(self.defs[id].slot, index, r, g, b)

    # ---- instances -----------------------------------------------------
    def place(mut self, definition: Int, x: Float64, y: Float64) -> Int:
        self.instances.append(
            SpriteInstance(definition, x, y, 0, False, 1.0)
        )
        return len(self.instances) - 1

    def show(mut self, inst: Int):
        self.instances[inst].visible = True

    def hide(mut self, inst: Int):
        self.instances[inst].visible = False

    def move_to(mut self, inst: Int, x: Float64, y: Float64):
        self.instances[inst].x = x
        self.instances[inst].y = y

    def set_frame(mut self, inst: Int, frame: Int):
        self.instances[inst].frame = frame

    def set_alpha(mut self, inst: Int, a: Float32):
        self.instances[inst].alpha = a

    def sprite_x(self, inst: Int) -> Float64:
        return self.instances[inst].x

    def sprite_y(self, inst: Int) -> Float64:
        return self.instances[inst].y

    def tick(mut self, dt: Float64):
        """Advance auto-animating instances.

        Nothing in Galaxigans auto-animates -- every frame is picked from
        game state -- but the call is part of the shape and a game makes it
        once a frame. Kept so the source does not have to change; if
        per-instance animation is ever wanted, it goes here."""
        _ = dt

    def render(
        mut self,
        rtv: Int,
        scroll_x: Float64,
        scroll_y: Float64,
        view_w: Float64,
        view_h: Float64,
    ) raises:
        """Third of the frame. One DrawInstanced for the whole pool.

        The instance's position is its CENTRE, which is the game's
        convention; the pass underneath places by top-left corner, so the
        half-size comes off here and in one place."""
        _ = view_w
        _ = view_h
        self.atlas.clear()
        for i in range(len(self.instances)):
            if not self.instances[i].visible:
                continue
            # Fields read in place rather than the structs copied: a
            # definition owns a List of frame handles, and copying one per
            # sprite per frame would be fifty-two heap allocations a frame
            # for nothing.
            var di = self.instances[i].definition
            var f = self.instances[i].frame
            if f < 0 or f >= len(self.defs[di].frames):
                f = 0
            var dw = Float32(self.defs[di].w) * 0.5
            var dh = Float32(self.defs[di].h) * 0.5
            self.atlas.push(
                self.defs[di].frames[f],
                Float32(self.instances[i].x - scroll_x) - dw,
                Float32(self.instances[i].y - scroll_y) - dh,
                self.defs[di].slot,
                self.instances[i].alpha,
            )
        self.atlas.render(rtv)


# ── layer 3 ─────────────────────────────────────────────────────────────


struct TextOverlay(Movable):
    """The HUD.

    The Metal pane rasterises text into an RGBA buffer and uploads it when
    dirty. This one queues glyph instances and draws them, which needs no
    upload and no dirty flag at all -- so `clear` empties a queue rather than
    blanking a bitmap, and a caller that redraws its HUD every frame pays
    almost nothing rather than paying for a texture upload.
    """

    var text: Text
    var width: Int
    var height: Int

    def __init__(
        out self, device: Int, context: Int, width: Int, height: Int
    ) raises:
        self.text = Text(device, context)
        self.width = width
        self.height = height

    def clear(mut self):
        self.text.clear()

    def draw_text(
        mut self,
        x: Int,
        y: Int,
        s: String,
        r: Int,
        g: Int,
        b: Int,
        scale: Int = 1,
    ) -> Int:
        """One string, in its own colour and size. Returns the pen x after
        it, so a caller can append without counting characters."""
        self.text.set_colour(r, g, b)
        return self.text.draw(x, y, s, scale)

    def text_width(self, s: String, scale: Int = 1) -> Int:
        return self.text.text_width(s, scale)

    def render(mut self, rtv: Int, back_w: Int, back_h: Int) raises:
        """Last of the frame, over everything.

        It sets the viewport itself, unlike the layer underneath it. The text
        pass deliberately leaves that to its caller -- a caller compositing
        into a 640x360 layer wants a different one -- but at THIS tier the
        answer is always the back buffer, so the game should not have to
        know that D3D11's default viewport is empty."""
        set_viewport(self.text.context, back_w, back_h)
        self.text.render(rtv)
