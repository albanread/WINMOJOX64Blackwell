"""The project tree in the sidebar: what is on disk, expanded as you ask.

Milestone 5. Until now the only way to a second file was Ctrl+O and knowing
its path, which is not how anybody reads a project.

Lazy by construction. A directory's children are read when it is expanded and
forgotten when it is collapsed, so opening Griddle on a tree with a
`bazel-bin` in it costs one `FindFirstFileW` rather than a walk of four
hundred thousand files. The flat list is the display order: a row's depth is
what indents it, and collapsing removes the rows below it that are deeper.
That is the whole data structure, and it is a list because the thing being
drawn is a list.

`WIN32_FIND_DATAW` is read out of a raw buffer at the offsets the metadata
gives -- 592 bytes, `cFileName` at 44 -- rather than declared field by field.
It has two fixed-length arrays in it and no member this needs except the name
and one attribute bit; a Mojo struct mirroring it exactly would be a hundred
lines that exist to be skipped over.
"""

from std.ffi import c_int
from std.memory import Pointer, alloc
from std.sys._globals import named_global
from std.sys._winkb import winkb_struct_size

from ide.win32 import win32

# From the metadata, checked at compile time: if Windows ever disagrees this
# stops being a silent misread of somebody's filenames.
comptime FIND_DATA_BYTES = 592
comptime NAME_OFFSET = 44
comptime MAX_NAME_UNITS = 260

# FILE_ATTRIBUTE_DIRECTORY. A #define rather than an enumeration, so there is
# no metadata row to look it up in.
comptime FILE_ATTRIBUTE_DIRECTORY = 0x10
comptime INVALID_HANDLE = -1


@fieldwise_init
struct Entry(ImplicitlyCopyable, Movable):
    """One row of the tree."""

    var path: String
    var name: String
    var depth: Int
    var is_dir: Bool
    var expanded: Bool


comptime g_entries = named_global["tree.entries", List[Entry]]
comptime g_root = named_global["tree.root", String]
comptime g_top = named_global["tree.top", Int]


def entry_count() -> Int:
    """How many rows the tree has.

    Returns:
        The count.
    """
    return len(g_entries()[])


def entry_at(i: Int) raises -> Entry:
    """One row.

    Args:
        i: Its index.

    Returns:
        The row.

    Raises:
        If the index is out of range.
    """
    var entries = g_entries()
    if i < 0 or i >= len(entries[]):
        raise Error("no such tree row")
    return entries[][i]


def root_name() -> String:
    """The project root's own name, for the sidebar's heading.

    Returns:
        The last path component, or "GRIDDLE" when there is no root.
    """
    var root = g_root()[]
    if root.byte_length() == 0:
        return String("GRIDDLE")
    var cut = root.rfind(chr(0x5C))
    return String(root[byte=cut + 1 :]) if cut >= 0 else root


def top_row() -> Int:
    """The first row drawn, for scrolling a tree taller than the sidebar.

    Returns:
        The index.
    """
    return g_top()[]


def scroll_tree(by: Int):
    """Scroll the tree, clamped to what there is.

    Args:
        by: How many rows, positive for down.
    """
    var top = g_top()[] + by
    var limit = entry_count() - 1
    if top > limit:
        top = limit
    if top < 0:
        top = 0
    g_top()[] = top


