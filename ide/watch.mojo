"""Noticing that the disk moved while Griddle was not looking.

Griddle has had a fixed idea of the project. The tree is whatever
`FindFirstFileW` said at the moment a folder was expanded, and an open
document is whatever `ReadFile` returned at the moment it was opened. Both go
stale the instant anything else touches the disk: a `git checkout`, a build
that writes generated sources, a second editor, a formatter run from a shell.
Until now the editor would let a person go on typing into a document that
something else had already rewritten, and then save over it. This module is
the noticing. What to do about a change -- re-read the tree, ask about the
document, reload it silently -- is the window's business and is deliberately
not decided here, so nothing in this file draws anything or knows what a
window is.

The mechanism is `FindFirstChangeNotificationW`, which returns a waitable
handle that Windows signals when something under a directory changes. It is
the coarse API: it says *something* happened, not what, and coarse is exactly
what a tree that is going to be re-read wholesale wants. The precise one,
`ReadDirectoryChangesW`, needs either a read that blocks or overlapped I/O
with a completion routine, and Griddle is one thread that must be sitting in
`GetMessageW` whenever it is not drawing. Buying a list of changed filenames
with a second thread would mean making every tree and document mutation
thread-safe, to pay for detail that the refresh throws away.

So the handle is tested with a zero timeout from the message-loop timer, the
same shape `ide/build.mojo` uses to drain a child process's pipe.
`WaitForSingleObject(handle, 0)` is a signal test rather than a wait: it
answers `WAIT_OBJECT_0` or `WAIT_TIMEOUT` immediately and a timer tick that
performs one costs nothing measurable.

One watch at a time, because Griddle shows one project at a time. Starting a
second replaces the first rather than accumulating handles nobody remembers
holding.
"""

from std.ffi import c_int
from std.memory import Pointer
from std.sys._com import com_addr
from std.sys._globals import named_global
from std.sys._winkb import (
    winkb_constant,
    winkb_field_offset,
    winkb_struct_size,
)
from std.sys.info import size_of

from ide.win32 import win32


# What counts as a change worth waking up for. Names appearing and vanishing
# is a tree that has to be re-read; a last write is an open document that has
# to be re-checked. Attribute and security changes are excluded because a
# `chmod` does not alter a single byte a person is looking at.
#
# These read as #defines in the headers, but they are `FILE_NOTIFY_CHANGE`
# enumeration members and the metadata has rows for all three -- so they come
# from the database like every other number in this program, and there is no
# hand-copied hex here to be wrong about.
comptime WATCH_FILTER = UInt32(
    winkb_constant["FILE_NOTIFY_CHANGE_FILE_NAME"]()
    | winkb_constant["FILE_NOTIFY_CHANGE_DIR_NAME"]()
    | winkb_constant["FILE_NOTIFY_CHANGE_LAST_WRITE"]()
)

# `FindFirstChangeNotificationW` reports failure by returning this, and it is
# emphatically not a handle. Storing it and polling it is how a watch comes to
# report a change on every single timer tick forever: `WaitForSingleObject` on
# a garbage handle answers `WAIT_FAILED`, which is not `WAIT_TIMEOUT`, and a
# poll written as "anything but a timeout means something changed" then
# refreshes the tree sixty times a second for the rest of the session.
comptime INVALID_HANDLE = winkb_constant["INVALID_HANDLE_VALUE"]()

comptime WAIT_OBJECT_0 = UInt32(winkb_constant["WAIT_OBJECT_0"]())

# The subtree flag, spelled out because `BOOL` is an `int` and `1` on its own
# at a call site says nothing about which of three arguments it is.
comptime WATCH_SUBTREE = c_int(1)

# How many signals one call will absorb. A build writes thousands of files and
# signals this handle thousands of times; taking one per timer tick would put
# the tree minutes behind the disk and make a refresh look like a hang. An
# unbounded loop is the opposite failure -- a program writing in a tight loop
# can signal faster than this drains and would hold the message pump until it
# stopped. Sixty-four folds any realistic burst into one refresh and still
# hands the pump back on the same tick.
comptime MAX_DRAIN = 64

# `GET_FILEEX_INFO_LEVELS.GetFileExInfoStandard`. There is exactly one level
# and it has been the only one since Windows 98, but it is an enumeration
# member with a row in the metadata, so it is looked up rather than written
# as the 0 it happens to be.
comptime FILE_INFO_STANDARD = c_int(
    winkb_constant["GetFileExInfoStandard"]()
)


