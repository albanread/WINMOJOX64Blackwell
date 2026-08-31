"""Preferences: the handful of answers Griddle should stop asking for.

Sprint 7.1 wants one verb, `setting <key> [value]`: a key alone reads, a key
and a value writes. Everything else in this module follows from wanting the
write to still be true tomorrow morning.

These are NOT the same thing as a session, and the difference is worth being
precise about because the tree now has both. `ide/session.mojo` remembers
*where you were*: which files were open in this project, where the caret sat
in each, which directories the tree had expanded. That is per-project and it
belongs beside the project, in `.griddle-session.json`, so that it moves when
the project moves and dies when the project is deleted -- session.mojo says
so at length, and it is right. This module remembers *how you like it*: the
font, the tab width, whether the outline opens on the left. That is a
property of the person, not of the directory they happen to have open, and
storing it per-project would mean setting the font again in every project and
would leave a preferences file in source control for everyone else to
inherit. So: two files, two lifetimes, two scopes, and no shared code beyond
the write-then-rename dance both of them need.

Where it lives is `%LOCALAPPDATA%\\Griddle\\settings.json`, the directory
`ide/python_env.mojo` already claimed for its environments root -- one
per-user directory for Griddle's own state rather than a second one invented
here, resolved the same way (the environment variable, not
`SHGetKnownFolderPath`, whose known-folder ids are GUID structures the
metadata cannot hand back as a constant) and created the same way (a loop up
the parents calling `CreateDirectoryW`).

`GRIDDLE_SETTINGS` overrides the path outright, and that is a requirement
rather than a convenience: without it the check suite would have to write
into the developer's own profile to test anything, which makes running the
checks a thing that changes your editor's font.

Values are strings, always. A tab width of 4 is stored as `"4"` and the
caller converts. The alternative is a value union that every reader has to
switch on, and a class of bug where a setting written as a number is read
back as a string by the one caller that used the other accessor. One type
means `setting()` has one signature and a missing key and an empty value are
the same answer -- `""` -- which is what a caller wants anyway, since a
preference that is set to nothing is a preference that is not set.

Nothing here raises because of what is in the file. A missing file is what
every profile looks like the first time; an empty one is what a power cut
during a save used to leave; a malformed one is what a person leaves after
editing it by hand at the end of a long day. All three read as "no settings
yet", and the next write repairs the file. A preferences file must never be
the reason an editor will not start -- it is the one file in this tree whose
failure has no useful thing to tell the user, because the answer to "your
settings are corrupt" is always "then use the defaults".
"""

from std.ffi import c_int
from std.sys._globals import named_global
from std.time import sleep
from std.memory import Pointer
from std.sys._winkb import winkb_constant

from ide.json import parsed_whole_document, BOOL, JSON, NUMBER, OBJECT, STRING, parse
from ide.win32 import absolute, env_or, win32


# The per-user directory Griddle already owns. `ide/python_env.mojo` puts
# `Python\\Environments` under this same name; the settings file is its
# sibling, so a person looking for "what has Griddle put on my disk" finds one
# directory rather than two.
comptime APP_DIR = "Griddle"
comptime SETTINGS_NAME = "settings.json"

# The environment variable that moves the whole file. Read before anything
# else, so a check never has to know what the real location would have been.
comptime SETTINGS_ENV = "GRIDDLE_SETTINGS"

comptime SEP = "\\"

# From the metadata rather than transcribed, for the reason session.mojo
# gives: MOVEFILE_REPLACE_EXISTING is 1 and MOVEFILE_COPY_ALLOWED is 2, and
# swapping them by hand gives a rename that silently does not replace, so
# every save after the first one fails.
comptime MOVEFILE_REPLACE_EXISTING = UInt32(
    winkb_constant["MOVEFILE_REPLACE_EXISTING"]()
)

