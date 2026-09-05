"""Which toolchain Griddle is using, where it came from, and what is missing.

Milestone 6.1. Every other module in `ide/` reaches the compiler by spelling
a path: `ide/build.mojo` writes `absolute("bazel-bin/KGEN/tools/mojo/mojo.exe")`
in one place, `ide/window.mojo` writes it in another, and the debugger writes
two more. That works exactly as long as everybody is standing in the source
tree with the same current directory, and it fails silently the moment they
are not -- a build that says "could not start it" and a Toolchain pane that
says nothing at all. This module is the one place that answers "which
toolchain", and it answers with paths it has actually stat'd.

THE LOOKUP THE SPRINT ASKS FOR, AND THE ONE THAT WORKS HERE. The sprint
specifies three candidates in order -- `WINMOJO_ROOT`, then
`%LOCALAPPDATA%\\WinMojo\\current`, then beside the binary. That order is
implemented first and unchanged, and it now finds something: packaging
produces exactly this layout, so an installed Griddle sitting in `bin`
recognises the toolchain it was shipped with.

The sentinel is `bin\\mojo.exe`, which is the compiler a release actually
contains. The sprint called it `bin\\winmojo.exe`, a name that exists
nowhere on disk and never did, and while this module used it the installed
branch could not match: a packaged editor walked straight past its own
toolchain and picked up whatever source tree the current directory happened
to be sitting in. A sentinel nobody ships is a lookup that always fails.

So there is a fourth candidate, and it is the one that actually resolves
today: the from-source Bazel tree, identified by
`bazel-bin\\KGEN\\tools\\mojo\\mojo.exe` -- where `bazel-bin` is a junction
into `F:\\bzs`. It is tried in the current directory first and then by walking
up from Griddle's own executable, in that order and for a specific reason:
`build.ensure_linker` resolves its four runtime directories relative to the
current directory, so if this module preferred the walk-up it could name one
toolchain while every build used another. The two agree by construction.

Everything here is measured rather than declared. The version comes from
running `mojo.exe --version` and keeping what it said; it is not a constant in
this file, because a constant would be right until the day it was not and
would never say so. The GPU comes from `nvidia-smi`, for the same reason and
one more: `std.gpu.host.info` is compile-time -- `_accelerator_arch()` is a
build-flag parameter, not a probe -- and its table has no T1000 row, so the
nearest entry to this machine's card is an RTX 2060. Naming the wrong card is
worse than naming none, so an absent `nvidia-smi` produces a gap, not a guess.

That is the rule for the whole module: `toolchain_gaps` is a first-class
output, not an apology. The installed layout's inner paths, the compiler's
build identity behind its `deadbeef` placeholder, an integrated display
adapter `nvidia-smi` cannot see -- each of those is something this machine
cannot establish, and each is reported as unknown rather than filled in.
"""

from std.ffi import c_int
from std.memory import Pointer, alloc
from std.sys._globals import named_global
from std.sys._winkb import winkb_constant
from std.time import perf_counter_ns

from ide.pipes import Child, kill, read_some, set_env, spawn
from ide.win32 import absolute, env_or, win32


@fieldwise_init
struct Component(ImplicitlyCopyable, Movable):
    """One thing the toolchain is supposed to contain.

    Flat and already resolved: the path is absolute and `exists` is what
    Windows said about it, not what the caller should go and check. A row that
    made the reader stat it themselves would be a row that different callers
    answered differently.
    """

    var name: String
    """What it is, in the words the pane prints -- "compiler", "language
    server". Also the key `component_path` looks up, so these are stable."""
    var path: String
    """Absolute, and spelled with backslashes even where this file wrote the
    relative half with forward ones."""
    var exists: Bool
    """From `GetFileAttributesW`, at the moment the lookup ran."""
    var is_dir: Bool
    """Directories are components too: the four runtime folders on the child's
    PATH are as load-bearing as any executable, and a missing one produces a
    debugger with no variables in it rather than an error."""


# ── What identifies each layout ─────────────────────────────────────────────
# The sprint's sentinel. Every one of its three candidates is accepted only if
# this file is under it; a directory that merely exists proves nothing, and
# accepting one would move the failure from "no toolchain" to "the compiler
# would not start", which is a much longer walk back to the truth.
comptime INSTALLED_SENTINEL = "bin/mojo.exe"

# The from-source sentinel: the compiler Bazel builds, under the junction.
comptime SOURCE_SENTINEL = "bazel-bin/KGEN/tools/mojo/mojo.exe"

comptime LAYOUT_NONE = 0
comptime LAYOUT_INSTALLED = 1
comptime LAYOUT_SOURCE = 2

# How far up from the executable to look. Eight is past the top of any tree
# this ships in and short enough that a bad answer is a fast one.
comptime WALK_LIMIT = 8

