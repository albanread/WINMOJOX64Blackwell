"""Searching a whole project for a literal string.

`ide/find.mojo` searches the document that is open. This is the other half:
the thing a person actually does when they want to know where a name is used,
which is to search every file rather than the one in front of them.

It is deliberately only the search. There is no window code here and nothing
imported from `ide/window.mojo`, `ide/gridview.mojo` or `ide/griddle.mojo` --
those three import each other and the editor, and a module they import that
imports them back does not compile. What is here is a call that fills a list
and ten accessors that read it, which is all a results pane needs.

Three decisions shape everything below, and each of them is the difference
between a search that returns and one that does not:

**The walk skips what is not source.** A checkout of this repository has four
hundred thousand files under `bazel-bin` alone. A search that walks them is
correct and useless; nobody waits for it. The skip list is small, named, and
applied to directory names before the directory is opened.

**Files are chosen by extension, never by sniffing.** Guessing from content
means opening the file first, and opening it is the expensive part -- a
directory of PNGs costs the same to reject by content as to search. The
extension is in the name the directory walk already gave us, so rejecting by
it costs nothing at all.

**Columns are UTF-16 code units.** The editor's caret counts UTF-16, because
that is what Windows' text services and the language server both speak. A byte
column on a line with an emoji in it names a position the caret cannot occupy,
and "jump to result" then lands somewhere else. See `_utf16_units`.
"""

from std.ffi import c_int
from std.memory import Pointer, alloc
from std.sys._globals import named_global
from std.sys._winkb import winkb_struct_size

from ide.win32 import absolute, win32

# ===----------------------------------------------------------------------===#
# The directory walk
#
# Written here rather than borrowed from `ide/tree.mojo` for one reason: the
# file's size arrives in the same `WIN32_FIND_DATAW` record as its name, so the
# four-megabyte rule below is free. Going through `tree.list_dir` would give
# rows shaped for the sidebar and then need a `getsize` -- a second open of
# every file in the project -- to learn something Windows already told us.
# ===----------------------------------------------------------------------===#

# From the metadata, checked at compile time, exactly as `ide/tree.mojo` does:
# if Windows ever disagrees this stops being a silent misread of somebody's
# filenames and becomes a build failure.
comptime FIND_DATA_BYTES = 592
comptime NAME_OFFSET = 44
comptime MAX_NAME_UNITS = 260

# Sizes are two halves of a 64-bit number in the same record, at these offsets:
# `nFileSizeHigh` follows the three FILETIMEs and `nFileSizeLow` follows it.
comptime SIZE_HIGH_OFFSET = 28
comptime SIZE_LOW_OFFSET = 32

# FILE_ATTRIBUTE_DIRECTORY and the invalid handle sentinel are `#define`s in
# the Windows headers rather than enumerations, so there is no metadata row to
# look either of them up in and they are written out with their names.
comptime FILE_ATTRIBUTE_DIRECTORY = 0x10
comptime INVALID_HANDLE = -1

# Directory names never descended into. Every one of these is a place a build
# system or a package manager put machine-written files, and the point is not
# tidiness: `bazel-bin` in this tree holds four hundred thousand files, so a
# walk that enters it turns a two-second search into one nobody waits for.
# Names starting with "." are skipped as well, by rule rather than by listing,
# which covers `.git`, `.venv`, `.cache` and whatever the next tool invents.
# Delimited on both sides so that a lookup of "|obj|" cannot match "|object|".
comptime SKIP_DIRECTORIES = StaticString(
    "|bazel-bin|bazel-out|node_modules|__pycache__|.git|build|target|obj|"
)

# Extensions worth opening. Deciding by name is not a lesser form of deciding
# by content -- it is the only one that is cheap, because content costs an
# open and a read of the very files this exists to avoid reading. A file whose
# name lies about it is skipped, and that is a far better failure than every
# object file in the tree being read to discover it is not text.
comptime TEXT_EXTENSIONS = StaticString(
    "|.mojo|.py|.txt|.md|.json|.toml|.yaml|.yml|.cfg|.ini|.ps1|.sh|.c|.h"
    "|.cpp|.hpp|.rs|.ts|.js|.html|.css|.bazel|.bzl|"
)

# Four megabytes. A source file is not four megabytes; something that is was
# generated, and reading it is a stall in the middle of a search that a person
# did not ask for and cannot cancel.
comptime MAX_FILE_BYTES = 4 * 1024 * 1024

