"""Driving the editor from a window handle.

Everything in this file starts the same way: find the document behind the
HWND, do the thing, mark the window for repaint. That is the whole of it, and
the reason it is a file of its own.

`gridview` draws and `edit` changes, and neither knows what a window is --
they take a `Doc` and a `Chrome` and can be reasoned about, or one day tested,
without one. This is the layer that turns a message or a verb into a call on
them. The window procedure and the agent both come through here, which is why
what a person gets and what a check gets cannot drift apart: `type` is what
WM_CHAR calls, `move` is what the arrow keys call, `caret_click` is what
WM_LBUTTONDOWN calls.

The one piece of state that lives here rather than in the document is none at
all. The window procedure is captureless -- Windows calls it, so it can hold
nothing -- and everything it needs is reachable from the single pointer
Windows keeps for the window: the `Chrome`, and through it the `Doc`.
"""

from std.ffi import c_int
from std.memory import OpaquePointer, Pointer
from std.sys._winkb import winkb_constant
from std.time import perf_counter_ns

from ide.caret import is_simple
from ide.chrome import Chrome, Layout
from ide.doc import Doc, Grid
from ide.edit import (
    backspace,
    byte_at,
    delete_forward,
    insert,
    move_horizontal,
    move_line_edge,
    move_to,
    move_vertical,
    newline,
    redo,
    select_all,
    selected_text,
    undo,
)
from ide.find import find_next, find_prev, select_match
from ide.gridview import (
    GUTTER_W,
    advance_of,
    caret_x,
    clusters_of,
    col_at_x,
    status_line,
)
from ide.rope import Rope
from ide.win32 import RECT, win32

def doc_of(hwnd: Int) raises -> Int:
    """The address of a window's document, or zero if it has none."""
    var GetWindowLongPtrW = win32[
        def (Int, c_int) thin abi("C") -> Int, "GetWindowLongPtrW"
    ]()
    var stored = GetWindowLongPtrW(
        hwnd, c_int(winkb_constant["GWLP_USERDATA"]())
    )
    if stored == 0:
        return 0
    return Pointer[Chrome, MutAnyOrigin](unsafe_from_address=stored)[].doc


def presents_immediately(hwnd: Int) raises -> Bool:
    """Whether this window's target skips the wait for the vertical blank."""
    var GetWindowLongPtrW = win32[
        def (Int, c_int) thin abi("C") -> Int, "GetWindowLongPtrW"
    ]()
    var stored = GetWindowLongPtrW(
        hwnd, c_int(winkb_constant["GWLP_USERDATA"]())
    )
    if stored == 0:
        return False
    return Pointer[Chrome, MutAnyOrigin](unsafe_from_address=stored)[].immediate


def page_lines(hwnd: Int) raises -> Int:
    """How many lines one page of this window's editor holds."""
    var address = doc_of(hwnd)
    if address == 0:
        return 1
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)
    var GetClientRect = win32[
        def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
        "GetClientRect",
    ]()
    var rc = RECT()
    _ = GetClientRect(hwnd, Pointer(to=rc).unsafe_origin_cast[MutAnyOrigin]())
    var editor = Layout(
        Int(rc.right - rc.left), Int(rc.bottom - rc.top)
    ).editor()
    # One line short of a screenful, so a page turn keeps a line of context.
    var whole = doc[].grid.visible_lines(editor.bottom - editor.top) - 1
    return whole if whole > 1 else 1


def scroll_to(hwnd: Int, line: Int) raises -> Int:
    """Put `line` at the top of this window's editor.

    Clamped so the document cannot be scrolled off either end. Asking for a
    line past the end lands on the last one, which is what `End` wants.

    Args:
        hwnd: The window to scroll.
        line: The line to show first, zero-based.

    Returns:
        The line actually shown first.

    Raises:
        If the window cannot be read.
    """
    var address = doc_of(hwnd)
    if address == 0:
        return 0
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)
    var last = doc[].rope.line_count() - 1
    var want = line
    if want > last:
        want = last
    if want < 0:
        want = 0
    if want == doc[].grid.top_line:
        return want
    doc[].grid.top_line = want

    var InvalidateRect = win32[
        def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
    ]()
    # Erasing the background first would flash: Direct2D clears the surface
    # itself, and letting Windows paint over it in between is visible.
    _ = InvalidateRect(hwnd, 0, c_int(0))
    return want


