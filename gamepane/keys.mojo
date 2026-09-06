# ===----------------------------------------------------------------------=== #
# Keys, in the only code space this platform actually has.
#
# This file used to hold macOS virtual key codes -- KEY_ESCAPE = 53 -- because
# the pane was ported from a Metal backend and the Windows pump translated
# every WM_KEYDOWN into a Mac code on the way in. That was legacy twice over:
# it made a Windows game's key constants magic numbers, and it made the pane
# the only place in this repository that did not ask the winkb metadata
# database for a Win32 constant. The reference (RASM's gpu/input.was) never
# had the problem, because it never had a Mac to be ported from.
#
# So the code space is now the Windows virtual key code, 0..255, and every
# constant below is a metadata lookup rather than a literal. `winkb_constant`
# fails the BUILD on a name it does not know, which is the property that makes
# a table this size worth having at all -- a typo is a compile error at the
# line, not a key that silently never responds.
#
# TWO TIERS, and the upper one is the portable answer:
#
#   RAW      key_down(KEY_A) / key_hit(KEY_A) -- a specific key, held or
#            pressed-this-frame. Fine for an editor, wrong for a game,
#            because it hardcodes one keyboard's opinion of "fire".
#
#   ACTIONS  action(ACT_FIRE) / action_hit(ACT_FIRE) -- eight device-
#            independent verbs, each mapped from TWO keys, so the arrows and
#            WASD are the same control and neither is privileged. This is the
#            tier a game should use and the tier that survives a port.
#
# The mapping is the reference's, key for key (gpu/input.was:139-219):
#
#     LEFT     VK_LEFT   or A          FIRE     VK_SPACE or VK_CONTROL
#     RIGHT    VK_RIGHT  or D          PAUSE    P
#     UP       VK_UP     or W          RESTART  R
#     DOWN     VK_DOWN   or S          QUIT     VK_ESCAPE
#
# The one thing deliberately NOT ported is the joystick half: the reference
# ORs each action with a joyGetPosEx axis or button. joyGetPosEx is winmm's
# legacy MMSYSTEM API and this tree has no winmm binding; XInput is the right
# answer here and is a separate piece of work. `sim_action` is ported, so an
# automated run can drive a game without any device at all -- which is what
# the joystick path was mostly being used for.
# ===----------------------------------------------------------------------=== #

from std.sys._winkb import winkb_constant

comptime KEY_COUNT = 256
"""The whole virtual key space. The reference's KEY_COUNT, and not a
coincidence: Windows delivers wParam in 0..255 for WM_KEYDOWN, so a table
this size cannot be overrun and needs no translation to be complete.

The previous design allocated 128 and indexed it by Mac code. Under VK
indexing 128 is not enough -- F1 is 0x70, the numeric keypad is 0x60..0x69,
the left/right modifier pairs are 0xA0..0xA5 and every OEM punctuation key is
0xBA..0xDF. All of those are above 128 and all of them would have been a
silent heap write."""

# ── the raw keys ────────────────────────────────────────────────────────
# Named for what is on the keycap, valued by the metadata. Letters and digits
# are their ASCII capitals, which is one of Win32's few kindnesses.

comptime KEY_LEFT = winkb_constant["VK_LEFT"]()
comptime KEY_RIGHT = winkb_constant["VK_RIGHT"]()
comptime KEY_UP = winkb_constant["VK_UP"]()
comptime KEY_DOWN = winkb_constant["VK_DOWN"]()

comptime KEY_ESCAPE = winkb_constant["VK_ESCAPE"]()
comptime KEY_SPACE = winkb_constant["VK_SPACE"]()
comptime KEY_RETURN = winkb_constant["VK_RETURN"]()
comptime KEY_TAB = winkb_constant["VK_TAB"]()
comptime KEY_BACK = winkb_constant["VK_BACK"]()
comptime KEY_SHIFT = winkb_constant["VK_SHIFT"]()
comptime KEY_CONTROL = winkb_constant["VK_CONTROL"]()
comptime KEY_MENU = winkb_constant["VK_MENU"]()
"""Alt. Windows calls it MENU and delivers it as WM_SYSKEYDOWN."""

comptime KEY_0 = winkb_constant["VK_0"]()
comptime KEY_1 = winkb_constant["VK_1"]()
comptime KEY_2 = winkb_constant["VK_2"]()
comptime KEY_3 = winkb_constant["VK_3"]()
comptime KEY_4 = winkb_constant["VK_4"]()
comptime KEY_5 = winkb_constant["VK_5"]()
comptime KEY_6 = winkb_constant["VK_6"]()
comptime KEY_7 = winkb_constant["VK_7"]()
comptime KEY_8 = winkb_constant["VK_8"]()
comptime KEY_9 = winkb_constant["VK_9"]()

comptime KEY_A = winkb_constant["VK_A"]()
comptime KEY_B = winkb_constant["VK_B"]()
comptime KEY_C = winkb_constant["VK_C"]()
comptime KEY_D = winkb_constant["VK_D"]()
comptime KEY_E = winkb_constant["VK_E"]()
comptime KEY_F = winkb_constant["VK_F"]()
comptime KEY_G = winkb_constant["VK_G"]()
comptime KEY_H = winkb_constant["VK_H"]()
comptime KEY_I = winkb_constant["VK_I"]()
comptime KEY_J = winkb_constant["VK_J"]()
comptime KEY_K = winkb_constant["VK_K"]()
comptime KEY_L = winkb_constant["VK_L"]()
comptime KEY_M = winkb_constant["VK_M"]()
comptime KEY_N = winkb_constant["VK_N"]()
comptime KEY_O = winkb_constant["VK_O"]()
comptime KEY_P = winkb_constant["VK_P"]()
comptime KEY_Q = winkb_constant["VK_Q"]()
comptime KEY_R = winkb_constant["VK_R"]()
comptime KEY_S = winkb_constant["VK_S"]()
comptime KEY_T = winkb_constant["VK_T"]()
comptime KEY_U = winkb_constant["VK_U"]()
comptime KEY_V = winkb_constant["VK_V"]()
comptime KEY_W = winkb_constant["VK_W"]()
comptime KEY_X = winkb_constant["VK_X"]()
comptime KEY_Y = winkb_constant["VK_Y"]()
comptime KEY_Z = winkb_constant["VK_Z"]()

