"""The debug adapter client: talking to lldb-dap over a pipe.

Griddle can run a program. This is the half that stops it. `lldb-dap.exe` is
built beside the compiler, `bazel-bin/KGEN/MojoLLDB.dll` teaches LLDB what a
Mojo value looks like, and `tools/dap-probe.py` proved the whole wire on this
machine -- a breakpoint binds, a stop arrives, and locals come back with
names, values and types. Not one line of `ide/` knew any of it existed.

This module is the client and nothing else. It holds the session and speaks
the protocol; it draws nothing and imports no window. That is not tidiness,
it is the only arrangement that compiles: `ide/window.mojo` will import this,
so this importing it back would be a cycle.

The transport is byte-identical to the language server's -- `Content-Length`,
CRLF CRLF, then that many bytes of JSON -- so `ide/lsp.mojo` is the model and
this is deliberately the same shape: globals for the child and the inbox, a
`poll_debug` drained from the window's timer, and a dispatch that matches
responses by their sequence number and events by name. It cannot *import*
lsp.mojo. Those globals belong to the language server, one process runs both
at once, and a shared inbox would hand the debugger's frames to the completion
list.

Only the envelope differs. A request is

    {"seq": N, "type": "request", "command": "...", "arguments": {...}}

and an answer is either a response carrying `request_seq`, `success` and
`body`, or an event carrying `event` and `body`. There is no `jsonrpc` member
and no `method`. The part that shapes this file is the second kind: events
answer nothing we asked. `stopped` is the important one -- the debuggee hit a
breakpoint while no request of ours was outstanding -- which is why the stack,
the scope and the variables are fetched from inside the dispatch the moment a
stop lands, rather than waiting for whoever asks next. By the time a person
sees the editor stop, the locals are already there.

Lines are the trap. DAP counts from one; `initialize` says `linesStartAt1`
and the probe proves the adapter honours it. Everything inside Griddle counts
from zero. Both conversions happen here, at the boundary: `+ 1` on the way out
in `set_breakpoints`, `- 1` on the way in for every line that comes back.
Getting this wrong puts every breakpoint one line off, and that does not read
as an off-by-one -- it reads as a debugger that does not work.
"""

from std.memory import OpaquePointer, alloc
from std.sys._globals import named_global
from std.time import perf_counter_ns, sleep

from ide.json import JSON, parse
from ide.pipes import Child, kill, read_some, spawn, waiting, write_all
from ide.pipeutf8 import sanitized, take_chunk


# ── Bounds ──────────────────────────────────────────────────────────────────
# The same guards the language server carries, for the same reason: a
# `Content-Length` that is not a length leaves an inbox that can never drain,
# and every later read is appended to it until a String asks the allocator for
# gigabytes. A stack trace or a variable list is kilobytes at worst.
comptime MAX_MESSAGE = 64 * 1024 * 1024
comptime MAX_INBOX = 96 * 1024 * 1024
comptime READ_CHUNK = 65536

# How much of the debuggee's output to keep. Chunks, not lines: the pane that
# shows this wants the text as the program wrote it, newlines included.
comptime MAX_LOG_CHUNKS = 4000

# How long the two waiting calls will wait. Only `set_breakpoints` waits at
# all -- see its docstring for why it must. Launching is slow because loading
# MojoLLDB.dll is slow (it is a hundred-odd megabytes of LLDB), so the launch
# deadline is the probe's; the reply to a breakpoint request, once the adapter
# is alive, comes back immediately and gets a short one.
comptime WAIT_LAUNCH_SECONDS = 60.0
comptime WAIT_REPLY_SECONDS = 15.0
comptime POLL_INTERVAL_SECONDS = 0.01

# Which outstanding request `_wait_for_slot` is watching.
comptime SLOT_BREAKPOINTS = 1
comptime SLOT_DISCONNECT = 2


# ── State ───────────────────────────────────────────────────────────────────
# The adapter process and the two pipe ends we hold, as one Child -- the shape
# `ide/build.mojo` uses, because unlike the language server there is nothing
# here that wants the handles apart.
comptime g_child = named_global["dap.child", Child]
comptime g_running = named_global["dap.running", Int]

# Set by the `initialized` EVENT, which is the adapter saying it will now
# accept configuration. Breakpoints sent before it are rejected, so this gate
# is not an optimisation.
comptime g_configurable = named_global["dap.configurable", Int]

comptime g_next_seq = named_global["dap.seq", Int]
comptime g_serial = named_global["dap.serial", Int]

# Bytes that arrived and do not yet make a whole message, and the trailing
# bytes of those that do not yet make a whole character. `g_pending` is a byte
# list rather than a String on purpose: a String holding half a codepoint is
# exactly what `ide/pipeutf8.mojo` exists to prevent.
comptime g_inbox = named_global["dap.inbox", String]
comptime g_pending = named_global["dap.pending", List[UInt8]]

# What the session was started with. `launch` is sent from the dispatch when
# the `initialize` response lands, so the arguments have to outlive the call
# that asked for them.
comptime g_program = named_global["dap.program", String]
comptime g_plugin = named_global["dap.plugin", String]