def scroll_by(hwnd: Int, lines: Int) raises -> Int:
    """Move this window's editor by a number of lines, up being negative."""
    var address = doc_of(hwnd)
    if address == 0:
        return 0
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)
    return scroll_to(hwnd, doc[].grid.top_line + lines)


def _bits(hwnd: Int) raises -> Tuple[Int, Int]:
    """A window's document and chrome addresses, or zeroes."""
    var GetWindowLongPtrW = win32[
        def (Int, c_int) thin abi("C") -> Int, "GetWindowLongPtrW"
    ]()
    var stored = GetWindowLongPtrW(
        hwnd, c_int(winkb_constant["GWLP_USERDATA"]())
    )
    if stored == 0:
        return (0, 0)
    return (
        Pointer[Chrome, MutAnyOrigin](unsafe_from_address=stored)[].doc,
        stored,
    )


def caret_report(hwnd: Int) raises -> String:
    """Where the caret is, and where that puts it on screen."""
    var bits = _bits(hwnd)
    if bits[0] == 0:
        return String("error: this window has no document")
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=bits[0])
    var chrome = Pointer[Chrome, MutAnyOrigin](unsafe_from_address=bits[1])
    var dwrite = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=chrome[].dwrite
    )
    var text = doc[].rope.line(doc[].caret_line)
    # Measured before it is reported: caret_x returns early at column zero,
    # so a fresh window would otherwise report an advance of nothing.
    _ = advance_of(doc[].grid, dwrite, chrome[])
    var x = caret_x(
        doc[].grid,
        dwrite,
        chrome[],
        doc[].rope,
        doc[].caret_line,
        doc[].caret_col,
        doc[].revision,
    )
    return (
        String("caret line=") + String(doc[].caret_line)
        + " col=" + String(doc[].caret_col)
        + " x=" + String(x)
        + " advance=" + String(doc[].grid.advance)
        + " path=" + ("arithmetic" if is_simple(text) else "directwrite")
    )


def caret_move(hwnd: Int, line: Int, col: Int) raises -> String:
    """Put the caret somewhere, clamped to the document."""
    var bits = _bits(hwnd)
    if bits[0] == 0:
        return String("error: this window has no document")
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=bits[0])
    # Through move_to, which collapses the selection. Setting the caret
    # directly and leaving the anchor where it was leaves a selection nobody
    # asked for -- and since every edit replaces the selection, the next
    # keystroke then eats the text between here and wherever the anchor had
    # been. The editing suite found exactly that.
    move_to(doc[], line, col)
    var InvalidateRect = win32[
        def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
    ]()
    _ = InvalidateRect(hwnd, 0, c_int(0))
    return caret_report(hwnd)


def caret_click(hwnd: Int, x: Int, y: Int) raises -> String:
    """Put the caret where a click in the editor landed.

    The point is in client coordinates, the way Windows delivers one, so the
    editor's origin and the gutter come off here rather than at every caller.
    """
    var bits = _bits(hwnd)
    if bits[0] == 0:
        return String("error: this window has no document")
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=bits[0])
    var chrome = Pointer[Chrome, MutAnyOrigin](unsafe_from_address=bits[1])
    var dwrite = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=chrome[].dwrite
    )

    var GetClientRect = win32[
        def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
        "GetClientRect",
    ]()
    var rc = RECT()
    _ = GetClientRect(hwnd, Pointer(to=rc).unsafe_origin_cast[MutAnyOrigin]())
    var editor = Layout(
        Int(rc.right - rc.left), Int(rc.bottom - rc.top)
    ).editor()
    if Float32(x) < editor.left or Float32(y) > editor.bottom:
        return String("outside the editor")

    var row = Int((Float32(y) - editor.top) / doc[].grid.line_height)
    var line = doc[].grid.top_line + row
    var last = doc[].rope.line_count() - 1
    if line > last:
        line = last
    if line < 0:
        line = 0
    var into = Float32(x) - editor.left - Float32(GUTTER_W)
    if into < 0:
        into = 0
    move_to(
        doc[],
        line,
        col_at_x(
            doc[].grid, dwrite, chrome[], doc[].rope, line, into, doc[].revision
        ),
    )
    var InvalidateRect = win32[
        def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
    ]()
    _ = InvalidateRect(hwnd, 0, c_int(0))
    return caret_report(hwnd)


