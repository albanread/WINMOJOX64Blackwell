# ===----------------------------------------------------------------------=== #
# G0 -- the palette-indexed canvas, ported from RASM's gpu/canvas.was.
#
# The model is the reference's, not a reinterpretation of it. One index
# plane, two palettes, one full-screen triangle, and a frame that allocates
# nothing:
#
#   idx      640x360 R8_UINT          -- one byte a pixel, the colour INDEX
#   palGlobal  256x1 B8G8R8A8_UNORM   -- indices 16..255, the global colours
#   palLine    16x360 B8G8R8A8_UNORM  -- indices 0..15, per SCANLINE
#
# The per-line palette is what makes this a retro canvas rather than a
# framebuffer: sixteen of the colours can differ on every scanline, so a
# gradient sky, a copper bar or a colour-cycled tunnel costs one palette row
# rather than a screen of pixels. Both palettes are the hardware's own
# B8G8R8A8, so the shader loads a float4 and does no unpacking.
#
# Everything is created once, in `__init__`. The previous port created views
# at bind time and ran a driver out of memory; the reference's nine
# CreateShaderResourceView calls are all in init paths and that is the rule
# here. Nothing in `present` allocates, and nothing needs releasing, because
# the canvas owns its handles for as long as the process draws.
#
# The one call the old port never made is `rs_set_state`. D3D11's default
# rasterizer culls back faces, so whether a full-screen triangle is drawn at
# all depends on a winding nobody wrote down. The reference sets
# FILL_SOLID + CULL_NONE (gpu/canvas.was:238-241) and binds it every frame;
# so does this.
# ===----------------------------------------------------------------------=== #

from max.gpu.host import DeviceContext, HostBuffer
from std.memory import Pointer
from .blitter import Planes
from .device import (
    host_ptr,
    clear_render_target,
    create_pixel_shader,
    create_rasterizer_state,
    create_srv,
    create_texture2d,
    create_vertex_shader,
    compile_shader_blob,
    draw,
    ia_set_topology,
    om_set_render_targets,
    ps_set_shader,
    ps_set_shader_resources,
    resolve_compiler,
    rs_set_state,
    set_viewport,
    update_subresource,
    vs_set_shader,
)

# The canvas is a fixed size, as the reference's is: a retro pane is a
# resolution, not a window. The window scales it.
comptime CANVAS_W = 640
comptime CANVAS_H = 360
comptime PAL_GLOBAL = 256
comptime PAL_LINE = 16

comptime _FORMAT_R8_UINT = 62
comptime _FORMAT_B8G8R8A8_UNORM = 87
comptime _BIND_SHADER_RESOURCE = 8
comptime _USAGE_DEFAULT = 0
comptime _TOPOLOGY_TRIANGLELIST = 4


# The reference's shader, kept to the letter (gpu/canvas.was). The entry
# names and the resolution constants are the only edits: `idx` is sampled
# with an integer Load and no sampler, indices under sixteen resolve
# through THIS SCANLINE's row of the line palette, and the rest through the
# global one. Alpha is forced to 1 -- a canvas is opaque, and a palette
# entry whose alpha happened to be zero would otherwise erase the frame.
comptime CANVAS_SHADER = String(
    """
Texture2D<uint> idx : register(t0);
Texture2D<float4> palGlobal : register(t1);
Texture2D<float4> palLine : register(t2);

struct VO {
    float4 p : SV_Position;
    float2 uv : TEXCOORD0;
};

VO vmain(uint i : SV_VertexID) {
    float2 u = float2(float((i << 1) & 2), float(i & 2));
    VO o;
    o.p = float4(u.x * 2.0 - 1.0, 1.0 - u.y * 2.0, 0.0, 1.0);
    o.uv = u;
    return o;
}

float4 ps_main(VO v) : SV_Target {
    int px = (int)(v.uv.x * 640.0);
    int py = (int)(v.uv.y * 360.0);
    px = clamp(px, 0, 639);
    py = clamp(py, 0, 359);
    uint c = idx.Load(int3(px, py, 0));
    float4 col;
    if (c < 16u) {
        col = palLine.Load(int3((int)c, py, 0));
    } else {
        col = palGlobal.Load(int3((int)c, 0, 0));
    }
    return float4(col.rgb, 1.0);
}

float4 ps_overlay(VO v) : SV_Target {
    int px = (int)(v.uv.x * 640.0);
    int py = (int)(v.uv.y * 360.0);
    px = clamp(px, 0, 639);
    py = clamp(py, 0, 359);
    uint c = idx.Load(int3(px, py, 0));
    if (c == 0u) discard;
    float4 col;
    if (c < 16u) {
        col = palLine.Load(int3((int)c, py, 0));
    } else {
        col = palGlobal.Load(int3((int)c, 0, 0));
    }
    return float4(col.rgb, 1.0);
}
"""
)


