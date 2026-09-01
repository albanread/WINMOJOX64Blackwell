"""Griddle -- a Mojo IDE for Windows, written in win-mojo.

Milestone 0.1: the window. It opens dark-chromed, survives resize, and exits
zero. Everything else in `IDE-DESIGN.md` hangs off this one HWND -- the rail,
the sidebar, the grid and the panes are all drawn into it by one Direct2D
pass, because a layout engine is precisely the thing the design refuses.

Run it:

    mojo build --no-optimization -I mojo/stdlib -o build/griddle.exe \\
        ide/griddle.mojo

`--ms N` closes the window on its own after N milliseconds -- milliseconds
because a second is far too coarse both ways: a check wants to be quick, and
a person watching wants time to see the thing rather than a flash. `--cmd "<verb>"` sends one command to our own window and prints the answer,
which is how the agent surface is checked with no second process involved --
a self-send dispatches straight into the window procedure, so it exercises
the whole path (message, handler, dispatcher, reply) without needing a
caller that shares our desktop. And `--selftest` resizes it and reports the client area before and after, which
is how the check drives it with nobody at the keyboard. The app inspects
itself rather than being inspected: a window created from a build harness is
not always on the interactive desktop, so cross-process EnumWindows can come
up empty for a window that plainly exists.
"""

from std.os import getenv
from std.sys import argv

from std.ffi import c_int
from std.memory import Pointer
from std.python._cpython import _fn_ptr_as_opaque
from std.sys.info import size_of
from std.sys._win32 import Win32Module
from std.sys._winkb import winkb_constant, winkb_struct_size
from std.sys.com import Apartment

from std.memory import alloc

from ide.agent import agent_command
from ide.chrome import Chrome, bring_up, draw, finish, release
from ide.drop import register as register_drop, revoke as revoke_drop
from ide.toolchain import adopt_installed_toolchain
from ide.python_env import project_location
from ide.tree import project_root
from ide.pipeutf8 import file_starts_with_bom, without_bom
from ide.doc import (
    Doc,
    LINE_H,
    PANE_OUTLINE,
    PANE_PYTHON,
    PANE_REFERENCES,
    PANE_TOOLCHAIN,
    PANE_VARIABLES,
)
from ide.gridview import (
    draw_hover,
    draw_variables,
    set_breakpoint_lines,
    draw_issues,
    draw_output,
    draw_tabs,
    draw_tree,
    set_tab_labels,
    draw_popup,
    draw_outline,
    draw_python,
    draw_toolchain,
    draw_references,
    draw_text,
    release_cache,
    status_line,
)
from ide.window import (
    adopt_tab,
    remember_session,
    restore_session,
    breakpoint_lines,
    debug_evaluate,
    run_to_caret,
    debug_after_build,
    debug_file,
    debug_poll,
    debug_step,
    debug_stop,
    debugging,
    find_needle,
    replace_preview,
    toggle_breakpoint,
    poll_disk,
    recreate,
    search_in_project,
    watch_project,
    rescale,
    set_root,
    zoom_in,
    zoom_out,
    zoom_report,
    zoom_reset,
    build_file,
    close_tab,
    confirm_close,
    confirm_close_all,
    current_tab,
    next_tab,
    tab_count,
    tab_name,
    set_unattended,
    build_poll,
    caret_click,
    complete_at_caret,
    document_path,
    run_file,
    stop_build,
    open_dialog,
    retitle,
    save,
    save_dialog,
    definition_at_caret,
    hover_at_caret,
    about,
    clear_breakpoints,
    copy,
    cut,
    paste,
    find_text,
    new_tab,
    asking,
    outline,
    prompt_accept,
    prompt_cancel,
    prompt_find,
    prompt_goto,
    prompt_key,
    prompt_replace,
    prompt_package,
    prompt_symbol,
    python_create,
    python_install,
    open_sample,
    _lsp_exe as lsp_exe,
    _lsp_stdlib as lsp_stdlib,
    prompt_type,
    pane_problems,
    pane_python,
    pane_toolchain,
    hover_close,
    hover_is_open,
    jump_back,
    references_at_caret,
    file_uri,
    popup_accept,
    popup_close,
    popup_is_open,
    popup_move,
    pump as lsp_pump,
    start_server,
    stop_server,
    find_again,
    mark_drawn,
    mark_keystroke,
    mark_presented,
    refresh_hz,
    edit_key,
    move_key,
    move_page,
    page_lines,
    scroll_by,
    scroll_to,
    type_unit,
)
from ide.menu import build as build_menu
from ide.lsp import is_running as lsp_running
from ide.rope import Rope
from ide.tsf import Tsf, activate, deactivate
from ide.build import ensure_linker
from ide.watch import file_stamp
from ide.win32 import (
    COPYDATASTRUCT,
    absolute,
    env_or,
    drain,
    MSG,
    RECT,
    WNDCLASSEXW,
    WndProcType,
    dpi_scale,
    scaled,
    wide,
    win32,
)


# Direct2D's way of saying the GPU went away underneath us -- a driver
# update, a remote session, a laptop switching graphics. It arrives from
# EndDraw rather than from the call that failed, and the answer is to build a
# new render target, not to give up.
comptime D2DERR_RECREATE_TARGET = 0x8899000C


# ===----------------------------------------------------------------------===#
# The window procedure
#
# Windows calls this, so it is a captureless C-ABI function: it cannot hold
# anything resolved in advance and has to find what it needs each time. That
# is the whole reason it re-opens user32 rather than being handed a pointer.
# ===----------------------------------------------------------------------===#