def hittest_report(hwnd: Int, line: Int) raises -> String:
    """The caret-stop round trip for one line, as text."""
    var bits = _bits(hwnd)
    if bits[0] == 0:
        return String("error: this window has no document")
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=bits[0])
    var chrome = Pointer[Chrome, MutAnyOrigin](unsafe_from_address=bits[1])
    var dwrite = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=chrome[].dwrite
    )
    return clusters_of(
        doc[].grid, dwrite, chrome[], doc[].rope, line, doc[].revision
    )


def counters(hwnd: Int) raises -> String:
    """What the grid has been doing, as text.

    The sprint's claim is that scrolling lays out only newly exposed lines.
    This is how that gets checked: scroll a page, read the misses, and see a
    screenful rather than a document.

    Args:
        hwnd: The window to report on.

    Returns:
        The counters, as one line of text.

    Raises:
        If the window cannot be read.
    """
    var address = doc_of(hwnd)
    if address == 0:
        return String("error: this window has no document")
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)
    return (
        String("lines=") + String(doc[].rope.line_count())
        + " bytes=" + String(doc[].rope.byte_length())
        + " top=" + String(doc[].grid.top_line)
        + " rev=" + String(doc[].revision)
        + "  layouts: hits=" + String(doc[].grid.hits)
        + " misses=" + String(doc[].grid.misses)
        + " drawn=" + String(doc[].grid.drawn)
        + " cache=" + String(doc[].grid.capacity)
    )


def reset_counters(hwnd: Int) raises:
    """Zero the counters, so the next measurement starts from nothing."""
    var address = doc_of(hwnd)
    if address == 0:
        return
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)
    doc[].grid.hits = 0
    doc[].grid.misses = 0
    doc[].grid.drawn = 0


def _touch(hwnd: Int) raises:
    """Mark the window for repaint after the document changed."""
    var InvalidateRect = win32[
        def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
    ]()
    _ = InvalidateRect(hwnd, 0, c_int(0))


def _doc_at(hwnd: Int) raises -> Pointer[Doc, MutAnyOrigin]:
    """The window's document, or a raise if it has none."""
    var address = doc_of(hwnd)
    if address == 0:
        raise Error("this window has no document")
    return Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)


def follow_caret(hwnd: Int) raises:
    """Scroll so the caret is on screen, if it is not already.

    Called after anything that moves the caret. A caret that has wandered off
    the top or bottom is the editor's most common small betrayal: you press a
    key, something happens, and you cannot see what.
    """
    var doc = _doc_at(hwnd)
    var page = page_lines(hwnd)
    if doc[].caret_line < doc[].grid.top_line:
        _ = scroll_to(hwnd, doc[].caret_line)
    elif doc[].caret_line >= doc[].grid.top_line + page:
        _ = scroll_to(hwnd, doc[].caret_line - page + 1)


def find_text(hwnd: Int, needle: String) raises -> String:
    """Search for text and select the first match after the caret.

    Searching from the caret rather than from the top is what makes F3 mean
    "the next one" instead of "the first one, again".
    """
    var doc = _doc_at(hwnd)
    if needle.byte_length() > 0:
        doc[].needle = needle
    if doc[].needle.byte_length() == 0:
        return String("nothing to find; try: find <text>")

    var from_byte = byte_at(doc[].rope, doc[].caret_line, doc[].caret_col)
    var started = perf_counter_ns()
    var hit = find_next(doc[], doc[].needle, from_byte)
    var took = perf_counter_ns() - started
    if hit < 0:
        _touch(hwnd)
        return String("no match for ") + doc[].needle
    select_match(doc[], hit, doc[].needle)
    var page = page_lines(hwnd)
    var top = doc[].caret_line - page // 2
    _ = scroll_to(hwnd, top if top > 0 else 0)
    _touch(hwnd)
    return (
        String("found at byte ") + String(hit)
        + ", line " + String(doc[].caret_line + 1)
        + " in " + String(Float64(took) / 1_000_000.0) + " ms"
    )