# Roughly how much of a matching line to keep. The text goes into a one-line
# row in a results list, and a minified stylesheet is one line of nine hundred
# thousand characters; keeping it whole would cost more memory than the search.
comptime MAX_LINE_CHARS = 200


@fieldwise_init
struct Hit(ImplicitlyCopyable, Movable):
    """One occurrence of the needle, everything a results row needs."""

    var path: String
    var line: Int
    var column: Int
    var text: String


@fieldwise_init
struct Found(ImplicitlyCopyable, Movable):
    """One entry of one directory, as the walk saw it."""

    var path: String
    var name: String
    var is_dir: Bool
    var size: Int


# Globals for the same reason the tree's and the build's state is global: the
# window procedure that will draw these results is captureless and has one
# pointer to work with, so a subsystem's state lives in a named slot.
comptime g_hits = named_global["search.hits", List[Hit]]
comptime g_needle = named_global["search.needle", String]
comptime g_files = named_global["search.files", Int]
comptime g_truncated = named_global["search.truncated", Int]


# ===----------------------------------------------------------------------===#
# What the results pane reads
# ===----------------------------------------------------------------------===#


def hit_count() -> Int:
    """How many occurrences the last search recorded.

    Returns:
        The count, which is at most the `max_hits` that search was given.
    """
    return len(g_hits()[])


def hit_path(i: Int) -> String:
    """The full path of the file one hit is in.

    Args:
        i: Which hit.

    Returns:
        The absolute path, or empty when the index is out of range.
    """
    var hits = g_hits()
    if i < 0 or i >= len(hits[]):
        return String("")
    return hits[][i].path


def hit_line(i: Int) -> Int:
    """Which line one hit is on, counted from zero.

    Zero-based because every other line number in this editor is -- the rope,
    the caret and the language server all count from zero, and the one place
    a one-based number belongs is the moment it is drawn.

    Args:
        i: Which hit.

    Returns:
        The line number, or -1 when the index is out of range.
    """
    var hits = g_hits()
    if i < 0 or i >= len(hits[]):
        return -1
    return hits[][i].line


def hit_column(i: Int) -> Int:
    """Where on its line one hit starts, in UTF-16 code units from zero.

    UTF-16 rather than bytes because that is the unit the caret moves in.
    See `_utf16_units` for why the distinction is not academic.

    Args:
        i: Which hit.

    Returns:
        The column, or -1 when the index is out of range.
    """
    var hits = g_hits()
    if i < 0 or i >= len(hits[]):
        return -1
    return hits[][i].column


def hit_text(i: Int) -> String:
    """The whole line a hit is on, trimmed and clipped for a one-line row.

    Args:
        i: Which hit.

    Returns:
        The line's text, or empty when the index is out of range.
    """
    var hits = g_hits()
    if i < 0 or i >= len(hits[]):
        return String("")
    return hits[][i].text


def hit_truncated() -> Bool:
    """Whether the search stopped early because it reached `max_hits`.

    Worth asking and worth showing. A search that silently returns five
    hundred of nine thousand matches is a search that lies, and the person
    reading the list has no way to tell that the answer they want is in the
    part that was not recorded.

    Returns:
        True when at least one further occurrence existed and was not kept.
    """
    return g_truncated()[] != 0


def searched_files() -> Int:
    """How many files were actually opened and read.

    Not how many were walked: the skipped extensions and the oversized files
    never cost an open, and this is the number that says what the search
    really did.

    Returns:
        The count.
    """
    return g_files()[]


def search_needle() -> String:
    """What the last search looked for.

    Returns:
        The needle, or empty if nothing has been searched for yet.
    """
    return g_needle()[]


def clear_hits():
    """Forget the last search entirely, results and counters alike."""
    g_hits()[] = List[Hit]()
    g_needle()[] = String("")
    g_files()[] = 0
    g_truncated()[] = 0


# ===----------------------------------------------------------------------===#
# The search
# ===----------------------------------------------------------------------===#


