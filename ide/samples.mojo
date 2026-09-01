"""The examples the toolchain ships, as a menu.

Sprint 4.4 describes an Examples view of cards reading from the toolchain's
`share\\examples`, copied into `Documents\\WinMojo Examples\\` on first open.
Two of those three things turned out not to match anything that exists, and
this is what was built instead, with the reasons.

THERE IS NO `share\\examples`. The string appears twice in this repository and
both are design documents; no code has ever created such a directory and the
packaging does not. What exists is `examples/win32`, eleven Mojo files that
are named one by one in IDE-DESIGN.md and are the set the design was written
about. So that is what this reads, and packaging copies it into the release
under the same name.

THEY ARE PROJECTS, NOT FILES. Each one is a directory holding `main.mojo`,
which is the same shape the Mac port looks for and the same shape
`ide/build.mojo` already prefers when it looks for a project's entry point.
They began as eleven loose files, and that was the wrong shape for the same
reason it would be wrong for anything else the editor opens: a single file
cannot carry a README saying what it demonstrates, a requirements.txt naming
what it needs, or a second source file. This editor is folder-based
everywhere else and examples are not a special case.

NOTHING IS COPIED. The sprint wanted the first open to copy the example
somewhere writable so the shipped copy stays pristine. The Mac port, which had
the same idea available to it, opens them in place; and a copy raises
questions this cannot answer well -- where the second copy goes, what happens
when the toolchain is updated under it, which of the two a person is looking
at when they have both. Opening in place is what every other editor does with
a file it did not write, and `Documents\\WinMojo Examples` is a decision
better made when somebody asks for it than guessed at now.

WHAT THEY DO. Eight of the eleven build and run on this machine. Three --
`adreno_index_probe`, `adreno_saxpy`, `adreno_saxpy_debug` -- are Qualcomm
programs: they build here and stop at runtime with `nvptxrt does not implement
device API 'adreno'`, which is a fact about the example rather than about the
installation. They are listed anyway. Hiding a file that is really there, in a
menu whose whole job is to say what is really there, would be worse than
letting somebody read the name and find out what it is for.
"""

from std.os import getenv
from std.sys._globals import named_global

from ide.tree import Entry, list_dir
from ide.win32 import absolute, env_or
from ide.toolchain import layout_name, toolchain_root


# The examples, discovered once. A menu is built at startup and the set cannot
# change under it without the directory changing, which is not something worth
# watching for.
comptime g_paths = named_global["samples.paths", List[String]]
comptime g_names = named_global["samples.names", List[String]]
comptime g_looked = named_global["samples.looked", Int]
comptime g_root = named_global["samples.root", List[String]]


def samples_root() raises -> String:
    """Where the examples are.

    `GRIDDLE_EXAMPLES` first, so a working tree or a check can point this
    somewhere of its own; then the installed toolchain's own copy; then the
    source tree's. The same shape as every other lookup here, and for the same
    reason: the machine this runs on is sometimes a release and sometimes a
    checkout, and an editor that only works in one of them is half an editor.

    Returns:
        The directory, or empty when there is none.

    Raises:
        If a path cannot be made absolute.
    """
    var named = String(env_or("GRIDDLE_EXAMPLES", ""))
    if named != "":
        return named^

    if layout_name() == "installed":
        var root = toolchain_root()
        if root != "":
            var shipped = root + chr(0x5C) + "examples" + chr(0x5C) + "win32"
            if _has_examples(shipped):
                return shipped^

    var here = absolute(String("examples") + chr(0x5C) + "win32")
    return here^ if _has_examples(here) else String("")


def _has_examples(path: String) raises -> Bool:
    """Whether a directory is there AND has example projects in it.

    Both halves matter, and the first one cannot be asked on its own here:
    `tree.list_dir` answers an empty list for a directory it cannot open
    rather than raising, so "not there" and "there and empty" arrive
    identically. Since a candidate with nothing in it is no use to this menu
    either way, the useful question is whether it holds any -- and asking that
    makes the lookup fall through to the next candidate instead of stopping at
    a directory that would give an empty menu.

    Args:
        path: The directory to try.

    Returns:
        True when at least one subdirectory holds a `main.mojo`.

    Raises:
        Never in practice.
    """
    try:
        var rows = list_dir(path)
        for row in rows:
            if row.is_dir and _is_project(row.path):
                return True
        return False
    except:
        return False


def _is_project(path: String) raises -> Bool:
    """Whether a directory is an example project.

    One rule: it has a `main.mojo`. A folder without one is not something the
    editor could open and run, so it is skipped rather than offered and then
    failing -- the Mac port words it the same way and means the same thing.

    Args:
        path: The candidate directory.

    Returns:
        True when `main.mojo` is in it.

    Raises:
        Never in practice.
    """
    try:
        var rows = list_dir(path)
        for row in rows:
            if not row.is_dir and row.name.lower() == "main.mojo":
                return True
        return False
    except:
        return False


