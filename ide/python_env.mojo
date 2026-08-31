"""Per-project Python for Griddle: which interpreter, which packages, and the
four variables that make a compiled Mojo program find them.

Python called from Mojo is not another process. `std.python` loads libpython
*into the running Mojo program* and calls `Py_Initialize` there, so a program
built by Griddle has to be told two separate things before it starts: which
library to load, and whose `site-packages` that library should see. Neither is
discoverable on Windows -- the section below is the measurement, not a
guess -- so Griddle has to say both, every time, or Python does not work at
all.

WHICH VARIABLES THIS BUILD ACTUALLY READS. Grepped, not assumed.
`KGEN/lib/CompilerRT/Python.cpp:79` reads `MOJO_PYTHON` and turns it into
`PYTHONEXECUTABLE` at line 95; line 99 reads `MOJO_PYTHON_LIBRARY`;
`mojo/stdlib/std/python/_cpython.mojo:1736` reads `MOJO_PYTHON_LIBRARY` again
and hands it to `OwnedDLHandle`. Those two are the whole of it.
`PYTHONHOME` appears nowhere in `KGEN/` or `mojo/stdlib/` -- the Mac module
sets it and this one deliberately does not, because on Windows a venv is
located from `pyvenv.cfg` and a `PYTHONHOME` pointing at the base prefix would
override the venv rather than support it. `PYTHONPATH` is not set either:
`_cpython.mojo:1721` rewrites it as `f"{file_dir}:{python_path}"`, joining
with a colon, and Windows splits `PYTHONPATH` on semicolons -- anything put
there arrives as one unusable entry glued to a drive letter.

WHAT WAS MEASURED. A probe that imports a marker module out of a venv's
`site-packages`, built with this toolchain and run three ways against a real
venv created by `python -m venv`:

  * `MOJO_PYTHON_LIBRARY` alone -- CPython starts, but `sys.prefix` is the
    base runtime and `sys.executable` is
    `...\\Microsoft\\WindowsApps\\python3.exe`, the Store stub that
    `findProgramByName("python3")` finds first. The venv is not on `sys.path`
    and the marker import fails.
  * `MOJO_PYTHON` alone -- `findLibPython` shells out as
    `python.exe -c '...'` (`Python.cpp:61`), POSIX quoting that `cmd.exe` does
    not honour, so the script dies with `SyntaxError: unterminated string
    literal`, the empty result is taken for the meaningful "look in this
    process" case, and the program aborts with
    `Failed to load libpython from :`.
  * Both -- `sys.prefix` is the venv, `<venv>\\Lib\\site-packages` is on
    `sys.path`, and the marker imports.

So each alone fails, in a different way, and neither failure names the missing
variable. That is the argument for this module existing rather than a README
sentence telling people to set two variables.

WHY `PYTHONEXECUTABLE` IS SET HERE AS WELL. `Python.cpp:95` derives it from
`MOJO_PYTHON` and writes it into the running process, and it is the value that
actually finds the venv -- CPython reads it, locates `pyvenv.cfg` beside it,
and sets `sys.prefix` to the environment. The survey said to leave it to the
compiler runtime. Measurement disagreed. The same probe, with the same
environment, imports the marker when it is started from a shell and does not
when it is started by a Mojo program through `pipes.spawn`: `sys.prefix` comes
back as the base runtime and `os.environ` has no `PYTHONEXECUTABLE` in it,
although `KGEN_CompilerRT_Python_SetPythonPath` returned success in both.

The two children's environments were dumped and compared: identical but for
`_`, which names the parent. So the difference is not the environment -- it is
that the runtime's write happens *inside* the process, after the C runtime has
already taken its copy, and whether CPython sees it afterwards depends on
timing this module does not control. A value present in the block at process
creation has no such question about it. Setting it costs one more variable and
makes the outcome the same every time; the value written is exactly the one
`Python.cpp` would have derived, so nothing disagrees about what it means.

WHAT IS DIFFERENT FROM THE MAC. The venv layout is `Scripts\\python.exe` and
`Lib\\site-packages`, not `bin/python`. A Windows venv carries no libpython of
its own, so `MOJO_PYTHON_LIBRARY` names the *base* runtime's `python3NN.dll`
while `MOJO_PYTHON` names the *venv's* interpreter -- the two values come from
different directories, which is the part that is easy to get wrong and
impossible to notice, because a wrong library still starts a Python. And
nothing is put on `PATH`: `ide/build.mojo`'s `ensure_linker` rebuilds `PATH`
from the C runtime's startup snapshot on every build and would silently drop
whatever this module had added (see `docs/` and the survey in the sprint
report). Every path injected here is absolute, so nothing needs `PATH`.

THIS MODULE HOLDS NO STATE. Every answer is computed from the project path,
the environment and the disk, so two callers asking at different times cannot
disagree, and a check can ask for `python_report` without first arranging for
something to have run.
"""

from std.hashlib._fnv1a import Fnv1a
from std.ffi import c_int
from std.memory import Pointer
from std.sys._com import com_addr
from std.sys._winkb import winkb_constant
from std.time import perf_counter_ns, sleep

from ide.json import JSON
from ide.pipes import kill, read_some, set_env, spawn, utf16z
from ide.win32 import absolute, env_or, win32


