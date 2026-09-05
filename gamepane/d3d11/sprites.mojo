"""Layer 2 on Direct3D 11: sprites, composited by the GPU.

The same design the Metal backend states, with the Windows answers: per
DEFINITION one index texture and a 16-float4 palette, persisted; per
INSTANCE nothing on the GPU at all -- four vertices computed on the CPU,
uploaded per draw. Blending is source-alpha over one-minus-source-alpha,
which is what makes `set_alpha` a fade rather than a switch.

The quads are Triangle-STRIP order (top-left, top-right, bottom-left,
bottom-right) because `quad_vertices` emits them that way for
`setVertexBytes:`; D3D11 draws the same strip with
`IASetPrimitiveTopology(TRIANGLESTRIP)` -- the one topology where the
default is actually right.
"""

from max.gpu.host import DeviceContext, HostBuffer
from std.memory import Pointer, OpaquePointer
from std.sys._com import com_method_of
from std.sys._winkb import winkb_constant

from gamepane.api import (
    SpriteBitmap,
    SpriteInstance,
    parse_sprite_rows,
    quad_vertices,
    SPRITE_COLORS,
    stride_for,
)

from .device import (
    create_buffer,
    create_texture2d,
    update_subresource,
    device_ptr,
    host_ptr,
    set_viewport,
)
from .layers import make_srv
from .window import Frame
from .layers import _bytes, compile_shader_helper
from .device import (
    compile_shader_blob, create_vertex_shader, create_pixel_shader,
)


# The sprite shaders. The vertex stage takes its quad from a constant
# buffer (no vertex buffer to manage); the pixel stage does the texel
# lookup, the transparent-index clip, and folds the instance alpha into
# the palette colour so the blend stage can do the rest.
comptime SPRITE_VERTEX = String(
    """
cbuffer Quad : register(b0) {
    float4 v0; float4 v1; float4 v2; float4 v3;  // pos.xy, uv.xy each
};

struct PSIn {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

PSIn vmain(uint vid : SV_VertexID) {
    float4 q[4] = { v0, v1, v2, v3 };
    PSIn o;
    o.pos = float4(q[vid].xy, 0.0, 1.0);
    o.uv = q[vid].zw;
    return o;
}
"""
)

comptime SPRITE_PIXEL = String(
    """
Texture2D<uint> indexTex : register(t0);
Texture1D<float4> palette : register(t1);
cbuffer Alpha : register(b1) {
    float alpha;
};

struct PSIn {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

float4 ps_main(PSIn psi) : SV_Target {
    uint w; uint h;
    indexTex.GetDimensions(w, h);
    uint2 texel = uint2(psi.uv.x * w, psi.uv.y * h);
    uint ci = indexTex.Load(int3(texel, 0)).r;
    if (ci == 0u) { clip(-1); }
    float4 c = palette.Load(int2(ci, 0));
    c.a *= alpha;
    return c;
}
"""
)


@fieldwise_init
struct SpriteDef(Movable):
    """One definition: size, frames, palette.

    The HostBuffers are held because the device addresses and texture
    uploads below are only as alive as they are."""

    var width: Int
    var height: Int
    var stride: Int
    var frames: List[HostBuffer[DType.uint8]]
    var hosts: List[Int]
    var devices: List[Int]
    var texture: Int
    """One shared texture, re-uploaded per frame change. A per-frame
    texture would be cleaner; one per definition keeps the count at
    `len(defs)` and frame switches cost one UpdateSubresource."""
    var palette: List[Float32]
    var palette_dirty: Bool
    var palette_texture: Int


