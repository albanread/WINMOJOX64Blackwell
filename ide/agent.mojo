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
)
from ide.window import (
    all_text,
    caret_click,
    caret_move,
    caret_report,
    complete_at_caret,
    counters,
    edit_key,
    goto_issue,
    issues_report,
    lsp_wait,
    popup_accept,
    popup_close,
    popup_move,
    popup_report,
    popup_wait,
    keystorm,
    latency_report,
    latency_reset,
    find_again,
    find_bench,
    find_text,
    goto,
    hittest_report,
    definition_at_caret,
    definition_wait,
    hover_at_caret,
    hover_close,
    hover_report,
    hover_wait,
    jump_back,
    goto_reference,
    build_file,
    build_wait,
    close_tab,
    next_tab,
    set_root,
    toggle,
    breakpoints_report,
    clear_breakpoints,
    debug_file,
    debug_launch,
    debug_report,
    debug_step,
    debug_stop,
    debug_wait,
    replace_every,
    replace_here,
    replace_preview,
    poll_disk,
    stamp_report,
    toggle_breakpoint,
    reload_document,
    search_in_project,
    remember_session,
    restore_session,
    session_report,
    project_root,
    tree_report,
    watch_project,
    zoom_report,
    switch_tab,
    tabs_report,
    is_dirty,
    output_report,
    run_file,
    save,
    save_as,
    stop_build,
    line_height_of,
    line_text,
    open_path,
    pane_problems,
    references_at_caret,
    references_report,
    references_wait,
    move_key,
    page_lines,
    presents_immediately,
    reset_counters,
    scroll_by,
    scroll_to,
    selection_report,
    state_report,
    type_text,
)
from ide.menu import invoke as invoke_menu
from ide.tsf import self_check as tsf_self_check
from ide.screenshot import capture
from ide.dap import debug_log, debugging, resume
from ide.session import forget_session
from ide.watch import stop_watching
from ide.win32 import (
    RECT,
    dpi_of,
    dpi_scale,
    drain,
    private_bytes,
    scaled,
    win32,
)


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
            "repeat N <cmd>    run one command N times\n"
            "tsf               drive the text store, as an IME would\n"
            "find <text>       search, and select the next match\n"
            "findnext | findprev   repeat the search, F3 and Shift+F3\n"
            "find-bench <text>     time one search of the whole document\n"
            "storm [N]         N keystrokes through the real message path\n"
            "latency [reset]   keystroke to presented frame\n"
            "issues [N]        the language server's complaints, or jump to one\n"
            "lsp wait [ms]     wait for the server to have something to say\n"
            "complete [wait|show|up|down|accept|close]   the completion popup"
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
        var l = Layout(w, h, dpi_scale(hwnd))
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
        var s = dpi_scale(hwnd)
        var gutter = Int(scaled(GUTTER_W, s))
        out += "gutter " + String(gutter) + "\n"
        out += "text " + String(Int(l.editor().left) + gutter) + "\n"
        # Measured, not remembered. Each of these used to be a number
        # written here, which made a check that read them a check on the
        # constant rather than on the editor -- and on a 150% display the
        # editor and the constant disagree by half again.
        out += "lineheight " + String(
            Int(line_height_of(hwnd))
        ) + "\n"
        out += "dpi " + String(dpi_of(hwnd)) + "\n"
        out += "scale " + String(s) + "\n"
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
        # UpdateWindow sends WM_PAINT straight to the procedure and leaves
        # everything else the window manager had for us sitting in the queue.
        # Draining it here is what stops an unattended run from being a
        # window that draws frames and answers nothing -- which Windows
        # treats as hung, and composites as a ghost. See the note on the
        # pump in ide/win32.mojo.
        _ = drain(hwnd)
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
            _ = drain(hwnd)
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

    if verb == "tsf":
        # Drive the text store through its own vtable, with a real sink
        # advised, the way an input method does. What this cannot cover is a
        # real IME choosing to make those calls, which is the manual half.
        return tsf_self_check(hwnd)

    if verb == "find":
        return find_text(hwnd, rest)

    if verb == "findnext":
        return find_again(hwnd, False)

    if verb == "findprev":
        return find_again(hwnd, True)

    if verb == "find-bench":
        # The sprint acceptance, as a number rather than a claim.
        return find_bench(hwnd, rest)

    if verb == "storm":
        # The budget run: N keystrokes through the real WM_CHAR path, each
        # followed by the frame that shows it.
        var many = 200
        if rest.byte_length() > 0:
            many = Int(rest)
        return keystorm(hwnd, many)

    if verb == "latency":
        if rest == "reset":
            latency_reset(hwnd)
            return String("latency counters zeroed")
        return latency_report(hwnd)

    if verb == "lsp":
        # `lsp wait [ms]`. The window drains the server from a timer; a check
        # has no timer, so it says when to wait and for how long.
        if rest.startswith("wait"):
            var ms = 8000
            var space2 = rest.find(" ")
            if space2 > 0:
                ms = Int(String(rest[byte=space2 + 1 :]).strip())
            return lsp_wait(hwnd, ms)
        return String("usage: lsp wait [milliseconds]")

    if verb == "complete":
        # `complete` asks; `complete show|up|down|accept|close` drives the
        # popup the way the keyboard does, so a check and a person exercise
        # one path.
        if rest == "show":
            return popup_report(hwnd)
        if rest.startswith("wait"):
            var ms = 8000
            var sp = rest.find(" ")
            if sp > 0:
                ms = Int(String(rest[byte=sp + 1 :]).strip())
            return popup_wait(hwnd, ms)
        if rest == "up":
            return popup_move(hwnd, -1)
        if rest == "down":
            return popup_move(hwnd, 1)
        if rest == "accept":
            return popup_accept(hwnd)
        if rest == "close":
            return popup_close(hwnd)
        return complete_at_caret(hwnd)

    # ---- sprint 2.5: navigation --------------------------------------
    # Three verbs with one shape, matching the three requests. Each asks and
    # returns; `wait` is what a check uses in place of the window's timer,
    # and it does the going-there as well, because a definition that arrives
    # and is not followed is not what F12 does.
    if verb == "definition" or verb == "def":
        if rest.startswith("wait"):
            var ms = 8000
            var sp = rest.find(" ")
            if sp > 0:
                ms = Int(String(rest[byte=sp + 1 :]).strip())
            return definition_wait(hwnd, ms)
        return definition_at_caret(hwnd)

    if verb == "hover":
        if rest == "show":
            return hover_report(hwnd)
        if rest == "close":
            return hover_close(hwnd)
        if rest.startswith("wait"):
            var ms = 8000
            var sp = rest.find(" ")
            if sp > 0:
                ms = Int(String(rest[byte=sp + 1 :]).strip())
            return hover_wait(hwnd, ms)
        return hover_at_caret(hwnd)

    if verb == "references" or verb == "refs":
        # `references N` goes to the nth, the way `issues N` does -- one verb
        # shape for two lists that are read the same way.
        if rest == "show":
            return references_report(hwnd)
        if rest == "close":
            return pane_problems(hwnd)
        if rest.startswith("wait"):
            var ms = 8000
            var sp = rest.find(" ")
            if sp > 0:
                ms = Int(String(rest[byte=sp + 1 :]).strip())
            return references_wait(hwnd, ms)
        if rest.byte_length() > 0:
            return goto_reference(hwnd, Int(rest))
        return references_at_caret(hwnd)

    if verb == "debug":
        # `debug` starts, `debug wait N` pumps until it stops, `debug step`
        # and its friends move, `debug stop` ends it. One verb, the same shape
        # as the others, so a check drives the debugger the way a person does.
        if rest.startswith("wait"):
            var sp = rest.find(" ")
            var ms = 60000
            if sp > 0:
                ms = Int(String(rest[byte=sp + 1 :]).strip())
            return debug_wait(hwnd, ms)
        if rest == "log":
            # What the adapter itself said. A debugger that comes up with no
            # variables has almost always failed to load something, and it
            # says so here and nowhere else.
            return debug_log()
        if rest == "launch":
            return debug_launch(hwnd)
        if rest == "stop":
            return debug_stop(hwnd)
        if rest == "over" or rest == "in" or rest == "out":
            return debug_step(hwnd, rest)
        if rest == "continue":
            if not debugging():
                return String("nothing is being debugged")
            resume()
            return String("continuing")
        if rest.byte_length() > 0:
            return String("usage: debug [launch|wait N|over|in|out|continue|stop]")
        return debug_file(hwnd)

    if verb == "replace":
        # `replace <old> -> <new>` for one, `replace all <old> -> <new>` for
        # the lot, `replace preview <old> -> <new>` to look first.
        var body = rest
        var every = False
        var preview = False
        if body.startswith("all "):
            every = True
            body = String(String(body[byte=4:]).strip())
        elif body.startswith("preview "):
            preview = True
            body = String(String(body[byte=8:]).strip())
        var arrow = body.find(" -> ")
        if arrow < 0:
            return String("usage: replace [all|preview] <old> -> <new>")
        var old_text = String(String(body[byte=0:arrow]).strip())
        var new_text = String(String(body[byte=arrow + 4 :]).strip())
        if preview:
            return replace_preview(hwnd, old_text, new_text)
        if every:
            return replace_every(hwnd, old_text, new_text)
        return replace_here(hwnd, old_text, new_text)

    if verb == "break":
        # `break` toggles at the caret, `break N` at a line, `break list` and
        # `break clear` do what they say.
        if rest == "list":
            return breakpoints_report(hwnd)
        if rest == "clear":
            return clear_breakpoints(hwnd)
        if rest.byte_length() > 0:
            return toggle_breakpoint(hwnd, Int(rest) - 1)
        return toggle_breakpoint(hwnd, -1)

    if verb == "search":
        # Results land in the output pane, written the way a compiler writes a
        # location, so clicking one jumps there through the handler that
        # already exists.
        if rest.byte_length() == 0:
            return String("usage: search <text>")
        return search_in_project(hwnd, rest)

    if verb == "watch":
        if rest == "stamp":
            # What the document thinks its file was, against what it is now.
            # The two disagreeing is the whole trigger for a reload, so being
            # able to read both is how a reload that does not happen gets
            # explained rather than guessed at.
            return stamp_report(hwnd)
        if rest == "poll":
            return String("changed ") + ("yes" if poll_disk(hwnd) else "no")
        if rest == "stop":
            stop_watching()
            return String("stopped watching")
        return watch_project(hwnd)

    if verb == "reload":
        return reload_document(hwnd)

    if verb == "zoom":
        # `zoom` says what it is; the menu and the keys change it, and they
        # live in the window procedure because changing it rebuilds the
        # chrome.
        return zoom_report(hwnd)

    if verb == "session":
        # `session` says what is remembered, `session save` writes it,
        # `session restore` puts it back, `session forget` removes it. An
        # unattended run never restores on its own, so a check that wants to
        # exercise this asks.
        if rest == "save":
            return remember_session(hwnd)
        if rest == "restore":
            return restore_session(hwnd)
        if rest == "forget":
            return forget_session(project_root())
        return session_report(hwnd)

    if verb == "tree":
        # `tree` lists it, `tree N` expands or collapses row N, `tree root
        # <path>` points it somewhere else.
        if rest.startswith("root"):
            var sp = rest.find(" ")
            if sp < 0:
                return String("usage: tree root <path>")
            return set_root(String(String(rest[byte=sp + 1 :]).strip()))
        if rest.byte_length() > 0:
            return toggle(Int(rest) - 1)
        return tree_report()

    if verb == "tabs":
        # `tabs` lists them, `tabs N` switches, `tabs close` closes the one
        # showing -- the same shape as `issues` and `references`.
        if rest == "close":
            return close_tab(hwnd)
        if rest == "next":
            return next_tab(hwnd, 1)
        if rest == "prev":
            return next_tab(hwnd, -1)
        if rest.byte_length() > 0:
            return switch_tab(hwnd, Int(rest) - 1)
        return tabs_report(hwnd)

    if verb == "run":
        # F5's verb. The document is saved first, because running the version
        # on disk while the window shows another one is how a person spends
        # ten minutes debugging an edit they had not saved.
        if rest.startswith("wait"):
            var sp = rest.find(" ")
            var ms = 30000
            if sp > 0:
                ms = Int(String(rest[byte=sp + 1 :]).strip())
            return build_wait(hwnd, ms)
        return run_file(hwnd)

    if verb == "build":
        if rest.startswith("wait"):
            var sp = rest.find(" ")
            var ms = 120000
            if sp > 0:
                ms = Int(String(rest[byte=sp + 1 :]).strip())
            return build_wait(hwnd, ms)
        return build_file(hwnd)

    if verb == "output":
        return output_report(hwnd)

    if verb == "stop":
        return stop_build()

    if verb == "save":
        # `save` writes where it came from; `save as <path>` writes elsewhere
        # and makes that the document's home.
        if rest.startswith("as"):
            var sp = rest.find(" ")
            if sp < 0:
                return String("usage: save as <path>")
            return save_as(hwnd, String(String(rest[byte=sp + 1 :]).strip()))
        if rest.byte_length() > 0:
            return String("usage: save | save as <path>")
        return save(hwnd)

    if verb == "dirty":
        # Whether there is unsaved work, which is the one thing a person must
        # be able to find out without guessing.
        return String("dirty ") + ("yes" if is_dirty(hwnd) else "no")

    if verb == "back":
        # Where the caret was before the last jump. The stack is what makes
        # following a definition into a definition survivable.
        return jump_back(hwnd)

    if verb == "open":
        # Opening by path, which is what a cross-file jump does underneath
        # and what a check needs to set one up.
        if rest.byte_length() == 0:
            return String("usage: open <path>")
        return open_path(hwnd, rest)

    if verb == "issues":
        # The issues pane, as text. The same list the pane draws and the same
        # order, so a check and a person are reading one thing.
        if rest.byte_length() > 0:
            return goto_issue(hwnd, Int(rest) - 1)
        return issues_report(hwnd)

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
