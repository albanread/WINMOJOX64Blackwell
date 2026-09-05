"""The layers: three panes, three HLSL programs, and the draw calls that
composite them.

The MSL is ported, not reinvented -- the indexed shader keeps the three
things its Metal original calls specification rather than style: index 0
discards (the layer below shows through), the scroll offset is added in
WORLD space after the viewport lookup (panning costs nothing), and the
palette index splits at 16 into per-scanline and global halves. The MSL's
`texture2d<uint>.read` becomes `Texture2D.Load`, `discard_fragment()`
becomes `clip(-1)`, and the palette -- RGBA bytes on both platforms --
is read through a ByteAddressBuffer at `k * 4`, which is the same four
bytes little-endian.

What changes is where the bytes come from. Metal sampled the pane's
allocation through a linear texture view; Direct3D cannot alias app
memory, so `render` pushes the pane's bytes up with `UpdateSubresource`
-- from the HOST side of the same device-mapped allocation the CPU drew
through and the kernels wrote through. One upload of a retro-sized plane
per frame is the platform's toll for a discrete card over PCIe, and it is
paid here, in one place, instead of being smeared over the api.
"""

from max.gpu.host import DeviceContext, HostBuffer
from std.ffi import c_int
from std.memory import Pointer, OpaquePointer
from std.sys._com import com_method_of
from std.sys._winkb import winkb_constant
from std.windows.gui import win32

from gamepane.api import (
    Palette,
    Plane,
    ShaderParams,
    PALETTE_SIZE,
    stride_for,
    buffer_len_for,
    NUM_BUFFERS,
    FRONT,
    GLOBAL_COLORS,
    LINE_COLORS,
    palette_entries,
    hsv_to_rgb,
    clamp_scroll,
)

from .window import Frame
from .device import (
    create_buffer,
    create_texture2d,
    compile_shader_blob,
    create_vertex_shader,
    create_pixel_shader,
    set_viewport,
    set_viewport,
    device_ptr,
    host_ptr,
    update_subresource,
    draw,
    om_set_render_targets,
    clear_render_target,
)


comptime D3D11_USAGE_DEFAULT = 0
comptime D3D11_BIND_SHADER_RESOURCE = 8
comptime D3D11_BIND_CONSTANT_BUFFER = 4
comptime DXGI_FORMAT_R8_UINT = 61
comptime DXGI_FORMAT_R32G32B32A32_FLOAT = 2


# The fullscreen triangle and the vertex shader every layer shares.
comptime VERTEX_SHADER = String(
    """
struct PSIn {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

PSIn vmain(uint vid : SV_VertexID) {
    float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    PSIn o;
    float2 p = positions[vid];
    o.pos = float4(p, 0.0, 1.0);
    o.uv = float2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);
    return o;
}
"""
)

# The shader pane's header: uniforms arrive as three float4s -- an HLSL
# cbuffer pads array elements to sixteen bytes, so the MSL's forty-byte
# `Uniforms` is carried as c0 = (time, aspect, p0, p1), c1 = p2..p5,
# c2 = p6, p7 -- and handed to the game's body reassembled into the same
# `Uniforms` shape the api tier documents. The game writes only the body.
comptime SHADER_HEADER = String(
    """
cbuffer U : register(b0) {
    float4 c0;  // time, aspect, p0, p1
    float4 c1;  // p2..p5
    float4 c2;  // p6, p7
};

struct Uniforms {
    float time;
    float aspect;
    float p[8];
};

Uniforms make_u() {
    Uniforms u;
    u.time = c0.x;
    u.aspect = c0.y;
    u.p[0] = c0.z; u.p[1] = c0.w;
    u.p[2] = c1.x; u.p[3] = c1.y; u.p[4] = c1.z; u.p[5] = c1.w;
    u.p[6] = c2.x; u.p[7] = c2.y;
    return u;
}

float4 fmain(float2 uv, Uniforms u) {
"""
)

# Transliterated from the Metal backend's INDEXED_SHADER. The three
# specification points survive verbatim: index 0 clips, scroll is world
# space after the viewport lookup, and the palette index splits at 16.
comptime TAIL = String(
    """
}

struct PSIn {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

float4 ps_main(PSIn psi) : SV_Target {
    return fmain(psi.uv, make_u());
}
"""
)


