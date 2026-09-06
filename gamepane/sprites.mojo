# ===----------------------------------------------------------------------=== #
# G3 -- the instanced sprite pass, ported from RASM's gpu/sprite.was.
#
# The shape that matters, and the one the previous port did not have: every
# sprite on screen is drawn by ONE DrawInstanced. Not one draw per sprite --
# one draw, full stop. The per-sprite data lives in a dynamic vertex buffer
# refilled once a frame with Map(WRITE_DISCARD), and the vertex shader turns
# each 32-byte instance into a quad.
#
#   atlas      512x512 R8_UINT          every frame's pixels, as INDICES
#   palette     16x32   B8G8R8A8_UNORM  row = slot, column = colour
#   instances  8192 x 32 bytes          DYNAMIC vertex buffer
#
# Index 0 is transparent and the pixel shader discards it, so a sprite sheet
# needs no alpha channel: one byte a pixel, and the colours come from the
# slot. Two sprites sharing a frame but not a slot are the same pixels in
# different colours, which is how a formation of aliens costs one frame.
#
# The old port did the opposite of all of this: a texture per definition,
# re-uploaded per instance per frame, two shader resource views created per
# instance per frame, a constant buffer written twice per instance, and one
# Draw per sprite. At forty-five sprites that is ~45 uploads, ~90 view
# creations and ~45 draws a frame, and the views were never released -- so
# it emptied the driver's memory in about two seconds.
# ===----------------------------------------------------------------------=== #

from std.memory import Pointer
from .canvas import CANVAS_H, CANVAS_W, _bytes
from .device import (
    D3D11_INPUT_ELEMENT_DESC,
    compile_shader_blob,
    create_blend_state,
    create_buffer_dynamic,
    create_input_layout,
    create_pixel_shader,
    create_srv,
    create_texture2d,
    create_vertex_shader,
    draw_instanced,
    ia_set_input_layout,
    ia_set_topology,
    ia_set_vertex_buffer,
    map_write_discard,
    om_set_blend_state,
    ps_set_shader,
    ps_set_shader_resources,
    resolve_compiler,
    unmap,
    update_subresource,
    vs_set_shader,
)

comptime SPR_MAX_INST = 8192
comptime SPR_STRIDE = 32
"""Eight floats: screenX, screenY, atlasX, atlasY, w, h, slot, alpha."""
comptime SPR_ATLAS_DIM = 512
comptime SPR_PAL_WIDE = 16
comptime SPR_PAL_SLOTS = 32

comptime _FORMAT_R8_UINT = 62
comptime _FORMAT_B8G8R8A8_UNORM = 87
comptime _FORMAT_R32G32_FLOAT = 16
comptime _FORMAT_R32_FLOAT = 41
comptime _BIND_SHADER_RESOURCE = 8
comptime _BIND_VERTEX_BUFFER = 1
comptime _USAGE_DEFAULT = 0
comptime _TOPOLOGY_TRIANGLESTRIP = 5
comptime _PER_INSTANCE_DATA = 1