# `INVALID_FILE_ATTRIBUTES` arrives from the metadata as a signed -1 and
# `GetFileAttributesW` returns unsigned 32-bit, so the direct comparison can
# never be true and every path looks as though it exists. Masked, the way
# `ide/session.mojo` masks it and for the same reason.
comptime INVALID_FILE_ATTRIBUTES = (
    winkb_constant["INVALID_FILE_ATTRIBUTES"]() & 0xFFFFFFFF
)
comptime FILE_ATTRIBUTE_DIRECTORY = 0x10

comptime CAPTURE_CHUNK = 8192
# A cold `mojo.exe` is 113 MB and its first run pages all of it in.
comptime VERSION_TIMEOUT_MS = 20000
comptime GPU_TIMEOUT_MS = 10000


# ── State ───────────────────────────────────────────────────────────────────
# Everything here is a cache of something that cost a syscall or a process, so
# a pane may redraw as often as it likes. `refresh_toolchain` is the only way
# to invalidate it, which is what a person means by pressing refresh.
comptime g_found = named_global["toolchain.found", Int]
comptime g_layout = named_global["toolchain.layout", Int]
comptime g_components = named_global["toolchain.components", List[Component]]
comptime g_serial = named_global["toolchain.serial", Int]

# One-element lists rather than bare slots, throughout. A zero-initialised
# global String is not a valid String and a zero-initialised List is a valid
# empty one -- the reason `ide/symbols.mojo` gives for its `g_uri`.
comptime g_root = named_global["toolchain.root", List[String]]
comptime g_source = named_global["toolchain.source", List[String]]
comptime g_version = named_global["toolchain.version", List[String]]
comptime g_lldb = named_global["toolchain.lldb", List[String]]
comptime g_smi = named_global["toolchain.smi", List[String]]

# Probed-yet flags, separate from the values, because an empty answer is a
# real answer here: a machine with no NVIDIA card and a machine nobody has
# asked yet are different states and only the flag tells them apart.
comptime g_versioned = named_global["toolchain.versioned", Int]
comptime g_lldb_probed = named_global["toolchain.lldb.probed", Int]
comptime g_gpu_probed = named_global["toolchain.gpu.probed", Int]
comptime g_gpus = named_global["toolchain.gpus", List[String]]


def _cell(mut slot: List[String], var text: String):
    """Put a value in a one-element string slot, creating it the first time."""
    if len(slot) == 0:
        slot.append(text^)
    else:
        slot[0] = text^


def _cell_value(slot: List[String]) -> String:
    """Read a one-element string slot, empty when it has never been set."""
    return slot[0] if len(slot) > 0 else String()


# ── Paths ───────────────────────────────────────────────────────────────────
def _backslashed(s: String) -> String:
    """A relative path written with forward slashes, in Windows spelling.

    The relative halves below are written with `/` because that is how
    `ide/build.mojo` already writes them and because a backslash in a source
    string is the character most likely to be mangled by whatever wrote the
    file. Windows accepts either; a person reading the pane should see the
    one they would type.
    """
    var out = String("")
    for ch in s.codepoints():
        out += chr(0x5C) if Int(ch) == 0x2F else chr(Int(ch))
    return out^


def _under(root: String, relative: String) -> String:
    """Join a relative path onto a root, in Windows spelling.

    Args:
        root: An absolute directory, with or without a trailing separator.
        relative: The rest, written with forward slashes.

    Returns:
        The joined path, or just the root when `relative` is empty.
    """
    if relative == "":
        return root
    var base = root
    if base.byte_length() > 0 and base.as_bytes()[base.byte_length() - 1] == 92:
        var trimmed = String(base[byte=0 : base.byte_length() - 1])
        base = trimmed^
    return base + chr(0x5C) + _backslashed(relative)


def _parent(path: String) -> String:
    """The directory above a path, or empty at the top.

    Empty at a drive root rather than `"E:"`-and-onwards forever, which is
    what makes the walk in `_lookup` terminate.
    """
    var cut = path.rfind(chr(0x5C))
    if cut <= 0:
        return String()
    return String(path[byte=0:cut])


def _attributes(path: String) raises -> Int:
    """What Windows says about a path, or -1 when there is nothing there.

    `GetFileAttributesW` reads the directory entry: it opens nothing and takes
    no share lock, so asking about a 113 MB compiler in the middle of a build
    costs the same as asking about an empty file and cannot fail because
    something else has it open.
    """
    if path == "":
        return -1
    var GetFileAttributesW = win32[
        def (Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> UInt32,
        "GetFileAttributesW",
    ]()
    var wide = _utf16z(path)
    var attributes = GetFileAttributesW(
        wide.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    )
    _ = wide
    if Int(attributes) == INVALID_FILE_ATTRIBUTES:
        return -1
    return Int(attributes)


def _exists(path: String) raises -> Bool:
    """Whether a path names something on disk."""
    return _attributes(path) >= 0


def _module_dir() raises -> String:
    """The directory Griddle's own executable is in.

    `GetModuleFileNameW(NULL, ...)` names the running image, which is the only
    honest form of "beside the binary": the current directory is wherever the
    person launched from, and for a double-clicked editor that is not the
    install root.

    Returns:
        The directory, or empty if Windows would not say.
    """
    var GetModuleFileNameW = win32[
        def (
            Int, Pointer[UInt16, MutAnyOrigin], UInt32
        ) thin abi("C") -> UInt32,
        "GetModuleFileNameW",
    ]()
    var buffer = List[UInt16]()
    for _ in range(1024):
        buffer.append(0)
    var n = GetModuleFileNameW(
        0, buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](), UInt32(1024)
    )
    if n == 0 or n >= UInt32(1024):
        return String()
    var full = String("")
    for k in range(Int(n)):
        full += chr(Int(buffer[k]))
    _ = buffer
    return _parent(full)


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