def find_again(hwnd: Int, backwards: Bool) raises -> String:
    """What F3 and Shift+F3 do: the next match, or the one before."""
    var doc = _doc_at(hwnd)
    if doc[].needle.byte_length() == 0:
        return String("nothing to find yet")

    var hit = 0
    var started = perf_counter_ns()
    if backwards:
        # From the anchor rather than the caret: after a forward find the
        # match is selected, and searching back from its end would find the
        # same one again.
        var from_byte = byte_at(
            doc[].rope, doc[].anchor_line, doc[].anchor_col
        )
        hit = find_prev(doc[], doc[].needle, from_byte)
    else:
        var from_byte = byte_at(doc[].rope, doc[].caret_line, doc[].caret_col)
        hit = find_next(doc[], doc[].needle, from_byte)
    var took = perf_counter_ns() - started
    if hit < 0:
        return String("no match for ") + doc[].needle
    select_match(doc[], hit, doc[].needle)
    var page = page_lines(hwnd)
    var top = doc[].caret_line - page // 2
    _ = scroll_to(hwnd, top if top > 0 else 0)
    _touch(hwnd)
    return (
        String("found at byte ") + String(hit)
        + ", line " + String(doc[].caret_line + 1)
        + " in " + String(Float64(took) / 1_000_000.0) + " ms"
    )


def find_bench(hwnd: Int, needle: String) raises -> String:
    """Time one search of the whole document, both directions.

    The sprint acceptance is a number over a large document, and a number
    wants measuring rather than asserting. Forward is a walk to the first
    match; backward is a walk of the whole document, which the rope says
    plainly in `find_last` and which this reports rather than hides.
    """
    var doc = _doc_at(hwnd)
    var want = needle if needle.byte_length() > 0 else doc[].needle
    if want.byte_length() == 0:
        return String("usage: find-bench <text>")

    doc[].needle = want
    var t0 = perf_counter_ns()
    var forward = doc[].rope.find(want, 0)
    var t1 = perf_counter_ns()
    var last = find_prev(doc[], want, doc[].rope.byte_length())
    var t2 = perf_counter_ns()
    # A needle that is not there is the only honest full-scan measurement: a
    # forward find that stopped at byte 24 has measured the first two lines.
    # The absent needle is built from the real one so it cannot accidentally
    # be shorter, and a short needle is a faster scan.
    var absent = want + String("~~no~~")
    var t3 = perf_counter_ns()
    var miss = doc[].rope.find(absent, 0)
    var t4 = perf_counter_ns()
    # And the same scan the other way, which is the one that used to be slow.
    var t5 = perf_counter_ns()
    var miss_back = find_prev(doc[], absent, doc[].rope.byte_length())
    var t6 = perf_counter_ns()

    return (
        String("bytes=") + String(doc[].rope.byte_length())
        + " needle=" + want
        + "\nforward: first match at " + String(forward)
        + " in " + String(Float64(t1 - t0) / 1_000_000.0) + " ms"
        + "\nbackward: last match at " + String(last)
        + " in " + String(Float64(t2 - t1) / 1_000_000.0) + " ms"
        + "\nfull scan forward (no match, " + String(miss) + "): "
        + String(Float64(t4 - t3) / 1_000_000.0) + " ms"
        + "\nfull scan backward (no match, " + String(miss_back) + "): "
        + String(Float64(t6 - t5) / 1_000_000.0) + " ms"
    )


def type_text(hwnd: Int, text: String) raises -> String:
    """Insert text at the caret."""
    var doc = _doc_at(hwnd)
    insert(doc[], text)
    follow_caret(hwnd)
    _touch(hwnd)
    return caret_report(hwnd)