# ===----------------------------------------------------------------------===#
# Constants
# ===----------------------------------------------------------------------===#

comptime INVALID_FILE_ATTRIBUTES = (
    winkb_constant["INVALID_FILE_ATTRIBUTES"]() & 0xFFFFFFFF
)
"""Masked to the API's width. The metadata reports this as -1 and
`GetFileAttributesW` returns unsigned 32-bit, so the unmasked comparison can
never be true and every path looks as though it exists. `ide/session.mojo`
made the same masking for the same reason."""

comptime SEP = "\\"
"""The separator every path this module builds uses."""

comptime READ_CHUNK = 4096
"""How much of a child's output to take per read."""

comptime NEWEST_MINOR = 14
comptime OLDEST_MINOR = 8
"""The CPython 3.x minors worth probing for, newest first. A range rather
than a directory listing: the question is only ever "is there a
python3NN.dll beside this python.exe", and 3.8 is older than any Windows
build of this toolchain has ever shipped."""


# ===----------------------------------------------------------------------===#
# Paths
# ===----------------------------------------------------------------------===#


def dirname(path: String) -> String:
    """Everything before the last separator.

    Both separators are accepted on the way in, because a path that reached
    Griddle through a URI or a command line may be spelled with forward
    slashes and still name the same directory.

    Args:
        path: A file or directory path.

    Returns:
        The parent, or empty when the path has no separator past its first
        character. `"E:\\main.mojo"` gives `"E:"`, which is a real place;
        `"main.mojo"` gives empty.
    """
    var cut = path.rfind(SEP)
    var slash = path.rfind("/")
    if slash > cut:
        cut = slash
    if cut <= 0:
        return String()
    return String(path[byte=0:cut])


def basename(path: String) -> String:
    """The last component of a path.

    Args:
        path: A file or directory path.

    Returns:
        Everything after the last separator, or the whole path when it has
        none.
    """
    var cut = path.rfind(SEP)
    var slash = path.rfind("/")
    if slash > cut:
        cut = slash
    return String(path[byte=cut + 1 :]) if cut >= 0 else path


def is_absolute(path: String) -> Bool:
    """Whether a path names a place without reference to a current directory.

    The Mac module asks `startswith("/")`, which on Windows is true of almost
    nothing and would make `package_arguments` glue a project root onto a
    perfectly good `E:\\requirements.txt`.

    Args:
        path: A file or directory path.

    Returns:
        True for `X:\\...` and for a `\\\\server\\share` UNC path.
    """
    if path.byte_length() >= 2:
        var head = String(path[byte=0:2])
        if head == SEP + SEP or head == "//":
            return True
    if path.byte_length() >= 3:
        if String(path[byte=1:2]) == ":":
            var third = String(path[byte=2:3])
            if third == SEP or third == "/":
                return True
    return False


def _join(left: String, right: String) -> String:
    """Two path pieces with exactly one separator between them."""
    if left == "":
        return right
    if left.endswith(SEP) or left.endswith("/"):
        return left + right
    return left + SEP + right


# ===----------------------------------------------------------------------===#
# Which project a launch belongs to
# ===----------------------------------------------------------------------===#


def project_location(root: String, current: String) -> String:
    """The stable directory whose Python packages belong to this launch.

    An open folder wins, because that is what a person means by "this
    project". A loose file falls back to its own directory, so running one
    scratch file does not silently install packages into whichever project
    happened to be open before.

    Args:
        root: The open project root, or empty when none is open.
        current: The path of the file being run, or empty.

    Returns:
        A directory, or empty when there is neither.
    """
    if root != "":
        return root
    return dirname(current)


def project_key(project: String) -> String:
    """A stable, filesystem-safe key that keeps source paths out of filenames.

    FNV-1a over the path's bytes, the same function the Mac module uses -- a
    probe confirmed `hash[Fnv1a](String("/project/a"))` is `f1659aa827aec143`
    on this fork too, so the algorithm carries over unchanged.

    What does *not* carry over is the input, and that is deliberate. Two
    Windows-only decisions, each of which has to be made once and never
    changed, because changing either silently strands every environment that
    already exists:

    * The path is lower-cased and its separators are normalised to backslash
      before hashing. `E:\\proj` and `e:/proj` are the same directory on
      Windows and hashing them apart would build a second environment for a
      project that already had one.
    * The key is sixteen hex digits, always. `hex()` drops leading zeros, so
      one project in sixteen would get a shorter directory name than the
      rest for no reason a reader could work out.

    So a POSIX-spelled path hashes as its backslash form and the Mac's own
    test vector does not transfer: `project_key("/project/a")` is
    `9b3bebb61d0ec567` here, being FNV-1a of `\\project\\a`. A check should
    assert that number rather than the Mac's, and assert separately that the
    four spellings of one Windows directory all agree.

    Args:
        project: The project directory.

    Returns:
        Sixteen lowercase hex digits, or empty for an empty project.
    """
    if project == "":
        return String()
    return _hex64(hash[Fnv1a](_normalized(project)))


def _normalized(path: String) -> String:
    """A path in the one spelling the key is taken from."""
    var text = path.replace("/", SEP).lower()
    while text.byte_length() > 3 and text.endswith(SEP):
        var cut = String(text[byte=0 : text.byte_length() - 1])
        text = cut^
    return text^