comptime INDEXED_SHADER = String(
    """
Texture2D<uint> indexTex : register(t0);
Texture1D<uint> palette : register(t1);
cbuffer U : register(b0) {
    float scroll_x;
    float scroll_y;
    float viewport_w;
    float viewport_h;
};

struct PSIn {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

float4 ps_main(PSIn psi) : SV_Target {
    uint screenX = uint(psi.uv.x * viewport_w);
    uint screenY = uint(psi.uv.y * viewport_h);
    uint worldX = uint(int(screenX) + int(scroll_x));
    uint worldY = uint(int(screenY) + int(scroll_y));
    uint ci = indexTex.Load(int3(worldX, worldY, 0)).r;
    if (ci == 0u) { clip(-1); }
    uint k;
    if (ci < 16u) { k = screenY * 16u + ci; } else { k = uint(viewport_h) * 16u + (ci - 16u); }
    uint rgba = palette.Load(int2(k, 0));
    return float4(
        float(rgba & 255u),
        float((rgba >> 8u) & 255u),
        float((rgba >> 16u) & 255u),
        float((rgba >> 24u) & 255u)
    ) / 255.0;
}
"""
)

# The direct pane's shader: the same palette arithmetic, no scroll, and
# no transparent index -- the direct pane owns the whole frame.
comptime DIRECT_SHADER = String(
    """
Texture2D<uint> indexTex : register(t0);
Texture1D<uint> palette : register(t1);
cbuffer U : register(b0) {
    float w;
    float h;
    float pad0;
    float pad1;
};

struct PSIn {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

float4 ps_main(PSIn psi) : SV_Target {
    uint x = uint(psi.uv.x * w);
    uint y = uint(psi.uv.y * h);
    uint ci = indexTex.Load(int3(x, y, 0)).r;
    uint rgba = palette.Load(int2(ci, 0));
    return float4(
        float(rgba & 255u),
        float((rgba >> 8u) & 255u),
        float((rgba >> 16u) & 255u),
        float((rgba >> 24u) & 255u)
    ) / 255.0;
}
"""
)


def _bytes(s: String) -> List[UInt8]:
    """A string's bytes as a heap list -- the only form that reliably
    crosses a function boundary in this build."""
    var out = List[UInt8]()
    for byte in s.as_bytes():
        out.append(byte)
    return out^


def _build_pass(
    compile: def (
        Int, Int, Int, Int, Int, Int, Int, UInt32, UInt32,
        Pointer[Int, MutAnyOrigin],
        Pointer[Int, MutAnyOrigin],
    ) thin abi("C") -> Int32,
    device: Int, body_bytes: List[UInt8],
) raises -> Tuple[Int, Int, Int]:
    """Compile a layer's shaders and build its constant buffer. Returns
    (pixel_shader, constant_buffer). The vertex shader is shared; each
    pane compiles it once more for now, which is one D3DCompile of forty
    lines and nothing to optimise."""
    var empty = List[UInt8]()
    var vs_src = _bytes(String(VERTEX_SHADER))
    var vs_blob = compile_shader_blob(
        compile, vs_src, empty, empty, _bytes(String("vmain")),
        _bytes(String("vs_5_0"))
    )
    var vs = create_vertex_shader(device, vs_blob[0], vs_blob[1])
    var ps_blob = compile_shader_blob(
        compile, body_bytes, _bytes(String("")), _bytes(String("")),
        _bytes(String("ps_main")), _bytes(String("ps_5_0"))
    )
    var ps = create_pixel_shader(device, ps_blob[0], ps_blob[1])
    var cb = create_buffer(
        device, 64, D3D11_BIND_CONSTANT_BUFFER, D3D11_USAGE_DEFAULT
    )
    return (vs, ps, cb)


