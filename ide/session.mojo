"""Remembering where you were: which files were open, and where in them.

Griddle forgets everything when it closes. Reopening a project has meant
finding every file again through the tree, re-expanding the four directories
it took to reach them, and putting the breakpoints back on the lines you had
already worked out were the interesting ones. That is a minute of nothing,
paid every time, and it is the reason people leave editors running for weeks.

This module is the remembering, and it is deliberately the dullest thing in
the tree. It knows about paths and numbers. It does not know what a window
is, it never opens a document, and it never touches the tree -- it is handed
plain data and it hands plain data back, and the editor decides what to do
with it. That is not tidiness for its own sake: `ide/window.mojo` already
imports the tree, the documents and the debugger, so a session module that
imported the window in order to "just restore things itself" would close a
cycle and stop compiling. Keeping the knowledge one-way is what keeps it
buildable.

The other half of the design is that loading a session is a convenience and
may never be the reason an editor will not start. Every failure this can meet
-- no file, a file truncated by a power cut, a file describing sources that a
`git checkout` deleted an hour ago -- resolves to "restore less, say so, and
carry on". There is no failure mode here that reaches the user as an error
box, because there is nothing a user could usefully do about one.
"""

from std.ffi import c_int
from std.memory import Pointer
from std.sys._globals import named_global
from std.sys._winkb import winkb_constant

from ide.json import ARRAY, JSON, OBJECT, parse
from ide.win32 import absolute, win32


# The session lives NEXT TO THE PROJECT, under this name, rather than in a
# global store keyed by path. A central registry goes stale the moment
# somebody renames a directory -- the sessions are all still there, all
# pointing at paths that no longer exist, and none of them can be found by the
# project they describe. It also accumulates entries for projects that were
# deleted years ago, which nothing ever cleans up because nothing is told.
# A file beside the project moves when the project moves, is copied when the
# project is copied, and is deleted when the project is deleted, all without
# this module being involved.
comptime SESSION_NAME = ".griddle-session.json"

# What the file says it is, so a later format can tell itself apart from this
# one instead of misreading it.
comptime SESSION_VERSION = 1

# A session is a convenience, not a database. Somebody who has opened four
# hundred files over an afternoon does not want four hundred of them back, and
# a session file that grows without bound is one more thing to go wrong in a
# path where nothing is allowed to go wrong. The caps are applied when writing
# and again when reading, because a file written by some other version of this
# is still a file this has to survive.
comptime MAX_FILES = 50
comptime MAX_EXPANDED = 200

# From the metadata rather than transcribed. MOVEFILE_REPLACE_EXISTING is 1
# and MOVEFILE_COPY_ALLOWED is 2, and the two are easy to swap when typing
# from memory -- with the effect that the replace silently does not happen and
# every save after the first one fails.
comptime MOVEFILE_REPLACE_EXISTING = UInt32(
    winkb_constant["MOVEFILE_REPLACE_EXISTING"]()
)

# Also from the metadata, but it needs a word. The database gives the signed
# reading, which is -1, and `GetFileAttributesW` returns an unsigned 32-bit
# value, so comparing them directly is a test that can never be true and every
# file would look as though it existed. Masking to 32 bits is the comparison
# both sides agree on.
comptime INVALID_FILE_ATTRIBUTES = (
    winkb_constant["INVALID_FILE_ATTRIBUTES"]() & 0xFFFFFFFF
)

comptime BACKSLASH = 0x5C
comptime FORWARD_SLASH = 0x2F


