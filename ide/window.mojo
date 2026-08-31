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
from std.memory import OpaquePointer, Pointer, alloc
from std.sys._com import com_addr, com_method_of
from std.sys.com import co_create
from std.sys._globals import named_global
from std.sys._winkb import winkb_constant
from std.time import perf_counter_ns

from ide.caret import is_simple
from ide.chrome import Chrome, Layout, bring_up, release
from ide.doc import (
    Doc,
    Grid,
    LINE_H,
    PANE_ISSUES,
    PANE_OUTLINE,
    PANE_PYTHON,
    PANE_REFERENCES,
    PANE_TOOLCHAIN,
    PANE_VARIABLES,
    Snapshot,
)
from ide.edit import (
    delete_selection,
    caret_of_byte,
    remember,
    restate_dirty,
    apply,
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
from ide.diagnostics import count_for_shown, nth_visible, summary
from ide.find import find_next, find_prev, select_match
from ide.toolchain import (
    component_path,
    gpu_at,
    gpu_count,
    mojo_version,
    toolchain_root,
)
from ide.python_env import (
    install_packages,
    project_location,
    python_report,
)
from ide.python_env import variables as python_variables
from ide.pipeutf8 import without_bom
from ide.prompt import (
    asking,
    ASK_FIND,
    ASK_GOTO,
    ASK_NOTHING,
    ASK_OPEN,
    ASK_PACKAGE,
    ASK_REPLACE_WITH,
    ASK_SYMBOL,
    accept,
    ask,
    cancel,
    clear as prompt_clear,
    backspace as prompt_backspace,
    delete_forward as prompt_delete,
    move as prompt_move,
    move_to_end as prompt_end,
    move_to_start as prompt_home,
    prompt_report,
    put,
    recalled,
)
from ide.clipboard import (
    clipboard_text,
    clipboard_was_busy,
    set_clipboard_text,
)
from ide.symbols import (
    clear_symbols,
    matching_symbols,
    request_symbols,
    symbol_at,
    symbol_count,
    symbols_report,
    symbols_serial,
)
from ide.lsp import (
    start_with_environment,
    parse_serial,
    parsed_uri,
    did_change,
    did_open,
    g_diag_col,
    g_diag_line,
    g_diag_msg,
    is_ready,
    is_running,
    poll,
    clear_completions,
    completion_count,
    g_comp_detail,
    g_comp_insert,
    g_comp_label,
    request_completion,
    set_shown_uri,
    start,
    stop,
    # Sprint 2.5. All of this came with the Mac port's client already
    # written -- the requests, the response handlers and the ContentModified
    # retry. The editor side is what this sprint adds.
    clear_references,
    definition_character,
    definition_line,
    definition_serial,
    definition_uri,
    hover_serial,
    hover_text,
    reference_character,
    reference_count,
    reference_line,
    reference_uri,
    references_serial,
    request_definition,
    request_hover,
    request_references,
)
from ide.gridview import (
    GUTTER_W,
    debug_row_at,
    frame_rows,
    set_stop_line,
    set_variable_rows,
    outline_row_at,
    output_row_at,
    tab_at,
    tree_row_at,
    release_cache,
    issue_row_at,
    advance_of,
    caret_x,
    clusters_of,
    col_at_x,
    status_line,
)
from ide.build import (
    append_output,
    clear_output,
    is_building,
    locate,
    output_count,
    output_line,
    output_serial,
    poll as poll_build,
    start as start_build,
    stop as stop_build,
    what_ran,
)
from ide.dap import (
    configuration_done,
    evaluate,
    evaluated_type,
    debug_serial,
    debugging,
    frame_count,
    frame_line,
    frame_name,
    frame_source,
    poll_debug,
    resume,
    select_frame,
    set_breakpoints,
    start_debug,
    step_in,
    step_out,
    step_over,
    stop_debug,
    stop_line,
    stop_reason,
    stop_source,
    stopped,
    variable_count,
    variable_name,
    variable_type,
    variable_value,
)
from ide.replace import (
    count_matches,
    preview_replacements,
    replace_all,
    replace_next,
)
from ide.rope import Rope
from ide.search import (
    hit_column,
    hit_count,
    hit_line,
    hit_path,
    hit_text,
    hit_truncated,
    search_project,
    searched_files,
)
from ide.watch import (
    file_stamp,
    poll_changes,
    watch_directory,
    watching,
)
from ide.session import (
    OpenFile,
    dropped_count,
    expanded_count,
    expanded_path,
    load_session,
    save_session,
    session_current,
    session_file,
    session_file_count,
    session_path,
    forget_session,
)
from ide.tree import (
    entry_at,
    expand_path,
    expanded_paths,
    project_root,
    refresh,
    entry_count,
    scroll_tree,
    set_root,
    toggle,
    tree_report,
)
from ide.win32 import (
    RECT,
    absolute,
    env_or,
    dpi_scale,
    drain,
    set_zoom,
    zoom,
    ZOOM_STEP,
    scaled,
    settle,
    win32,
)

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
        Int(rc.right - rc.left), Int(rc.bottom - rc.top), dpi_scale(hwnd)
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
    var scale = dpi_scale(hwnd)
    var editor = Layout(
        Int(rc.right - rc.left), Int(rc.bottom - rc.top), scale
    ).editor()
    var full = Layout(
        Int(rc.right - rc.left), Int(rc.bottom - rc.top), scale
    )
    # The sidebar: a file opens, a directory expands. Checked before the
    # editor because the sidebar is to the left of it and a click there is
    # never about the text.
    var side = full.sidebar()
    if Float32(x) >= side.left and Float32(x) < side.right:
        var row = tree_row_at(side, Float32(y), scale)
        if row < 0:
            return String("the sidebar")
        var e = entry_at(row)
        if e.is_dir:
            var said = toggle(row)
            _touch(hwnd)
            return said
        return open_path(hwnd, e.path)

    # A click on a tab switches to it. Checked before the editor because the
    # strip sits inside the editor field's column and above its text.
    var strip = full.tabs()
    if Float32(y) <= strip.bottom and Float32(x) >= strip.left:
        var which = tab_at(strip, Float32(x), scale, tab_count())
        if which < 0:
            return String("the tab strip")
        return switch_tab(hwnd, which)

    # A frame in the debug pane is a place too, and clicking one walks the
    # stack: the caret goes to that frame's line and the locals become its
    # locals. Execution has not moved -- browsing a stack is reading, not
    # stepping -- so the halted line stays where it is.
    if doc[].pane_mode == PANE_VARIABLES:
        var debug_pane = full.issues()
        if (
            Float32(x) >= debug_pane.left
            and Float32(x) < debug_pane.right
            and Float32(y) >= debug_pane.top
            and Float32(y) <= debug_pane.bottom
        ):
            var row = debug_row_at(debug_pane, Float32(y), scale)
            if row < 0 or row >= frame_rows():
                return String("the debug pane")
            select_frame(row)
            var where = frame_source(row)
            if where.byte_length() > 0 and frame_line(row) >= 0:
                return jump_to(hwnd, file_uri(where), frame_line(row), 0)
            return String("that frame has no source")

    if doc[].pane_mode == PANE_OUTLINE:
        var out_of = full.issues()
        if (
            Float32(x) >= out_of.left
            and Float32(x) < out_of.right
            and Float32(y) >= out_of.top
            and Float32(y) <= out_of.bottom
        ):
            var row = outline_row_at(out_of, Float32(y), scale)
            if row < 0:
                return String("the outline pane")
            var one = symbol_at(row)
            _ = caret_move(hwnd, one.line, one.column)
            follow_caret(hwnd)
            _touch(hwnd)
            return String("went to ") + one.name

    # A diagnostic in the output pane is a place, and clicking a place
    # should go there. This is the edit-build-fix loop closing: the compiler
    # says where, and the editor takes you.
    var out_pane = full.output()
    if (
        Float32(x) >= out_pane.left
        and Float32(y) >= out_pane.top
        and Float32(y) <= out_pane.bottom
    ):
        var row = output_row_at(out_pane, Float32(y), scale)
        if row < 0 or row >= output_count():
            return String("the output pane")
        var found = locate(output_line(row))
        if found[0].byte_length() == 0:
            return String("that line names no place")
        return jump_to(hwnd, file_uri(found[0]), found[1], found[2])

    var pane = full.issues()
    # The issues pane is below the editor field and to the left. A click there
    # is a person asking to go somewhere, not to put the caret in a list.
    if (
        Float32(y) >= pane.top
        and Float32(y) <= pane.bottom
        and Float32(x) >= pane.left
        and Float32(x) <= pane.right
    ):
        var row = issue_row_at(pane, Float32(y), scale)
        if row < 0:
            return String("the issues heading")
        return goto_issue(hwnd, row)

    if Float32(x) < editor.left or Float32(y) > editor.bottom:
        return String("outside the editor")

    var row = Int((Float32(y) - editor.top) / doc[].grid.line_height)
    var line = doc[].grid.top_line + row
    var last = doc[].rope.line_count() - 1
    if line > last:
        line = last
    if line < 0:
        line = 0
    # The gutter is where breakpoints are set, so a click in it is not a
    # click in the text. Everything left of the text origin belongs to the
    # gutter, which is exactly the region the markers are drawn in.
    var gutter_right = editor.left + scaled(GUTTER_W, scale)
    if Float32(x) < gutter_right:
        return toggle_breakpoint(hwnd, line)

    var into = Float32(x) - editor.left - scaled(GUTTER_W, dpi_scale(hwnd))
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
    # The title carries the dirty mark, so it is refreshed wherever the
    # document changes rather than at the handful of places that remember to.
    try:
        retitle(hwnd)
    except:
        pass

def _doc_at(hwnd: Int) raises -> Pointer[Doc, MutAnyOrigin]:
    """The window's document, or a raise if it has none."""
    var address = doc_of(hwnd)
    if address == 0:
        raise Error("this window has no document")
    return Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)


def line_height_of(hwnd: Int) raises -> Float32:
    """How tall one text row is on this window, in device pixels.

    The grid holds it because scrolling and hit testing both divide by it, and
    it is scaled from the display's DPI when the chrome is brought up. Exposed
    so the agent surface can report the number the editor is using rather than
    the constant it started from.

    Args:
        hwnd: The window.

    Returns:
        The row height.

    Raises:
        If the window has no document.
    """
    return _doc_at(hwnd)[].grid.line_height


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
    # The prompt, when it is open, is what a keystroke is for. The pairing
    # above happens first either way: a surrogate half is not a character, and
    # the line has no more business holding one than the document does.
    if asking():
        return prompt_type(hwnd, String(chr(code)))
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


# ===----------------------------------------------------------------------===#
# The language server
#
# Sprint 2.2. The client is MojoCocoa's, ported; this is the part that knows
# about a window. The server is started when a real file is opened, told about
# every edit, and drained from a timer -- a blocking read on the thread that
# draws is an editor that stops responding whenever the server thinks.
# ===----------------------------------------------------------------------===#


def file_uri(path: String) -> String:
    """A file URI Windows will accept: forward slashes, three after the colon.

    `file:///E:/x` rather than `file://E:/x`: with two slashes the drive letter
    is read as a hostname, and the server looks for a machine called E.
    """
    var out = String("file:///")
    for byte in path.as_bytes():
        var c = Int(byte)
        out += "/" if c == ord("\\") else chr(c)
    return out^


def start_server(hwnd: Int, exe: String, stdlib: String) raises -> String:
    """Start the language server for the document in this window."""
    var doc = _doc_at(hwnd)
    if doc[].uri.byte_length() == 0:
        return String("no file open; nothing to diagnose")
    if is_ready():
        return String("already running")
    # The document's own directory as the root: an editor that roots the
    # server at the drive scans the drive.
    var full = doc[].uri
    var slash = full.rfind("/")
    # A fresh String rather than assigning a slice of `root` back over it:
    # the slice borrows the storage it would be overwriting.
    var root = String(full[byte=:slash]) if slash > 0 else full
    # With the project's Python environment, through the parameter the client
    # has always had and nobody has ever filled. The server resolves
    # `from python import ...` the same way a build does, so a server started
    # in a different environment from the compiler disagrees with it about
    # what exists -- and the disagreement shows up as a squiggle under working
    # code, which is the most expensive kind of wrong an editor can be.
    # The environment is keyed by the project's PATH, not by `root`, which is
    # a file:/// uri: hashing that would key a second environment for the same
    # project and hand the server a different set of packages from the one the
    # build uses. The server and the compiler have to be in the same world or
    # the disagreement shows up as a squiggle under working code.
    if not start_with_environment(
        exe,
        root,
        stdlib,
        python_variables(
            project_location(project_root(), document_path(hwnd))
        ),
    ):
        return String("could not start ") + exe
    return String("starting ") + exe


def announce(hwnd: Int) raises:
    """Tell the server about the open document, once it is ready.

    A server that has just finished its handshake knows about no documents at
    all, so this runs on the transition rather than once at startup -- the
    same reason MojoCocoa watches `ready_serial`.
    """
    var doc = _doc_at(hwnd)
    if doc[].uri.byte_length() == 0 or not is_ready():
        return
    if doc[].sent_version == 0:
        did_open(doc[].uri, doc[].rope.to_string())
        doc[].sent_version = 1
        set_shown_uri(doc[].uri)


def sync(hwnd: Int) raises:
    """Send the document if it has changed since the server last heard.

    Full text, deliberately, and worth being plain about: the sprint asks for
    incremental didChange from the rope's edit spans, and the rope does know
    them. What it does not have is a mapping from a byte span to the UTF-16
    line and character range LSP wants, on the document *as the server last
    saw it* -- which is a different document from the current one once two
    edits have happened between polls. Getting that wrong moves every
    diagnostic in the file by a column and looks like the server is broken.
    Whole-document sync is correct at any version, costs one string copy per
    idle period rather than per keystroke, and leaves the span mapping to be
    built deliberately rather than in passing.
    """
    var doc = _doc_at(hwnd)
    if doc[].uri.byte_length() == 0 or not is_ready():
        return
    if doc[].sent_version == 0:
        announce(hwnd)
        return
    if doc[].sent_version == doc[].revision + 1:
        return
    doc[].sent_version = doc[].revision + 1
    did_change(doc[].uri, doc[].sent_version, doc[].rope.to_string())


