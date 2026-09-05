"""Input, as a game sees it: polled state, not an event queue.

The codes are macOS virtual key codes because that is what the one backend
reports, and inventing a private enumeration would mean a translation table
in every backend for no gain -- a second platform maps its own codes to
these. `IndexedPane.mod` and the Rust engine both use exactly these numbers.

Mouse position is NORMALISED (0..1 across the view) and measured from the
TOP, which is the pane's own convention. A window can be resized while the
world it shows keeps its fixed size, so a coordinate in points would quietly
mean a different cell after a resize; a fraction never does. The flip happens
once, at the source, rather than in every game that reads it.
"""

comptime MAX_KEY_CODE = 128

comptime KEY_LEFT = 123
comptime KEY_RIGHT = 124
comptime KEY_DOWN = 125
comptime KEY_UP = 126
comptime KEY_SPACE = 49
comptime KEY_ESCAPE = 53
# The number row, for a demo that wants a key per effect. Apple's codes are
# not in numeric order past 3, which is why these are written out.
comptime KEY_1 = 18
comptime KEY_2 = 19
comptime KEY_3 = 20
comptime KEY_4 = 21
comptime KEY_5 = 23
comptime KEY_6 = 22

comptime KEY_RETURN = 36
comptime KEY_A = 0
comptime KEY_S = 1
comptime KEY_D = 2
comptime KEY_W = 13
comptime KEY_Z = 6
comptime KEY_X = 7


@fieldwise_init
struct MouseState(Copyable, Movable):
    """Where the mouse is and what is held, as of the last event."""

    var x: Float64
    """0..1 across the view, left to right."""
    var y: Float64
    """0..1 down the view, TOP to bottom."""
    var left: Bool
    var right: Bool


@fieldwise_init
struct GamepadState(Copyable, Movable):
    """The first connected extended gamepad, or all-clear when there is none.
    """

    var connected: Bool
    var button_a: Bool
    var button_b: Bool
    var stick_x: Float64
    """-1..1, left to right."""
    var stick_y: Float64
    """-1..1, down to up (the controller's own sign)."""