@fieldwise_init
struct OpenFile(ImplicitlyCopyable, Movable):
    """One file that was open, and everything about where you were in it.

    Line and column are zero-based throughout, the way `ide/doc.mojo` holds
    them, so that restoring a session is an assignment rather than an
    arithmetic that has to be got right in two places.
    """

    var path: String
    var caret_line: Int
    var caret_col: Int
    # What the view was scrolled to, kept separately from the caret. A caret
    # on line 900 restored into a view scrolled to the top puts the line you
    # were reading at the very bottom of the window, which is not where you
    # left it.
    var top_line: Int
    var breakpoints: List[Int]

    def __init__(out self, *, copy: Self):
        """Copy one, breakpoints and all.

        Written out rather than synthesized because a `List` is deliberately
        not implicitly copyable, so a struct containing one cannot have its
        copy constructor generated. This type is small -- four integers, a
        path and a handful of line numbers -- and it is handed across a
        module boundary by value on purpose, which is what `ImplicitlyCopyable`
        is for.

        Args:
            copy: The one to copy.
        """
        self.path = copy.path
        self.caret_line = copy.caret_line
        self.caret_col = copy.caret_col
        self.top_line = copy.top_line
        self.breakpoints = copy.breakpoints.copy()


comptime g_files = named_global["session.files", List[OpenFile]]
comptime g_current = named_global["session.current", Int]
comptime g_expanded = named_global["session.expanded", List[String]]
comptime g_dropped = named_global["session.dropped", Int]


# ===----------------------------------------------------------------------===#
# Where it lives
# ===----------------------------------------------------------------------===#


def session_path(project_root: String) raises -> String:
    """Where this project's session file lives.

    Args:
        project_root: The directory the tree is showing.

    Returns:
        The full path of the session file, beside the project.

    Raises:
        If the path cannot be resolved to an absolute one.
    """
    return _join(project_root, String(SESSION_NAME))


def _join(directory: String, name: String) raises -> String:
    """A file inside a directory, absolute, with exactly one separator."""
    var root = absolute(directory)
    # A drive root arrives with a trailing separator on it and every other
    # directory arrives without one, so appending one unconditionally gives a
    # doubled separator for exactly the caller whose project is a whole drive.
    # Windows forgives that in most calls and not in all of them, and the ones
    # that do not forgive it fail in ways that read as "the project is gone".
    while root.byte_length() > 1:
        var last = Int(root.as_bytes()[root.byte_length() - 1])
        if last != BACKSLASH and last != FORWARD_SLASH:
            break
        # The slice has to land in a fresh variable first: assigning a slice of
        # a string back over that same string is a compile error, because the
        # source is being destroyed while it is still being read.
        var trimmed = String(root[byte = 0 : root.byte_length() - 1])
        root = trimmed^
    return root + "\\" + name


# ===----------------------------------------------------------------------===#
# Writing it
# ===----------------------------------------------------------------------===#