def pump(hwnd: Int) raises -> Int:
    """Drain whatever the server has said, and repaint if it said anything."""
    if not is_running():
        return 0
    var handled = poll()
    var was = is_ready()
    if was:
        announce(hwnd)
        sync(hwnd)
    if handled > 0:
        _touch(hwnd)
    return handled


def issues_report(hwnd: Int) raises -> String:
    """Every diagnostic for the open document, as text."""
    if not is_running():
        return String("the language server is not running")
    if not is_ready():
        return String("the language server is still starting")
    return summary()


def goto_issue(hwnd: Int, n: Int) raises -> String:
    """Put the caret on the nth issue, the way clicking its row does."""
    var which = nth_visible(n)
    if which < 0:
        return String("no issue ") + String(n + 1)
    var line = g_diag_line()[][which]
    var col = g_diag_col()[][which]
    _ = goto(hwnd, line, col)
    return (
        String("issue ") + String(n + 1) + " at line " + String(line + 1)
        + ": " + g_diag_msg()[][which]
    )


def lsp_wait(hwnd: Int, milliseconds: Int) raises -> String:
    """Pump the server until it has something to say, or the time runs out.

    The window's timer does this in the background while a person types. A
    check has no timer -- `--cmd` answers and exits -- so it needs a way to
    say "wait for the server", and this is it. Bounded, because a server that
    never answers must not hang the check that is measuring it.

    Args:
        hwnd: The window.
        milliseconds: How long to wait at most.

    Returns:
        What state the server reached.

    Raises:
        If the window has no document.
    """
    var deadline = perf_counter_ns() + milliseconds * 1_000_000
    var saw_ready = False
    while perf_counter_ns() < deadline:
        _ = pump(hwnd)
        if is_ready():
            saw_ready = True
            # Ready is not the same as having parsed: the handshake finishes
            # long before the first diagnostic arrives, and a check that
            # stopped at "ready" would read an empty list every time.
            if summary() != "no issues":
                return String("ready, ") + String(count_for_shown()) + " issue(s)"
        # Ten milliseconds of being idle, not ten of being hung: `settle`
        # dispatches whatever the window manager has queued and comes back
        # early if something arrived.
        _ = settle(hwnd, 10)
    if not is_running():
        return String("the server is not running")
    if not saw_ready:
        return String("the server did not finish its handshake in time")
    return String("ready, no issues")


def stop_server() raises:
    """Shut the server down.

    Without this the process exits with the pipe still open, the server's next
    write fails, and it reports a crash -- a crash caused entirely by the
    editor walking away mid-sentence.
    """
    if is_running():
        stop()


# ===----------------------------------------------------------------------===#
# The completion popup
#
# The list itself lives in the language server client -- it arrives
# asynchronously and belongs to a request, not to a document -- so what the
# document keeps is only whether the popup is up and which row is chosen.
# ===----------------------------------------------------------------------===#


def complete_at_caret(hwnd: Int) raises -> String:
    """Ask the server what could go here, and put the popup up.

    The request is asynchronous: this returns as soon as it is sent, and the
    items arrive on a later pump. So the popup opens now and fills in when the
    answer comes, which is also what stops a slow server from freezing a
    keystroke.
    """
    var doc = _doc_at(hwnd)
    if doc[].uri.byte_length() == 0 or not is_ready():
        return String("no language server for this document")
    sync(hwnd)
    clear_completions()
    doc[].popup = True
    doc[].popup_row = 0
    doc[].popup_line = doc[].caret_line
    doc[].popup_col = doc[].caret_col
    _ = request_completion(doc[].uri, doc[].caret_line, doc[].caret_col)
    _touch(hwnd)
    return String("asked for completions at ") + String(
        doc[].caret_line + 1
    ) + ":" + String(doc[].caret_col + 1)


def popup_move(hwnd: Int, by: Int) raises -> String:
    """Move the chosen row, wrapping at both ends."""
    var doc = _doc_at(hwnd)
    var total = completion_count()
    if not doc[].popup or total == 0:
        return String("no popup")
    doc[].popup_row = (doc[].popup_row + by + total) % total
    _touch(hwnd)
    return (
        String("row ") + String(doc[].popup_row + 1) + " of " + String(total)
        + ": " + g_comp_label()[][doc[].popup_row]
    )


def popup_close(hwnd: Int) raises -> String:
    """Put the popup away without taking anything from it."""
    var doc = _doc_at(hwnd)
    doc[].popup = False
    clear_completions()
    _touch(hwnd)
    return String("popup closed")


def popup_accept(hwnd: Int) raises -> String:
    """Take the chosen completion, replacing the word being typed.

    The word is what was there when the popup opened plus whatever has been
    typed since, so the replacement starts at the identifier's beginning and
    not at the caret. Inserting at the caret is how an editor turns `Drag`
    into `DragDragOver`.
    """
    var doc = _doc_at(hwnd)
    var total = completion_count()
    if not doc[].popup or total == 0:
        return String("no popup")
    var row = doc[].popup_row
    if row < 0 or row >= total:
        row = 0
    var text = g_comp_insert()[][row]
    if text.byte_length() == 0:
        text = g_comp_label()[][row]

    # Back up over the identifier the caret is sitting at the end of.
    var line_text = doc[].rope.line(doc[].caret_line)
    var bytes = line_text.as_bytes()
    var at = byte_at(doc[].rope, doc[].caret_line, doc[].caret_col)
    var line_start = doc[].rope.line_start(doc[].caret_line)
    var back = at - line_start
    while back > 0:
        var c = Int(bytes[back - 1])
        var wordish = (
            (c >= ord("a") and c <= ord("z"))
            or (c >= ord("A") and c <= ord("Z"))
            or (c >= ord("0") and c <= ord("9"))
            or c == ord("_")
        )
        if not wordish:
            break
        back -= 1

    doc[].popup = False
    apply(doc[], line_start + back, at, text)
    clear_completions()
    follow_caret(hwnd)
    _touch(hwnd)
    return String("accepted ") + g_comp_label()[][row] if False else (
        String("accepted, ") + String(doc[].rope.line(doc[].caret_line))
    )


def popup_report(hwnd: Int) raises -> String:
    """What the popup is showing, for a check to read."""
    var doc = _doc_at(hwnd)
    var total = completion_count()
    if not doc[].popup:
        return String("popup closed")
    if total == 0:
        return String("popup open, still waiting")
    var out = (
        String("popup open, ") + String(total) + " item(s), row "
        + String(doc[].popup_row + 1) + "\n"
    )
    for i in range(total if total < 12 else 12):
        out += (
            (String("> ") if i == doc[].popup_row else String("  "))
            + g_comp_label()[][i] + "  " + g_comp_detail()[][i] + "\n"
        )
    return out^


def popup_is_open(hwnd: Int) raises -> Bool:
    """Whether the popup is up, for the key handler to ask."""
    var address = doc_of(hwnd)
    if address == 0:
        return False
    return Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)[].popup


def popup_state(hwnd: Int) raises -> Tuple[Bool, Int, Int, Int]:
    """Whether the popup is up, its row, and the caret it hangs from."""
    var doc = _doc_at(hwnd)
    return (doc[].popup, doc[].popup_row, doc[].caret_line, doc[].caret_col)


def popup_wait(hwnd: Int, milliseconds: Int) raises -> String:
    """Pump until the completion answer arrives, or the time runs out.

    The window's timer does this while a person is still deciding what to
    type. A check has no timer, so it says when to wait -- the same shape as
    `lsp_wait`, and for the same reason.
    """
    var deadline = perf_counter_ns() + milliseconds * 1_000_000
    while perf_counter_ns() < deadline:
        _ = pump(hwnd)
        if completion_count() > 0:
            return popup_report(hwnd)
        # Ten milliseconds of being idle, not ten of being hung: `settle`
        # dispatches whatever the window manager has queued and comes back
        # early if something arrived.
        _ = settle(hwnd, 10)
    return String("no completions arrived")


# ===----------------------------------------------------------------------===#
# Navigation
#
# Sprint 2.5. Definition, references and hover are three questions with one
# shape: ask the server about the position the caret is on, and do something
# with where it points. The client half was already written -- the Mac port's
# `ide/lsp.mojo` has `request_definition`, `request_hover` and
# `request_references`, their response handlers, and the `-32801` retry a
# request sent mid-reparse needs. This is the editor half.
#
# Every one of these returns as soon as the request is sent. A server that
# takes a second to answer must not be able to freeze a keystroke, so the
# answer lands on a later pump and the `_wait` functions are what a check uses
# in place of the window's timer.
# ===----------------------------------------------------------------------===#


def _hex_digit(c: Int) -> Int:
    """One hex digit's value, or -1 if it is not one.

    Args:
        c: A byte.

    Returns:
        0-15, or -1.
    """
    if c >= 0x30 and c <= 0x39:
        return c - 0x30
    if c >= 0x61 and c <= 0x66:
        return c - 0x61 + 10
    if c >= 0x41 and c <= 0x46:
        return c - 0x41 + 10
    return -1


def path_of_uri(uri: String) raises -> String:
    """The Windows path a `file:///` URI names.

    The inverse of `file_uri`, and it has to be: a definition reply names a
    file the way the server spells it, and the editor opens files the way
    Windows spells them. Percent-escapes are decoded because a server is
    entitled to send them and a path with a space in it is not unusual.

    Args:
        uri: A file URI.

    Returns:
        The path, with backslashes, or an empty string for anything that is
        not a file URI.

    Raises:
        Never in practice.
    """
    if not uri.startswith("file:///"):
        return String("")
    var rest = String(uri[byte=8:])
    var out = String("")
    var bytes = rest.as_bytes()
    var i = 0
    while i < len(bytes):
        var c = Int(bytes[i])
        if c == 0x25 and i + 2 < len(bytes):  # '%'
            var hi = _hex_digit(Int(bytes[i + 1]))
            var lo = _hex_digit(Int(bytes[i + 2]))
            if hi >= 0 and lo >= 0:
                out += chr(hi * 16 + lo)
                i += 3
                continue
        out += chr(0x5C) if c == 0x2F else chr(c)  # '/' becomes a backslash
        i += 1
    return out^


def open_path(hwnd: Int, path: String) raises -> String:
    """Replace the window's document with the file at `path`.

    Milestone 3 gives this tabs. Until then a jump into another file is that
    file taking the window, which is what a single-document editor can honestly
    do -- and the jump stack is what makes it survivable, because the way back
    is one keystroke rather than a re-open.

    The undo history goes with the old document. It has to: a history whose
    snapshots are roots of a rope the window no longer holds would restore the
    previous file's text into this one.

    Args:
        hwnd: The window.
        path: The file to open.

    Returns:
        What happened, for the agent surface.

    Raises:
        If the window has no document.
    """
    var full = absolute(path)
    var uri = file_uri(full)

    # Already open? Then this is a switch, not a load. Opening a second copy
    # of a file is how an editor lets somebody edit one of them and save the
    # other over it.
    var existing = tab_for_uri(uri)
    if existing >= 0:
        return switch_tab(hwnd, existing)

    var text = String("")
    try:
        with open(path, "r") as f:
            text = f.read()
    except err:
        return String("cannot open ") + path + ": " + String(err)

    var stripped = without_bom(text^)
    var store = alloc[Doc](1, alignment=8)
    # Emplaced, not assigned: `store[] = value` destroys what was there
    # first, and what is there is whatever the allocator last had.
    store.unsafe_write(Doc(Rope(stripped[0])))
    store[].had_bom = stripped[1]
    store[].uri = uri
    # From the moment it is open, not from the first change noticed. Recording
    # it lazily meant the first external write was spent establishing the
    # baseline and the reload it should have triggered never happened.
    store[].disk_stamp = file_stamp(full)
    var bits = _bits(hwnd)
    var chrome = Pointer[Chrome, MutAnyOrigin](unsafe_from_address=bits[1])
    store[].grid.line_height = scaled(LINE_H, chrome[].scale)
    _ = adopt_tab(hwnd, Int(store))
    var doc = _doc_at(hwnd)
    # Zero means "the server has not been told about this document", which is
    # what `announce` waits for.
    doc[].sent_version = 0
    try:
        announce(hwnd)
    except:
        pass
    _touch(hwnd)
    return (
        String("opened ") + path + " (" + String(doc[].rope.line_count())
        + " lines)"
    )


def jump_to(hwnd: Int, uri: String, line: Int, character: Int) raises -> String:
    """Put the caret at a place the server named, opening its file if needed.

    Where the caret was goes on the jump stack first, so the way back exists
    before the way forward is taken.

    Args:
        hwnd: The window.
        uri: The file the location is in.
        line: Zero-based line.
        character: Zero-based UTF-16 offset.

    Returns:
        What happened.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    doc[].jump_uri.append(doc[].uri)
    doc[].jump_line.append(doc[].caret_line)
    doc[].jump_col.append(doc[].caret_col)

    var out = String("")
    if uri != doc[].uri and uri.byte_length() > 0:
        var path = path_of_uri(uri)
        if path.byte_length() == 0:
            return String("cannot follow ") + uri
        out = open_path(hwnd, path) + "; "
    _ = caret_move(hwnd, line, character)
    follow_caret(hwnd)
    _touch(hwnd)
    return out + "at " + String(line + 1) + ":" + String(character + 1)


def jump_back(hwnd: Int) raises -> String:
    """Undo the last jump, opening the file it came from if it was elsewhere.

    Args:
        hwnd: The window.

    Returns:
        What happened, or that there was nowhere to go.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    var n = len(doc[].jump_uri)
    if n == 0:
        return String("nowhere to go back to")
    var uri = doc[].jump_uri[n - 1]
    var line = doc[].jump_line[n - 1]
    var col = doc[].jump_col[n - 1]
    _ = doc[].jump_uri.pop()
    _ = doc[].jump_line.pop()
    _ = doc[].jump_col.pop()

    var out = String("")
    if uri != doc[].uri and uri.byte_length() > 0:
        var path = path_of_uri(uri)
        if path.byte_length() > 0:
            out = open_path(hwnd, path) + "; "
    _ = caret_move(hwnd, line, col)
    follow_caret(hwnd)
    _touch(hwnd)
    return (
        out + "back to " + String(line + 1) + ":" + String(col + 1)
        + " (" + String(n - 1) + " left)"
    )