# Requests we are waiting on, by sequence number, one slot per command. A slot
# holding zero means nothing is outstanding for that command; the dispatch
# clears the slot as it consumes the answer, so a second response with the
# same shape cannot be mistaken for the first.
comptime g_seq_initialize = named_global["dap.seq.initialize", Int]
comptime g_seq_launch = named_global["dap.seq.launch", Int]
comptime g_seq_breakpoints = named_global["dap.seq.breakpoints", Int]
comptime g_seq_stack = named_global["dap.seq.stack", Int]
comptime g_seq_scopes = named_global["dap.seq.scopes", Int]
comptime g_seq_variables = named_global["dap.seq.variables", Int]
comptime g_seq_disconnect = named_global["dap.seq.disconnect", Int]

# How many breakpoints the adapter said it bound, from the last answer.
comptime g_bp_verified = named_global["dap.bp.verified", Int]

# Where the debuggee is stopped. The line is ZERO-based here and one-based on
# the wire; the conversion is in `_take_stack`. Minus one means "no line",
# which a frame without debug information really does report.
comptime g_stopped = named_global["dap.stopped", Int]
comptime g_reason = named_global["dap.reason", String]
comptime g_thread_id = named_global["dap.thread", Int]
comptime g_stop_source = named_global["dap.stop.source", String]
comptime g_stop_line = named_global["dap.stop.line", Int]

# The call stack, as flat parallel lists rather than a list of structs. They
# are read from a draw loop, which wants no allocation to look at one row --
# the same reasoning that shaped the language server's diagnostics.
comptime g_frame_id = named_global["dap.frame.id", List[Int]]
comptime g_frame_name = named_global["dap.frame.name", List[String]]
comptime g_frame_source = named_global["dap.frame.source", List[String]]
comptime g_frame_line = named_global["dap.frame.line", List[Int]]

# The variables of whichever frame was asked for last.
comptime g_var_name = named_global["dap.var.name", List[String]]
comptime g_var_value = named_global["dap.var.value", List[String]]
comptime g_var_type = named_global["dap.var.type", List[String]]

# Everything the debuggee printed, in the chunks the adapter delivered it in.
# Kept as a list and joined on demand: appending to one big String copies the
# whole log on every `output` event, and a program in a loop sends a great
# many of those.
comptime g_log = named_global["dap.log", List[String]]


# ── Reading the session ─────────────────────────────────────────────────────
def debugging() -> Bool:
    """Whether a debug session is alive.

    Returns:
        True between a successful `start_debug` and the adapter going away.
    """
    return g_running()[] != 0


def stopped() -> Bool:
    """Whether the debuggee is sitting at a stop.

    Returns:
        True after a `stopped` event and before the next resume or step.
    """
    return g_stopped()[] != 0


def stop_reason() -> String:
    """Why it stopped: `breakpoint`, `step`, `exception`, and so on.

    Returns:
        The adapter's word for it, or empty when nothing is stopped.
    """
    return g_reason()[]


def stop_source() -> String:
    """The file the debuggee stopped in.

    This is the top frame's source, not the selected frame's -- it answers
    "where did execution stop", which is a different question from "what am I
    looking at". A caller browsing the stack wants `frame_source`.

    Returns:
        A full path when the adapter gave one, otherwise the bare file name,
        otherwise empty.
    """
    return g_stop_source()[]


def stop_line() -> Int:
    """The line the debuggee stopped on, ZERO-based, as the editor counts.

    Returns:
        The line, or -1 when nothing is stopped or the frame has no line.
    """
    # Guarded on `stopped` rather than trusting the slot, because a process
    # global starts at zero and zero is a real line. Before the first session
    # the honest answer is "nowhere", and that is -1.
    return g_stop_line()[] if stopped() else -1


def frame_count() -> Int:
    """How many frames the current stack has.

    Returns:
        The count, zero when nothing is stopped.
    """
    return len(g_frame_id()[])


def frame_name(i: Int) -> String:
    """One frame's function name.

    Args:
        i: Its index, zero being the innermost frame.

    Returns:
        The name, or empty when out of range.
    """
    var names = g_frame_name()
    return names[][i] if i >= 0 and i < len(names[]) else String()


def frame_source(i: Int) -> String:
    """One frame's file.

    Args:
        i: Its index, zero being the innermost frame.

    Returns:
        A full path when the adapter gave one, otherwise the bare file name,
        otherwise empty -- frames in code with no debug information have no
        source at all, and that is not an error.
    """
    var sources = g_frame_source()
    return sources[][i] if i >= 0 and i < len(sources[]) else String()


def frame_line(i: Int) -> Int:
    """One frame's line, ZERO-based, as the editor counts.

    Args:
        i: Its index, zero being the innermost frame.

    Returns:
        The line, or -1 when out of range or the frame has no line.
    """
    var lines = g_frame_line()
    return lines[][i] if i >= 0 and i < len(lines[]) else -1


def variable_count() -> Int:
    """How many variables the last-fetched scope holds.

    Returns:
        The count, zero when nothing is stopped.
    """
    return len(g_var_name()[])


def variable_name(i: Int) -> String:
    """One variable's name.

    Args:
        i: Its index.

    Returns:
        The name, or empty when out of range.
    """
    var names = g_var_name()
    return names[][i] if i >= 0 and i < len(names[]) else String()


def variable_value(i: Int) -> String:
    """One variable's value, as the adapter rendered it.

    Args:
        i: Its index.

    Returns:
        The value, or empty when out of range.
    """
    var values = g_var_value()
    return values[][i] if i >= 0 and i < len(values[]) else String()


def variable_type(i: Int) -> String:
    """One variable's type.

    Args:
        i: Its index.

    Returns:
        The type, or empty when the adapter did not name one.
    """
    var types = g_var_type()
    return types[][i] if i >= 0 and i < len(types[]) else String()


