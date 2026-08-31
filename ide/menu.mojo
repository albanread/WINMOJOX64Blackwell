"""The menu bar, and invoking it by the names a person can read.

A real Win32 menu, not a drawn one: it costs nothing, it behaves the way
every other Windows program does, and -- the reason it earns its place in
this sprint -- an agent can drive it by the words on screen. The Mac team
called menu-invocation-by-name the master key, because every feature that
ever gets a menu item joins the scriptable surface at a stroke rather than
needing a verb of its own. The same is true here.

`menu File > Exit` walks the live menu, matches the visible strings, and
sends the item's own command. Nothing is hard-coded and nothing is
duplicated: if the item moves or is renamed, the walk finds it or honestly
does not.
"""

from std.ffi import c_int
from std.memory import Pointer
from std.sys._winkb import winkb_constant

from ide.win32 import win32


# Command ids. Small and explicit: the agent never uses them -- it uses the
# visible names -- but WM_COMMAND arrives carrying one.
comptime ID_FILE_NEW = 1006
comptime ID_FILE_CLOSE_TAB = 1007

# Edit. An IDE without cut, copy and paste is not an editor, and Griddle had
# none of the three until this sprint. The menu is where that absence was
# loudest, which is a fair argument for building the menu bar early.
comptime ID_EDIT_UNDO = 1030
comptime ID_EDIT_REDO = 1031
comptime ID_EDIT_CUT = 1032
comptime ID_EDIT_COPY = 1033
comptime ID_EDIT_PASTE = 1034
comptime ID_EDIT_SELECT_ALL = 1035
comptime ID_EDIT_FIND = 1036
comptime ID_EDIT_FIND_NEXT = 1037
comptime ID_EDIT_FIND_PREV = 1038
comptime ID_EDIT_REPLACE = 1039
comptime ID_EDIT_SEARCH_PROJECT = 1040

# Go. Everything that moves the caret somewhere it was not, which is a
# different kind of act from editing and earns its own list.
comptime ID_GO_DEFINITION = 1050
comptime ID_GO_REFERENCES = 1051
comptime ID_GO_SYMBOL = 1052
comptime ID_GO_BACK = 1053
comptime ID_GO_NEXT_TAB = 1054
comptime ID_GO_PREV_TAB = 1055

comptime ID_BUILD_STEP_OUT = 1027
comptime ID_BUILD_RUN_TO_CARET = 1017
comptime ID_BUILD_EVALUATE = 1018
comptime ID_BUILD_CLEAR_BREAKPOINTS = 1019

comptime ID_VIEW_OUTLINE = 1023
comptime ID_VIEW_TOOLCHAIN = 1024
comptime ID_VIEW_PYTHON = 1025
comptime ID_VIEW_PROBLEMS = 1026
comptime ID_VIEW_ZOOM_IN = 1020
comptime ID_VIEW_ZOOM_OUT = 1021
comptime ID_VIEW_ZOOM_RESET = 1022
comptime ID_BUILD_RUN = 1010
comptime ID_BUILD_BUILD = 1011
comptime ID_BUILD_STOP = 1012
comptime ID_BUILD_DEBUG = 1013
comptime ID_BUILD_STEP_OVER = 1014
comptime ID_BUILD_STEP_INTO = 1015
comptime ID_BUILD_BREAKPOINT = 1016
comptime ID_FILE_OPEN = 1003
comptime ID_FILE_SAVE = 1004
comptime ID_FILE_SAVE_AS = 1005
comptime ID_FILE_EXIT = 1001