def save_session(
    project_root: String,
    files: List[OpenFile],
    current: Int,
    expanded: List[String],
) raises -> String:
    """Write the session file for a project.

    Args:
        project_root: The directory the tree is showing.
        files: The open files, in tab order.
        current: Which of them was in front, as an index into `files`.
        expanded: The directories the tree had open.

    Returns:
        A sentence saying what was written and where.

    Raises:
        If the path cannot be resolved or the temporary file cannot be
        written.
    """
    var path = session_path(project_root)

    var root = JSON.object()
    root.set(String("version"), JSON(SESSION_VERSION))
    root.set(String("current"), JSON(current))

    var files_json = JSON.array()
    var written = 0
    while written < len(files) and written < MAX_FILES:
        var one = JSON.object()
        # Absolute, always. A relative path in a session file means the
        # session only works when the editor happens to be started from the
        # same directory it was saved from -- launched from the Start menu, or
        # from a shortcut, or by double-clicking a file, it restores nothing
        # and cannot say why. Nobody expects a saved position to depend on a
        # working directory, so the dependency is removed here rather than
        # documented.
        one.set(String("path"), JSON(absolute(files[written].path)))
        one.set(String("caret_line"), JSON(files[written].caret_line))
        one.set(String("caret_col"), JSON(files[written].caret_col))
        one.set(String("top_line"), JSON(files[written].top_line))
        var marks = JSON.array()
        for k in range(len(files[written].breakpoints)):
            marks.push(JSON(files[written].breakpoints[k]))
        one.set(String("breakpoints"), marks^)
        files_json.push(one^)
        written += 1
    root.set(String("files"), files_json^)

    var folders = JSON.array()
    var kept = 0
    while kept < len(expanded) and kept < MAX_EXPANDED:
        folders.push(JSON(absolute(expanded[kept])))
        kept += 1
    root.set(String("expanded"), folders^)

    # Through `ide/json.mojo` rather than by assembling the text here. A
    # Windows path is a string full of backslashes and every one of them has
    # to be doubled; a project under "C:\Users\somebody\Documents" written by
    # hand produces a file that this module's own reader cannot parse, and the
    # failure surfaces as "there was no session" rather than as a bug.
    var text = root.serialize()

    # Atomic enough. Writing straight over the session file means that a
    # crash, a full disk or a lost network drive halfway through leaves a
    # truncated file -- which is strictly worse than a stale one, because a
    # stale session restores yesterday's work and a truncated one restores
    # nothing while looking like a corruption. So: write beside it, then
    # rename over it, and a failure at any point leaves the previous session
    # exactly as it was.
    #
    # The process id is in the temporary name because two Griddles can have
    # the same project open, and two saves landing on one temporary file would
    # interleave into a file that is neither of them.
    var GetCurrentProcessId = win32[
        def () thin abi("C") -> UInt32, "GetCurrentProcessId"
    ]()
    var temporary = (
        path + "." + String(Int(GetCurrentProcessId())) + ".tmp"
    )
    # Closed by name rather than by leaving a `with open(...)` block. Within
    # one function the handle outlives its block -- it is destroyed when the
    # function returns, not when the indentation ends -- so a `with` here
    # would still hold the file open at the rename, and `MoveFileExW` would
    # fail with ERROR_SHARING_VIOLATION every single time. It is invisible
    # anywhere the file is only read, which is why every other `with open` in
    # the tree is fine and this one is not.
    var f = open(temporary, "w")
    f.write(text)
    f.close()

    var MoveFileExW = win32[
        def (
            Pointer[UInt16, MutAnyOrigin],
            Pointer[UInt16, MutAnyOrigin],
            UInt32,
        ) thin abi("C") -> c_int,
        "MoveFileExW",
    ]()
    var from_wide = _utf16z(temporary)
    var to_wide = _utf16z(path)
    var moved = MoveFileExW(
        from_wide.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        to_wide.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        MOVEFILE_REPLACE_EXISTING,
    )
    _ = from_wide
    _ = to_wide
    if moved == 0:
        # The rename is the only step that can fail after something has been
        # written, so it is the only one that can leave litter. Take the
        # temporary away and report; the old session file is untouched and
        # still loadable, which is the whole point of doing it this way.
        _ = _delete(temporary)
        return String("could not replace ") + path + " (session not saved)"

    return (
        String("saved ")
        + String(written)
        + " files and "
        + String(kept)
        + " folders to "
        + path
    )


# ===----------------------------------------------------------------------===#
# Reading it back
# ===----------------------------------------------------------------------===#


