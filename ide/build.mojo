"""Building and running the open file, with its output in the output pane.

Milestone 4. The editor can open, edit and save; this is the half that closes
the loop, and the target the design document names is `Griddle builds
Griddle`.

The transport is the one the language server already uses -- `ide/pipes.mojo`,
which is `CreateProcessW` with inherited pipe handles and a `PeekNamedPipe`
poll, because an anonymous pipe cannot be made non-blocking and a read that
blocks is a frozen editor. Nothing new is needed for a compiler that a
language server did not need first.

The output is kept as lines rather than as one string. The pane draws the last
screenful and a person scrolls; keeping a 40 MB build log as a single String
and slicing it per frame is the shape that makes a build log the slowest part
of a build.
"""

from std.ffi import c_int
from std.memory import Pointer, alloc
from std.sys._globals import named_global
from std.time import perf_counter_ns

from ide.pipes import Child, kill, read_some, set_env, spawn, utf16z, waiting
from ide.win32 import absolute, env_or, win32

# The child, its output, and what it was asked to do. Globals for the same
# reason the language server's state is global: the window procedure is
# captureless and has one pointer to work with.
comptime g_child = named_global["build.child", Child]
comptime g_lines = named_global["build.lines", List[String]]
comptime g_partial = named_global["build.partial", String]
comptime g_running = named_global["build.running", Int]
comptime g_started = named_global["build.started", Int]
comptime g_what = named_global["build.what", String]
comptime g_serial = named_global["build.serial", Int]

# How much of a build log to keep. Ten thousand lines is more than anyone
# reads and a great deal less than a runaway program can print in a second.
comptime MAX_LINES = 10000
comptime READ_CHUNK = 65536


def is_building() -> Bool:
    """Whether a build or run is in flight.

    Returns:
        True while a child process is alive.
    """
    return g_running()[] != 0


def output_count() -> Int:
    """How many output lines are held.

    Returns:
        The count.
    """
    return len(g_lines()[])


def output_line(i: Int) -> String:
    """One output line.

    Args:
        i: Its index.

    Returns:
        The line, or empty when out of range.
    """
    var lines = g_lines()
    if i < 0 or i >= len(lines[]):
        return String("")
    return lines[][i]


def output_serial() -> Int:
    """Bumped whenever the output changes, so a waiter can tell.

    Returns:
        The serial.
    """
    return g_serial()[]


def what_ran() -> String:
    """The command line of the build or run in flight, or the last one.

    Returns:
        The command.
    """
    return g_what()[]


def clear_output():
    """Empty the pane, so one build's output is not read as the next one's."""
    g_lines()[] = List[String]()
    g_partial()[] = String("")
    g_serial()[] += 1


def append_output(var text: String):
    """Put text into the output pane, splitting it into lines.

    Public because a build is not the only thing with something to say. The
    project search writes its results here rather than growing a pane of its
    own: a result is `path:line:col: text`, which is exactly the shape the
    pane's click handler already parses and jumps to, so search results are
    clickable without one line of new interface.

    Args:
        text: What to add. Need not end at a line boundary.
    """
    _append(text^)


def _append(var text: String):
    """Split what arrived on newlines and keep the tail for next time.

    A pipe read ends wherever the buffer filled, which is usually mid-line.
    Appending the fragment as a line puts a break through the middle of a
    diagnostic and makes it unparseable, so the tail is held until its
    newline arrives.
    """
    var lines = g_lines()
    var pending = g_partial()[] + text
    var start = 0
    var bytes = pending.as_bytes()
    for i in range(len(bytes)):
        if Int(bytes[i]) == 10:
            var one = String(pending[byte=start:i])
            # Trailing carriage return: the compiler writes CRLF and the pane
            # would otherwise draw a box for it.
            if one.byte_length() > 0 and one.as_bytes()[
                one.byte_length() - 1
            ] == 13:
                var trimmed = String(one[byte=0 : one.byte_length() - 1])
                one = trimmed^
            lines[].append(one^)
            start = i + 1
    g_partial()[] = String(pending[byte=start:])
    # Drop the oldest rather than refusing the newest: the end of a build log
    # is the part that says what went wrong.
    while len(lines[]) > MAX_LINES:
        _ = lines[].pop(0)
    g_serial()[] += 1