def definition_at_caret(hwnd: Int) raises -> String:
    """Ask where the thing under the caret is defined.

    Args:
        hwnd: The window.

    Returns:
        What was asked, or why it was not.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    if doc[].uri.byte_length() == 0 or not is_ready():
        return String("no language server for this document")
    sync(hwnd)
    _ = request_definition(doc[].uri, doc[].caret_line, doc[].caret_col)
    return (
        String("asked where ") + String(doc[].caret_line + 1) + ":"
        + String(doc[].caret_col + 1) + " is defined"
    )


def definition_wait(hwnd: Int, milliseconds: Int) raises -> String:
    """Pump until the definition answer arrives, then go there.

    Args:
        hwnd: The window.
        milliseconds: How long to wait.

    Returns:
        Where it went, or that nothing came.

    Raises:
        If the window has no document.
    """
    var before = definition_serial()
    var deadline = perf_counter_ns() + milliseconds * 1_000_000
    while perf_counter_ns() < deadline:
        _ = pump(hwnd)
        if definition_serial() != before:
            var uri = definition_uri()
            if uri.byte_length() == 0:
                return String("no definition for that")
            return jump_to(
                hwnd, uri, definition_line(), definition_character()
            )
        # Ten milliseconds of being idle, not ten of being hung: `settle`
        # dispatches whatever the window manager has queued and comes back
        # early if something arrived.
        _ = settle(hwnd, 10)
    return String("no definition arrived")


def hover_at_caret(hwnd: Int) raises -> String:
    """Ask what the thing under the caret is.

    Args:
        hwnd: The window.

    Returns:
        What was asked, or why it was not.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    if doc[].uri.byte_length() == 0 or not is_ready():
        return String("no language server for this document")
    sync(hwnd)
    doc[].hover = True
    _ = request_hover(doc[].uri, doc[].caret_line, doc[].caret_col)
    _touch(hwnd)
    return (
        String("asked what is at ") + String(doc[].caret_line + 1) + ":"
        + String(doc[].caret_col + 1)
    )


def hover_wait(hwnd: Int, milliseconds: Int) raises -> String:
    """Pump until the hover answer arrives.

    Args:
        hwnd: The window.
        milliseconds: How long to wait.

    Returns:
        The hover text, flattened to one line, or that nothing came.

    Raises:
        If the window has no document.
    """
    var before = hover_serial()
    var deadline = perf_counter_ns() + milliseconds * 1_000_000
    while perf_counter_ns() < deadline:
        _ = pump(hwnd)
        if hover_serial() != before:
            _touch(hwnd)
            return hover_report(hwnd)
        # Ten milliseconds of being idle, not ten of being hung: `settle`
        # dispatches whatever the window manager has queued and comes back
        # early if something arrived.
        _ = settle(hwnd, 10)
    return String("no hover arrived")


def hover_report(hwnd: Int) raises -> String:
    """What the hover box is showing, as one line.

    Args:
        hwnd: The window.

    Returns:
        The text with newlines turned into spaces, or that there is none.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    if not doc[].hover:
        return String("no hover")
    var text = hover_text()
    if text.byte_length() == 0:
        return String("hover: nothing known about that")
    var out = String("hover: ")
    for byte in text.as_bytes():
        var c = Int(byte)
        out += " " if (c == 10 or c == 13) else chr(c)
    return out^


def hover_close(hwnd: Int) raises -> String:
    """Put the hover box away.

    Args:
        hwnd: The window.

    Returns:
        That it is closed.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    doc[].hover = False
    _touch(hwnd)
    return String("hover closed")


def hover_is_open(hwnd: Int) raises -> Bool:
    """Whether the hover box is up, for the key handler.

    Args:
        hwnd: The window.

    Returns:
        True while it is showing.

    Raises:
        If the window has no document.
    """
    return _doc_at(hwnd)[].hover


def references_at_caret(hwnd: Int) raises -> String:
    """Ask where the thing under the caret is used.

    Args:
        hwnd: The window.

    Returns:
        What was asked, or why it was not.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    if doc[].uri.byte_length() == 0 or not is_ready():
        return String("no language server for this document")
    sync(hwnd)
    clear_references()
    doc[].pane_mode = PANE_REFERENCES
    _ = request_references(doc[].uri, doc[].caret_line, doc[].caret_col)
    _touch(hwnd)
    return (
        String("asked who uses ") + String(doc[].caret_line + 1) + ":"
        + String(doc[].caret_col + 1)
    )


def references_wait(hwnd: Int, milliseconds: Int) raises -> String:
    """Pump until the references arrive.

    Args:
        hwnd: The window.
        milliseconds: How long to wait.

    Returns:
        The list, or that nothing came.

    Raises:
        If the window has no document.
    """
    var before = references_serial()
    var deadline = perf_counter_ns() + milliseconds * 1_000_000
    while perf_counter_ns() < deadline:
        _ = pump(hwnd)
        if references_serial() != before:
            _touch(hwnd)
            return references_report(hwnd)
        # Ten milliseconds of being idle, not ten of being hung: `settle`
        # dispatches whatever the window manager has queued and comes back
        # early if something arrived.
        _ = settle(hwnd, 10)
    return String("no references arrived")


def references_report(hwnd: Int) raises -> String:
    """The references, one per line, the way the issues pane lists them.

    Args:
        hwnd: The window.

    Returns:
        `references N` and then a line each.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    var total = reference_count()
    var out = String("references ") + String(total) + "\n"
    if doc[].pane_mode != PANE_REFERENCES:
        out = (
            String("references (pane not showing them) ") + String(total)
            + "\n"
        )
    for i in range(total):
        # The file's own name rather than the whole URI: a reference list is
        # read at a glance and a URI is sixty characters of prefix.
        var uri = reference_uri(i)
        var cut = uri.rfind("/")
        var name = String(uri[byte=cut + 1 :]) if cut >= 0 else uri
        out += (
            name + ":" + String(reference_line(i) + 1) + ":"
            + String(reference_character(i) + 1) + "\n"
        )
    return out^


def goto_reference(hwnd: Int, n: Int) raises -> String:
    """Go to the nth reference, one-based, the way the pane numbers them.

    Args:
        hwnd: The window.
        n: Which one.

    Returns:
        Where it went, or why it did not.

    Raises:
        If the window has no document.
    """
    var total = reference_count()
    if total == 0:
        return String("no references")
    if n < 1 or n > total:
        return String("there are ") + String(total) + " references"
    return jump_to(
        hwnd,
        reference_uri(n - 1),
        reference_line(n - 1),
        reference_character(n - 1),
    )


def pane_problems(hwnd: Int) raises -> String:
    """Put the issues pane back to showing problems.

    Args:
        hwnd: The window.

    Returns:
        That it is back.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    doc[].pane_mode = PANE_ISSUES
    _touch(hwnd)
    return String("pane showing problems")


# ===----------------------------------------------------------------------===#
# Saving
#
# Milestone 3. An editor that cannot write a file is a viewer, and every
# sprint up to here has built a very good viewer.
#
# Written whole rather than incrementally: the rope knows its text and a file
# is small next to the machinery that would track which bytes changed. A
# 104 MB document takes as long to write as the disk takes, which is the right
# answer and the only honest one -- an editor that streams a partial file to
# disk to save a few milliseconds has invented a new way to lose work.
# ===----------------------------------------------------------------------===#


def document_path(hwnd: Int) raises -> String:
    """The file this window's document came from, or an empty string.

    Args:
        hwnd: The window.

    Returns:
        The path, or empty if this document has never been on disk.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    if doc[].uri.byte_length() == 0:
        return String("")
    return path_of_uri(doc[].uri)


def save_as(hwnd: Int, path: String) raises -> String:
    """Write the document to `path` and make that its home.

    Args:
        hwnd: The window.
        path: Where to write.

    Returns:
        What happened.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    var text = doc[].rope.to_string()
    try:
        with open(path, "w") as f:
            # The mark goes back if it was there. Three bytes nobody looks at,
            # and a diff nobody wanted if they vanish.
            if _doc_at(hwnd)[].had_bom:
                # One codepoint, not three bytes spelled as codepoints:
                # U+FEFF is what EF BB BF encodes, and writing 0xEF, 0xBB and
                # 0xBF as characters produces their own UTF-8 encodings --
                # six bytes of mojibake at the head of the file.
                f.write(String(chr(0xFEFF)))
            f.write(text)
    except err:
        return String("cannot write ") + path + ": " + String(err)

    doc[].saved_depth = len(doc[].past)
    doc[].disk_stamp = file_stamp(path)
    restate_dirty(doc[])
    var full = absolute(path)
    var was = doc[].uri
    doc[].uri = file_uri(full)
    if doc[].uri != was:
        # Saved somewhere else: as far as the server is concerned that is a
        # different document, and the old URI's diagnostics are about a file
        # this window is no longer showing.
        #
        # No didSave for the unmoved case, deliberately. The server is already
        # told about every edit by didChange, so a save changes nothing it
        # knows; sending didSave would be protocol for its own sake.
        doc[].sent_version = 0
        try:
            announce(hwnd)
        except:
            pass
    retitle(hwnd)
    _touch(hwnd)
    return (
        String("saved ") + full + " (" + String(text.byte_length())
        + " bytes)"
    )


def save(hwnd: Int) raises -> String:
    """Write the document back where it came from.

    A document with no path has nowhere to go; the caller asks for one. That
    is the difference between Save and Save As, and it belongs at the point
    where a person can be asked rather than buried here.

    Args:
        hwnd: The window.

    Returns:
        What happened, or that there is nowhere to save to.

    Raises:
        If the window has no document.
    """
    var path = document_path(hwnd)
    if path.byte_length() == 0:
        return String("this document has no file; use save as <path>")
    return save_as(hwnd, path)


def is_dirty(hwnd: Int) raises -> Bool:
    """Whether the document has unsaved changes.

    Args:
        hwnd: The window.

    Returns:
        True when there is work not on disk.

    Raises:
        If the window has no document.
    """
    return _doc_at(hwnd)[].dirty


def retitle(hwnd: Int) raises:
    """Put the file's name and its dirty mark in the title bar.

    The one place a person looks to find out whether their work is safe, and
    the convention every editor shares: a leading bullet means unsaved. It is
    updated on every edit, which costs a SetWindowTextW on a string that is
    usually the same -- Windows compares and does nothing when it matches.

    Args:
        hwnd: The window.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    var path = document_path(hwnd)
    var name = String("untitled")
    if path.byte_length() > 0:
        var cut = path.rfind(chr(0x5C))
        name = String(path[byte=cut + 1 :]) if cut >= 0 else path
    var title = String("")
    if doc[].dirty:
        title += chr(0x2022) + " "  # bullet
    title += name + "  --  Griddle"

    var SetWindowTextW = win32[
        def (Int, Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> c_int,
        "SetWindowTextW",
    ]()
    var units = List[UInt16]()
    for ch in title.codepoints():
        var v = Int(ch)
        if v >= 0x10000:
            var u = v - 0x10000
            units.append(UInt16(0xD800 + (u >> 10)))
            units.append(UInt16(0xDC00 + (u & 0x3FF)))
        else:
            units.append(UInt16(v))
    units.append(0)
    _ = SetWindowTextW(
        hwnd, units.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    )
    _ = units


# ===----------------------------------------------------------------------===#
# The file dialogs
#
# `IFileOpenDialog` and `IFileSaveDialog`, which is the modern pair -- the
# `GetOpenFileNameW` a lot of code still reaches for has been the compatibility
# path since Vista and does not get the places bar, the search box or the
# breadcrumb.
#
# Both classes implement `IFileDialog`, so Show, SetFileName and GetResult are
# one code path and only the class ID differs. Every slot comes from
# windows_api.db; nothing here counts vtable entries. spikes/com's
# s06_apartment_activation proved the activation before any of this was built.
# ===----------------------------------------------------------------------===#

# The metadata carries the interfaces but not the class IDs -- its guid-kind
# constants are present and valueless, a recorded gap -- so these two are
# written once, here, beside their names.
comptime CLSID_FileOpenDialog = "dc1c5a9c-e88a-4dde-a5a1-60f82a20aef7"
comptime CLSID_FileSaveDialog = "c0b4e2f3-ba21-4773-8dba-335ec946eb8b"

# SIGDN_FILESYSPATH, an enumerator whose value the database does not carry.
comptime SIGDN_FILESYSPATH = 0x80058000


def _utf16z(s: String) -> List[UInt16]:
    """A NUL-terminated UTF-16 copy of a string, for a PCWSTR parameter."""
    var units = List[UInt16]()
    for ch in s.codepoints():
        var v = Int(ch)
        if v >= 0x10000:
            var u = v - 0x10000
            units.append(UInt16(0xD800 + (u >> 10)))
            units.append(UInt16(0xDC00 + (u & 0x3FF)))
        else:
            units.append(UInt16(v))
    units.append(0)
    return units^


def _shell_item_path(item: Int) raises -> String:
    """The filesystem path of an IShellItem, or an empty string.

    Args:
        item: The shell item the dialog returned.

    Returns:
        The path.

    Raises:
        If the call cannot be made.
    """
    if item == 0:
        return String("")
    var this = OpaquePointer[MutUntrackedOrigin](unsafe_from_address=item)
    var wide_path = Int(0)
    var hr = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> Int32,
        "IShellItem",
        "GetDisplayName",
    ](this)(this, UInt32(SIGDN_FILESYSPATH), com_addr(wide_path))
    if hr != 0 or wide_path == 0:
        return String("")

    var out = String("")
    var p = Pointer[UInt16, MutAnyOrigin](unsafe_from_address=wide_path)
    var i = 0
    while True:
        var unit = Int(p[i])
        if unit == 0:
            break
        # A path outside the basic plane is legal and vanishingly rare; the
        # surrogate pair is reassembled rather than dropped, because a path
        # that is nearly right is worse than one that is obviously wrong.
        if unit >= 0xD800 and unit <= 0xDBFF:
            var lo = Int(p[i + 1])
            if lo >= 0xDC00 and lo <= 0xDFFF:
                out += chr(0x10000 + ((unit - 0xD800) << 10) + (lo - 0xDC00))
                i += 2
                continue
        out += chr(unit)
        i += 1

    # The dialog allocated this with the task allocator; it is ours to free.
    var CoTaskMemFree = win32[
        def (Int) thin abi("C") -> NoneType, "CoTaskMemFree"
    ]()
    CoTaskMemFree(wide_path)
    return out^