def _begin_pass(
    context: Int, device: Int, rtv: Int, vertex_shader: Int,
    pixel_shader: Int, constant_buffer: Int,
    constants: Pointer[UInt8, MutUntrackedOrigin], constant_bytes: Int,
    textures: List[Int], clear: Bool, clear_r: Float32, clear_g: Float32,
    clear_b: Float32, vp_w: Int, vp_h: Int,
) raises:
    """One layer's draw: bind, upload constants, set the textures, draw
    the fullscreen triangle. `clear` clears first -- layer 0's load
    action, in the Metal design's own vocabulary."""
    # D3D11's default topology is TRIANGLESTRIP; this triangle is a LIST.
    # Unset, it renders three disconnected lines and no error anywhere.
    var set_topology = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], UInt32
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "IASetPrimitiveTopology",
    ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=context))
    set_topology(
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=context),
        UInt32(4),
    )
    set_viewport(context, vp_w, vp_h)
    if clear:
        clear_render_target(context, rtv, clear_r, clear_g, clear_b)
    om_set_render_targets(context, rtv)
    if constant_bytes > 0:
        update_subresource(
            context, constant_buffer, constants, constant_bytes
        )
    var set_ps = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int, Int, Int
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "PSSetShader",
    ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=context))
    set_ps(OpaquePointer[MutUntrackedOrigin](unsafe_from_address=context),
           pixel_shader, 0, 0)
    var set_vs = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int, Int, UInt32
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "VSSetShader",
    ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=context))
    set_vs(
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=context),
        vertex_shader, 0, UInt32(0),
    )
    var n = len(textures)
    if n > 0:
        var set_srvs = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin],
                UInt32,  # StartSlot
                UInt32,  # NumViews
                Pointer[Int, ImmUnsafeAnyOrigin],  # ppShaderResourceViews
            ) thin abi("C") -> NoneType,
            "ID3D11DeviceContext",
            "PSSetShaderResources",
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=context))
        set_srvs(
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=context),
            UInt32(0),
            UInt32(n),
            textures.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        )
    var set_cbs = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            UInt32,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "PSSetConstantBuffers",
    ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=context))
    var cb = constant_buffer
    set_cbs(
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=context),
        UInt32(0),
        UInt32(1),
        Pointer(to=cb).unsafe_origin_cast[MutAnyOrigin](),
    )
    draw(context, 3)


def make_srv(device: Int, resource: Int) raises -> Int:
    """A whole-resource shader resource view. A null description asks
    D3D11 for the default view over the whole thing, which is exactly
    what every pane here wants."""
    var make_view = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            Int,  # pDesc -- null: the default view
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreateShaderResourceView",
    ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=device))
    var view: Int = 0
    var hr = make_view(
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=device),
        resource,
        Int(0),
        Pointer(to=view).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr != 0 or view == 0:
        raise Error("CreateShaderResourceView failed, hr = " + String(hr))
    return view


@fieldwise_init
struct ShaderPane(Movable):
    """Layer 0: a full-screen fragment body and ten floats.

    The game writes only `fmain`'s BODY -- the pane wraps it in the
    vertex shader, the uniform declarations and the entry that reassembles
    `Uniforms` from the constant buffer. Everything the body may name --
    `uv`, `u.time`, `u.aspect`, `u.p[0..8]` -- is the api tier's contract,
    unchanged from the Metal side.
    """

    var device: Int
    var context: Int
    var vertex_shader: Int
    var pixel_shader: Int
    var constant_buffer: Int
    var params: ShaderParams
    var is_clear: Bool
    var source: List[UInt8]
    """The pane's own copy of the shader text, as bytes. The caller's
    argument may be a borrowed slice of a comptime materialisation, and a
    String crossing two frames has been observed to arrive EMPTY in an
    optimisation-off build -- so the pane copies the bytes at construction,
    where the source is still alive, and every later stage moves bytes.
    The copy loop is the proven cstr pattern."""

    def __init__(
        out self, pane_ctx: DeviceContext, device: Int, context: Int,
        body: List[UInt8],
    ) raises:
        self.device = device
        self.context = context
        self.params = ShaderParams()
        var copy = List[UInt8]()
        for byte in body:
            copy.append(byte)
        self.source = copy^
        # Layer 0 is always Clear -- the ground the other layers draw over.
        self.is_clear = True
        var src = _bytes(String(SHADER_HEADER))
        for byte in self.source:
            src.append(byte)
        for byte in _bytes(String(TAIL)):
            src.append(byte)
        var built = _build_pass(
            compile_shader_helper(), device, src
        )
        self.vertex_shader = built[0]
        self.pixel_shader = built[1]
        self.constant_buffer = built[2]
        _ = pane_ctx

    def set_param(mut self, i: Int, value: Float32):
        self.params.set_param(i, value)

    def set_aspect(mut self, aspect: Float32):
        self.params.set_aspect(aspect)

    def render(mut self, frame: Frame, rtv: Int) raises:
        """Layer 0, with the time advanced by the pane's clock."""
        if not frame.valid:
            return
        self.params.set_time(Float32(Float64(_now_ns()) / 1_000_000_000.0))
        # Repack ten floats into three float4s: (t, a, p0, p1), p2..p5,
        # (p6, p7, pad, pad). The shader's make_u() undoes exactly this.
        var packed = List[Float32](length=12, fill=0.0)
        packed[0] = self.params.v[0]
        packed[1] = self.params.v[1]
        for i in range(8):
            packed[2 + i] = self.params.v[2 + i]
        var no_textures = List[Int]()
        _begin_pass(
            self.context, self.device, rtv, self.vertex_shader,
            self.pixel_shader, self.constant_buffer,
            packed.unsafe_ptr().unsafe_bitcast[UInt8]().unsafe_origin_cast[
                MutUntrackedOrigin
            ](),
            48,
            no_textures^,
            False, 0.0, 0.0, 0.0, 640, 400,
        )