# Also from the metadata, and also needing a word. The database gives the
# signed reading, -1, while `GetFileAttributesW` returns an unsigned 32-bit
# value, so comparing the two directly is a test that can never be true and
# every path looks as though it exists. Mask to the width the API answers in.
comptime INVALID_FILE_ATTRIBUTES = (
    winkb_constant["INVALID_FILE_ATTRIBUTES"]() & 0xFFFFFFFF
)


# ===----------------------------------------------------------------------===#
# Where they live
# ===----------------------------------------------------------------------===#


def settings_path() raises -> String:
    """The settings file, wherever it is for this run.

    `GRIDDLE_SETTINGS` names the file itself, not a directory holding it.
    That is the spelling a check wants: two checks running out of the same
    scratch directory need two different files, and only a full path can give
    them that. Its parent is created on the first write, like any other.

    Returns:
        An absolute path, or empty when there is no profile directory to put
        it in -- which is a machine with neither `%LOCALAPPDATA%` nor
        `%USERPROFILE%` set, and on such a machine settings simply do not
        persist.

    Raises:
        If the path cannot be made absolute.
    """
    var override = env_or(SETTINGS_ENV, "")
    if override != "":
        return absolute(override)

    var local = env_or("LOCALAPPDATA", "")
    if local == "":
        # The same fallback python_env.mojo uses. A service account or a
        # stripped-down environment can be missing LOCALAPPDATA and still have
        # a profile, and the directory below it is the documented location of
        # the one the variable would have named.
        var profile = env_or("USERPROFILE", "")
        if profile == "":
            return String()
        var built = _join(_join(profile, String("AppData")), String("Local"))
        local = built^
    return _join(_join(local, String(APP_DIR)), String(SETTINGS_NAME))


# ===----------------------------------------------------------------------===#
# Reading
# ===----------------------------------------------------------------------===#


def setting(key: String) raises -> String:
    """One preference.

    There is no cache in front of this: the file is read on every call. It is
    a few hundred bytes and this is on the path of a typed command, not of a
    keystroke, and a cache would make the first thing anybody tries -- set it
    in one window, read it in the other -- give the wrong answer. The same
    reasoning keeps two Griddles honest about each other.

    Args:
        key: The preference's name.

    Returns:
        Its value, or empty when it is unset, when the file cannot be read,
        or when what is in the file is not text.

    Raises:
        If the path cannot be resolved.
    """
    var root = _load()
    var node = root.get(key)
    return _as_text(node[])


def settings_report() raises -> String:
    """Every preference, one to a line.

    Sorted by key. The file itself keeps the order things were written in --
    see `_store` -- but a report is read by a person looking for a name, and
    by a check comparing output, and both want the same list every time
    regardless of the order the settings happened to be set in.

    Returns:
        `"settings N"`, then `"  key = value"` for each one.

    Raises:
        If the path cannot be resolved.
    """
    var root = _load()
    var total = len(root.keys)

    # Insertion sort over indices rather than over the entries: the values
    # hang off ArcPointer and the keys are Strings, and sorting indices moves
    # neither. There are a dozen settings on a busy day.
    var order = List[Int]()
    for i in range(total):
        var at = len(order)
        while at > 0 and root.keys[i] < root.keys[order[at - 1]]:
            at -= 1
        order.insert(at, i)

    var out = String("settings ") + String(total)
    for i in order:
        out += "\n  " + root.keys[i] + " = " + _as_text(root.items[i][])
    return out^


# ===----------------------------------------------------------------------===#
# Writing
# ===----------------------------------------------------------------------===#


def set_setting(key: String, value: String) raises -> Bool:
    """Record one preference, replacing any previous value.

    Read, change one key, write the whole file back. Everything else in the
    file survives -- including keys this build has never heard of, which is
    what makes a settings file written by a newer Griddle safe to open with an
    older one.

    Args:
        key: The preference's name. Empty is refused: a nameless key can be
            written but never meaningfully asked for, and it would show up in
            every report as a blank line for the rest of the file's life.
        value: What to store, as text.

    Returns:
        True when the file now says so, False when it could not be written.

    Raises:
        If the path cannot be resolved.
    """
    if key.byte_length() == 0:
        return False
    var root = _load()
    if settings_unreadable():
        # There are settings on disk that could not be read. Writing one key
        # now would replace all of them with it.
        return False
    root.set(String(key), JSON(String(value)))
    return _store(root^)