def _quoted(path: String) -> String:
    """A path wrapped in double quotes, for a command line.

    `chr(0x22)` rather than an escaped literal, the way `ide/dap.mojo` writes
    its own and `ide/tree.mojo` writes its backslash.
    """
    var quote = String(chr(0x22))
    return quote + path + quote


# ── The lookup ──────────────────────────────────────────────────────────────
def _lookup() raises:
    """Find a toolchain and record what was found, once.

    The sprint's three candidates first, in the sprint's order, each accepted
    only on its sentinel. Then the from-source tree, which is the one that
    resolves on this machine -- see the module docstring for why it is here at
    all and why the current directory is tried before the executable's.
    """
    g_found()[] = 1
    var components = List[Component]()
    g_components()[] = components^
    _cell(g_root()[], String())
    _cell(g_source()[], String("nothing found"))
    g_layout()[] = LAYOUT_NONE

    # 1. WINMOJO_ROOT. `env_or` reads the C runtime's startup snapshot, which
    # is exactly right for a variable a person set before launching and which
    # nothing in this process writes.
    var named = String(env_or("WINMOJO_ROOT", ""))
    if named != "" and _exists(_under(named, INSTALLED_SENTINEL)):
        _accept(named, String("WINMOJO_ROOT"), LAYOUT_INSTALLED)
        return

    # 2. Beside the binary, and above it: an installed editor sits in the
    # toolchain's own `bin`, so its root is a level or two up.
    #
    # Ahead of the junction below, and the order matters. This is the most
    # specific answer there is: an executable that is sitting inside an
    # installation is running from that installation, whatever some other
    # directory has been made current since. With the junction first, a copy
    # installed anywhere else reported the current one as its toolchain --
    # correct-looking, entirely wrong, and invisible until its Examples menu
    # was empty because the *other* installation had no examples in it.
    var here = _module_dir()
    var up = here
    var steps = 0
    while up != "" and steps < WALK_LIMIT:
        if _exists(_under(up, INSTALLED_SENTINEL)):
            _accept(up^, String("beside the binary"), LAYOUT_INSTALLED)
            return
        up = _parent(up)
        steps += 1

    # 3. %LOCALAPPDATA%\WinMojo\current -- the junction an installer
    # re-points to make a version current. This is for an executable that is
    # not inside an installation at all: a shortcut somewhere, a build in a
    # scratch directory, a bare griddle.exe copied onto a desktop.
    var local = String(env_or("LOCALAPPDATA", ""))
    if local != "":
        var current = _under(local, "WinMojo/current")
        if _exists(_under(current, INSTALLED_SENTINEL)):
            _accept(
                current^,
                String("%LOCALAPPDATA%") + chr(0x5C) + "WinMojo"
                + chr(0x5C) + "current",
                LAYOUT_INSTALLED,
            )
            return

    # 4. The from-source tree. Current directory first, because
    # `build.ensure_linker` resolves its runtime directories against the
    # current directory: preferring the walk-up here would let this module
    # name one toolchain while every build in the editor used another.
    var cwd = absolute(".")
    if _exists(_under(cwd, SOURCE_SENTINEL)):
        _accept(
            cwd^, String("bazel-bin in the current directory"), LAYOUT_SOURCE
        )
        return

    var climb = here
    steps = 0
    while climb != "" and steps < WALK_LIMIT:
        if _exists(_under(climb, SOURCE_SENTINEL)):
            _accept(
                climb^,
                String("bazel-bin above the executable"),
                LAYOUT_SOURCE,
            )
            return
        climb = _parent(climb)
        steps += 1

    # Nothing. The components list stays empty and `toolchain_gaps` says so;
    # inventing a root here would turn one clear failure into a pane full of
    # missing files under a directory that was never a toolchain.


def _accept(var root: String, var source: String, layout: Int) raises:
    """Record the winning candidate and stat everything under it."""
    _cell(g_root()[], root)
    _cell(g_source()[], source^)
    g_layout()[] = layout
    var rows = List[Component]()
    if layout == LAYOUT_INSTALLED:
        _installed_components(root, rows)
    else:
        _source_components(root, rows)
    # Built in a local and moved in at the end, the way `ide/symbols.mojo`
    # builds its outline: a pane reading the global mid-walk would draw half a
    # toolchain.
    g_components()[] = rows^
    g_serial()[] += 1


