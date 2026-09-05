"""Layer 3 on Direct3D 11: the text overlay.

The Metal design's shape: a retained RGBA buffer the CPU rasterises the
5×7 font into, backing a texture, composited last with alpha blending so
it survives whatever the pane clears. `clear` zeroes the buffer, which
with A=0 everywhere means fully transparent -- the overlay's rest state.
"""

from max.gpu.host import DeviceContext
from std.memory import Pointer, OpaquePointer
from std.sys._com import com_method_of

from gamepane.api import (
    RgbaCanvas,
    glyph_for,
    text_cols,
    text_rows,
    GLYPH_W,
    GLYPH_H,
    GLYPH_ADVANCE,
)

from .device import (
    create_buffer,
    create_texture2d,
    update_subresource,
    set_viewport,
)
from .layers import make_srv
from .window import Frame
from .layers import _bytes, compile_shader_helper
from .device import (
    compile_shader_blob, create_vertex_shader, create_pixel_shader,
)


comptime TEXT_VERTEX = String(
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

comptime TEXT_PIXEL = String(
    """
Texture2D<float4> overlay : register(t0);
struct PSIn {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};
float4 ps_main(PSIn psi) : SV_Target {
    float4 c = overlay.Load(int3(int(psi.uv.x * 640.0), int(psi.uv.y * 400.0), 0));
    clip(c.a - 0.0039);  // A < 1/255: fully transparent, show the game
    return c;
}
"""
)


struct TextOverlay(Movable):
    """A rasterised text surface, viewport-sized, blended over the frame.

    Rows are width-packed RGBA bytes (the api's `RgbaCanvas` contract);
    the texture upload uses the width as the row pitch, which a
    D3D11_TEX2D with matching width accepts."""

    var ctx: DeviceContext
    var device: Int
    var context: Int
    var width: Int
    var height: Int
    var canvas: RgbaCanvas
    var pixels: List[UInt8]
    """The canvas's storage; the canvas points into it, so it must live as
    long as the overlay does."""
    var texture: Int
    var vs: Int
    var ps: Int
    var _device: Int
    var _context: Int

    def __init__(
        out self, pane_ctx: DeviceContext, device: Int, context: Int,
        width: Int, height: Int,
    ) raises:
        self.ctx = pane_ctx
        self.device = device
        self.context = context
        self.width = width
        self.height = height
        var pixels = List[UInt8](length=width * height * 4, fill=0)
        self.canvas = RgbaCanvas(
            pixels.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
            width, height,
        )
        self.pixels = pixels^
        self.texture = create_texture2d(
            device, width, height, 87,  # B8G8R8A8_UNORM
            8, 0, 0,
        )
        var compile = compile_shader_helper()
        var empty = List[UInt8]()
        var vs_blob = compile_shader_blob(
            compile, _bytes(String(TEXT_VERTEX)), empty, empty,
            _bytes(String("vmain")), _bytes(String("vs_5_0")),
        )
        self.vs = create_vertex_shader(device, vs_blob[0], vs_blob[1])
        var ps_blob = compile_shader_blob(
            compile, _bytes(String(TEXT_PIXEL)), empty, empty,
            _bytes(String("ps_main")), _bytes(String("ps_5_0")),
        )
        self.ps = create_pixel_shader(device, ps_blob[0], ps_blob[1])
        self._device = device
        self._context = context

    def clear(mut self):
        """Zero the canvas: A=0 everywhere, fully transparent."""
        self.canvas.clear()

    def draw_text(
        mut self,
        x: Int,
        y: Int,
        text: String,
        r: Int,
        g: Int,
        b: Int,
        scale: Int,
    ):
        """Rasterise the 5×7 font at (x, y), blocks of `scale` pixels.

        The rasterisation itself is the API's own `RgbaCanvas` -- the same
        code the Mac backend's overlay uses, bit order and all. The first
        version here re-derived it from the glyph table and indexed seven
        bytes as thirty-five: the assert in `List.__getitem__` caught it,
        which is exactly what it is for."""
        self.canvas.draw_text(x, y, text, r, g, b, scale)

    def render(mut self, frame: Frame, rtv: Int) raises:
        """Composite the overlay, blended, always last."""
        if not frame.valid:
            return
        update_subresource(
            self._context, self.texture,
            self.canvas.base, self.width * 4,
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
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self._context),
            UInt32(1),
            Pointer(to=slot).unsafe_origin_cast[MutAnyOrigin](),
            0,
        )
        var set_topology = com_method_of[
            def (OpaquePointer[MutUntrackedOrigin], UInt32) thin abi("C") -> NoneType,
            "ID3D11DeviceContext",
            "IASetPrimitiveTopology",
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self._context))
        set_topology(
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self._context),
            UInt32(4),
        )
        var set_ps = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], Int, Int, UInt32
            ) thin abi("C") -> NoneType,
            "ID3D11DeviceContext",
            "PSSetShader",
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self._context))
        set_ps(
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self._context),
            self.ps, 0, UInt32(0),
        )
        var set_vs = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], Int, Int, UInt32
            ) thin abi("C") -> NoneType,
            "ID3D11DeviceContext",
            "VSSetShader",
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self._context))
        set_vs(
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self._context),
            self.vs, 0, UInt32(0),
        )
        var srv = make_srv(self.device, self.texture)
        var srvs = List[Int](length=1, fill=srv)
        var set_srvs = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], UInt32, UInt32,
                Pointer[Int, ImmUnsafeAnyOrigin],
            ) thin abi("C") -> NoneType,
            "ID3D11DeviceContext",
            "PSSetShaderResources",
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self._context))
        set_srvs(
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self._context),
            UInt32(0), UInt32(1),
            srvs.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        )
        var draw = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], UInt32, UInt32
            ) thin abi("C") -> NoneType,
            "ID3D11DeviceContext",
            "Draw",
        ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self._context))
        draw(
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self._context),
            UInt32(3), UInt32(0),
        )