def load_session(project_root: String) raises -> Bool:
    """Read a project's session file into this module's state.

    A missing file, an unreadable one and an unparseable one all answer False
    rather than raising. None of them is exceptional: the first is what every
    project looks like the first time it is opened, and the other two are what
    a session file looks like after a crash during a save on a version of this
    that did not rename into place. Restoring nothing is a fine outcome for
    all three.

    Files named in the session that no longer exist are dropped silently and
    counted; see `dropped_count`. Deleting a source file is a normal thing to
    do between one editing session and the next, and it should cost a line in
    the status bar rather than a dialog.

    Args:
        project_root: The directory the tree is showing.

    Returns:
        True if a session was found and read, False if there was none.

    Raises:
        If the path cannot be resolved.
    """
    g_files()[] = List[OpenFile]()
    g_expanded()[] = List[String]()
    g_current()[] = 0
    g_dropped()[] = 0

    var path = session_path(project_root)
    var text: String
    try:
        with open(path, "r") as f:
            text = f.read()
    except:
        return False

    var root = parse(text^)
    # `parse` answers null for anything it could not read, so a truncated file
    # arrives here looking exactly like an empty one. Checking the shape we
    # wanted is therefore the whole of the error handling, and it also rejects
    # a file that is valid JSON but is not a session -- somebody's unrelated
    # config that happened to land on the name.
    if root.kind != OBJECT:
        return False
    # The version is what makes "this is a session file" checkable rather than
    # merely likely. A truncated write loses whatever came after the point it
    # stopped, and `parse` hands back the fragment it did manage to read, so
    # without this a file cut off after two characters arrives looking like a
    # session that happens to list no files -- and would be reported as one. A
    # version this build does not understand is declined for the opposite
    # reason: guessing at a newer format is how a future Griddle's session
    # gets quietly replaced by an older one's misreading of it.
    var version = root.get(String("version"))[].as_int()
    if version < 1 or version > SESSION_VERSION:
        return False
    var files_node = root.get(String("files"))
    if files_node[].kind != ARRAY:
        return False

    var wanted = root.get(String("current"))[].as_int()
    var restored = List[OpenFile]()
    var dropped = 0
    var current = 0

    var total = files_node[].count()
    for i in range(total):
        if len(restored) >= MAX_FILES:
            break
        var entry = files_node[].at(i)
        var file_path = entry[].get(String("path"))[].as_string()
        if file_path.byte_length() == 0:
            continue
        if not _exists(file_path):
            dropped += 1
            continue

        var marks = List[Int]()
        var marks_node = entry[].get(String("breakpoints"))
        for k in range(marks_node[].count()):
            var line = marks_node[].at(k)[].as_int()
            # A negative line cannot be drawn and cannot be sent to the
            # debugger; it can only come from a corrupted file, and letting it
            # through would make the breakpoint gutter the place that crashes.
            if line >= 0:
                marks.append(line)

        # The index of the front tab is stored, but dropping a file shifts
        # every index after it. Remapping while scanning is the only place
        # that knows both numbers, so it is done here: if the file that was in
        # front survived, it is still in front.
        if i == wanted:
            current = len(restored)

        restored.append(
            OpenFile(
                file_path,
                _at_least_zero(entry[].get(String("caret_line"))[].as_int()),
                _at_least_zero(entry[].get(String("caret_col"))[].as_int()),
                _at_least_zero(entry[].get(String("top_line"))[].as_int()),
                marks^,
            )
        )

    # If the file that was in front is one of the ones that went, `current`
    # was never assigned and the first surviving tab is as good an answer as
    # any. The clamp also covers a `current` from a file that named more tabs
    # than it listed.
    if current >= len(restored):
        current = 0

    var folders = List[String]()
    var folders_node = root.get(String("expanded"))
    for i in range(folders_node[].count()):
        if len(folders) >= MAX_EXPANDED:
            break
        var folder = folders_node[].at(i)[].as_string()
        # Directories are not checked against the disk and not counted as
        # drops. Re-expanding the tree already ignores a path it cannot find
        # -- it looks for the row and there is no row -- so a stale directory
        # costs nothing, and counting it would make "3 files are gone" mean
        # something other than three files being gone.
        if folder.byte_length() > 0:
            folders.append(folder)

    g_files()[] = restored^
    g_expanded()[] = folders^
    g_current()[] = current
    g_dropped()[] = dropped
    return True


def _at_least_zero(v: Int) -> Int:
    """A stored coordinate, floored at the start of the document.

    A negative line or column has no meaning to any part of the editor and
    every part of it would react differently to one. Clamping here means the
    rest of the program never has to ask whether a restored caret is sane.
    """
    return v if v > 0 else 0


# ===----------------------------------------------------------------------===#
# What was loaded
# ===----------------------------------------------------------------------===#


def session_file_count() -> Int:
    """How many files the loaded session describes.

    Returns:
        The count, zero when nothing has been loaded.
    """
    return len(g_files()[])