def search_project(
    root: String, needle: String, max_hits: Int = 500
) raises -> Int:
    """Search every text file under a directory for a literal string.

    Case-sensitive and literal throughout: this is a byte comparison, not a
    regular expression. Every occurrence is recorded, including several on one
    line, and the scan advances by one byte after each match so that a needle
    which can overlap itself reports every position it occupies.

    Any previous results are discarded first, because a results pane holding
    two searches at once is a pane nobody can read.

    Args:
        root: The directory to walk. Made absolute, since a hit's path is
            going to be handed back to the editor's open.
        needle: The literal text to look for.
        max_hits: Stop after this many occurrences. See `hit_truncated`.

    Returns:
        How many occurrences were recorded.

    Raises:
        If the entry points cannot be resolved. A directory that cannot be
        listed or a file that cannot be read is skipped, not raised on:
        one locked file in a project is not a reason to abandon the search.
    """
    clear_hits()
    g_needle()[] = needle
    # An empty needle matches at every byte of every file, forever. There is
    # no useful answer to give, so the answer is none.
    if needle.byte_length() == 0:
        return 0

    var start = absolute(root)

    # A worklist rather than recursion, for a reason that only shows up on a
    # deep tree: a recursive walk holds a `FindFirstFileW` handle open at
    # every level it has descended through. This closes each directory's
    # handle before it opens the next one, and the only thing that grows with
    # depth is a list of paths.
    var pending = List[String]()
    pending.append(start)

    var truncated = False
    while len(pending) > 0 and not truncated:
        var directory = pending.pop(len(pending) - 1)
        var entries = _read_dir(directory)

        var subdirectories = List[String]()
        for entry in entries:
            if entry.is_dir:
                # The root itself is never tested against the skip list: a
                # person who points the search at `build` meant it.
                if not _skip_directory(entry.name):
                    subdirectories.append(entry.path)
                continue
            if entry.size > MAX_FILE_BYTES:
                continue
            if not _looks_like_text(entry.name):
                continue
            if _scan_file(entry.path, needle, max_hits):
                truncated = True
                break

        # Pushed in reverse so the name Windows reported first is the one
        # popped first. The hit list then reads in the same order the sidebar
        # tree draws, rather than back to front.
        if not truncated:
            for k in range(len(subdirectories) - 1, -1, -1):
                pending.append(subdirectories[k])

    g_truncated()[] = 1 if truncated else 0
    return len(g_hits()[])


def _scan_file(path: String, needle: String, max_hits: Int) raises -> Bool:
    """Record every occurrence in one file. True if it stopped at the cap.

    One pass. The line number and the start of the current line are carried
    forward from match to match rather than recomputed, because matches come
    out of `find` in increasing order and counting the newlines before each
    one from the top of the file would make a file with a thousand matches
    cost a thousand scans of itself.
    """
    var text: String
    try:
        with open(path, "r") as f:
            text = f.read()
    except:
        # Locked, denied, or vanished between the walk and the open. One file
        # in a project being unreadable is not a reason to stop searching.
        return False
    g_files()[] += 1

    var hits = g_hits()
    var bytes = text.as_bytes()
    var total = len(bytes)
    var line_number = 0
    var line_start = 0
    var counted = 0
    var at = 0

    while True:
        var found = text.find(needle, at)
        if found < 0:
            return False
        if len(hits[]) >= max_hits:
            # There is at least one more match than the cap allows, which is
            # exactly the condition `hit_truncated` reports.
            return True

        while counted < found:
            if Int(bytes[counted]) == 10:
                line_number += 1
                line_start = counted + 1
            counted += 1

        var line_end = found
        while line_end < total and Int(bytes[line_end]) != 10:
            line_end += 1

        var line = String(text[byte=line_start:line_end])
        hits[].append(
            Hit(
                path,
                line_number,
                _utf16_units(text, line_start, found),
                _clip(line),
            )
        )
        # Advance by one, not by the needle's length, so that "aa" in "aaa"
        # is reported twice. Overlapping occurrences are still occurrences.
        at = found + 1


def _utf16_units(text: String, start: Int, end: Int) -> Int:
    """How many UTF-16 code units the bytes in `[start, end)` encode to.

    This is the column, and getting it wrong is the failure this module was
    most likely to ship with. The editor's caret, Windows' text services and
    the language server all count UTF-16 code units; the text on disk is
    UTF-8. On a line of ASCII the two agree and the bug is invisible. On a
    line with an emoji before the match they differ by three, and "jump to
    this result" puts the caret in the wrong place -- or in a position the
    caret cannot occupy at all, which is worse because it looks like a
    rendering fault rather than a counting one.

    So: a continuation byte is part of a character already counted. A leading
    byte of a four-byte sequence is a codepoint above the basic plane, which
    UTF-16 spells as a surrogate pair and therefore counts as two. Everything
    else is one.
    """
    var bytes = text.as_bytes()
    var units = 0
    for i in range(start, end):
        var byte = Int(bytes[i])
        if (byte & 0xC0) == 0x80:
            continue
        units += 2 if (byte & 0xF8) == 0xF0 else 1
    return units