def debug_serial() -> Int:
    """Bumped every time anything above changes, so a caller can wait on it.

    Returns:
        The serial.
    """
    return g_serial()[]


def debug_log() -> String:
    """Everything the debuggee has printed this session.

    The log outlives the debuggee on purpose. A program that ran to completion
    has just written the thing somebody wanted to read, and clearing it on
    `terminated` would wipe it at the exact moment it became interesting; it
    is cleared by the next `start_debug` instead.

    Returns:
        The output, joined in the order it arrived.
    """
    var out = String()
    var chunks = g_log()
    for i in range(len(chunks[])):
        out += chunks[][i]
    return out^


# ── Framing and sending ─────────────────────────────────────────────────────
def _framed(body: String) -> String:
    """One message on the wire: `Content-Length`, a blank line, then bytes.

    Args:
        body: The JSON text.

    Returns:
        The framed message.
    """
    # The length counts BYTES, not characters. A header saying 40 for a
    # 39-byte body leaves the adapter waiting forever for one more.
    var out = String("Content-Length: ")
    out += String(body.byte_length())
    out += "\r\n\r\n"
    out += body
    return out^


def _send(var message: JSON) -> Bool:
    """Write one message to the adapter.

    Args:
        message: The whole envelope.

    Returns:
        False when there is no adapter to write to.
    """
    var handle = g_child()[].writes_to
    if handle == 0:
        return False
    try:
        return write_all(handle, _framed(message.serialize()))
    except:
        return False


def _request(var command: String, var arguments: JSON) -> Int:
    """Send a request and return its sequence number.

    Args:
        command: The DAP command.
        arguments: Its arguments object.

    Returns:
        The sequence number, so a response can be matched to it.
    """
    g_next_seq()[] += 1
    var seq = g_next_seq()[]
    var msg = JSON.object()
    msg.set(String("seq"), JSON(seq))
    msg.set(String("type"), JSON(String("request")))
    msg.set(String("command"), JSON(command^))
    msg.set(String("arguments"), arguments^)
    _ = _send(msg^)
    return seq


def _request_bare(var command: String) -> Int:
    """Send a request that carries no arguments at all.

    `configurationDone` is the one that matters. The probe omits the
    `arguments` member rather than sending an empty object, and the probe is
    the sequence that is known to work on this machine, so this omits it too.

    Args:
        command: The DAP command.

    Returns:
        The sequence number.
    """
    g_next_seq()[] += 1
    var seq = g_next_seq()[]
    var msg = JSON.object()
    msg.set(String("seq"), JSON(seq))
    msg.set(String("type"), JSON(String("request")))
    msg.set(String("command"), JSON(command^))
    _ = _send(msg^)
    return seq


# ── Lifecycle ───────────────────────────────────────────────────────────────
def _quoted(path: String) -> String:
    """A path wrapped in double quotes, for a command line.

    Args:
        path: The path.

    Returns:
        The quoted path.
    """
    # `chr(0x22)` rather than an escaped literal, the way tree.mojo writes its
    # backslash: a quote inside a quoted string is the one character in this
    # file most likely to be mangled by whatever writes it.
    var quote = String(chr(0x22))
    return quote + path + quote


def start_debug(
    adapter: String, plugin: String, program: String
) raises -> String:
    """Spawn the debug adapter and begin a session on a program.

    Only `initialize` is sent here. Its response drives `launch`, and
    `launch` in turn produces the `initialized` event that opens the session
    to breakpoints -- the same chain the probe walks, driven from the dispatch
    so that nothing waits on a pipe while the editor is trying to draw.

    The adapter's stderr is deliberately NOT merged into its stdout. Merging
    them is right for a compiler, whose diagnostics are the point; here it
    would interleave LLDB's chatter with the framed JSON and destroy the
    stream.

    Args:
        adapter: Path to `lldb-dap.exe`.
        plugin: Path to `MojoLLDB.dll`, loaded through `initCommands`.
        program: The debuggee, built with debug information.

    Returns:
        What happened, for the status line.

    Raises:
        If the adapter process cannot be created.
    """
    if debugging():
        return String("a debug session is already running")

    _clear_stop()
    g_log()[] = List[String]()
    g_inbox()[] = String()
    g_pending()[] = List[UInt8]()
    g_configurable()[] = 0
    g_bp_verified()[] = 0
    _clear_pending_requests()

    var child = spawn(_quoted(adapter))
    if not child.running():
        return String("could not start the debug adapter: ") + adapter
    g_child()[] = child
    g_running()[] = 1
    g_program()[] = program
    g_plugin()[] = plugin

    var caps = JSON.object()
    caps.set(String("adapterID"), JSON(String("mojo")))
    # One-based lines on the wire. Every line that crosses this boundary is
    # converted, and the constant that says which way lives right here.
    caps.set(String("linesStartAt1"), JSON(True))
    g_seq_initialize()[] = _request(String("initialize"), caps^)
    g_serial()[] += 1
    return String("debugging ") + program


def _send_launch():
    """Ask the adapter to load the plugin and start the debuggee.

    Sent from the dispatch when the `initialize` response lands, because that
    is the order the adapter requires and the order the probe uses.
    """
    var args = JSON.object()
    args.set(String("program"), JSON(g_program()[]))
    # The plugin is loaded by an LLDB command rather than by a DAP member,
    # because there is no DAP member for it. Without this every Mojo value
    # renders as raw bytes, which looks like a debugger that works and lies.
    # The path goes in verbatim, exactly as the probe passes it: LLDB's
    # command parser reads Windows backslashes here without complaint, and
    # quoting it would be a change to a sequence that is known to work.
    var commands = JSON.array()
    commands.push(JSON(String("plugin load ") + g_plugin()[]))
    args.set(String("initCommands"), commands^)
    # False: the session should stop where a person put a breakpoint, not on
    # whatever the runtime does before main.
    args.set(String("stopOnEntry"), JSON(False))
    g_seq_launch()[] = _request(String("launch"), args^)