def build(hwnd: Int) raises:
    """Attach Griddle's menu bar to the window.

    Args:
        hwnd: The window to attach to.

    Raises:
        If Windows refuses to create or set the menu.
    """
    var CreateMenu = win32[def () thin abi("C") -> Int, "CreateMenu"]()
    var CreatePopupMenu = win32[
        def () thin abi("C") -> Int, "CreatePopupMenu"
    ]()
    var AppendMenuW = win32[
        def (
            Int, UInt32, Int, Pointer[UInt16, MutAnyOrigin]
        ) thin abi("C") -> c_int,
        "AppendMenuW",
    ]()
    var SetMenu = win32[def (Int, Int) thin abi("C") -> c_int, "SetMenu"]()

    var bar = CreateMenu()
    if bar == 0:
        raise Error("CreateMenu failed")

    var file = CreatePopupMenu()
    # The accelerators are in the labels because they are what a person looks
    # for; the keys themselves are handled in the window procedure, which is
    # where they work whether or not the menu is open.
    _append(AppendMenuW, file, winkb_constant["MF_STRING"](), ID_FILE_OPEN,
            "Open...\tCtrl+O")
    _append(AppendMenuW, file, winkb_constant["MF_STRING"](), ID_FILE_SAVE,
            "Save\tCtrl+S")
    _append(AppendMenuW, file, winkb_constant["MF_STRING"](), ID_FILE_SAVE_AS,
            "Save As...\tCtrl+Shift+S")
    _append(AppendMenuW, file, winkb_constant["MF_STRING"](),
            ID_FILE_NEW, "New\tCtrl+N")
    _append(AppendMenuW, file, winkb_constant["MF_STRING"](),
            ID_FILE_CLOSE_TAB, "Close Tab\tCtrl+W")
    _append(AppendMenuW, file, winkb_constant["MF_SEPARATOR"](), 0, "")
    _append(AppendMenuW, file, winkb_constant["MF_STRING"](), ID_FILE_EXIT,
            "Exit")
    _append(AppendMenuW, bar, winkb_constant["MF_POPUP"](), file, "File")

    # Edit and Go sit where every Windows editor puts them, between File
    # and View. The order within each is the order a person reaches for
    # them, not the order they were implemented.
    var edit = CreatePopupMenu()
    _append(AppendMenuW, edit, winkb_constant["MF_STRING"](),
            ID_EDIT_UNDO, "Undo\tCtrl+Z")
    _append(AppendMenuW, edit, winkb_constant["MF_STRING"](),
            ID_EDIT_REDO, "Redo\tCtrl+Y")
    _append(AppendMenuW, edit, winkb_constant["MF_SEPARATOR"](), 0, "")
    _append(AppendMenuW, edit, winkb_constant["MF_STRING"](),
            ID_EDIT_CUT, "Cut\tCtrl+X")
    _append(AppendMenuW, edit, winkb_constant["MF_STRING"](),
            ID_EDIT_COPY, "Copy\tCtrl+C")
    _append(AppendMenuW, edit, winkb_constant["MF_STRING"](),
            ID_EDIT_PASTE, "Paste\tCtrl+V")
    _append(AppendMenuW, edit, winkb_constant["MF_STRING"](),
            ID_EDIT_SELECT_ALL, "Select All\tCtrl+A")
    _append(AppendMenuW, edit, winkb_constant["MF_SEPARATOR"](), 0, "")
    _append(AppendMenuW, edit, winkb_constant["MF_STRING"](),
            ID_EDIT_FIND, "Find\tCtrl+F")
    _append(AppendMenuW, edit, winkb_constant["MF_STRING"](),
            ID_EDIT_FIND_NEXT, "Find Next\tF3")
    _append(AppendMenuW, edit, winkb_constant["MF_STRING"](),
            ID_EDIT_FIND_PREV, "Find Previous\tShift+F3")
    _append(AppendMenuW, edit, winkb_constant["MF_STRING"](),
            ID_EDIT_REPLACE, "Replace\tCtrl+H")
    _append(AppendMenuW, edit, winkb_constant["MF_STRING"](),
            ID_EDIT_SEARCH_PROJECT, "Find in Project\tCtrl+Shift+F")
    _append(AppendMenuW, bar, winkb_constant["MF_POPUP"](), edit, "Edit")

    var go = CreatePopupMenu()
    _append(AppendMenuW, go, winkb_constant["MF_STRING"](),
            ID_GO_DEFINITION, "Definition\tF12")
    _append(AppendMenuW, go, winkb_constant["MF_STRING"](),
            ID_GO_REFERENCES, "References\tShift+F12")
    _append(AppendMenuW, go, winkb_constant["MF_STRING"](),
            ID_GO_SYMBOL, "Symbol in File\tCtrl+Shift+O")
    _append(AppendMenuW, go, winkb_constant["MF_SEPARATOR"](), 0, "")
    _append(AppendMenuW, go, winkb_constant["MF_STRING"](),
            ID_GO_BACK, "Back\tAlt+Left")
    _append(AppendMenuW, go, winkb_constant["MF_SEPARATOR"](), 0, "")
    _append(AppendMenuW, go, winkb_constant["MF_STRING"](),
            ID_GO_NEXT_TAB, "Next Tab\tCtrl+Tab")
    _append(AppendMenuW, go, winkb_constant["MF_STRING"](),
            ID_GO_PREV_TAB, "Previous Tab\tCtrl+Shift+Tab")
    _append(AppendMenuW, bar, winkb_constant["MF_POPUP"](), go, "Go")

    var view = CreatePopupMenu()
    _append(AppendMenuW, view, winkb_constant["MF_STRING"](),
            ID_VIEW_ZOOM_IN, "Zoom In\tCtrl++")
    _append(AppendMenuW, view, winkb_constant["MF_STRING"](),
            ID_VIEW_ZOOM_OUT, "Zoom Out\tCtrl+-")
    _append(AppendMenuW, view, winkb_constant["MF_STRING"](),
            ID_VIEW_ZOOM_RESET, "Reset Zoom\tCtrl+0")
    # The bottom pane's four other faces. They are menu items and not only
    # keys because they are the answer to "where has my problem list gone" --
    # a pane that changes what it shows needs somewhere that lists what it
    # can show.
    _append(AppendMenuW, view, winkb_constant["MF_SEPARATOR"](), 0, "")
    _append(AppendMenuW, view, winkb_constant["MF_STRING"](),
            ID_VIEW_OUTLINE, "Outline	Ctrl+Shift+O")
    _append(AppendMenuW, view, winkb_constant["MF_STRING"](),
            ID_VIEW_PROBLEMS, "Problems")
    _append(AppendMenuW, view, winkb_constant["MF_STRING"](),
            ID_VIEW_TOOLCHAIN, "Toolchain")
    _append(AppendMenuW, view, winkb_constant["MF_STRING"](),
            ID_VIEW_PYTHON, "Python")
    _append(AppendMenuW, bar, winkb_constant["MF_POPUP"](), view, "View")

    var build = CreatePopupMenu()
    _append(AppendMenuW, build, winkb_constant["MF_STRING"](), ID_BUILD_RUN,
            "Run Without Debugging\tCtrl+F5")
    _append(AppendMenuW, build, winkb_constant["MF_STRING"](), ID_BUILD_BUILD,
            "Build\tCtrl+B")
    _append(AppendMenuW, build, winkb_constant["MF_SEPARATOR"](), 0, "")
    _append(AppendMenuW, build, winkb_constant["MF_STRING"](), ID_BUILD_DEBUG,
            "Debug\tF5")
    _append(AppendMenuW, build, winkb_constant["MF_STRING"](),
            ID_BUILD_STEP_OVER, "Step Over\tF10")
    _append(AppendMenuW, build, winkb_constant["MF_STRING"](),
            ID_BUILD_STEP_INTO, "Step Into\tF11")
    _append(AppendMenuW, build, winkb_constant["MF_STRING"](),
            ID_BUILD_STEP_OUT, "Step Out\tShift+F11")
    _append(AppendMenuW, build, winkb_constant["MF_STRING"](),
            ID_BUILD_RUN_TO_CARET, "Run to Cursor\tCtrl+F10")
    _append(AppendMenuW, build, winkb_constant["MF_STRING"](),
            ID_BUILD_EVALUATE, "Evaluate\tCtrl+I")
    _append(AppendMenuW, build, winkb_constant["MF_SEPARATOR"](), 0, "")
    _append(AppendMenuW, build, winkb_constant["MF_STRING"](),
            ID_BUILD_BREAKPOINT, "Toggle Breakpoint\tF9")
    _append(AppendMenuW, build, winkb_constant["MF_STRING"](),
            ID_BUILD_CLEAR_BREAKPOINTS, "Clear All Breakpoints")
    _append(AppendMenuW, build, winkb_constant["MF_SEPARATOR"](), 0, "")
    _append(AppendMenuW, build, winkb_constant["MF_STRING"](), ID_BUILD_STOP,
            "Stop\tShift+F5")
    _append(AppendMenuW, bar, winkb_constant["MF_POPUP"](), build, "Build")

    var help = CreatePopupMenu()
    _append(AppendMenuW, help, winkb_constant["MF_STRING"](), 1002, "About")
    _append(AppendMenuW, bar, winkb_constant["MF_POPUP"](), help, "Help")

    if SetMenu(hwnd, bar) == 0:
        raise Error("SetMenu failed")


