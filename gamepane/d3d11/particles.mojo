"""The particle field on Direct3D 11: two Mojo GPU kernels and the plane
they scatter into.

The kernels are the Metal backend's VERBATIM -- they are plain Mojo defs
over pointers, the same four-instruction dispatch the blitter uses, and
the device-mapped allocations give them the same bytes the CPU seeded.
Per frame: clear the plane, step every particle. The plane composites
over the game through the same index-sampler shader as the direct pane,
plus the transparent clip, so debris never paints a black box.
"""

from max.gpu.host import DeviceContext, HostBuffer
from std.gpu import global_idx
from std.memory import Pointer, OpaquePointer, Span
from std.sys._com import com_method_of

from gamepane.api import (
    P,
    stride_for,
    particle_colour,
    burst_velocity,
    PARTICLE_COLOURS_PER_DEF,
)

from .device import (
    create_texture2d,
    update_subresource,
    set_viewport,
    device_ptr,
    host_ptr,
)
from .layers import make_srv
from .window import Frame
from .layers import _bytes, compile_shader_helper
from .device import (
    compile_shader_blob, create_vertex_shader, create_pixel_shader,
    create_buffer,
)


comptime PARTICLE_PALETTE = 256
comptime BLOCK = 16


def particles_step_kernel(
    px: Pointer[Float32, MutAnyOrigin],
    py: Pointer[Float32, MutAnyOrigin],
    pvx: Pointer[Float32, MutAnyOrigin],
    pvy: Pointer[Float32, MutAnyOrigin],
    life: Pointer[Float32, MutAnyOrigin],
    colour: Pointer[UInt8, MutAnyOrigin],
    plane: Pointer[UInt8, MutAnyOrigin],
    stride: Int32,
    width: Int32,
    height: Int32,
    dt: Float32,
    gravity: Float32,
    fade: Float32,
    count: Int32,
    frame: Int32,
):
    """One thread, one particle: integrate, age, thin, scatter."""
    var i = Int(global_idx.x)
    if i >= Int(count):
        return
    var l = life[unsafe_offset=i]
    if l <= 0.0:
        return

    var vy = pvy[unsafe_offset=i] + gravity * dt
    var x = px[unsafe_offset=i] + pvx[unsafe_offset=i] * dt
    var y = py[unsafe_offset=i] + vy * dt
    var nl = l - fade * dt
    px[unsafe_offset=i] = x
    py[unsafe_offset=i] = y
    pvy[unsafe_offset=i] = vy
    life[unsafe_offset=i] = nl
    if nl <= 0.0:
        return

    var h = (i * 2654435761 + Int(frame) * 40503) & 0x7FFFFFFF
    h = (h ^ (h >> 13)) & 0x7FFFFFFF
    h = (h * 1274126177) & 0x7FFFFFFF
    var coin = Float32((h >> 7) & 0xFFFF) / 65536.0
    if coin > nl:
        return

    var xi = Int(x)
    var yi = Int(y)
    if xi < 0 or yi < 0 or xi >= Int(width) or yi >= Int(height):
        return
    plane[unsafe_offset = yi * Int(stride) + xi] = colour[unsafe_offset=i]


def particles_clear_kernel(
    plane: Pointer[UInt8, MutAnyOrigin],
    stride: Int32,
    count: Int32,
):
    var i = Int(global_idx.x)
    if i >= Int(count):
        return
    plane[unsafe_offset=i] = 0


comptime PARTICLE_VERTEX = String(
    """
struct PSIn {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};
PSIn vmain(uint vid : SV_VertexID) {
    float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    PSIn o;
    o.pos = float4(p[vid], 0.0, 1.0);
    o.uv = float2((p[vid].x + 1.0) * 0.5, 1.0 - (p[vid].y + 1.0) * 0.5);
    return o;
}
"""
)