def stop_debug() raises -> String:
    """End the session and kill the debuggee with it.

    `disconnect` with `terminateDebuggee` is what stops the program; killing
    the adapter without it leaves the debuggee running as an orphan holding
    the file the editor is about to rebuild. So the request goes out and the
    adapter is given a bounded moment to act on it before the handles close.

    Returns:
        What happened.

    Raises:
        If the process handles cannot be closed.
    """
    if not debugging():
        return String("nothing is being debugged")

    var args = JSON.object()
    args.set(String("terminateDebuggee"), JSON(True))
    g_seq_disconnect()[] = _request(String("disconnect"), args^)
    _ = _wait_for_slot(SLOT_DISCONNECT, WAIT_REPLY_SECONDS)

    _end_session()
    return String("debugging stopped")


def _end_session():
    """Forget the session, keeping only what the debuggee printed.

    Called both by `stop_debug` and by the dispatch on `terminated`, `exited`
    or a pipe that broke, so a session ends the same way however it ends. The
    inbox goes with it: half a message left behind would be parsed as the
    front of the next session's first reply.
    """
    var child = g_child()[]
    if child.process != 0:
        try:
            kill(child)
        except:
            pass
    g_child()[] = Child()
    g_running()[] = 0
    g_configurable()[] = 0
    g_inbox()[] = String()
    g_pending()[] = List[UInt8]()
    _clear_pending_requests()
    _clear_stop()
    g_thread_id()[] = 0
    g_serial()[] += 1


def _clear_pending_requests():
    """Forget every outstanding sequence number.

    A slot left set across the end of a session would match a fresh request's
    number in the next one, and the dispatch would feed one session's stack
    frames to another's.
    """
    g_seq_initialize()[] = 0
    g_seq_launch()[] = 0
    g_seq_breakpoints()[] = 0
    g_seq_stack()[] = 0
    g_seq_scopes()[] = 0
    g_seq_variables()[] = 0
    g_seq_disconnect()[] = 0


def _clear_stop():
    """Drop everything that described where the debuggee was standing.

    The in-flight slots go with it, and that is not housekeeping. A stop
    starts a chain -- stack, then scope, then variables -- and a person who
    presses step the instant the editor stops leaves that chain halfway done.
    Left live, its answers arrive after the program has resumed and paint the
    previous stop's frames back over a running debuggee: a stack view that is
    confidently wrong, which is worse than an empty one. A stop that has been
    left behind gets no more answers.
    """
    g_stopped()[] = 0
    g_reason()[] = String()
    g_stop_source()[] = String()
    g_stop_line()[] = -1
    g_seq_stack()[] = 0
    g_seq_scopes()[] = 0
    g_seq_variables()[] = 0
    # Evaluate goes with them, and for the same reason: an answer about a
    # frame that has moved is a value from a moment that has passed, and
    # showing it beside a name in the current file would be a lie with a
    # number in it.
    g_seq_evaluate()[] = 0
    _clear_frames()
    _clear_variables()


def _clear_frames():
    """Empty the stack."""
    g_frame_id()[] = List[Int]()
    g_frame_name()[] = List[String]()
    g_frame_source()[] = List[String]()
    g_frame_line()[] = List[Int]()


def _clear_variables():
    """Empty the locals."""
    g_var_name()[] = List[String]()
    g_var_value()[] = List[String]()
    g_var_type()[] = List[String]()


# ── Configuration ───────────────────────────────────────────────────────────
def set_breakpoints(source: String, lines: List[Int]) raises -> Int:
    """Set every breakpoint for one file, replacing whatever was there.

    DAP has no "add one breakpoint": `setBreakpoints` is the complete set for
    that source, so a caller passes all of them each time and an empty list
    clears the file.

    This is the one call in the module that waits. Everything else is
    fire-and-forget because the answer arrives in the state; here the answer
    IS the return value, and a count returned before the adapter has spoken
    would be a number made up. So it drains the pipe in a bounded loop through
    the same dispatch `poll_debug` uses -- events that land meanwhile are
    handled normally rather than dropped -- and gives up rather than hanging.
    The wait matters least where it happens most: breakpoints are set while
    the session is being built, when there is nothing else to draw.

    Args:
        source: The file's path, as the compiler saw it.
        lines: ZERO-based lines, as the editor counts them. They are sent
            one-based, which is what `linesStartAt1` promised the adapter.

    Returns:
        How many came back verified, or -1 if the adapter never answered.

    Raises:
        If the pipe cannot be read.
    """
    if not debugging():
        return 0

    # Breakpoints before the `initialized` event are rejected outright, so
    # wait for the session to open rather than sending into a closed door.
    if not _wait_for_configurable(WAIT_LAUNCH_SECONDS):
        return -1

    var wanted = JSON.array()
    for i in range(len(lines)):
        var one = JSON.object()
        # Zero-based inside Griddle, one-based on the wire. This `+ 1` and the
        # `- 1` in `_take_stack` are the only two places the two conventions
        # touch, and they have to stay a matched pair.
        one.set(String("line"), JSON(lines[i] + 1))
        wanted.push(one^)

    var where = JSON.object()
    where.set(String("path"), JSON(source))
    var args = JSON.object()
    args.set(String("source"), where^)
    args.set(String("breakpoints"), wanted^)

    g_bp_verified()[] = 0
    g_seq_breakpoints()[] = _request(String("setBreakpoints"), args^)
    if not _wait_for_slot(SLOT_BREAKPOINTS, WAIT_REPLY_SECONDS):
        return -1
    return g_bp_verified()[]