def compile_shader_helper() raises -> def (
    Int, Int, Int, Int, Int, Int, Int, UInt32, UInt32,
    Pointer[Int, MutAnyOrigin],
    Pointer[Int, MutAnyOrigin],
) thin abi("C") -> Int32:
    from .device import resolve_compiler

    return resolve_compiler()


def _now_ns() raises -> Int:
    from std.windows import performance_counter, performance_frequency

    return Int((performance_counter() * 1_000_000_000) // performance_frequency())


@fieldwise_init
struct DirectPane(Movable):
    """A palette-indexed screen the host writes straight into.

    The Metal pane's three rotating buffers become three device-mapped
    pinned allocations: the CPU writes bytes, the compositor pushes the
    written one up per frame, and the rotation means the GPU is never
    reading the buffer the game is writing. The stride is the width
    rounded up -- the alignment rule survives the port.
    """

    var ctx: DeviceContext
    var device: Int
    var context: Int
    var width: Int
    var height: Int
    var stride: Int
    var buffers: List[Int]
    """Device addresses, for the blitter."""
    var hosts: List[Int]
    """Host addresses, for the game."""
    var owned: List[HostBuffer[DType.uint8]]
    """The owners. The device and host addresses above are only as alive
    as these, and Mojo destroys a value at its last use -- so they live
    here, as fields, for as long as the pane does."""
    var index_srv: Int
    var index_upload: Int
    var palette_srv: Int
    var palette_upload: Int
    """The palette texture the SRV reads; held so the view stays honest."""
    var vertex_shader: Int
    var pixel_shader: Int
    var constant_buffer: Int
    var write: Int
    var palette: Palette

    def __init__(
        out self, pane_ctx: DeviceContext, device: Int, context: Int,
        width: Int, height: Int,
    ) raises:
        if width <= 0 or height <= 0:
            raise Error("direct pane needs a non-zero size")
        self.ctx = pane_ctx
        self.device = device
        self.context = context
        self.width = width
        self.height = height
        # The D3D texture does not demand the Metal alignment, but the
        # stride rule stays: it is the api's contract, and a game that
        # writes rows must mean the same rows on both platforms.
        self.stride = stride_for(width, 16)

        self.buffers = List[Int]()
        self.hosts = List[Int]()
        self.owned = List[HostBuffer[DType.uint8]]()
        let bytes = buffer_len_for(self.stride, height)
        for _ in range(3):
            var buf = self.ctx.enqueue_create_host_buffer[DType.uint8](bytes)
            # Zero it: a demo's first frame should be a colour, not
            # whatever the allocator had.
            var p = host_ptr(buf)
            for i in range(bytes):
                p[unsafe_offset=i] = 0
            self.buffers.append(device_ptr(buf))
            self.hosts.append(Int(p))
            self.owned.append(buf^)

        self.write = 0
        self.palette = Palette()
        var index_tex = create_texture2d(
            device, width, height, DXGI_FORMAT_R8_UINT,
            D3D11_BIND_SHADER_RESOURCE, D3D11_USAGE_DEFAULT, 0,
        )
        self.index_srv = make_srv(device, index_tex)
        self.index_upload = index_tex
        var palette_tex = create_texture2d(
            device, PALETTE_SIZE, 1, DXGI_FORMAT_R8_UINT,
            D3D11_BIND_SHADER_RESOURCE, D3D11_USAGE_DEFAULT, 0,
        )
        self.palette_srv = make_srv(device, palette_tex)
        self.palette_upload = palette_tex
        var src = DIRECT_SHADER
        var built = _build_pass(
            compile_shader_helper(), device, _bytes(String(src))
        )
        self.vertex_shader = built[0]
        self.pixel_shader = built[1]
        self.constant_buffer = built[2]

    def stride_bytes(self) -> Int:
        """Bytes per row. A writer addresses `fb[y * stride_bytes() + x]`."""
        return self.stride

    def buffer_len(self) -> Int:
        """Total writable bytes in one buffer -- `stride * height`."""
        return buffer_len_for(self.stride, self.height)

    def buffer_count(self) -> Int:
        return 3

    def backbuffer_ptr(self) -> Pointer[UInt8, MutUntrackedOrigin]:
        """The buffer to write RIGHT NOW. Changes after every `render`."""
        return Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=self.hosts[self.write]
        )

    def buffer_ptrs(self) -> List[Int]:
        """Every buffer's host address, in rotation order. `render` draws
        buffer `n % count` for the nth frame, so a writer counting frames
        the same way agrees which buffer is safe with no synchronisation."""
        var out = List[Int]()
        for i in range(3):
            out.append(self.hosts[i])
        return out^

    def set_rgb(mut self, index: Int, r: Int, g: Int, b: Int):
        self.palette.set_rgb(index, r, g, b)

    def render(mut self, frame: Frame, rtv: Int) raises:
        """Draw the buffer the host just wrote, then rotate so the next
        thing it writes is a buffer the GPU is not reading."""
        if not frame.valid:
            return
        if self.palette.dirty:
            update_subresource(
                self.context, self.palette_upload,
                self.palette.v.unsafe_ptr().unsafe_bitcast[UInt8]().unsafe_origin_cast[
                    MutUntrackedOrigin
                ](),
                Int(PALETTE_SIZE),
            )
            self.palette.dirty = False

        var drawn = self.write
        var host = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=self.hosts[drawn]
        )
        update_subresource(
            self.context, self.index_upload, host, self.stride
        )

        var uniforms = List[Float32](length=4, fill=0.0)
        uniforms[0] = Float32(self.width)
        uniforms[1] = Float32(self.height)
        var textures = List[Int](length=1, fill=0)
        textures[0] = self.index_srv
        _begin_pass(
            self.context, self.device, rtv, self.vertex_shader,
            self.pixel_shader, self.constant_buffer,
            uniforms.unsafe_ptr().unsafe_bitcast[UInt8]().unsafe_origin_cast[
                MutUntrackedOrigin
            ](),
            16,
            textures^,
            True, 0.0, 0.0, 0.0, self.width, self.height,
        )

        self.write = (drawn + 1) % 3