def _hex64(value: UInt64) -> String:
    """Sixty-four bits as sixteen lowercase hex digits, zeros and all.

    Written out rather than calling `hex(..., prefix="")`: that goes through
    `Int(value)`, which is signed, and it drops leading zeros. Neither is
    wanted in a directory name that has to be the same next year.
    """
    var digits = String("0123456789abcdef")
    var out = String("")
    var shift = 60
    while shift >= 0:
        var nibble = Int((value >> UInt64(shift)) & UInt64(0xF))
        out += String(digits[byte=nibble : nibble + 1])
        shift -= 4
    return out^


# ===----------------------------------------------------------------------===#
# The runtime Griddle carries
# ===----------------------------------------------------------------------===#


def toolchain_root() raises -> String:
    """Where the compiler, the language server and the debugger live.

    `GRIDDLE_TOOLCHAIN_ROOT` first so a packaged build can say; otherwise the
    `bazel-bin` junction, which is how `ide/build.mojo` and `ide/griddle.mojo`
    already find every tool they spawn. There is no installed product on a
    from-source machine and this must degrade to the build rather than fail.

    Returns:
        An absolute directory, which may not exist.

    Raises:
        If the path cannot be made absolute.
    """
    var override = env_or("GRIDDLE_TOOLCHAIN_ROOT", "")
    if override != "":
        return override^
    return absolute("bazel-bin")


def runtime_home() raises -> String:
    """The CPython prefix Griddle runs Python out of.

    Three candidates, each validated by probing for `python.exe` inside it
    before it is returned, so a stale override falls through to the next one
    instead of poisoning every launch:

    1. `GRIDDLE_PYTHON_HOME`, which is how a check points this at a runtime
       of its own and how a person points it at theirs.
    2. `<toolchain>\\python`, where packaging will put a relocatable CPython
       beside the compiler.
    3. The standalone CPython this toolchain already fetches for its own
       build, under Bazel's external tree, newest minor first.

    Deliberately not `PATH`. The Mac module's rule is that there is no
    fallback to a system Python, and on Windows there is a second reason:
    `python3.exe` on `PATH` is almost always the Microsoft Store stub, which
    is what the compiler's own detection finds and why it fails.

    Returns:
        A directory containing `python.exe`, or empty when there is none.

    Raises:
        If a path cannot be made absolute or the disk cannot be read.
    """
    var override = env_or("GRIDDLE_PYTHON_HOME", "")
    if override != "" and _exists(_join(override, "python.exe")):
        return override^

    var root = toolchain_root()
    var bundled = _join(root, "python")
    if _exists(_join(bundled, "python.exe")):
        return bundled^

    # Bazel's convenience junction is `bazel-<workspace directory, lowercased>`
    # beside the checkout, and the fetched interpreters live under its
    # `external`. Derived rather than written out, so a checkout under another
    # name still finds them; each candidate is probed anyway, so a wrong guess
    # costs one `GetFileAttributesW`.
    var checkout = dirname(root)
    var junction = _join(
        checkout, "bazel-" + basename(checkout).lower()
    )
    var external = _join(junction, "external")
    var minor = NEWEST_MINOR
    while minor >= OLDEST_MINOR:
        var candidate = _join(
            external,
            "rules_python++python+python_3_"
            + String(minor)
            + "_x86_64-pc-windows-msvc",
        )
        if _exists(_join(candidate, "python.exe")):
            return candidate^
        minor -= 1
    return String()


def runtime_python() raises -> String:
    """The interpreter that creates environments.

    `python.exe`, never `python3.exe`: a Windows CPython prefix has no
    `python3.exe` in it, and the only file by that name on a typical machine
    is the Store stub.

    Returns:
        A path, or empty when there is no runtime.

    Raises:
        If the disk cannot be read.
    """
    var home = runtime_home()
    return _join(home, "python.exe") if home != "" else String()


def runtime_minor() raises -> Int:
    """Which CPython this runtime is, from the DLL sitting beside it.

    The version and the library are the same fact on Windows -- `python313.dll`
    says both -- so they are read once, from the filesystem, with no
    subprocess. The Mac reads a `VERSION` file that packaging writes; there is
    no such file here and there does not need to be.

    `python3.dll`, the stable-ABI forwarder, is never matched: only the
    two-digit form is probed.

    Returns:
        The minor version, or zero when no `python3NN.dll` is beside
        `python.exe`.

    Raises:
        If the disk cannot be read.
    """
    var home = runtime_home()
    if home == "":
        return 0
    var minor = NEWEST_MINOR
    while minor >= OLDEST_MINOR:
        if _exists(_join(home, "python3" + String(minor) + ".dll")):
            return minor
        minor -= 1
    return 0


def runtime_version() raises -> String:
    """The runtime as `3.NN`, for the directory name an environment gets.

    `GRIDDLE_PYTHON_VERSION` overrides it, which is what lets a check assert
    a fixed path without a runtime being installed at all.

    Returns:
        `"3.13"` and the like, or `"external"` when nothing says.

    Raises:
        If the disk cannot be read.
    """
    var override = env_or("GRIDDLE_PYTHON_VERSION", "")
    if override != "":
        return override^
    var minor = runtime_minor()
    if minor > 0:
        return String("3.") + String(minor)
    return String("external")