@fieldwise_init
struct FileAttributeData(Defaultable, Copyable, Movable):
    """`WIN32_FILE_ATTRIBUTE_DATA`, with its `FILETIME`s written as halves.

    Windows declares three `FILETIME` members and a `FILETIME` is a pair of
    `UInt32` fields. Writing them flat is the same thirty-six bytes and saves
    a nested struct whose only purpose would be to be taken apart again one
    line later; `MSG` in `ide/win32.mojo` flattens its `POINT` for the same
    reason. What makes the flattening checkable rather than merely plausible
    is the pair of compile-time assertions in `file_stamp`: the whole struct
    must be the size Windows says, and `ftLastWriteTime` must begin exactly
    where this declaration puts its low half. If a future Windows moves a
    field, the build stops instead of silently reporting somebody's file
    creation time as its modification time.
    """

    var dwFileAttributes: UInt32
    var ftCreationTimeLow: UInt32
    var ftCreationTimeHigh: UInt32
    var ftLastAccessTimeLow: UInt32
    var ftLastAccessTimeHigh: UInt32
    var ftLastWriteTimeLow: UInt32
    var ftLastWriteTimeHigh: UInt32
    var nFileSizeHigh: UInt32
    var nFileSizeLow: UInt32

    def __init__(out self):
        """All zero, ready for Windows to fill in."""
        self.dwFileAttributes = 0
        self.ftCreationTimeLow = 0
        self.ftCreationTimeHigh = 0
        self.ftLastAccessTimeLow = 0
        self.ftLastAccessTimeHigh = 0
        self.ftLastWriteTimeLow = 0
        self.ftLastWriteTimeHigh = 0
        self.nFileSizeHigh = 0
        self.nFileSizeLow = 0


# The watch, as process state. Globals for the reason the build's child
# process is a global: the poll is reached from a captureless window
# procedure by way of a timer, and there is nowhere on that path to hand it
# a receiver.
comptime g_handle = named_global["watch.handle", Int]
comptime g_path = named_global["watch.path", String]
comptime g_changes = named_global["watch.changes", Int]


def watching() -> Bool:
    """Whether a directory is currently being watched.

    Returns:
        True when there is a live notification handle.
    """
    var handle = g_handle()[]
    # Zero is "never started" and -1 is "Windows refused". Neither is a handle
    # and both must answer the same way, or a caller that trusts this will go
    # on to poll something that is not a watch.
    return handle != 0 and handle != INVALID_HANDLE


def watched_path() -> String:
    """The directory the watch covers.

    Returns:
        The path handed to `watch_directory`, or empty when nothing is being
        watched.
    """
    return g_path()[]


def change_count() -> Int:
    """How many changes have been noticed since this watch started.

    A drained burst counts once per signal absorbed rather than once per call,
    so this is a rough measure of how busy the disk has been -- enough for a
    status line to say "12 changes" and for a person to tell a quiet project
    from one with a build running in it.

    Returns:
        The count, reset to zero every time a new watch starts.
    """
    return g_changes()[]


def watch_directory(path: String) raises -> String:
    """Start watching a directory tree for changes.

    Any previous watch is stopped first, so calling this on every project
    switch is correct and does not leak a handle.

    Args:
        path: The directory to watch. Its whole subtree is covered.

    Returns:
        A sentence saying what happened, for the status line.

    Raises:
        If the entry points cannot be resolved.
    """
    # Unconditionally, before anything can fail: a caller opening a second
    # project must not end up watching the first one because the second could
    # not be watched.
    stop_watching()

    var FindFirstChangeNotificationW = win32[
        def (
            Pointer[UInt16, MutAnyOrigin], c_int, UInt32
        ) thin abi("C") -> Int,
        "FindFirstChangeNotificationW",
    ]()

    var wide_path = _utf16z(path)
    var handle = FindFirstChangeNotificationW(
        wide_path.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        WATCH_SUBTREE,
        WATCH_FILTER,
    )
    # Keep the buffer alive across the call: Windows reads the path during it,
    # and nothing afterwards refers to it, which is exactly the shape an
    # optimizer is entitled to free early.
    _ = wide_path

    if handle == INVALID_HANDLE or handle == 0:
        # A directory that has been deleted or renamed since the tree last
        # read it is the ordinary case here, not an exceptional one, so this
        # reports rather than raises and leaves the module not watching.
        return String("cannot watch ") + path

    g_handle()[] = handle
    g_path()[] = path
    g_changes()[] = 0
    return String("watching ") + path


def stop_watching() raises:
    """Stop watching, and give the directory back.

    Closing matters more than it looks. A change notification is a handle on
    the directory itself, and a directory with an open handle on it is one
    Windows will not let anybody delete or rename. Leak it and a person finds,
    an hour later and with no idea why, that a folder they are done with
    cannot be removed -- by then they have long forgotten that Griddle is
    open, and the file manager will not tell them.

    Safe to call when nothing is being watched, because a window closing has
    no way of knowing whether a project was ever opened and should not have to
    find out.

    Raises:
        If the entry point cannot be resolved.
    """
    if not watching():
        # Still clear the slots: a handle of -1 left behind from a failed
        # start would make `watching` right but leave the path claiming a
        # directory nothing is watching.
        g_handle()[] = 0
        g_path()[] = String("")
        return

    var FindCloseChangeNotification = win32[
        def (Int) thin abi("C") -> c_int, "FindCloseChangeNotification"
    ]()
    _ = FindCloseChangeNotification(g_handle()[])
    g_handle()[] = 0
    g_path()[] = String("")