# The reference's sprite shader (gpu/sprite.was), kept to the letter. The
# clamp in the pixel shader is the subtle part and its comment is the
# reference's own reasoning: the quad's interpolated atlas coordinate spans
# [org, org+wh], so the far edge truncates to org+wh -- column zero of the
# NEXT frame, because the packer leaves no gutter. Clamp to this frame's
# rect first, then to the atlas.
comptime SPRITE_SHADER = String(
    """
Texture2D<uint> idxAtlas : register(t0);
Texture2D<float4> spritePal : register(t1);

struct VO {
    float4 p : SV_Position;
    float2 atl : TEXCOORD0;
    float pal : TEXCOORD1;
    float a : TEXCOORD2;
    nointerpolation float2 org : TEXCOORD3;
    nointerpolation float2 wh : TEXCOORD4;
};

VO svs(uint vid : SV_VertexID,
       float2 scr : INSTSCR, float2 atl : INSTATL, float2 wh : INSTWH,
       float pal : INSTPAL, float a : INSTA) {
    VO o;
    float2 corner = float2(float(vid & 1u), float((vid >> 1) & 1u));
    float2 pos = scr + corner * wh;
    o.p = float4(pos.x / 320.0 - 1.0, 1.0 - pos.y / 180.0, 0.0, 1.0);
    o.atl = atl + corner * wh;
    o.pal = pal;
    o.a = a;
    o.org = atl;
    o.wh = wh;
    return o;
}

float4 sps(VO v) : SV_Target {
    int ax = (int)v.atl.x;
    int ay = (int)v.atl.y;
    int x0 = (int)v.org.x;
    int y0 = (int)v.org.y;
    ax = clamp(ax, x0, x0 + (int)v.wh.x - 1);
    ay = clamp(ay, y0, y0 + (int)v.wh.y - 1);
    ax = clamp(ax, 0, 511);
    ay = clamp(ay, 0, 511);
    uint c = idxAtlas.Load(int3(ax, ay, 0));
    if (c == 0u) discard;
    int slot = (int)(v.pal + 0.5);
    float4 col = spritePal.Load(int3((int)c, slot, 0));
    return float4(col.rgb, v.a);
}
"""
)


@fieldwise_init
struct AtlasFrame(ImplicitlyCopyable, Copyable, Movable):
    """Where one frame's pixels live in the atlas.

    Named for the atlas, not `Frame`: `window.Frame` is the per-frame token
    the pane hands out, and two things called Frame in one package is how a
    reader loses an afternoon.
    """

    var x: Int
    var y: Int
    var w: Int
    var h: Int