def runtime_library() raises -> String:
    """The libpython to load into the Mojo process.

    This is the value nothing can work out for itself. The compiler runtime
    tries, by running a script that looks for `libpython3.NN.dll` under
    `LIBPL` or `LIBDIR`; on Windows both config variables are `None` and the
    file is called `python3NN.dll` in the prefix root, so the script cannot
    succeed even when the shell quoting that invokes it is fixed.

    `GRIDDLE_PYTHON_LIBRARY` overrides, for a runtime whose DLL is somewhere
    unusual.

    Returns:
        A path to `python3NN.dll`, or empty.

    Raises:
        If the disk cannot be read.
    """
    var override = env_or("GRIDDLE_PYTHON_LIBRARY", "")
    if override != "" and _exists(override):
        return override^
    var home = runtime_home()
    if home == "":
        return String()
    var minor = runtime_minor()
    if minor == 0:
        return String()
    return _join(home, "python3" + String(minor) + ".dll")


def runtime_available() raises -> Bool:
    """Whether Python can be used at all.

    Both halves, because either one alone is a different failure and neither
    names the missing piece: see the measurements in this module's docstring.

    Returns:
        True when there is both an interpreter and a library.

    Raises:
        If the disk cannot be read.
    """
    return runtime_python() != "" and runtime_library() != ""


# ===----------------------------------------------------------------------===#
# The per-project environment
# ===----------------------------------------------------------------------===#


def environments_root() raises -> String:
    """The mutable Python root, outside any project and outside the install.

    Per-user rather than per-project, for the reason the Mac gives: a signed
    or read-only install cannot hold mutable packages, and a `.venv` inside
    the project would be a large directory a person did not create appearing
    in their tree and their source control.

    `GRIDDLE_PYTHON_ENV_ROOT` overrides it, and a check that does not set it
    is a check that writes into the user's real profile.

    `%LOCALAPPDATA%` is read from the environment rather than asked of
    `SHGetKnownFolderPath`, whose known-folder ids are GUID structures the
    metadata cannot hand back as a constant; `ide/build.mojo` reads `%TEMP%`
    the same way for the same reason.

    Returns:
        An existing directory, or empty when it could not be made.

    Raises:
        If the directory cannot be created.
    """
    var override = env_or("GRIDDLE_PYTHON_ENV_ROOT", "")
    if override != "":
        _ = _ensure_dir(override)
        return override^
    var local = env_or("LOCALAPPDATA", "")
    if local == "":
        var profile = env_or("USERPROFILE", "")
        if profile == "":
            return String()
        local = _join(_join(profile, "AppData"), "Local")
    var root = _join(_join(_join(local, "Griddle"), "Python"), "Environments")
    if not _ensure_dir(root):
        return String()
    return root^


def environment_dir(project: String) raises -> String:
    """Where this project's packages live.

    `<root>\\<key>\\py-<version>`. The version is part of the path so that
    upgrading the runtime builds a fresh, compatible environment rather than
    pointing a new CPython at the previous one's `site-packages`, which fails
    later and somewhere else.

    Args:
        project: The project directory.

    Returns:
        A directory, which may not exist yet, or empty when there is no root
        or no project.

    Raises:
        If the disk cannot be read.
    """
    var root = environments_root()
    var key = project_key(project)
    if root == "" or key == "":
        return String()
    return _join(_join(root, key), "py-" + runtime_version())


def environment_python(project: String) raises -> String:
    """The interpreter inside this project's environment.

    Args:
        project: The project directory.

    Returns:
        `<env>\\Scripts\\python.exe`, or empty.

    Raises:
        If the disk cannot be read.
    """
    var env = environment_dir(project)
    if env == "":
        return String()
    return _join(_join(env, "Scripts"), "python.exe")


def environment_ready(project: String) raises -> Bool:
    """Whether this project's environment exists and can be used.

    Two probes rather than one: `pyvenv.cfg` proves it is a venv,
    `Scripts\\python.exe` proves it is a usable one. A half-created
    environment -- an interrupted `-m venv`, an antivirus that ate the
    executable -- has one and not the other, and injecting it would produce a
    Python that starts and imports nothing.

    Args:
        project: The project directory.

    Returns:
        True when both landmarks are there.

    Raises:
        If the disk cannot be read.
    """
    var env = environment_dir(project)
    if env == "":
        return False
    if not _exists(_join(env, "pyvenv.cfg")):
        return False
    return _exists(_join(_join(env, "Scripts"), "python.exe"))


# ===----------------------------------------------------------------------===#
# What gets injected
# ===----------------------------------------------------------------------===#


