# ===----------------------------------------------------------------------=== #
# The bank, and the blits between it: eight GPU planes, no host in the loop.
#
# This is the model the port is built on, drawn out end to end. Eight planes
# live in VRAM. Slots 0 and 1 are the display pair -- one shown, one drawn
# into, swapped a frame. Slots 2..7 hold data: art loaded ONCE, when a level
# starts, and never touched by the CPU again. A frame is a handful of
# rectangle blits between planes, every one of them a kernel launch that
# reads and writes device memory and never crosses the bus.
#
# What the demo puts on screen, and which blit each part proves:
#
#   fill    the sky above the horizon -- a constant, no source
#   copy    the landscape, scrolling, from a 1280-wide plane in slot 2.
#           Two copies a frame, the second wrapping the seam, which is how
#           an endless backdrop costs a fixed 640x240 of blitting
#   keyed   the sprites, from a strip of eight frames in slot 3. Source
#           index 0 leaves the destination alone, so a sprite is a
#           rectangle that does not look like one -- the whole trick, and
#           the reason the planes are indexed rather than RGBA
#   op      the scanner bar, XORed with what is under it, so it inverts the
#           landscape rather than covering it and un-inverts on the way out
#
# The one place the host appears is the last step: `present_planes` copies
# the front plane device-to-host and uploads it to the D3D11 texture,
# because nvptxrt has no CUDA/D3D11 interop yet. 230,400 bytes a frame.
#
# Before the window opens, `_verify` runs one deterministic frame of exactly
# those four blits, reads the plane back, and checks the bytes against the
# same art functions that produced the source. That is the check the first
# attempt at this layer did not have, and without it "it drew something" was
# all anybody could say. Blits are addressed by number and clipped on the
# host, so an off-by-one in the stride is invisible to the eye and obvious
# to a comparison.
#
# Headless: GAMEPANE_FRAMES=n renders n frames and exits.
# ===----------------------------------------------------------------------=== #

from std.math import sin, sqrt
from gamepane import (
    CANVAS_H,
    CANVAS_W,
    GamePane,
    GpuCanvas,
    KEY_ESCAPE,
    OP_XOR,
    Planes,
    key_held,
)
from gamepane.device import host_ptr
from max.gpu.host import DeviceContext, HostBuffer

comptime LAND = 2
comptime SPRITES = 3
comptime BAR = 4

comptime LAND_W = 1280
comptime LAND_H = 240
comptime LAND_Y = CANVAS_H - LAND_H
"""The landscape sits on the bottom; the fill shows above it."""

comptime SPR = 32
comptime SPR_FRAMES = 8
comptime SWARM = 48

comptime BAR_W = 64
comptime BAR_H = 16

comptime SKY = UInt8(20)
"""The fill index. Above 15, so it resolves through the GLOBAL palette --
0..15 are the per-scanline palette's and this demo does not use those."""


# ── the art, as functions ───────────────────────────────────────────────
# Every source plane is generated from one of these, and `_verify` calls the
# same function to say what a blitted pixel should have become. A check that
# compared the GPU against a second copy of the pixels would only prove the
# upload; comparing against the generator proves the whole path.


