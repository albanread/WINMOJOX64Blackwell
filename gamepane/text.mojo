# ===----------------------------------------------------------------------=== #
# G5 -- text, from RASM's gpu/text.was.
#
# One DrawInstanced for every glyph on screen, in every colour at once. A
# title, a score and a debug overlay in three different colours cost exactly
# one draw call between them, because the COLOUR TRAVELS IN THE INSTANCE
# rather than in a constant buffer -- which is the whole reason this layer is
# shaped the way it is.
#
#   font atlas  128x64 R8_UINT   16 x 8 cells of 8x8, baked at init
#   instances   4096 x 32 bytes  DYNAMIC vertex buffer, refilled per frame
#   transform   float4 in VS b0  scale.xy, offset.xy; identity by default
#
# The atlas is NOT indexed like the sprite atlas, and the difference is worth
# understanding before touching either. A sprite frame is allocated by a
# packer and remembered in a table, so an instance has to carry {atlasX,
# atlasY, w, h}. A GLYPH's cell is arithmetic -- `cellX = (ch & 15) * 8`,
# `cellY = (ch >> 4) * 8`, size always 8x8 -- so there is no table, no
# allocator, and the two floats a sprite spends on {w, h} are spent here on
# {r, g} instead. That is the trade that makes per-glyph colour free.
#
# The font is 896 bytes of 5x7 bitmap embedded in the source. Five columns
# wide inside an eight-wide cell, and the pen advances SIX pixels, so
# adjacent glyph quads overlap by two. That is only correct because the bake
# leaves cell columns 5..7 at index 0 and the pixel shader discards index 0 --
# widen the glyph or change the advance and it silently breaks.
#
# The pixel shader clamps TWICE and both clamps are load-bearing. The quad's
# interpolated atlas coordinate reaches origin+8.0 exactly at the far edge,
# so `int()` can land on the first texel of the NEXT glyph's cell; the vertex
# shader forwards the un-offset cell origin as a flat attribute purely so the
# pixel shader can clamp to this glyph's own 8x8 rect. The second clamp, to
# the real 127x63, is the guard against a garbage instance.
# ===----------------------------------------------------------------------=== #

from std.memory import Pointer
from .canvas import _bytes, _cstr
from .device import (
    D3D11_INPUT_ELEMENT_DESC,
    compile_shader_blob,
    create_blend_state,
    create_buffer,
    create_buffer_dynamic,
    create_input_layout,
    create_pixel_shader,
    create_rasterizer_state,
    create_srv,
    create_texture2d,
    create_vertex_shader,
    draw_instanced,
    ia_set_input_layout,
    ia_set_topology,
    ia_set_vertex_buffer,
    map_write_discard,
    om_set_blend_state,
    om_set_render_targets,
    ps_set_shader,
    ps_set_shader_resources,
    resolve_compiler,
    rs_set_state,
    unmap,
    update_subresource,
    vs_set_constant_buffers,
    vs_set_shader,
)

comptime FONT_ATLAS_W = 128
comptime FONT_ATLAS_H = 64
comptime GLYPH_CELL = 8
"""The atlas cell, and the quad's size in the shader. 16 cells across x 8
down covers ASCII 0..127 with the cell computed rather than looked up."""

comptime PEN_ADVANCE = 6
"""The reference's tight spacing. Two pixels narrower than the cell, which
works only because the glyph is five columns wide and the rest discards."""

comptime TXT_MAX_INST = 4096
comptime TXT_STRIDE = 32
"""Eight floats: screenX, screenY, atlasX, atlasY, r, g, b, pad."""

comptime _FORMAT_R8_UINT = 62
comptime _FORMAT_R32G32_FLOAT = 16
comptime _FORMAT_R32G32B32_FLOAT = 6
comptime _BIND_SHADER_RESOURCE = 8
comptime _BIND_VERTEX_BUFFER = 1
comptime _BIND_CONSTANT_BUFFER = 4
comptime _USAGE_DEFAULT = 0
comptime _TOPOLOGY_TRIANGLESTRIP = 5
comptime _PER_INSTANCE_DATA = 1


