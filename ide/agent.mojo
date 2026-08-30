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
from ide.chrome import Chrome
from ide.drop import last as last_drop, simulate
from ide.gridview import (
    GUTTER_W,
    all_text,
    caret_click,
    caret_move,
    caret_report,
    counters,
    edit_key,
    goto,
    hittest_report,
    line_text,
    move_key,
    selection_report,
    state_report,
    type_text,
    page_lines,
    presents_immediately,
    reset_counters,
    scroll_by,
    scroll_to,
)
from ide.menu import invoke as invoke_menu
from ide.screenshot import capture
from ide.win32 import RECT, private_bytes, win32


from std.ffi import c_int
from std.time import perf_counter_ns
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
            "menu T > I        invoke a menu item by its visible name\n"
            "drops             the paths from the most recent drop\n"
            "drop-test         drive the drop target through its own vtable\n"
            "paint             force one frame, synchronously\n"
            "frame [N]         time N scroll-and-paint frames\n"
            "grid [reset]      the layout cache counters\n"
            "scroll N | to N | top | end | page    move the editor\n"
            "caret [L C]       report or move the caret\n"
            "click X Y         put the caret where a click landed\n"
            "hittest L         every caret stop on line L, round-tripped\n"
            "type <text>       insert text; \\n and \\t are a newline and a tab\n"
            "enter             split the line at the caret\n"
            "backspace         delete backwards, or the selection\n"
            "delete            delete forwards, or the selection\n"
            "move D [select]   left|right|up|down|home|end|all\n"
            "undo | redo       step through the history\n"
            "sel               what is selected\n"
            "state             dirty flag, history depth, size\n"
            "text [L]          one line, or the whole document\n"
            "goto L[:C]        put the caret there, one-based\n"
            "mem               what this process is holding\n"
            "repeat N <cmd>    run one command N times"
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
        # Where the text itself starts, which is the editor's left edge plus
        # the gutter. Reported rather than left for a caller to know, because
        # a check that hardcodes the gutter width is a check that passes after
        # someone changes it.
        out += "gutter " + String(GUTTER_W) + "\n"
        out += "text " + String(Int(l.editor().left) + GUTTER_W) + "\n"
        out += "lineheight 16\n"
        return out

    if verb == "paint":
        # Synchronous: InvalidateRect only marks the window, and a caller
        # that then reads a counter would be reading the frame before the
        # one it asked for. UpdateWindow sends WM_PAINT straight through.
        var InvalidateRect = win32[
            def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
        ]()
        var UpdateWindow = win32[
            def (Int) thin abi("C") -> c_int, "UpdateWindow"
        ]()
        _ = InvalidateRect(hwnd, 0, c_int(0))
        _ = UpdateWindow(hwnd)
        return String("painted")

    if verb == "frame":
        # What a frame actually costs. Every paint scrolls by one line first,
        # because painting the same view repeatedly measures a warm cache and
        # nothing else -- the honest number is the one an editor pays while
        # somebody is holding a scroll key down.
        var runs = 60
        if rest.byte_length() > 0:
            runs = Int(rest)
        var InvalidateRect = win32[
            def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
        ]()
        var UpdateWindow = win32[
            def (Int) thin abi("C") -> c_int, "UpdateWindow"
        ]()
        reset_counters(hwnd)
        var start = perf_counter_ns()
        var worst = 0
        var dropped = 0
        for _ in range(runs):
            var t0 = perf_counter_ns()
            _ = scroll_by(hwnd, 1)
            _ = InvalidateRect(hwnd, 0, c_int(0))
            _ = UpdateWindow(hwnd)
            var took = perf_counter_ns() - t0
            if took > worst:
                worst = took
            # A render target presents on the vertical blank, so a frame that
            # made its budget takes one refresh and a frame that did not takes
            # two. Anything past 1.5 refreshes is a frame the display showed
            # twice -- which is what a person sees as a stutter.
            if took > 25_000_000:
                dropped += 1
        var each = Float64(perf_counter_ns() - start) / 1_000_000.0 / Float64(
            runs
        )
        var high = Float64(worst) / 1_000_000.0
        # Two different measurements, and saying which one this is matters.
        # Presenting on the vertical blank pins the mean to the refresh
        # interval whatever the drawing cost, so the honest claim there is the
        # dropped count: every frame arrived on the refresh it was due. With
        # --no-vsync the mean is the drawing cost, and the budget ratio means
        # something.
        if presents_immediately(hwnd):
            return (
                String(runs) + " frames, " + String(each)
                + " ms mean, worst " + String(high)
                + " ms  (vsync off: " + String(16.6667 / each)
                + "x the 60Hz budget)\n" + counters(hwnd)
            )
        return (
            String(runs) + " frames, " + String(each)
            + " ms mean (pinned to the vertical blank), worst " + String(high)
            + " ms, " + String(dropped) + " dropped\n" + counters(hwnd)
        )

    if verb == "caret":
        # No argument reports; `L C` moves. One verb rather than two because
        # every check that moves the caret then wants to see where it went,
        # and moving already answers with the report.
        if rest.byte_length() == 0:
            return caret_report(hwnd)
        var parts = rest.split(" ")
        if len(parts) != 2:
            return String("usage: caret [<line> <col>]")
        return caret_move(
            hwnd, Int(String(parts[0])), Int(String(parts[1]))
        )

    if verb == "click":
        # Client coordinates, the way Windows delivers them, so a check can
        # use the numbers `views` reported without adjusting them.
        var parts = rest.split(" ")
        if len(parts) != 2:
            return String("usage: click <x> <y>")
        return caret_click(
            hwnd, Int(String(parts[0])), Int(String(parts[1]))
        )

    if verb == "hittest":
        # Every caret stop on one line, with where a click in the middle of
        # the following glyph comes back as. This is sprint 1.3's acceptance
        # in one answer.
        if rest.byte_length() == 0:
            return String("usage: hittest <line>")
        return hittest_report(hwnd, Int(rest))

    if verb == "repeat":
        # `repeat 1000 type a`. A driver convenience, in the same spirit as
        # `frame N`: a thousand separate edits is the only way to measure what
        # a thousand-deep history costs, and a thousand `;;`-joined commands
        # is longer than a Windows command line.
        #
        # Not recursive. `repeat` inside `repeat` is a way to ask for a very
        # long afternoon by accident.
        var space2 = rest.find(" ")
        if space2 < 0:
            return String("usage: repeat <n> <command>")
        var times = Int(String(rest[byte=:space2]))
        var inner = String(String(rest[byte=space2 + 1 :]).strip())
        if inner.startswith("repeat"):
            return String("error: repeat cannot repeat itself")
        if times < 0 or times > 100000:
            return String("error: repeat count out of range")
        var last = String("")
        for _ in range(times):
            last = agent_command(hwnd, inner)
        return String("repeated ") + String(times) + " times; last: " + last

    if verb == "type":
        # Typing, with a backslash-n for a newline so a multi-line edit is one
        # command. The check suite leans on this: an editor that can only be
        # driven one character per process launch is not really drivable.
        var typed = String("")
        var i = 0
        var raw = rest.as_bytes()
        while i < len(raw):
            if raw[i] == UInt8(ord("\\")) and i + 1 < len(raw):
                var next = raw[i + 1]
                if next == UInt8(ord("n")):
                    typed += "\n"
                    i += 2
                    continue
                if next == UInt8(ord("t")):
                    typed += "\t"
                    i += 2
                    continue
                if next == UInt8(ord("\\")):
                    typed += "\\"
                    i += 2
                    continue
            typed += chr(Int(raw[i]))
            i += 1
        return type_text(hwnd, typed)

    if verb == "goto":
        # `goto 400` or `goto 400:12`. One-based on the way in, because that
        # is what the status bar shows and what a compiler diagnostic says,
        # and zero-based everywhere inside.
        if rest.byte_length() == 0:
            return String("usage: goto <line>[:<col>]")
        var colon = rest.find(":")
        var want_line = rest if colon < 0 else String(rest[byte=:colon])
        var want_col = String("1") if colon < 0 else String(
            rest[byte=colon + 1 :]
        )
        return goto(hwnd, Int(want_line) - 1, Int(want_col) - 1)

    if verb == "undo" or verb == "redo" or verb == "backspace" or (
        verb == "delete" or verb == "enter"
    ):
        return edit_key(hwnd, verb)

    if verb == "move":
        # `move left`, `move right select`, `move all`. One verb rather than
        # six because every one of them does the same three things afterwards.
        var parts = rest.split(" ")
        if len(parts) == 0 or rest.byte_length() == 0:
            return String(
                "usage: move left|right|up|down|home|end|all [select]"
            )
        var extend = len(parts) > 1 and String(parts[1]) == "select"
        return move_key(hwnd, String(parts[0]), extend)

    if verb == "sel":
        return selection_report(hwnd)

    if verb == "state":
        return state_report(hwnd)

    if verb == "text":
        if rest.byte_length() == 0:
            return all_text(hwnd)
        return line_text(hwnd, Int(rest) - 1)

    if verb == "mem":
        # What the process is actually holding. The undo depth claim is a
        # memory claim, and a memory claim wants a number from the operating
        # system rather than a calculation from the thing being measured.
        var bytes = private_bytes()
        return (
            String("committed ") + String(bytes) + " bytes ("
            + String(bytes // 1024) + " KB)"
        )

    if verb == "grid":
        # The counters, and a way to zero them. Measuring a scroll means
        # reading them, scrolling, and reading them again -- so the reset has
        # to be reachable, or the second number is always the sum of both.
        if rest == "reset":
            reset_counters(hwnd)
            return String("counters zeroed;  ") + counters(hwnd)
        return counters(hwnd)

    if verb == "scroll":
        # Absolute or relative, and the answer is where it actually landed --
        # which is how the clamp at either end can be seen rather than
        # assumed.
        var landed = 0
        if rest == "top":
            landed = scroll_to(hwnd, 0)
        elif rest == "end":
            landed = scroll_to(hwnd, 1 << 40)
        elif rest == "page":
            landed = scroll_by(hwnd, page_lines(hwnd))
        elif rest.startswith("to "):
            landed = scroll_to(hwnd, Int(String(rest[byte=3:]).strip()))
        elif rest.byte_length() > 0:
            landed = scroll_by(hwnd, Int(rest))
        else:
            return String("usage: scroll N | to N | top | end | page")
        return String("top line is now ") + String(landed)

    if verb == "drops":
        # What was dropped most recently. The callbacks are reached through a
        # C-ABI vtable and cannot answer up the stack, so they leave the
        # paths somewhere both the status line and this verb can read.
        var dropped = last_drop()
        if dropped.byte_length() == 0:
            return String("nothing dropped yet")
        return dropped

    if verb == "drop-test":
        # Drive our own drop target the way OLE's proxy does on a real drag:
        # straight through its vtable at the metadata's slots. It proves the
        # object is live and callable and that its callbacks run; the paths
        # a real drag carries come from Explorer, which is the manual half.
        var GetWindowLongPtrW = win32[
            def (Int, c_int) thin abi("C") -> Int, "GetWindowLongPtrW"
        ]()
        var stored = GetWindowLongPtrW(hwnd, c_int(-21))  # GWLP_USERDATA
        if stored == 0:
            return String("error: this window has no state")
        var chrome = Pointer[Chrome, MutAnyOrigin](unsafe_from_address=stored)
        return simulate(chrome[].drop_target)

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