fn _land_px(x: Int, y: Int) -> UInt8:
    """Rolling hills: a banded sky down to the horizon, dithered ground
    below it."""
    var h = Int(
        110.0 + 40.0 * sin(Float32(x) * 0.010) + 20.0 * sin(Float32(x) * 0.037)
    )
    if y < h:
        return UInt8(32 + (y * 12) // LAND_H)
    return UInt8(56 + ((x + y) & 15))


fn _spr_px(frame: Int, x: Int, y: Int) -> UInt8:
    """A shaded disc. The corners are index 0 and therefore transparent,
    which is what makes the keyed blit worth having."""
    var dx = Float32(x) - 15.5
    var dy = Float32(y) - 15.5
    var d = sqrt(dx * dx + dy * dy)
    if d > 14.0:
        return 0
    return UInt8(96 + ((Int(d) + frame * 3) % 32))


fn _bar_px(x: Int, y: Int) -> UInt8:
    """The XOR mask. Low bits only, so inverting the landscape shifts its
    colour without leaving the palette's populated range."""
    return UInt8((x + y * 3) & 15)


def _land() -> List[UInt8]:
    var px = List[UInt8](length=LAND_W * LAND_H, fill=0)
    for y in range(LAND_H):
        for x in range(LAND_W):
            px[y * LAND_W + x] = _land_px(x, y)
    return px^


def _sprite_strip() -> List[UInt8]:
    var w = SPR * SPR_FRAMES
    var px = List[UInt8](length=w * SPR, fill=0)
    for f in range(SPR_FRAMES):
        for y in range(SPR):
            for x in range(SPR):
                px[y * w + f * SPR + x] = _spr_px(f, x, y)
    return px^


def _bar() -> List[UInt8]:
    var px = List[UInt8](length=BAR_W * BAR_H, fill=0)
    for y in range(BAR_H):
        for x in range(BAR_W):
            px[y * BAR_W + x] = _bar_px(x, y)
    return px^


# ── the frame ───────────────────────────────────────────────────────────


def _compose(
    mut planes: Planes,
    scroll: Int,
    mut sx: List[Int],
    mut sy: List[Int],
    mut sf: List[Int],
    count: Int,
    bar_x: Int,
    bar_y: Int,
) raises:
    """One frame of blits into the back plane. The whole of a frame's
    drawing, and none of it touches host memory."""
    var back = planes.back()

    planes.fill(back, 0, 0, CANVAS_W, CANVAS_H, SKY)

    # The landscape, wrapped. `copy` clips, so the second call is a no-op
    # until the window actually straddles the seam.
    var run = LAND_W - scroll
    if run > CANVAS_W:
        run = CANVAS_W
    planes.copy(LAND, back, scroll, 0, 0, LAND_Y, run, LAND_H)
    if run < CANVAS_W:
        planes.copy(LAND, back, 0, 0, run, LAND_Y, CANVAS_W - run, LAND_H)

    for i in range(count):
        planes.keyed(
            SPRITES, back, sf[i] * SPR, 0, sx[i], sy[i], SPR, SPR
        )

    planes.op(BAR, back, 0, 0, bar_x, bar_y, BAR_W, BAR_H, OP_XOR)


# ── the check ───────────────────────────────────────────────────────────


def _sample(
    p: Pointer[UInt8, MutUntrackedOrigin],
    what: String,
    x: Int,
    y: Int,
    expect: UInt8,
) -> Int:
    """Compare one pixel and say so. Returns 1 if it is wrong."""
    var have = p[unsafe_offset = y * CANVAS_W + x]
    if have != expect:
        print(
            "  FAIL", what, "at", x, y,
            "- expected", Int(expect), "got", Int(have),
        )
        return 1
    print("  ok  ", what, "=", Int(have))
    return 0


def _verify(mut planes: Planes, ctx: DeviceContext) raises -> Bool:
    """One deterministic frame, read back and compared byte for byte.

    Seven samples, chosen where a plausible bug would change the answer
    rather than where any bug would:
      * the fill, above the landscape
      * the landscape, at pixels whose value depends on both x and y, so a
        stride mistake moves them
      * a sprite's centre AND a sprite's corner, the second still showing
        what was underneath -- that pair is the keying
      * the XOR bar, over the landscape, so the result depends on what was
        already in the plane
    """
    var tx = 100
    var ty = 40
    var bx = 300
    var by = 200

    var one_x = List[Int](length=1, fill=tx)
    var one_y = List[Int](length=1, fill=ty)
    var one_f = List[Int](length=1, fill=0)
    _compose(planes, 0, one_x, one_y, one_f, 1, bx, by)
    planes.swap()
    planes.finish()

    var got = ctx.enqueue_create_host_buffer[DType.uint8](CANVAS_W * CANVAS_H)
    ctx.synchronize()
    planes.read_front(got)
    planes.finish()
    var p = host_ptr(got)

    var bad = 0
    # fill: a row above the landscape and clear of the sprite.
    bad += _sample(p, String("fill"), 500, 20, SKY)
    # copy: the landscape is blitted from (0,0) to (0, LAND_Y).
    bad += _sample(p, String("copy mid"), 200, LAND_Y + 90, _land_px(200, 90))
    bad += _sample(p, String("copy edge"), 617, LAND_Y + 7, _land_px(617, 7))
    # keyed: the disc's centre lands, its corner does not.
    bad += _sample(
        p, String("keyed centre"), tx + 16, ty + 16, _spr_px(0, 16, 16)
    )
    bad += _sample(p, String("keyed corner"), tx, ty, SKY)
    # op: XOR against what the copy left there.
    bad += _sample(
        p, String("xor"), bx + 10, by + 5,
        _land_px(bx + 10, by + 5 - LAND_Y) ^ _bar_px(10, 5),
    )
    # And the seam: at scroll 0 there is none, so the right-hand edge is
    # still the landscape's own column 639 rather than a wrapped one.
    bad += _sample(
        p, String("no seam"), 639, LAND_Y + 100, _land_px(639, 100)
    )

    # Put the bank back the way an untouched one looks.
    planes.swap()
    return bad == 0


def main() raises:
    var pane = GamePane(String("Game pane - the blitter bank"), 1280, 720)
    var canvas = GpuCanvas(pane.ctx, pane.device, pane.context)
    var planes = Planes(pane.ctx, CANVAS_W, CANVAS_H)

    # ---- level load: the only host-to-device traffic there is ------------
    planes.load(LAND, LAND_W, LAND_H, _land())
    planes.load(SPRITES, SPR * SPR_FRAMES, SPR, _sprite_strip())
    planes.load(BAR, BAR_W, BAR_H, _bar())

    # ---- the palette ----------------------------------------------------
    # 32..43 sky bands, 56..71 ground, 96..127 the sprite ramp, and a
    # generic ramp everywhere else so an XOR result always has a colour.
    for i in range(256):
        canvas.set_rgb(i, (i * 5) & 255, (i * 3) & 255, (i * 7) & 255)
    canvas.set_rgb(Int(SKY), 24, 28, 48)
    for i in range(12):
        canvas.set_rgb(32 + i, 40 + i * 6, 60 + i * 8, 130 + i * 10)
    for i in range(16):
        canvas.set_rgb(56 + i, 30 + i * 4, 70 + i * 5, 30 + i * 3)
    for i in range(32):
        var s = Float32(31 - i) / 31.0
        canvas.set_rgb(
            96 + i,
            Int(60.0 + 195.0 * s),
            Int(40.0 + 150.0 * s),
            Int(90.0 + 120.0 * s),
        )

    print("verifying the blits before anything is shown:")
    var clean = _verify(planes, pane.ctx)
    if not clean:
        raise Error("blit verification failed; not showing a wrong picture")
    print("  all seven samples correct")

    # ---- the swarm ------------------------------------------------------
    var sx = List[Int](length=SWARM, fill=0)
    var sy = List[Int](length=SWARM, fill=0)
    var sf = List[Int](length=SWARM, fill=0)
    var vx = List[Float32](length=SWARM, fill=0.0)
    var vy = List[Float32](length=SWARM, fill=0.0)
    var fx = List[Float32](length=SWARM, fill=0.0)
    var fy = List[Float32](length=SWARM, fill=0.0)

    var seed: Int = 0x1234567
    for i in range(SWARM):
        seed = (seed ^ (seed << 13)) & 0xFFFFFFFF
        seed = seed ^ (seed >> 17)
        seed = (seed ^ (seed << 5)) & 0xFFFFFFFF
        fx[i] = Float32(seed % (CANVAS_W - SPR))
        fy[i] = Float32((seed // 977) % (CANVAS_H - SPR))
        vx[i] = Float32((seed % 9) - 4) * 0.55
        vy[i] = Float32(((seed // 31) % 7) - 3) * 0.45

    var scroll = 0
    var frames = 0
    while pane.pump():
        if key_held(KEY_ESCAPE):
            break

        for i in range(SWARM):
            fx[i] += vx[i]
            fy[i] += vy[i]
            if fx[i] < 0.0 or fx[i] > Float32(CANVAS_W - SPR):
                vx[i] = -vx[i]
                fx[i] += vx[i]
            if fy[i] < 0.0 or fy[i] > Float32(CANVAS_H - SPR):
                vy[i] = -vy[i]
                fy[i] += vy[i]
            sx[i] = Int(fx[i])
            sy[i] = Int(fy[i])
            sf[i] = ((frames // 4) + i) % SPR_FRAMES

        scroll = (scroll + 2) % LAND_W
        var bar_y = LAND_Y + 20 + Int(60.0 * sin(Float32(frames) * 0.03))
        var bar_x = (frames * 3) % (CANVAS_W - BAR_W)

        _compose(planes, scroll, sx, sy, sf, SWARM, bar_x, bar_y)
        planes.swap()

        var frame = pane.begin_frame()
        canvas.present_planes(planes, pane.rtv, pane.width, pane.height)
        pane.end_frame(frame)
        frames += 1

    pane.close()
    print(
        "gamepane-blit:", frames, "frames,", SWARM + 3,
        "blits a frame, none of them through host memory",
    )
