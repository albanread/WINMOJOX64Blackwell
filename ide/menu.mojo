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
    _append(AppendMenuW, file, winkb_constant["MF_SEPARATOR"](), 0, "")
    _append(AppendMenuW, file, winkb_constant["MF_STRING"](), ID_FILE_EXIT,
            "Exit")
    _append(AppendMenuW, bar, winkb_constant["MF_POPUP"](), file, "File")

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
    """The visible label of one menu item, by position."""
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
        out += chr(Int(buffer[k]))
    return out


def utf16(s: StaticString) -> List[UInt16]:
    """A NUL-terminated UTF-16 copy of ASCII text."""
    var out = List[UInt16]()
    for byte in s.as_bytes():
        out.append(UInt16(Int(byte)))
    out.append(0)
    return out^