struct Sprites(Movable):
    """The atlas, the palette LUT, and the one pass that draws them all.

    Created once. `push` costs eight float writes into a CPU mirror;
    `render` maps the instance buffer once, copies, and issues a single
    DrawInstanced.
    """

    var device: Int
    var context: Int
    var vs: Int
    var ps: Int
    var layout: Int
    var blend_alpha: Int

    var tex_atlas: Int
    var srv_atlas: Int
    var tex_pal: Int
    var srv_pal: Int
    var inst_vb: Int

    var atlas: List[UInt8]
    """The atlas's CPU mirror, one byte a pixel."""
    var atlas_dirty: Bool
    var pal: List[UInt8]
    """16 x 32 BGRA."""
    var pal_dirty: Bool

    var frames: List[AtlasFrame]
    var shelf_x: Int
    var shelf_y: Int
    var shelf_h: Int
    """A shelf packer, as the reference's is: frames go left to right until
    the row is full, then a new row starts below the tallest so far."""

    var inst: List[Float32]
    """The per-frame instance mirror -- eight floats each."""
    var count: Int

    var views: List[Int]

    def __init__(out self, device: Int, context: Int) raises:
        self.device = device
        self.context = context

        var compile = resolve_compiler()
        var empty = List[UInt8]()
        var src = _bytes(String(SPRITE_SHADER))
        var vs_blob = compile_shader_blob(
            compile, src, empty, empty, _bytes(String("svs")),
            _bytes(String("vs_5_0")),
        )
        self.vs = create_vertex_shader(device, vs_blob[0], vs_blob[1])
        var ps_blob = compile_shader_blob(
            compile, src, empty, empty, _bytes(String("sps")),
            _bytes(String("ps_5_0")),
        )
        self.ps = create_pixel_shader(device, ps_blob[0], ps_blob[1])

        # The per-instance attributes. One slot, PER_INSTANCE_DATA, step 1:
        # the quad's four vertices come from SV_VertexID, so every attribute
        # here advances once per SPRITE rather than once per vertex.
        var sem_scr = _bytes(String("INSTSCR"))
        var sem_atl = _bytes(String("INSTATL"))
        var sem_wh = _bytes(String("INSTWH"))
        var sem_pal = _bytes(String("INSTPAL"))
        var sem_a = _bytes(String("INSTA"))
        var elements = List[D3D11_INPUT_ELEMENT_DESC]()
        elements.append(D3D11_INPUT_ELEMENT_DESC(
            Int(sem_scr.unsafe_ptr()), 0, _FORMAT_R32G32_FLOAT, 0, 0,
            _PER_INSTANCE_DATA, 1,
        ))
        elements.append(D3D11_INPUT_ELEMENT_DESC(
            Int(sem_atl.unsafe_ptr()), 0, _FORMAT_R32G32_FLOAT, 0, 8,
            _PER_INSTANCE_DATA, 1,
        ))
        elements.append(D3D11_INPUT_ELEMENT_DESC(
            Int(sem_wh.unsafe_ptr()), 0, _FORMAT_R32G32_FLOAT, 0, 16,
            _PER_INSTANCE_DATA, 1,
        ))
        elements.append(D3D11_INPUT_ELEMENT_DESC(
            Int(sem_pal.unsafe_ptr()), 0, _FORMAT_R32_FLOAT, 0, 24,
            _PER_INSTANCE_DATA, 1,
        ))
        elements.append(D3D11_INPUT_ELEMENT_DESC(
            Int(sem_a.unsafe_ptr()), 0, _FORMAT_R32_FLOAT, 0, 28,
            _PER_INSTANCE_DATA, 1,
        ))
        self.layout = create_input_layout(
            device, elements, vs_blob[0], vs_blob[1]
        )
        # The semantic strings are pointed at by the descriptors above, so
        # they have to outlive CreateInputLayout -- and they do, because
        # `elements` and they die together at the end of this scope, after
        # the call. Keeping them alive to here is deliberate.
        _ = sem_scr
        _ = sem_atl
        _ = sem_wh
        _ = sem_pal
        _ = sem_a

        self.blend_alpha = create_blend_state(device, True)

        self.tex_atlas = create_texture2d(
            device, SPR_ATLAS_DIM, SPR_ATLAS_DIM, _FORMAT_R8_UINT,
            _BIND_SHADER_RESOURCE, _USAGE_DEFAULT, 0,
        )
        self.srv_atlas = create_srv(device, self.tex_atlas, _FORMAT_R8_UINT)
        self.tex_pal = create_texture2d(
            device, SPR_PAL_WIDE, SPR_PAL_SLOTS, _FORMAT_B8G8R8A8_UNORM,
            _BIND_SHADER_RESOURCE, _USAGE_DEFAULT, 0,
        )
        self.srv_pal = create_srv(
            device, self.tex_pal, _FORMAT_B8G8R8A8_UNORM
        )
        self.inst_vb = create_buffer_dynamic(
            device, SPR_MAX_INST * SPR_STRIDE, _BIND_VERTEX_BUFFER
        )

        self.atlas = List[UInt8](
            length=SPR_ATLAS_DIM * SPR_ATLAS_DIM, fill=0
        )
        self.atlas_dirty = True
        self.pal = List[UInt8](
            length=SPR_PAL_WIDE * SPR_PAL_SLOTS * 4, fill=0
        )
        self.pal_dirty = True
        self.frames = List[AtlasFrame]()
        self.shelf_x = 0
        self.shelf_y = 0
        self.shelf_h = 0
        self.inst = List[Float32](length=SPR_MAX_INST * 8, fill=0.0)
        self.count = 0
        self.views = List[Int](length=2, fill=0)
        self.views[0] = self.srv_atlas
        self.views[1] = self.srv_pal

    # ── authoring ───────────────────────────────────────────────────────
    def add_frame(
        mut self, width: Int, height: Int, pixels: List[UInt8]
    ) raises -> Int:
        """Pack one frame's indices into the atlas; returns its id.

        A shelf packer, like the reference's: frames fill a row left to
        right, then start a new row under the tallest frame so far. No
        gutter, which is why the pixel shader clamps to the frame's own
        rect before it clamps to the atlas.
        """
        if width <= 0 or height <= 0 or width > SPR_ATLAS_DIM:
            raise Error("add_frame: frame does not fit the atlas")
        if self.shelf_x + width > SPR_ATLAS_DIM:
            self.shelf_x = 0
            self.shelf_y += self.shelf_h
            self.shelf_h = 0
        if self.shelf_y + height > SPR_ATLAS_DIM:
            raise Error("add_frame: the atlas is full")
        var fx = self.shelf_x
        var fy = self.shelf_y
        for row in range(height):
            var src = row * width
            var dst = (fy + row) * SPR_ATLAS_DIM + fx
            for col in range(width):
                self.atlas[dst + col] = pixels[src + col]
        self.shelf_x += width
        if height > self.shelf_h:
            self.shelf_h = height
        self.frames.append(AtlasFrame(fx, fy, width, height))
        self.atlas_dirty = True
        return len(self.frames) - 1

    def set_palette(
        mut self, slot: Int, colour: Int, r: Int, g: Int, b: Int
    ):
        """One colour of one slot. Colour 0 is never sampled -- the shader
        discards index 0 before it reaches the palette."""
        if slot < 0 or slot >= SPR_PAL_SLOTS:
            return
        if colour < 0 or colour >= SPR_PAL_WIDE:
            return
        var o = (slot * SPR_PAL_WIDE + colour) * 4
        self.pal[o + 0] = UInt8(b & 255)
        self.pal[o + 1] = UInt8(g & 255)
        self.pal[o + 2] = UInt8(r & 255)
        self.pal[o + 3] = 255
        self.pal_dirty = True

    # ── per frame ───────────────────────────────────────────────────────
    def clear(mut self):
        """Drop last frame's instances. Called once at the top of a frame."""
        self.count = 0

    def push(
        mut self, frame: Int, x: Float32, y: Float32, slot: Int,
        alpha: Float32 = 1.0,
    ):
        """Place one sprite. Eight float writes and nothing else -- no
        upload, no bind, no draw. They all happen once, in `render`."""
        if frame < 0 or frame >= len(self.frames):
            return
        if self.count >= SPR_MAX_INST:
            return
        var f = self.frames[frame]
        var o = self.count * 8
        self.inst[o + 0] = x
        self.inst[o + 1] = y
        self.inst[o + 2] = Float32(f.x)
        self.inst[o + 3] = Float32(f.y)
        self.inst[o + 4] = Float32(f.w)
        self.inst[o + 5] = Float32(f.h)
        self.inst[o + 6] = Float32(slot)
        self.inst[o + 7] = alpha
        self.count += 1

    def render(mut self, rtv: Int) raises:
        """Every sprite pushed this frame, in one DrawInstanced.

        The render target is expected to be bound already -- the canvas
        binds it and clears, and the sprites composite over what is there.
        """
        if self.count == 0:
            return
        if self.atlas_dirty:
            update_subresource(
                self.context, self.tex_atlas,
                self.atlas.unsafe_ptr().unsafe_origin_cast[
                    MutUntrackedOrigin
                ](),
                SPR_ATLAS_DIM,
            )
            self.atlas_dirty = False
        if self.pal_dirty:
            update_subresource(
                self.context, self.tex_pal,
                self.pal.unsafe_ptr().unsafe_origin_cast[
                    MutUntrackedOrigin
                ](),
                SPR_PAL_WIDE * 4,
            )
            self.pal_dirty = False

        # One map, one copy, one draw.
        var dst = map_write_discard(self.context, self.inst_vb)
        var src = self.inst.unsafe_ptr().unsafe_bitcast[UInt8]()
        var bytes = self.count * SPR_STRIDE
        for i in range(bytes):
            dst[unsafe_offset=i] = src[unsafe_offset=i]
        unmap(self.context, self.inst_vb)

        om_set_blend_state(self.context, self.blend_alpha)
        vs_set_shader(self.context, self.vs)
        ps_set_shader(self.context, self.ps)
        ps_set_shader_resources(self.context, self.views)
        ia_set_input_layout(self.context, self.layout)
        ia_set_vertex_buffer(self.context, self.inst_vb, SPR_STRIDE)
        ia_set_topology(self.context, _TOPOLOGY_TRIANGLESTRIP)
        draw_instanced(self.context, 4, self.count)