def _installed_components(root: String, mut rows: List[Component]) raises:
    """The components of a packaged toolchain.

    These were guesses when this was written, and they are not any more.
    `release/windows/create-release.ps1` builds this layout, so every path
    below is one that packaging actually produces and that has been walked on
    disk. The one that mattered most was the sentinel: nothing ships as
    `winmojo.exe` -- the sprint invented the name -- so this branch had never
    once matched, and a packaged Griddle walked past its own toolchain to find
    whatever source tree the current directory happened to be sitting in.

    Two differences from the source tree are worth naming, because they are
    what makes an installed toolchain a different shape rather than the same
    shape somewhere else. The debugger is `mojo-lldb.exe`, renamed by
    packaging so it cannot be confused with a system LLDB on PATH. And there
    is no stdlib directory at all: a release ships `lib/std.mojoc`, a compiled
    package that the compiler finds through `import_path` in `modular.cfg`,
    so a build from an installed toolchain passes no `-I` for it and must not.
    """
    _add(rows, String("compiler"), _under(root, INSTALLED_SENTINEL), False)
    _add(
        rows,
        String("language server"),
        _under(root, "bin/mojo-lsp-server.exe"),
        False,
    )
    _add(rows, String("debug adapter"), _under(root, "bin/lldb-dap.exe"), False)
    _add(rows, String("debugger"), _under(root, "bin/mojo-lldb.exe"), False)
    _add(
        rows, String("debugger plugin"), _under(root, "lib/MojoLLDB.dll"), False
    )
    _add(rows, String("linker"), _under(root, "bin/lld.exe"), False)
    _add(rows, String("runtime bin"), _under(root, "bin"), True)
    _add(rows, String("runtime lib"), _under(root, "lib"), True)
    _add(rows, String("import path"), _under(root, "lib/std.mojoc"), False)
    _add(rows, String("staged linker"), _staged_linker(), False)
    _add(rows, String("win32 metadata"), _metadata_path(), False)


def _source_components(root: String, mut rows: List[Component]) raises:
    """The components of the from-source tree, under the `bazel-bin` junction.

    Every path here has been stat'd on this machine. The four runtime
    directories are the same four `build.ensure_linker` puts on a child's
    PATH, in the same order, so the pane and the build cannot disagree about
    what is staged.
    """
    _add(rows, String("compiler"), _under(root, SOURCE_SENTINEL), False)
    _add(
        rows,
        String("language server"),
        _under(
            root, "bazel-bin/KGEN/tools/mojo-lsp-server/mojo-lsp-server.exe"
        ),
        False,
    )
    _add(
        rows,
        String("debug adapter"),
        _under(
            root,
            "bazel-bin/external/+llvm_configure+llvm-project/lldb/lldb-dap.exe",
        ),
        False,
    )
    _add(
        rows,
        String("debugger"),
        _under(
            root,
            "bazel-bin/external/+llvm_configure+llvm-project/lldb/lldb.exe",
        ),
        False,
    )
    _add(
        rows,
        String("debugger plugin"),
        _under(root, "bazel-bin/KGEN/MojoLLDB.dll"),
        False,
    )
    _add(
        rows,
        String("linker"),
        _under(
            root, "bazel-bin/external/+llvm_configure+llvm-project/lld/lld.exe"
        ),
        False,
    )
    _add(rows, String("runtime KGEN"), _under(root, "bazel-bin/KGEN"), True)
    _add(
        rows, String("runtime AsyncRT"), _under(root, "bazel-bin/AsyncRT"), True
    )
    _add(
        rows, String("runtime Support"), _under(root, "bazel-bin/Support"), True
    )
    _add(
        rows,
        String("runtime nvptx"),
        _under(root, "bazel-bin/nvptx/runtime"),
        True,
    )
    _add(
        rows,
        String("runtime lldb"),
        _under(root, "bazel-bin/external/+llvm_configure+llvm-project/lldb"),
        True,
    )
    _add(rows, String("stdlib"), _under(root, "mojo/stdlib"), True)
    _add(rows, String("staged linker"), _staged_linker(), False)
    _add(rows, String("win32 metadata"), _metadata_path(), False)


def _staged_linker() -> String:
    """Where `build.ensure_linker` copies lld under the name `link.exe`.

    Listed because a stale or absent copy here is invisible and fatal: the
    compiler asks for `link`, MSYS answers with its hard-link utility, and
    every in-editor build fails complaining about a flag.
    """
    return _under(String(env_or("TEMP", ".")), "griddle-linkbin/link.exe")


def _metadata_path() -> String:
    """The `windows_api.db` the compiler was told to use, if it was told.

    Empty when `MODULAR_MOJO_MAX_WINKB_PATH` is unset, which is a gap rather
    than a default: the database is a 90 MB file whose location this module
    has no way to guess and no business guessing.
    """
    return _backslashed(String(env_or("MODULAR_MOJO_MAX_WINKB_PATH", "")))