def configuration_done() raises:
    """Tell the adapter the setup is complete and let the debuggee run.

    Nothing is returned and nothing is waited for. What comes next is a
    `stopped` event, unsolicited, whenever the program reaches a breakpoint --
    which may be in a microsecond or in a minute, and either way is
    `poll_debug`'s to notice.

    Raises:
        Never in practice; the signature matches the rest of the module.
    """
    if not debugging():
        return
    _ = _request_bare(String("configurationDone"))
    g_serial()[] += 1


# ── Execution control ───────────────────────────────────────────────────────
def _step(var command: String):
    """Send one execution-control request for the stopped thread.

    The stop state is cleared here rather than when the adapter's `continued`
    event arrives. A caret and a highlight left on the old line while the
    program runs claim the debuggee is somewhere it is not; the next `stopped`
    event fills the state back in, and until then "not stopped" is the truth.

    Args:
        command: `continue`, `next`, `stepIn` or `stepOut`.
    """
    if not debugging() or not stopped():
        return
    var args = JSON.object()
    args.set(String("threadId"), JSON(g_thread_id()[]))
    _ = _request(command^, args^)
    # The thread id survives: it is a property of the debuggee, not of the
    # stop, and the next step request needs it.
    var thread = g_thread_id()[]
    _clear_stop()
    g_thread_id()[] = thread
    g_serial()[] += 1


def resume() raises:
    """Let the debuggee run until the next breakpoint.

    Raises:
        Never in practice.
    """
    _step(String("continue"))


def step_over() raises:
    """Run one source line, over any call in it.

    Raises:
        Never in practice.
    """
    _step(String("next"))


def step_in() raises:
    """Run one source line, into any call in it.

    Raises:
        Never in practice.
    """
    _step(String("stepIn"))


def step_out() raises:
    """Run until this frame returns.

    Raises:
        Never in practice.
    """
    _step(String("stepOut"))


def select_frame(i: Int) raises:
    """Fetch the variables of one frame of the stack.

    Asynchronous, like everything but `set_breakpoints`: this sends `scopes`,
    the dispatch turns the answer into a `variables` request, and the locals
    appear a poll or two later. `stop_source` and `stop_line` are left alone
    on purpose -- they say where execution stopped, and browsing the stack
    does not move it.

    Args:
        i: Which frame, zero being the innermost.

    Raises:
        Never in practice.
    """
    if not debugging() or not stopped():
        return
    var ids = g_frame_id()
    if i < 0 or i >= len(ids[]):
        return
    _request_scopes(ids[][i])


def _request_scopes(frame_id: Int):
    """Ask what scopes a frame has, which is the only route to its variables.

    Args:
        frame_id: The adapter's id for the frame, from `stackTrace`.
    """
    var args = JSON.object()
    args.set(String("frameId"), JSON(frame_id))
    g_seq_scopes()[] = _request(String("scopes"), args^)


# ── Reading the pipe ────────────────────────────────────────────────────────
def poll_debug() raises -> Bool:
    """Drain the adapter's pipe, dispatch everything whole, and report change.

    Non-blocking, and called from the window's timer. Reading without blocking
    is `ide/pipes.waiting`, which asks `PeekNamedPipe` how many bytes are
    there: an anonymous pipe cannot be made non-blocking on Windows in any
    supported way, and a blocking read on the thread that pumps messages is an
    editor that freezes whenever the debuggee thinks.

    Returns:
        True if any state a caller can see changed.

    Raises:
        If a pipe read fails in a way `pipes` does not swallow.
    """
    if g_child()[].reads_from == 0:
        return False
    var before = g_serial()[]
    var broken = False

    while True:
        var handle = g_child()[].reads_from
        if handle == 0:
            break
        var ready: Int
        try:
            ready = waiting(handle)
        except:
            ready = -1
        if ready < 0:
            # PeekNamedPipe fails on a broken pipe, which is how an adapter
            # that exited reports itself.
            broken = True
            break
        if ready == 0:
            break
        # No need to zero this: `take_chunk` is given a length and never looks
        # past it, so there is nothing for a stray NUL to terminate.
        var buffer = alloc[UInt8](READ_CHUNK, alignment=8)
        var got: Int
        try:
            got = read_some(handle, Int(buffer), READ_CHUNK)
        except:
            got = -1
        if got <= 0:
            buffer.unsafe_free()
            if got < 0:
                broken = True
            break
        var accumulated = g_inbox()[]
        # Whole characters only. A 64 KB read boundary lands wherever it
        # lands, sometimes inside a multi-byte sequence, and the String that
        # results is not valid UTF-8 -- which nothing notices until something
        # iterates it and unwraps an empty Optional. The partial sequence is
        # early, not damaged, so it waits for the next read.
        accumulated += take_chunk(
            g_pending()[],
            OpaquePointer[MutUntrackedOrigin](unsafe_from_address=Int(buffer)),
            got,
        )
        g_inbox()[] = accumulated^
        buffer.unsafe_free()

    _drain_messages()

    # After the messages, not before: an adapter that exited has usually just
    # sent `terminated` and `exited`, and those are worth reading.
    if broken and debugging():
        _append_log(String("\n[the debug adapter closed the connection]\n"))
        _end_session()

    return g_serial()[] != before