def variables(project: String) raises -> JSON:
    """The environment that makes a built Mojo program use this project's venv.

    Five members when this project has an environment, four when it does not
    but the toolchain has an interpreter, and none at all when there is no
    Python anywhere. The four-member case exists because of a measurement:
    without `MOJO_PYTHON_LIBRARY` a Mojo program that touches Python does not
    merely miss its packages, it aborts, and nothing on Windows can work that
    value out for itself. What is never injected is anything that changes how
    a project WITHOUT Python builds -- no PATH, no PYTHONHOME -- so this
    feature cannot break what does not use it.

    A `JSON` object because that is the shape `lsp.start_with_environment`
    already takes, so wiring the language server up is passing this in
    instead of `JSON.object()`.

    `MOJO_PYTHON` is the venv's interpreter, which is what the compiler
    runtime checks and names in its diagnostics. `PYTHONEXECUTABLE` is the
    same path said again rather than left to be derived, because it is the
    one CPython reads to find `pyvenv.cfg` and put `sys.prefix` on the
    environment; the module docstring has the measurement that made this
    necessary. `MOJO_PYTHON_LIBRARY` is the *base* runtime's `python3NN.dll`
    -- a venv carries none of its own, and this is the value nothing can
    discover. `VIRTUAL_ENV` is the environment's identity, for pip and for
    anything a package shells out to. `PYTHONNOUSERSITE` is `1`, so a
    successful import cannot secretly depend on the user's global packages.

    No `PATH` and no `PYTHONHOME`, both on purpose; the module docstring says
    why.

    Args:
        project: The project directory.

    Returns:
        An object of string members, empty when there is nothing to inject.

    Raises:
        If the disk cannot be read.
    """
    var vars = JSON.object()
    var library = runtime_library()
    if library == "":
        return vars^
    if not environment_ready(project):
        # No venv, but there is still one thing worth saying, and it is the
        # thing that decides whether Python works at all here. Measured on
        # this machine, twice, with the same binary:
        #
        #   nothing set              -> ABORT: Failed to load libpython from :
        #   MOJO_PYTHON_LIBRARY set  -> python: 3 13
        #
        # The compiler runtime cannot discover the library on Windows --
        # KGEN/lib/CompilerRT/Python.cpp shells out to `python -c` with POSIX
        # quoting, and the script it runs looks for the library under LIBPL
        # and LIBDIR, which CPython leaves as None on Windows. So a Mojo
        # program that imports Python does not fail to find packages; it
        # crashes. Naming the library the toolchain already ships costs a
        # project that has no Python nothing at all, because an environment
        # variable naming a DLL has no effect until something loads it.
        var base = runtime_python()
        if base == "":
            return vars^
        var said = String(base)
        vars.set(String("MOJO_PYTHON"), JSON(base^))
        vars.set(String("PYTHONEXECUTABLE"), JSON(said^))
        vars.set(String("MOJO_PYTHON_LIBRARY"), JSON(library^))
        vars.set(String("PYTHONNOUSERSITE"), JSON(String("1")))
        return vars^
    var python = environment_python(project)
    if python == "":
        return vars^
    # Both names, same value. The compiler runtime reads the first and reports
    # it in its diagnostics; CPython reads the second and is the thing that
    # actually finds the environment.
    var stated = String(python)
    vars.set(String("MOJO_PYTHON"), JSON(python^))
    vars.set(String("PYTHONEXECUTABLE"), JSON(stated^))
    vars.set(String("MOJO_PYTHON_LIBRARY"), JSON(library^))
    vars.set(String("VIRTUAL_ENV"), JSON(environment_dir(project)))
    vars.set(String("PYTHONNOUSERSITE"), JSON(String("1")))
    return vars^


def pip_variables(project: String) raises -> JSON:
    """`variables`, plus the two settings pip should run under.

    `PIP_REQUIRE_VIRTUALENV` is the belt to the absolute path's braces: pip is
    invoked as `<venv>\\Scripts\\python.exe -m pip`, so it cannot install
    into the base runtime, and this makes it say so rather than do it if that
    ever changes.

    Args:
        project: The project directory.

    Returns:
        The object `variables` returns with two more members, or an empty one
        when the environment is not ready.

    Raises:
        If the disk cannot be read.
    """
    var vars = variables(project)
    if vars.count() == 0:
        return vars^
    vars.set(String("PIP_REQUIRE_VIRTUALENV"), JSON(String("1")))
    vars.set(String("PIP_DISABLE_PIP_VERSION_CHECK"), JSON(String("1")))
    return vars^


def apply_variables(project: String) raises -> Int:
    """Put this project's Python into the environment children inherit.

    Called just before a spawn -- after `ensure_linker`, for a build -- and it
    is the whole of the injection: `ide/pipes.mojo` passes NULL for
    `lpEnvironment`, so a child inherits this process's block, and setting a
    variable here is the same result as building a block in one call.

    Two consequences a caller has to know about. This changes Griddle's own
    environment, permanently and for every later child, which is why
    `clear_variables` exists and why the values are re-applied per launch
    rather than once at startup. And `SetEnvironmentVariableW` does not
    update the C runtime's copy, so `env_or` cannot see what this wrote --
    nothing here ever reads its own writes back.

    Args:
        project: The project directory.

    Returns:
        How many variables were set. Zero means there was nothing to inject,
        which is the ordinary case for a project with no Python in it.

    Raises:
        If a Win32 entry point cannot be resolved.
    """
    return _apply(variables(project))


def clear_variables() raises:
    """Take this project's Python back out of the environment.

    Setting a variable to the empty string removes it on Windows. Worth doing
    when a project is closed or another is opened: a `MOJO_PYTHON` left over
    from the last project is a program that starts, imports the wrong
    packages, and gives no sign that it did.

    Raises:
        If a Win32 entry point cannot be resolved.
    """
    set_env(String("MOJO_PYTHON"), String())
    set_env(String("PYTHONEXECUTABLE"), String())
    set_env(String("MOJO_PYTHON_LIBRARY"), String())
    set_env(String("VIRTUAL_ENV"), String())
    set_env(String("PYTHONNOUSERSITE"), String())