def _append(
    AppendMenuW: def (
        Int, UInt32, Int, Pointer[UInt16, MutAnyOrigin]
    ) thin abi("C") -> c_int,
    menu: Int,
    flags: Int,
    id_or_submenu: Int,
    text: StaticString,
) raises:
    """Append one item, keeping its label alive across the call."""
    var label = utf16(text)
    _ = AppendMenuW(
        menu,
        UInt32(flags),
        id_or_submenu,
        label.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
    )
    # The label must outlive the call: Windows copies it, but not before.
    _ = label


def report(hwnd: Int) raises -> String:
    """The whole menu bar, as text, without invoking any of it.

    Reading the bar and firing it are different acts, and a check that wanted
    the first had to do the second: walking the items by invoking them meant
    File > Exit ended the walk, and Save As put a modal dialog in front of it.
    This asks Windows what the menus contain and answers with names, which is
    also the only list of Griddle's features that cannot drift from the
    features -- it is read from the live menu rather than written down.

    Args:
        hwnd: The window whose menu to walk.

    Returns:
        `menu N` and a `Title > Item (id)` line each.

    Raises:
        If the menu cannot be read.
    """
    var GetMenu = win32[def (Int) thin abi("C") -> Int, "GetMenu"]()
    var GetSubMenu = win32[
        def (Int, c_int) thin abi("C") -> Int, "GetSubMenu"
    ]()
    var GetMenuItemCount = win32[
        def (Int) thin abi("C") -> c_int, "GetMenuItemCount"
    ]()
    var GetMenuStringW = win32[
        def (
            Int, UInt32, Pointer[UInt16, MutAnyOrigin], c_int, UInt32
        ) thin abi("C") -> c_int,
        "GetMenuStringW",
    ]()
    var GetMenuItemID = win32[
        def (Int, c_int) thin abi("C") -> UInt32, "GetMenuItemID"
    ]()

    var bar = GetMenu(hwnd)
    if bar == 0:
        return String("menu 0")
    var lines = String("")
    var total = 0
    var count = Int(GetMenuItemCount(bar))
    for i in range(count):
        var title = _item_text(GetMenuStringW, bar, i)
        var sub = GetSubMenu(bar, c_int(i))
        if sub == 0:
            continue
        var sub_count = Int(GetMenuItemCount(sub))
        for j in range(sub_count):
            var name = _item_text(GetMenuStringW, sub, j)
            if name.byte_length() == 0:
                # A separator has no name. It is a line on the screen and
                # nothing to a person naming a command.
                continue
            var id = Int(GetMenuItemID(sub, c_int(j)))
            lines += (
                "  " + title + " > " + name + " (" + String(id) + ")\n"
            )
            total += 1
    return String("menu ") + String(total) + "\n" + lines