def _ask(dialog: Int, hwnd: Int, suggested: String) raises -> String:
    """Show a file dialog and return the chosen path, or an empty string.

    Args:
        dialog: An IFileDialog, from either class.
        hwnd: The owner, so the dialog is modal to the editor rather than
            free-floating -- an editor whose Save dialog can be lost behind it
            is one that loses work.
        suggested: A name to start with, or empty.

    Returns:
        The chosen path, or empty when cancelled.

    Raises:
        If a call cannot be made.
    """
    if dialog == 0:
        return String("")
    var this = OpaquePointer[MutUntrackedOrigin](unsafe_from_address=dialog)

    if suggested.byte_length() > 0:
        var name = _utf16z(suggested)
        _ = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin],
                Pointer[UInt16, MutAnyOrigin],
            ) thin abi("C") -> Int32,
            "IFileDialog",
            "SetFileName",
        ](this)(
            this, name.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
        )
        _ = name

    # Show returns S_OK when something was chosen and
    # HRESULT_FROM_WIN32(ERROR_CANCELLED) -- 0x800704C7 -- when the person
    # said no. Cancelling is not an error and must not read as one.
    var shown = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin], Int) thin abi("C") -> Int32,
        "IFileDialog",
        "Show",
    ](this)(this, hwnd)
    if shown != 0:
        return String("")

    var item = Int(0)
    var got = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Pointer[Int, MutAnyOrigin]
        ) thin abi("C") -> Int32,
        "IFileDialog",
        "GetResult",
    ](this)(this, com_addr(item))
    if got != 0 or item == 0:
        return String("")

    var path = _shell_item_path(item)
    # GetResult handed us a reference; the dialog's own is not ours.
    _ = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> UInt32,
        "IUnknown",
        "Release",
    ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=item))(
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=item)
    )
    return path^


def open_dialog(hwnd: Int) raises -> String:
    """Ask for a file and open it.

    Args:
        hwnd: The window.

    Returns:
        What happened, or that nothing was chosen.

    Raises:
        If the dialog cannot be created.
    """
    var dialog = co_create[CLSID_FileOpenDialog, "IFileDialog"]()
    var path = _ask(dialog.address(), hwnd, String(""))
    if path.byte_length() == 0:
        return String("nothing opened")
    return open_path(hwnd, path)


def save_dialog(hwnd: Int) raises -> String:
    """Ask where to write, and write there.

    Args:
        hwnd: The window.

    Returns:
        What happened, or that nothing was chosen.

    Raises:
        If the dialog cannot be created.
    """
    var current = document_path(hwnd)
    var name = String("untitled.mojo")
    if current.byte_length() > 0:
        var cut = current.rfind(chr(0x5C))
        name = String(current[byte=cut + 1 :]) if cut >= 0 else current
    var dialog = co_create[CLSID_FileSaveDialog, "IFileDialog"]()
    var path = _ask(dialog.address(), hwnd, name)
    if path.byte_length() == 0:
        return String("not saved")
    return save_as(hwnd, path)


# ===----------------------------------------------------------------------===#
# Build and run
#
# Milestone 4. The command is composed here because this is where the document
# and its path are; ide/build.mojo knows about processes and pipes and nothing
# about which file is open.
# ===----------------------------------------------------------------------===#


def _toolchain() raises -> Tuple[String, String]:
    """The mojo compiler and the stdlib to build against.

    Overridable by environment for the same reason the language server's path
    is: a check, a release and a working tree disagree about where the
    toolchain lives, and none of them should have to patch a source file.

    Returns:
        The compiler path and the stdlib path, both absolute.

    Raises:
        Never in practice.
    """
    var exe = String(env_or("WINMOJO_MOJO", ""))
    if exe.byte_length() == 0:
        # From the toolchain module rather than spelled here, so that the
        # compiler a build runs is by construction the one the Toolchain view
        # names. Two places spelling the same path is two places to be wrong
        # in, and the failure is the confusing kind: a view that says the
        # toolchain is fine beside a build that cannot find it.
        exe = component_path(String("compiler"))
        if exe.byte_length() == 0:
            exe = String("bazel-bin/KGEN/tools/mojo/mojo.exe")
    var stdlib = String(env_or("WINMOJO_STDLIB", ""))
    if stdlib.byte_length() == 0:
        stdlib = component_path(String("stdlib"))
        if stdlib.byte_length() == 0:
            stdlib = String("mojo/stdlib")
    return (absolute(exe), absolute(stdlib))


def run_file(hwnd: Int) raises -> String:
    """Run the open document, with its output in the output pane.

    Args:
        hwnd: The window.

    Returns:
        What was started, or why it was not.

    Raises:
        If the process cannot be created.
    """
    var path = document_path(hwnd)
    if path.byte_length() == 0:
        return String("save the file first; there is nothing to run")
    # Saved first, deliberately. Running the version on disk while the window
    # shows a different one is how a person spends ten minutes debugging an
    # edit they had not saved.
    if is_dirty(hwnd):
        var wrote = save(hwnd)
        if not wrote.startswith("saved"):
            return wrote
    var tools = _toolchain()
    return start_build(
        '"' + tools[0] + '" run -I "' + tools[1] + '" -I .'
        + _extra_flags() + ' "' + path + '"'
    )


def build_file(hwnd: Int) raises -> String:
    """Compile the open document to an executable beside it.

    Args:
        hwnd: The window.

    Returns:
        What was started, or why it was not.

    Raises:
        If the process cannot be created.
    """
    var path = document_path(hwnd)
    if path.byte_length() == 0:
        return String("save the file first; there is nothing to build")
    if is_dirty(hwnd):
        var wrote = save(hwnd)
        if not wrote.startswith("saved"):
            return wrote
    var out = path
    if out.endswith(".mojo"):
        var stem = String(out[byte=0 : out.byte_length() - 5])
        out = stem^
    out += ".exe"
    var tools = _toolchain()
    return start_build(
        '"' + tools[0] + '" build --no-optimization -I "' + tools[1]
        + '" -I .' + _extra_flags() + ' -o "' + out + '" "' + path + '"'
    )


def build_poll(hwnd: Int) raises -> Bool:
    """Take whatever the child has written and repaint if anything came.

    Args:
        hwnd: The window.

    Returns:
        True if the pane changed.

    Raises:
        If a pipe read fails.
    """
    var changed = poll_build()
    if changed:
        _touch(hwnd)
    return changed


def build_wait(hwnd: Int, milliseconds: Int) raises -> String:
    """Pump until the run finishes, or the time runs out.

    Args:
        hwnd: The window.
        milliseconds: How long to wait.

    Returns:
        The output, or that it is still going.

    Raises:
        If a pipe read fails.
    """
    var deadline = perf_counter_ns() + milliseconds * 1_000_000
    while perf_counter_ns() < deadline:
        _ = build_poll(hwnd)
        if not is_building():
            return output_report(hwnd)
        _ = settle(hwnd, 10)
    return String("still running after ") + String(milliseconds) + " ms"


def output_report(hwnd: Int) raises -> String:
    """The output pane as text, the way the pane shows it.

    Args:
        hwnd: The window.

    Returns:
        `output N` and then a line each.

    Raises:
        Never in practice.
    """
    _ = hwnd
    var total = output_count()
    var out = String("output ") + String(total) + "\n"
    for i in range(total):
        out += output_line(i) + "\n"
    return out^


# ===----------------------------------------------------------------------===#
# Closing
# ===----------------------------------------------------------------------===#

# MessageBox's flags and answers are #defines in winuser.h rather than an
# enumeration, so the metadata has no rows for them and they are named here.
comptime MB_YESNOCANCEL = 0x00000003
comptime MB_ICONWARNING = 0x00000030
comptime IDCANCEL = 2
comptime IDYES = 6
comptime IDNO = 7


comptime g_unattended = named_global["ide.unattended", Int]


def set_unattended(on: Bool):
    """Say that nobody is watching, so nothing may wait for an answer.

    A modal dialog in an unattended run is a hang with a friendly face: the
    check suite would sit on "Save before closing?" until it was killed. The
    `--cmd` path sets this, and every question in the editor has to honour it
    or it is not honoured at all.

    Args:
        on: Whether this is an unattended run.
    """
    g_unattended()[] = 1 if on else 0


def is_unattended() -> Bool:
    """Whether this run has nobody to ask.

    Returns:
        True when `--cmd` drove the process.
    """
    return g_unattended()[] != 0


def confirm_close_all(hwnd: Int) raises -> Bool:
    """Whether it is all right to close the window, asking about every tab.

    Each dirty document is brought to the front before it is asked about, so
    the question is never about a file the person cannot see. Cancel on any
    one of them calls off the whole close and leaves that document showing,
    which is where they will want to be.

    Args:
        hwnd: The window.

    Returns:
        True to go ahead and close.

    Raises:
        If the window has no chrome.
    """
    if tab_count() <= 1:
        return confirm_close(hwnd)
    var i = 0
    while i < tab_count():
        var address = tab_doc(i)
        var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)
        if doc[].dirty:
            _ = switch_tab(hwnd, i)
            if not confirm_close(hwnd):
                return False
        i += 1
    return True


def confirm_close(hwnd: Int) raises -> Bool:
    """Whether it is all right to close, asking if there is unsaved work.

    Three answers and not two, because "do you want to lose this" with only
    yes and no forces a person who misclicked to lose it. Yes saves, No
    discards deliberately, Cancel goes back to the editor.

    A document with nowhere to save to sends Yes through the Save As dialog,
    and a person who cancels *that* has not agreed to lose anything either --
    so the close is called off rather than quietly completed.

    Args:
        hwnd: The window.

    Returns:
        True to go ahead and close.

    Raises:
        If the window has no document.
    """
    if not is_dirty(hwnd):
        return True
    if is_unattended():
        # Nobody to ask. Closing wins over prompting, because the alternative
        # is a check suite stopped on a dialog nobody will ever click.
        return True

    var path = document_path(hwnd)
    var name = String("This document")
    if path.byte_length() > 0:
        var cut = path.rfind(chr(0x5C))
        name = String(path[byte=cut + 1 :]) if cut >= 0 else path
    var text = _utf16z(
        name + " has unsaved changes.\n\nSave before closing?"
    )
    var caption = _utf16z(String("Griddle"))

    var MessageBoxW = win32[
        def (
            Int,
            Pointer[UInt16, MutAnyOrigin],
            Pointer[UInt16, MutAnyOrigin],
            UInt32,
        ) thin abi("C") -> c_int,
        "MessageBoxW",
    ]()
    var answer = Int(
        MessageBoxW(
            hwnd,
            text.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            caption.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            UInt32(MB_YESNOCANCEL | MB_ICONWARNING),
        )
    )
    _ = text
    _ = caption

    if answer == IDNO:
        return True
    if answer == IDCANCEL:
        return False
    # IDYES, and anything else: the safe reading of an answer we did not
    # expect is that the work should be kept.
    var wrote = save_dialog(hwnd) if path.byte_length() == 0 else save(hwnd)
    return wrote.startswith("saved")


# ===----------------------------------------------------------------------===#
# Tabs
#
# A tab is a `Doc`, and the window shows whichever one `chrome.doc` points at.
# That is the whole mechanism: every function in this module already reaches
# its document through `_doc_at`, so switching tabs is one assignment and
# nothing else had to learn about tabs at all. The single-document design
# turned out to be the tabbed one with a list of length one.
#
# Documents are never freed. A person opens tens of files in a session, not
# millions, and a Doc holds a rope whose nodes are shared with its own undo
# history -- freeing one correctly means proving nothing else holds a node,
# which is work with no benefit at this size. Closing a tab forgets it.
# ===----------------------------------------------------------------------===#

comptime g_tabs = named_global["ide.tabs", List[Int]]
comptime g_tab = named_global["ide.tab", Int]


def tab_count() -> Int:
    """How many documents are open.

    Returns:
        The count.
    """
    return len(g_tabs()[])


def current_tab() -> Int:
    """Which tab is showing.

    Returns:
        Its index, or -1 when none are open.
    """
    var n = len(g_tabs()[])
    if n == 0:
        return -1
    var i = g_tab()[]
    return 0 if i < 0 or i >= n else i


def tab_doc(i: Int) -> Int:
    """The document address behind a tab.

    Args:
        i: Its index.

    Returns:
        The address, or zero.
    """
    var tabs = g_tabs()
    if i < 0 or i >= len(tabs[]):
        return 0
    return tabs[][i]


def tab_name(i: Int) raises -> String:
    """The file name a tab shows, with a bullet when it has unsaved work.

    Args:
        i: Its index.

    Returns:
        The label.

    Raises:
        Never in practice.
    """
    var address = tab_doc(i)
    if address == 0:
        return String("")
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)
    var name = String("untitled")
    if doc[].uri.byte_length() > 0:
        var path = path_of_uri(doc[].uri)
        var cut = path.rfind(chr(0x5C))
        name = String(path[byte=cut + 1 :]) if cut >= 0 else path
    return (chr(0x2022) + " " + name) if doc[].dirty else name


def adopt_tab(hwnd: Int, address: Int) raises -> Int:
    """Take an already-built document as a new tab, and show it.

    Used at startup for the document `main` built, so the first tab and every
    later one are the same kind of thing.

    Args:
        hwnd: The window.
        address: The document.

    Returns:
        The new tab's index.

    Raises:
        If the window has no chrome.
    """
    var tabs = g_tabs()
    tabs[].append(address)
    var index = len(tabs[]) - 1
    _ = switch_tab(hwnd, index)
    return index


