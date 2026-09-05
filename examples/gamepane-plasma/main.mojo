# ===----------------------------------------------------------------------=== #
# The direct pane: a framebuffer you write a byte at a time.
#
# Look for the upload. There isn't one. `backbuffer_ptr()` is ordinary
# CPU-writable memory that a linear texture view already covers, so the byte
# this loop stores IS the byte the fragment shader reads -- no copy, no
# staging buffer, no replaceRegion:. That is what unified memory buys, and it
# is the right shape for anything where every pixel changes every frame: a
# plasma, a raycaster, a live Julia set.
#
# One rule: rows are `stride_bytes()` apart, not `width` apart. The stride is
# the width rounded up to the device's texture alignment, so a demo that
# writes `y * width + x` draws a diagonal smear at most widths.
#
# Headless:
#   GAMEPANE_FRAMES=30 GAMEPANE_DUMP=/tmp/plasma.bgra \
#       mojo run examples/gamepane-plasma/main.mojo
# ===----------------------------------------------------------------------=== #

from std.math import sin, sqrt
from gamepane.api import KEY_ESCAPE
from gamepane.d3d11 import GamePane, DirectPane, key_held


comptime W = 320
comptime H = 200


def main() raises:
    var pane = GamePane(String("Plasma"), 640, 400)
    var screen = DirectPane(pane.ctx, pane.device, pane.context, W, H)

    # A cyclic ramp: 256 indices around the hue wheel, so adding a constant
    # to every index rotates the colours -- palette cycling, free.
    for i in range(256):
        let a = Float32(i) * 6.2831853 / 256.0
        screen.set_rgb(
            i,
            Int(127.0 + 127.0 * sin(a)),
            Int(127.0 + 127.0 * sin(a + 2.0944)),
            Int(127.0 + 127.0 * sin(a + 4.1888)),
        )

    var t = Float32(0.0)
    let stride = screen.stride_bytes()

    while pane.pump():
        if key_held(KEY_ESCAPE):
            break
        t += Float32(pane.dt())
        let fb = screen.backbuffer_ptr()
        for y in range(H):
            let fy = Float32(y)
            let row = y * stride
            for x in range(W):
                let fx = Float32(x)
                let v = (
                    sin(fx * 0.035 + t * 1.7)
                    + sin(fy * 0.048 - t * 1.1)
                    + sin((fx + fy) * 0.028 + t * 0.9)
                    + sin(sqrt(fx * fx + fy * fy) * 0.052 - t * 2.3)
                )
                fb[unsafe_offset = row + x] = UInt8(Int(v * 31.0 + 128.0) & 255)
        let frame = pane.begin_frame()
        screen.render(frame, pane.rtv)
        pane.end_frame(frame)

    pane.close()
    print("presented", pane.frame_count(), "frames")