def ensure_linker() raises -> String:
    """Put the toolchain Griddle trusts at the front of the child's PATH.

    The compiler shells out to a program called `link`, and on a machine with
    MSYS or Git for Windows installed that name resolves to coreutils' own
    /usr/bin/link -- which is a hard-link utility and answers "unknown option
    -- X". Every build started from inside the editor then fails with a
    message about a flag, which is a long way from the truth.

    IDE-DESIGN.md called this out before the editor could build anything: the
    toolchain lookup must pin the real linker rather than trust PATH. So lld
    is staged under the name the compiler will ask for, in a directory of our
    own, and that directory goes first. tools/build-ide.ps1 does exactly this
    for the builds a person runs by hand; this is the same trick for the
    builds Griddle runs itself.

    Returns:
        What happened, for the output pane.

    Raises:
        Never in practice; failures are reported rather than raised.
    """
    var staged = String(env_or("TEMP", ".")) + "\\griddle-linkbin"
    var CreateDirectoryW = win32[
        def (Pointer[UInt16, MutAnyOrigin], Int) thin abi("C") -> c_int,
        "CreateDirectoryW",
    ]()
    var CopyFileW = win32[
        def (
            Pointer[UInt16, MutAnyOrigin],
            Pointer[UInt16, MutAnyOrigin],
            c_int,
        ) thin abi("C") -> c_int,
        "CopyFileW",
    ]()
    var folder = utf16z(staged)
    _ = CreateDirectoryW(
        folder.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](), 0
    )
    _ = folder

    var lld = absolute(
        "bazel-bin/external/+llvm_configure+llvm-project/lld/lld.exe"
    )
    var target = staged + "\\link.exe"
    var from_path = utf16z(lld)
    var to_path = utf16z(target)
    # bFailIfExists false: a copy already there is the same binary, and
    # refusing to overwrite it would make this fail on the second run.
    _ = CopyFileW(
        from_path.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        to_path.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        c_int(0),
    )
    _ = from_path
    _ = to_path

    # And the runtime the toolchain's own DLLs need. MojoLLDB.dll is a
    # hundred megabytes that imports KGENCompilerRTShared, AsyncRTRuntimeGlobals
    # and MSupportGlobals; if Windows cannot find those, LoadLibrary fails and
    # lldb-dap reports "this file does not represent a loadable dylib" -- which
    # names the plugin and says nothing about the dependency that was actually
    # missing. The debugger then runs without the Mojo language plugin and
    # every frame has no variables in it, which looks like a broken debugger.
    # tools/check-debugger.ps1 has staged these since sprint 0.0; this is the
    # same list, for the children Griddle spawns itself.
    var runtime = List[String]()
    runtime.append(absolute("bazel-bin/KGEN"))
    runtime.append(absolute("bazel-bin/AsyncRT"))
    runtime.append(absolute("bazel-bin/Support"))
    runtime.append(
        absolute("bazel-bin/external/+llvm_configure+llvm-project/lldb")
    )

    # Each directory is checked for on its own. Using the linker's directory
    # as a sentinel for "already staged" was wrong in the one case that
    # mattered: a shell that had staged the linker by hand -- which every
    # build script here does -- looked already-done, so the runtime
    # directories were never added and the debugger came up with no plugin.
    var path = String(env_or("PATH", ""))
    var prefix = String("")
    if path.find(staged) < 0:
        prefix = staged
    for folder in runtime:
        if path.find(folder) < 0:
            prefix += (";" if prefix.byte_length() > 0 else "") + folder
    if prefix.byte_length() > 0:
        set_env(String("PATH"), prefix + ";" + path)
    return String("toolchain staged: ") + target


def start(command: String, working_dir: String = String("")) raises -> String:
    """Run a command, collecting its output into the pane.

    Args:
        command: The full command line.
        working_dir: Where to run it, or empty for the current directory.

    Returns:
        What was started, or why it was not.

    Raises:
        If the process cannot be created.
    """
    if is_building():
        return String("something is already running; stop it first")
    # Before anything is spawned, because the child inherits our PATH and the
    # compiler it runs will ask for `link`.
    try:
        _ = ensure_linker()
    except:
        pass
    clear_output()
    g_what()[] = command
    _append(String("> ") + command + "\n")
    # Both streams: a compiler's diagnostics are on stderr and they are
    # the reason anybody is watching this pane.
    var child = spawn(command, working_dir, merge_stderr=True)
    if child.process == 0:
        _append(String("could not start it\n"))
        return String("could not start: ") + command
    g_child()[] = child
    g_running()[] = 1
    g_started()[] = perf_counter_ns()
    return String("started: ") + command