def _apply(overlay: JSON) raises -> Int:
    """Set every string member of an overlay, skipping empty ones."""
    var set_count = 0
    var i = 0
    while i < overlay.count():
        var value = overlay.items[i][].as_string()
        if value != "":
            set_env(overlay.keys[i], value)
            set_count += 1
        i += 1
    return set_count


# ===----------------------------------------------------------------------===#
# Command lines
# ===----------------------------------------------------------------------===#


def quoted(argument: String) -> String:
    """One argument, quoted so `CreateProcessW` gives it back whole.

    `ide/pipes.mojo` takes a command line and not an argument vector, which is
    what Windows actually has; the Mac hands `NSTask` a `List[String]` and
    never thinks about this. So the quoting has to happen here, and it has to
    be the rule the C runtime parses by, or a requirement like
    `pkg[extra]>=1,<2` or a project under `C:\\Program Files` breaks in a way
    that looks like pip failing.

    The rule: wrap in double quotes; double every run of backslashes that
    precedes a quote or the closing quote; escape an embedded quote with a
    backslash.

    Args:
        argument: One argument, unquoted.

    Returns:
        The argument, quoted.
    """
    var out = String('"')
    var bytes = argument.as_bytes()
    var n = len(bytes)
    var i = 0
    while i < n:
        var slashes = 0
        while i < n and Int(bytes[i]) == 0x5C:  # backslash
            slashes += 1
            i += 1
        if i == n:
            # Runs into the closing quote, so each one has to be doubled or
            # the quote is escaped instead of ending the argument.
            out += SEP * (slashes * 2)
            break
        if Int(bytes[i]) == 0x22:  # '"'
            out += SEP * (slashes * 2 + 1)
            out += '"'
        else:
            out += SEP * slashes
            out += String(argument[byte=i : i + 1])
        i += 1
    out += '"'
    return out^


def command_line(exe: String, args: List[String]) -> String:
    """An executable and its arguments as one line, each part quoted.

    Args:
        exe: The program.
        args: Its arguments, one element each.

    Returns:
        The command line for `pipes.spawn`.
    """
    var line = quoted(exe)
    for argument in args:
        line += " " + quoted(argument)
    return line^


def package_arguments(requirement: String, project: String) -> List[String]:
    """Arguments for installing one requirement, or a requirements file.

    The requirement stays one element all the way to `command_line`, which is
    what keeps `numpy==2.3.1 ; python_version < "3.13"` from being cut in half
    by a space.

    A relative `-r` path is resolved against the project, an absolute one is
    left alone -- and "absolute" is `is_absolute`, not `startswith("/")`,
    because the Mac's test would treat `E:\\req.txt` as relative and produce
    `E:\\proj\\E:\\req.txt`.

    Args:
        requirement: A pip requirement, or `-r <path>`.
        project: The project directory, for resolving a relative path.

    Returns:
        `["-m", "pip", "install", ...]`, or just the first three when the
        requirement is empty.
    """
    var args = List[String]()
    args.append(String("-m"))
    args.append(String("pip"))
    args.append(String("install"))
    var text = String(requirement.strip())
    if text.startswith("-r "):
        var path = String(String(text[byte=3:]).strip())
        if path != "" and not is_absolute(path) and project != "":
            path = _join(project, path)
        args.append(String("-r"))
        args.append(path^)
    elif text != "":
        args.append(text^)
    return args^


def project_dependency_arguments(project: String) raises -> List[String]:
    """Prefer an explicit requirements file; otherwise install the project.

    Args:
        project: The project directory.

    Returns:
        Arguments for `python -m pip`, or an empty list when the project
        declares no dependencies -- which the caller reports rather than
        treating as a failure.

    Raises:
        If the disk cannot be read.
    """
    var args = List[String]()
    if project == "":
        return args^
    if _exists(_join(project, "requirements.txt")):
        return package_arguments(String("-r requirements.txt"), project)
    if _exists(_join(project, "pyproject.toml")):
        args.append(String("-m"))
        args.append(String("pip"))
        args.append(String("install"))
        args.append(String("-e"))
        args.append(project)
    return args^


def create_environment_command(project: String) raises -> String:
    """The command line that builds or repairs this project's environment.

    `--upgrade` when one is already there, so an application or runtime update
    refreshes the links and the configuration without throwing away the
    packages a person installed.

    Handed out as a string so a caller can give it to `build.start` and watch
    it in the output pane, which is what the editor should do -- eight seconds
    is a long time to hold the message loop. `create_environment` is the same
    command run synchronously, for a check.

    Args:
        project: The project directory.

    Returns:
        A command line, or empty when there is no runtime or no project.

    Raises:
        If the disk cannot be read.
    """
    var python = runtime_python()
    var destination = environment_dir(project)
    if python == "" or destination == "":
        return String()
    var args = List[String]()
    args.append(String("-m"))
    args.append(String("venv"))
    if environment_ready(project):
        args.append(String("--upgrade"))
    args.append(destination^)
    return command_line(python, args)