def poll_changes() raises -> Bool:
    """Whether anything under the watched directory changed since last asked.

    Never blocks, because this is called from the window's timer and the timer
    runs on the thread that draws. The zero timeout turns
    `WaitForSingleObject` into a question rather than a wait.

    Returns:
        True if at least one change was seen, in which case the caller should
        re-read whatever it is showing.

    Raises:
        If the entry points cannot be resolved.
    """
    if not watching():
        # Not watching is the normal state before a project is opened, and a
        # timer that fires regardless must be able to ask without guarding.
        return False

    var WaitForSingleObject = win32[
        def (Int, UInt32) thin abi("C") -> UInt32, "WaitForSingleObject"
    ]()
    var FindNextChangeNotification = win32[
        def (Int) thin abi("C") -> c_int, "FindNextChangeNotification"
    ]()

    var handle = g_handle()[]
    var changed = False
    var drained = 0
    while drained < MAX_DRAIN:
        # Exactly `WAIT_OBJECT_0` and nothing else. `WAIT_TIMEOUT` is the
        # quiet answer and `WAIT_FAILED` means the handle has gone bad;
        # treating "not a timeout" as a change turns a broken handle into a
        # permanent refresh storm.
        if WaitForSingleObject(handle, UInt32(0)) != WAIT_OBJECT_0:
            break
        changed = True
        drained += 1
        g_changes()[] += 1
        # A signalled notification stays signalled until it is re-armed, so
        # skipping this would make the next poll -- and every poll after it --
        # report the same change again.
        if FindNextChangeNotification(handle) == 0:
            # The watch cannot be re-armed, which in practice means the
            # directory is gone. Close it here rather than leaving a dead
            # handle to be polled forever; the caller sees one last True and
            # then a `watching()` of False, which is the truth.
            stop_watching()
            return True
    return changed


def file_stamp(path: String) raises -> Int:
    """One file's last-write time, as a single comparable integer.

    This is how the editor tells that the document under the cursor has been
    rewritten by something else. A stamp rather than the file's contents,
    because comparing contents means reading the whole file back on a timer,
    for every open document: a 40 MB log or a generated source costs 40 MB of
    I/O and a full rope comparison to answer a question that is almost always
    "no". Reading it back also has to open it, and a file another program is
    still writing may refuse to open at all -- so the cheap check would be the
    one that fails exactly when something is changing. `GetFileAttributesExW`
    reads the directory entry, opens nothing, takes no share lock, and costs
    the same thirty-six bytes whatever the file's size is.

    The two `FILETIME` halves are joined rather than compared separately
    because a caller wants one `!=`. A `FILETIME` counts hundred-nanosecond
    intervals since 1601, so the joined value is around 1.3e17 today and has
    another twenty-eight thousand years before it troubles a signed 64-bit
    integer.

    Args:
        path: The file. It is not opened.

    Returns:
        The last-write time as an integer, or 0 when the file cannot be read
        -- a deleted or renamed file included, which a caller comparing
        against a remembered non-zero stamp will correctly see as a change.

    Raises:
        If the entry point cannot be resolved.
    """
    comptime assert (
        size_of[FileAttributeData]()
        == winkb_struct_size["WIN32_FILE_ATTRIBUTE_DATA"]()
    ), "WIN32_FILE_ATTRIBUTE_DATA is not the size this declares"
    # The flattening is only sound while the write time starts where this
    # struct's low half sits. Windows says 20; if it ever says otherwise this
    # stops being a silent read of the wrong timestamp.
    comptime assert (
        winkb_field_offset["WIN32_FILE_ATTRIBUTE_DATA", "ftLastWriteTime"]()
        == 20
    ), "ftLastWriteTime is not where this reads it"

    var GetFileAttributesExW = win32[
        def (
            Pointer[UInt16, MutAnyOrigin],
            c_int,
            Pointer[FileAttributeData, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "GetFileAttributesExW",
    ]()

    var data = FileAttributeData()
    var wide_path = _utf16z(path)
    var ok = GetFileAttributesExW(
        wide_path.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        FILE_INFO_STANDARD,
        # `com_addr` rather than `Int(Pointer(to=data))`: erasing the origin
        # lets an optimized build merge `data`'s slot with another local and
        # fill in whatever now lives there. See `docs/addresses-and-
        # optimization.md`; the unoptimized build is correct either way, which
        # is what makes the bug so unpleasant to find.
        com_addr(data),
    )
    _ = wide_path
    if ok == 0:
        return 0
    return (Int(data.ftLastWriteTimeHigh) << 32) | Int(
        data.ftLastWriteTimeLow
    )


def _utf16z(s: String) -> List[UInt16]:
    """A NUL-terminated UTF-16 copy of a path, for a `PCWSTR` parameter.

    Paths are the one place non-ASCII reaches this module -- a project under a
    person's name, a folder with an accent in it -- so this pairs surrogates
    properly instead of truncating each code point to sixteen bits and
    watching Windows fail to find a directory that plainly exists.
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