struct Sprites(Movable):
    """Every definition and every instance, and the one pass that draws
    them."""

    var ctx: DeviceContext
    var device: Int
    var context: Int
    var defs: List[SpriteDef]
    var instances: List[SpriteInstance]
    var vs: Int
    var ps: Int
    var quad_buffer: Int
    var alpha_buffer: Int

    def __init__(
        out self, pane_ctx: DeviceContext, device: Int, context: Int
    ) raises:
        self.ctx = pane_ctx
        self.device = device
        self.context = context
        self._blend = 0
        self.defs = List[SpriteDef]()
        self.instances = List[SpriteInstance]()
        var compile = compile_shader_helper()
        var empty = List[UInt8]()
        var vs_src = _bytes(String(SPRITE_VERTEX))
        var vs_blob = compile_shader_blob(
            compile, vs_src, empty, empty, _bytes(String("vmain")),
            _bytes(String("vs_5_0")),
        )
        self.vs = create_vertex_shader(device, vs_blob[0], vs_blob[1])
        var ps_src = _bytes(String(SPRITE_PIXEL))
        var ps_blob = compile_shader_blob(
            compile, ps_src, empty, empty, _bytes(String("ps_main")),
            _bytes(String("ps_5_0")),
        )
        self.ps = create_pixel_shader(device, ps_blob[0], ps_blob[1])
        self.quad_buffer = create_buffer(device, 64, 4, 0)
        self.alpha_buffer = create_buffer(device, 16, 4, 0)

    # ── definitions ─────────────────────────────────────────────────────

    def _make_plane(
        mut self, bmp: SpriteBitmap, stride: Int
    ) raises -> HostBuffer[DType.uint8]:
        """A stride-packed copy of the bitmap's pixels, on the device."""
        var buf = self.ctx.enqueue_create_host_buffer[DType.uint8](
            stride * bmp.height
        )
        var base = host_ptr(buf)
        for y in range(bmp.height):
            for x in range(stride):
                base[unsafe_offset = y * stride + x] = (
                    bmp.pixels[y * bmp.width + x] if x < bmp.width else 0
                )
        return buf^

    def define_sprite(mut self, rows: String) raises -> Int:
        """Define a sprite from its text rows; returns the handle."""
        let bmp = parse_sprite_rows(rows)
        let stride = stride_for(bmp.width, 16)
        var plane = self._make_plane(bmp, stride)

        var pal = List[Float32](length=SPRITE_COLORS * 4, fill=0.0)
        for i in range(SPRITE_COLORS):
            pal[i * 4 + 3] = 1.0
        var palette_texture = create_texture2d(
            self.device, SPRITE_COLORS, 1, 2,  # R32G32B32A32_FLOAT
            8,  # D3D11_BIND_SHADER_RESOURCE
            0, 0,
        )
        var frames = List[HostBuffer[DType.uint8]]()
        var hosts = List[Int]()
        var devices = List[Int]()
        var texture = create_texture2d(
            self.device, bmp.width, bmp.height, 61,  # R8_UINT
            8, 0, 0,
        )
        frames.append(plane)
        hosts.append(Int(host_ptr(plane)))
        devices.append(device_ptr(plane))
        self.defs.append(
            SpriteDef(
                bmp.width, bmp.height, stride, frames^, hosts^, devices^,
                texture, pal^, True, palette_texture,
            )
        )
        return len(self.defs) - 1

    def add_frame(mut self, id: Int, rows: String) raises -> Bool:
        """Append another frame. Its dimensions must match the first's --
        a sprite whose frames are different sizes would change size as it
        animated, which is never what anyone meant."""
        if id < 0 or id >= len(self.defs):
            return False
        let bmp = parse_sprite_rows(rows)
        if (
            bmp.width != self.defs[id].width
            or bmp.height != self.defs[id].height
        ):
            return False
        var plane = self._make_plane(bmp, self.defs[id].stride)
        self.defs[id].frames.append(plane)
        self.defs[id].hosts.append(Int(host_ptr(plane)))
        self.defs[id].devices.append(device_ptr(plane))
        return True

    def sprite_rgb(mut self, id: Int, index: Int, r: Int, g: Int, b: Int):
        """Set a palette entry -- 0..255 bytes in, 0..1 floats out."""
        if id < 0 or id >= len(self.defs):
            return
        if index < 0 or index >= SPRITE_COLORS:
            return
        self.defs[id].palette[index * 4 + 0] = Float32(r) / 255.0
        self.defs[id].palette[index * 4 + 1] = Float32(g) / 255.0
        self.defs[id].palette[index * 4 + 2] = Float32(b) / 255.0
        self.defs[id].palette[index * 4 + 3] = 1.0
        self.defs[id].palette_dirty = True

    def palette_rgb(self, id: Int, index: Int) -> Tuple[Int, Int, Int]:
        """A palette entry as 0..255 bytes, for the debris table."""
        if id < 0 or id >= len(self.defs):
            return (0, 0, 0)
        if index < 0 or index >= SPRITE_COLORS:
            return (0, 0, 0)
        return (
            Int(self.defs[id].palette[index * 4 + 0] * 255.0 + 0.5),
            Int(self.defs[id].palette[index * 4 + 1] * 255.0 + 0.5),
            Int(self.defs[id].palette[index * 4 + 2] * 255.0 + 0.5),
        )

    def frame_pixels(
        self, id: Int, frame: Int
    ) raises -> Tuple[Int, Int, Int, List[UInt8]]:
        """A frame's index bytes: (width, height, stride, bytes). Copied
        rather than a view of the plane -- handing out a pointer into a
        live GPU buffer to be read later is the borrow trap this package
        keeps meeting."""
        if id < 0 or id >= len(self.defs):
            return (0, 0, 0, List[UInt8]())
        let id_a = id
        let w = self.defs[id_a].width
        let h = self.defs[id_a].height
        let st = self.defs[id_a].stride
        var f = frame
        if f < 0 or f >= len(self.defs[id_a].hosts):
            f = 0
        var out = List[UInt8]()
        var base = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=self.defs[id_a].hosts[f]
        )
        for y in range(h):
            for x in range(w):
                out.append(base[unsafe_offset = y * st + x])
        return (w, h, st, out^)

    # ── instances ───────────────────────────────────────────────────────

    def place(mut self, definition: Int, x: Float64, y: Float64) -> Int:
        var inst = SpriteInstance(
            definition, x, y, 1.0, 0.0, 1.0, 0, True, 0.0, 0.0
        )
        self.instances.append(inst^)
        return len(self.instances) - 1

    def move_to(mut self, inst: Int, x: Float64, y: Float64):
        if inst >= 0 and inst < len(self.instances):
            self.instances[inst].x = x
            self.instances[inst].y = y

    def set_scale(mut self, inst: Int, s: Float64):
        if inst >= 0 and inst < len(self.instances):
            self.instances[inst].scale = s

    def set_rotation(mut self, inst: Int, degrees: Float64):
        if inst >= 0 and inst < len(self.instances):
            self.instances[inst].rotation_degrees = degrees

    def set_alpha(mut self, inst: Int, a: Float64):
        if inst >= 0 and inst < len(self.instances):
            self.instances[inst].alpha = a

    def set_frame(mut self, inst: Int, frame: Int):
        if inst >= 0 and inst < len(self.instances):
            self.instances[inst].frame = frame

    def animate(mut self, inst: Int, fps: Float64):
        """Animate at `fps`; 0 or negative parks the sprite on its frame."""
        if inst >= 0 and inst < len(self.instances):
            self.instances[inst].animate_fps = fps
            self.instances[inst].anim_accum_secs = 0.0

    def show(mut self, inst: Int):
        if inst >= 0 and inst < len(self.instances):
            self.instances[inst].visible = True

    def hide(mut self, inst: Int):
        if inst >= 0 and inst < len(self.instances):
            self.instances[inst].visible = False

    def sprite_x(self, inst: Int) -> Float64:
        if inst >= 0 and inst < len(self.instances):
            return self.instances[inst].x
        return 0.0

    def sprite_y(self, inst: Int) -> Float64:
        if inst >= 0 and inst < len(self.instances):
            return self.instances[inst].y
        return 0.0

    def sprite_frame(self, inst: Int) -> Int:
        if inst >= 0 and inst < len(self.instances):
            return self.instances[inst].frame
        return 0

    def tick(mut self, dt: Float64):
        """Advance every animation. Frame-wrap is per definition."""
        for i in range(len(self.instances)):
            if self.instances[i].animate_fps <= 0.0:
                continue
            let di = self.instances[i].definition
            if di < 0 or di >= len(self.defs):
                continue
            self.instances[i].anim_accum_secs += (
                dt * self.instances[i].animate_fps
            )
            while self.instances[i].anim_accum_secs >= 1.0:
                self.instances[i].anim_accum_secs -= 1.0
                self.instances[i].frame += 1
                if self.instances[i].frame >= len(self.defs[di].hosts):
                    self.instances[i].frame = 0

    def hit(self, a: Int, b: Int) -> Bool:
        """AABB overlap of two instances, in world space."""
        from gamepane.api import sprites_overlap

        if a < 0 or b < 0 or a >= len(self.instances) or b >= len(self.instances):
            return False
        var da = a
        if (
            self.instances[da].definition < 0
            or self.instances[da].definition >= len(self.defs)
        ):
            da = 0
        var db = b
        if (
            self.instances[db].definition < 0
            or self.instances[db].definition >= len(self.defs)
        ):
            db = 0
        let wa = self.defs[self.instances[da].definition].width
        let ha = self.defs[self.instances[da].definition].height
        let wb = self.defs[self.instances[db].definition].width
        let hb = self.defs[self.instances[db].definition].height
        return sprites_overlap(
            self.instances[a].x, self.instances[a].y,
            Float64(wa), Float64(ha),
            self.instances[b].x, self.instances[b].y,
            Float64(wb), Float64(hb),
        )

    # ── the pass ────────────────────────────────────────────────────────

    def render(
        mut self,
        frame: Frame,
        rtv: Int,
        scroll_x: Float64,
        scroll_y: Float64,
        viewport_w: Float64,
        viewport_h: Float64,
    ) raises:
        """Composite every visible instance over the target.

        Always blending: sprites draw over whatever the layers below left.
        The scroll is subtracted here rather than stored on the instance,
        so a sprite placed in world coordinates scrolls with the
        background without being told to."""
        if not frame.valid:
            return

        # Flush any dirty palettes.
        for i in range(len(self.defs)):
            if self.defs[i].palette_dirty:
                update_subresource(
                    self.context, self.defs[i].palette_texture,
                    self.defs[i].palette.unsafe_ptr().unsafe_bitcast[
                        UInt8
                    ]().unsafe_origin_cast[MutUntrackedOrigin](),
                    SPRITE_COLORS * 16,
                )
                self.defs[i].palette_dirty = False

        # Blend state: this layer's whole difference from the ones below.
        self._set_blend_state()
        set_viewport(self.context, Int(viewport_w), Int(viewport_h))
        var set_targets = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], UInt32,
                Pointer[Int, MutAnyOrigin], Int,
            ) thin abi("C") -> NoneType,
            "ID3D11DeviceContext",
            "OMSetRenderTargets",
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context))
        var slot = rtv
        set_targets(
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context),
            UInt32(1),
            Pointer(to=slot).unsafe_origin_cast[MutAnyOrigin](),
            0,
        )
        var set_topology = com_method_of[
            def (OpaquePointer[MutUntrackedOrigin], UInt32) thin abi("C") -> NoneType,
            "ID3D11DeviceContext",
            "IASetPrimitiveTopology",
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context))
        # TRIANGLESTRIP -- the strip order quad_vertices emits.
        set_topology(
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context),
            UInt32(5),
        )
        var set_ps = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], Int, Int, UInt32
            ) thin abi("C") -> NoneType,
            "ID3D11DeviceContext",
            "PSSetShader",
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context))
        set_ps(
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context),
            self.ps, 0, UInt32(0),
        )
        var set_vs = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], Int, Int, UInt32
            ) thin abi("C") -> NoneType,
            "ID3D11DeviceContext",
            "VSSetShader",
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context))
        set_vs(
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context),
            self.vs, 0, UInt32(0),
        )

        for i in range(len(self.instances)):
            let inst = self.instances[i]
            if not inst.visible:
                continue
            if inst.definition < 0 or inst.definition >= len(self.defs):
                continue
            let di = inst.definition
            if len(self.defs[di].hosts) == 0:
                continue
            var verts = quad_vertices(
                inst, self.defs[di].width, self.defs[di].height,
                scroll_x, scroll_y, viewport_w, viewport_h,
            )
            update_subresource(
                self.context, self.quad_buffer,
                verts.unsafe_ptr().unsafe_bitcast[UInt8]().unsafe_origin_cast[
                    MutUntrackedOrigin
                ](),
                len(verts) * 4,
            )
            var alpha = List[Float32](length=4, fill=0.0)
            alpha[0] = Float32(inst.alpha)
            update_subresource(
                self.context, self.alpha_buffer,
                alpha.unsafe_ptr().unsafe_bitcast[UInt8]().unsafe_origin_cast[
                    MutUntrackedOrigin
                ](),
                16,
            )
            var f = inst.frame
            if f < 0 or f >= len(self.defs[di].hosts):
                f = 0
            # The frame's bytes go up now; the shared texture is re-bound
            # per instance because the next instance may be another frame
            # of another definition.
            update_subresource(
                self.context, self.defs[di].texture,
                Pointer[UInt8, MutUntrackedOrigin](
                    unsafe_from_address=self.defs[di].hosts[f]
                ),
                self.defs[di].stride,
            )
            var srv = make_srv(self.device, self.defs[di].texture)
            var pal_srv = make_srv(
                self.device, self.defs[di].palette_texture
            )
            var srvs = List[Int](length=2, fill=0)
            srvs[0] = srv
            srvs[1] = pal_srv
            var set_srvs = com_method_of[
                def (
                    OpaquePointer[MutUntrackedOrigin], UInt32, UInt32,
                    Pointer[Int, ImmUnsafeAnyOrigin],
                ) thin abi("C") -> NoneType,
                "ID3D11DeviceContext",
                "PSSetShaderResources",
            ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context))
            set_srvs(
                OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context),
                UInt32(0), UInt32(2),
                srvs.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            )
            var cbs = List[Int](length=2, fill=0)
            cbs[0] = self.quad_buffer
            cbs[1] = self.alpha_buffer
            var set_cbs = com_method_of[
                def (
                    OpaquePointer[MutUntrackedOrigin], UInt32, UInt32,
                    Pointer[Int, MutAnyOrigin],
                ) thin abi("C") -> NoneType,
                "ID3D11DeviceContext",
                "PSSetConstantBuffers",
            ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context))
            set_cbs(
                OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context),
                UInt32(1), UInt32(1),
                Pointer(to=cbs[0]).unsafe_origin_cast[MutAnyOrigin](),
            )
            # VS constant buffer: b0 in the vertex shader.
            var set_vcb = com_method_of[
                def (
                    OpaquePointer[MutUntrackedOrigin], UInt32, UInt32,
                    Pointer[Int, MutAnyOrigin],
                ) thin abi("C") -> NoneType,
                "ID3D11DeviceContext",
                "VSSetConstantBuffers",
            ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context))
            set_vcb(
                OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context),
                UInt32(0), UInt32(1),
                Pointer(to=cbs[0]).unsafe_origin_cast[MutAnyOrigin](),
            )
            var draw = com_method_of[
                def (
                    OpaquePointer[MutUntrackedOrigin], UInt32, UInt32
                ) thin abi("C") -> NoneType,
                "ID3D11DeviceContext",
                "Draw",
            ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context))
            draw(
                OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context),
                UInt32(4), UInt32(0),
            )

        self._clear_blend_state()

    def _set_blend_state(mut self) raises:
        """Source-alpha blending, for the whole sprite pass."""
        # D3D11 needs a blend-state object; build one lazily and hold it.
        if self._blend == 0:
            # D3D11_BLEND_DESC: 4 x BOOL RenderTargetWriteMask-first is
            # complex; use the simplified default with alpha-to-coverage
            # off and per-RT blend. The struct is
            # {BOOL AlphaToCoverageEnable; BOOL IndependentBlendEnable;
            #  D3D11_RENDER_TARGET_BLEND_DESC[8]}, 264 bytes; we want
            # SrcAlpha/InvSrcSrcAlpha on RT0.
            # D3D11_BLEND_DESC, 264 bytes as 66 UInt32s. RT0 begins at
            # word 2; within it: BlendEnable, Src, Dest, Op, SrcA, DestA,
            # OpA -- seven words -- and the write mask is BYTE offset 28
            # of the RT block, word 9's low byte.
            var desc = List[UInt32](length=66, fill=0)
            desc[2] = 1  # BlendEnable
            desc[3] = 5  # SrcBlend = SRC_ALPHA
            desc[4] = 6  # DestBlend = INV_SRC_ALPHA
            desc[5] = 1  # BlendOp = ADD
            desc[6] = 5  # SrcBlendAlpha
            desc[7] = 6  # DestBlendAlpha
            desc[8] = 1  # BlendOpAlpha = ADD
            desc[9] = 0xF  # RenderTargetWriteMask: all channels
            var create = com_method_of[
                def (
                    OpaquePointer[MutUntrackedOrigin],
                    Pointer[UInt32, MutAnyOrigin],
                    Pointer[Int, MutAnyOrigin],
                ) thin abi("C") -> Int32,
                "ID3D11Device",
                "CreateBlendState",
            ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.device))
            var state: Int = 0
            var hr = create(
                OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.device),
                desc.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
                Pointer(to=state).unsafe_origin_cast[MutAnyOrigin](),
            )
            if hr != 0:
                raise Error("CreateBlendState failed, hr = " + String(hr))
            self._blend = state
        var set = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], Int, UInt32,
                Int,
            ) thin abi("C") -> NoneType,
            "ID3D11DeviceContext",
            "OMSetBlendState",
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context))
        set(
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context),
            self._blend, UInt32(0), Int(0),
        )

    def _clear_blend_state(mut self):
        var set = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], Int, UInt32,
                Int,
            ) thin abi("C") -> NoneType,
            "ID3D11DeviceContext",
            "OMSetBlendState",
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context))
        set(
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self.context),
            0, UInt32(0), Int(0),
        )

    var _blend: Int