struct GpuCanvas(Movable):
    """The index plane, its two palettes, and the pass that resolves them.

    Every handle here is created in `__init__` and lives as long as the
    canvas. `present` binds and draws; it allocates nothing and creates
    nothing.
    """

    var device: Int
    var context: Int
    var rast: Int
    var vs: Int
    var ps: Int
    var ps_overlay: Int
    """The same resolve with `if (c == 0u) discard`. Two shaders rather than a
    branch on a constant, because the branch would cost a constant buffer and
    a bind in the layer that can least afford one."""
    var overlay: Bool
    """False: this canvas is the bottom of the stack -- it clears the target
    and every index is a colour. True: it is a layer OVER something, so it
    does not clear and index 0 is a hole.

    The Mac pane makes this choice at the shader level too (`if (ci == 0u)
    discard_fragment()`), and Galaxigans needs it: the indexed plane is layer
    1, over the cosmos."""

    var tex_idx: Int
    var srv_idx: Int
    var tex_global: Int
    var srv_global: Int
    var tex_line: Int
    var srv_line: Int

    var idx: List[UInt8]
    """One byte a pixel, CANVAS_W * CANVAS_H. The game writes here."""
    var pal_global: List[UInt8]
    """256 BGRA quads."""
    var pal_line: List[UInt8]
    """16 BGRA quads per scanline, CANVAS_H rows of them."""

    var views: List[Int]
    """t0, t1, t2 -- built once so `present` binds without allocating."""
    var staging: HostBuffer[DType.uint8]
    """Pinned, kept for the life of the canvas: the bank's front buffer
    lands here on its way to the texture. One allocation, not one a
    frame."""

    def __init__(
        out self, ctx: DeviceContext, device: Int, context: Int
    ) raises:
        self.device = device
        self.context = context

        self.rast = create_rasterizer_state(device)

        var compile = resolve_compiler()
        var empty = List[UInt8]()
        var src = _bytes(String(CANVAS_SHADER))
        var vs_blob = compile_shader_blob(
            compile, src, empty, empty, _bytes(String("vmain")),
            _bytes(String("vs_5_0")),
        )
        self.vs = create_vertex_shader(device, vs_blob[0], vs_blob[1])
        var ps_blob = compile_shader_blob(
            compile, src, empty, empty, _bytes(String("ps_main")),
            _bytes(String("ps_5_0")),
        )
        self.ps = create_pixel_shader(device, ps_blob[0], ps_blob[1])
        var ov_blob = compile_shader_blob(
            compile, src, empty, empty, _bytes(String("ps_overlay")),
            _bytes(String("ps_5_0")),
        )
        self.ps_overlay = create_pixel_shader(device, ov_blob[0], ov_blob[1])
        self.overlay = False

        self.tex_idx = create_texture2d(
            device, CANVAS_W, CANVAS_H, _FORMAT_R8_UINT,
            _BIND_SHADER_RESOURCE, _USAGE_DEFAULT, 0,
        )
        self.srv_idx = create_srv(device, self.tex_idx, _FORMAT_R8_UINT)

        self.tex_global = create_texture2d(
            device, PAL_GLOBAL, 1, _FORMAT_B8G8R8A8_UNORM,
            _BIND_SHADER_RESOURCE, _USAGE_DEFAULT, 0,
        )
        self.srv_global = create_srv(
            device, self.tex_global, _FORMAT_B8G8R8A8_UNORM
        )

        self.tex_line = create_texture2d(
            device, PAL_LINE, CANVAS_H, _FORMAT_B8G8R8A8_UNORM,
            _BIND_SHADER_RESOURCE, _USAGE_DEFAULT, 0,
        )
        self.srv_line = create_srv(
            device, self.tex_line, _FORMAT_B8G8R8A8_UNORM
        )

        self.idx = List[UInt8](length=CANVAS_W * CANVAS_H, fill=0)
        self.pal_global = List[UInt8](length=PAL_GLOBAL * 4, fill=0)
        self.pal_line = List[UInt8](length=PAL_LINE * CANVAS_H * 4, fill=0)

        # Opaque by default. An untouched index should read as a colour,
        # not as a hole in the frame.
        for i in range(PAL_GLOBAL):
            self.pal_global[i * 4 + 3] = 255
        for i in range(PAL_LINE * CANVAS_H):
            self.pal_line[i * 4 + 3] = 255

        self.staging = ctx.enqueue_create_host_buffer[DType.uint8](
            CANVAS_W * CANVAS_H
        )
        ctx.synchronize()
        self.views = List[Int](length=3, fill=0)
        self.views[0] = self.srv_idx
        self.views[1] = self.srv_global
        self.views[2] = self.srv_line

    def set_overlay(mut self, on: Bool):
        """Make this canvas a LAYER rather than a background.

        An overlay does not clear the render target and treats index 0 as
        transparent, so whatever was drawn underneath shows through. Call it
        once, after construction."""
        self.overlay = on

    # ── the canvas the game writes ──────────────────────────────────────
    def cls(mut self, index: Int):
        """Fill every pixel with one index."""
        var c = UInt8(index & 255)
        for i in range(len(self.idx)):
            self.idx[i] = c

    def pset(mut self, x: Int, y: Int, index: Int):
        """One pixel. Out of range is ignored, as the reference's is."""
        if x < 0 or x >= CANVAS_W or y < 0 or y >= CANVAS_H:
            return
        self.idx[y * CANVAS_W + x] = UInt8(index & 255)

    def set_rgb(mut self, index: Int, r: Int, g: Int, b: Int):
        """A global palette entry, 16..255. Stored BGRA, the format the
        texture is, so the upload is a copy and the shader does no work."""
        if index < 0 or index >= PAL_GLOBAL:
            return
        self.pal_global[index * 4 + 0] = UInt8(b & 255)
        self.pal_global[index * 4 + 1] = UInt8(g & 255)
        self.pal_global[index * 4 + 2] = UInt8(r & 255)
        self.pal_global[index * 4 + 3] = 255

    def set_line_rgb(
        mut self, line: Int, index: Int, r: Int, g: Int, b: Int
    ):
        """One of the sixteen colours on ONE scanline -- the copper bar."""
        if line < 0 or line >= CANVAS_H or index < 0 or index >= PAL_LINE:
            return
        var o = (line * PAL_LINE + index) * 4
        self.pal_line[o + 0] = UInt8(b & 255)
        self.pal_line[o + 1] = UInt8(g & 255)
        self.pal_line[o + 2] = UInt8(r & 255)
        self.pal_line[o + 3] = 255

    # ── the frame ───────────────────────────────────────────────────────
    def present_planes(
        mut self, mut planes: Planes, rtv: Int, back_w: Int, back_h: Int
    ) raises:
        """Draw the bank's FRONT buffer.

        The blits have to be finished before their bytes are read, because
        they went out on the runtime's stream and this reads on the host --
        two paths to one GPU with nothing ordering them. Then one copy
        device-to-host into the pinned plane, and the ordinary upload.

        That copy is the whole cost of not having CUDA/D3D11 interop:
        345,600 bytes at 720x480, 0.13% of the bus at 60Hz. Registering the
        texture with CUDA would let a kernel write it in place and remove
        even this.
        """
        if planes.width != CANVAS_W or planes.height != CANVAS_H:
            raise Error(
                "present_planes: the bank and the canvas must agree on size"
            )
        planes.finish()
        planes.read_front(self.staging)
        planes.finish()
        update_subresource(
            self.context, self.tex_idx, host_ptr(self.staging), CANVAS_W
        )
        self.upload_palettes()
        self._draw(rtv, back_w, back_h)

    def present(mut self, rtv: Int, back_w: Int, back_h: Int) raises:
        """Upload, bind, draw. The reference's GpuPresent, call for call.

        The viewport is the BACK BUFFER's size, not the canvas's: the
        triangle covers the whole drawable and the shader maps uv onto the
        640x360 index plane, so the GPU does the scaling. The old port set
        the viewport to the canvas size and drew into a corner.
        """
        update_subresource(
            self.context, self.tex_idx,
            self.idx.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
            CANVAS_W,
        )
        self.upload_palettes()
        self._draw(rtv, back_w, back_h)

    def upload_palettes(mut self) raises:
        """Both palette textures, host to GPU.

        Public, and not only because `present` uses it: the TILE layer
        samples these two textures without ever touching the canvas's
        index plane, so a game that draws tiles instead of a canvas still
        needs the palettes uploaded and has nothing else to call."""
        update_subresource(
            self.context, self.tex_global,
            self.pal_global.unsafe_ptr().unsafe_origin_cast[
                MutUntrackedOrigin
            ](),
            PAL_GLOBAL * 4,
        )
        update_subresource(
            self.context, self.tex_line,
            self.pal_line.unsafe_ptr().unsafe_origin_cast[
                MutUntrackedOrigin
            ](),
            PAL_LINE * 4,
        )

    def _draw(mut self, rtv: Int, back_w: Int, back_h: Int) raises:
        """Bind and draw. The reference's GpuPresent from the render
        target onward, shared by both ways of filling the index plane."""
        om_set_render_targets(self.context, rtv)
        if not self.overlay:
            # Only the BOTTOM layer clears. As an overlay this call would
            # wipe whatever the cosmos just drew, which is exactly what it
            # did the first time this canvas was put over one.
            clear_render_target(self.context, rtv, 0.0, 0.0, 0.0)
        set_viewport(self.context, back_w, back_h)
        rs_set_state(self.context, self.rast)
        vs_set_shader(self.context, self.vs)
        ps_set_shader(
            self.context, self.ps_overlay if self.overlay else self.ps
        )
        ps_set_shader_resources(self.context, self.views)
        ia_set_topology(self.context, _TOPOLOGY_TRIANGLELIST)
        draw(self.context, 3)


def _cstr(s: String) -> List[UInt8]:
    """A string's bytes plus a terminator, for an argument D3D reads as a
    C string.

    `_bytes` deliberately does not add one -- its callers pass an explicit
    length -- and that is exactly the trap. `D3D11_INPUT_ELEMENT_DESC`'s
    SemanticName is an `LPCSTR` with no length beside it, so a buffer
    without a terminator makes CreateInputLayout read past the end of the
    allocation and compare whatever is there against the shader's signature.
    It matched for months because the byte after the string happened to be
    zero; changing an unrelated build flag moved the allocations and every
    layout in the sprite pass started failing with E_INVALIDARG. The same
    hazard is already handled inside `compile_shader_blob`, which terminates
    its entry point and target before the call.
    """
    var out = _bytes(s)
    out.append(0)
    return out^


def _bytes(s: String) -> List[UInt8]:
    """A string's bytes as a heap list -- the form that crosses a function
    boundary reliably in this build."""
    var out = List[UInt8]()
    for byte in s.as_bytes():
        out.append(byte)
    return out^