def edit_key(hwnd: Int, what: StringSlice) raises -> String:
    """One editing action by name, so a verb and a keystroke share a path."""
    var doc = _doc_at(hwnd)
    if what == "backspace":
        backspace(doc[])
    elif what == "delete":
        delete_forward(doc[])
    elif what == "enter":
        newline(doc[])
    elif what == "undo":
        if not undo(doc[]):
            return String("nothing to undo")
    elif what == "redo":
        if not redo(doc[]):
            return String("nothing to redo")
    else:
        return String("error: unknown edit '") + String(what) + "'"
    follow_caret(hwnd)
    _touch(hwnd)
    return caret_report(hwnd)


def move_key(hwnd: Int, what: StringSlice, extend: Bool) raises -> String:
    """One caret movement by name, shared by the keyboard and the agent."""
    var doc = _doc_at(hwnd)
    if what == "left":
        move_horizontal(doc[], -1, extend)
    elif what == "right":
        move_horizontal(doc[], 1, extend)
    elif what == "up":
        move_vertical(doc[], -1, extend)
    elif what == "down":
        move_vertical(doc[], 1, extend)
    elif what == "home":
        move_line_edge(doc[], False, extend)
    elif what == "end":
        move_line_edge(doc[], True, extend)
    elif what == "all":
        select_all(doc[])
    else:
        return String("error: unknown move '") + String(what) + "'"
    follow_caret(hwnd)
    _touch(hwnd)
    return caret_report(hwnd)


def goto(hwnd: Int, line: Int, col: Int) raises -> String:
    """Put the caret on a line, and scroll so it can be seen."""
    var doc = _doc_at(hwnd)
    move_to(doc[], line, col)
    # Centred rather than merely on screen: `goto` is how a person arrives
    # somewhere new, and arriving at the very bottom row of the window means
    # immediately scrolling to see any context at all.
    var page = page_lines(hwnd)
    var top = doc[].caret_line - page // 2
    _ = scroll_to(hwnd, top if top > 0 else 0)
    _touch(hwnd)
    return caret_report(hwnd)


def selection_report(hwnd: Int) raises -> String:
    """What is selected, and between which two points."""
    var doc = _doc_at(hwnd)
    if not doc[].has_selection():
        return String("no selection")
    return (
        String("selection ") + String(doc[].anchor_line) + ":"
        + String(doc[].anchor_col) + " to " + String(doc[].caret_line) + ":"
        + String(doc[].caret_col) + "\n" + selected_text(doc[])
    )


def state_report(hwnd: Int) raises -> String:
    """The document's edit state: dirty, and how far it can be undone."""
    var doc = _doc_at(hwnd)
    return (
        String("dirty=") + String(doc[].dirty)
        + " undo=" + String(len(doc[].past))
        + " redo=" + String(len(doc[].future))
        + " rev=" + String(doc[].revision)
        + " bytes=" + String(doc[].rope.byte_length())
        + " lines=" + String(doc[].rope.line_count())
    )


def line_text(hwnd: Int, line: Int) raises -> String:
    """One line, read back out of the rope."""
    var doc = _doc_at(hwnd)
    if line < 0 or line >= doc[].rope.line_count():
        return String("error: no line ") + String(line)
    return doc[].rope.line(line)


def all_text(hwnd: Int) raises -> String:
    """The whole document. For checks on small documents, not for humans."""
    var doc = _doc_at(hwnd)
    return doc[].rope.to_string()


def move_page(hwnd: Int, by: Int, extend: Bool) raises -> String:
    """Move the caret a page, and the view with it."""
    var doc = _doc_at(hwnd)
    move_to(doc[], doc[].caret_line + by, doc[].caret_col, extend)
    _ = scroll_by(hwnd, by)
    follow_caret(hwnd)
    _touch(hwnd)
    return caret_report(hwnd)