comptime TEXT_SHADER = String(
    """
Texture2D<uint> fontAtlas:register(t0);
cbuffer TXF:register(b0){float4 txf;};
struct VO{float4 p:SV_Position;float2 atl:TEXCOORD0;nointerpolation float3 col:TEXCOORD1;
          nointerpolation float2 org:TEXCOORD2;};
VO TXVS(uint vid:SV_VertexID,
        float2 scr:INSTPOS, float2 atl:INSTCEL, float3 col:INSTCOL){
  VO o;
  float2 corner=float2((float)(vid&1u),(float)((vid>>1)&1u));
  float2 pos=scr+corner*8.0;
  float2 op=pos*txf.xy+txf.zw;
  o.p=float4(op.x/320.0-1.0, 1.0-op.y/180.0, 0.0, 1.0);
  o.atl=atl+corner*8.0;
  o.col=col;
  o.org=atl;
  return o;
}
float4 TXPS(VO v):SV_Target{
  int ax=(int)v.atl.x; int ay=(int)v.atl.y;
  int x0=(int)v.org.x; int y0=(int)v.org.y;
  ax=clamp(ax, x0, x0+7);
  ay=clamp(ay, y0, y0+7);
  ax=clamp(ax,0,127); ay=clamp(ay,0,63);
  uint c=fontAtlas.Load(int3(ax,ay,0));
  if(c==0u) discard;
  return float4(v.col, 1.0);
}
"""
)
"""The reference's text shader, verbatim.

The NDC divisors 320 and 180 are half the 640x360 physical canvas, shared
with the index plane, the resolve pass and the sprite layer -- text lands in
the same coordinate space a fill does. `txf` is applied AFTER the corner is
added, so a scale enlarges the glyph as well as moving the pen; identity
(1,1,0,0) is the constructed default, so a caller that never sets a transform
gets un-scaled placement with no branch anywhere."""


comptime FONT_ROWS = 7
"""Bytes per glyph. Five columns are used, in the low five bits."""


