# ===----------------------------------------------------------------------=== #
# The keymap sweep, drawn by the text layer: all 256 virtual keys at once.
#
# Two things prove themselves here, and they prove each other.
#
# G5 TEXT. Every label in the window -- the title, 256 grid cells and the
# action row, around 700 glyphs in a dozen colours -- is ONE DrawInstanced.
# The colour rides in the instance rather than in a constant buffer, which is
# what makes a grid where every cell has its own colour cost the same as a
# grid where they are all white.
#
# THE SWEEP. The pane latches the WHOLE key table every frame:
# `edge = down AND NOT prev` across all 256 codes, then the eight
# device-independent actions on top. That is RASM's InputPoll and it is why
# `key_hit` works for a key nobody registered an interest in -- there is no
# subscription list to be absent from.
#
# What you should see, and what each part would look like if it were wrong:
#
#   * a full 16x16 grid. Named keys are labelled, the rest show their code in
#     hex and dim grey. If the grid is half empty, `key_name` is returning
#     nothing for keys it should know.
#   * holding a key turns its cell GREEN, and the instant of the press turns
#     it WHITE for exactly one frame. A cell that stays white has a broken
#     edge latch -- `prev` is not being carried forward.
#   * holding an arrow OR the matching WASD key lights the same action, and
#     lights it once. If the arrows work and WASD does not, the action table
#     is only reading its first key.
#   * F1..F12, the keypad and the OEM punctuation keys all respond. Those all
#     live above VK 128, which the previous 128-byte Mac-indexed table could
#     not even store.
#
# Before the window opens, `_verify` drives the action layer with no keyboard
# at all -- `sim_action` is the reference's headless hook -- and checks that
# an edge lasts exactly one sweep. That is the half a screenshot cannot show.
#
# Headless: GAMEPANE_FRAMES=n renders n frames and exits.
# ===----------------------------------------------------------------------=== #

from gamepane import (
    ACT_COUNT,
    ACT_DOWN,
    ACT_FIRE,
    ACT_LEFT,
    ACT_PAUSE,
    ACT_QUIT,
    ACT_RESTART,
    ACT_RIGHT,
    ACT_UP,
    GamePane,
    KEY_1,
    KEY_2,
    KEY_4,
    KEY_COUNT,
    Text,
    action,
    action_hit,
    input_poll,
    key_down,
    key_held,
    key_hit,
    key_name,
    letter_held,
    sim_action,
)
from gamepane.device import (
    clear_render_target,
    om_set_render_targets,
    set_viewport,
)

comptime COLS = 16
comptime ROWS = 16
comptime CELL_W = 40
comptime CELL_H = 20
comptime GRID_X = 2
comptime GRID_Y = 22
"""The grid, in the 640x360 physical canvas the text layer draws into."""


def _hex2(v: Int) -> String:
    """Two hex digits, upper case. The font has no lower case worth the
    name, and a keycode is conventionally upper anyway."""
    comptime digits = String("0123456789ABCDEF")
    return (
        String(digits[byte = (v >> 4) & 15])
        + String(digits[byte = v & 15])
    )


def _act_name(a: Int) -> String:
    if a == ACT_LEFT:
        return String("LEFT")
    if a == ACT_RIGHT:
        return String("RIGHT")
    if a == ACT_UP:
        return String("UP")
    if a == ACT_DOWN:
        return String("DOWN")
    if a == ACT_FIRE:
        return String("FIRE")
    if a == ACT_PAUSE:
        return String("PAUSE")
    if a == ACT_RESTART:
        return String("RESTART")
    return String("QUIT")


def _check(what: String, got: Bool, want: Bool) -> Int:
    """Compare one latch reading and say so. Returns 1 if it is wrong."""
    if got != want:
        print("  FAIL", what, "- expected", want, "got", got)
        return 1
    print("  ok  ", what, "=", got)
    return 0


def _verify() raises -> Bool:
    """Drive the action layer with no keyboard and check the latch.

    `sim_action` forces an action on; the sweep ORs it in exactly where a
    real key would have been, so this exercises the same code path a press
    does. The property being checked is the one that is easy to get wrong and
    invisible on screen: an edge lasts EXACTLY ONE sweep. A latch that
    forgets to copy `down` into `prev` reports a press every frame, which
    reads as a menu that scrolls away from you.
    """
    var bad = 0

    sim_action(ACT_FIRE, False)
    input_poll()
    bad += _check(String("fire is idle to start"), action(ACT_FIRE), False)

    sim_action(ACT_FIRE, True)
    input_poll()
    bad += _check(
        String("fire held after the press"), action(ACT_FIRE), True
    )
    bad += _check(
        String("fire EDGE on the press frame"), action_hit(ACT_FIRE), True
    )

    input_poll()
    bad += _check(
        String("fire still held a frame later"), action(ACT_FIRE), True
    )
    bad += _check(
        String("fire edge GONE a frame later"), action_hit(ACT_FIRE), False
    )

    sim_action(ACT_FIRE, False)
    input_poll()
    bad += _check(String("fire released"), action(ACT_FIRE), False)

    # An action nobody touched must not have been dragged along with it.
    bad += _check(String("quit unaffected"), action(ACT_QUIT), False)
    return bad == 0


