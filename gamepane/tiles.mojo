# ===----------------------------------------------------------------------=== #
# G2 -- tile layers and parallax scrolling, from RASM's gpu/tile.was.
#
# THE IDEA, and it is the reason this layer exists rather than being a loop
# over sprites: a tilemap is BAKED ONCE into a wide index plane, and
# scrolling it afterwards costs two integers. No redraw, no re-upload, no
# per-tile work of any kind at frame time. The reference calls this the
# overscan model and it is what let 1980s hardware scroll a whole world on a
# budget that could not afford to touch every pixel.
#
#   atlas    256x256 R8_UINT   1024 tiles of 8x8, packed in add order
#   world    1024x360 R8_UINT  per layer: the map, stamped out as pixels
#   scroll   int4 in b0        {scrollX, scrollY, wrapW, worldH}
#
# The world plane is WIDER than the 640-pixel view on purpose -- that is the
# overscan -- but the shader does not wrap at the plane's width. It wraps at
# each layer's OWN map period, `mapW * 8`, which is what makes three layers
# with different map widths scroll seamlessly at three different rates from
# one shared constant buffer.
#
# Tile index 0 is transparent: the pixel shader emits the compositor's
# magenta key for it, and the keyed composite discards it. So layers stack
# back to front and a sky shows through every empty cell of every layer above
# it. Indices 1..15 resolve through the PER-SCANLINE palette at the SCREEN
# row (not the world row -- a gradient sky must stay screen-relative while
# the world scrolls under it), and 16..255 through the global palette.
#
# A tilemap cell holds tile-id + 1, so that 0 can mean empty. Cell k draws
# atlas tile k-1. Get that off by one and the whole map draws one tile to the
# left, which looks like art rather than like a bug.
# ===----------------------------------------------------------------------=== #

from std.memory import Pointer
from .canvas import CANVAS_H, CANVAS_W, _bytes
from .device import (
    clear_render_target,
    compile_shader_blob,
    create_blend_state,
    create_buffer,
    create_pixel_shader,
    create_rasterizer_state,
    create_srv,
    create_texture2d,
    create_vertex_shader,
    draw,
    ia_set_topology,
    om_set_blend_state,
    om_set_render_targets,
    ps_set_constant_buffers,
    ps_set_shader,
    ps_set_shader_resources,
    resolve_compiler,
    rs_set_state,
    set_viewport,
    update_subresource,
    vs_set_shader,
)

comptime TILE_PX = 8
"""The tile edge. Everything else here is a multiple of it, and the shifts
in this file (`>> 3`, `* 8`) are all this constant."""

comptime TILE_WORLD_W = 1024
comptime TILE_WORLD_H = 360
"""One layer's baked world: 128 tiles across, 45 down. Wider than the view so
there is somewhere to scroll to; the shader wraps at the map period rather
than here, so this only has to be at least as wide as the widest map."""

comptime TILE_ATLAS_DIM = 256
comptime TILE_ATLAS_COLS = 32
"""32 x 32 cells of 8x8 = 1024 tiles."""

comptime TILE_SLOTS = 4
"""Four parallax layers. The reference's fixed capacity."""

comptime _FORMAT_R8_UINT = 62
comptime _BIND_SHADER_RESOURCE = 8
comptime _BIND_CONSTANT_BUFFER = 4
comptime _USAGE_DEFAULT = 0
comptime _TOPOLOGY_TRIANGLELIST = 4


comptime TILE_SHADER = String(
    """
Texture2D<uint> tIdx:register(t0);
Texture2D<float4> palGlobal:register(t1);
Texture2D<float4> palLine:register(t2);
cbuffer TCB:register(b0){int4 scr;};
struct VO{float4 p:SV_Position;float2 uv:TEXCOORD0;};
VO TVS(uint i:SV_VertexID){VO o;float2 u=float2((i<<1)&2,i&2);o.p=float4(u.x*2-1,1-u.y*2,0,1);o.uv=u;return o;}
float4 TPS(VO v):SV_Target{
int sx=(int)(v.uv.x*640.0);int sy=(int)(v.uv.y*360.0);
sx=clamp(sx,0,639);sy=clamp(sy,0,359);
int ww=scr.z;int wh=scr.w;
int wx=scr.x+sx;wx=wx%ww;if(wx<0)wx+=ww;
int wy=scr.y+sy;if(wy<0)wy=0;if(wy>=wh)wy=wh-1;
uint c=tIdx.Load(int3(wx,wy,0));
if(c==0u){return float4(1.0,0.0,1.0,1.0);}
float4 col;
if(c<16u){col=palLine.Load(int3((int)c,sy,0));}else{col=palGlobal.Load(int3((int)c,0,0));}
return float4(col.rgb,1.0);}
"""
)
"""The reference's tile shader, verbatim.

Four details in it that a rewrite would get wrong:

  * `if(wx<0)wx+=ww` is not redundant. HLSL's `%` on signed integers returns
    a NEGATIVE remainder for a negative left operand, and scrollX is signed
    because games scroll left.
  * wy is CLAMPED where wx is WRAPPED. Vertical scrolling runs into the
    world's edges and sticks; only the horizontal axis is endless.
  * palLine is indexed by `sy`, the SCREEN row, while the texel came from
    `wy`, the world row. That is the one place screen space deliberately
    leaks into the resolve, and it is what keeps a per-scanline gradient sky
    still while the world moves under it.
  * 640.0/360.0/639/359 are literals. The shader is bound to the layer
    viewport, not to any constant it could read."""