def _drain_messages() raises:
    """Take every complete message out of the inbox and dispatch it.

    Raises:
        If the dispatch does.
    """
    while True:
        var accumulated = g_inbox()[]
        var header_end = accumulated.find("\r\n\r\n")
        if header_end < 0:
            return
        var header = String(accumulated[byte=0:header_end])
        var marker = header.find("Content-Length:")
        if marker < 0:
            # Not a frame we understand. Drop it rather than spin forever on
            # a header that will never grow into one.
            g_inbox()[] = String(
                accumulated[byte = header_end + 4 : accumulated.byte_length()]
            )
            continue
        var length = 0
        var i = marker + 15
        let bytes = header.as_bytes()
        while i < header.byte_length():
            var c = Int(bytes[i])
            if c >= 0x30 and c <= 0x39:
                length = length * 10 + (c - 0x30)
            elif length > 0:
                break
            i += 1
        var body_at = header_end + 4
        if length < 0 or length > MAX_MESSAGE:
            g_inbox()[] = String()
            _append_log(
                String("\n[dap: implausible Content-Length ")
                + String(length)
                + " -- resynchronising]\n"
            )
            return
        if accumulated.byte_length() < body_at + length:
            if accumulated.byte_length() > MAX_INBOX:
                g_inbox()[] = String()
                _append_log(
                    String("\n[dap: no whole message in ")
                    + String(MAX_INBOX)
                    + " bytes -- resynchronising]\n"
                )
            return  # the rest has not arrived
        var body = String(accumulated[byte = body_at : body_at + length])
        g_inbox()[] = String(
            accumulated[byte = body_at + length : accumulated.byte_length()]
        )
        _handle(parse(body))


# ── Dispatch ────────────────────────────────────────────────────────────────
def _handle(var msg: JSON) raises:
    """One message from the adapter.

    Args:
        msg: The parsed envelope.

    Raises:
        If a chained request cannot be sent.
    """
    var kind = msg.get("type")[].as_string()
    if kind == "event":
        _handle_event(msg)
    elif kind == "response":
        _handle_response(msg)
    # Anything else is a reverse request -- the adapter asking US for
    # something, `runInTerminal` being the one that exists. lldb-dap only
    # sends it when the launch configuration asks it to, and this one does
    # not, so ignoring it is correct rather than merely convenient.


def _handle_event(msg: JSON) raises:
    """An event: something happened that we did not ask about.

    Args:
        msg: The envelope.

    Raises:
        If a chained request cannot be sent.
    """
    var event = msg.get("event")[].as_string()
    let body = msg.get("body")[]

    if event == "initialized":
        # The adapter will now take configuration. Breakpoints sent earlier
        # were refused, which is why `set_breakpoints` waits for this.
        g_configurable()[] = 1
        g_serial()[] += 1
        return

    if event == "output":
        # Requirement of the pane above this: what the debuggee printed. The
        # category distinguishes `stdout` from the adapter's own `console`
        # noise, and both belong in the log -- a person watching a debug
        # session wants the whole transcript.
        _append_log(body.get("output")[].as_string())
        g_serial()[] += 1
        return

    if event == "stopped":
        g_stopped()[] = 1
        g_reason()[] = body.get("reason")[].as_string()
        var thread = body.get("threadId")[].as_int()
        if thread != 0:
            g_thread_id()[] = thread
        # The chain that makes a stop useful. Asking for the stack here, and
        # for the scope and the variables as each answer lands, means the
        # locals are on screen the moment the stop is -- rather than one
        # round trip later, after whoever draws the editor notices and asks.
        _request_stack()
        g_serial()[] += 1
        return

    if event == "continued":
        # Usually redundant: `_step` already cleared the stop when it sent the
        # request. It is not redundant when the debuggee resumes for a reason
        # of its own, and then this is the only notice we get.
        var thread = g_thread_id()[]
        _clear_stop()
        g_thread_id()[] = thread
        g_serial()[] += 1
        return

    if event == "terminated" or event == "exited":
        # The session is over however it got here. `exited` carries the
        # program's exit code, which is worth saying out loud: a debuggee that
        # ended before reaching a breakpoint otherwise leaves the pane blank.
        if event == "exited":
            _append_log(
                String("\n[exit ")
                + String(body.get("exitCode")[].as_int())
                + "]\n"
            )
        _end_session()
        return