comptime PARTICLE_PIXEL = String(
    """
Texture2D<uint> indexTex : register(t0);
Texture1D<float4> palette : register(t1);
cbuffer U : register(b0) {
    float w; float h; float pad0; float pad1;
};
struct PSIn {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};
float4 ps_main(PSIn psi) : SV_Target {
    uint x = uint(psi.uv.x * w), y = uint(psi.uv.y * h);
    if (x >= uint(w)) x = uint(w) - 1;
    if (y >= uint(h)) y = uint(h) - 1;
    uint ci = indexTex.Load(int3(x, y, 0)).r;
    if (ci == 0u) { clip(-1); }
    return palette.Load(int2(ci, 0));
}
"""
)


struct ParticleField(Movable):
    """A fixed pool of particles and the plane they scatter into.

    A ROLLING cursor rather than a free list: a new burst overwrites the
    oldest particles still alive. At a few thousand slots that never
    shows, and it means spawning is a write with no search."""

    var ctx: DeviceContext
    var capacity: Int
    var cursor: Int
    var width: Int
    var height: Int
    var stride: Int
    var frame: Int

    var px: HostBuffer[DType.float32]
    var py: HostBuffer[DType.float32]
    var pvx: HostBuffer[DType.float32]
    var pvy: HostBuffer[DType.float32]
    var life: HostBuffer[DType.float32]
    var colour: HostBuffer[DType.uint8]
    var plane: HostBuffer[DType.uint8]

    var texture: Int
    var palette: List[Float32]
    var palette_texture: Int
    var palette_dirty: Bool
    var vs: Int
    var ps: Int
    var uniform_buffer: Int

    def __init__(
        out self,
        pane_ctx: DeviceContext,
        device: Int,
        context: Int,
        width: Int,
        height: Int,
        capacity: Int = 8192,
    ) raises:
        self.ctx = pane_ctx
        self.capacity = capacity
        self.cursor = 0
        self.width = width
        self.height = height
        self.frame = 0
        self.stride = stride_for(width, 16)

        self.px = pane_ctx.enqueue_create_host_buffer[DType.float32](capacity)
        self.py = pane_ctx.enqueue_create_host_buffer[DType.float32](capacity)
        self.pvx = pane_ctx.enqueue_create_host_buffer[DType.float32](capacity)
        self.pvy = pane_ctx.enqueue_create_host_buffer[DType.float32](capacity)
        self.life = pane_ctx.enqueue_create_host_buffer[DType.float32](capacity)
        self.colour = pane_ctx.enqueue_create_host_buffer[DType.uint8](capacity)
        var lp = host_ptr(self.life)
        for i in range(capacity * 4):
            lp[unsafe_offset=i] = 0

        self.plane = pane_ctx.enqueue_create_host_buffer[DType.uint8](
            self.stride * height
        )
        var pp = host_ptr(self.plane)
        for i in range(self.stride * height):
            pp[unsafe_offset=i] = 0

        self.texture = create_texture2d(
            device, width, height, 61, 8, 0, 0,
        )
        self.palette = List[Float32](length=PARTICLE_PALETTE * 4, fill=0.0)
        for i in range(PARTICLE_PALETTE):
            self.palette[i * 4 + 3] = 1.0
        self.palette_texture = create_texture2d(
            device, PARTICLE_PALETTE, 1, 2, 8, 0, 0,
        )
        self.palette_dirty = True

        var compile = compile_shader_helper()
        var empty = List[UInt8]()
        var vs_blob = compile_shader_blob(
            compile, _bytes(String(PARTICLE_VERTEX)), empty, empty,
            _bytes(String("vmain")), _bytes(String("vs_5_0")),
        )
        self.vs = create_vertex_shader(device, vs_blob[0], vs_blob[1])
        var ps_blob = compile_shader_blob(
            compile, _bytes(String(PARTICLE_PIXEL)), empty, empty,
            _bytes(String("ps_main")), _bytes(String("ps_5_0")),
        )
        self.ps = create_pixel_shader(device, ps_blob[0], ps_blob[1])
        self.uniform_buffer = create_buffer(device, 16, 4, 0)
        self._device = device
        self._context = context

    def set_colour_f(mut self, slot: Int, r: Int, g: Int, b: Int):
        """Bytes-in spelling, matching sprites.sprite_rgb."""
        self.set_colour(
            slot, Float32(r) / 255.0, Float32(g) / 255.0, Float32(b) / 255.0
        )

    def set_colour(mut self, slot: Int, r: Float32, g: Float32, b: Float32):
        """One entry of the shared table. `particle_colour` says which."""
        if slot <= 0 or slot >= PARTICLE_PALETTE:
            return
        self.palette[slot * 4 + 0] = r
        self.palette[slot * 4 + 1] = g
        self.palette[slot * 4 + 2] = b
        self.palette[slot * 4 + 3] = 1.0
        self.palette_dirty = True

    def spawn(
        mut self,
        rows: Span[UInt8, _],
        src_w: Int,
        src_h: Int,
        src_stride: Int,
        definition: Int,
        cx: Float64,
        cy: Float64,
        scale: Float64,
        speed: Float64,
        seed: Int,
    ) -> Int:
        """Turn a sprite frame into debris. Returns how many particles.

        `rows` is the frame's index bytes -- the sprite's OWN pixels,
        which is the whole point: the colours are not chosen, they are
        whatever that alien was made of."""
        var fx = host_ptr(self.px).unsafe_bitcast[Float32]()
        var fy = host_ptr(self.py).unsafe_bitcast[Float32]()
        var fvx = host_ptr(self.pvx).unsafe_bitcast[Float32]()
        var fvy = host_ptr(self.pvy).unsafe_bitcast[Float32]()
        var fl = host_ptr(self.life).unsafe_bitcast[Float32]()
        var cs = host_ptr(self.colour)

        var made = 0
        var rng = seed | 1
        let half_w = Float64(src_w) / 2.0
        let half_h = Float64(src_h) / 2.0
        for y in range(src_h):
            for x in range(src_w):
                let at = y * src_stride + x
                if at >= len(rows):
                    continue
                let idx = Int(rows[at])
                if idx == 0:
                    continue
                rng = (rng ^ (rng << 13)) & 0x7FFFFFFF
                rng = rng ^ (rng >> 17)
                rng = (rng ^ (rng << 5)) & 0x7FFFFFFF
                let jitter = Float64(rng & 0xFFFF) / 65536.0 * 0.8 - 0.2

                let dx = Float64(x) - half_w
                let dy = Float64(y) - half_h
                let v = burst_velocity(dx, dy, speed, jitter)

                let s = self.cursor
                fx[unsafe_offset=s] = Float32(cx + dx * scale)
                fy[unsafe_offset=s] = Float32(cy + dy * scale)
                fvx[unsafe_offset=s] = Float32(v[0])
                fvy[unsafe_offset=s] = Float32(v[1] - speed * 0.35)
                fl[unsafe_offset=s] = Float32(0.75 + jitter * 0.3)
                cs[unsafe_offset=s] = UInt8(particle_colour(definition, idx))
                self.cursor = (s + 1) % self.capacity
                made += 1
        return made

    def step(
        mut self, dt: Float64, gravity: Float64 = 260.0, fade: Float64 = 0.85
    ) raises:
        """Clear the plane and advance every particle -- two kernels, and
        the only per-frame GPU compute in the package."""
        self.frame += 1
        let plane_bytes = self.stride * self.height
        self.ctx.enqueue_function[particles_clear_kernel](
            Pointer[UInt8, MutAnyOrigin](
                unsafe_from_address=Int(host_ptr(self.plane))
            ),
            Int32(plane_bytes),
            Int32(plane_bytes),
            grid_dim=(plane_bytes + 255) // 256,
            block_dim=256,
        )
        self.ctx.enqueue_function[particles_step_kernel](
            Pointer[Float32, MutAnyOrigin](
                unsafe_from_address=Int(host_ptr(self.px))
            ),
            Pointer[Float32, MutAnyOrigin](
                unsafe_from_address=Int(host_ptr(self.py))
            ),
            Pointer[Float32, MutAnyOrigin](
                unsafe_from_address=Int(host_ptr(self.pvx))
            ),
            Pointer[Float32, MutAnyOrigin](
                unsafe_from_address=Int(host_ptr(self.pvy))
            ),
            Pointer[Float32, MutAnyOrigin](
                unsafe_from_address=Int(host_ptr(self.life))
            ),
            Pointer[UInt8, MutAnyOrigin](
                unsafe_from_address=Int(host_ptr(self.colour))
            ),
            Pointer[UInt8, MutAnyOrigin](
                unsafe_from_address=Int(host_ptr(self.plane))
            ),
            Int32(self.stride),
            Int32(self.width),
            Int32(self.height),
            Float32(dt),
            Float32(gravity),
            Float32(fade),
            Int32(self.capacity),
            Int32(self.frame),
            grid_dim=(self.capacity + 255) // 256,
            block_dim=256,
        )

    def render(mut self, frame: Frame, rtv: Int) raises:
        """Composite the plane over the game, transparent index clipped."""
        if not frame.valid:
            return
        update_subresource(
            self._context, self.texture,
            host_ptr(self.plane), self.stride,
        )
        if self.palette_dirty:
            update_subresource(
                self._context, self.palette_texture,
                self.palette.unsafe_ptr().unsafe_bitcast[UInt8]().unsafe_origin_cast[
                    MutUntrackedOrigin
                ](),
                PARTICLE_PALETTE * 16,
            )
            self.palette_dirty = False
        var uniforms = List[Float32](length=4, fill=0.0)
        uniforms[0] = Float32(self.width)
        uniforms[1] = Float32(self.height)
        update_subresource(
            self._context, self.uniform_buffer,
            uniforms.unsafe_ptr().unsafe_bitcast[UInt8]().unsafe_origin_cast[
                MutUntrackedOrigin
            ](),
            16,
        )
        set_viewport(self._context, self.width, self.height)
        var set_targets = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], UInt32,
                Pointer[Int, MutAnyOrigin], Int,
            ) thin abi("C") -> NoneType,
            "ID3D11DeviceContext",
            "OMSetRenderTargets",
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self._context))
        var slot = rtv
        set_targets(
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=_ctx_addr(self)),
            UInt32(1),
            Pointer(to=slot).unsafe_origin_cast[MutAnyOrigin](),
            0,
        )
        var set_topology = com_method_of[
            def (OpaquePointer[MutUntrackedOrigin], UInt32) thin abi("C") -> NoneType,
            "ID3D11DeviceContext",
            "IASetPrimitiveTopology",
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=_ctx_addr(self)))
        set_topology(
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=_ctx_addr(self)),
            UInt32(4),
        )
        var set_ps = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], Int, Int, UInt32
            ) thin abi("C") -> NoneType,
            "ID3D11DeviceContext",
            "PSSetShader",
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=_ctx_addr(self)))
        set_ps(
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=_ctx_addr(self)),
            self.ps, 0, UInt32(0),
        )
        var set_vs = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], Int, Int, UInt32
            ) thin abi("C") -> NoneType,
            "ID3D11DeviceContext",
            "VSSetShader",
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=_ctx_addr(self)))
        set_vs(
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=_ctx_addr(self)),
            self.vs, 0, UInt32(0),
        )
        var srv = make_srv(_dev_addr(self), self.texture)
        var pal_srv = make_srv(_dev_addr(self), self.palette_texture)
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
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=_ctx_addr(self)))
        set_srvs(
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=_ctx_addr(self)),
            UInt32(0), UInt32(2),
            srvs.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        )
        var cb = self.uniform_buffer
        var set_cbs = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], UInt32, UInt32,
                Pointer[Int, MutAnyOrigin],
            ) thin abi("C") -> NoneType,
            "ID3D11DeviceContext",
            "PSSetConstantBuffers",
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=_ctx_addr(self)))
        set_cbs(
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=_ctx_addr(self)),
            UInt32(0), UInt32(1),
            Pointer(to=cb).unsafe_origin_cast[MutAnyOrigin](),
        )
        var draw = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], UInt32, UInt32
            ) thin abi("C") -> NoneType,
            "ID3D11DeviceContext",
            "Draw",
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=_ctx_addr(self)))
        draw(
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=_ctx_addr(self)),
            UInt32(3), UInt32(0),
        )

    # The device/context addresses, held next to the DeviceContext for the
    # render pass. Stored at construction by the game.
    var _device: Int
    var _context: Int


def _ctx_addr(field: ParticleField) -> Int:
    return field._context


def _dev_addr(field: ParticleField) -> Int:
    return field._device
