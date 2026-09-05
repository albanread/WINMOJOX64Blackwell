# ===----------------------------------------------------------------------=== #
# The shader pane: a background that is one fragment shader.
#
# Everything on screen here comes from the shader body below. There is no
# vertex buffer, no texture, no per-frame upload and no CPU work at all --
# the pane hands the GPU a full-screen triangle and forty bytes of uniforms,
# and the shader decides what every pixel is.
#
# The body is the Cocoa port's starfield, transliterated from MSL to HLSL
# line for line: `fract` stays `frac`, `mod` stays `fmod`, and `u.time` is
# still the only thing that changes between frames, which is what makes the
# stars twinkle.
#
# Headless:
#   GAMEPANE_FRAMES=30 GAMEPANE_DUMP=build/starfield.bgra build/starfield.exe
# ===----------------------------------------------------------------------=== #

from gamepane.api import KEY_ESCAPE
from gamepane.d3d11 import GamePane, ShaderPane, key_held


comptime STARFIELD = String(
    """
    return float4(1.0, 0.0, 0.0, 1.0);
    float2 uv2 = uv * float2(u.aspect, 1.0);
    float3 col = float3(0.02, 0.02, 0.06);
    for (int i = 0; i < 3; i++) {
        float layer = float(i);
        float scale = 18.0 + layer * 14.0;
        float2 grid = uv2 * scale + layer * 11.0;
        float2 cellId = floor(grid);
        float2 cellUv = frac(grid) - 0.5;
        float h = frac(sin(dot(cellId, float2(12.9898, 78.233)) + layer * 3.7) * 43758.5453);
        float star = smoothstep(0.06, 0.0, length(cellUv)) * step(0.97, h);
        float twinkle = 0.5 + 0.5 * sin(u.time * (2.0 + h * 4.0) + h * 12.0);
        col += (star * twinkle).xxx;
    }
    return float4(col, 1.0);
"""
)


def main() raises:
    var pane = GamePane(String("Starfield"), 640, 400)
    # The shader body crosses as BYTES, copied while the literal is alive.
    # A String built from a comptime literal has been observed to arrive
    # empty two frames down in an opt-off build -- the cstr rule again.
    var body = List[UInt8]()
    for byte in STARFIELD.as_bytes():
        body.append(byte)
    var sky = ShaderPane(pane.ctx, pane.device, pane.context, body^)
    sky.set_aspect(pane.aspect())

    while pane.pump():
        if key_held(KEY_ESCAPE):
            break
        let frame = pane.begin_frame()
        sky.render(frame, pane.rtv)
        pane.end_frame(frame)

    pane.close()
    print("presented", pane.frame_count(), "frames")