@fieldwise_init
struct IndexedUniforms(Copyable, Movable):
    """`{scroll_x, scroll_y, viewport_w, viewport_h}`, sixteen bytes."""

    var scroll_x: Float32
    var scroll_y: Float32
    var viewport_w: Float32
    var viewport_h: Float32


struct IndexedPane(Movable):
    """Eight index planes, a per-line palette, and a world larger than the
    viewport that the compositor pans across.

    **There is no CPU mirror**, exactly as on Metal: each slot is one
    device-mapped pinned allocation, so `pset` stores into the bytes the
    compositor pushes up, and the blitter kernels read and write the same
    bytes through their device addresses. The overscan is the other half:
    draw once into a world bigger than the screen, then move `set_scroll`
    instead of redrawing.
    """

    var ctx: DeviceContext
    var device: Int
    var context: Int
    var world_width: Int
    var world_height: Int
    var viewport_width: Int
    var viewport_height: Int
    var stride: Int
    var scroll_x: Int
    var scroll_y: Int
    var active: Int
    # The buffers, and they MUST be held: the device addresses below are
    # only as alive as the allocations they point into.
    var owned: List[HostBuffer[DType.uint8]]
    """The slot allocations. The bases and device addresses are only as
    alive as these."""
    var bases: List[Int]
    var device_addrs: List[Int]
    # Logical slot -> physical index. swap_buffers permutes THIS rather
    # than moving allocations, which keeps the swap two integer stores.
    var slot_of: List[Int]
    var palette_len: Int
    var palette_host: Int
    var palette_owned: HostBuffer[DType.uint8]
    var palette_upload: Int
    var index_srv: Int
    var palette_srv: Int
    var pixel_shader: Int
    var constant_buffer: Int

    def __init__(
        out self,
        pane_ctx: DeviceContext,
        device: Int,
        context: Int,
        world_width: Int,
        world_height: Int,
        viewport_width: Int,
        viewport_height: Int,
    ) raises:
        if world_width < viewport_width or world_height < viewport_height:
            raise Error(
                "world size must be >= viewport size (that is the overscan"
                " margin)"
            )
        self.ctx = pane_ctx
        self.device = device
        self.context = context
        self.world_width = world_width
        self.world_height = world_height
        self.viewport_width = viewport_width
        self.viewport_height = viewport_height
        self.stride = stride_for(world_width, 16)
        self.scroll_x = 0
        self.scroll_y = 0
        self.active = FRONT

        self.owned = List[HostBuffer[DType.uint8]]()
        self.bases = List[Int]()
        self.device_addrs = List[Int]()
        self.slot_of = List[Int]()
        let bytes = self.stride * world_height
        for i in range(NUM_BUFFERS):
            var buf = self.ctx.enqueue_create_host_buffer[DType.uint8](bytes)
            var p = host_ptr(buf)
            for b in range(bytes):
                p[unsafe_offset=b] = 0
            self.device_addrs.append(device_ptr(buf))
            self.bases.append(Int(p))
            self.slot_of.append(i)
            self.owned.append(buf^)

        # The palette lives HERE and nowhere else. There is nothing to
        # upload FROM, so nothing can copy a stale mirror over a game's
        # work -- which is exactly what a mirror would do the moment a
        # guest wrote to it.
        self.palette_len = palette_entries(viewport_height)
        var pal = self.ctx.enqueue_create_host_buffer[DType.uint8](
            self.palette_len * 4
        )
        var pp = host_ptr(pal)
        for i in range(self.palette_len):
            pp[unsafe_offset = i * 4 + 0] = 0
            pp[unsafe_offset = i * 4 + 1] = 0
            pp[unsafe_offset = i * 4 + 2] = 0
            pp[unsafe_offset = i * 4 + 3] = 255
        self.palette_host = Int(pp)
        self.palette_owned = pal^
        var index_tex = create_texture2d(
            device, world_width, world_height, DXGI_FORMAT_R8_UINT,
            D3D11_BIND_SHADER_RESOURCE, D3D11_USAGE_DEFAULT, 0,
        )
        self.index_srv = make_srv(device, index_tex)
        var palette_tex = create_texture2d(
            device, self.palette_len, 1, DXGI_FORMAT_R8_UINT,
            D3D11_BIND_SHADER_RESOURCE, D3D11_USAGE_DEFAULT, 0,
        )
        self.palette_srv = make_srv(device, palette_tex)
        self.palette_upload = palette_tex
        var src = INDEXED_SHADER
        var built = _build_pass(
            compile_shader_helper(), device, _bytes(String(src))
        )
        self.vertex_shader = built[0]
        self.pixel_shader = built[1]
        self.constant_buffer = built[2]
        self.load_default_palette()

    # ── slots ────────────────────────────────────────────────────────────

    def plane(mut self, slot: Int) -> Plane:
        """The plane for a slot, ready to draw into. Slots out of range give
        the active one rather than trapping."""
        var s = slot
        if s < 0 or s >= NUM_BUFFERS:
            s = self.active
        return Plane(
            Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=self.bases[self.slot_of[s]]
            ),
            self.stride,
            self.world_width,
            self.world_height,
        )

    def device_plane(mut self, slot: Int) -> Int:
        """The slot's DEVICE address, for the blitter's kernels."""
        var s = slot
        if s < 0 or s >= NUM_BUFFERS:
            s = self.active
        return self.device_addrs[self.slot_of[s]]

    def set_active(mut self, slot: Int):
        var s = slot
        if s < 0 or s >= NUM_BUFFERS:
            s = self.active
        self.active = s

    def swap_buffers(mut self):
        """FRONT and BACK exchange identities, not bytes."""
        var f = self.slot_of[FRONT]
        self.slot_of[FRONT] = self.slot_of[1]
        self.slot_of[1] = f

    def set_scroll(mut self, x: Int, y: Int):
        """Where in the world the viewport sits. Clamped to the overscan
        margin, which is `world - viewport`."""
        self.scroll_x = clamp_scroll(x, self.world_width, self.viewport_width)
        self.scroll_y = clamp_scroll(
            y, self.world_height, self.viewport_height
        )

    # ── the palette ──────────────────────────────────────────────────────

    def palette_ptr(mut self) -> Pointer[UInt8, MutUntrackedOrigin]:
        """The palette's bytes, for a writer that recomputes them every
        frame -- the copper-bars case, where 240 commands a frame became
        none."""
        return Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=self.palette_host
        )

    def set_palette_entry(
        mut self, line_or_index: Int, index: Int, r: Int, g: Int, b: Int
    ):
        """One palette entry: per-scanline (index 1..15) or global
        (16..255), at the entry the api's arithmetic names."""
        var entry = line_or_index
        if index >= 16:
            entry = (
                self.viewport_height * LINE_COLORS + (index - GLOBAL_COLORS)
            )
        else:
            entry = line_or_index * LINE_COLORS + index
        var pp = self.palette_ptr()
        pp[unsafe_offset = entry * 4 + 0] = UInt8(r)
        pp[unsafe_offset = entry * 4 + 1] = UInt8(g)
        pp[unsafe_offset = entry * 4 + 2] = UInt8(b)
        pp[unsafe_offset = entry * 4 + 3] = 255

    def load_default_palette(mut self):
        """The Rust's default: a 16-step per-line grey ramp and a 240-step
        hue wheel. `hsv_to_rgb` is the api tier's, truncation and all."""
        var pp = self.palette_ptr()
        for line in range(self.viewport_height):
            for index in range(1, 16):
                let v = Float32(index) / 16.0
                let shade = UInt8(16.0 + v * 222.0)
                var entry = line * LINE_COLORS + index
                pp[unsafe_offset = entry * 4 + 0] = shade
                pp[unsafe_offset = entry * 4 + 1] = shade
                pp[unsafe_offset = entry * 4 + 2] = shade
                pp[unsafe_offset = entry * 4 + 3] = 255
        for index in range(16, 256):
            let t = Float32(index - 16) / 240.0
            let rgb = hsv_to_rgb(t, 1.0, 1.0)
            var entry = (
                self.viewport_height * LINE_COLORS + (index - 16)
            )
            pp[unsafe_offset = entry * 4 + 0] = UInt8(rgb[0])
            pp[unsafe_offset = entry * 4 + 1] = UInt8(rgb[1])
            pp[unsafe_offset = entry * 4 + 2] = UInt8(rgb[2])
            pp[unsafe_offset = entry * 4 + 3] = 255

    # ── the frame ────────────────────────────────────────────────────────

    def render(mut self, frame: Frame, rtv: Int, clear: Bool = False) raises:
        """Composite FRONT at the current scroll offset.

        `clear` is False almost always: this draws OVER whatever the
        shader pane already put there, which is what index 0's clip is
        for. Clear only makes sense when this is the bottom layer of a
        frame.
        """
        if not frame.valid:
            return
        # The pane's front slot, host side: the compositor reads it after
        # the ordering rule has synchronised every kernel that touched it.
        var host = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=self.bases[self.slot_of[FRONT]]
        )
        update_subresource(self.context, self.index_tex, host, self.stride)
        update_subresource(
            self.context, self.palette_upload,
            Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=self.palette_host
            ),
            Int(0),
        )
        var uni = IndexedUniforms(
            Float32(self.scroll_x),
            Float32(self.scroll_y),
            Float32(self.viewport_width),
            Float32(self.viewport_height),
        )
        var textures = List[Int](length=2, fill=0)
        textures[0] = self.index_srv
        textures[1] = self.palette_srv
        _begin_pass(
            self.context, self.device, rtv, self.vertex_shader,
            self.pixel_shader, self.constant_buffer,
            uni.unsafe_ptr().unsafe_bitcast[UInt8]().unsafe_origin_cast[
                MutUntrackedOrigin
            ](),
            16,
            textures^,
            clear, 0.0, 0.0, 0.0, self.viewport_width, self.viewport_height,
        )