comptime KEY_F1 = winkb_constant["VK_F1"]()
comptime KEY_F2 = winkb_constant["VK_F2"]()
comptime KEY_F3 = winkb_constant["VK_F3"]()
comptime KEY_F4 = winkb_constant["VK_F4"]()
comptime KEY_F5 = winkb_constant["VK_F5"]()
comptime KEY_F6 = winkb_constant["VK_F6"]()
comptime KEY_F7 = winkb_constant["VK_F7"]()
comptime KEY_F8 = winkb_constant["VK_F8"]()
comptime KEY_F9 = winkb_constant["VK_F9"]()
comptime KEY_F10 = winkb_constant["VK_F10"]()
comptime KEY_F11 = winkb_constant["VK_F11"]()
comptime KEY_F12 = winkb_constant["VK_F12"]()

# ── the actions ─────────────────────────────────────────────────────────

comptime ACT_LEFT = 0
comptime ACT_RIGHT = 1
comptime ACT_UP = 2
comptime ACT_DOWN = 3
comptime ACT_FIRE = 4
comptime ACT_PAUSE = 5
comptime ACT_RESTART = 6
comptime ACT_QUIT = 7
comptime ACT_COUNT = 8


def action_keys(act: Int) -> Tuple[Int, Int]:
    """The two keys an action listens to. The reference's defaults, and the
    only place the mapping is written down.

    Returned as a pair rather than consulted through a table because the
    caller ORs them and nothing else ever needs the pair -- and because a
    table of two-element lists would be a heap allocation on the input path,
    which runs every frame."""
    if act == ACT_LEFT:
        return (KEY_LEFT, KEY_A)
    if act == ACT_RIGHT:
        return (KEY_RIGHT, KEY_D)
    if act == ACT_UP:
        return (KEY_UP, KEY_W)
    if act == ACT_DOWN:
        return (KEY_DOWN, KEY_S)
    if act == ACT_FIRE:
        return (KEY_SPACE, KEY_CONTROL)
    if act == ACT_PAUSE:
        return (KEY_P, KEY_P)
    if act == ACT_RESTART:
        return (KEY_R, KEY_R)
    if act == ACT_QUIT:
        return (KEY_ESCAPE, KEY_ESCAPE)
    return (0, 0)


def key_name(vk: Int) -> String:
    """A short label for a virtual key, for the sweep display.

    Short on purpose: the keymap sweep draws all 256 of these in a grid and a
    cell is four characters wide. winkb can turn a NAME into a value at
    compile time but not a value into a name at run time, so this is the one
    direction the metadata cannot serve and the table is written out.

    The font has no lower case that differs from upper (see text.mojo), so
    everything here is upper case by construction rather than by choice."""
    if vk >= KEY_A and vk <= KEY_Z:
        return String(chr(vk))
    if vk >= KEY_0 and vk <= KEY_9:
        return String(chr(vk))
    if vk >= KEY_F1 and vk <= KEY_F12:
        return String("F") + String(vk - KEY_F1 + 1)
    if vk == KEY_LEFT:
        return String("LEFT")
    if vk == KEY_RIGHT:
        return String("RGHT")
    if vk == KEY_UP:
        return String("UP")
    if vk == KEY_DOWN:
        return String("DOWN")
    if vk == KEY_ESCAPE:
        return String("ESC")
    if vk == KEY_SPACE:
        return String("SPC")
    if vk == KEY_RETURN:
        return String("ENT")
    if vk == KEY_TAB:
        return String("TAB")
    if vk == KEY_BACK:
        return String("BKSP")
    if vk == KEY_SHIFT:
        return String("SHFT")
    if vk == KEY_CONTROL:
        return String("CTRL")
    if vk == KEY_MENU:
        return String("ALT")
    if vk == winkb_constant["VK_LSHIFT"]():
        return String("LSFT")
    if vk == winkb_constant["VK_RSHIFT"]():
        return String("RSFT")
    if vk == winkb_constant["VK_LCONTROL"]():
        return String("LCTL")
    if vk == winkb_constant["VK_RCONTROL"]():
        return String("RCTL")
    if vk == winkb_constant["VK_LMENU"]():
        return String("LALT")
    if vk == winkb_constant["VK_RMENU"]():
        return String("RALT")
    if vk == winkb_constant["VK_LWIN"]():
        return String("LWIN")
    if vk == winkb_constant["VK_RWIN"]():
        return String("RWIN")
    if vk == winkb_constant["VK_CAPITAL"]():
        return String("CAPS")
    if vk == winkb_constant["VK_HOME"]():
        return String("HOME")
    if vk == winkb_constant["VK_END"]():
        return String("END")
    if vk == winkb_constant["VK_PRIOR"]():
        return String("PGUP")
    if vk == winkb_constant["VK_NEXT"]():
        return String("PGDN")
    if vk == winkb_constant["VK_INSERT"]():
        return String("INS")
    if vk == winkb_constant["VK_DELETE"]():
        return String("DEL")
    if vk >= winkb_constant["VK_NUMPAD0"]() and vk <= winkb_constant[
        "VK_NUMPAD9"
    ]():
        return String("N") + String(vk - winkb_constant["VK_NUMPAD0"]())
    return String("")