def poll() raises -> Bool:
    """Take whatever the child has written, and notice when it finishes.

    Called from the window's timer, so a build's output appears as it is
    produced rather than in one lump at the end.

    Returns:
        True if anything changed.

    Raises:
        If a pipe read fails.
    """
    if not is_building():
        return False
    var child = g_child()[]
    var changed = False

    # Everything available, not one chunk: a compiler emitting a thousand
    # lines of diagnostics should not take a thousand timer ticks to show
    # them.
    var buffer = alloc[UInt8](READ_CHUNK, alignment=8)
    while True:
        var ready = waiting(child.reads_from)
        if ready <= 0:
            break
        var got = read_some(child.reads_from, Int(buffer), READ_CHUNK)
        if got <= 0:
            break
        var text = String("")
        for i in range(got):
            text += chr(Int(buffer[i]))
        _append(text^)
        changed = True
    buffer.free()

    # Alive? WaitForSingleObject with no timeout answers immediately.
    var WaitForSingleObject = win32[
        def (Int, UInt32) thin abi("C") -> UInt32, "WaitForSingleObject"
    ]()
    if WaitForSingleObject(child.process, UInt32(0)) == UInt32(0):
        # WAIT_OBJECT_0: it has exited. Its last words may still be in the
        # pipe, which is why the read above happens first.
        var GetExitCodeProcess = win32[
            def (
                Int, Pointer[UInt32, MutAnyOrigin]
            ) thin abi("C") -> c_int,
            "GetExitCodeProcess",
        ]()
        var code = UInt32(0)
        _ = GetExitCodeProcess(
            child.process, Pointer(to=code).unsafe_origin_cast[MutAnyOrigin]()
        )
        var took = (perf_counter_ns() - g_started()[]) // 1_000_000
        if g_partial()[].byte_length() > 0:
            _append(String("\n"))
        _append(
            String("\n[exit ") + String(Int(code)) + " after "
            + String(took) + " ms]\n"
        )
        var dying = g_child()[]
        kill(dying)
        g_running()[] = 0
        changed = True
    return changed


def stop() raises -> String:
    """End whatever is running.

    Returns:
        What happened.

    Raises:
        If the handles cannot be closed.
    """
    if not is_building():
        return String("nothing is running")
    var child = g_child()[]
    kill(child)
    g_running()[] = 0
    _append(String("\n[stopped]\n"))
    return String("stopped")



def locate(text: String) -> Tuple[String, Int, Int]:
    """The file, line and column a tool's diagnostic names, if it names one.

    Compilers say `path:line:col: error: ...` and have for forty years. The
    parse is from the left but skips the first two characters, because on
    Windows the path starts `E:` and a naive search for a colon finds the
    drive letter and reports a file called `E`.

    Args:
        text: One line of output.

    Returns:
        The path, the zero-based line and the zero-based column. The path is
        empty when the line does not name a place.
    """
    var bytes = text.as_bytes()
    var n = len(bytes)
    var i = 2
    while i < n:
        if Int(bytes[i]) != 0x3A:  # ':'
            i += 1
            continue
        # A colon, then digits, a colon, digits, and a colon. Anything else
        # is a colon in a message and not a location.
        var j = i + 1
        var line_start = j
        while j < n and Int(bytes[j]) >= 0x30 and Int(bytes[j]) <= 0x39:
            j += 1
        if j == line_start or j >= n or Int(bytes[j]) != 0x3A:
            i += 1
            continue
        var line_text = String(text[byte=line_start:j])
        var k = j + 1
        var col_start = k
        while k < n and Int(bytes[k]) >= 0x30 and Int(bytes[k]) <= 0x39:
            k += 1
        if k == col_start:
            i += 1
            continue
        var col_text = String(text[byte=col_start:k])
        try:
            # One-based on the wire, zero-based everywhere inside the editor.
            return (String(text[byte=0:i]), Int(line_text) - 1, Int(col_text) - 1)
        except:
            i += 1
            continue
    return (String(""), -1, -1)