def _clip(line: String) -> String:
    """A matching line trimmed of surrounding whitespace and cut to length.

    Trimmed because the indentation of a hit says nothing in a flat list and
    pushes the interesting part off the right edge.
    """
    var trimmed = String(line.strip())
    # A UTF-8 byte count is an upper bound on the character count, so a line
    # this short is certainly short enough and needs no walk to prove it.
    if trimmed.byte_length() <= MAX_LINE_CHARS:
        return trimmed^
    # Cut on a character, never on a byte: half a multi-byte sequence is not
    # a string, and the row would draw as a replacement glyph.
    var out = String("")
    var kept = 0
    for codepoint in trimmed.codepoints():
        if kept >= MAX_LINE_CHARS:
            break
        out += chr(Int(codepoint))
        kept += 1
    out += "..."
    return out^


def _skip_directory(name: String) -> Bool:
    """Whether a directory name is one the walk refuses to enter."""
    # Anything hidden or tool-owned. `.git` alone is tens of thousands of
    # loose objects, none of which is a file anybody meant to search.
    if name.startswith("."):
        return True
    return String(SKIP_DIRECTORIES).find("|" + name + "|") >= 0


def _looks_like_text(name: String) -> Bool:
    """Whether a file is worth opening, decided from its name alone."""
    # Two names carry no extension but are certainly source. `CLAUDE.md` is
    # caught by `.md` as well; it is named here so that the rule reads the
    # way it was specified rather than by happy accident.
    if name == "BUILD" or name == "CLAUDE.md":
        return True
    var dot = name.rfind(".")
    if dot < 0:
        return False
    # Lowered because Windows filenames are case-insensitive and a `.MOJO`
    # off a foreign checkout is the same file as a `.mojo`.
    var extension = String(name[byte=dot:]).lower()
    return String(TEXT_EXTENSIONS).find("|" + extension + "|") >= 0


def _read_dir(path: String) raises -> List[Found]:
    """One directory's entries, with the size Windows reported for each.

    Returns an empty list rather than raising when the directory cannot be
    opened. A project walk crosses junctions, permission-denied folders and
    directories that were deleted a moment ago, and none of those is a reason
    to abandon a search of the rest of the tree.
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

    var out = List[Found]()
    var pattern = _utf16z(path + "\\*")
    var data = alloc[UInt8](FIND_DATA_BYTES, alignment=8)
    var handle = FindFirstFileW(
        pattern.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](), Int(data)
    )
    _ = pattern
    if handle == INVALID_HANDLE or handle == 0:
        data.free()
        return out^

    while True:
        var attributes = Int(
            Pointer[UInt32, MutAnyOrigin](unsafe_from_address=Int(data))[]
        )
        var name = _name_at(Int(data) + NAME_OFFSET)
        # `.` and `..` are links back up the tree, and a walk that follows
        # them does not finish.
        if name != "." and name != "..":
            var is_dir = (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0
            var size_high = Int(
                Pointer[UInt32, MutAnyOrigin](
                    unsafe_from_address=Int(data) + SIZE_HIGH_OFFSET
                )[]
            )
            var size_low = Int(
                Pointer[UInt32, MutAnyOrigin](
                    unsafe_from_address=Int(data) + SIZE_LOW_OFFSET
                )[]
            )
            out.append(
                Found(
                    path + "\\" + name,
                    name,
                    is_dir,
                    (size_high << 32) | size_low,
                )
            )
        if FindNextFileW(handle, Int(data)) == 0:
            break
    _ = FindClose(handle)
    data.free()
    return out^


def _name_at(address: Int) -> String:
    """The NUL-terminated UTF-16 name at an address, as a String.

    The same helper `ide/tree.mojo` has. Duplicated rather than imported
    because it is private there, and a module reaching into another module's
    underscored names is a coupling neither of them declared.
    """
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


def search_report() raises -> String:
    """The results as text, one line each, for the command mode and tests.

    Returns:
        A `search N` header and a `path:line:column: text` line per hit,
        followed by a note when the search was truncated.

    Raises:
        Never in practice.
    """
    var out = String("search ") + String(hit_count()) + " in "
    out += String(searched_files()) + " files\n"
    for i in range(hit_count()):
        out += hit_path(i) + ":" + String(hit_line(i) + 1) + ":"
        out += String(hit_column(i)) + ": " + hit_text(i) + "\n"
    if hit_truncated():
        out += "(truncated)\n"
    return out^