def install_command(requirement: String, project: String) raises -> String:
    """The command line that installs into this project's environment.

    Always `<venv>\\Scripts\\python.exe -m pip`, never a bare `pip`. A
    `pip.exe` found on `PATH` belongs to whichever Python is first there,
    which on this platform is frequently the Store stub, and installing into
    the wrong environment succeeds silently.

    Args:
        requirement: A pip requirement, or `-r <path>`.
        project: The project directory.

    Returns:
        A command line, or empty when the environment is not ready or the
        requirement is empty.

    Raises:
        If the disk cannot be read.
    """
    if not environment_ready(project):
        return String()
    var args = package_arguments(requirement, project)
    if len(args) < 4:
        return String()
    return command_line(environment_python(project), args)


def project_dependency_command(project: String) raises -> String:
    """The command line that installs what the project declares.

    Args:
        project: The project directory.

    Returns:
        A command line, or empty when the environment is not ready or the
        project declares nothing.

    Raises:
        If the disk cannot be read.
    """
    if not environment_ready(project):
        return String()
    var args = project_dependency_arguments(project)
    if len(args) == 0:
        return String()
    return command_line(environment_python(project), args)


# ===----------------------------------------------------------------------===#
# Running one
# ===----------------------------------------------------------------------===#


def create_environment(
    project: String, timeout_ms: Int = 180000
) raises -> String:
    """Create or repair the environment, and wait for it.

    Through `pipes.spawn`, which is the only process-creation call in the
    editor; nothing here opens a second one.

    Synchronous, and that is the whole reason it is separate from
    `create_environment_command`: a check needs an answer, the editor needs
    its message loop. Three minutes by default because a first `-m venv`
    installs pip and takes eight seconds on a warm machine and considerably
    longer behind an antivirus scanner watching every file it writes.

    Args:
        project: The project directory.
        timeout_ms: How long to wait before giving up on it.

    Returns:
        A sentence saying what happened, with the interpreter's own output
        appended when it failed.

    Raises:
        If a Win32 entry point cannot be resolved.
    """
    if project == "":
        return String("open a project or save the current file first")
    if not runtime_available():
        return String("no Python runtime: set GRIDDLE_PYTHON_HOME")
    var destination = environment_dir(project)
    if destination == "":
        return String("could not place a Python environment for ") + project
    var command = create_environment_command(project)
    if command == "":
        return String("no command to create ") + destination
    if not _exists(project):
        return String("no such project directory: ") + project
    # The parent of the destination, not the destination: `-m venv` makes its
    # own directory and refuses nothing, but `CreateProcessW` fails outright
    # when `lpCurrentDirectory` does not exist, and the environments root has
    # never seen this project before. The project is used as the working
    # directory rather than either -- it is the one directory certain to
    # exist, and it is where a person would have run the command themselves.
    _ = _ensure_dir(dirname(destination))
    var result = _run(command, project, timeout_ms)
    if result[0] != 0:
        return (
            String("Python environment creation failed (")
            + String(result[0])
            + ")\n"
            + result[1]
        )
    if not environment_ready(project):
        return (
            String("creation reported success but ")
            + destination
            + " is not usable\n"
            + result[1]
        )
    return String("Python environment ready: ") + destination


def install_packages(
    requirement: String, project: String, timeout_ms: Int = 300000
) raises -> String:
    """Install into this project's environment, and wait for it.

    Args:
        requirement: A pip requirement, or `-r <path>`. Empty means whatever
            the project declares.
        project: The project directory.
        timeout_ms: How long to wait before giving up on pip.

    Returns:
        A sentence saying what happened, with pip's output when it failed.

    Raises:
        If a Win32 entry point cannot be resolved.
    """
    if not environment_ready(project):
        return String("create the project Python environment first")
    var command = (
        project_dependency_command(project)
        if String(requirement.strip()) == ""
        else install_command(requirement, project)
    )
    if command == "":
        return String("no requirements.txt or pyproject.toml in ") + project
    var restore = variables(project)
    _ = _apply(pip_variables(project))
    var result = _run(command, project, timeout_ms)
    # Back to the launch environment. The two PIP_ settings are pip's and have
    # no business reaching a compiler or a debuggee started afterwards.
    set_env(String("PIP_REQUIRE_VIRTUALENV"), String())
    set_env(String("PIP_DISABLE_PIP_VERSION_CHECK"), String())
    _ = _apply(restore^)
    if result[0] != 0:
        return (
            String("pip failed (") + String(result[0]) + ")\n" + result[1]
        )
    return String("Python packages installed")