def forget_setting(key: String) raises -> Bool:
    """Remove one preference, so the default applies again.

    Args:
        key: The preference's name.

    Returns:
        True when it was there and the file has been rewritten without it,
        False when there was no such setting or the file could not be written.

    Raises:
        If the path cannot be resolved.
    """
    var root = _load()
    if settings_unreadable():
        return False
    if not root.has(key):
        # Distinguished from a failed write on purpose: "there was nothing to
        # forget" and "I could not forget it" are different answers, and only
        # the second one is worth telling somebody about.
        return False

    # Rebuilt rather than deleted in place, because `JSON` has no remove and
    # this is not the module that should grow one. Copying the entries across
    # is cheap for the same reason the parser can afford it: a value is an
    # `ArcPointer` to its node, so keeping a value means copying a pointer and
    # bumping a count, not copying whatever tree hangs beneath it. `JSON`
    # itself is Movable and not Copyable, so this is in fact the only way to
    # carry a value from one object to another.
    var fresh = JSON.object()
    for i in range(len(root.keys)):
        if root.keys[i] == key:
            continue
        fresh.keys.append(root.keys[i])
        fresh.items.append(root.items[i])
    return _store(fresh^)


# ===----------------------------------------------------------------------===#
# The file itself
# ===----------------------------------------------------------------------===#


# Whether the last `_load` failed to read a file that is really there. The
# distinction is the whole of this module's durability: a file that is absent
# and a file that is present but unreadable both yield an empty document, and
# only one of them may be written over.
comptime g_unread = named_global["settings.unread", Int]


def settings_unreadable() -> Bool:
    """Whether the last read failed on a file that exists.

    Returns:
        True when there are settings on disk that could not be read.
    """
    return g_unread()[] != 0


def _load() raises -> JSON:
    """The settings file as an object, and an empty object for anything else.

    Most ways this can fail -- no file, a truncated write, somebody's
    unrelated JSON that landed on the name, a hand edit that lost a brace --
    arrive here as the same answer, and it is the right one: the editor starts
    with its defaults and the next `set_setting` writes a whole valid file
    over the wreckage.

    One way is different, and it used to arrive here as the same answer too.
    A file that exists and cannot be opened *this instant* is not an empty
    file, and the callers that write are read-modify-write: handed an empty
    document they add one key and rename it over a complete one. Every other
    preference is gone and the call returns True. It needs no unusual
    permissions to happen, because `_store`'s own rename makes the
    destination briefly unopenable -- so two Griddles saving at the same
    moment is the trigger, and this module already knows two can be running,
    which is why the pid is in the temporary name.

    So the open is retried, and if it still fails on a file that is there,
    `settings_unreadable` says so and the writers refuse.
    """
    g_unread()[] = 0
    var path = settings_path()
    if path == "":
        return JSON.object()

    var text = String("")
    var read = False
    # Six attempts over about a hundred milliseconds. The window this closes
    # is one rename wide -- microseconds -- so a retry that reaches the second
    # attempt has almost certainly hit something else, and one that reaches
    # the sixth has hit a real problem worth reporting rather than papering
    # over.
    var tries = 0
    while tries < 6:
        try:
            # A plain `with` is correct for a read. The handle outliving the
            # block only matters where the file is about to be renamed over,
            # which is `_store`'s problem and is solved there by closing
            # explicitly.
            with open(path, "r") as f:
                text = f.read()
            read = True
            break
        except:
            tries += 1
            if tries < 6:
                sleep(0.02)
    if not read:
        # Absent is fine and means what it says. Present-but-unreadable is
        # not, and saying so is the difference between starting with defaults
        # and destroying somebody's preferences.
        g_unread()[] = 1 if _exists(path) else 0
        return JSON.object()

    # A UTF-8 byte order mark, if somebody has had this file open in Notepad,
    # which is the likeliest editor for it and which still writes one. It is
    # not whitespace and the parser does not skip it, so without this the mark
    # alone makes a perfectly good settings file unreadable -- and the person
    # who edited it would have no way of seeing why, since the mark is
    # invisible in the editor that added it.
    var body = text
    var mark = chr(0xFEFF)
    if body.startswith(mark):
        var without_mark = String(body[byte = mark.byte_length() :])
        body = without_mark^
    var trimmed = String(body.strip())

    # Braces at both ends before parsing at all. `ide/json.mojo` is forgiving
    # by design -- it hands back whatever it managed to read -- so a file cut
    # off mid-write parses into the pairs that were complete plus, quite
    # possibly, one key whose value is the first few letters of the value.
    # That is worse than reading nothing: a font of "Casca" looks like a
    # setting somebody chose, and it would be written back as one by the next
    # save.
    #
    # This used to test that the text ended in `}`, on the reasoning that a
    # complete object always does. So does an incomplete one that happens to
    # be cut after a nested brace, and an adversarial read found two such cuts
    # in a plausible settings file -- one of which presented a truncated build
    # command as a real setting. The parser now says whether it reached the
    # end without failing, which is the actual question, so this asks it
    # instead of guessing from the last character.
    if trimmed.byte_length() < 2:
        return JSON.object()

    # `parse` answers null for anything else it could not read, so a file full
    # of binary rubbish arrives looking like nothing at all. Checking the shape
    # we wanted is the rest of the error handling: a top-level array, string or
    # number is not a settings file either, and this rejects those too.
    var root = parse(trimmed^)
    if not parsed_whole_document():
        return JSON.object()
    if root.kind != OBJECT:
        return JSON.object()
    return root^