def type_unit(hwnd: Int, unit: Int) raises -> String:
    """Insert one UTF-16 code unit, joining surrogate pairs across messages.

    Windows delivers a character outside the basic plane as two WM_CHARs, a
    high surrogate and then a low. Inserting each as it arrives would put two
    lone surrogates in the document, which is not the emoji anyone typed. So
    the high half waits on the document until its partner turns up.

    A high surrogate that is never followed is dropped rather than kept
    forever: it is not a character, and leaving it pending would attach it to
    whatever unrelated thing was typed next.

    Args:
        hwnd: The window.
        unit: The UTF-16 code unit from WM_CHAR.

    Returns:
        Where the caret ended up, or a note that the pair is incomplete.

    Raises:
        If the edit fails.
    """
    var doc = _doc_at(hwnd)
    if unit >= 0xD800 and unit <= 0xDBFF:
        doc[].pending = unit
        return String("awaiting the low half of a surrogate pair")

    var code = unit
    if unit >= 0xDC00 and unit <= 0xDFFF:
        if doc[].pending == 0:
            # A low surrogate with nothing before it is not a character.
            return String("a stray low surrogate, ignored")
        code = 0x10000 + ((doc[].pending - 0xD800) << 10) + (unit - 0xDC00)
    doc[].pending = 0
    return type_text(hwnd, String(chr(code)))


# ===----------------------------------------------------------------------===#
# Input latency
#
# Sprint 1.7. What is measured here is the half of input-to-photon the
# application is responsible for: from the WM_CHAR handler being entered to
# EndDraw returning. With a vsync-presenting render target, EndDraw returns
# after the frame has been handed to the display, so that boundary is the last
# moment this process can affect.
#
# What is NOT measured, and cannot be from inside the process:
#
#   - key press to WM_CHAR: the keyboard, its driver, the raw input thread and
#     the message queue. Milliseconds, and none of them ours.
#   - present to photon: scanout and panel response. Also milliseconds, also
#     none of them ours.
#
# PresentMon measures both of those by reading ETW, which is why the sprint
# named it. It is not installed on this machine and pulling down and running
# an external binary is a decision for a person, not for a build. So the
# number below is the application half, measured precisely, and the reason the
# other half is missing is written down rather than papered over. See
# docs/latency.md.
# ===----------------------------------------------------------------------===#


def refresh_hz(hwnd: Int) raises -> Int:
    """The display refresh rate, asked of the display rather than assumed.

    A budget of "one frame" means nothing without knowing how long a frame is,
    and 60 Hz is an assumption that is wrong on most machines bought recently.
    """
    var GetDC = win32[def (Int) thin abi("C") -> Int, "GetDC"]()
    var ReleaseDC = win32[def (Int, Int) thin abi("C") -> c_int, "ReleaseDC"]()
    var GetDeviceCaps = win32[
        def (Int, c_int) thin abi("C") -> c_int, "GetDeviceCaps"
    ]()
    var dc = GetDC(hwnd)
    if dc == 0:
        return 60
    var hz = Int(GetDeviceCaps(dc, c_int(winkb_constant["VREFRESH"]())))
    _ = ReleaseDC(hwnd, dc)
    # 0 and 1 both mean "the default hardware rate" in GDI, which is not a
    # number anything can be divided by.
    return hz if hz > 1 else 60


def mark_keystroke(hwnd: Int) raises:
    """Note when a keystroke arrived, for the frame that will show it."""
    var address = doc_of(hwnd)
    if address == 0:
        return
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)
    # Only the first keystroke of a burst is stamped. If two arrive before a
    # frame is drawn, the second is shown by the same frame, and the honest
    # latency for that frame is the older one -- the longer wait, not the
    # shorter.
    if doc[].stamp == 0:
        doc[].stamp = perf_counter_ns()


def mark_drawn(hwnd: Int) raises:
    """Note that every drawing command for this frame has been issued.

    The boundary between the two halves. Before it is this application doing
    arithmetic, laying out text and filling rectangles; after it is EndDraw
    waiting for the vertical blank, which is the display's own cadence and
    which no amount of work here makes shorter.
    """
    var address = doc_of(hwnd)
    if address == 0:
        return
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)
    if doc[].stamp == 0:
        return
    var took = perf_counter_ns() - doc[].stamp
    doc[].work_total += took
    if took > doc[].work_worst:
        doc[].work_worst = took