def switch_tab(hwnd: Int, i: Int) raises -> String:
    """Show a different tab.

    Args:
        hwnd: The window.
        i: Which one.

    Returns:
        What is showing now.

    Raises:
        If the window has no chrome.
    """
    var address = tab_doc(i)
    if address == 0:
        return String("no such tab")
    var bits = _bits(hwnd)
    var chrome = Pointer[Chrome, MutAnyOrigin](unsafe_from_address=bits[1])
    chrome[].doc = address
    g_tab()[] = i
    # The layout cache belongs to the document, so nothing has to be dropped;
    # the new document's own cache is either warm or will be after one frame.
    try:
        retitle(hwnd)
    except:
        pass
    _touch(hwnd)
    return String("tab ") + String(i + 1) + " of " + String(
        tab_count()
    ) + ": " + tab_name(i)


def tab_for_uri(uri: String) raises -> Int:
    """Which tab is showing a URI, or -1.

    Args:
        uri: The document's URI.

    Returns:
        The index, or -1.

    Raises:
        Never in practice.
    """
    var tabs = g_tabs()
    for i in range(len(tabs[])):
        var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=tabs[][i])
        if doc[].uri == uri:
            return i
    return -1


def next_tab(hwnd: Int, by: Int) raises -> String:
    """Move to the next or previous tab, wrapping.

    Args:
        hwnd: The window.
        by: 1 for the next, -1 for the one before.

    Returns:
        What is showing now.

    Raises:
        If the window has no chrome.
    """
    var n = tab_count()
    if n < 2:
        return String("only one document is open")
    return switch_tab(hwnd, (current_tab() + by + n) % n)


def close_tab(hwnd: Int) raises -> String:
    """Close the tab that is showing, if its work is safe.

    The last tab is not closed: an editor with no document has nothing to
    draw and no way back. Closing it means closing the window, which is a
    different decision and belongs to the person, not to Ctrl+W.

    Args:
        hwnd: The window.

    Returns:
        What happened.

    Raises:
        If the window has no chrome.
    """
    var n = tab_count()
    if n <= 1:
        return String("this is the only document; close the window instead")
    if not confirm_close(hwnd):
        return String("not closed")
    var i = current_tab()
    var tabs = g_tabs()
    _ = tabs[].pop(i)
    var next = i
    if next >= len(tabs[]):
        next = len(tabs[]) - 1
    return switch_tab(hwnd, next)


def tabs_report(hwnd: Int) raises -> String:
    """Every tab, in order, with the current one marked.

    Args:
        hwnd: The window.

    Returns:
        `tabs N` and a line each.

    Raises:
        Never in practice.
    """
    _ = hwnd
    var out = String("tabs ") + String(tab_count()) + "\n"
    for i in range(tab_count()):
        out += (
            ("*" if i == current_tab() else " ") + " " + String(i + 1) + ". "
            + tab_name(i) + "\n"
        )
    return out^


# ===----------------------------------------------------------------------===#
# Zoom
#
# Three functions that set one number. Everything that follows -- the font, the
# gutter, the rail, the row height, the panes -- follows because it is all
# multiplied by that number in `scaled`. The rebuild is the caller's, because
# only griddle.mojo can reach the chrome to rebuild it.
# ===----------------------------------------------------------------------===#


def zoom_report(hwnd: Int) raises -> String:
    """What the zoom is, as a percentage a person recognises.

    Args:
        hwnd: The window.

    Returns:
        The zoom, and the scale it combines with.

    Raises:
        Never in practice.
    """
    return (
        String("zoom ") + String(Int(zoom() * 100.0 + 0.5)) + "%  scale "
        + String(dpi_scale(hwnd))
    )


def zoom_in(hwnd: Int) raises -> String:
    """Draw everything a step bigger.

    Args:
        hwnd: The window.

    Returns:
        The new zoom.

    Raises:
        If Direct2D cannot be brought up at the new scale.
    """
    _ = set_zoom(zoom() + ZOOM_STEP)
    rescale(hwnd)
    return zoom_report(hwnd)


def zoom_out(hwnd: Int) raises -> String:
    """Draw everything a step smaller.

    Args:
        hwnd: The window.

    Returns:
        The new zoom.

    Raises:
        If Direct2D cannot be brought up at the new scale.
    """
    _ = set_zoom(zoom() - ZOOM_STEP)
    rescale(hwnd)
    return zoom_report(hwnd)


def zoom_reset(hwnd: Int) raises -> String:
    """Back to the display's own scale.

    Args:
        hwnd: The window.

    Returns:
        The new zoom.

    Raises:
        If Direct2D cannot be brought up at the new scale.
    """
    _ = set_zoom(1.0)
    rescale(hwnd)
    return zoom_report(hwnd)


def rescale(hwnd: Int) raises:
    """Rebuild everything the display scale is baked into.

    The font size is inside the text format and every cached line layout was
    made with that format, so a scale that changes cannot be applied to what
    is already there -- it has to be built again. That is the same work a lost
    device needs, so it goes through the same function, and the DPI change and
    the zoom keys share one path instead of each having a version of it.

    Args:
        hwnd: The window.

    Raises:
        If Direct2D cannot be brought up at the new scale.
    """
    var GetWindowLongPtrW = win32[
        def (Int, c_int) thin abi("C") -> Int, "GetWindowLongPtrW"
    ]()
    var stored = GetWindowLongPtrW(
        hwnd, c_int(winkb_constant["GWLP_USERDATA"]())
    )
    if stored == 0:
        return
    var chrome = Pointer[Chrome, MutAnyOrigin](unsafe_from_address=stored)
    var GetClientRect = win32[
        def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
        "GetClientRect",
    ]()
    var rc = RECT()
    _ = GetClientRect(hwnd, Pointer(to=rc).unsafe_origin_cast[MutAnyOrigin]())
    recreate(
        chrome, hwnd, Int(rc.right - rc.left), Int(rc.bottom - rc.top)
    )
    if chrome[].doc != 0:
        Pointer[Doc, MutAnyOrigin](
            unsafe_from_address=chrome[].doc
        )[].grid.line_height = scaled(LINE_H, chrome[].scale)
    var InvalidateRect = win32[
        def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
    ]()
    _ = InvalidateRect(hwnd, 0, c_int(0))


def recreate(chrome: Pointer[Chrome, MutAnyOrigin], hwnd: Int, width: Int,
             height: Int) raises:
    """Build a new render target after the device was lost.

    The window's own state -- the document, the drop target -- survives; only
    Direct2D's objects are rebuilt. Cached text layouts go too: they were made
    by the old DirectWrite factory, and outliving it is not a risk worth
    taking for one frame's worth of work.

    Args:
        chrome: The window's chrome, replaced in place.
        hwnd: The window to make a target for.
        width: Client width.
        height: Client height.

    Raises:
        If Direct2D cannot be brought up again.
    """
    print("griddle: device lost, rebuilding the render target")
    var doc = chrome[].doc
    var drop = chrome[].drop_target
    if doc != 0:
        release_cache(Pointer[Doc, MutAnyOrigin](unsafe_from_address=doc)[].grid)
    var immediate = chrome[].immediate
    release(chrome[])
    chrome[] = bring_up(hwnd, width, height, immediate)
    chrome[].doc = doc
    chrome[].drop_target = drop


# ===----------------------------------------------------------------------===#
# Searching the project, and noticing it change
# ===----------------------------------------------------------------------===#


def find_needle(hwnd: Int) raises -> String:
    """What was last searched for in this document.

    Ctrl+Shift+F searches the project for it, so finding something in a file
    and then asking where else it appears is two keystrokes rather than
    retyping it.

    Args:
        hwnd: The window.

    Returns:
        The needle, or empty.

    Raises:
        If the window has no document.
    """
    return _doc_at(hwnd)[].needle


def search_in_project(hwnd: Int, needle: String) raises -> String:
    """Search every file under the project root and list the hits.

    The results go into the output pane rather than a pane of their own. A hit
    is written `path:line:col: text`, which is what a compiler writes, which
    is what the pane's click handler already parses -- so every result is
    clickable without a line of new interface. Reusing the shape a tool
    already speaks is cheaper than teaching the editor a second one.

    Args:
        hwnd: The window.
        needle: The literal to look for.

    Returns:
        A summary line.

    Raises:
        If the project cannot be read.
    """
    if needle.byte_length() == 0:
        return String("nothing to search for")
    var root = project_root()
    if root.byte_length() == 0:
        return String("no project; use tree root <path>")

    var found = search_project(root, needle)
    clear_output()
    append_output(
        String("searching ") + root + " for " + repr(needle) + "\n"
    )
    for i in range(hit_count()):
        append_output(
            hit_path(i) + ":" + String(hit_line(i) + 1) + ":"
            + String(hit_column(i) + 1) + ": " + hit_text(i) + "\n"
        )
    var summary = (
        String("\n[") + String(found) + " hits in "
        + String(searched_files()) + " files"
    )
    if hit_truncated():
        summary += ", stopped at the limit"
    summary += "]\n"
    append_output(summary^)
    _touch(hwnd)
    return (
        String("found ") + String(found) + " in "
        + String(searched_files()) + " files"
    )


def watch_project(hwnd: Int) raises -> String:
    """Start watching the project root for changes on disk.

    Args:
        hwnd: The window.

    Returns:
        What happened.

    Raises:
        If the directory cannot be watched.
    """
    _ = hwnd
    var root = project_root()
    if root.byte_length() == 0:
        return String("no project to watch")
    return watch_directory(root)


def poll_disk(hwnd: Int) raises -> Bool:
    """Notice anything that changed on disk, and react to it.

    Called from the window's timer. Two different questions get asked here
    because they have two different answers: the tree cares that *something*
    under the project changed, and the open document cares whether that
    something was itself.

    Args:
        hwnd: The window.

    Returns:
        True if anything was done.

    Raises:
        Never in practice; failures are reported rather than raised.
    """
    if not poll_changes():
        return False
    try:
        _ = refresh()
    except:
        pass

    # And the document being edited. A file that changed underneath a clean
    # document is reloaded without asking, because there is nothing to lose
    # and an editor showing stale text is worse than one that moved. A dirty
    # document is left alone and the person is told -- choosing for them which
    # copy survives is not the editor's decision to make.
    try:
        var doc = _doc_at(hwnd)
        var path = document_path(hwnd)
        if path.byte_length() > 0:
            var now = file_stamp(path)
            # A stamp of zero means this document has never been compared
            # against its file. Record it rather than treating it as a
            # change: the first observation is not evidence of anything, and
            # calling it one would reload every document a second after it
            # opened.
            if now != 0 and doc[].disk_stamp == 0:
                doc[].disk_stamp = now
            elif now != 0 and now != doc[].disk_stamp:
                doc[].disk_stamp = now
                if doc[].dirty:
                    append_output(
                        String("\n[") + path
                        + " changed on disk; your version is unsaved]\n"
                    )
                else:
                    var line = doc[].caret_line
                    _ = reload_document(hwnd)
                    _ = caret_move(hwnd, line, 0)
                    append_output(
                        String("\n[") + path + " changed on disk; reloaded]\n"
                    )
    except:
        pass
    _touch(hwnd)
    return True


def stamp_report(hwnd: Int) raises -> String:
    """The document's remembered file stamp against the file's current one.

    Args:
        hwnd: The window.

    Returns:
        Both numbers and the path they are about.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    var path = document_path(hwnd)
    return (
        String("stamp remembered=") + String(doc[].disk_stamp)
        + " ondisk=" + String(file_stamp(path) if path.byte_length() > 0 else 0)
        + " watching=" + String(watching())
        + " path=" + path
    )


def reload_document(hwnd: Int) raises -> String:
    """Read the open document's file again, discarding what is in memory.

    Only ever called for a document with nothing to lose. The undo history
    goes: its snapshots describe a text this document no longer holds, and
    restoring one would put the old file back on screen and call it an undo.

    Args:
        hwnd: The window.

    Returns:
        What happened.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    var path = document_path(hwnd)
    if path.byte_length() == 0:
        return String("this document has no file")
    var text = String("")
    try:
        with open(path, "r") as f:
            text = f.read()
    except err:
        return String("cannot reread ") + path + ": " + String(err)
    doc[].rope = Rope(text^)
    doc[].revision += 1
    doc[].past = List[Snapshot]()
    doc[].future = List[Snapshot]()
    doc[].saved_depth = 0
    doc[].disk_stamp = file_stamp(path)
    restate_dirty(doc[])
    release_cache(doc[].grid)
    _touch(hwnd)
    return String("reloaded ") + path


# ===----------------------------------------------------------------------===#
# Breakpoints
#
# Kept on the document, sorted, zero-based. On the document because a
# breakpoint outlives a debug session: you set one, run, fix something, run
# again, and it is still where you put it.
# ===----------------------------------------------------------------------===#


def toggle_breakpoint(
    hwnd: Int, line: Int, condition: String = String("")
) raises -> String:
    """Put a breakpoint on a line, or take it off.

    Args:
        hwnd: The window.
        line: Zero-based. A negative line means the caret's own.
        condition: An expression the debugger evaluates before stopping, or
            empty to stop every time.

    Returns:
        What happened.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    var at = doc[].caret_line if line < 0 else line
    if at < 0 or at >= doc[].rope.line_count():
        return String("no such line")
    for i in range(len(doc[].breakpoints)):
        if doc[].breakpoints[i] == at:
            _ = doc[].breakpoints.pop(i)
            if i < len(doc[].breakpoint_conditions):
                _ = doc[].breakpoint_conditions.pop(i)
            _touch(hwnd)
            return String("breakpoint cleared at ") + String(at + 1)
    # Kept in order so the gutter and any list read the same way round, and so
    # the debugger receives them in the order a person would write them.
    var where = len(doc[].breakpoints)
    for i in range(len(doc[].breakpoints)):
        if doc[].breakpoints[i] > at:
            where = i
            break
    doc[].breakpoints.insert(where, at)
    doc[].breakpoint_conditions.insert(where, condition)
    _touch(hwnd)
    if condition.byte_length() > 0:
        # Said out loud, because a conditional breakpoint that silently
        # behaves like an unconditional one is worse than no feature: a person
        # would sit through every iteration wondering what they got wrong.
        return (
            String("breakpoint set at ") + String(at + 1) + " when "
            + condition
            + "  (this toolchain's debugger ignores conditions and will stop"
            + " every time -- see docs/debugger-conditions.md)"
        )
    return String("breakpoint set at ") + String(at + 1)


def breakpoint_lines(hwnd: Int) raises -> List[Int]:
    """Every line in this document with a breakpoint, in order.

    Args:
        hwnd: The window.

    Returns:
        Zero-based line numbers.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    var out = List[Int]()
    for at in doc[].breakpoints:
        out.append(at)
    return out^