def font_table() -> List[UInt8]:
    """The embedded 5x7 font, transcribed from RASM's
    library/gc_font.inc: 128 glyphs of 7 rows, ASCII-indexed.

    One byte is one scanline, top row first, and only the low five
    bits are used -- bit 4 (0x10) is the LEFTMOST column and bit 0
    the fifth. 'A' is 14,17,17,17,31,17,17, which reads

        01110   10001   10001   10001   11111   10001   10001

    if you write the bits out. 896 bytes is the entire font: there
    is no font file, no rasteriser and no reload path, which is why
    a text layer can exist without a dependency on GDI or DirectWrite.

    Codes 97..122 are byte-for-byte copies of 65..90, so the font has
    no lower case -- `draw_text` folds anyway, for parity with the
    reference, and the fold is invisible rather than load-bearing.
    """
    var f = List[UInt8](length=128 * FONT_ROWS, fill=0)
    _glyph(f, 33, 4, 4, 4, 4, 4, 0, 4)  # '!'
    _glyph(f, 40, 4, 8, 16, 16, 16, 8, 4)  # '('
    _glyph(f, 41, 4, 2, 1, 1, 1, 2, 4)  # ')'
    _glyph(f, 43, 0, 4, 4, 31, 4, 4, 0)  # '+'
    _glyph(f, 44, 0, 0, 0, 0, 12, 12, 8)  # ','
    _glyph(f, 45, 0, 0, 0, 31, 0, 0, 0)  # '-'
    _glyph(f, 46, 0, 0, 0, 0, 0, 12, 12)  # '.'
    _glyph(f, 47, 1, 2, 4, 4, 8, 16, 16)  # '/'
    _glyph(f, 48, 14, 17, 19, 21, 25, 17, 14)  # '0'
    _glyph(f, 49, 4, 12, 4, 4, 4, 4, 14)  # '1'
    _glyph(f, 50, 14, 17, 1, 6, 8, 16, 31)  # '2'
    _glyph(f, 51, 31, 1, 2, 6, 1, 17, 14)  # '3'
    _glyph(f, 52, 2, 6, 10, 18, 31, 2, 2)  # '4'
    _glyph(f, 53, 31, 16, 30, 1, 1, 17, 14)  # '5'
    _glyph(f, 54, 6, 8, 16, 30, 17, 17, 14)  # '6'
    _glyph(f, 55, 31, 1, 2, 4, 8, 8, 8)  # '7'
    _glyph(f, 56, 14, 17, 17, 14, 17, 17, 14)  # '8'
    _glyph(f, 57, 14, 17, 17, 15, 1, 2, 12)  # '9'
    _glyph(f, 58, 0, 12, 12, 0, 12, 12, 0)  # ':'
    _glyph(f, 65, 14, 17, 17, 17, 31, 17, 17)  # 'A'
    _glyph(f, 66, 30, 17, 17, 30, 17, 17, 30)  # 'B'
    _glyph(f, 67, 14, 17, 16, 16, 16, 17, 14)  # 'C'
    _glyph(f, 68, 30, 17, 17, 17, 17, 17, 30)  # 'D'
    _glyph(f, 69, 31, 16, 16, 30, 16, 16, 31)  # 'E'
    _glyph(f, 70, 31, 16, 16, 30, 16, 16, 16)  # 'F'
    _glyph(f, 71, 14, 17, 16, 23, 17, 17, 15)  # 'G'
    _glyph(f, 72, 17, 17, 17, 31, 17, 17, 17)  # 'H'
    _glyph(f, 73, 14, 4, 4, 4, 4, 4, 14)  # 'I'
    _glyph(f, 74, 7, 2, 2, 2, 18, 18, 12)  # 'J'
    _glyph(f, 75, 17, 18, 20, 24, 20, 18, 17)  # 'K'
    _glyph(f, 76, 16, 16, 16, 16, 16, 16, 31)  # 'L'
    _glyph(f, 77, 17, 27, 21, 21, 17, 17, 17)  # 'M'
    _glyph(f, 78, 17, 25, 21, 19, 17, 17, 17)  # 'N'
    _glyph(f, 79, 14, 17, 17, 17, 17, 17, 14)  # 'O'
    _glyph(f, 80, 30, 17, 17, 30, 16, 16, 16)  # 'P'
    _glyph(f, 81, 14, 17, 17, 17, 21, 18, 13)  # 'Q'
    _glyph(f, 82, 30, 17, 17, 30, 20, 18, 17)  # 'R'
    _glyph(f, 83, 15, 16, 16, 14, 1, 1, 30)  # 'S'
    _glyph(f, 84, 31, 4, 4, 4, 4, 4, 4)  # 'T'
    _glyph(f, 85, 17, 17, 17, 17, 17, 17, 14)  # 'U'
    _glyph(f, 86, 17, 17, 17, 17, 17, 10, 4)  # 'V'
    _glyph(f, 87, 17, 17, 17, 21, 21, 27, 17)  # 'W'
    _glyph(f, 88, 17, 17, 10, 4, 10, 17, 17)  # 'X'
    _glyph(f, 89, 17, 17, 10, 4, 4, 4, 4)  # 'Y'
    _glyph(f, 90, 31, 1, 2, 4, 8, 16, 31)  # 'Z'
    _glyph(f, 97, 14, 17, 17, 17, 31, 17, 17)  # 'a'
    _glyph(f, 98, 30, 17, 17, 30, 17, 17, 30)  # 'b'
    _glyph(f, 99, 14, 17, 16, 16, 16, 17, 14)  # 'c'
    _glyph(f, 100, 30, 17, 17, 17, 17, 17, 30)  # 'd'
    _glyph(f, 101, 31, 16, 16, 30, 16, 16, 31)  # 'e'
    _glyph(f, 102, 31, 16, 16, 30, 16, 16, 16)  # 'f'
    _glyph(f, 103, 14, 17, 16, 23, 17, 17, 15)  # 'g'
    _glyph(f, 104, 17, 17, 17, 31, 17, 17, 17)  # 'h'
    _glyph(f, 105, 14, 4, 4, 4, 4, 4, 14)  # 'i'
    _glyph(f, 106, 7, 2, 2, 2, 18, 18, 12)  # 'j'
    _glyph(f, 107, 17, 18, 20, 24, 20, 18, 17)  # 'k'
    _glyph(f, 108, 16, 16, 16, 16, 16, 16, 31)  # 'l'
    _glyph(f, 109, 17, 27, 21, 21, 17, 17, 17)  # 'm'
    _glyph(f, 110, 17, 25, 21, 19, 17, 17, 17)  # 'n'
    _glyph(f, 111, 14, 17, 17, 17, 17, 17, 14)  # 'o'
    _glyph(f, 112, 30, 17, 17, 30, 16, 16, 16)  # 'p'
    _glyph(f, 113, 14, 17, 17, 17, 21, 18, 13)  # 'q'
    _glyph(f, 114, 30, 17, 17, 30, 20, 18, 17)  # 'r'
    _glyph(f, 115, 15, 16, 16, 14, 1, 1, 30)  # 's'
    _glyph(f, 116, 31, 4, 4, 4, 4, 4, 4)  # 't'
    _glyph(f, 117, 17, 17, 17, 17, 17, 17, 14)  # 'u'
    _glyph(f, 118, 17, 17, 17, 17, 17, 10, 4)  # 'v'
    _glyph(f, 119, 17, 17, 17, 21, 21, 27, 17)  # 'w'
    _glyph(f, 120, 17, 17, 10, 4, 10, 17, 17)  # 'x'
    _glyph(f, 121, 17, 17, 10, 4, 4, 4, 4)  # 'y'
    _glyph(f, 122, 31, 1, 2, 4, 8, 16, 31)  # 'z'
    return f^