def main() raises:
    var pane = GamePane(String("Game pane - keymap sweep"), 1280, 720)
    var text = Text(pane.device, pane.context)

    print("verifying the edge latch with no keyboard:")
    if not _verify():
        raise Error("input latch verification failed")
    print("  the sweep latches an edge for exactly one frame")

    var frames = 0
    while pane.pump():
        if action(ACT_QUIT):
            break

        # Window zoom, on the 1/2/4 ladder the game uses. Cheap to call
        # from a held key: set_zoom returns immediately when the factor is
        # already current.
        if key_held(KEY_1):
            pane.set_zoom(1)
        elif key_held(KEY_2):
            pane.set_zoom(2)
        elif key_held(KEY_4):
            pane.set_zoom(4)

        var frame = pane.begin_frame()
        om_set_render_targets(pane.context, pane.rtv)
        clear_render_target(pane.context, pane.rtv, 0.04, 0.04, 0.07)
        # The text layer sets no viewport, on purpose and like the reference:
        # a caller drawing into a 640x360 layer wants a different one from a
        # caller drawing onto the back buffer, and the layer cannot know
        # which. So the caller sets it -- and D3D11's default is EMPTY, so
        # forgetting this rasterises nothing at all rather than rasterising
        # somewhere unexpected.
        set_viewport(pane.context, pane.width, pane.height)
        _ = frame

        text.clear()

        text.set_colour(150, 190, 255)
        _ = text.draw(
            4, 6, String("GAMEPANE KEYMAP SWEEP - 256 KEYS LATCHED PER FRAME")
        )

        # The grid. One cell per virtual key code, in code order: row is the
        # high nibble, column the low one, so the whole table reads like the
        # hex dump it is.
        for vk in range(KEY_COUNT):
            var col = vk % COLS
            var row = vk // COLS
            var x = GRID_X + col * CELL_W
            var y = GRID_Y + row * CELL_H

            var label = key_name(vk)
            var named = label.byte_length() > 0
            if not named:
                label = _hex2(vk)

            if key_hit(vk):
                text.set_colour(255, 255, 255)
            elif key_down(vk):
                text.set_colour(80, 240, 120)
            elif named:
                text.set_colour(120, 120, 155)
            else:
                text.set_colour(48, 48, 66)
            _ = text.draw(x, y, label)

        # The action row: the portable tier, lit from whichever key or keys
        # happen to be under it.
        text.set_colour(150, 190, 255)
        var pen = text.draw(4, GRID_Y + ROWS * CELL_H + 4, String("ACTIONS"))
        pen += 12
        for a in range(ACT_COUNT):
            if action_hit(a):
                text.set_colour(255, 255, 255)
            elif action(a):
                text.set_colour(80, 240, 120)
            else:
                text.set_colour(90, 90, 120)
            pen = text.draw(pen, GRID_Y + ROWS * CELL_H + 4, _act_name(a))
            pen += 8

        # The initials-screen reader: which letter, not twenty-six questions.
        # On Windows the answer IS the key code, because VK_A..VK_Z are the
        # ASCII capitals.
        var typed = letter_held()
        text.set_colour(150, 190, 255)
        var lp = text.draw(330, 6, String("LETTER"))
        lp += 12
        if typed != 0:
            text.set_colour(255, 255, 255)
            _ = text.draw(lp, 6, String(chr(typed)))
        else:
            text.set_colour(90, 90, 120)
            _ = text.draw(lp, 6, String("-"))
        text.set_colour(90, 90, 120)
        _ = text.draw(
            lp + 24, 6,
            String("ZOOM ") + String(pane.zoom) + String("X (1 2 4)"),
        )

        text.render(pane.rtv)
        pane.end_frame(frame)
        frames += 1

    pane.close()
    print(
        "gamepane-keys:", frames,
        "frames, 256 keys swept a frame, every label in ONE DrawInstanced",
    )
