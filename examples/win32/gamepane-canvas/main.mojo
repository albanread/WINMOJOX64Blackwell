# ===----------------------------------------------------------------------=== #
# G0 on screen: a plasma in the index plane, both palettes doing work.
#
# The demo is chosen to prove the parts, not to look busy:
#
#   * the PLASMA writes indices 16..255 -- one byte a pixel into
#     `canvas.idx`, no colour anywhere. Cycling the GLOBAL palette rotates
#     every colour on screen without touching a single pixel.
#   * the top forty scanlines and the bottom forty use indices 0..15, which
#     resolve through the PER-LINE palette: a sky gradient and its
#     reflection, a different set of sixteen colours on every row. That is
#     the thing a plain framebuffer cannot do cheaply and the reason the
#     canvas has two palettes.
#
# Headless: GAMEPANE_FRAMES=n renders n frames and exits.
#
#   mojo build -I . -I <repo> -o gamepane-canvas.exe main.mojo
# ===----------------------------------------------------------------------=== #

from std.math import sin, sqrt
from std.windows import get_environment
from gamepane import (
    CANVAS_H,
    CANVAS_W,
    GamePane,
    GpuCanvas,
    KEY_ESCAPE,
    key_held,
)


def main() raises:
    var pane = GamePane(String("Game pane - G0 canvas"), 1280, 720)
    var canvas = GpuCanvas(pane.device, pane.context)

    # Indices 16..255: a cyclic hue ramp, so adding a constant to the index
    # rotates every colour at once.
    for i in range(16, 256):
        var a = Float32(i - 16) * 6.2831853 / 240.0
        canvas.set_rgb(
            i,
            Int(127.0 + 127.0 * sin(a)),
            Int(127.0 + 127.0 * sin(a + 2.0944)),
            Int(127.0 + 127.0 * sin(a + 4.1888)),
        )

    # Indices 0..15 on every scanline: a sky that darkens down the top
    # band, and its mirror along the bottom. One row of the line palette
    # per scanline is the whole cost.
    for y in range(CANVAS_H):
        var t = Float32(0.0)
        if y < 40:
            t = Float32(y) / 40.0
        elif y >= CANVAS_H - 40:
            t = Float32(CANVAS_H - 1 - y) / 40.0
        else:
            t = 1.0
        for c in range(16):
            var shade = Float32(c) / 15.0
            canvas.set_line_rgb(
                y, c,
                Int(20.0 + 200.0 * shade * (1.0 - t)),
                Int(40.0 + 120.0 * shade * (1.0 - t)),
                Int(90.0 + 160.0 * (1.0 - t * 0.5)),
            )

    var frames = 0
    var limit = 0
    var env = get_environment("GAMEPANE_FRAMES")
    if env.byte_length() > 0:
        for byte in env.as_bytes():
            var d = Int(byte) - 48
            if d >= 0 and d <= 9:
                limit = limit * 10 + d

    var t = Float32(0.0)
    while pane.pump():
        if key_held(KEY_ESCAPE):
            break
        t += Float32(pane.dt())

        for y in range(CANVAS_H):
            var fy = Float32(y)
            var row = y * CANVAS_W
            var banded = y < 40 or y >= CANVAS_H - 40
            for x in range(CANVAS_W):
                var fx = Float32(x)
                var v = (
                    sin(fx * 0.021 + t * 1.7)
                    + sin(fy * 0.031 - t * 1.1)
                    + sin((fx + fy) * 0.017 + t * 0.9)
                    + sin(sqrt(fx * fx + fy * fy) * 0.029 - t * 2.3)
                )
                if banded:
                    # 0..15: the per-line palette resolves these.
                    canvas.idx[row + x] = UInt8(
                        Int(v * 3.7 + 8.0) & 15
                    )
                else:
                    # 16..255: the global palette, cycled by `t`.
                    var n = Int(v * 30.0 + 128.0 + t * 40.0)
                    canvas.idx[row + x] = UInt8(16 + (n & 239))

        var frame = pane.begin_frame()
        canvas.present(pane.rtv, pane.width, pane.height)
        pane.end_frame(frame)

        frames += 1
        if limit > 0 and frames >= limit:
            break

    pane.close()
    print("gamepane-canvas: presented", frames, "frames")