def _handle_response(msg: JSON) raises:
    """A response: the answer to one of our requests, matched by its number.

    Args:
        msg: The envelope.

    Raises:
        If a chained request cannot be sent.
    """
    var command = msg.get("command")[].as_string()
    var seq = msg.get("request_seq")[].as_int()
    var ok = True
    if msg.has("success"):
        ok = msg.get("success")[].as_bool()

    if not ok:
        # A failed response carries no `body`, so it would fall through every
        # branch below and leave its slot set -- and then the NEXT response
        # with that shape would be taken for this one, and `set_breakpoints`
        # would wait out its whole deadline for an answer that had already
        # come. Clear the slot the failure answers, and say why.
        _append_log(
            String("\n[dap: ")
            + command
            + " failed: "
            + msg.get("message")[].as_string()
            + "]\n"
        )
        _clear_slot_for(seq)
        g_serial()[] += 1
        return

    let body = msg.get("body")[]

    if command == "initialize" and seq == g_seq_initialize()[]:
        g_seq_initialize()[] = 0
        # `launch` goes out only now. Sending it alongside `initialize`
        # races: the adapter has not yet said what it supports.
        _send_launch()
        return

    if command == "launch" and seq == g_seq_launch()[]:
        g_seq_launch()[] = 0
        # Nothing to do. The `initialized` event, not this, is what opens the
        # session to breakpoints, and it may already have arrived.
        return

    if command == "setBreakpoints" and seq == g_seq_breakpoints()[]:
        g_seq_breakpoints()[] = 0
        let list = body.get("breakpoints")[]
        var verified = 0
        for i in range(list.count()):
            if list.at(i)[].get("verified")[].as_bool():
                verified += 1
        g_bp_verified()[] = verified
        g_serial()[] += 1
        return

    if command == "stackTrace" and seq == g_seq_stack()[]:
        g_seq_stack()[] = 0
        _take_stack(body)
        return

    if command == "scopes" and seq == g_seq_scopes()[]:
        g_seq_scopes()[] = 0
        _take_scopes(body)
        return

    if command == "variables" and seq == g_seq_variables()[]:
        g_seq_variables()[] = 0
        _take_variables(body)
        return

    if command == "evaluate" and seq == g_seq_evaluate()[]:
        g_seq_evaluate()[] = 0
        _take_evaluate(body)
        return

    if command == "disconnect" and seq == g_seq_disconnect()[]:
        g_seq_disconnect()[] = 0
        return


def _clear_slot_for(seq: Int):
    """Forget the one outstanding request that this sequence number names.

    Args:
        seq: The `request_seq` of a response that failed.
    """
    if seq == 0:
        return
    if seq == g_seq_initialize()[]:
        g_seq_initialize()[] = 0
    elif seq == g_seq_launch()[]:
        g_seq_launch()[] = 0
    elif seq == g_seq_breakpoints()[]:
        g_seq_breakpoints()[] = 0
    elif seq == g_seq_stack()[]:
        g_seq_stack()[] = 0
    elif seq == g_seq_scopes()[]:
        g_seq_scopes()[] = 0
    elif seq == g_seq_variables()[]:
        g_seq_variables()[] = 0
    elif seq == g_seq_disconnect()[]:
        g_seq_disconnect()[] = 0


def _request_stack():
    """Ask for the stopped thread's call stack.

    Sent with nothing but the thread id, as the probe sends it: the adapter
    then answers with every frame, which is what a stack view wants and what
    the probe was proven against.
    """
    var args = JSON.object()
    args.set(String("threadId"), JSON(g_thread_id()[]))
    g_seq_stack()[] = _request(String("stackTrace"), args^)


def _take_stack(body: JSON):
    """Turn a `stackTrace` body into the frame lists, then ask for locals.

    Args:
        body: The response body.
    """
    _clear_frames()
    let frames = body.get("stackFrames")[]
    for i in range(frames.count()):
        let one = frames.at(i)[]
        g_frame_id()[].append(one.get("id")[].as_int())
        g_frame_name()[].append(one.get("name")[].as_string())

        # A frame in code with no debug information has no `source` at all,
        # and that is ordinary rather than an error -- the runtime's frames
        # look like this. The full path is preferred over the bare name
        # because the editor has to open the file, and a name is not enough
        # to find it.
        let source = one.get("source")[]
        var path = source.get("path")[].as_string()
        if path == "":
            path = source.get("name")[].as_string()
        g_frame_source()[].append(path)

        # One-based on the wire, zero-based in the editor. A frame with no
        # line reports zero, which lands on -1 and means exactly that.
        g_frame_line()[].append(one.get("line")[].as_int() - 1)

    if len(g_frame_id()[]) > 0:
        g_stop_source()[] = g_frame_source()[][0]
        g_stop_line()[] = g_frame_line()[][0]
        _request_scopes(g_frame_id()[][0])
    g_serial()[] += 1


def _take_scopes(body: JSON):
    """Turn a `scopes` body into the `variables` request that follows it.

    Args:
        body: The response body.
    """
    let scopes = body.get("scopes")[]
    if scopes.count() == 0:
        _clear_variables()
        g_serial()[] += 1
        return
    # The first scope, which for lldb-dap is the locals -- the probe reads it
    # and it is the one a person means by "the variables". Globals and
    # registers are the later ones and are a view of their own.
    var reference = scopes.at(0)[].get("variablesReference")[].as_int()
    var args = JSON.object()
    args.set(String("variablesReference"), JSON(reference))
    g_seq_variables()[] = _request(String("variables"), args^)


def _take_variables(body: JSON):
    """Turn a `variables` body into the three parallel lists.

    Args:
        body: The response body.
    """
    _clear_variables()
    let list = body.get("variables")[]
    for i in range(list.count()):
        let one = list.at(i)[]
        g_var_name()[].append(one.get("name")[].as_string())
        # Sanitised, and this is not paranoia. A value is whatever bytes were
        # at that address rendered as text, and an uninitialised local is
        # arbitrary bytes; drawn as-is it killed the locals view outright,
        # because the grapheme iterator unwraps an empty Optional on a byte
        # that decodes to nothing. Unlike a split read there is no later read
        # that completes these, so replacement is the right answer here and
        # the wrong one in `take_chunk`.
        g_var_value()[].append(sanitized(one.get("value")[].as_string()))
        g_var_type()[].append(sanitized(one.get("type")[].as_string()))
    g_serial()[] += 1