def list_dir(path: String) raises -> List[Entry]:
    """One directory's children, directories first and each side by name.

    Directories first because that is how a project reads: the folders are
    the structure and the files are the leaves. Hidden entries and the `.`
    and `..` links are left out.

    Args:
        path: The directory.

    Returns:
        Its children, as rows with no depth set yet.

    Raises:
        If the entry points cannot be resolved.
    """
    comptime assert (
        FIND_DATA_BYTES == winkb_struct_size["WIN32_FIND_DATAW"]()
    ), "WIN32_FIND_DATAW is not the size this reads"

    var FindFirstFileW = win32[
        def (Pointer[UInt16, MutAnyOrigin], Int) thin abi("C") -> Int,
        "FindFirstFileW",
    ]()
    var FindNextFileW = win32[
        def (Int, Int) thin abi("C") -> c_int, "FindNextFileW"
    ]()
    var FindClose = win32[def (Int) thin abi("C") -> c_int, "FindClose"]()

    var dirs = List[Entry]()
    var files = List[Entry]()

    var pattern = _utf16z(path + "\\*")
    var data = alloc[UInt8](FIND_DATA_BYTES, alignment=8)
    var handle = FindFirstFileW(
        pattern.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](), Int(data)
    )
    _ = pattern
    if handle == INVALID_HANDLE or handle == 0:
        data.free()
        return dirs^

    while True:
        var attributes = (
            Pointer[UInt32, MutAnyOrigin](unsafe_from_address=Int(data))[]
        )
        var name = _name_at(Int(data) + NAME_OFFSET)
        # `.` and `..` are links back up the tree and would make it infinite.
        if name != "." and name != ".." and not name.startswith("."):
            var is_dir = (
                Int(attributes) & FILE_ATTRIBUTE_DIRECTORY
            ) != 0
            var row = Entry(path + "\\" + name, name, 0, is_dir, False)
            if is_dir:
                dirs.append(row^)
            else:
                files.append(row^)
        if FindNextFileW(handle, Int(data)) == 0:
            break
    _ = FindClose(handle)
    data.free()

    _sort_by_name(dirs)
    _sort_by_name(files)
    for f in files:
        dirs.append(f)
    return dirs^


def _sort_by_name(mut rows: List[Entry]):
    """Insertion sort by name. The list is one directory's worth -- tens of
    entries, occasionally thousands -- and an insertion sort on that is faster
    to run than a better one is to write."""
    var i = 1
    while i < len(rows):
        var j = i
        while j > 0 and rows[j - 1].name > rows[j].name:
            rows.swap_elements(j - 1, j)
            j -= 1
        i += 1


def _name_at(address: Int) -> String:
    """The NUL-terminated UTF-16 name at an address, as a String."""
    var p = Pointer[UInt16, MutAnyOrigin](unsafe_from_address=address)
    var out = String("")
    var i = 0
    while i < MAX_NAME_UNITS:
        var unit = Int(p[i])
        if unit == 0:
            break
        if unit >= 0xD800 and unit <= 0xDBFF and i + 1 < MAX_NAME_UNITS:
            var lo = Int(p[i + 1])
            if lo >= 0xDC00 and lo <= 0xDFFF:
                out += chr(0x10000 + ((unit - 0xD800) << 10) + (lo - 0xDC00))
                i += 2
                continue
        out += chr(unit)
        i += 1
    return out^


def _utf16z(s: String) -> List[UInt16]:
    """A NUL-terminated UTF-16 copy, for a PCWSTR parameter."""
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


def set_root(path: String) raises -> String:
    """Show a directory as the project.

    Args:
        path: The directory.

    Returns:
        What happened.

    Raises:
        If the directory cannot be read.
    """
    g_root()[] = path
    g_top()[] = 0
    var rows = list_dir(path)
    g_entries()[] = rows^
    return (
        String("project ") + path + " (" + String(entry_count())
        + " entries)"
    )


def toggle(i: Int) raises -> String:
    """Expand or collapse a directory row.

    Args:
        i: Which row.

    Returns:
        What happened.

    Raises:
        If the row does not exist.
    """
    var entries = g_entries()
    if i < 0 or i >= len(entries[]):
        return String("no such row")
    if not entries[][i].is_dir:
        return String("not a directory")

    if entries[][i].expanded:
        # Collapse: everything below it that is deeper belongs to it.
        var depth = entries[][i].depth
        var j = i + 1
        while j < len(entries[]) and entries[][j].depth > depth:
            _ = entries[].pop(i + 1)
        entries[][i].expanded = False
        return String("collapsed ") + entries[][i].name

    var children = list_dir(entries[][i].path)
    var depth = entries[][i].depth + 1
    var at = i + 1
    for child in children:
        var row = child
        row.depth = depth
        entries[].insert(at, row^)
        at += 1
    entries[][i].expanded = True
    return (
        String("expanded ") + entries[][i].name + " ("
        + String(len(children)) + " entries)"
    )


def tree_report() raises -> String:
    """The tree as text, indented the way it is drawn.

    Returns:
        `tree N` and a line each.

    Raises:
        Never in practice.
    """
    var out = String("tree ") + String(entry_count()) + "\n"
    for i in range(entry_count()):
        var e = entry_at(i)
        var mark = String("  ")
        if e.is_dir:
            mark = "- " if e.expanded else "+ "
        out += " " * (e.depth * 2) + mark + e.name + "\n"
    return out^