def invoke(hwnd: Int, path: StringSlice) raises -> String:
    """Invoke a menu item named like `File > Exit`.

    The names are matched against what the menu actually shows, so this
    reaches any item the IDE ever grows without anyone adding a verb for it.

    Args:
        hwnd: The window whose menu to walk.
        path: `Title > Item`, as the menu spells them.

    Returns:
        What happened, as text.

    Raises:
        If the menu cannot be read.
    """
    var GetMenu = win32[def (Int) thin abi("C") -> Int, "GetMenu"]()
    var GetSubMenu = win32[
        def (Int, c_int) thin abi("C") -> Int, "GetSubMenu"
    ]()
    var GetMenuItemCount = win32[
        def (Int) thin abi("C") -> c_int, "GetMenuItemCount"
    ]()
    var GetMenuStringW = win32[
        def (
            Int, UInt32, Pointer[UInt16, MutAnyOrigin], c_int, UInt32
        ) thin abi("C") -> c_int,
        "GetMenuStringW",
    ]()
    var GetMenuItemID = win32[
        def (Int, c_int) thin abi("C") -> UInt32, "GetMenuItemID"
    ]()
    var PostMessageW = win32[
        def (Int, UInt32, Int, Int) thin abi("C") -> c_int, "PostMessageW"
    ]()

    var arrow = String(path).find(">")
    if arrow < 0:
        return String("error: expected 'Title > Item'")
    var want_menu = String(String(path[byte=:arrow]).strip())
    var want_item = String(String(path[byte=arrow + 1 :]).strip())

    var bar = GetMenu(hwnd)
    if bar == 0:
        return String("error: this window has no menu")

    var count = Int(GetMenuItemCount(bar))
    for i in range(count):
        if _item_text(GetMenuStringW, bar, i) != want_menu:
            continue
        var sub = GetSubMenu(bar, c_int(i))
        if sub == 0:
            return String("error: '") + want_menu + "' has no items"
        var sub_count = Int(GetMenuItemCount(sub))
        for j in range(sub_count):
            if _item_text(GetMenuStringW, sub, j) != want_item:
                continue
            var id = Int(GetMenuItemID(sub, c_int(j)))
            # Posted, not sent: the caller gets its answer back before the
            # command runs, which matters when the command is Exit.
            _ = PostMessageW(
                hwnd, UInt32(winkb_constant["WM_COMMAND"]()), id, 0
            )
            return (
                String("invoked ") + want_menu + " > " + want_item
                + " (id " + String(id) + ")"
            )
        return String("error: no item '") + want_item + "' in " + want_menu
    return String("error: no menu '") + want_menu + "'"


