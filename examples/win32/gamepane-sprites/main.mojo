# ===----------------------------------------------------------------------=== #
# G3 on screen: three thousand sprites, one draw call.
#
# The same test the reference uses for this layer (RASM examples/gpu_g3.was):
# an atlas of three recognisable 16x16 frames, a palette of eight slots so
# the same frame appears in eight colours, and a swarm of 3000 drifting over
# a G0 canvas background. Every one of them is drawn by a single
# DrawInstanced -- the count is the point.
#
# What each layer is doing, so a wrong picture says which one broke:
#   * the BACKGROUND is G0: an index plane resolved through the per-line
#     palette, so the sky gradient costs one palette row a scanline.
#   * the SPRITES are G3: index 0 in a frame is transparent and discarded,
#     1..15 resolve through the sprite's own palette SLOT, and the instance
#     alpha composites through G1's alpha-over blend state.
#
# Headless: GAMEPANE_FRAMES=n renders n frames and exits.
# ===----------------------------------------------------------------------=== #

from std.math import sin, sqrt
from std.windows import get_environment
from gamepane import (
    CANVAS_H,
    CANVAS_W,
    GamePane,
    GpuCanvas,
    KEY_ESCAPE,
    Sprites,
    key_held,
)

comptime SWARM = 3000
comptime SLOTS = 8


def _ball() -> List[UInt8]:
    """A filled disc, shaded 1..15 from the rim inward."""
    var px = List[UInt8](length=16 * 16, fill=0)
    for y in range(16):
        for x in range(16):
            var dx = Float32(x) - 7.5
            var dy = Float32(y) - 7.5
            var d = sqrt(dx * dx + dy * dy)
            if d <= 7.5:
                var shade = Int(15.0 - d * 1.7)
                if shade < 1:
                    shade = 1
                px[y * 16 + x] = UInt8(shade)
    return px^


def _star() -> List[UInt8]:
    """A four-pointed star: bright core, tapering arms."""
    var px = List[UInt8](length=16 * 16, fill=0)
    for y in range(16):
        for x in range(16):
            var dx = Float32(x) - 7.5
            var dy = Float32(y) - 7.5
            var ax = dx if dx >= 0 else -dx
            var ay = dy if dy >= 0 else -dy
            var arm = ax + ay
            if arm <= 7.5 and (ax < 1.6 or ay < 1.6 or arm < 4.0):
                var shade = Int(15.0 - arm * 1.6)
                if shade < 2:
                    shade = 2
                px[y * 16 + x] = UInt8(shade)
    return px^


def _arrow() -> List[UInt8]:
    """A chevron pointing up."""
    var px = List[UInt8](length=16 * 16, fill=0)
    for y in range(16):
        for x in range(16):
            var dx = Float32(x) - 7.5
            var ax = dx if dx >= 0 else -dx
            var edge = Float32(y) * 0.55
            if ax <= edge and ax >= edge - 4.0 and y >= 2:
                px[y * 16 + x] = UInt8(4 + ((y * 11) // 16))
    return px^


def main() raises:
    var pane = GamePane(String("Game pane - G3 sprites"), 1280, 720)
    var canvas = GpuCanvas(pane.ctx, pane.device, pane.context)
    var sprites = Sprites(pane.device, pane.context)

    # ---- the background: G0's per-line palette ----------------------------
    for y in range(CANVAS_H):
        var t = Float32(y) / Float32(CANVAS_H - 1)
        for c in range(16):
            var s = Float32(c) / 15.0
            canvas.set_line_rgb(
                y, c,
                Int(10.0 + 40.0 * s + 30.0 * t),
                Int(12.0 + 30.0 * s + 20.0 * t),
                Int(40.0 + 90.0 * s + 60.0 * (1.0 - t)),
            )
    # A soft vertical banding in the index plane, so the gradient shows.
    for y in range(CANVAS_H):
        var row = y * CANVAS_W
        for x in range(CANVAS_W):
            canvas.idx[row + x] = UInt8(
                (Int(Float32(x) * 0.02 + Float32(y) * 0.06) & 7) + 4
            )

    # ---- the atlas: three frames, eight palette slots ---------------------
    var ball = sprites.add_frame(16, 16, _ball())
    var star = sprites.add_frame(16, 16, _star())
    var arrow = sprites.add_frame(16, 16, _arrow())

    for slot in range(SLOTS):
        var a = Float32(slot) * 6.2831853 / Float32(SLOTS)
        for c in range(1, 16):
            var s = Float32(c) / 15.0
            sprites.set_palette(
                slot, c,
                Int(s * (127.0 + 127.0 * sin(a))),
                Int(s * (127.0 + 127.0 * sin(a + 2.0944))),
                Int(s * (127.0 + 127.0 * sin(a + 4.1888))),
            )

    # ---- the swarm: position, velocity, frame and slot per sprite --------
    var px = List[Float32](length=SWARM, fill=0.0)
    var py = List[Float32](length=SWARM, fill=0.0)
    var vx = List[Float32](length=SWARM, fill=0.0)
    var vy = List[Float32](length=SWARM, fill=0.0)
    var fid = List[Int](length=SWARM, fill=0)
    var slot = List[Int](length=SWARM, fill=0)

    # xorshift, seeded fixed: the same swarm every run, so a screenshot is
    # comparable with the last one.
    var seed: Int = 0x2545F491
    for i in range(SWARM):
        seed = (seed ^ (seed << 13)) & 0xFFFFFFFF
        seed = seed ^ (seed >> 17)
        seed = (seed ^ (seed << 5)) & 0xFFFFFFFF
        px[i] = Float32(seed % (CANVAS_W - 16))
        py[i] = Float32((seed // 977) % (CANVAS_H - 16))
        vx[i] = Float32((seed % 13) - 6) * 0.20
        vy[i] = Float32(((seed // 31) % 11) - 5) * 0.16
        var pick = seed % 3
        fid[i] = ball if pick == 0 else (star if pick == 1 else arrow)
        slot[i] = (seed // 7) % SLOTS

    var limit = 0
    var env = get_environment("GAMEPANE_FRAMES")
    if env.byte_length() > 0:
        for byte in env.as_bytes():
            var d = Int(byte) - 48
            if d >= 0 and d <= 9:
                limit = limit * 10 + d

    var frames = 0
    while pane.pump():
        if key_held(KEY_ESCAPE):
            break

        sprites.clear()
        for i in range(SWARM):
            px[i] += vx[i]
            py[i] += vy[i]
            if px[i] < -16.0:
                px[i] = Float32(CANVAS_W)
            elif px[i] > Float32(CANVAS_W):
                px[i] = -16.0
            if py[i] < -16.0:
                py[i] = Float32(CANVAS_H)
            elif py[i] > Float32(CANVAS_H):
                py[i] = -16.0
            sprites.push(fid[i], px[i], py[i], slot[i], 1.0)

        var frame = pane.begin_frame()
        canvas.present(pane.rtv, pane.width, pane.height)
        sprites.render(pane.rtv)
        pane.end_frame(frame)

        frames += 1
        if limit > 0 and frames >= limit:
            break

    pane.close()
    print(
        "gamepane-sprites:", frames, "frames,", SWARM,
        "sprites a frame in ONE DrawInstanced",
    )