def breakpoints_report(hwnd: Int) raises -> String:
    """The breakpoints, one per line, as a person would read them.

    Args:
        hwnd: The window.

    Returns:
        A count and a line each.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    var out = String("breakpoints ") + String(len(doc[].breakpoints)) + "\n"
    for i in range(len(doc[].breakpoints)):
        var at = doc[].breakpoints[i]
        out += String(at + 1) + ": " + String(doc[].rope.line(at).strip())
        if (
            i < len(doc[].breakpoint_conditions)
            and doc[].breakpoint_conditions[i].byte_length() > 0
        ):
            out += "   when " + doc[].breakpoint_conditions[i]
        out += "\n"
    return out^


def clear_breakpoints(hwnd: Int) raises -> String:
    """Take every breakpoint off this document.

    Args:
        hwnd: The window.

    Returns:
        How many went.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    var had = len(doc[].breakpoints)
    doc[].breakpoints = List[Int]()
    _touch(hwnd)
    return String("cleared ") + String(had) + " breakpoints"



# ===----------------------------------------------------------------------===#
# Debugging
#
# The editor half. ide/dap.mojo speaks the protocol and holds the session;
# this decides what a person's keys mean, hands the debugger the breakpoints
# the document is carrying, and moves the caret to wherever execution stopped.
# ===----------------------------------------------------------------------===#


def _debug_tools() raises -> Tuple[String, String]:
    """Where lldb-dap and the Mojo LLDB plugin live.

    Overridable by environment for the same reason the compiler and the
    language server are: a release, a check and a working tree disagree about
    the layout, and none of them should have to patch a source file.

    Returns:
        The adapter and the plugin, both absolute.

    Raises:
        Never in practice.
    """
    var adapter = String(env_or("WINMOJO_DAP", ""))
    if adapter.byte_length() == 0:
        adapter = String(
            "bazel-bin/external/+llvm_configure+llvm-project/lldb/lldb-dap.exe"
        )
    var plugin = String(env_or("WINMOJO_LLDB_PLUGIN", ""))
    if plugin.byte_length() == 0:
        plugin = String("bazel-bin/KGEN/MojoLLDB.dll")
    return (absolute(adapter), absolute(plugin))


def debug_file(hwnd: Int) raises -> String:
    """Build the open document with symbols and start debugging it.

    A debug build is a different artifact from the one Run produces, and
    deliberately so: an optimized build deletes the locals a debugger exists to
    show, and the Mac team paid for that lesson twice. It goes to a separate
    path so switching between Run and Debug never silently rebuilds the other
    one's output.

    Args:
        hwnd: The window.

    Returns:
        What happened.

    Raises:
        If the compiler cannot be started.
    """
    var path = document_path(hwnd)
    if path.byte_length() == 0:
        return String("save the file first; there is nothing to debug")
    if is_dirty(hwnd):
        var wrote = save(hwnd)
        if not wrote.startswith("saved"):
            return wrote
    if debugging():
        # Already stopped somewhere: F5 means carry on, which is what it means
        # in every debugger and what a person pressing it again expects.
        resume()
        return String("continuing")

    var stem = path
    if stem.endswith(".mojo"):
        var cut = String(stem[byte=0 : stem.byte_length() - 5])
        stem = cut^
    var out = stem + ".debug.exe"
    var tools = _toolchain()
    # Symbols, always. Debug means --debug-level full and never anything else;
    # handing a debugger an optimized binary is how an afternoon disappears
    # into locals that are simply absent.
    g_debug_pending()[] = 1
    return start_build(
        '"' + tools[0] + '" build --no-optimization --debug-level full -I "'
        + tools[1] + '" -I .' + _extra_flags() + ' -o "' + out + '" "'
        + path + '"'
    ) + " (debug build; the debugger starts when it finishes)"


comptime g_debug_pending = named_global["ide.debugpending", Int]
comptime g_was_debugging = named_global["ide.wasdebugging", Int]


def debug_after_build(hwnd: Int) raises -> Bool:
    """Start the adapter once the debug build has finished.

    F5 cannot launch a debugger directly because there is nothing to launch
    until the compiler has produced a binary, and waiting for it would freeze
    the editor for the length of a build. So F5 starts a build and sets this
    flag, and the timer notices the build ending and takes it from there.

    Args:
        hwnd: The window.

    Returns:
        True if a session was started on this tick.

    Raises:
        Never in practice; failures are reported into the output pane.
    """
    if g_debug_pending()[] == 0 or is_building():
        return False
    g_debug_pending()[] = 0
    try:
        append_output(String("\n[") + debug_launch(hwnd) + "]\n")
    except err:
        append_output(String("\n[debugger failed: ") + String(err) + "]\n")
    _touch(hwnd)
    return True


def debug_launch(hwnd: Int) raises -> String:
    """Start the adapter on the debug build and send the breakpoints.

    Called once the debug build has finished, because there is nothing to
    debug until there is a binary.

    Args:
        hwnd: The window.

    Returns:
        What happened.

    Raises:
        If the adapter cannot be started.
    """
    var path = document_path(hwnd)
    if path.byte_length() == 0:
        return String("no file")
    var stem = path
    if stem.endswith(".mojo"):
        var cut = String(stem[byte=0 : stem.byte_length() - 5])
        stem = cut^
    var program = stem + ".debug.exe"

    # A binary that is not there is the difference between "no breakpoints
    # verified and nothing ever stops" and a sentence saying what is wrong.
    # lldb-dap attaches to a missing program without complaint and then simply
    # never halts, which reads as a broken debugger rather than a missing
    # build -- and is exactly what a stale debug build looks like.
    if file_stamp(program) == 0:
        return (
            String("no debug build at ") + program
            + "; press F5 to build one"
        )

    var tools = _debug_tools()
    var said = start_debug(tools[0], tools[1], program)

    # Every tab's breakpoints, not only the one on screen. DAP's
    # setBreakpoints is per source file and replaces that file's whole set, so
    # a debugger told about one file simply does not stop in the others --
    # which reads as breakpoints that silently do not work, and is the bug
    # tabs introduced the moment a second file could hold one.
    var verified = 0
    var asked = 0
    for tab in range(tab_count()):
        var address = tab_doc(tab)
        if address == 0:
            continue
        var other = Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)
        if len(other[].breakpoints) == 0:
            continue
        var where = path_of_uri(other[].uri)
        if where.byte_length() == 0:
            continue
        var lines = List[Int]()
        for at in other[].breakpoints:
            lines.append(at)
        var whens = List[String]()
        for when in other[].breakpoint_conditions:
            whens.append(when)
        asked += len(lines)
        var got = set_breakpoints(where, lines, whens)
        if got > 0:
            verified += got
    configuration_done()
    _doc_at(hwnd)[].pane_mode = PANE_VARIABLES
    _touch(hwnd)
    return (
        said + "; " + String(verified) + " of " + String(asked)
        + " breakpoints verified"
    )


def debug_stop(hwnd: Int) raises -> String:
    """End the session and put the pane back.

    Args:
        hwnd: The window.

    Returns:
        What happened.

    Raises:
        If the adapter cannot be shut down.
    """
    var said = stop_debug()
    _doc_at(hwnd)[].pane_mode = PANE_ISSUES
    _touch(hwnd)
    return said


def debug_step(hwnd: Int, which: String) raises -> String:
    """Step, in whichever of the three senses.

    Args:
        hwnd: The window.
        which: "over", "in" or "out".

    Returns:
        What happened.

    Raises:
        If the adapter refuses.
    """
    if not debugging():
        return String("nothing is being debugged")
    if which == "in":
        step_in()
    elif which == "out":
        step_out()
    else:
        step_over()
    return String("stepping ") + which


def debug_poll(hwnd: Int) raises -> Bool:
    """Drain the adapter and follow the debuggee.

    Called from the window's timer. When execution stops this opens the file
    it stopped in, puts the caret on the line and fills the variables pane --
    all of it, because a debugger that halts and leaves you to go and look is
    one you end up driving with two hands.

    Args:
        hwnd: The window.

    Returns:
        True if anything changed.

    Raises:
        Never in practice; failures are reported rather than raised.
    """
    var was = debug_serial()
    if not poll_debug():
        return False
    if debug_serial() == was:
        return False

    # A stop arrives as an event; the frames and locals arrive as answers to
    # the three requests the client fires on receiving it. Acting on the event
    # alone moves the caret to line zero of nowhere, because the stack has not
    # come back yet. Waiting for one frame is waiting for all of it: the
    # client chains stackTrace, scopes and variables in that order.
    if stopped() and frame_count() > 0:
        var source = stop_source()
        if source.byte_length() > 0:
            var here = document_path(hwnd)
            # Only move if it stopped somewhere else. Reopening the file that
            # is already showing would throw away the undo history for no
            # reason.
            if source != here:
                _ = open_path(hwnd, source)
            _ = caret_move(hwnd, stop_line(), 0)
            follow_caret(hwnd)
        var rows = List[String]()
        var frames = frame_count()
        for i in range(frames):
            var where = frame_source(i)
            var cut = where.rfind(chr(0x5C))
            var name = String(where[byte=cut + 1 :]) if cut >= 0 else where
            rows.append(
                "#" + String(i) + "  " + frame_name(i) + "   " + name + ":"
                + String(frame_line(i) + 1)
            )
        for i in range(variable_count()):
            rows.append(
                variable_name(i) + " = " + variable_value(i)
                + "   (" + variable_type(i) + ")"
            )
        set_variable_rows(rows^, frames)
        set_stop_line(stop_line(), True)
        try:
            clear_temporary_breakpoint(hwnd)
        except:
            pass
        _doc_at(hwnd)[].pane_mode = PANE_VARIABLES
    else:
        set_stop_line(-1, debugging())
        if not debugging():
            set_variable_rows(List[String](), 0)
            # A debug session that ends says so. Without this a person presses
            # F5, the program runs to completion, the marks quietly disappear
            # and nothing anywhere says whether it finished or fell over.
            if g_was_debugging()[] != 0:
                g_was_debugging()[] = 0
                append_output(String("\n[the debuggee ended]\n"))
                _doc_at(hwnd)[].pane_mode = PANE_ISSUES
        else:
            g_was_debugging()[] = 1
    _touch(hwnd)
    return True


def debug_report(hwnd: Int) raises -> String:
    """Where the debugger is, as text.

    Args:
        hwnd: The window.

    Returns:
        The session state, the stop and the variables.

    Raises:
        Never in practice.
    """
    _ = hwnd
    if not debugging():
        return String("debug: not running")
    if not stopped():
        return String("debug: running")
    var out = (
        String("debug: stopped (") + stop_reason() + ") at "
        + stop_source() + ":" + String(stop_line() + 1)
        + "  frames=" + String(frame_count())
        + " variables=" + String(variable_count()) + "\n"
    )
    for i in range(frame_count()):
        out += (
            "  #" + String(i) + " " + frame_name(i) + " ("
            + frame_source(i) + ":" + String(frame_line(i) + 1) + ")\n"
        )
    for i in range(variable_count()):
        out += (
            "  " + variable_name(i) + " = " + variable_value(i)
            + "  (" + variable_type(i) + ")\n"
        )
    return out^


def debug_wait(hwnd: Int, milliseconds: Int) raises -> String:
    """Pump until the debuggee stops, or the time runs out.

    Args:
        hwnd: The window.
        milliseconds: How long to wait.

    Returns:
        Where it stopped, or that it did not.

    Raises:
        Never in practice.
    """
    var deadline = perf_counter_ns() + milliseconds * 1_000_000
    # "No session" means two different things and they must not share an
    # answer. Before the debug build finishes there is nothing to attach to
    # yet; after it has run there is nothing left. Telling them apart is
    # remembering whether one was ever seen -- reporting "the debuggee ended"
    # to somebody whose debugger had not started is a lie that sends them
    # looking in the wrong place.
    var ever_started = debugging()
    while perf_counter_ns() < deadline:
        # The launch is normally the timer's job, but a check driving this
        # through the agent surface may arrive between the build finishing and
        # the next tick. Doing it here too costs nothing when it is already
        # done and removes a race that only ever shows up under a check.
        try:
            _ = debug_after_build(hwnd)
        except:
            pass
        _ = debug_poll(hwnd)
        if debugging():
            ever_started = True
        if stopped() and frame_count() > 0:
            # The stack answers before the scopes and the scopes before the
            # variables, so a stop with frames may still have no locals for
            # another round trip. Give the rest of the chain a moment rather
            # than reporting a stop with an empty variables pane, which reads
            # as a debugger that cannot see locals.
            # Ask for the top frame's locals explicitly. The client chains
            # scopes and variables off a stop, but a stop that arrives while
            # an earlier one's requests are still in flight has those answers
            # discarded -- correctly, they describe a stack that has moved --
            # and nothing re-asks. Asking here costs one round trip and means
            # a stop always has its locals.
            if variable_count() == 0:
                try:
                    select_frame(0)
                except:
                    pass
            var settle_by = perf_counter_ns() + 1_500_000_000
            while perf_counter_ns() < settle_by and variable_count() == 0:
                _ = debug_poll(hwnd)
                _ = settle(hwnd, 10)
            return debug_report(hwnd)
        if ever_started and not debugging():
            return String("debug: the debuggee ran to the end")
        _ = settle(hwnd, 10)
    if not ever_started:
        return String("debug: no session started in ") + String(
            milliseconds
        ) + " ms"
    return String("debug: nothing stopped in ") + String(milliseconds) + " ms"