@export("griddle_wndproc")
def griddle_wndproc(
    hwnd: Int, message: UInt32, wparam: Int, lparam: Int
) abi("C") -> Int:
    try:
        # A command from outside. Windows has already copied the bytes into
        # this process, so the pointer is ours to read for the length of
        # this call and no longer.
        if message == UInt32(winkb_constant["WM_COPYDATA"]()):
            var cds = Pointer[COPYDATASTRUCT, MutAnyOrigin](
                unsafe_from_address=lparam
            )
            var bytes = Pointer[UInt8, MutAnyOrigin](
                unsafe_from_address=cds[].lpData
            )
            var request = String("")
            for i in range(Int(cds[].cbData)):
                request += chr(Int(bytes.unsafe_offset(i)[]))
            # First line names the file the answer goes in; the rest is the
            # command. Answering into a file is what lets a caller be a
            # shell script with no window of its own -- see ide/agent.mojo.
            var newline = request.find("\n")
            if newline < 0:
                return 0
            var reply_path = String(request[byte=:newline]).strip()
            var command = String(request[byte=newline + 1 :])
            # A verb that raises is still an answer. Reporting "the window
            # did not accept the command" tells the caller nothing about
            # what went wrong, and the outer handler cannot say more because
            # it has already lost the error.
            var reply = String("")
            try:
                reply = agent_command(hwnd, command)
            except err:
                reply = String("error: ") + String(err)
            with open(reply_path, "w") as f:
                f.write(reply)
            return 1

        # Everything visible is drawn here. The chrome's interfaces live in
        # the window's user data because this procedure is captureless --
        # Windows calls it, so it can hold nothing and must fetch what it
        # needs from the one place a window can keep something.
        # A window dragged onto a display of a different density. Windows
        # sends this only to a per-monitor-aware process -- which is what the
        # manifest buys -- and hands over the rectangle the window should
        # take, already worked out. Taking it is what stops the window
        # growing or shrinking by a hair on every crossing.
        #
        # Everything drawn was sized for the old density: the font is baked
        # into the text format at a point size, and every cached line layout
        # was made with that format. So this goes through the same rebuild a
        # lost device does -- new chrome at the new scale, cache dropped --
        # rather than trying to rescale what is already there.
        if message == UInt32(winkb_constant["WM_DPICHANGED"]()):
            var GetWindowLongPtrW2 = win32[
                def (Int, c_int) thin abi("C") -> Int, "GetWindowLongPtrW"
            ]()
            var stored2 = GetWindowLongPtrW2(
                hwnd, c_int(winkb_constant["GWLP_USERDATA"]())
            )
            var SetWindowPos2 = win32[
                def (
                    Int, Int, c_int, c_int, c_int, c_int, UInt32
                ) thin abi("C") -> c_int,
                "SetWindowPos",
            ]()
            var suggested = Pointer[RECT, MutAnyOrigin](
                unsafe_from_address=lparam
            )
            # SWP_NOZORDER | SWP_NOACTIVATE, named here because they are
            # #defines and the metadata has no row for them.
            _ = SetWindowPos2(
                hwnd,
                0,
                c_int(Int(suggested[].left)),
                c_int(Int(suggested[].top)),
                c_int(Int(suggested[].right - suggested[].left)),
                c_int(Int(suggested[].bottom - suggested[].top)),
                UInt32(0x0004 | 0x0010),
            )
            if stored2 != 0:
                var chrome2 = Pointer[Chrome, MutAnyOrigin](
                    unsafe_from_address=stored2
                )
                var GetClientRect2 = win32[
                    def (
                        Int, Pointer[RECT, MutAnyOrigin]
                    ) thin abi("C") -> c_int,
                    "GetClientRect",
                ]()
                var rc2 = RECT()
                _ = GetClientRect2(
                    hwnd, Pointer(to=rc2).unsafe_origin_cast[MutAnyOrigin]()
                )
                try:
                    recreate(
                        chrome2,
                        hwnd,
                        Int(rc2.right - rc2.left),
                        Int(rc2.bottom - rc2.top),
                    )
                    if chrome2[].doc != 0:
                        Pointer[Doc, MutAnyOrigin](
                            unsafe_from_address=chrome2[].doc
                        )[].grid.line_height = scaled(
                            LINE_H, chrome2[].scale
                        )
                except err:
                    print("griddle: DPI change failed:", String(err))
            var InvalidateRect2 = win32[
                def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
            ]()
            _ = InvalidateRect2(hwnd, 0, c_int(0))
            return 0

        if message == UInt32(winkb_constant["WM_PAINT"]()):
            var GetWindowLongPtrW = win32[
                def (Int, c_int) thin abi("C") -> Int, "GetWindowLongPtrW"
            ]()
            var stored = GetWindowLongPtrW(
                hwnd, c_int(winkb_constant["GWLP_USERDATA"]())
            )
            if stored != 0:
                var GetClientRect = win32[
                    def (
                        Int, Pointer[RECT, MutAnyOrigin]
                    ) thin abi("C") -> c_int,
                    "GetClientRect",
                ]()
                var rc = RECT()
                _ = GetClientRect(
                    hwnd, Pointer(to=rc).unsafe_origin_cast[MutAnyOrigin]()
                )
                var chrome = Pointer[Chrome, MutAnyOrigin](
                    unsafe_from_address=stored
                )
                # A paint that fails half-way leaves a window that looks
                # merely unfinished, with nothing said. Report it: a silent
                # partial paint is the hardest kind of bug to see.
                var width = Int(rc.right - rc.left)
                var height = Int(rc.bottom - rc.top)
                try:
                    # The status bar is composed here because this is where
                    # both halves are in scope: the chrome that draws it and
                    # the document it describes.
                    var status = String("Ln 1, Col 1    UTF-8")
                    if chrome[].doc != 0:
                        status = status_line(
                            Pointer[Doc, MutAnyOrigin](
                                unsafe_from_address=chrome[].doc
                            )[]
                        )
                    # The strip's labels are gathered here because this
                    # is where a document's name is known; gridview draws a
                    # row of tabs and does not know what a Doc is.
                    var labels = List[String]()
                    for t in range(tab_count()):
                        labels.append(tab_name(t))
                    set_tab_labels(labels^)
                    if chrome[].doc != 0:
                        set_breakpoint_lines(breakpoint_lines(hwnd))
                    var layout = draw(chrome[], width, height, status)
                    # The text goes inside the batch the chrome opened, so
                    # both halves of the frame are presented at once and the
                    # editor never shows an empty field for a frame.
                    if chrome[].doc != 0:
                        var doc = Pointer[Doc, MutAnyOrigin](
                            unsafe_from_address=chrome[].doc
                        )
                        draw_text(
                            doc[].grid,
                            chrome[],
                            doc[].rope,
                            layout.editor(),
                            doc[].revision,
                            doc[].caret_line,
                            doc[].caret_col,
                            doc[].anchor_line,
                            doc[].anchor_col,
                            doc[].needle,
                            lsp_running(),
                        )
                        # One pane, two lists. References take it while
                        # they are up because a person who just asked who
                        # calls this is not reading the problem list.
                        if doc[].pane_mode == PANE_VARIABLES:
                            draw_variables(chrome[], layout.issues())
                        elif doc[].pane_mode == PANE_OUTLINE:
                            draw_outline(chrome[], layout.issues())
                        elif doc[].pane_mode == PANE_TOOLCHAIN:
                            draw_toolchain(chrome[], layout.issues())
                        elif doc[].pane_mode == PANE_PYTHON:
                            draw_python(
                                chrome[],
                                layout.issues(),
                                project_location(
                                    project_root(), document_path(hwnd)
                                ),
                            )
                        elif doc[].pane_mode == PANE_REFERENCES:
                            draw_references(
                                doc[].grid, chrome[], layout.issues()
                            )
                        elif lsp_running():
                            draw_issues(
                                doc[].grid, chrome[], layout.issues()
                            )
                        draw_output(
                            doc[].grid, chrome[], layout.output()
                        )
                        draw_tabs(
                            chrome[], layout.tabs(), tab_count(), current_tab()
                        )
                        draw_tree(chrome[], layout.sidebar())
                        # Last, and over everything: a popup that the text
                        # can draw on top of is not a popup. The hover box
                        # is the same box and obeys the same rule, and the
                        # completion list wins when somehow both are up --
                        # it is the one being typed into.
                        if doc[].popup:
                            draw_popup(
                                doc[].grid,
                                chrome[],
                                doc[].rope,
                                layout.editor(),
                                doc[].caret_line,
                                doc[].caret_col,
                                doc[].popup_row,
                                doc[].revision,
                            )
                        elif doc[].hover:
                            draw_hover(
                                doc[].grid,
                                chrome[],
                                doc[].rope,
                                layout.editor(),
                                doc[].caret_line,
                                doc[].caret_col,
                                doc[].revision,
                            )
                except err:
                    print("griddle: paint failed:", String(err))
                # Every drawing command is issued; what remains is the
                # present. Split here so the application half can be measured
                # apart from the wait for the vertical blank.
                try:
                    mark_drawn(hwnd)
                except:
                    pass

                # EndDraw runs whatever happened above. BeginDraw opened a
                # batch, and a batch left open poisons every frame after it,
                # so a paint that failed half-way must still be closed.
                try:
                    var _hr = finish(chrome[])
                    if _hr == D2DERR_RECREATE_TARGET:
                        recreate(chrome, hwnd, width, height)
                    # EndDraw has returned, which for a vsync-presenting
                    # target means the frame is on its way to the display.
                    # That is the last boundary this process controls.
                    mark_presented(hwnd, frame_budget_ns(hwnd))
                except err:
                    print("griddle: present failed:", String(err))
            # Validate the whole window: the update region must be cleared or
            # Windows sends WM_PAINT again immediately, forever.
            var ValidateRect = win32[
                def (Int, Int) thin abi("C") -> c_int, "ValidateRect"
            ]()
            _ = ValidateRect(hwnd, 0)
            return 0

        # A click puts the caret where it landed. The same function the
        # `click` verb calls, so what a person gets and what a check gets
        # cannot drift apart -- which is the whole reason the agent surface
        # exists before the editor does.
        if message == UInt32(winkb_constant["WM_LBUTTONDOWN"]()):
            # lParam packs the point as two signed 16-bit halves, and they
            # are signed: a drag that leaves the window to the left reports a
            # negative x, which read unsigned becomes 65,000-odd.
            var px = lparam & 0xFFFF
            if px >= 0x8000:
                px -= 0x10000
            var py = (lparam >> 16) & 0xFFFF
            if py >= 0x8000:
                py -= 0x10000
            var SetFocus = win32[def (Int) thin abi("C") -> Int, "SetFocus"]()
            _ = SetFocus(hwnd)
            _ = caret_click(hwnd, px, py)
            return 0

        # Scrolling. The wheel reports in notches of 120; three lines a notch
        # is what every other Windows editor does. Nothing is recomputed here
        # -- the top line moves and the next paint is arithmetic from it.
        if message == UInt32(winkb_constant["WM_MOUSEWHEEL"]()):
            # The delta is the signed high word of wParam, and it is signed:
            # read it unsigned and scrolling only ever goes one way.
            var delta = Int((wparam >> 16) & 0xFFFF)
            if delta >= 0x8000:
                delta -= 0x10000
            _ = scroll_by(hwnd, -(delta * 3) // 120)
            return 0

        # Typed characters. Windows has already done the keyboard layout, the
        # dead keys and AltGr by the time this arrives, so what turns up is
        # the character the person meant -- which is why editors handle text
        # here rather than trying to reconstruct it from key codes.
        if message == UInt32(winkb_constant["WM_CHAR"]()):
            # Stamped first, before any work: what is being measured is the
            # whole of this process's response, and starting the clock after
            # the response has begun would measure a shorter one.
            mark_keystroke(hwnd)
            var unit = wparam & 0xFFFF
            # While a question is on screen the keyboard belongs to it. This
            # is the same rule the completion popup already follows, and for
            # the same reason: two things that both want Return have to take
            # turns, and the one that just opened is the one being used.
            if asking():
                if unit == 13:  # Return
                    print("griddle:", prompt_accept(hwnd))
                elif unit == 27:  # Escape
                    _ = prompt_cancel(hwnd)
                elif unit == 8:  # Backspace
                    _ = prompt_key(hwnd, "backspace")
                elif unit == 9 or unit >= 32:
                    # Through `type_unit`, not straight into the line: it is
                    # the one place that joins a surrogate pair across two
                    # messages, and an emoji typed into a search box is two
                    # WM_CHARs exactly as it is in the document. It hands the
                    # joined character to whichever of the two is listening.
                    _ = type_unit(hwnd, unit)
                return 0
            if unit == 13:  # Return
                _ = edit_key(hwnd, "enter")
            elif unit == 8:  # Backspace
                _ = edit_key(hwnd, "backspace")
            elif unit == 9 or unit >= 32:
                # WM_CHAR carries UTF-16, so anything outside the basic plane
                # arrives as two messages. Holding the first until the second
                # comes is the difference between typing an emoji and typing
                # two replacement characters.
                _ = type_unit(hwnd, unit)
            return 0

        if message == UInt32(winkb_constant["WM_KEYDOWN"]()):
            var GetKeyState = win32[
                def (c_int) thin abi("C") -> Int16, "GetKeyState"
            ]()
            if asking():
                # Escape and the movement keys arrive here rather than as
                # characters. Everything else is left alone deliberately:
                # Ctrl+C while a question is open should still copy, and a
                # function key should still do what it does.
                if wparam == winkb_constant["VK_ESCAPE"]():
                    _ = prompt_cancel(hwnd)
                    return 0
                if wparam == winkb_constant["VK_LEFT"]():
                    _ = prompt_key(hwnd, "left")
                    return 0
                if wparam == winkb_constant["VK_RIGHT"]():
                    _ = prompt_key(hwnd, "right")
                    return 0
                if wparam == winkb_constant["VK_HOME"]():
                    _ = prompt_key(hwnd, "home")
                    return 0
                if wparam == winkb_constant["VK_END"]():
                    _ = prompt_key(hwnd, "end")
                    return 0
                if wparam == winkb_constant["VK_DELETE"]():
                    _ = prompt_key(hwnd, "delete")
                    return 0

            var held = GetKeyState(c_int(winkb_constant["VK_SHIFT"]()))
            var shift = (Int(held) & 0x8000) != 0
            var ctrl_held = GetKeyState(c_int(winkb_constant["VK_CONTROL"]()))
            var ctrl = (Int(ctrl_held) & 0x8000) != 0
            var page = page_lines(hwnd)

            # While the popup is up it owns these keys. Letting the
            # editor have them means Enter inserts a newline behind the list
            # and Escape does nothing, which is every bad completion UI.
            if popup_is_open(hwnd):
                if wparam == winkb_constant["VK_ESCAPE"]():
                    _ = popup_close(hwnd)
                    return 0
                if wparam == winkb_constant["VK_UP"]():
                    _ = popup_move(hwnd, -1)
                    return 0
                if wparam == winkb_constant["VK_DOWN"]():
                    _ = popup_move(hwnd, 1)
                    return 0
                if (
                    wparam == winkb_constant["VK_RETURN"]()
                    or wparam == winkb_constant["VK_TAB"]()
                ):
                    _ = popup_accept(hwnd)
                    return 0

            # Escape closes the hover box the way it closes the popup. It
            # is checked before the ctrl block so a box can be dismissed
            # without knowing which one is up.
            if wparam == winkb_constant["VK_ESCAPE"]() and hover_is_open(hwnd):
                _ = hover_close(hwnd)
                return 0

            # F12 asks where this is defined, Shift+F12 asks who uses it.
            # The answers arrive on a later pump and the window redraws then;
            # nothing here waits, because a slow server must not be able to
            # hold a keystroke.
            if wparam == winkb_constant["VK_F12"]():
                if shift:
                    _ = references_at_caret(hwnd)
                else:
                    _ = definition_at_caret(hwnd)
                return 0

            # Alt+Left, the way every browser and most editors spell "back".
            var alt_held = GetKeyState(c_int(winkb_constant["VK_MENU"]()))
            if (Int(alt_held) & 0x8000) != 0:
                if wparam == winkb_constant["VK_LEFT"]():
                    _ = jump_back(hwnd)
                    return 0

            if ctrl:
                # Ctrl+Space: the universal "what can go here".
                if wparam == winkb_constant["VK_SPACE"]():
                    _ = complete_at_caret(hwnd)
                    return 0
                # Ctrl+I: what is this. VS Code spells it Ctrl+K Ctrl+I; a
                # chord is a lot of machinery for one box, and Ctrl+I is free.
                if wparam == ord("I"):
                    # The same question -- "what is this" -- answered by
                    # whichever of the two actually knows right now. While a
                    # program is stopped the live value beats a type, because
                    # it is a fact about this run rather than a fact about
                    # the language.
                    if debugging():
                        print("griddle:", debug_evaluate(hwnd, String("")))
                    else:
                        _ = hover_at_caret(hwnd)
                    return 0
                # Z, Y and A are virtual key codes, which are the ASCII
                # capitals for letters -- one of Win32's few kindnesses.
                # X, C and V: the three keys every Windows program has had
                # since 1990. They call what the Edit menu calls, so a
                # feature cannot work from one and not the other.
                if wparam == ord("X"):
                    print("griddle:", cut(hwnd))
                    return 0
                if wparam == ord("C"):
                    print("griddle:", copy(hwnd))
                    return 0
                if wparam == ord("V"):
                    print("griddle:", paste(hwnd))
                    return 0
                if wparam == ord("N"):
                    print("griddle:", new_tab(hwnd))
                    return 0
                if wparam == ord("Z"):
                    _ = edit_key(hwnd, "redo" if shift else "undo")
                elif wparam == ord("Y"):
                    _ = edit_key(hwnd, "redo")
                elif wparam == ord("A"):
                    _ = move_key(hwnd, "all", False)
                elif wparam == ord("S"):
                    # Ctrl+S saves; Ctrl+Shift+S asks where. A document that
                    # has never been on disk turns the first into the second,
                    # because "saved" with nowhere to save to is a lie.
                    if shift or document_path(hwnd).byte_length() == 0:
                        print("griddle:", save_dialog(hwnd))
                    else:
                        print("griddle:", save(hwnd))
                elif wparam == ord("F") and shift:
                    # Ctrl+Shift+F, the search-everywhere chord every editor
                    # shares. Plain Ctrl+F stays with the document.
                    print("griddle:", search_in_project(hwnd, find_needle(hwnd)))
                elif wparam == ord("F"):
                    # Ctrl+F asks. It used to search for whatever the last
                    # search was, which is a strange thing for a key called
                    # Find to do, and there was nowhere to type a new one.
                    print("griddle:", prompt_find(hwnd))
                elif wparam == ord("G"):
                    print("griddle:", prompt_goto(hwnd))
                elif wparam == ord("P") and shift:
                    print("griddle:", prompt_symbol(hwnd))
                elif wparam == ord("O") and shift:
                    # Ctrl+Shift+O, the go-to-symbol chord, opposite Ctrl+O
                    # for open the way Ctrl+Shift+F sits opposite Ctrl+F.
                    # Without a box to type into it shows the outline, which
                    # is the half of the feature that is worth having on its
                    # own: a list of what is in this file, clickable.
                    print("griddle:", outline(hwnd))
                elif wparam == ord("O"):
                    print("griddle:", open_dialog(hwnd))
                elif wparam == ord("B"):
                    print("griddle:", build_file(hwnd))
                elif wparam == ord("H"):
                    # Ctrl+H replaces every occurrence of whatever the last
                    # search looked for. Without a dialog to type a
                    # replacement into -- milestone 3 has no text input that
                    # is not the document -- this is the honest half: it says
                    # what it would do, and `replace all X -> Y` through the
                    # agent surface does it. A person gets the count and the
                    # preview rather than a key that quietly rewrites a file.
                    print(
                        "griddle:",
                        prompt_replace(hwnd),
                    )
                elif wparam == ord("W"):
                    print("griddle:", close_tab(hwnd))
                elif (
                    wparam == winkb_constant["VK_OEM_PLUS"]()
                    or wparam == winkb_constant["VK_ADD"]()
                ):
                    print("griddle:", zoom_in(hwnd))
                elif (
                    wparam == winkb_constant["VK_OEM_MINUS"]()
                    or wparam == winkb_constant["VK_SUBTRACT"]()
                ):
                    print("griddle:", zoom_out(hwnd))
                elif wparam == ord("0"):
                    print("griddle:", zoom_reset(hwnd))
                elif wparam == winkb_constant["VK_TAB"]():
                    # Ctrl+Tab forward, Ctrl+Shift+Tab back, the way every
                    # tabbed thing on this platform spells it.
                    _ = next_tab(hwnd, -1 if shift else 1)
                return 0

            # F5 runs what is open, Shift+F5 stops it. The document is
            # saved first; running the version on disk while the window shows
            # another one is a way to lose an afternoon.
            if wparam == winkb_constant["VK_F9"]():
                # The caret's line. A breakpoint is about a line, and asking
                # which one by pointing the caret at it is what F9 has meant
                # for thirty years.
                print("griddle:", toggle_breakpoint(hwnd, -1))
                return 0

            if wparam == winkb_constant["VK_F5"]():
                if shift:
                    # Shift+F5 stops whichever is going.
                    if debugging():
                        print("griddle:", debug_stop(hwnd))
                    else:
                        print("griddle:", stop_build())
                elif ctrl:
                    print("griddle:", run_file(hwnd))
                else:
                    print("griddle:", debug_file(hwnd))
                return 0

            if wparam == winkb_constant["VK_F10"]():
                if ctrl:
                    print("griddle:", run_to_caret(hwnd))
                else:
                    print("griddle:", debug_step(hwnd, "over"))
                return 0
            if wparam == winkb_constant["VK_F11"]():
                print("griddle:", debug_step(hwnd, "out" if shift else "in"))
                return 0

            # F3 repeats the search; shift reverses it. The needle lives on
            # the document, so it survives focus moving away and back.
            if wparam == winkb_constant["VK_F3"]():
                _ = find_again(hwnd, shift)
                return 0

            if wparam == winkb_constant["VK_DELETE"]():
                _ = edit_key(hwnd, "delete")
            elif wparam == winkb_constant["VK_LEFT"]():
                _ = move_key(hwnd, "left", shift)
            elif wparam == winkb_constant["VK_RIGHT"]():
                _ = move_key(hwnd, "right", shift)
            elif wparam == winkb_constant["VK_DOWN"]():
                _ = move_key(hwnd, "down", shift)
            elif wparam == winkb_constant["VK_UP"]():
                _ = move_key(hwnd, "up", shift)
            elif wparam == winkb_constant["VK_HOME"]():
                _ = move_key(hwnd, "home", shift)
            elif wparam == winkb_constant["VK_END"]():
                _ = move_key(hwnd, "end", shift)
            # The page keys move the caret by a page as well as the view.
            # Scrolling without the caret leaves the next keystroke jumping
            # back to wherever it was, which reads as the editor losing your
            # place.
            elif wparam == winkb_constant["VK_NEXT"]():
                _ = move_page(hwnd, page, shift)
            elif wparam == winkb_constant["VK_PRIOR"]():
                _ = move_page(hwnd, -page, shift)
            return 0

        # The language server, drained. Its own timer id, checked against
        # its own window, for the reason the close timer's comment gives.
        if message == UInt32(winkb_constant["WM_TIMER"]()):
            # A running program's output goes into the pane as it is
            # produced, on whichever timer happens to tick. Not gated on the
            # LSP's id: a document with no language server still has to be
            # able to watch its program run.
            try:
                _ = build_poll(hwnd)
            except:
                pass
            # And anything that changed on disk. Same tick, because both are
            # "the world moved while you were typing" and both want the same
            # answer: notice, and redraw.
            try:
                _ = poll_disk(hwnd)
            except:
                pass
            try:
                _ = debug_poll(hwnd)
                _ = debug_after_build(hwnd)
            except:
                pass
            if wparam == LSP_TIMER_ID:
                try:
                    _ = lsp_pump(hwnd)
                except:
                    pass
                return 0

        # A menu item was chosen -- by a person or by the agent, which sends
        # the same command the menu does.
        if message == UInt32(winkb_constant["WM_COMMAND"]()):
            var which = wparam & 0xFFFF
            if which == 1020:  # View > Zoom In
                print("griddle:", zoom_in(hwnd))
                return 0
            if which == 1021:  # View > Zoom Out
                print("griddle:", zoom_out(hwnd))
                return 0
            if which == 1022:  # View > Reset Zoom
                print("griddle:", zoom_reset(hwnd))
                return 0
            if which == 1006:  # File > New
                print("griddle:", new_tab(hwnd))
                return 0
            if which == 1007:  # File > Close Tab
                print("griddle:", close_tab(hwnd))
                return 0
            if which == 1030:  # Edit > Undo
                print("griddle:", edit_key(hwnd, "undo"))
                return 0
            if which == 1031:  # Edit > Redo
                print("griddle:", edit_key(hwnd, "redo"))
                return 0
            if which == 1032:  # Edit > Cut
                print("griddle:", cut(hwnd))
                return 0
            if which == 1033:  # Edit > Copy
                print("griddle:", copy(hwnd))
                return 0
            if which == 1034:  # Edit > Paste
                print("griddle:", paste(hwnd))
                return 0
            if which == 1035:  # Edit > Select All
                print("griddle:", move_key(hwnd, "all", False))
                return 0
            if which == 1036:  # Edit > Find
                print("griddle:", find_text(hwnd, find_needle(hwnd)))
                return 0
            if which == 1037:  # Edit > Find Next
                print("griddle:", find_again(hwnd, False))
                return 0
            if which == 1038:  # Edit > Find Previous
                print("griddle:", find_again(hwnd, True))
                return 0
            if which == 1039:  # Edit > Replace
                print(
                    "griddle:",
                    replace_preview(hwnd, find_needle(hwnd), String("")),
                )
                return 0
            if which == 1040:  # Edit > Find in Project
                print("griddle:", search_in_project(hwnd, find_needle(hwnd)))
                return 0
            if which == 1050:  # Go > Definition
                print("griddle:", definition_at_caret(hwnd))
                return 0
            if which == 1051:  # Go > References
                print("griddle:", references_at_caret(hwnd))
                return 0
            if which == 1052:  # Go > Symbol in File
                print("griddle:", outline(hwnd))
                return 0
            if which == 1053:  # Go > Back
                print("griddle:", jump_back(hwnd))
                return 0
            if which == 1054:  # Go > Next Tab
                print("griddle:", next_tab(hwnd, 1))
                return 0
            if which == 1055:  # Go > Previous Tab
                print("griddle:", next_tab(hwnd, -1))
                return 0
            if which == 1027:  # Build > Step Out
                print("griddle:", debug_step(hwnd, "out"))
                return 0
            if which == 1017:  # Build > Run to Cursor
                print("griddle:", run_to_caret(hwnd))
                return 0
            if which == 1018:  # Build > Evaluate
                print("griddle:", debug_evaluate(hwnd, String("")))
                return 0
            if which == 1019:  # Build > Clear All Breakpoints
                print("griddle:", clear_breakpoints(hwnd))
                return 0
            # ---- Python ------------------------------------------
            if which == 1060:  # Python > Create or Repair Environment
                print("griddle:", python_create(hwnd))
                return 0
            if which == 1061:  # Python > Install Project Dependencies
                print("griddle:", python_install(hwnd, String("")))
                return 0
            if which == 1062:  # Python > Install Package...
                # Asks, rather than doing something to a package nobody
                # named. This is what the prompt line was built for.
                print("griddle:", prompt_package(hwnd))
                return 0
            if which == 1063:  # Python > Show Environment
                print("griddle:", pane_python(hwnd))
                return 0

            # ---- Examples ----------------------------------------
            # One id per example, in the order the menu listed them.
            if which >= 1200 and which < 1264:
                print("griddle:", open_sample(hwnd, which - 1200))
                return 0

            if which == 1023:  # View > Outline
                print("griddle:", outline(hwnd))
                return 0
            if which == 1024:  # View > Toolchain
                print("griddle:", pane_toolchain(hwnd))
                return 0
            if which == 1025:  # View > Python
                print("griddle:", pane_python(hwnd))
                return 0
            if which == 1026:  # View > Problems
                print("griddle:", pane_problems(hwnd))
                return 0
            if which == 1013:  # Build > Debug
                print("griddle:", debug_file(hwnd))
                return 0
            if which == 1014:  # Build > Step Over
                print("griddle:", debug_step(hwnd, "over"))
                return 0
            if which == 1015:  # Build > Step Into
                print("griddle:", debug_step(hwnd, "in"))
                return 0
            if which == 1016:  # Build > Toggle Breakpoint
                print("griddle:", toggle_breakpoint(hwnd, -1))
                return 0
            if which == 1010:  # Build > Run
                print("griddle:", run_file(hwnd))
                return 0
            if which == 1011:  # Build > Build
                print("griddle:", build_file(hwnd))
                return 0
            if which == 1012:  # Build > Stop
                print("griddle:", stop_build())
                return 0
            if which == 1004:  # File > Save
                print("griddle:", save(hwnd))
                return 0
            if which == 1005:  # File > Save As
                print("griddle:", save_dialog(hwnd))
                return 0
            if which == 1003:  # File > Open
                print("griddle:", open_dialog(hwnd))
                return 0
            if which == 1002:  # Help > About
                # It said nothing at all until a check walked the bar and
                # asked what every item was wired to. An About that does
                # nothing is the smallest possible broken promise, and the
                # answer is one a person actually wants: which build this is
                # and what it is running on.
                print("griddle:", about())
                return 0
            if which == 1001:  # File > Exit
                # Through WM_CLOSE, so Exit asks about unsaved work the same
                # way the X button does. Two ways out of a program is two
                # places to forget the question.
                var SendMessageW2 = win32[
                    def (Int, UInt32, Int, Int) thin abi("C") -> Int,
                    "SendMessageW",
                ]()
                _ = SendMessageW2(
                    hwnd, UInt32(winkb_constant["WM_CLOSE"]()), 0, 0
                )
            return 0

        # The X button, Alt+F4 and File > Exit all arrive here first. This is
        # the last moment at which unsaved work can still be saved, so it is
        # the only place the question can be asked -- WM_DESTROY is too late,
        # the window is already going.
        if message == UInt32(winkb_constant["WM_CLOSE"]()):
            try:
                if not confirm_close_all(hwnd):
                    return 0
                # After the question, not before: a close that gets cancelled
                # must not have already written down a session for a window
                # that is staying open.
                try:
                    print("griddle:", remember_session(hwnd))
                except:
                    pass
            except:
                # A window with no document has nothing to lose; a raise here
                # must not be able to trap someone in the editor.
                pass
            var DestroyWindow2 = win32[
                def (Int) thin abi("C") -> c_int, "DestroyWindow"
            ]()
            _ = DestroyWindow2(hwnd)
            return 0

        # Closing the window ends the program: without this the loop waits
        # forever for messages from a window that no longer exists.
        if message == UInt32(winkb_constant["WM_DESTROY"]()):
            var PostQuitMessage = win32[
                def (c_int) thin abi("C") -> NoneType, "PostQuitMessage"
            ]()
            _ = PostQuitMessage(c_int(0))
            return 0

        var DefWindowProcW = win32[WndProcType, "DefWindowProcW"]()
        return DefWindowProcW(hwnd, message, wparam, lparam)
    except:
        # A raise cannot cross back into Windows. Answering zero is the
        # documented "handled" reply and keeps the window alive; the
        # alternative is unwinding through a foreign frame.
        return 0


# ===----------------------------------------------------------------------===#
# Startup
# ===----------------------------------------------------------------------===#


# Our own close timer's id. Named because the loop must be able to tell it
# from every other timer in the process: the runtime sets thread timers of
# its own, and a WM_TIMER that is not ours must not be read as "shut down".
comptime CLOSE_TIMER_ID = 0x6721
# The language server is drained from here. Fifty milliseconds is three
# frames: often enough that a diagnostic appears while a person is still
# looking at the line, rare enough that an idle editor is idle.
comptime LSP_TIMER_ID = 0x6722
comptime LSP_POLL_MS = 50


def dark_titlebar(hwnd: Int) raises -> Int32:
    """Ask the DWM for a dark caption, so the frame matches the editor.

    A light title bar over a dark editor is the tell of a port that stopped
    at "it opens". The attribute is advisory -- older Windows 10 builds
    simply ignore it -- so a failure here is not fatal. The HRESULT is
    returned rather than swallowed, because "the call was made" and "Windows
    accepted it" are different claims and only the second one is worth
    printing.

    Args:
        hwnd: The window to darken.

    Returns:
        The HRESULT; zero means the caption is dark.
    """
    var DwmSetWindowAttribute = win32[
        def (Int, UInt32, Pointer[Int32, MutAnyOrigin], UInt32) thin abi("C")
        -> Int32,
        "DwmSetWindowAttribute",
    ]()
    var enabled = Int32(1)
    return DwmSetWindowAttribute(
        hwnd,
        UInt32(winkb_constant["DWMWA_USE_IMMERSIVE_DARK_MODE"]()),
        Pointer(to=enabled).unsafe_origin_cast[MutAnyOrigin](),
        UInt32(size_of[Int32]()),
    )


def load_document(path: String, lines: Int) raises -> Rope:
    """The text to show: a file, a synthetic document, or the welcome note.

    A file that cannot be read is reported in the buffer rather than raised.
    The window is the thing being started here, and refusing to open at all
    because one path was wrong helps nobody.

    Args:
        path: A file to read, or empty.
        lines: How many lines to generate when there is no file.

    Returns:
        The document.

    Raises:
        If the rope cannot be built.
    """
    if path.byte_length() > 0:
        try:
            with open(path, "r") as f:
                # Without the byte-order mark, and this is the second place
                # that has to say so: a file opened from the command line is
                # loaded here rather than through `open_path`, so a fix in
                # one of them is a fix in half the cases. `had_bom` is set by
                # the caller, which is the one that holds the document.
                return Rope(without_bom(f.read())[0])
        except err:
            return Rope(
                String("Could not open ") + path + "\n\n" + String(err) + "\n"
            )

    if lines > 0:
        # Built once as a String and handed to the rope whole: this is the
        # document, not an edit sequence, and the rope's own builder splits it
        # far faster than a quarter of a million insertions would.
        var text = String("")
        for i in range(lines):
            text += "line "
            text += String(i + 1)
            text += ": the quick brown fox jumps over the lazy dog\n"
        return Rope(text^)

    return Rope(
        String(
            "Griddle\n"
            "\n"
            "A text grid on a rope. Nothing here is measured to decide what\n"
            "to draw: the visible range is a division and each origin is a\n"
            "multiplication.\n"
            "\n"
            "  griddle --open FILE      show a file\n"
            "  griddle --lines 250000   show a synthetic document\n"
            "  griddle --cmd grid       print the layout cache counters\n"
            "\n"
            "Scroll with the wheel, or with Page Up and Page Down.\n"
        )
    )


def main() raises:
    # DPI awareness. ide/griddle.manifest is what normally declares this, and
    # a manifest is the right place because awareness is a property of the
    # process from its first instruction rather than something to switch on
    # part way through. This call is the fallback for a binary run without
    # the manifest embedded or beside it, and it fails -- harmlessly, with
    # ERROR_ACCESS_DENIED -- when the manifest already won.
    #
    # Without either, Windows reports a smaller desktop than there is, lets
    # the process draw at that size and stretches the result: blurry text in
    # an editor, which is the one thing an editor may not have.
    #
    # -4 is DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2. It is a sentinel
    # handle value rather than an enumerator, so it is not in the metadata to
    # be looked up; it is written here with its name because that is the only
    # place it can be written.
    try:
        var SetProcessDpiAwarenessContext = win32[
            def (Int) thin abi("C") -> c_int,
            "SetProcessDpiAwarenessContext",
        ]()
        _ = SetProcessDpiAwarenessContext(-4)
    except:
        pass

    # Windows describes its own structures; a disagreement is a build
    # failure here rather than corruption at the first call.
    comptime assert (
        size_of[WNDCLASSEXW]() == winkb_struct_size["WNDCLASSEXW"]()
    ), "WNDCLASSEXW does not match Windows"
    comptime assert (
        size_of[MSG]() == winkb_struct_size["MSG"]()
    ), "MSG does not match Windows"

    # `--seconds N`: close on our own, for unattended runs.
    var close_ms = 0
    var selftest = False
    var command = String("")
    var trace = False
    # What to show. `--open` reads a file; `--lines N` builds a synthetic
    # document of N lines, which is how the "250,000 lines scrolls like an
    # empty one" claim gets tested without shipping a 12 MB fixture.
    var open_path = String("")
    var synth_lines = 0
    # Presenting on the vertical blank pins every frame to the refresh rate,
    # which is right for looking at and useless for measuring: the mean comes
    # back as 16.67 ms whether a frame took one millisecond or fifteen.
    var no_vsync = False
    # The checks that measure drawing do not want a language server
    # parsing in the background while they time a frame.
    var no_lsp = False
    # Sessions are a convenience for a person and a source of surprise for a
    # check: a suite that opens one file and expects one tab should not
    # inherit whatever was open when somebody last used the editor here.
    var no_session = False
    var args = argv()
    for i in range(len(args)):
        if args[i] == "--ms" and i + 1 < len(args):
            close_ms = Int(args[i + 1])
        if args[i] == "--selftest":
            selftest = True
        if args[i] == "--trace":
            trace = True
        if args[i] == "--cmd" and i + 1 < len(args):
            command = String(args[i + 1])
        if args[i] == "--open" and i + 1 < len(args):
            open_path = String(args[i + 1])
        if args[i] == "--lines" and i + 1 < len(args):
            synth_lines = Int(args[i + 1])
        if args[i] == "--no-vsync":
            no_vsync = True
        if args[i] == "--no-lsp":
            no_lsp = True
        if args[i] == "--no-session":
            no_session = True

    var GetModuleHandleW = win32[
        def (Int) thin abi("C") -> Int, "GetModuleHandleW"
    ]()
    var GetLastError = win32[def () thin abi("C") -> UInt32, "GetLastError"]()
    var RegisterClassExW = win32[
        def (Pointer[WNDCLASSEXW, MutAnyOrigin]) thin abi("C") -> UInt16,
        "RegisterClassExW",
    ]()
    var CreateWindowExW = win32[
        def (
            UInt32, Pointer[UInt16, MutAnyOrigin],
            Pointer[UInt16, MutAnyOrigin], UInt32,
            c_int, c_int, c_int, c_int, Int, Int, Int, Int,
        ) thin abi("C") -> Int,
        "CreateWindowExW",
    ]()
    var ShowWindow = win32[
        def (Int, c_int) thin abi("C") -> c_int, "ShowWindow"
    ]()
    var GetMessageW = win32[
        def (
            Pointer[MSG, MutAnyOrigin], Int, UInt32, UInt32
        ) thin abi("C") -> c_int,
        "GetMessageW",
    ]()
    var TranslateMessage = win32[
        def (Pointer[MSG, MutAnyOrigin]) thin abi("C") -> c_int,
        "TranslateMessage",
    ]()
    var DispatchMessageW = win32[
        def (Pointer[MSG, MutAnyOrigin]) thin abi("C") -> Int,
        "DispatchMessageW",
    ]()

    var hInstance = GetModuleHandleW(0)
    var class_name = wide("GriddleWindow")
    var title = wide("Griddle")

    var proc: WndProcType = griddle_wndproc
    var wc = WNDCLASSEXW()
    wc.cbSize = UInt32(size_of[WNDCLASSEXW]())
    # Redraw the whole client area on either axis changing, because the grid
    # is laid out by arithmetic on the window size.
    wc.style = UInt32(
        winkb_constant["CS_HREDRAW"]() | winkb_constant["CS_VREDRAW"]()
    )
    wc.lpfnWndProc = Int(_fn_ptr_as_opaque(proc))
    wc.hInstance = hInstance
    wc.lpszClassName = Int(class_name.unsafe_ptr())

    # The icon, out of this executable's own resources. Resource 1, which is
    # what `ide/griddle.rc` names it and what the shell shows as the file's
    # icon; loading it here is what puts the same picture in the title bar,
    # on the taskbar button and in Alt+Tab. Both sizes are asked for
    # separately: Windows will shrink the large one for the small slot, and
    # the result is a smudge next to a 16-pixel icon drawn as 16 pixels.
    var LoadImageW = win32[
        def (Int, Int, UInt32, c_int, c_int, UInt32) thin abi("C") -> Int,
        "LoadImageW",
    ]()
    var image_icon = UInt32(winkb_constant["IMAGE_ICON"]())
    var shared = UInt32(winkb_constant["LR_SHARED"]())
    var big = winkb_constant["SM_CXICON"]()
    var small = winkb_constant["SM_CXSMICON"]()
    var GetSystemMetrics = win32[
        def (c_int) thin abi("C") -> c_int, "GetSystemMetrics"
    ]()
    wc.hIcon = LoadImageW(
        hInstance,
        1,
        image_icon,
        GetSystemMetrics(c_int(big)),
        GetSystemMetrics(c_int(big)),
        shared,
    )
    wc.hIconSm = LoadImageW(
        hInstance,
        1,
        image_icon,
        GetSystemMetrics(c_int(small)),
        GetSystemMetrics(c_int(small)),
        shared,
    )

    if RegisterClassExW(Pointer(to=wc).unsafe_origin_cast[MutAnyOrigin]()) == 0:
        raise Error(
            "RegisterClassExW failed, GetLastError = " + String(GetLastError())
        )

    var hwnd = CreateWindowExW(
        UInt32(0),
        class_name.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        title.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        UInt32(winkb_constant["WS_OVERLAPPEDWINDOW"]()),
        c_int(winkb_constant["CW_USEDEFAULT"]()),
        c_int(winkb_constant["CW_USEDEFAULT"]()),
        c_int(1200),
        c_int(800),
        0,
        0,
        hInstance,
        0,
    )
    if hwnd == 0:
        raise Error(
            "CreateWindowExW failed, GetLastError = " + String(GetLastError())
        )

    # Before the window is shown, so it never flashes light chrome.
    # Publish the window handle. A second process could FindWindowW our
    # class instead, and a person's tooling may well prefer to -- but a file
    # needs no window station in common with us, which a build harness
    # launching Griddle does not always have. One line, no failure mode.
    var handle_path = String(env_or("TEMP", ".")) + "\\griddle.hwnd"
    with open(handle_path, "w") as f:
        f.write(String(hwnd))

    # An unattended run never inherits a session. A check that opens one
    # file and expects one tab would otherwise get whatever somebody had open
    # the last time they used the editor in this directory, and fail for a
    # reason that has nothing to do with what it is checking. `session
    # restore` asks for it explicitly when a check wants to exercise it.
    if command.byte_length() > 0:
        no_session = True

    # The menu first: it takes height from the client area, and the chrome's
    # layout is arithmetic on whatever is left.
    build_menu(hwnd)

    # 1200x800 was written for a 96 DPI display, so on a denser one the
    # window has to grow with everything in it. Done after creation rather
    # than in CreateWindowExW because the window has to exist before Windows
    # will say which display it landed on.
    var window_scale = dpi_scale(hwnd)
    var SetWindowPos = win32[
        def (
            Int, Int, c_int, c_int, c_int, c_int, UInt32
        ) thin abi("C") -> c_int,
        "SetWindowPos",
    ]()
    var want_w = Int(1200.0 * window_scale)
    var want_h = Int(800.0 * window_scale)

    # Fit the window to the monitor's work area, and it is not a nicety.
    #
    # CW_USEDEFAULT cascades: each launch places the window a little further
    # down and to the right than the last. On a 1440-tall screen a window
    # 1200 tall runs off the bottom after a few launches, and the part that is
    # off-screen is a part DWM never composes -- so `PrintWindow` photographs
    # it as white. That is the band along the bottom of unattended
    # screenshots, of a height that varies with how far the cascade had got:
    # 12, 52 and 88 pixels against 26, 64 and 102 pixels of overhang. It read
    # as a rendering fault for a day and was a window placement fault.
    #
    # The work area rather than the screen, because the taskbar is not
    # somewhere a window should open under either.
    var SystemParametersInfoW = win32[
        def (
            UInt32, UInt32, Pointer[RECT, MutAnyOrigin], UInt32
        ) thin abi("C") -> c_int,
        "SystemParametersInfoW",
    ]()
    var work = RECT()
    # SPI_GETWORKAREA is 0x0030. A #define rather than an enumeration, so
    # there is no metadata row for it.
    var have_work = SystemParametersInfoW(
        UInt32(0x0030),
        UInt32(0),
        Pointer(to=work).unsafe_origin_cast[MutAnyOrigin](),
        UInt32(0),
    )
    var GetWindowRect0 = win32[
        def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
        "GetWindowRect",
    ]()
    var placed = RECT()
    _ = GetWindowRect0(
        hwnd, Pointer(to=placed).unsafe_origin_cast[MutAnyOrigin]()
    )
    var x = Int(placed.left)
    var y = Int(placed.top)
    if have_work != 0:
        var work_w = Int(work.right - work.left)
        var work_h = Int(work.bottom - work.top)
        # Shrink before moving: a window taller than the work area cannot be
        # moved into it, and one that is merely too low can.
        if want_w > work_w:
            want_w = work_w
        if want_h > work_h:
            want_h = work_h
        if x + want_w > Int(work.right):
            x = Int(work.right) - want_w
        if y + want_h > Int(work.bottom):
            y = Int(work.bottom) - want_h
        if x < Int(work.left):
            x = Int(work.left)
        if y < Int(work.top):
            y = Int(work.top)
    # SWP_NOZORDER | SWP_NOACTIVATE. Also #defines, also named here.
    _ = SetWindowPos(
        hwnd, 0, c_int(x), c_int(y), c_int(want_w), c_int(want_h),
        UInt32(0x0004 | 0x0010),
    )

    # Shown BEFORE Direct2D is brought up, and the order is load-bearing.
    # An ID2D1HwndRenderTarget makes a DXGI swap chain for the window it is
    # given, and a swap chain made for a window that is not yet visible is
    # born occluded. Occluded is not an error: EndDraw returns S_OK and the
    # present is quietly skipped, so every HRESULT reads healthy, the text
    # layouts are all built and drawn, and the window stays the blank white
    # of a surface nothing was ever presented to. It cost most of an
    # afternoon precisely because nothing reports it -- see
    # docs/occlusion.md. The titlebar is darkened first so showing early
    # costs no flash of light chrome.
    var dark = dark_titlebar(hwnd)
    _ = ShowWindow(hwnd, c_int(winkb_constant["SW_SHOW"]()))

    # Direct2D, now that there is a visible window to present to. The chrome
    # outlives this scope -- the window procedure picks it up on every
    # WM_PAINT -- so it is heap-allocated and the window is told where it
    # lives.
    var rc0 = RECT()
    var GetClientRect0 = win32[
        def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
        "GetClientRect",
    ]()
    _ = GetClientRect0(hwnd, Pointer(to=rc0).unsafe_origin_cast[MutAnyOrigin]())
    var chrome_store = alloc[Chrome](1, alignment=8)
    # Emplaced, not assigned. `store[] = value` destroys what was there
    # first, and what is there is whatever the allocator last had. Chrome is
    # all integers so it would survive that; the document below is not, and
    # the two should not be spelled differently for a reason that subtle.
    chrome_store.unsafe_write(bring_up(
        hwnd,
        Int(rc0.right - rc0.left),
        Int(rc0.bottom - rc0.top),
        immediate=no_vsync,
    ))
    var SetWindowLongPtrW = win32[
        def (Int, c_int, Int) thin abi("C") -> Int, "SetWindowLongPtrW"
    ]()
    _ = SetWindowLongPtrW(
        hwnd, c_int(winkb_constant["GWLP_USERDATA"]()), Int(chrome_store)
    )

    # The document. Heap-allocated for the same reason the chrome is: the
    # window procedure reaches it through the one pointer Windows keeps.
    var doc_store = alloc[Doc](1, alignment=8)
    doc_store.unsafe_write(Doc(load_document(open_path, synth_lines)))
    if open_path.byte_length() > 0:
        doc_store[].uri = file_uri(absolute(open_path))
        doc_store[].had_bom = file_starts_with_bom(absolute(open_path))
        # The baseline for noticing that something else rewrote this file.
        try:
            doc_store[].disk_stamp = file_stamp(absolute(open_path))
        except:
            pass
    chrome_store[].doc = Int(doc_store)
    _ = adopt_tab(hwnd, Int(doc_store))
    # The project is the open file's directory. No configuration, no guessing
    # at a repository root: the folder the file is in is where a person is
    # working, and the tree can be pointed elsewhere at any time.
    try:
        # With a file open the project is its directory; with no file it is
        # the working directory itself. Taking the dirname in both cases made
        # a Griddle started with no file show its own parent, which is a
        # folder nobody was working in.
        var root = absolute(".")
        if open_path.byte_length() > 0:
            var here = absolute(open_path)
            var cut = here.rfind(chr(0x5C))
            if cut > 0:
                var folder = String(here[byte=0:cut])
                root = folder^
        print("griddle:", set_root(root))
        print("griddle:", watch_project(hwnd))
        # And what was open last time. After the tree, because restoring it
        # expands directories, and after the first tab, because the front tab
        # is chosen from among all of them.
        if not no_session:
            print("griddle:", restore_session(hwnd))
    except err:
        print("griddle: no project tree (", String(err), ")")

    # Once, at startup: the compiler and the debugger are both children of
    # this process and both need the toolchain's own DLLs findable.
    try:
        print("griddle:", ensure_linker())
    except err:
        print("griddle: toolchain not staged (", String(err), ")")

    # Before anything is compiled: an installed copy that has been moved
    # since it was packaged has a modular.cfg naming the packaging machine's
    # directories, and the launchers that fix that are not what a person
    # pinned to their taskbar. Silent when there is nothing to do, which is
    # every start after the first and every start from a source tree.
    try:
        var adopted = adopt_installed_toolchain()
        if adopted != "":
            print("griddle:", adopted)
    except err2:
        print("griddle: could not adopt the toolchain (", String(err2), ")")

    # The editor's heartbeat, and it is not the language server's. It used to
    # be: the timer was created only when a server started, so a text file
    # opened with --no-lsp had no timer at all and nothing polled the disk,
    # the build or anything else. Everything that has to notice the world
    # moving hangs off this tick, and it exists whether or not a server does.
    var SetTimer = win32[
        def (Int, Int, UInt32, Int) thin abi("C") -> Int, "SetTimer"
    ]()
    _ = SetTimer(hwnd, LSP_TIMER_ID, UInt32(LSP_POLL_MS), 0)

    # One row, at this display's density. The grid holds it because scrolling
    # and hit testing divide by it; the chrome holds the scale because the
    # font was made at it. They have to agree, so it is set from the chrome.
    doc_store[].grid.line_height = scaled(LINE_H, chrome_store[].scale)
    print(
        "griddle: document", doc_store[].rope.line_count(), "lines,",
        doc_store[].rope.byte_length(), "bytes",
    )

    # Drag and drop. OleInitialize (not CoInitializeEx) is what the drag
    # subsystem requires, and the apartment stays open for the life of the
    # window -- revoking happens before it closes.
    var ole = Apartment(ole=True)
    ole.__enter__()
    var drop = register_drop(hwnd)
    chrome_store[].drop_target = drop.address()

    # Text services, after the document: activation hands TSF a store that
    # reaches the document through this window, so the document has to be
    # there first. A machine without TSF, or one that refuses, is not fatal --
    # the editor falls back to WM_CHAR, which is what it had before 1.5.
    var tsf_store = alloc[Tsf](1, alignment=8)
    var tsf_live = False
    try:
        tsf_store.unsafe_write(activate(hwnd))
        chrome_store[].tsf = Int(tsf_store)
        tsf_live = True
        print("griddle: text services active, client", tsf_store[].client_id)
    except err:
        print("griddle: no text services (", String(err), ")")

    # Paint now rather than when the loop first idles: a command that reads
    # the grid's counters would otherwise be reading a window that has not
    # drawn a frame, and get zeroes that look like a bug.
    var InvalidateRect0 = win32[
        def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
    ]()
    var UpdateWindow = win32[
        def (Int) thin abi("C") -> c_int, "UpdateWindow"
    ]()
    retitle(hwnd)
    _ = InvalidateRect0(hwnd, 0, c_int(0))
    _ = UpdateWindow(hwnd)
    print(
        "griddle: window", hwnd, "open  dark-titlebar hr =", dark,
        "(0 = accepted)",
    )

    # The language server, if there is a real file to diagnose and a server
    # to ask. Neither is fatal: an editor with no server is the editor every
    # sprint before this one had.
    # Only for Mojo. A Mojo language server has nothing to say about a text
    # file, and starting one anyway costs a process and a parse for every
    # document a person opens -- which the check suite, whose fixtures are
    # .txt, would pay on every one of its sixty-odd runs.
    if open_path.endswith(".mojo") and not no_lsp:
        # From the toolchain, not spelled here. Written out as a relative
        # bazel-bin path this resolved against whatever directory the editor
        # was started in, so a packaged installation tried to start a server
        # inside the user's own project folder and failed naming it.
        print("griddle:", start_server(hwnd, lsp_exe(), lsp_stdlib()))

    if command.byte_length() > 0:
        # Nobody is watching this run, so nothing in it may stop to ask.
        set_unattended(True)
        # Ask ourselves, through the real message path. SendMessage to our
        # own window dispatches inline -- Windows calls the procedure
        # directly rather than queueing -- so this exercises the transport,
        # the handler and the dispatcher without a message loop and without
        # a second process. It is also why the check needs no second
        # desktop: nothing here crosses a process boundary.
        var SendMessageW = win32[
            def (
                Int, UInt32, Int, Pointer[COPYDATASTRUCT, MutAnyOrigin]
            ) thin abi("C") -> Int,
            "SendMessageW",
        ]()
        var reply_path = String(env_or("TEMP", ".")) + "\\griddle-selfcmd.txt"
        # `;;` separates several commands. One message each, so the transport
        # keeps its one-command-one-reply shape and the convenience lives
        # here, at the command line, where it belongs. A measurement that
        # needs a before and an after now takes one launch rather than two.
        for step in command.split(";;"):
            var one = String(String(step).strip())
            if one.byte_length() == 0:
                continue
            var payload = reply_path + "\n" + one
            var bytes = payload.as_bytes()
            var cds = COPYDATASTRUCT()
            cds.cbData = UInt32(len(bytes))
            cds.lpData = Int(bytes.unsafe_ptr())
            var accepted = SendMessageW(
                hwnd,
                UInt32(winkb_constant["WM_COPYDATA"]()),
                0,
                Pointer(to=cds).unsafe_origin_cast[MutAnyOrigin](),
            )
            _ = payload
            if accepted != 1:
                raise Error("the window did not accept the command")
            # Between commands, answer everything the window manager has
            # asked in the meantime. A run of twenty commands with a wait in
            # each is a minute of wall clock, and a window that says nothing
            # for a minute is a window Windows has already given up on.
            with open(reply_path, "r") as f:
                print(f.read(), end="")
            print()
            _ = drain(hwnd)
        try:
            stop_server()
        except:
            pass
        # Out through the same door a person leaves by. Returning from here
        # skipped WM_DESTROY, the drop target's revoke, the text store's
        # deactivate and the D2D release -- which is why an unattended run
        # left a process behind often enough to lock the build's own DLLs.
        var DestroyWindow = win32[
            def (Int) thin abi("C") -> c_int, "DestroyWindow"
        ]()
        _ = DestroyWindow(hwnd)
        _ = drain(hwnd)
        return

    if selftest:
        # Resize through the same call a user's drag ends in, and read the
        # client area back from Windows on both sides of it. "It opened" and
        # "it survives being resized" are different claims; this one is the
        # second, and the grid's whole layout is arithmetic on these numbers.
        var GetClientRect = win32[
            def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
            "GetClientRect",
        ]()
        var SetWindowPos = win32[
            def (
                Int, Int, c_int, c_int, c_int, c_int, UInt32
            ) thin abi("C") -> c_int,
            "SetWindowPos",
        ]()
        var rc = RECT()
        _ = GetClientRect(hwnd, Pointer(to=rc).unsafe_origin_cast[MutAnyOrigin]())
        print("griddle: client", rc.right - rc.left, "x", rc.bottom - rc.top)
        # SWP_NOZORDER, so the window keeps its place in the stack.
        _ = SetWindowPos(hwnd, 0, c_int(80), c_int(80), c_int(640), c_int(480),
                         UInt32(winkb_constant["SWP_NOZORDER"]()))
        var rc2 = RECT()
        _ = GetClientRect(hwnd, Pointer(to=rc2).unsafe_origin_cast[MutAnyOrigin]())
        print(
            "griddle: client", rc2.right - rc2.left, "x",
            rc2.bottom - rc2.top, "after resize",
        )
        var IsWindow = win32[def (Int) thin abi("C") -> c_int, "IsWindow"]()
        print("griddle: alive after resize:", IsWindow(hwnd) != 0)

        # Can anything find us by class name? The agent surface depends on a
        # second process doing exactly this, so ask from inside first: if we
        # cannot find ourselves, the class name is wrong, not the observer.
        var FindWindowW = win32[
            def (
                Pointer[UInt16, MutAnyOrigin], Int
            ) thin abi("C") -> Int,
            "FindWindowW",
        ]()
        var probe = wide("GriddleWindow")
        var found = FindWindowW(
            probe.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](), 0
        )
        _ = probe
        print("griddle: FindWindowW('GriddleWindow') ->", found,
              "(ours is", String(hwnd) + ")")

    if close_ms > 0:
        # Unattended: a timer whose tick destroys the window, so the timed
        # exit rejoins the human one at WM_DESTROY -- the same quit message,
        # the same clean-up, no second path to keep working.
        var SetTimer = win32[
            def (Int, Int, UInt32, Int) thin abi("C") -> Int, "SetTimer"
        ]()
        _ = SetTimer(hwnd, CLOSE_TIMER_ID, UInt32(close_ms), 0)
        print("griddle: closing in", close_ms, "ms")

    # The message loop. GetMessageW blocks, which is right for an editor:
    # idle costs no CPU, and the D2D redraw is driven by WM_PAINT rather than
    # by spinning. It answers 0 for WM_QUIT and -1 for an error.
    var msg = MSG()
    while True:
        var got = GetMessageW(Pointer(to=msg).unsafe_origin_cast[MutAnyOrigin](), 0, 0, 0)
        if got == 0:
            break
        if trace:
            print("griddle: msg", msg.message, "hwnd", msg.hwnd)
        if got == -1:
            raise Error(
                "GetMessageW failed, GetLastError = " + String(GetLastError())
            )
        # OUR timer means the unattended run is over; destroy the window and
        # let WM_DESTROY post the quit exactly as a real close would. The
        # identity checks are not defensive padding: the runtime posts
        # thread-level timers (WM_TIMER with a null hwnd) all by itself, and
        # treating one of those as the close signal shut the window within a
        # second of opening -- which reads exactly like "the window does not
        # stay up" and is nothing of the kind.
        if (
            msg.message == UInt32(winkb_constant["WM_TIMER"]())
            and msg.hwnd == hwnd
            and msg.wParam == CLOSE_TIMER_ID
        ):
            var DestroyWindow = win32[
                def (Int) thin abi("C") -> c_int, "DestroyWindow"
            ]()
            _ = DestroyWindow(hwnd)
            continue
        _ = TranslateMessage(Pointer(to=msg).unsafe_origin_cast[MutAnyOrigin]())
        _ = DispatchMessageW(Pointer(to=msg).unsafe_origin_cast[MutAnyOrigin]())

    try:
        stop_server()
    except:
        pass

    # Text services first: TSF holds a reference to a store that reaches the
    # document, so it has to let go before the document does.
    if tsf_live:
        try:
            deactivate(tsf_store[])
        except err:
            print("griddle: text services would not deactivate:", String(err))
        _ = tsf_store.unsafe_take_pointee()
    tsf_store.unsafe_free()

    # Give the target back before the window goes: OLE holds a reference to
    # it, and revoking is what returns that one.
    revoke_drop(hwnd)
    _ = drop
    ole.__exit__()
    release_cache(doc_store[].grid)
    # Moved out rather than merely freed: the document owns a rope, and
    # releasing the storage without running its destructor leaks every node.
    _ = doc_store.unsafe_take_pointee()
    doc_store.unsafe_free()
    release(chrome_store[])
    chrome_store.unsafe_free()
    print("griddle: closed cleanly")


def frame_budget_ns(hwnd: Int) raises -> Int:
    """One frame at this display's refresh rate, in nanoseconds.

    Asked of the display rather than assumed: "one frame" is the budget the
    sprint names, and 60 Hz is an assumption that is wrong on most machines
    bought in the last few years.
    """
    return 1_000_000_000 // refresh_hz(hwnd)