struct Tiles(Movable):
    """The tile atlas, four bakeable world planes, and the scroll pass."""

    var device: Int
    var context: Int
    var vs: Int
    var ps: Int
    var cb: Int
    var rast: Int
    var blend_opaque: Int

    var atlas: List[UInt8]
    """The CPU atlas. Never uploaded: the bake reads it host-side and stamps
    pixels into a world plane, which is the only consumer. The reference
    creates a GPU atlas texture too and then never binds it -- a placeholder
    for a GPU-side stamp that was never written. Not ported; an unbound
    texture is a thing to explain rather than a thing to have."""
    var atlas_count: Int

    var world: List[UInt8]
    """Four world planes end to end, TILE_WORLD_W * TILE_WORLD_H each."""
    var world_tex: List[Int]
    var world_srv: List[Int]
    var wrap_w: List[Int]
    """Per layer: the map's period in pixels, mapW * 8. The shader's `ww`."""

    var scroll: List[Int32]
    """The constant buffer's int4, on the host."""

    def __init__(out self, device: Int, context: Int) raises:
        self.device = device
        self.context = context
        self.atlas_count = 0

        var compile = resolve_compiler()
        var empty = List[UInt8]()
        var src = _bytes(String(TILE_SHADER))
        var vs_blob = compile_shader_blob(
            compile, src, empty, empty, _bytes(String("TVS")),
            _bytes(String("vs_5_0")),
        )
        self.vs = create_vertex_shader(device, vs_blob[0], vs_blob[1])
        var ps_blob = compile_shader_blob(
            compile, src, empty, empty, _bytes(String("TPS")),
            _bytes(String("ps_5_0")),
        )
        self.ps = create_pixel_shader(device, ps_blob[0], ps_blob[1])

        self.cb = create_buffer(
            device, 16, _BIND_CONSTANT_BUFFER, _USAGE_DEFAULT
        )
        self.rast = create_rasterizer_state(device)
        self.blend_opaque = create_blend_state(device, False)

        self.atlas = List[UInt8](
            length=TILE_ATLAS_DIM * TILE_ATLAS_DIM, fill=0
        )
        self.world = List[UInt8](
            length=TILE_SLOTS * TILE_WORLD_W * TILE_WORLD_H, fill=0
        )
        self.world_tex = List[Int](length=TILE_SLOTS, fill=0)
        self.world_srv = List[Int](length=TILE_SLOTS, fill=0)
        self.wrap_w = List[Int](length=TILE_SLOTS, fill=TILE_WORLD_W)
        self.scroll = List[Int32](length=4, fill=0)

        for slot in range(TILE_SLOTS):
            var tex = create_texture2d(
                device, TILE_WORLD_W, TILE_WORLD_H, _FORMAT_R8_UINT,
                _BIND_SHADER_RESOURCE, _USAGE_DEFAULT, 0,
            )
            self.world_tex[slot] = tex
            self.world_srv[slot] = create_srv(device, tex, _FORMAT_R8_UINT)

    # ── the atlas ───────────────────────────────────────────────────────
    def add_tile(mut self, pixels: List[UInt8]) raises -> Int:
        """Append one 8x8 tile and return its id.

        Ids are assigned in call order and the packing is left to right, top
        to bottom -- so the ORDER of these calls is the tile numbering, and a
        map written against one order does not survive a reshuffle."""
        if len(pixels) < TILE_PX * TILE_PX:
            raise Error("add_tile: a tile is 8x8 indices")
        if self.atlas_count >= TILE_ATLAS_COLS * TILE_ATLAS_COLS:
            raise Error("add_tile: the atlas holds 1024 tiles")
        var id = self.atlas_count
        var tx = (id % TILE_ATLAS_COLS) * TILE_PX
        var ty = (id // TILE_ATLAS_COLS) * TILE_PX
        for row in range(TILE_PX):
            var dst = (ty + row) * TILE_ATLAS_DIM + tx
            var s = row * TILE_PX
            for col in range(TILE_PX):
                self.atlas[dst + col] = pixels[s + col]
        self.atlas_count += 1
        return id

    # ── the bake ────────────────────────────────────────────────────────
    def bake(
        mut self, slot: Int, map: List[UInt8], map_w: Int, map_h: Int
    ) raises:
        """Stamp a tilemap into one layer's world plane. Once, per level.

        The map is tiled to fill the WHOLE 1024x360 plane in both axes --
        `mx = wx % map_w`, `my = wy % map_h` -- so a 16-cell map repeats
        eight times across the world and the shader's wrap at `map_w * 8`
        always lands on identical pixels. That identity is what makes the
        seam invisible.

        A cell of 0, or one naming a tile that has not been added, CLEARS its
        8x8 block rather than skipping it. The reference is explicit about
        why: a re-bake with a different map must not leave the previous
        bake's pixels showing through the gaps."""
        if slot < 0 or slot >= TILE_SLOTS:
            raise Error("bake: there are four tile layers")
        if map_w <= 0 or map_h <= 0 or len(map) < map_w * map_h:
            raise Error("bake: the map is smaller than its own dimensions")

        self.wrap_w[slot] = map_w * TILE_PX
        var base = slot * TILE_WORLD_W * TILE_WORLD_H
        var cols = TILE_WORLD_W // TILE_PX
        var rows = TILE_WORLD_H // TILE_PX

        for wy in range(rows):
            var my = wy % map_h
            for wx in range(cols):
                var mx = wx % map_w
                var k = Int(map[my * map_w + mx])
                var dst = base + (wy * TILE_PX) * TILE_WORLD_W + wx * TILE_PX
                if k == 0 or (k - 1) >= self.atlas_count:
                    for row in range(TILE_PX):
                        var d = dst + row * TILE_WORLD_W
                        for col in range(TILE_PX):
                            self.world[d + col] = 0
                    continue
                var id = k - 1
                var sx = (id % TILE_ATLAS_COLS) * TILE_PX
                var sy = (id // TILE_ATLAS_COLS) * TILE_PX
                for row in range(TILE_PX):
                    var s = (sy + row) * TILE_ATLAS_DIM + sx
                    var d = dst + row * TILE_WORLD_W
                    for col in range(TILE_PX):
                        self.world[d + col] = self.atlas[s + col]

    def upload(mut self, slot: Int) raises:
        """One layer's baked plane, host to GPU. Once, after each bake.

        This is the whole per-level cost. The per-frame scroll re-reads this
        texture at a different offset and uploads nothing."""
        if slot < 0 or slot >= TILE_SLOTS:
            raise Error("upload: there are four tile layers")
        var base = slot * TILE_WORLD_W * TILE_WORLD_H
        update_subresource(
            self.context, self.world_tex[slot],
            self.world.unsafe_ptr().unsafe_offset(base)
                .unsafe_origin_cast[MutUntrackedOrigin](),
            TILE_WORLD_W,
        )

    def set_scroll(mut self, slot: Int, x: Int, y: Int):
        """Where this layer is looking. Two integers; nothing is redrawn.

        The slot argument is not decoration even though the constant buffer
        is shared: it selects the layer's own wrap period, which is the
        entire mechanism of the parallax. Call it immediately before the
        matching `render`."""
        self.scroll[0] = Int32(x)
        self.scroll[1] = Int32(y)
        self.scroll[2] = Int32(self.wrap_w[slot])
        self.scroll[3] = Int32(TILE_WORLD_H)

    # ── the pass ────────────────────────────────────────────────────────
    def render(
        mut self, slot: Int, rtv: Int, pal_global: Int, pal_line: Int
    ) raises:
        """Draw one layer into a 640x360 render target.

        The reference's TileRenderLayer, call for call. The destination is
        bound FIRST -- that unbinds whatever was the render target before,
        which is what makes a layer texture legal to sample on the next
        pass -- and the layer is cleared to the KEY so any pixel this pass
        does not cover also composites away."""
        om_set_render_targets(self.context, rtv)
        set_viewport(self.context, CANVAS_W, CANVAS_H)
        clear_render_target(self.context, rtv, 1.0, 0.0, 1.0)

        var views = List[Int](length=3, fill=0)
        views[0] = self.world_srv[slot]
        views[1] = pal_global
        views[2] = pal_line
        ps_set_shader_resources(self.context, views)

        update_subresource(
            self.context, self.cb,
            self.scroll.unsafe_ptr().unsafe_bitcast[UInt8]()
                .unsafe_origin_cast[MutUntrackedOrigin](),
            0,
        )
        ps_set_constant_buffers(self.context, self.cb)

        vs_set_shader(self.context, self.vs)
        ps_set_shader(self.context, self.ps)
        rs_set_state(self.context, self.rast)
        om_set_blend_state(self.context, self.blend_opaque)
        ia_set_topology(self.context, _TOPOLOGY_TRIANGLELIST)
        draw(self.context, 3)