def find_samples() raises -> Int:
    """Look for the examples, once, and remember what was found.

    Returns:
        How many there are.

    Raises:
        If the directory cannot be read.
    """
    if g_looked()[] != 0:
        return len(g_paths()[])
    g_looked()[] = 1

    var paths = List[String]()
    var names = List[String]()
    var root = samples_root()
    if len(g_root()[]) == 0:
        g_root()[].append(root)
    else:
        g_root()[][0] = root

    if root != "":
        try:
            var rows = list_dir(root)
            for row in rows:
                if not row.is_dir:
                    continue
                if not _is_project(row.path):
                    continue
                # The folder is what is opened; the name of the folder is what
                # the menu says. `main.mojo` on eleven lines would tell nobody
                # anything.
                paths.append(row.path)
                names.append(row.name)
        except:
            pass

    g_paths()[] = paths^
    g_names()[] = names^
    return len(g_paths()[])


def sample_count() raises -> Int:
    """How many examples there are.

    Returns:
        The count, looking for them if nobody has yet.

    Raises:
        If the directory cannot be read.
    """
    return find_samples()


def sample_name(i: Int) raises -> String:
    """One example's name, without its extension.

    Args:
        i: Which one.

    Returns:
        The name, or empty when out of range.

    Raises:
        If the directory cannot be read.
    """
    _ = find_samples()
    var names = g_names()
    return names[][i] if i >= 0 and i < len(names[]) else String("")


def sample_entry(i: Int) raises -> String:
    """One example's entry point, the file to put on screen first.

    Args:
        i: Which one.

    Returns:
        The path of its `main.mojo`, or empty when out of range.

    Raises:
        If the directory cannot be read.
    """
    var folder = sample_path(i)
    if folder == "":
        return String("")
    return folder + chr(0x5C) + "main.mojo"


def sample_path(i: Int) raises -> String:
    """One example's folder.

    Args:
        i: Which one.

    Returns:
        The path, or empty when out of range.

    Raises:
        If the directory cannot be read.
    """
    _ = find_samples()
    var paths = g_paths()
    return paths[][i] if i >= 0 and i < len(paths[]) else String("")


def sample_index_named(name: String) raises -> Int:
    """Which example has this name, or -1.

    Args:
        name: The example's folder name, case-insensitively.

    Returns:
        Its index, or -1.

    Raises:
        If the directory cannot be read.
    """
    _ = find_samples()
    var want = name.lower()
    var names = g_names()
    for i in range(len(names[])):
        if names[][i].lower() == want:
            return i
    return -1


def sample_named(name: String) raises -> String:
    """One example's path by name, case-insensitively.

    Args:
        name: The name, with or without `.mojo`.

    Returns:
        The path, or empty when there is no such example.

    Raises:
        If the directory cannot be read.
    """
    _ = find_samples()
    var want = name.lower()
    var names = g_names()
    for i in range(len(names[])):
        if names[][i].lower() == want:
            return sample_path(i)
    return String("")


def samples_report() raises -> String:
    """The examples as text, so a check reads what the menu shows.

    Returns:
        `samples N`, where they are, and a line each.

    Raises:
        If the directory cannot be read.
    """
    var total = find_samples()
    var root = g_root()[][0] if len(g_root()[]) > 0 else String("")
    if total == 0:
        if root == "":
            return String("samples 0  (no examples directory found)")
        return String("samples 0  in ") + root
    var out = String("samples ") + String(total) + "  in " + root + "\n"
    for i in range(total):
        out += "  " + sample_name(i) + "\n"
    return out^


def sample_files(i: Int) raises -> List[String]:
    """Everything in one example's folder, entry point first.

    Opening a project means opening what is in it. An example that is three
    files and a README shows all four, with `main.mojo` in front because that
    is the one somebody wants to look at.

    Args:
        i: Which example.

    Returns:
        Absolute paths, `main.mojo` first.

    Raises:
        If the directory cannot be read.
    """
    var out = List[String]()
    var folder = sample_path(i)
    if folder == "":
        return out^
    var entry = sample_entry(i)
    out.append(entry)
    try:
        var rows = list_dir(folder)
        for row in rows:
            if row.is_dir:
                continue
            if row.name.lower() == "main.mojo":
                continue
            # Sources and prose, not build output. A folder somebody has
            # already built in holds an .exe and a .lib nobody wants a tab of.
            if (
                row.name.endswith(".mojo")
                or row.name.endswith(".md")
                or row.name.endswith(".txt")
                or row.name.endswith(".toml")
            ):
                out.append(row.path)
    except:
        pass
    return out^
