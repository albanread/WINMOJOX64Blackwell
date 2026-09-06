# ===----------------------------------------------------------------------=== #
# Layer 0 on screen: twelve cosmic backdrops, and the stack that sits on them.
#
# This is the game pane's bottom layer and the last one it was missing. The
# shaders are RASM's own, from projects/galaxigans/galaxigans_starfield.was --
# the same twelve the assembler Galaxigans flies through, already HLSL, so
# nothing was translated and nothing was invented.
#
# The demo cycles a scene every three seconds and draws the FULL STACK over
# it, in the order a game composites:
#
#   0  the cosmos, opaque, and therefore also the frame's clear
#   1  the indexed canvas -- a scanning beam drawn ONCE into palette index 1
#      and animated by rewriting what index 1 means on each scanline. That is
#      the copper-bar trick, and it is exactly the mechanism Galaxigans'
#      capture boss uses for its tractor beam, so this demo is also a rehearsal
#      for that.
#   3  text, naming the scene
#
# What a wrong picture would tell you:
#   * a BLACK window means the cosmos pass did not run -- nothing else clears.
#   * a backdrop with no canvas over it means the canvas is drawing opaque
#     black where it should be transparent; index 0 must stay untouched.
#   * a beam that is a flat colour rather than a gradient means the per-line
#     palette is not being uploaded, and the tractor beam will not work either.
#   * text but no backdrop means the draw order is inverted.
#
# Headless: GAMEPANE_FRAMES=n renders n frames and exits.
# ===----------------------------------------------------------------------=== #

from std.math import sin
from gamepane import (
    CANVAS_H,
    CANVAS_W,
    Cosmos,
    GamePane,
    GpuCanvas,
    KEY_ESCAPE,
    KEY_LEFT,
    KEY_RIGHT,
    SCENE_COUNT,
    Text,
    key_hit,
    key_held,
    scene_name,
)
from gamepane.device import set_viewport

comptime IX_BEAM = 1
"""The beam's index. Under 16, so it resolves through the PER-SCANLINE
palette -- which is the whole point: the pixels never change, only what the
index means on each row."""

comptime SCENE_SECONDS = 3.0


def main() raises:
    var pane = GamePane(String("Game pane - the cosmos"), 1280, 720)
    var cosmos = Cosmos(pane.device, pane.context)
    var canvas = GpuCanvas(pane.ctx, pane.device, pane.context)
    # Layer 1, not layer 0: do not clear, and let index 0 through.
    canvas.set_overlay(True)
    var text = Text(pane.device, pane.context)

    # ---- the canvas: draw the beam ONCE, here, and never again ----------
    # A vertical band down the middle of the field. Every pixel of it is
    # index 1; nothing in the frame loop touches these bytes.
    canvas.cls(0)
    for y in range(CANVAS_H):
        var half = 14 + Int(10.0 * sin(Float32(y) * 0.02))
        for x in range(320 - half, 320 + half):
            canvas.pset(x, y, IX_BEAM)

    var frames = 0
    var scene = 0
    var t = 0.0
    while pane.pump():
        if key_held(KEY_ESCAPE):
            break
        if key_hit(KEY_RIGHT):
            scene = (scene + 1) % SCENE_COUNT
            t = 0.0
        if key_hit(KEY_LEFT):
            scene = (scene + SCENE_COUNT - 1) % SCENE_COUNT
            t = 0.0

        # A fixed step, so a headless run of n frames is the same picture
        # every time and a screenshot can be compared with the last one.
        t += 1.0 / 30.0
        if t >= SCENE_SECONDS:
            t = 0.0
            scene = (scene + 1) % SCENE_COUNT

        cosmos.set_scene(scene)
        cosmos.advance(1.0 / 30.0)

        # The copper bar: the beam's PIXELS are already there and untouched.
        # All that moves is the meaning of index 1, one row at a time.
        for y in range(CANVAS_H):
            var phase = Float32(y) * 0.05 - Float32(frames) * 0.12
            var s = 0.5 + 0.5 * sin(phase)
            canvas.set_line_rgb(
                y, IX_BEAM,
                Int(60.0 + 195.0 * s),
                Int(40.0 + 120.0 * (1.0 - s)),
                Int(120.0 + 135.0 * s),
            )

        text.clear()
        text.set_colour(255, 255, 255)
        _ = text.draw(
            8, 8, String("LAYER 0 - ") + scene_name(scene)
        )
        text.set_colour(150, 170, 210)
        _ = text.draw(
            8, 340,
            String("LEFT/RIGHT CHANGE SCENE - THE BEAM IS ONE PALETTE ROW"),
        )

        var frame = pane.begin_frame()
        # 0: the cosmos. Opaque, drawn first, and therefore the clear.
        cosmos.render(pane.rtv, pane.width, pane.height)
        # 1: the indexed canvas, over it.
        canvas.present(pane.rtv, pane.width, pane.height)
        # 3: the HUD.
        set_viewport(pane.context, pane.width, pane.height)
        text.render(pane.rtv)
        pane.end_frame(frame)

        frames += 1

    pane.close()
    print(
        "gamepane-cosmos:", frames, "frames,", SCENE_COUNT,
        "procedural backdrops, no geometry at all",
    )
