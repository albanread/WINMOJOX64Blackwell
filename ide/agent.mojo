"""The agent surface: one dispatcher, text in, text out.

Griddle is drivable from outside from its second sprint, before it can edit
a character, because that is what makes every later sprint checkable with
nobody at the keyboard. The Mac team's IDE gained this late and their own
notes say it is what made the back half cheap; we start with it.

The shape is theirs, translated. One function turns a line of text into a
line of text, and everything a menu or a button will eventually do arrives
here as a verb. So an agent run exercises the same code a person does, and
a verb that breaks under a script breaks under the pointer too.

Windows makes the transport simpler than the Mac's: no permission wall
exists, so `WM_COPYDATA` -- a message whose whole purpose is handing bytes
to another process -- needs no registration and no grant. What it does not
give is a way to hand bytes back: the reply would need the sender to own a
window and pump messages, which a shell script or a CI step should not have
to do. So a request names a file for its answer, and because `SendMessage`
is synchronous the answer is on disk by the time the call returns. No
polling, no race, no window required of the caller.
"""


from ide.chrome import D2D_RECT_F, Layout
from ide.menu import invoke as invoke_menu
from ide.screenshot import capture
from ide.win32 import RECT, win32


from std.ffi import c_int
from std.memory import Pointer


comptime GRIDDLE_VERSION = StaticString("0.1.0")


def _region(name: StaticString, r: D2D_RECT_F) -> String:
    """One region as a line of text, for the `views` reply."""
    return (
        String(name)
        + " "
        + String(Int(r.left))
        + ","
        + String(Int(r.top))
        + " "
        + String(Int(r.right - r.left))
        + "x"
        + String(Int(r.bottom - r.top))
        + "\n"
    )


def agent_command(hwnd: Int, text: StringSlice) raises -> String:
    """Answer one command.

    Every verb the IDE grows is added here, and menus and buttons are wired
    to the same functions, so this stays the one description of what Griddle
    can be asked to do.

    Args:
        hwnd: The window the command arrived at, so `status` can report it.
        text: The command line: a verb, then its arguments.

    Returns:
        The reply, as text. Errors are replies too -- a caller reads one
        stream, not two.
    """
    # strip() answers a span; make it a String so the pieces below are
    # values with their own storage rather than views into a temporary.
    var trimmed = String(String(text).strip())
    if trimmed.byte_length() == 0:
        return String("error: empty command")

    # The verb is the first word; the rest is its argument, unsplit, because
    # a path may contain spaces and re-joining is how that gets broken.
    var verb = trimmed
    var rest = String("")
    var space = trimmed.find(" ")
    if space >= 0:
        verb = String(trimmed[byte=:space])
        rest = String(String(trimmed[byte=space + 1 :]).strip())

    if verb == "status":
        return (
            String("griddle ")
            + String(GRIDDLE_VERSION)
            + " hwnd="
            + String(hwnd)
            + " state=idle"
        )

    if verb == "help":
        # Listed rather than described: the surface IS the command language,
        # so `help` is its documentation and has to stay complete.
        return String(
            "status            what Griddle is and which window it is\n"
            "help              this list\n"
            "echo <text>       answer with <text>, for round-trip checks\n"
            "screenshot [path] photograph this window to a PNG\n"
            "views             where every region of the chrome sits\n"
            "menu T > I        invoke a menu item by its visible name"
        )

    if verb == "echo":
        return rest

    if verb == "views":
        # Where every region actually is, asked of the running window rather
        # than recomputed here -- a check that reads this is checking the
        # layout, not a copy of it.
        var GetClientRect = win32[
            def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
            "GetClientRect",
        ]()
        var rc = RECT()
        _ = GetClientRect(
            hwnd, Pointer(to=rc).unsafe_origin_cast[MutAnyOrigin]()
        )
        var w = Int(rc.right - rc.left)
        var h = Int(rc.bottom - rc.top)
        var l = Layout(w, h)
        var out = String("client ") + String(w) + "x" + String(h) + "\n"
        out += _region("rail", l.rail())
        out += _region("sidebar", l.sidebar())
        out += _region("editor", l.editor())
        out += _region("issues", l.issues())
        out += _region("output", l.output())
        out += _region("status", l.status())
        return out

    if verb == "menu":
        return invoke_menu(hwnd, rest)

    if verb == "screenshot":
        # The window photographs itself: no screen capture, so nothing to
        # ask permission for, and it works while covered.
        var where = rest
        if where.byte_length() == 0:
            where = String("griddle.png")
        var size = capture(hwnd, where)
        return String("wrote ") + where + " (" + String(size) + " bytes)"

    return String("error: unknown verb '") + verb + "' (try 'help')"