def _glyph(
    mut f: List[UInt8],
    code: Int,
    r0: UInt8, r1: UInt8, r2: UInt8, r3: UInt8,
    r4: UInt8, r5: UInt8, r6: UInt8,
):
    """One glyph's seven rows. Written as a call per glyph so the
    table reads as the source it came from rather than as a flat
    896-element literal nobody can check against anything."""
    var b = code * FONT_ROWS
    f[b + 0] = r0
    f[b + 1] = r1
    f[b + 2] = r2
    f[b + 3] = r3
    f[b + 4] = r4
    f[b + 5] = r5
    f[b + 6] = r6


struct Text(Movable):
    """The font atlas, one instance buffer, and the pass that empties it."""

    var device: Int
    var context: Int
    var vs: Int
    var ps: Int
    var layout: Int
    var rast: Int
    var blend_alpha: Int

    var tex_font: Int
    var srv_font: Int
    var inst_vb: Int
    var xform_cb: Int

    var inst: List[Float32]
    """The CPU mirror, eight floats per glyph. `draw` writes here and does
    nothing else; one Map a frame carries the lot across."""
    var count: Int
    var col_r: Float32
    var col_g: Float32
    var col_b: Float32
    """The pen colour, snapshotted into each instance as it is queued. This
    is why three colours cost one draw call and not three."""

    def __init__(out self, device: Int, context: Int) raises:
        self.device = device
        self.context = context
        self.count = 0
        self.col_r = 1.0
        self.col_g = 1.0
        self.col_b = 1.0

        var compile = resolve_compiler()
        var empty = List[UInt8]()
        var src = _bytes(String(TEXT_SHADER))
        var vs_blob = compile_shader_blob(
            compile, src, empty, empty, _bytes(String("TXVS")),
            _bytes(String("vs_5_0")),
        )
        self.vs = create_vertex_shader(device, vs_blob[0], vs_blob[1])
        var ps_blob = compile_shader_blob(
            compile, src, empty, empty, _bytes(String("TXPS")),
            _bytes(String("ps_5_0")),
        )
        self.ps = create_pixel_shader(device, ps_blob[0], ps_blob[1])

        # Three per-instance attributes. No per-vertex slot at all: the
        # quad's four corners come from SV_VertexID, so everything the
        # layout describes advances once per GLYPH.
        var sem_pos = _cstr(String("INSTPOS"))
        var sem_cel = _cstr(String("INSTCEL"))
        var sem_col = _cstr(String("INSTCOL"))
        var elements = List[D3D11_INPUT_ELEMENT_DESC]()
        elements.append(D3D11_INPUT_ELEMENT_DESC(
            Int(sem_pos.unsafe_ptr()), 0, _FORMAT_R32G32_FLOAT, 0, 0,
            _PER_INSTANCE_DATA, 1,
        ))
        elements.append(D3D11_INPUT_ELEMENT_DESC(
            Int(sem_cel.unsafe_ptr()), 0, _FORMAT_R32G32_FLOAT, 0, 8,
            _PER_INSTANCE_DATA, 1,
        ))
        elements.append(D3D11_INPUT_ELEMENT_DESC(
            Int(sem_col.unsafe_ptr()), 0, _FORMAT_R32G32B32_FLOAT, 0, 16,
            _PER_INSTANCE_DATA, 1,
        ))
        self.layout = create_input_layout(
            device, elements, vs_blob[0], vs_blob[1]
        )
        # The semantic strings are pointed at by the descriptors, so they
        # have to outlive CreateInputLayout. Keeping them alive to here is
        # deliberate, not incidental.
        _ = sem_pos
        _ = sem_cel
        _ = sem_col

        self.rast = create_rasterizer_state(device)
        self.blend_alpha = create_blend_state(device, True)

        self.tex_font = create_texture2d(
            device, FONT_ATLAS_W, FONT_ATLAS_H, _FORMAT_R8_UINT,
            _BIND_SHADER_RESOURCE, _USAGE_DEFAULT, 0,
        )
        self.srv_font = create_srv(device, self.tex_font, _FORMAT_R8_UINT)
        self.inst_vb = create_buffer_dynamic(
            device, TXT_MAX_INST * TXT_STRIDE, _BIND_VERTEX_BUFFER
        )
        self.xform_cb = create_buffer(
            device, 16, _BIND_CONSTANT_BUFFER, _USAGE_DEFAULT
        )
        self.inst = List[Float32](
            length=TXT_MAX_INST * (TXT_STRIDE // 4), fill=0.0
        )

        # The atlas, baked and uploaded once. Nothing writes it again: there
        # is no runtime glyph, which is the reason there is no allocator.
        var atlas = bake_font()
        update_subresource(
            context, self.tex_font,
            atlas.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
            FONT_ATLAS_W,
        )
        _ = atlas

        # Identity, uploaded now rather than on a first `set_transform`.
        # A caller that never sets one must still have a valid transform
        # bound on frame zero, or the first frame draws garbage.
        self.set_transform(1.0, 1.0, 0.0, 0.0)

    # ── building a frame's text ─────────────────────────────────────────
    def set_transform(
        mut self, sx: Float32, sy: Float32, ox: Float32, oy: Float32
    ) raises:
        """Scale and offset applied to every glyph, in physical canvas
        pixels. Applied after the corner is added, so it scales the GLYPH as
        well as the pen -- a 1.8 scale gives 14.4-pixel characters."""
        var xf = List[Float32](length=4, fill=0.0)
        xf[0] = sx
        xf[1] = sy
        xf[2] = ox
        xf[3] = oy
        update_subresource(
            self.context, self.xform_cb,
            xf.unsafe_ptr().unsafe_bitcast[UInt8]()
                .unsafe_origin_cast[MutUntrackedOrigin](),
            0,
        )
        _ = xf

    def set_colour(mut self, r: Int, g: Int, b: Int):
        """The pen colour for glyphs queued from now on, 0..255 a channel.

        It affects nothing already queued: the colour is copied into each
        instance at queue time. Set it, draw a string, set it again."""
        self.col_r = Float32(r & 255) / 255.0
        self.col_g = Float32(g & 255) / 255.0
        self.col_b = Float32(b & 255) / 255.0

    def clear(mut self):
        """Start a frame's text. The queue is emptied, not the screen."""
        self.count = 0

    def draw(mut self, x: Int, y: Int, s: String) -> Int:
        """Queue one string at physical canvas pixels (x, y). Draws nothing.

        Returns the pen x after the string, so a caller can append without
        counting characters itself -- the reference makes callers do that
        arithmetic and every one of them gets it slightly wrong.

        The rules are the reference's, including the ones that look like
        oversights and are not:
          * lower case folds to upper. The font stores identical glyphs at
            both, so the fold changes nothing visible; it is kept because
            deleting it would make the duplicate half of the table load-
            bearing without saying so.
          * space queues NO instance but still advances the pen. A blank
            glyph would burn a slot for nothing.
          * a code above 127 advances without drawing -- there is no glyph
            and there is no substitution.
          * running out of instances ABANDONS the rest of the string. Losing
            the tail of a line is more legible than losing a line."""
        var pen = x
        for byte in s.as_bytes():
            var ch = Int(byte)
            if ch >= 97 and ch <= 122:
                ch -= 32
            if ch != 32 and ch < 128:
                if self.count >= TXT_MAX_INST:
                    return pen
                var b = self.count * (TXT_STRIDE // 4)
                self.inst[b + 0] = Float32(pen)
                self.inst[b + 1] = Float32(y)
                self.inst[b + 2] = Float32((ch & 15) * GLYPH_CELL)
                self.inst[b + 3] = Float32((ch >> 4) * GLYPH_CELL)
                self.inst[b + 4] = self.col_r
                self.inst[b + 5] = self.col_g
                self.inst[b + 6] = self.col_b
                self.inst[b + 7] = 0.0
                self.count += 1
            pen += PEN_ADVANCE
        return pen

    def text_width(self, s: String) -> Int:
        """What `draw` will advance the pen by. Every character counts, so
        this is exact rather than an estimate."""
        return s.byte_length() * PEN_ADVANCE

    # ── the pass ────────────────────────────────────────────────────────
    def render(mut self, rtv: Int) raises:
        """Upload the queue and issue ONE DrawInstanced.

        No viewport is set, deliberately and like the reference: a caller
        compositing text into a 640x360 layer wants a different one from a
        caller drawing onto a 1280x720 back buffer, and this layer has no way
        to know which. Every caller sets it immediately before.

        The draw is issued even at zero glyphs. That is not laziness -- it
        means the pass always re-binds the whole pipeline, which is what
        makes it safe to call straight after a sprite pass that left other
        shaders and another vertex buffer bound."""
        var dst = map_write_discard(self.context, self.inst_vb)
        var src = self.inst.unsafe_ptr().unsafe_bitcast[UInt8]()
        var bytes = self.count * TXT_STRIDE
        for i in range(bytes):
            dst[unsafe_offset=i] = src[unsafe_offset=i]
        unmap(self.context, self.inst_vb)

        om_set_render_targets(self.context, rtv)
        ia_set_input_layout(self.context, self.layout)
        ia_set_vertex_buffer(self.context, self.inst_vb, TXT_STRIDE)
        vs_set_shader(self.context, self.vs)
        ps_set_shader(self.context, self.ps)
        rs_set_state(self.context, self.rast)
        vs_set_constant_buffers(self.context, self.xform_cb)
        var views = List[Int](length=1, fill=self.srv_font)
        ps_set_shader_resources(self.context, views)
        om_set_blend_state(self.context, self.blend_alpha)
        ia_set_topology(self.context, _TOPOLOGY_TRIANGLESTRIP)
        draw_instanced(self.context, 4, self.count)


def bake_font() -> List[UInt8]:
    """Expand the 896-byte bitmap into the 128x64 atlas.

    Glyph `g` lands at cell (g & 15, g >> 4), and within it the bit walk is
    `mask = 16 >> col` for col 0..4 -- bit 4 is the leftmost column. The
    atlas starts zeroed and stays zero in cell columns 5..7 and row 7, which
    is precisely what makes the six-pixel pen advance safe against an
    eight-pixel quad."""
    var f = font_table()
    var atlas = List[UInt8](length=FONT_ATLAS_W * FONT_ATLAS_H, fill=0)
    for g in range(128):
        var cell_x = (g & 15) * GLYPH_CELL
        var cell_y = (g >> 4) * GLYPH_CELL
        for row in range(FONT_ROWS):
            var bits = Int(f[g * FONT_ROWS + row])
            for col in range(5):
                if (bits & (16 >> col)) != 0:
                    atlas[
                        (cell_y + row) * FONT_ATLAS_W + cell_x + col
                    ] = 1
    return atlas^