def _item_text(
    GetMenuStringW: def (
        Int, UInt32, Pointer[UInt16, MutAnyOrigin], c_int, UInt32
    ) thin abi("C") -> c_int,
    menu: Int,
    index: Int,
) -> String:
    """The name of one menu item, by position, without its accelerator.

    Windows keeps the shortcut hint in the same string as the name, after a
    tab, so `GetMenuStringW` hands back `Save<tab>Ctrl+S`. That is one string
    to Windows and two things to a person: the item is called Save, and Ctrl+S
    is another way to reach it. Matching the whole string would mean no item
    with a shortcut could be named -- which was true until this stopped at the
    tab, and left every accelerated item unreachable to `menu` and therefore
    uncheckable.
    """
    var buffer = List[UInt16]()
    for _ in range(128):
        buffer.append(0)
    var n = GetMenuStringW(
        menu,
        UInt32(index),
        buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        c_int(128),
        UInt32(0x0400),  # MF_BYPOSITION
    )
    var out = String("")
    for k in range(Int(n)):
        var c = Int(buffer[k])
        if c == 9:
            break
        out += chr(c)
    return out


def utf16(s: StaticString) -> List[UInt16]:
    """A NUL-terminated UTF-16 copy of ASCII text."""
    var out = List[UInt16]()
    for byte in s.as_bytes():
        out.append(UInt16(Int(byte)))
    out.append(0)
    return out^