# ===----------------------------------------------------------------------===#
# Replace
# ===----------------------------------------------------------------------===#


def replace_here(hwnd: Int, needle: String, replacement: String) raises -> String:
    """Replace the next match after the caret.

    Args:
        hwnd: The window.
        needle: What to look for.
        replacement: What to put there.

    Returns:
        What happened.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    if needle.byte_length() == 0:
        return String("nothing to replace")
    remember(doc[])
    var from_byte = byte_at(doc[].rope, doc[].caret_line, doc[].caret_col)
    var landed = replace_next(doc[].rope, needle, replacement, from_byte)
    if landed < 0:
        # Nothing changed, so the history entry would be an undo that does
        # nothing -- which is worse than no entry at all.
        _ = doc[].past.pop()
        return String("no match after the caret")
    doc[].revision += 1
    restate_dirty(doc[])
    release_cache(doc[].grid)
    var where = caret_of_byte(doc[].rope, landed)
    _ = caret_move(hwnd, where[0], where[1])
    _touch(hwnd)
    return String("replaced one")


def replace_every(hwnd: Int, needle: String, replacement: String) raises -> String:
    """Replace every match in the document, as one undoable edit.

    One history entry for the lot, because a person who replaces thirty-seven
    things and changes their mind meant all thirty-seven, and thirty-seven
    undos to get back is not an undo.

    Args:
        hwnd: The window.
        needle: What to look for.
        replacement: What to put there.

    Returns:
        How many.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    if needle.byte_length() == 0:
        return String("nothing to replace")
    remember(doc[])
    var count = replace_all(doc[].rope, needle, replacement)
    if count == 0:
        _ = doc[].past.pop()
        return String("no matches")
    doc[].revision += 1
    restate_dirty(doc[])
    release_cache(doc[].grid)
    _touch(hwnd)
    return String("replaced ") + String(count)


def replace_preview(hwnd: Int, needle: String, replacement: String) raises -> String:
    """What replacing everything would do, without doing it.

    Args:
        hwnd: The window.
        needle: What to look for.
        replacement: What to put there.

    Returns:
        A count and a line each.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    var total = count_matches(doc[].rope, needle)
    var out = String("replace ") + String(total) + " matches\n"
    for line in preview_replacements(doc[].rope, needle, replacement):
        out += line + "\n"
    return out^


# ===----------------------------------------------------------------------===#
# Remembering where you were
# ===----------------------------------------------------------------------===#


def session_report(hwnd: Int) raises -> String:
    """What is open now, and where it would be written down.

    Args:
        hwnd: The window.

    Returns:
        The session file and the tabs it would record.

    Raises:
        Never in practice.
    """
    _ = hwnd
    var root = project_root()
    if root.byte_length() == 0:
        return String("no project")
    var out = String("session ") + session_path(root) + "\n"
    for i in range(tab_count()):
        out += "  " + tab_name(i) + "\n"
    return out^


def remember_session(hwnd: Int) raises -> String:
    """Write down what is open, so the next run can put it back.

    Called on the way out. Failing to save a session may never be the reason
    an editor will not close, so everything here is best-effort and the
    module it calls reports rather than raises.

    Args:
        hwnd: The window.

    Returns:
        What happened.

    Raises:
        Never in practice.
    """
    var root = project_root()
    if root.byte_length() == 0:
        return String("no project; nothing to remember")

    var files = List[OpenFile]()
    for i in range(tab_count()):
        var address = tab_doc(i)
        if address == 0:
            continue
        var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)
        var path = path_of_uri(doc[].uri)
        # A document that has never been on disk has nothing to reopen. It is
        # skipped rather than saved with an empty path, which would come back
        # next time as a tab pointing at nothing.
        if path.byte_length() == 0:
            continue
        var marks = List[Int]()
        for at in doc[].breakpoints:
            marks.append(at)
        files.append(
            OpenFile(
                path,
                doc[].caret_line,
                doc[].caret_col,
                doc[].grid.top_line,
                marks^,
            )
        )

    var expanded = List[String]()
    try:
        expanded = expanded_paths()
    except:
        pass
    return save_session(root, files, current_tab(), expanded^)


def restore_session(hwnd: Int) raises -> String:
    """Put back what was open the last time this project was closed.

    Order matters. The files are opened first, because opening one switches to
    its tab and the front tab has to be chosen after they all exist. The tree
    is expanded second, because a directory can only be opened once its parent
    is showing and the saved list is already in that order.

    Args:
        hwnd: The window.

    Returns:
        What happened.

    Raises:
        Never in practice; a session that cannot be read is simply not used.
    """
    var root = project_root()
    if root.byte_length() == 0:
        return String("no project")
    if not load_session(root):
        return String("no previous session")

    var opened = 0
    for i in range(session_file_count()):
        var one = session_file(i)
        # The file the editor was started with is already open; opening it
        # again just switches to its tab, which is harmless and keeps this
        # loop from needing to know about it.
        var said = open_path(hwnd, one.path)
        if said.startswith("cannot open"):
            continue
        opened += 1
        var doc = _doc_at(hwnd)
        doc[].breakpoints = List[Int]()
        for at in one.breakpoints:
            doc[].breakpoints.append(at)
        doc[].grid.top_line = one.top_line
        _ = caret_move(hwnd, one.caret_line, one.caret_col)

    for i in range(expanded_count()):
        try:
            _ = expand_path(expanded_path(i))
        except:
            pass

    if session_current() >= 0 and session_current() < tab_count():
        _ = switch_tab(hwnd, session_current())

    var out = String("restored ") + String(opened) + " files"
    if dropped_count() > 0:
        # Said out loud rather than swallowed: a person who left four files
        # open and gets three back should be told which way that went, not
        # left wondering whether they imagined the fourth.
        out += ", " + String(dropped_count()) + " gone from disk"
    _touch(hwnd)
    return out^


def word_at_caret(hwnd: Int) raises -> String:
    """The identifier the caret is sitting in or beside.

    What a person means by "this one" when they are pointing at a name. The
    caret counts in UTF-16 units and the line is bytes, so the walk is over
    bytes and the caret's column is converted first -- an identifier is ASCII
    here, but the text before it on the line need not be.

    Args:
        hwnd: The window.

    Returns:
        The identifier, or an empty string if the caret is not in one.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    var line = doc[].rope.line(doc[].caret_line)
    var bytes = line.as_bytes()
    var at = byte_at(doc[].rope, doc[].caret_line, doc[].caret_col) - byte_at(
        doc[].rope, doc[].caret_line, 0
    )
    if at > len(bytes):
        at = len(bytes)

    fn is_word(c: Int) -> Bool:
        return (
            (c >= 0x41 and c <= 0x5A)
            or (c >= 0x61 and c <= 0x7A)
            or (c >= 0x30 and c <= 0x39)
            or c == 0x5F
        )

    # A caret just past the end of a word is still in that word as far as a
    # person is concerned: they have typed the name and want to know about it.
    var start = at
    if start > 0 and start <= len(bytes) and (
        start == len(bytes) or not is_word(Int(bytes[start]))
    ):
        if is_word(Int(bytes[start - 1])):
            start -= 1
    if start >= len(bytes) or not is_word(Int(bytes[start])):
        return String("")
    var finish = start
    while start > 0 and is_word(Int(bytes[start - 1])):
        start -= 1
    while finish < len(bytes) and is_word(Int(bytes[finish])):
        finish += 1
    return String(line[byte=start:finish])


def debug_evaluate(hwnd: Int, expression: String) raises -> String:
    """What an expression is worth where the debuggee is standing.

    Args:
        hwnd: The window.
        expression: What to ask about; empty means the word at the caret.

    Returns:
        The answer, or why there is none.

    Raises:
        If the window has no document.
    """
    if not debugging():
        return String("nothing is being debugged")
    if not stopped():
        return String("the debuggee is running")
    var want = expression
    if want.byte_length() == 0:
        want = word_at_caret(hwnd)
    if want.byte_length() == 0:
        return String("the caret is not on a name")
    var value = evaluate(want)
    if value.byte_length() == 0:
        return want + " is not in scope here"
    var out = want + " = " + value
    if evaluated_type().byte_length() > 0:
        out += "   (" + evaluated_type() + ")"
    return out^


def run_to_caret(hwnd: Int) raises -> String:
    """Carry on until execution reaches the caret's line.

    A breakpoint that exists for one stop. It is added to the document, sent
    with all the others, and taken off again when it is hit -- rather than
    kept, because a person who asked to run somewhere once did not ask for a
    breakpoint there forever, and an editor that leaves one behind teaches
    them to stop using this.

    Args:
        hwnd: The window.

    Returns:
        What happened.

    Raises:
        If the window has no document.
    """
    if not debugging():
        return String("nothing is being debugged; press F5 first")
    var doc = _doc_at(hwnd)
    var path = document_path(hwnd)
    if path.byte_length() == 0:
        return String("this document has no file")

    var target = doc[].caret_line
    var already = False
    for at in doc[].breakpoints:
        if at == target:
            already = True
    if not already:
        _ = toggle_breakpoint(hwnd, target)
        g_temporary_line()[] = target
        g_temporary_path()[] = path
    var lines = List[Int]()
    for at in doc[].breakpoints:
        lines.append(at)
    _ = set_breakpoints(path, lines)
    resume()
    return String("running to line ") + String(target + 1)


comptime g_temporary_line = named_global["ide.tempbreak.line", Int]
comptime g_temporary_path = named_global["ide.tempbreak.path", String]


def clear_temporary_breakpoint(hwnd: Int) raises:
    """Take away the breakpoint run-to-cursor put down, once it has served.

    Args:
        hwnd: The window.

    Raises:
        Never in practice.
    """
    if g_temporary_path()[].byte_length() == 0:
        return
    var path = document_path(hwnd)
    if path != g_temporary_path()[]:
        # The stop was somewhere else, so this one has not been reached and
        # is still wanted. Leaving it is right; a person who ran to a line and
        # stopped short of it still means to get there.
        return
    var line = g_temporary_line()[]
    if line != stop_line():
        return
    g_temporary_path()[] = String("")
    _ = toggle_breakpoint(hwnd, line)
    var doc = _doc_at(hwnd)
    var lines = List[Int]()
    for at in doc[].breakpoints:
        lines.append(at)
    _ = set_breakpoints(path, lines)


# ===----------------------------------------------------------------------===#
# The shape of the file
#
# The outline is the one LSP feature whose answer is about the whole document
# rather than about a position in it, which is why it can be asked for once
# and then read many times: the reply is still true after the caret moves. It
# goes stale when the text changes, and `outline` is cheap enough to re-ask
# rather than track that.
# ===----------------------------------------------------------------------===#


comptime g_outline_mark = named_global["ide.outline.mark", Int]


def outline(hwnd: Int) raises -> String:
    """Ask the server what is in this file, and show it in the pane.

    Args:
        hwnd: The window.

    Returns:
        What was asked, or why it was not.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    if doc[].uri.byte_length() == 0 or not is_ready():
        return String("no language server for this document")
    sync(hwnd)
    doc[].pane_mode = PANE_OUTLINE
    # The mark is taken here rather than in the wait, because a reply can
    # arrive in between: documentSymbol is answered from an already-parsed
    # tree and comes back in single-digit milliseconds, which is faster than
    # a person -- or a check driving one command after another -- can get to
    # the next line. A wait that sampled the serial itself would sample it
    # after the answer had already bumped it, and then wait out its whole
    # deadline for a second answer that nobody asked for.
    g_outline_mark()[] = symbols_serial()
    _ = request_symbols(doc[].uri)
    _touch(hwnd)
    return String("asked what is in this file")


def outline_wait(hwnd: Int, milliseconds: Int) raises -> String:
    """Pump until the outline arrives.

    Args:
        hwnd: The window.
        milliseconds: How long to wait.

    Returns:
        The outline, or that nothing came.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    var before = g_outline_mark()[]
    var deadline = perf_counter_ns() + milliseconds * 1_000_000
    # Up to three asks, because of a thing this server does that is worth
    # stating plainly: asked for a document's symbols while it is still
    # parsing that document, it does not say "not yet" -- it answers, with an
    # empty list or with however much of the file it has read. A spike put
    # the same question five times to the same unchanged file and got 0, 61,
    # 0, 0, 0 without a settle and 61 every time with one. So an empty
    # outline is not evidence of an empty file, and the difference between
    # the two is another parse.
    var tries = 0
    while perf_counter_ns() < deadline:
        _ = pump(hwnd)
        if symbols_serial() != before:
            if symbol_count() > 0 or tries >= 2:
                _touch(hwnd)
                return symbols_report()
            # Nothing came back. Wait for this document's parse to finish --
            # a diagnostics publish for it, which is the server's only "I
            # have read this file" -- and ask once more.
            tries += 1
            var parsed = parse_serial()
            while perf_counter_ns() < deadline and (
                parse_serial() == parsed or parsed_uri() != doc[].uri
            ):
                _ = pump(hwnd)
                _ = settle(hwnd, 10)
            if perf_counter_ns() >= deadline:
                return symbols_report()
            before = symbols_serial()
            g_outline_mark()[] = before
            _ = request_symbols(doc[].uri)
            continue
        _ = settle(hwnd, 10)
    return String("no outline arrived")


