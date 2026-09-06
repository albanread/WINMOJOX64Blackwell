# ===----------------------------------------------------------------------=== #
# G1 -- the layer pool and the composite, ported from RASM's gpu/blit.was.
#
# The G3 commit ported half of G1: the two blend states, which the sprite
# pass consumes. This is the other half, and G2 is what wanted it.
#
# THE MODEL. A layer is a 640x360 RGBA texture that is BOTH a render target
# and a shader resource. A pass draws into it; the compositor then draws it
# onto the back buffer as a full-screen triangle. Layers are allocated from a
# fixed pool of sixteen and never freed, because a game's layer set is
# decided when it starts and a pool that can fail at frame 400 is worse than
# one that cannot grow.
#
# TRANSPARENCY IS A COLOUR KEY, NOT AN ALPHA CHANNEL. A layer writes pure
# magenta where it wants to show what is underneath, and the composite's
# pixel shader discards any texel within 0.02 of the key. That looks archaic
# and is deliberate: the tile and mode-7 layers resolve INDICES through a
# palette, and an index has no alpha to carry. Index 0 becomes magenta in the
# tile shader and disappears here, which is the same mechanism as the sprite
# atlas's `if (c == 0u) discard` one layer up.
#
# Consequence, and the reason draw order is not a preference: a discard
# reveals whatever is ALREADY in the destination, so layers composite
# BACK TO FRONT -- far first, near last. The reference's own header notes
# that the G2 brief said front-to-back and the code does the opposite,
# because the opposite is right.
#
# TWO ORDERING RULES, both of which produce silent black rather than an
# error when broken:
#
#   * bind the destination render target FIRST, before binding the source
#     view. Binding an RT unbinds the previous one, which is what makes the
#     texture that was just a render target legal to sample. Reverse it and
#     an SRV and an RTV alias the same resource; D3D11 resolves that by
#     giving the shader black and saying nothing.
#
#   * set the rasterizer state in EVERY pass. Nothing is inherited and
#     D3D11's default is CULL_BACK, which culls a full-screen triangle. This
#     is the failure this port already hit once.
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
    create_render_target_view,
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

comptime POOL_SLOTS = 16
"""The reference's fixed capacity. A game allocates its layers at startup."""

comptime BLIT_COPY = 0
comptime BLIT_KEY = 1
comptime BLIT_ALPHA = 2
"""0 every texel lands; 1 the key is discarded; 2 the blend state does the
SRC_ALPHA/INV_SRC_ALPHA arithmetic and the shader just passes colour on."""

comptime KEY_MAGENTA = 0x00FF00FF
"""R=FF G=00 B=FF, in the reference's 0x00RRGGBB byte order. Magenta because
no palette in the reference's demos contains it, which is the only property
a colour key needs and the only one that can be got wrong."""

comptime _FORMAT_R8G8B8A8_UNORM = 28
comptime _BIND_SHADER_RESOURCE = 8
comptime _BIND_RENDER_TARGET = 32
comptime _BIND_CONSTANT_BUFFER = 4
comptime _USAGE_DEFAULT = 0
comptime _TOPOLOGY_TRIANGLELIST = 4


comptime BLIT_SHADER = String(
    """
Texture2D<float4> src:register(t0);
cbuffer BCB:register(b0){float4 keyCol;float4 modeF;};
struct VO{float4 p:SV_Position;float2 uv:TEXCOORD0;};
VO BVS(uint i:SV_VertexID){VO o;float2 u=float2((i<<1)&2,i&2);o.p=float4(u.x*2-1,1-u.y*2,0,1);o.uv=u;return o;}
float4 BPS(VO v):SV_Target{
int px=(int)(v.uv.x*640.0);int py=(int)(v.uv.y*360.0);
px=clamp(px,0,639);py=clamp(py,0,359);
float4 c=src.Load(int3(px,py,0));
int m=(int)(modeF.x+0.5);
if(m==1){float3 d=abs(c.rgb-keyCol.rgb);if(d.x<0.02&&d.y<0.02&&d.z<0.02)discard;}
return c;}
"""
)
"""The reference's blit shader, verbatim.

Two things in it are worth not tidying. The fetch is an integer `.Load` at
640x360 with no sampler anywhere, so compositing a 640x360 layer onto a
1280x720 back buffer nearest-neighbour DOUBLES it -- every source pixel
becomes a 2x2 block, and that chunkiness is the look, not an artefact. And
the key comparison is a per-channel epsilon rather than equality, because the
layer's colour has been through an 8-bit render target and back."""


@fieldwise_init
struct Layer(ImplicitlyCopyable, Copyable, Movable):
    """One pool slot: the texture, the view a pass draws through, and the
    view the composite samples."""

    var tex: Int
    var rtv: Int
    var srv: Int