def _store(var root: JSON) raises -> Bool:
    """Write the object out, atomically, answering whether it landed.

    Through `ide/json.mojo` rather than by assembling the text here: a value
    can be a Windows path, or contain a quote, or a newline somebody pasted,
    and every one of those has to be escaped exactly right or the file this
    module wrote is a file this module cannot read.
    """
    var path = settings_path()
    if path == "":
        return False
    if not _ensure_dir(_dirname(path)):
        return False

    # Insertion order, which for a file that was read and rewritten is the
    # order it already had, with anything new at the end. Sorting here would
    # reorder a file somebody has arranged by hand, and the report sorts
    # anyway -- so the person who edits the file keeps their arrangement and
    # the person who reads the report gets a stable list.
    var text = root.serialize()

    # Write beside it, then rename over it. Straight over the top means a
    # crash or a full disk halfway through leaves a truncated preferences
    # file, which is strictly worse than a stale one: stale still has your
    # font in it. The process id is in the temporary name because two
    # Griddles can be running, and two saves landing on one temporary file
    # would interleave into a file that is neither of them.
    var GetCurrentProcessId = win32[
        def () thin abi("C") -> UInt32, "GetCurrentProcessId"
    ]()
    var temporary = path + "." + String(Int(GetCurrentProcessId())) + ".tmp"

    # Closed by name, not by leaving a `with` block. Within one function the
    # handle is destroyed when the function returns, not when the indentation
    # ends, so a `with` here would still hold the file open at the rename and
    # `MoveFileExW` would fail with ERROR_SHARING_VIOLATION every single time.
    # session.mojo stood on this first; docs/mojo-traps.md has the probe.
    try:
        var f = open(temporary, "w")
        f.write(text)
        f.close()
    except:
        # A read-only directory, a full disk, a path the override points
        # somewhere impossible. Nothing has been touched: the previous
        # settings file is exactly as it was.
        return False

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
        # written, so it is the only one that can leave litter behind.
        _ = _delete(temporary)
        return False
    return True