# ── The log ─────────────────────────────────────────────────────────────────
def _append_log(var text: String):
    """Add a chunk to the debuggee's transcript.

    Args:
        text: What arrived. Need not end at a line boundary.
    """
    if text.byte_length() == 0:
        return
    g_log()[].append(sanitized(text))
    # Drop the oldest rather than refuse the newest: a program in a loop can
    # outrun any pane, and the end of the transcript is the part that says
    # what it was doing when it stopped.
    while len(g_log()[]) > MAX_LOG_CHUNKS:
        _ = g_log()[].pop(0)


# ── The one bounded wait ────────────────────────────────────────────────────
def _wait_for_configurable(seconds: Float64) raises -> Bool:
    """Pump until the adapter accepts configuration, or give up.

    Args:
        seconds: How long to wait at most.

    Returns:
        True if the `initialized` event arrived in time.

    Raises:
        If a pipe read fails.
    """
    var deadline = perf_counter_ns() + Int(seconds * 1_000_000_000.0)
    while g_configurable()[] == 0:
        if not debugging():
            return False
        if perf_counter_ns() > deadline:
            return False
        _ = poll_debug()
        sleep(POLL_INTERVAL_SECONDS)
    return True


def _slot_pending(which: Int) -> Int:
    """The sequence number still outstanding in one slot, or zero.

    A small integer selector rather than a pointer to the global: the globals
    are comptime aliases for a parameterised function, and passing one as a
    value is a lot of machinery to save two lines.

    Args:
        which: `SLOT_BREAKPOINTS` or `SLOT_DISCONNECT`.

    Returns:
        The outstanding sequence number, zero when the answer has landed.
    """
    if which == SLOT_BREAKPOINTS:
        return g_seq_breakpoints()[]
    return g_seq_disconnect()[]


def _wait_for_slot(which: Int, seconds: Float64) raises -> Bool:
    """Pump until an outstanding request's slot is cleared, or give up.

    The dispatch zeroes a slot as it consumes that request's answer, so the
    slot going back to zero is exactly "the adapter replied" -- including the
    case where it replied with a failure, which is an answer too.

    Args:
        which: Which slot to watch.
        seconds: How long to wait at most.

    Returns:
        True if the answer arrived in time.

    Raises:
        If a pipe read fails.
    """
    var deadline = perf_counter_ns() + Int(seconds * 1_000_000_000.0)
    while _slot_pending(which) != 0:
        if not debugging():
            return False
        if perf_counter_ns() > deadline:
            return False
        _ = poll_debug()
        sleep(POLL_INTERVAL_SECONDS)
    return True


# ===----------------------------------------------------------------------===#
# Evaluating an expression in a stopped frame
#
# The one request that answers a question a person asked rather than one the
# editor asked on their behalf, so unlike everything else here it has a value
# a caller waits for. It waits the way `set_breakpoints` does: through the
# same drain and dispatch `poll_debug` uses, so events arriving meanwhile are
# handled rather than dropped, and with a deadline so a wedged adapter cannot
# take the editor with it.
# ===----------------------------------------------------------------------===#

comptime g_seq_evaluate = named_global["dap.seq.evaluate", Int]
comptime g_evaluated = named_global["dap.evaluated", String]
comptime g_evaluated_type = named_global["dap.evaluated.type", String]


def evaluate(expression: String, frame: Int = 0) raises -> String:
    """Ask the debugger what an expression is worth, in a stopped frame.

    Args:
        expression: What to evaluate, as a person would type it.
        frame: Which frame to evaluate it in, zero being the innermost.

    Returns:
        The value, or an empty string when there is no answer. A failing
        expression is not an error here: asking about a name that is not in
        scope is a perfectly ordinary thing to do with a mouse.

    Raises:
        If a pipe read fails in a way `pipes` does not swallow.
    """
    g_evaluated()[] = String("")
    g_evaluated_type()[] = String("")
    if not debugging() or not stopped():
        return String("")
    if expression.byte_length() == 0:
        return String("")

    var args = JSON.object()
    args.set(String("expression"), JSON(expression))
    # The context tells the adapter what the answer is for. "hover" asks it to
    # be side-effect free, which matters: an editor that runs a function every
    # time a pointer crosses its name is an editor that changes the program it
    # is showing you.
    args.set(String("context"), JSON(String("hover")))
    var ids = g_frame_id()
    if frame >= 0 and frame < len(ids[]):
        args.set(String("frameId"), JSON(ids[][frame]))
    g_seq_evaluate()[] = _request(String("evaluate"), args^)

    var deadline = perf_counter_ns() + 5_000_000_000
    while perf_counter_ns() < deadline and g_seq_evaluate()[] != 0:
        _ = poll_debug()
    if g_seq_evaluate()[] != 0:
        # Gave up. Leaving the slot set would make the next evaluation's
        # answer match this one's request.
        g_seq_evaluate()[] = 0
        return String("")
    return g_evaluated()[]


def evaluated_type() -> String:
    """The type of the last thing evaluated, if the adapter said.

    Returns:
        The type name, or empty.
    """
    return g_evaluated_type()[]


def _take_evaluate(body: JSON):
    """Keep an `evaluate` answer.

    Args:
        body: The response body.
    """
    g_evaluated()[] = sanitized(body.get("result")[].as_string())
    g_evaluated_type()[] = sanitized(body.get("type")[].as_string())