def mark_presented(hwnd: Int, budget_ns: Int) raises:
    """Note that a frame reached the display, and what it cost."""
    var address = doc_of(hwnd)
    if address == 0:
        return
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)
    if doc[].stamp == 0:
        return
    var took = perf_counter_ns() - doc[].stamp
    doc[].stamp = 0
    doc[].lat_count += 1
    doc[].lat_total += took
    if took > doc[].lat_worst:
        doc[].lat_worst = took
    # Two frames, not one, and the reason matters. A keystroke arrives at some
    # point inside a refresh interval and is shown at the next vertical blank,
    # so keystroke-to-photon is spread across [work, work + one frame] even
    # when the work is nothing at all. Counting everything past one frame
    # would report half the samples as late by construction. What is actually
    # late is a keystroke that missed the next blank and waited for the one
    # after -- a dropped frame, which is what a person sees as a stutter.
    if took > budget_ns * 2:
        doc[].lat_over += 1


def latency_report(hwnd: Int) raises -> String:
    """Keystroke to presented frame, over whatever has been typed so far."""
    var doc = _doc_at(hwnd)
    var hz = refresh_hz(hwnd)
    var frame_ms = 1000.0 / Float64(hz)
    if doc[].lat_count == 0:
        return (
            String("no keystrokes measured yet; display is ") + String(hz)
            + " Hz, one frame is " + String(frame_ms) + " ms"
        )
    var n = Float64(doc[].lat_count)
    var mean = Float64(doc[].lat_total) / n / 1_000_000.0
    var worst = Float64(doc[].lat_worst) / 1_000_000.0
    var work_mean = Float64(doc[].work_total) / n / 1_000_000.0
    var work_worst = Float64(doc[].work_worst) / 1_000_000.0
    # Two numbers, because they answer different questions. The work is what
    # this editor costs and what any change to it moves. The total includes
    # the wait for the vertical blank, which is where a person's experience
    # actually lands and which is bounded below by the refresh interval no
    # matter how fast the work is.
    return (
        String("keystrokes=") + String(doc[].lat_count)
        + " display=" + String(hz) + "Hz frame=" + String(frame_ms) + "ms"
        + "\n  work (keystroke to last draw command): mean="
        + String(work_mean) + "ms worst=" + String(work_worst) + "ms"
        + "  = " + String(work_mean / frame_ms * 100.0) + "% of a frame"
        + "\n  total (keystroke to presented):        mean="
        + String(mean) + "ms worst=" + String(worst) + "ms"
        + "  frames missed: " + String(doc[].lat_over)
    )


def latency_reset(hwnd: Int) raises:
    """Forget everything measured so far."""
    var doc = _doc_at(hwnd)
    doc[].stamp = 0
    doc[].lat_count = 0
    doc[].lat_total = 0
    doc[].lat_worst = 0
    doc[].lat_over = 0
    doc[].work_total = 0
    doc[].work_worst = 0


def keystorm(hwnd: Int, count: Int) raises -> String:
    """Type `count` characters through the real message path, and measure.

    Real WM_CHAR messages, sent to this window, so the storm goes through the
    same handler a keyboard does -- not through `type_text`, which would skip
    the part being measured. UpdateWindow after each one is what the message
    loop does when it next goes idle, which for a person typing is
    immediately.
    """
    var SendMessageW = win32[
        def (Int, UInt32, Int, Int) thin abi("C") -> Int, "SendMessageW"
    ]()
    var UpdateWindow = win32[
        def (Int) thin abi("C") -> c_int, "UpdateWindow"
    ]()
    latency_reset(hwnd)
    var wm_char = UInt32(winkb_constant["WM_CHAR"]())
    for i in range(count):
        # Letters and the occasional newline, so the storm exercises the line
        # split as well as the common case.
        var ch = ord("a") + (i % 26)
        if i % 40 == 39:
            ch = 13  # Return
        _ = SendMessageW(hwnd, wm_char, ch, 0)
        _ = UpdateWindow(hwnd)
    return latency_report(hwnd)