def _as_text(v: JSON) raises -> String:
    """A stored value as the string this module promises to return.

    A number or a boolean is converted rather than refused. The file is meant
    to be editable by hand and a person writing a tab width will write `4`,
    not `"4"`; treating their file as unreadable over a pair of quotes is the
    same failure as treating it as corrupt. An object or an array has no
    honest rendering as one value, so it reads as unset -- and it survives the
    next write untouched, because `set_setting` rewrites the parsed document
    rather than what this function made of it.
    """
    if v.kind == STRING:
        return v.text
    if v.kind == NUMBER:
        # The same rule ide/json.mojo writes numbers by: a whole number does
        # not grow a decimal point, so a tab width of 4 reads back as "4".
        var whole = Int(v.num)
        if Float64(whole) == v.num:
            return String(whole)
        return String(v.num)
    if v.kind == BOOL:
        return String("true") if v.b else String("false")
    return String()


# ===----------------------------------------------------------------------===#
# The disk, at the smallest possible surface
#
# These mirror ide/session.mojo and ide/python_env.mojo deliberately rather
# than importing them. python_env.mojo pulls in the process-spawning
# machinery, and settings have to be readable before any of that exists;
# session.mojo's copies are private to it and about a different file. Four
# short wrappers are a smaller thing to own than a dependency in either
# direction.
# ===----------------------------------------------------------------------===#


def _join(directory: String, name: String) -> String:
    """Two path pieces with exactly one separator between them."""
    if directory == "":
        return name
    if directory.endswith(SEP) or directory.endswith("/"):
        return directory + name
    return directory + SEP + name


def _dirname(path: String) -> String:
    """Everything before the last separator.

    Both separators are accepted, because `GRIDDLE_SETTINGS` may well be set
    from a shell that spells paths with forward slashes.
    """
    var cut = path.rfind(SEP)
    var slash = path.rfind("/")
    if slash > cut:
        cut = slash
    if cut <= 0:
        return String()
    return String(path[byte=0:cut])


def _exists(path: String) raises -> Bool:
    """Whether a path names something on disk.

    `GetFileAttributesW` reads the directory entry: it opens nothing and takes
    no share lock, so asking does not itself become a reason the file cannot
    be written.
    """
    if path == "":
        return False
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


def _ensure_dir(path: String) raises -> Bool:
    """Make a directory and everything above it, answering whether it is there.

    A loop over the parents rather than `SHCreateDirectoryExW`, which lives in
    shell32 and would be a whole library loaded to save four lines. The
    recursion terminates because `_dirname` is strictly shorter every time and
    answers empty for a bare drive.
    """
    if path == "":
        return False
    if _exists(path):
        return True
    var parent = _dirname(path)
    if parent != "" and parent != path and not _exists(parent):
        if not _ensure_dir(parent):
            return False
    var CreateDirectoryW = win32[
        def (Pointer[UInt16, MutAnyOrigin], Int) thin abi("C") -> c_int,
        "CreateDirectoryW",
    ]()
    var wide_path = _utf16z(path)
    _ = CreateDirectoryW(
        wide_path.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](), 0
    )
    _ = wide_path
    # The return value is not the answer: it is false both for a race another
    # process won and for a real failure, and only the directory entry can
    # tell those apart.
    return _exists(path)


def _delete(path: String) raises -> Bool:
    """Remove a file, answering whether it went."""
    var DeleteFileW = win32[
        def (Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> c_int,
        "DeleteFileW",
    ]()
    var wide_path = _utf16z(path)
    var ok = DeleteFileW(wide_path.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]())
    _ = wide_path
    return ok != 0


def _utf16z(s: String) -> List[UInt16]:
    """A NUL-terminated UTF-16 copy of a path, for a `PCWSTR` parameter.

    Surrogates are paired properly rather than each code point being truncated
    to sixteen bits: `%LOCALAPPDATA%` contains the user's own name, which is
    exactly where non-ASCII reaches this module, and the truncating version
    fails by reporting that a directory which is plainly there does not exist.
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