struct Compositor(Movable):
    """The layer pool and the pass that puts a layer on the screen."""

    var device: Int
    var context: Int
    var vs: Int
    var ps: Int
    var cb: Int
    var rast: Int
    var blend_opaque: Int
    var blend_alpha: Int
    var layers: List[Layer]
    var key: List[Float32]
    """keyCol.rgba then modeF.xyzw -- the constant buffer's 32 bytes, kept
    on the host so a mode change rewrites one float rather than the pair."""

    def __init__(out self, device: Int, context: Int) raises:
        self.device = device
        self.context = context
        self.layers = List[Layer]()

        var compile = resolve_compiler()
        var empty = List[UInt8]()
        var src = _bytes(String(BLIT_SHADER))
        var vs_blob = compile_shader_blob(
            compile, src, empty, empty, _bytes(String("BVS")),
            _bytes(String("vs_5_0")),
        )
        self.vs = create_vertex_shader(device, vs_blob[0], vs_blob[1])
        var ps_blob = compile_shader_blob(
            compile, src, empty, empty, _bytes(String("BPS")),
            _bytes(String("ps_5_0")),
        )
        self.ps = create_pixel_shader(device, ps_blob[0], ps_blob[1])

        self.cb = create_buffer(
            device, 32, _BIND_CONSTANT_BUFFER, _USAGE_DEFAULT
        )
        self.rast = create_rasterizer_state(device)
        self.blend_opaque = create_blend_state(device, False)
        self.blend_alpha = create_blend_state(device, True)

        self.key = List[Float32](length=8, fill=0.0)
        self.set_key(KEY_MAGENTA)

    def alloc_layer(mut self) raises -> Int:
        """A 640x360 RGBA plane that a pass can draw into and the composite
        can sample. Returns its handle.

        BindFlags is SHADER_RESOURCE | RENDER_TARGET -- 40, the reference's
        LAYER kind. The render target view is created with a NULL descriptor
        so it inherits the texture's format, which is the reference's choice
        and one fewer place for a format to disagree with itself."""
        if len(self.layers) >= POOL_SLOTS:
            raise Error("alloc_layer: the pool holds 16 layers")
        var tex = create_texture2d(
            self.device, CANVAS_W, CANVAS_H, _FORMAT_R8G8B8A8_UNORM,
            _BIND_SHADER_RESOURCE | _BIND_RENDER_TARGET, _USAGE_DEFAULT, 0,
        )
        var rtv = create_render_target_view(self.device, tex)
        var srv = create_srv(self.device, tex, _FORMAT_R8G8B8A8_UNORM)
        self.layers.append(Layer(tex, rtv, srv))
        return len(self.layers) - 1

    def rtv(self, handle: Int) -> Int:
        return self.layers[handle].rtv

    def srv(self, handle: Int) -> Int:
        return self.layers[handle].srv

    def set_key(mut self, rgb: Int):
        """The colour a keyed composite discards, as 0x00RRGGBB.

        Normalised into the constant buffer here rather than in the shader,
        so the pixel shader compares in the same 0..1 space the texel
        arrives in."""
        self.key[0] = Float32(rgb & 0xFF) / 255.0
        self.key[1] = Float32((rgb >> 8) & 0xFF) / 255.0
        self.key[2] = Float32((rgb >> 16) & 0xFF) / 255.0
        self.key[3] = 1.0

    def clear_layer(mut self, handle: Int, r: Float32, g: Float32, b: Float32):
        """Bind a layer as the render target and clear it.

        A keyed layer clears to the KEY, not to black: anything the pass
        does not cover then reads as transparent rather than as a black
        rectangle over everything behind it."""
        om_set_render_targets(self.context, self.layers[handle].rtv)
        set_viewport(self.context, CANVAS_W, CANVAS_H)
        clear_render_target(self.context, self.layers[handle].rtv, r, g, b)

    def _blit(
        mut self, src_srv: Int, dst_rtv: Int, mode: Int
    ) raises:
        """The workhorse. The reference's `Blit`, call for call.

        No viewport is set here, deliberately: `to_back` and `to_layer` each
        set the right one first, and folding it in would take the choice
        away from a caller compositing into a layer rather than the screen.
        """
        om_set_render_targets(self.context, dst_rtv)

        var views = List[Int](length=1, fill=src_srv)
        ps_set_shader_resources(self.context, views)

        vs_set_shader(self.context, self.vs)
        ps_set_shader(self.context, self.ps)
        rs_set_state(self.context, self.rast)

        self.key[4] = Float32(mode)
        update_subresource(
            self.context, self.cb,
            self.key.unsafe_ptr().unsafe_bitcast[UInt8]()
                .unsafe_origin_cast[MutUntrackedOrigin](),
            0,
        )
        ps_set_constant_buffers(self.context, self.cb)

        om_set_blend_state(
            self.context,
            self.blend_alpha if mode == BLIT_ALPHA else self.blend_opaque,
        )
        ia_set_topology(self.context, _TOPOLOGY_TRIANGLELIST)
        draw(self.context, 3)

    def to_back(
        mut self, handle: Int, rtv: Int, back_w: Int, back_h: Int, mode: Int
    ) raises:
        """Composite one layer onto the back buffer.

        The render target is switched to the back buffer BEFORE anything
        else, which is what unbinds the layer's own render target view and
        makes its texture legal to sample in the very next call."""
        om_set_render_targets(self.context, rtv)
        set_viewport(self.context, back_w, back_h)
        self._blit(self.layers[handle].srv, rtv, mode)

    def to_layer(
        mut self, src_handle: Int, dst_handle: Int, mode: Int
    ) raises:
        """Composite one layer onto another, at layer resolution."""
        om_set_render_targets(self.context, self.layers[dst_handle].rtv)
        set_viewport(self.context, CANVAS_W, CANVAS_H)
        self._blit(
            self.layers[src_handle].srv, self.layers[dst_handle].rtv, mode
        )