def _add(
    mut rows: List[Component], var name: String, var path: String, want_dir: Bool
) raises:
    """Stat one component and append it."""
    var attributes = _attributes(path)
    var present = attributes >= 0
    var is_dir = present and (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0
    # A file where a directory belongs counts as missing. It is the same
    # failure -- nothing usable is there -- and reporting it as present would
    # send a reader looking for a permissions problem.
    if present and want_dir != is_dir:
        present = False
    rows.append(Component(name^, path^, present, is_dir))


def _ensure_found() raises:
    """Run the lookup if it has not run."""
    if g_found()[] == 0:
        _lookup()


# ── What was found ──────────────────────────────────────────────────────────
def toolchain_root() raises -> String:
    """The directory the toolchain was found under.

    Returns:
        The absolute path, or empty when no candidate had its sentinel.

    Raises:
        If a Win32 entry point cannot be resolved.
    """
    _ensure_found()
    return _cell_value(g_root()[])


def root_source() raises -> String:
    """Which candidate won, in words.

    The pane prints this beside the root, because "E:\\Mojo\\..." on its own
    does not say whether a person is looking at an installed product or the
    tree they are standing in, and the two behave differently.

    Returns:
        One of "WINMOJO_ROOT", "%LOCALAPPDATA%\\WinMojo\\current", "beside the
        binary", "bazel-bin in the current directory", "bazel-bin above the
        executable", or "nothing found".

    Raises:
        If a Win32 entry point cannot be resolved.
    """
    _ensure_found()
    return _cell_value(g_source()[])


def layout_name() raises -> String:
    """Which shape of toolchain this is.

    Returns:
        "installed", "from-source", or "none".

    Raises:
        If a Win32 entry point cannot be resolved.
    """
    _ensure_found()
    var layout = g_layout()[]
    if layout == LAYOUT_INSTALLED:
        return String("installed")
    if layout == LAYOUT_SOURCE:
        return String("from-source")
    return String("none")


def component_count() raises -> Int:
    """How many components the found layout is supposed to have.

    Returns:
        The count, zero when nothing was found.

    Raises:
        If a Win32 entry point cannot be resolved.
    """
    _ensure_found()
    return len(g_components()[])


def component_at(i: Int) raises -> Component:
    """One component.

    Args:
        i: Its index, in the order the pane draws them.

    Returns:
        The component.

    Raises:
        If the index is out of range.
    """
    _ensure_found()
    var rows = g_components()
    if i < 0 or i >= len(rows[]):
        raise Error("no such component")
    return rows[][i]


def component_path(name: String) raises -> String:
    """One component's path, by the name the report prints.

    This is the hook the rest of the editor would use instead of spelling a
    path: `component_path("compiler")` answers with whichever layout was
    found, so a packaged Griddle and a from-source one need no different code.
    A missing component still has a path -- the caller wants to say which file
    was not there.

    Args:
        name: The component's name, e.g. "compiler".

    Returns:
        Its absolute path, or empty when this layout has no such component.

    Raises:
        If a Win32 entry point cannot be resolved.
    """
    _ensure_found()
    var rows = g_components()
    for i in range(len(rows[])):
        if rows[][i].name == name:
            return rows[][i].path
    return String()


def toolchain_serial() -> Int:
    """How many times the toolchain has been looked up.

    The counter a draw compares against what it last drew, the way the rest of
    the client does it. Comparing the component list would mean copying it,
    and comparing its length would miss a refresh that swapped one root for
    another with the same number of pieces.

    Returns:
        The serial.
    """
    return g_serial()[]


def refresh_toolchain() raises -> Int:
    """Look again, forgetting every cached answer.

    The version and the GPU go too, not just the paths. A person presses
    refresh after installing something, and a refresh that kept reporting the
    old compiler's version would be worse than no refresh at all.

    Returns:
        How many components the new lookup has.

    Raises:
        If a Win32 entry point cannot be resolved.
    """
    g_found()[] = 0
    g_versioned()[] = 0
    g_lldb_probed()[] = 0
    g_gpu_probed()[] = 0
    g_gpus()[] = List[String]()
    _ensure_found()
    return len(g_components()[])


# ── Running the binaries to find out ────────────────────────────────────────
def _capture(command: String, timeout_ms: Int) raises -> String:
    """Run a command to completion and return everything it printed.

    Its own capture rather than `build.start`, because that one owns a single
    global child and drives it from the window's timer: asking the compiler
    its version must not cancel somebody's build. The transport underneath is
    the same `ide/pipes.mojo`.

    The wait is `WaitForSingleObject` with a small timeout rather than a spin
    or a sleep -- it returns the instant the child exits, and costs nothing
    while it does not.

    Args:
        command: The full command line, executable first and quoted.
        timeout_ms: How long to allow before giving up and killing it.

    Returns:
        stdout and stderr interleaved, or empty if it would not start.

    Raises:
        If a Win32 entry point cannot be resolved.
    """
    var child = spawn(command, String(""), merge_stderr=True)
    if not child.running():
        return String()
    var WaitForSingleObject = win32[
        def (Int, UInt32) thin abi("C") -> UInt32, "WaitForSingleObject"
    ]()
    var out = String("")
    var buffer = alloc[UInt8](CAPTURE_CHUNK, alignment=8)
    var deadline = perf_counter_ns() + timeout_ms * 1_000_000
    var exited = False
    while True:
        while True:
            var got = read_some(child.reads_from, Int(buffer), CAPTURE_CHUNK)
            if got <= 0:
                break
            for i in range(got):
                out += chr(Int(buffer[i]))
        # The drain above runs once more after the process has gone: its last
        # words are still in the pipe when it exits, and a loop that broke on
        # exit would lose exactly the line this function came for.
        if exited:
            break
        if perf_counter_ns() > deadline:
            break
        if WaitForSingleObject(child.process, UInt32(10)) == UInt32(0):
            exited = True
    buffer.free()
    # Closes both pipes and the two handles as well as ending the process,
    # which for one that has already exited is just the closing.
    kill(child)
    return out^


def _first_line(text: String) -> String:
    """The first line with anything on it, trimmed of its CRLF.

    A version banner is one line and everything after it is noise -- lld
    prints a paragraph about being a multiplexer, and the compiler prints its
    version and nothing else.
    """
    var lines = text.split("\n")
    for line in lines:
        var one = String(String(line).strip())
        if one != "":
            return one^
    return String()


def mojo_version() raises -> String:
    """What the compiler says its version is, asked once.

    Run rather than declared. A constant in this file would be right until the
    day somebody rebuilt the toolchain, and would then be wrong without ever
    saying so.

    Measured rather than assumed: this answers correctly with nothing of the
    toolchain on PATH at all, because Windows searches an executable's own
    directory for its imports before it searches PATH and the compiler's DLLs
    sit beside it under `bazel-bin\\KGEN`. So the version does not wait on
    `build.ensure_linker` having run, and a Toolchain pane can be opened
    before anything has been built. Should the probe fail anyway this answers
    empty, and `toolchain_gaps` says so rather than papering over it with a
    plausible number.

    Returns:
        The banner, e.g. `Mojo 1.1.0.dev0 (deadbeef)`, or empty.

    Raises:
        If a Win32 entry point cannot be resolved.
    """
    if g_versioned()[] != 0:
        return _cell_value(g_version()[])
    g_versioned()[] = 1
    _cell(g_version()[], String())
    var compiler = component_path(String("compiler"))
    if compiler == "" or not _exists(compiler):
        return String()
    var said = _capture(_quoted(compiler) + " --version", VERSION_TIMEOUT_MS)
    var line = _first_line(said)
    _cell(g_version()[], line)
    return line^


def debugger_version() raises -> String:
    """What lldb says its version is, asked once.

    A second fact for the same reason as the first, and a different one: the
    debugger in this tree is LLVM's, built alongside the compiler but
    versioned by LLVM, so it is not derivable from the Mojo banner.

    Returns:
        The banner, e.g. `lldb version 24.0.0git`, or empty.

    Raises:
        If a Win32 entry point cannot be resolved.
    """
    if g_lldb_probed()[] != 0:
        return _cell_value(g_lldb()[])
    g_lldb_probed()[] = 1
    _cell(g_lldb()[], String())
    var debugger = component_path(String("debugger"))
    if debugger == "" or not _exists(debugger):
        return String()
    var said = _capture(_quoted(debugger) + " --version", VERSION_TIMEOUT_MS)
    var line = _first_line(said)
    _cell(g_lldb()[], line)
    return line^


# ── The GPU ─────────────────────────────────────────────────────────────────
def _find_smi() raises -> String:
    """Where `nvidia-smi` is, if it is anywhere.

    The driver puts it in System32, which is why it works from any prompt
    without anything being on PATH; older packages put it under the NVSMI
    folder in Program Files. Both are tried and neither is assumed.
    """
    var system = _under(
        String(env_or("SystemRoot", "C:\\Windows")), "System32/nvidia-smi.exe"
    )
    if _exists(system):
        return system^
    var packaged = _under(
        String(env_or("ProgramFiles", "C:\\Program Files")),
        "NVIDIA Corporation/NVSMI/nvidia-smi.exe",
    )
    if _exists(packaged):
        return packaged^
    return String()


def _probe_gpu() raises:
    """Ask nvidia-smi what is installed, once."""
    if g_gpu_probed()[] != 0:
        return
    g_gpu_probed()[] = 1
    g_gpus()[] = List[String]()
    var smi = _find_smi()
    _cell(g_smi()[], smi)
    if smi == "":
        return
    # One row per card, comma-separated, no header. The compute capability is
    # the number that matters here -- this machine's card is 7.5, and a good
    # deal of MAX is gated above it.
    var said = _capture(
        _quoted(smi)
        + " --query-gpu=name,compute_cap,driver_version,memory.total"
        + " --format=csv,noheader",
        GPU_TIMEOUT_MS,
    )
    var found = List[String]()
    var lines = said.split("\n")
    for line in lines:
        var one = String(String(line).strip())
        # A driver that is installed but not running answers with a sentence
        # rather than a row. A row has the four fields' three commas in it.
        if one != "" and one.find(",") > 0:
            found.append(one^)
    g_gpus()[] = found^


def gpu_count() raises -> Int:
    """How many GPUs a real probe found.

    Zero means nvidia-smi was absent or said nothing, never that the machine
    has no display. This module reports NVIDIA cards because that is what it
    has a truthful source for.

    Returns:
        The count.

    Raises:
        If a Win32 entry point cannot be resolved.
    """
    _probe_gpu()
    return len(g_gpus()[])


def gpu_at(i: Int) raises -> String:
    """One GPU, as nvidia-smi described it.

    Passed through rather than parsed into fields. The four values are name,
    compute capability, driver version and total memory, and reformatting them
    would put this module's spelling between the reader and the driver's.

    Args:
        i: Which card.

    Returns:
        The CSV row, e.g. `NVIDIA T1000 8GB, 7.5, 582.08, 8192 MiB`.

    Raises:
        If the index is out of range.
    """
    _probe_gpu()
    var gpus = g_gpus()
    if i < 0 or i >= len(gpus[]):
        raise Error("no such gpu")
    return gpus[][i]


def gpu_source() raises -> String:
    """The program the GPU facts came from.

    Shown so the pane can say where it got them, and empty when it got none.
    The alternatives were both considered and both lie: `Win32_VideoController`
    lists this machine's integrated adapter first and truncates an 8 GB card's
    memory to 4293918720, and `std.gpu.host.info` is a compile-time table with
    no T1000 in it whose nearest row is a different card.

    Returns:
        The path to nvidia-smi, or empty.

    Raises:
        If a Win32 entry point cannot be resolved.
    """
    _probe_gpu()
    return _cell_value(g_smi()[])


# ── What could not be established ───────────────────────────────────────────
def toolchain_gaps() raises -> List[String]:
    """Everything this machine could not answer, in sentences.

    A first-class output, printed by `toolchain_report` and drawn by the pane.
    The alternative to saying "unknown" is filling a field in, and a Toolchain
    view whose GPU row is a plausible guess is worse than one whose GPU row is
    blank: the blank one sends a person to look, and the guess does not.

    Returns:
        Zero or more sentences.

    Raises:
        If a Win32 entry point cannot be resolved.
    """
    var gaps = List[String]()
    _ensure_found()

    if g_layout()[] == LAYOUT_NONE:
        gaps.append(
            String(
                "no toolchain found: no candidate had bin"
            )
            + chr(0x5C)
            + "mojo.exe under it and no bazel-bin tree was above the"
            + " executable or in the current directory"
        )

    for i in range(component_count()):
        var c = component_at(i)
        if c.path == "":
            gaps.append(
                String("no path is known for the ") + c.name
                + "; MODULAR_MOJO_MAX_WINKB_PATH is unset and this module does"
                + " not guess where a 90 MB database lives"
            )

    var compiler = component_path(String("compiler"))
    if compiler != "" and _exists(compiler) and mojo_version() == "":
        gaps.append(
            String("the compiler is at ") + compiler
            + " but would not answer --version; its runtime DLL directories"
            + " are probably not on PATH, which build.ensure_linker arranges"
        )
    if mojo_version().find("deadbeef") >= 0:
        gaps.append(
            String("the compiler reports (deadbeef) as its build identity,")
            + " which is a placeholder rather than a commit; the tree's real"
            + " revision is a separate fact this module does not read"
        )

    if gpu_count() == 0:
        gaps.append(
            String("no GPU established: nvidia-smi was not found, so the card")
            + " is reported as unknown rather than guessed from a table"
        )
    else:
        gaps.append(
            String("nvidia-smi sees only NVIDIA adapters, so an integrated")
            + " display adapter is absent from this list rather than missing"
        )
        gaps.append(
            String("the architecture the compiler is configured to target is")
            + " not read here; this is the card that is present, which is a"
            + " different question"
        )
    return gaps^


# ── The text form ───────────────────────────────────────────────────────────
def toolchain_report() raises -> String:
    """The toolchain as text, the way the pane draws it.

    The same shape as `tree.tree_report` and `symbols.symbols_report`, and for
    the same reason: a feature whose whole output is a list needs one way to
    print that list that is not the window, or every check of it is a
    screenshot.

    The count on the header line is the components, not the rows: the facts
    above them are one line each and the gaps below are as many as there are.
    Each row's first word is its own marker -- `root`, `ok`, `--`, `gap` -- so
    a check greps for what it cares about without counting columns.

    Returns:
        `toolchain N`, the found facts, a line per component, and a line per
        gap.

    Raises:
        If a Win32 entry point cannot be resolved.
    """
    _ensure_found()
    var out = String("toolchain ") + String(component_count()) + "\n"

    var root = toolchain_root()
    out += "  root " + (root if root != "" else String("(none)")) + "\n"
    out += "  source " + root_source() + "\n"
    out += "  layout " + layout_name() + "\n"

    var mojo = mojo_version()
    out += "  mojo " + (mojo if mojo != "" else String("(unknown)")) + "\n"
    var lldb = debugger_version()
    out += "  lldb " + (lldb if lldb != "" else String("(unknown)")) + "\n"

    if gpu_count() == 0:
        out += "  gpu (unknown: no nvidia-smi)\n"
    else:
        for i in range(gpu_count()):
            out += "  gpu " + gpu_at(i) + "\n"

    for i in range(component_count()):
        var c = component_at(i)
        # Two characters either way, so the names line up without padding
        # anything and without a column width to keep in step.
        out += "  " + ("ok " if c.exists else "-- ") + c.name + " "
        out += c.path if c.path != "" else String("(no path)")
        out += "\n"

    var gaps = toolchain_gaps()
    for gap in gaps:
        out += "  gap " + gap + "\n"
    return out^


# ===----------------------------------------------------------------------===#
# Making an installed copy point at itself
# ===----------------------------------------------------------------------===#


def adopt_installed_toolchain() raises -> String:
    """Point this installation's configuration and environment at itself.

    Every path in a release's `modular.cfg` is absolute and was written for
    the directory the release was packaged in. `paths.cmd` rewrites them, and
    every launcher in the package calls it -- but nobody pins a batch file to
    their taskbar. Launched as `bin\\griddle.exe`, the editor spawned a compiler
    that went looking for a directory on the packaging machine, and every
    build failed with "unable to locate module 'std'", which reads like a
    broken installation rather than a moved one.

    So the editor does it too, from the root its own lookup found. Three
    things, all of them things a launcher would otherwise have had to do:
    the configuration is rewritten if this copy has moved, `MODULAR_HOME` is
    set so a child compiler finds that configuration at all, and `bin` and
    `lib` go on PATH so a built program finds the runtime DLLs beside it.

    Does nothing for a source tree, which has no `modular.cfg` and needs none.

    Returns:
        What it did, for the startup log, or why there was nothing to do.

    Raises:
        Never in practice; a failure to write is reported, not raised.
    """
    if layout_name() != "installed":
        return String("")
    var root = toolchain_root()
    if root == "":
        return String("")

    # The environment first: it costs nothing and is right even when the
    # configuration is already current.
    try:
        set_env(String("MODULAR_HOME"), root)
    except:
        pass
    try:
        var path = String(env_or("PATH", ""))
        var bin = _under(root, "bin")
        var lib = _under(root, "lib")
        set_env(String("PATH"), bin + ";" + lib + ";" + path)
    except:
        pass

    var stamp = _under(root, "modular.cfg.root")
    var recorded = _read_text(stamp)
    if _same_path(recorded, root):
        return String("")

    var template = _read_text(_under(root, "modular.cfg.in"))
    if template == "":
        # No template, so nothing can be rewritten. Said rather than silently
        # skipped: a package missing its template is one that cannot be moved,
        # and somebody should find that out here rather than from a build.
        return String("this installation has no modular.cfg.in; it cannot be moved")

    var written = _replaced(template, String("@RELEASE_ROOT@"), root)
    if not _write_text(_under(root, "modular.cfg"), written):
        return String("could not rewrite modular.cfg in ") + root
    _ = _write_text(stamp, root)
    return String("pointed the toolchain at ") + root


def _read_text(path: String) -> String:
    """A whole file, or empty when it cannot be read."""
    try:
        var handle = open(path, "r")
        var text = handle.read()
        # Closed by name: `with` does not release it here, and this file is
        # about to be written. See docs/mojo-traps.md.
        handle.close()
        return String(text.strip())
    except:
        return String("")


def _write_text(path: String, text: String) -> Bool:
    """Replace a file's contents. True when it worked."""
    try:
        var handle = open(path, "w")
        handle.write(text)
        handle.close()
        return True
    except:
        return False


def _same_path(a: String, b: String) -> Bool:
    """Whether two paths name the same place, ignoring case.

    Windows paths are case-insensitive, and a shortcut that spells the drive
    letter in lower case would otherwise rewrite the configuration on every
    single start.
    """
    return a.lower() == b.lower()


def _replaced(text: String, needle: String, value: String) -> String:
    """Every occurrence of `needle` replaced by `value`."""
    var out = String("")
    var rest = text
    while True:
        var at = rest.find(needle)
        if at < 0:
            out += rest
            return out^
        out += rest[byte=:at] + value
        # Into a fresh String first, then moved: assigning a slice of `rest`
        # back over `rest` makes the slice borrow the storage it is about to
        # overwrite. `ide/window.mojo` hits the same wall in `start_server`.
        var tail = String(rest[byte = at + needle.byte_length() :])
        rest = tail^