def goto_symbol(hwnd: Int, query: String) raises -> String:
    """Go to the symbol whose name matches `query`.

    Go-to-symbol without a box to type into: the going-to is the part that is
    hard and the part a check can drive, and the box is a menu sprint's work.
    An outline that has not been fetched is fetched, because a person pressing
    this shortcut has asked a question about the file, not about the cache.

    Args:
        hwnd: The window.
        query: Part of a name, matched case-insensitively.

    Returns:
        Where it went, or what it found instead.

    Raises:
        If the window has no document.
    """
    if symbol_count() == 0:
        _ = outline(hwnd)
        var came = outline_wait(hwnd, 10000)
        if symbol_count() == 0:
            return came
    var hits = matching_symbols(query)
    if len(hits) == 0:
        return String("no symbol matching ") + repr(query)
    # The list stays in file order -- a filtered outline that reshuffles on
    # every keystroke is a different list each time -- but the jump does not
    # have to take the first line of it. Someone who types a whole name means
    # that name: `outline` should not land on `g_outline_mark` because that
    # happens to be defined higher up the file.
    var want = query.lower()
    var chosen = hits[0]
    var best = 2
    for at in hits:
        var name = symbol_at(at).name.lower()
        var rank = 0 if name == want else (1 if name.startswith(want) else 2)
        if rank < best:
            best = rank
            chosen = at
        if best == 0:
            break
    var one = symbol_at(chosen)
    _ = caret_move(hwnd, one.line, one.column)
    follow_caret(hwnd)
    _touch(hwnd)
    var out = (
        String("went to ") + one.name + " at " + String(one.line + 1)
        + ":" + String(one.column + 1)
    )
    if len(hits) > 1:
        # Said, because a person who typed three letters and got the wrong one
        # of eleven should know there were eleven, rather than conclude the
        # editor cannot find theirs.
        out += "  (" + String(len(hits)) + " matched)"
    return out^


def pane_toolchain(hwnd: Int) raises -> String:
    """Show the Toolchain view in the bottom pane.

    Args:
        hwnd: The window.

    Returns:
        What is now showing.

    Raises:
        If the window has no document.
    """
    _doc_at(hwnd)[].pane_mode = PANE_TOOLCHAIN
    _touch(hwnd)
    return String("pane showing the toolchain")


def pane_python(hwnd: Int) raises -> String:
    """Show the Python view in the bottom pane.

    Args:
        hwnd: The window.

    Returns:
        What is now showing.

    Raises:
        If the window has no document.
    """
    _doc_at(hwnd)[].pane_mode = PANE_PYTHON
    _touch(hwnd)
    return String("pane showing python")


def new_tab(hwnd: Int) raises -> String:
    """Start an empty document in a tab of its own.

    An untitled document has no uri, and that absence is what every other
    part of the editor already keys on: `save` turns into Save As, the
    language server is not told about it, and the disk watcher has nothing to
    watch. So there is nothing to special-case here beyond making the tab.

    Args:
        hwnd: The window.

    Returns:
        Which tab it became.

    Raises:
        If the tab cannot be adopted.
    """
    var store = alloc[Doc](1, alignment=8)
    # Emplaced rather than assigned, for the reason `open_path` gives: an
    # assignment destroys what was there first, and what is there is whatever
    # the allocator last held.
    store.unsafe_write(Doc(Rope(String(""))))
    var which = adopt_tab(hwnd, Int(store))
    _touch(hwnd)
    return String("new document in tab ") + String(which + 1)


# ===----------------------------------------------------------------------===#
# Cut, copy and paste
#
# The clipboard module owns the Win32 and the CRLF convention. What is left
# here is what the three verbs mean to a document, which is where the
# judgement is: copy with nothing selected takes the whole line, because that
# is what every editor a person has used does and because copying nothing is
# never what they meant.
# ===----------------------------------------------------------------------===#


def copy(hwnd: Int) raises -> String:
    """Put the selection on the clipboard, or the caret's line if there is none.

    Args:
        hwnd: The window.

    Returns:
        What was copied, in words.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    var text = selected_text(doc[])
    var whole_line = False
    if text.byte_length() == 0:
        # The line, including its newline, so pasting it puts a line back
        # rather than splicing text into the middle of another one.
        text = doc[].rope.line(doc[].caret_line) + "\n"
        whole_line = True
    if not set_clipboard_text(text):
        return String("the clipboard would not take it")
    if whole_line:
        return String("copied line ") + String(doc[].caret_line + 1)
    return String("copied ") + String(text.byte_length()) + " bytes"


def cut(hwnd: Int) raises -> String:
    """Copy the selection and remove it.

    With nothing selected this cuts the caret's line, matching `copy` -- the
    pair have to agree or Ctrl+X and Ctrl+C mean different things by "this".

    Args:
        hwnd: The window.

    Returns:
        What was cut.

    Raises:
        If the window has no document.
    """
    var doc = _doc_at(hwnd)
    var said = copy(hwnd)
    if not said.startswith("copied"):
        return said
    remember(doc[])
    if not delete_selection(doc[]):
        # No selection, so `copy` took the whole line and this takes the same
        # line away, newline included.
        var start = byte_at(doc[].rope, doc[].caret_line, 0)
        var finish = start + doc[].rope.line(doc[].caret_line).byte_length() + 1
        if finish > doc[].rope.byte_length():
            finish = doc[].rope.byte_length()
        apply(doc[], start, finish, String(""))
    restate_dirty(doc[])
    _touch(hwnd)
    return String("cut") + String(said[byte=6:])


def paste(hwnd: Int) raises -> String:
    """Insert the clipboard at the caret, replacing the selection.

    Args:
        hwnd: The window.

    Returns:
        How much arrived, or that nothing did.

    Raises:
        If the window has no document.
    """
    var text = clipboard_text()
    if text.byte_length() == 0:
        # Two different facts, and the advice that follows from each is
        # different: one means copy something first, the other means try
        # again in a moment.
        if clipboard_was_busy():
            return String("another program is holding the clipboard")
        return String("the clipboard has no text")
    var doc = _doc_at(hwnd)
    remember(doc[])
    insert(doc[], text)
    restate_dirty(doc[])
    follow_caret(hwnd)
    _touch(hwnd)
    return String("pasted ") + String(text.byte_length()) + " bytes"


def about(hwnd: Int = 0) raises -> String:
    """What this build is, and what it is standing on.

    Every fact here is one the toolchain module measured rather than one this
    file declares, so About cannot drift into claiming a version Griddle is
    not running.

    Args:
        hwnd: Unused; taken so the menu and the agent call it alike.

    Returns:
        Three lines: the program, the compiler, and the machine.

    Raises:
        If the toolchain cannot be read.
    """
    _ = hwnd
    var out = String("Griddle -- a Mojo IDE for Windows, written in Mojo") + "\n"
    out += "  " + mojo_version() + " from " + toolchain_root() + "\n"
    if gpu_count() > 0:
        out += "  " + gpu_at(0) + "\n"
    return out^


# ===----------------------------------------------------------------------===#
# The line a person types into
#
# `ide/prompt.mojo` holds the text and the caret and knows nothing about the
# editor; this is the other half, which knows what a find is and what a line
# number means and never touches a character. The split is the same one the
# rest of the editor uses -- state that can be checked without a window, and
# a window that reads it.
# ===----------------------------------------------------------------------===#


def prompt_find(hwnd: Int) raises -> String:
    """Ask what to search for.

    Args:
        hwnd: The window.

    Returns:
        What is being asked.

    Raises:
        If the window has no document.
    """
    # Offering what was searched for last, with the caret at its end: somebody
    # who found four matches, looked at them and pressed Ctrl+F again meant to
    # search for something near it, not to start from an empty line.
    ask(ASK_FIND, String("Find"), recalled(ASK_FIND))
    _touch(hwnd)
    return String("asking what to find")


def prompt_replace(hwnd: Int) raises -> String:
    """Ask what to replace the current search with.

    Args:
        hwnd: The window.

    Returns:
        What is being asked, or why it cannot be.

    Raises:
        If the window has no document.
    """
    if find_needle(hwnd).byte_length() == 0:
        # Replace needs two answers and this line gives one at a time, so the
        # first has to already exist. Saying which one is missing is the
        # difference between a refusal and a mystery.
        return String("find something first; Ctrl+H replaces what Ctrl+F found")
    ask(
        ASK_REPLACE_WITH,
        String("Replace ") + find_needle(hwnd) + " with",
        recalled(ASK_REPLACE_WITH),
    )
    _touch(hwnd)
    return String("asking what to replace it with")


def prompt_goto(hwnd: Int) raises -> String:
    """Ask which line to go to.

    Args:
        hwnd: The window.

    Returns:
        What is being asked.

    Raises:
        If the window has no document.
    """
    ask(ASK_GOTO, String("Go to line"), String(""))
    _touch(hwnd)
    return String("asking which line")


def prompt_symbol(hwnd: Int) raises -> String:
    """Ask which symbol to go to.

    Args:
        hwnd: The window.

    Returns:
        What is being asked.

    Raises:
        If the window has no document.
    """
    ask(ASK_SYMBOL, String("Go to symbol"), String(""))
    _touch(hwnd)
    return String("asking which symbol")


def prompt_package(hwnd: Int) raises -> String:
    """Ask which package to install into this project's environment.

    Args:
        hwnd: The window.

    Returns:
        What is being asked.

    Raises:
        If the window has no document.
    """
    ask(ASK_PACKAGE, String("Install package"), String(""))
    _touch(hwnd)
    return String("asking which package")


def prompt_open(hwnd: Int) raises -> String:
    """Ask for a path to open, for when a dialog is more than is wanted.

    Args:
        hwnd: The window.

    Returns:
        What is being asked.

    Raises:
        If the window has no document.
    """
    ask(ASK_OPEN, String("Open"), String(""))
    _touch(hwnd)
    return String("asking which file")


def prompt_cancel(hwnd: Int) raises -> String:
    """Put the question away without answering it.

    Args:
        hwnd: The window.

    Returns:
        That it is gone.

    Raises:
        If the window has no document.
    """
    cancel()
    _touch(hwnd)
    return String("nothing is being asked")


def prompt_accept(hwnd: Int) raises -> String:
    """Act on what was typed.

    The one place that knows what each question was for. Every branch hands
    off to the verb that already does the work, so a thing done from this line
    and the same thing done from `--cmd` are the same code and cannot
    disagree.

    Args:
        hwnd: The window.

    Returns:
        Whatever the answer led to.

    Raises:
        If the window has no document.
    """
    var answered = accept()
    var kind = answered[0]
    var text = answered[1]
    _touch(hwnd)
    if kind == ASK_NOTHING:
        return String("nothing was being asked")
    if text.byte_length() == 0:
        return String("nothing typed")

    if kind == ASK_FIND:
        return find_text(hwnd, text)
    if kind == ASK_REPLACE_WITH:
        return replace_every(hwnd, find_needle(hwnd), text)
    if kind == ASK_GOTO:
        # A line number, and anything else is a mistake worth naming rather
        # than a jump to line zero.
        var line = 0
        for byte in text.as_bytes():
            var c = Int(byte)
            if c < 0x30 or c > 0x39:
                return String("not a line number: ") + text
            line = line * 10 + (c - 0x30)
        if line < 1:
            return String("lines start at 1")
        return goto(hwnd, line - 1, 0)
    if kind == ASK_SYMBOL:
        return goto_symbol(hwnd, text)
    if kind == ASK_PACKAGE:
        return install_packages(
            text, project_location(project_root(), document_path(hwnd))
        )
    if kind == ASK_OPEN:
        return open_path(hwnd, text)
    return String("nothing to do with that")


def prompt_key(hwnd: Int, what: StringSlice) raises -> String:
    """One editing key, for the prompt rather than the document.

    Named the way `edit_key` and `move_key` are, and for the same reason: a
    keystroke and a check should take one path, so what a person can do a
    check can drive.

    Args:
        hwnd: The window.
        what: `backspace`, `delete`, `left`, `right`, `home`, `end`, `clear`.

    Returns:
        What the line holds now.

    Raises:
        If the window has no document.
    """
    if what == "backspace":
        prompt_backspace()
    elif what == "delete":
        prompt_delete()
    elif what == "left":
        prompt_move(-1)
    elif what == "right":
        prompt_move(1)
    elif what == "home":
        prompt_home()
    elif what == "end":
        prompt_end()
    elif what == "clear":
        prompt_clear()
    else:
        return String("not a prompt key: ") + String(what)
    _touch(hwnd)
    return prompt_report()


def prompt_type(hwnd: Int, text: String) raises -> String:
    """Type into the line.

    Args:
        hwnd: The window.
        text: What to add.

    Returns:
        What the line holds now.

    Raises:
        If the window has no document.
    """
    for c in text.codepoints():
        put(Int(c))
    _touch(hwnd)
    return prompt_report()


def _extra_flags() raises -> String:
    """The include path and the library the shipped examples need.

    Griddle could not build its own examples. `-I mojo/stdlib -I .` does not
    reach the `max` package -- it lives at `max/mojo/max` -- so every GPU
    example stopped at `unable to locate module 'gpu'`, and with the include
    path added they stopped again at `undefined symbol:
    AsyncRT_DeviceContext_create`, which is the NVIDIA device runtime that
    Bazel links as `nvptx/runtime/nvptxrt.lib`.

    Passed on every build rather than only when a file looks like it needs
    them, because deciding from the source text would mean reading imports and
    getting it wrong for the file that imports something that imports GPU. The
    cost of passing them anyway was measured rather than assumed: an ordinary
    program that uses neither built in the same nine seconds and produced a
    byte-identical 14848-byte executable, because a linker takes only what is
    referenced out of a library.

    Each is included only if it is really there, so a tree without the max
    package builds exactly as it did before.

    Returns:
        The flags, with a leading space, or empty.
    """
    var out = String("")
    var max_package = absolute(String("max/mojo"))
    if _is_directory(max_package):
        out += ' -I "' + max_package + '"'
    var runtime = absolute(String("bazel-bin/nvptx/runtime/nvptxrt.lib"))
    if _file_exists(runtime):
        out += ' -Xlinker "' + runtime + '"'
    return out^


def _file_exists(path: String) raises -> Bool:
    """Whether a file is there.

    Args:
        path: What to look for.

    Returns:
        True when it exists.
    """
    try:
        var handle = open(path, "r")
        handle.close()
        return True
    except:
        return False


def _is_directory(path: String) raises -> Bool:
    """Whether a directory is there.

    Asked by looking for something inside it rather than by stat'ing it: the
    only caller wants `max/mojo` as an include path, and an include path that
    exists and holds nothing is no more use than one that does not exist.

    Args:
        path: The directory.

    Returns:
        True when it holds the max package.
    """
    return _file_exists(path + "\\max\\__init__.mojo") or _file_exists(
        path + "\\max\\gpu\\__init__.mojo"
    )