def session_file(i: Int) raises -> OpenFile:
    """One file from the loaded session.

    Args:
        i: Its index, in tab order.

    Returns:
        Its path, caret, scroll position and breakpoints.

    Raises:
        If the index is out of range.
    """
    var files = g_files()
    if i < 0 or i >= len(files[]):
        raise Error("no such session file")
    return files[][i]


def session_current() -> Int:
    """Which file was in front, as an index into the loaded session.

    Returns:
        The index, already remapped past any files that were dropped, and
        zero when the session is empty.
    """
    return g_current()[]


def expanded_count() -> Int:
    """How many directories the loaded session had open.

    Returns:
        The count.
    """
    return len(g_expanded()[])


def expanded_path(i: Int) -> String:
    """One directory the tree had open.

    Non-raising, unlike `session_file`, because the caller is a loop that
    re-expands the tree and an out-of-range index there is not worth
    unwinding: an empty path is a path that matches no row, which is already
    how a directory that has since been deleted behaves.

    Args:
        i: Its index.

    Returns:
        The path, or an empty string if there is no such entry.
    """
    var folders = g_expanded()
    if i < 0 or i >= len(folders[]):
        return String("")
    return folders[][i]


def dropped_count() -> Int:
    """How many files the last load left out because they were gone.

    This is what a caller reports. The load itself says nothing -- it is on
    the path that opens a project, where a message per missing file would be
    a wall of dialogs standing between somebody and their work -- so the
    number is left here and the status line picks it up.

    Returns:
        The count from the most recent `load_session`.
    """
    return g_dropped()[]


# ===----------------------------------------------------------------------===#
# Throwing it away
# ===----------------------------------------------------------------------===#


def forget_session(project_root: String) raises -> String:
    """Delete a project's session file and clear what was loaded from it.

    Args:
        project_root: The directory the tree is showing.

    Returns:
        A sentence saying what happened.

    Raises:
        If the path cannot be resolved.
    """
    g_files()[] = List[OpenFile]()
    g_expanded()[] = List[String]()
    g_current()[] = 0
    g_dropped()[] = 0

    var path = session_path(project_root)
    if not _exists(path):
        return String("no session at ") + path
    if not _delete(path):
        return String("could not delete ") + path
    return String("forgot ") + path


# ===----------------------------------------------------------------------===#
# The disk, at the smallest possible surface
# ===----------------------------------------------------------------------===#


def _exists(path: String) raises -> Bool:
    """Whether a path names something on disk.

    `GetFileAttributesW` reads the directory entry: it opens nothing, takes no
    share lock, and answers just as fast for a 40 MB file as for an empty one.
    Opening the file to find out whether it is there would additionally fail
    for a file that is there but locked by a build, which would turn "your
    compiler is running" into "your file is gone".
    """
    var GetFileAttributesW = win32[
        def (Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> UInt32,
        "GetFileAttributesW",
    ]()
    var wide_path = _utf16z(path)
    var attributes = GetFileAttributesW(
        wide_path.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    )
    _ = wide_path
    return Int(attributes) != INVALID_FILE_ATTRIBUTES


def _delete(path: String) raises -> Bool:
    """Remove a file, answering whether it went."""
    var DeleteFileW = win32[
        def (Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> c_int,
        "DeleteFileW",
    ]()
    var wide_path = _utf16z(path)
    var ok = DeleteFileW(
        wide_path.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    )
    _ = wide_path
    return ok != 0


def _utf16z(s: String) -> List[UInt16]:
    """A NUL-terminated UTF-16 copy of a path, for a `PCWSTR` parameter.

    Surrogates are paired properly rather than each code point being truncated
    to sixteen bits, because a project under somebody's own name is exactly
    where non-ASCII reaches this module, and the truncating version fails by
    reporting that a directory which is plainly there does not exist.
    """
    var units = List[UInt16]()
    for ch in s.codepoints():
        var value = Int(ch)
        if value >= 0x10000:
            var offset = value - 0x10000
            units.append(UInt16(0xD800 + (offset >> 10)))
            units.append(UInt16(0xDC00 + (offset & 0x3FF)))
        else:
            units.append(UInt16(value))
    units.append(0)
    return units^