def _run(
    command: String, working_dir: String, timeout_ms: Int
) raises -> Tuple[Int, String]:
    """Run a command to completion, collecting everything it says.

    The drain-then-check order is `ide/build.mojo`'s and matters for the same
    reason: a process's last words are already in the pipe when it exits, and
    checking the handle first throws away the error message.

    Args:
        command: The full command line.
        working_dir: Where to run it.
        timeout_ms: How long to wait.

    Returns:
        The exit code and the output. The code is -1 when it could not be
        started and -2 when the deadline passed.

    Raises:
        If a Win32 entry point cannot be resolved.
    """
    var child = spawn(command, working_dir, merge_stderr=True)
    if child.process == 0:
        return (-1, String("could not start: ") + command)

    var WaitForSingleObject = win32[
        def (Int, UInt32) thin abi("C") -> UInt32, "WaitForSingleObject"
    ]()
    var GetExitCodeProcess = win32[
        def (Int, Pointer[UInt32, MutAnyOrigin]) thin abi("C") -> c_int,
        "GetExitCodeProcess",
    ]()

    var out = String("")
    var buffer = alloc[UInt8](READ_CHUNK, alignment=8)
    var deadline = perf_counter_ns() + timeout_ms * 1_000_000
    var code = -2
    while True:
        var moved = False
        while True:
            var got = read_some(child.reads_from, Int(buffer), READ_CHUNK)
            if got <= 0:
                break
            for i in range(got):
                out += chr(Int(buffer[i]))
            moved = True
        if WaitForSingleObject(child.process, UInt32(0)) == UInt32(0):
            # Exited. One more pass over the pipe: anything written between
            # the read above and the exit is still sitting in it.
            while True:
                var last = read_some(child.reads_from, Int(buffer), READ_CHUNK)
                if last <= 0:
                    break
                for i in range(last):
                    out += chr(Int(buffer[i]))
            var raw = UInt32(0)
            _ = GetExitCodeProcess(child.process, com_addr(raw))
            code = Int(raw)
            break
        if perf_counter_ns() > deadline:
            out += String("\n[gave up after ") + String(timeout_ms) + " ms]\n"
            break
        if not moved:
            # Only when there was nothing to take. Sleeping after a read that
            # returned data would make a chatty child take a hundred times
            # longer than it needs to.
            sleep(0.01)
    buffer.free()

    var dying = child
    kill(dying)
    return (code, out^)


# ===----------------------------------------------------------------------===#
# The report
# ===----------------------------------------------------------------------===#


def python_report(project: String = String()) raises -> String:
    """Everything a launch would do about Python, as text.

    The first line is the count of variables a Run would inject, so a check
    can tell "nothing to inject" from "a full environment" without parsing
    anything -- and can assert the count, which is how a variable quietly
    going missing gets noticed.
    Then those variables, one per line and spelled exactly as they will be
    set, so a check can start Griddle, ask for this, and compare each line
    against what `GetEnvironmentVariable` says afterwards -- which is the only
    way to prove the injection actually happened, since
    `SetEnvironmentVariableW` is invisible to this process's own `getenv`.

    The state lines below them are what makes a zero readable: without them a
    person cannot tell a project with no environment from a machine with no
    runtime, and those want opposite actions.

    Args:
        project: The project directory, or empty to report the runtime alone.

    Returns:
        `python N`, a line per injected variable, then the runtime, project,
        key and environment.

    Raises:
        If the disk cannot be read.
    """
    var vars = variables(project)
    var out = String("python ") + String(vars.count()) + "\n"
    var i = 0
    while i < vars.count():
        out += "  " + vars.keys[i] + " = " + vars.items[i][].as_string() + "\n"
        i += 1

    var home = runtime_home()
    out += "runtime " + (home if home != "" else String("none")) + "\n"
    out += "version " + runtime_version() + "\n"
    var library = runtime_library()
    out += "library " + (library if library != "" else String("none")) + "\n"
    out += "root " + environments_root() + "\n"
    out += "project " + (project if project != "" else String("none")) + "\n"
    out += "key " + project_key(project) + "\n"

    var env = environment_dir(project)
    var state = String("absent")
    if env == "":
        state = String("unplaced")
    elif environment_ready(project):
        state = String("ready")
    elif _exists(env):
        state = String("incomplete")
    out += "venv " + env + " " + state + "\n"
    return out^


# ===----------------------------------------------------------------------===#
# The disk, at the smallest possible surface
# ===----------------------------------------------------------------------===#


def _exists(path: String) raises -> Bool:
    """Whether a path names something on disk.

    `GetFileAttributesW` reads the directory entry and opens nothing, so it
    answers for a file a build is holding open as readily as for one it is
    not. `ide/session.mojo` says the same at greater length.
    """
    if path == "":
        return False
    var GetFileAttributesW = win32[
        def (Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> UInt32,
        "GetFileAttributesW",
    ]()
    var wide_path = utf16z(path)
    var attributes = GetFileAttributesW(
        wide_path.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    )
    _ = wide_path
    return Int(attributes) != INVALID_FILE_ATTRIBUTES


def _ensure_dir(path: String) raises -> Bool:
    """Make a directory and everything above it, answering whether it is there.

    A loop over the parents rather than `SHCreateDirectoryExW`: that lives in
    shell32 and this needs nothing shell32 has, and `CreateDirectoryW` is
    already the call `ide/build.mojo` uses to stage the linker.

    The recursion terminates because `dirname` is strictly shorter every
    time and answers empty for a bare drive.
    """
    if path == "":
        return False
    if _exists(path):
        return True
    var parent = dirname(path)
    if parent != "" and parent != path and not _exists(parent):
        if not _ensure_dir(parent):
            return False
    var CreateDirectoryW = win32[
        def (Pointer[UInt16, MutAnyOrigin], Int) thin abi("C") -> c_int,
        "CreateDirectoryW",
    ]()
    var wide_path = utf16z(path)
    _ = CreateDirectoryW(
        wide_path.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](), 0
    )
    _ = wide_path
    # The return value is not the answer: it is false both for a race another
    # thread won and for a failure, and only the directory entry can tell
    # those apart.
    return _exists(path)
