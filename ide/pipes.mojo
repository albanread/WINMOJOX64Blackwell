"""A child process on the other end of two pipes.

The Windows half of what MojoCocoa's `ide/lsp.mojo` gets from NSTask and
NSPipe. Everything above this file -- the JSON-RPC framing, the message
dispatch, the diagnostics -- is theirs and is shared; this is the five calls
underneath that cannot be.

The shape is the same on both platforms and so are its two hazards.

**Reads must not block.** A blocking read on the thread that pumps messages is
an editor that stops responding whenever the server thinks. The Mac port uses
`poll` with a zero timeout, and writes down at length why it does not use
`fcntl(O_NONBLOCK)` -- `fcntl` is variadic, and on arm64 a variadic argument
goes on the stack rather than in a register, so a fixed-signature call sets no
flag at all and nothing looks wrong. Windows has the same trap in a different
shape: an anonymous pipe cannot be made non-blocking in any supported way
(`SetNamedPipeHandleState` with `PIPE_NOWAIT` is documented as "should not be
used"), so the answer here is `PeekNamedPipe` -- ask how many bytes are
waiting, and only read that many.

**Handles must not leak into the child.** A pipe end the child inherits when
it should not is a pipe that never reports end-of-file, because the child
holds the last writer open. Both pipes are created inheritable and then the
end we keep is made non-inheritable before the process is created, which is
the documented order and the only order that works.
"""

from std.ffi import c_int
from std.memory import OpaquePointer, Pointer
from std.sys.info import size_of
from std.sys._com import com_addr
from std.sys._winkb import winkb_constant, winkb_field_offset, winkb_struct_size

from ide.win32 import win32


@fieldwise_init
struct SECURITY_ATTRIBUTES(Defaultable, ImplicitlyCopyable, Movable):
    """Whether a handle may be inherited, and by whom."""

    var nLength: UInt32
    var _pad: UInt32
    var lpSecurityDescriptor: Int
    var bInheritHandle: Int32
    var _pad2: Int32

    def __init__(out self):
        """Default security, not inheritable."""
        self.nLength = 0
        self._pad = 0
        self.lpSecurityDescriptor = 0
        self.bInheritHandle = 0
        self._pad2 = 0


@fieldwise_init
struct STARTUPINFOW(Defaultable, ImplicitlyCopyable, Movable):
    """How a new process starts, including which handles are its standard ones."""

    var cb: UInt32
    var _pad: UInt32
    var lpReserved: Int
    var lpDesktop: Int
    var lpTitle: Int
    var dwX: UInt32
    var dwY: UInt32
    var dwXSize: UInt32
    var dwYSize: UInt32
    var dwXCountChars: UInt32
    var dwYCountChars: UInt32
    var dwFillAttribute: UInt32
    var dwFlags: UInt32
    var wShowWindow: UInt16
    var cbReserved2: UInt16
    var _pad2: UInt32
    var lpReserved2: Int
    var hStdInput: Int
    var hStdOutput: Int
    var hStdError: Int

    def __init__(out self):
        """All zero but the size, which the caller sets."""
        self.cb = 0
        self._pad = 0
        self.lpReserved = 0
        self.lpDesktop = 0
        self.lpTitle = 0
        self.dwX = 0
        self.dwY = 0
        self.dwXSize = 0
        self.dwYSize = 0
        self.dwXCountChars = 0
        self.dwYCountChars = 0
        self.dwFillAttribute = 0
        self.dwFlags = 0
        self.wShowWindow = 0
        self.cbReserved2 = 0
        self._pad2 = 0
        self.lpReserved2 = 0
        self.hStdInput = 0
        self.hStdOutput = 0
        self.hStdError = 0


@fieldwise_init
struct PROCESS_INFORMATION(Defaultable, ImplicitlyCopyable, Movable):
    """What CreateProcess gives back."""

    var hProcess: Int
    var hThread: Int
    var dwProcessId: UInt32
    var dwThreadId: UInt32

    def __init__(out self):
        """Nothing started."""
        self.hProcess = 0
        self.hThread = 0
        self.dwProcessId = 0
        self.dwThreadId = 0


@fieldwise_init
struct Child(Defaultable, ImplicitlyCopyable, Movable):
    """A running child, and the two ends of the conversation we hold."""

    var process: Int
    var thread: Int
    # Our end of the child's stdin, and our end of its stdout.
    var writes_to: Int
    var reads_from: Int
    # The Job Object the child tree lives in. Killing the job kills every
    # process the child started, however many generations down; closing the
    # handle does the same, because the job is created kill-on-close. Zero
    # when job creation failed, in which case kill falls back to terminating
    # the one process it knows about.
    var job: Int

    def __init__(out self):
        """Nothing running."""
        self.process = 0
        self.thread = 0
        self.writes_to = 0
        self.reads_from = 0
        self.job = 0

    def running(self) -> Bool:
        """Whether there is a process here at all."""
        return self.process != 0


def utf16z(text: String) -> List[UInt16]:
    """A NUL-terminated UTF-16 copy, surrogate pairs and all."""
    var out = List[UInt16]()
    for ch in text.codepoints():
        var v = Int(ch)
        if v >= 0x10000:
            var u = v - 0x10000
            out.append(UInt16(0xD800 + (u >> 10)))
            out.append(UInt16(0xDC00 + (u & 0x3FF)))
        else:
            out.append(UInt16(v))
    out.append(0)
    return out^


def set_env(name: String, value: String) raises:
    """Set a variable in this process, for a child to inherit.

    Building an environment block to pass to CreateProcess would mean copying
    the whole of this process's environment and appending to it; setting the
    variable here and letting the child inherit is the same result in one
    call. It does change this process's environment, which is fine: the only
    variables set this way are ones the child needs and this process does not
    read.
    """
    var SetEnvironmentVariableW = win32[
        def (
            Pointer[UInt16, MutAnyOrigin], Pointer[UInt16, MutAnyOrigin]
        ) thin abi("C") -> c_int,
        "SetEnvironmentVariableW",
    ]()
    var n = utf16z(name)
    var v = utf16z(value)
    _ = SetEnvironmentVariableW(
        n.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        v.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
    )
    _ = n
    _ = v


def spawn(
    command: String,
    working_dir: String = String(""),
    merge_stderr: Bool = False,
) raises -> Child:
    """Start a process with its stdin and stdout on pipes.

    Args:
        command: The full command line, executable first.
        working_dir: Where to start it, or empty for this process's directory.

    Returns:
        The child, or an empty one if it could not be started.

    Raises:
        If a Win32 entry point cannot be resolved.
    """
    comptime assert (
        size_of[STARTUPINFOW]() == winkb_struct_size["STARTUPINFOW"]()
    ), "STARTUPINFOW does not match Windows"
    comptime assert (
        size_of[PROCESS_INFORMATION]()
        == winkb_struct_size["PROCESS_INFORMATION"]()
    ), "PROCESS_INFORMATION does not match Windows"
    comptime assert (
        size_of[SECURITY_ATTRIBUTES]()
        == winkb_struct_size["SECURITY_ATTRIBUTES"]()
    ), "SECURITY_ATTRIBUTES does not match Windows"

    var CreatePipe = win32[
        def (
            Pointer[Int, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
            Pointer[SECURITY_ATTRIBUTES, MutAnyOrigin],
            UInt32,
        ) thin abi("C") -> c_int,
        "CreatePipe",
    ]()
    var SetHandleInformation = win32[
        def (Int, UInt32, UInt32) thin abi("C") -> c_int,
        "SetHandleInformation",
    ]()
    var CreateProcessW = win32[
        def (
            Int,
            Pointer[UInt16, MutAnyOrigin],
            Int,
            Int,
            c_int,
            UInt32,
            Int,
            Int,
            Pointer[STARTUPINFOW, MutAnyOrigin],
            Pointer[PROCESS_INFORMATION, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "CreateProcessW",
    ]()

    var sa = SECURITY_ATTRIBUTES()
    sa.nLength = UInt32(size_of[SECURITY_ATTRIBUTES]())
    sa.bInheritHandle = 1

    # Two pipes: one the child reads its input from, one it writes output to.
    var child_stdin_read = Int(0)
    var our_write = Int(0)
    if CreatePipe(
        com_addr(child_stdin_read), com_addr(our_write), com_addr(sa), UInt32(0)
    ) == 0:
        return Child()
    var our_read = Int(0)
    var child_stdout_write = Int(0)
    if CreatePipe(
        com_addr(our_read), com_addr(child_stdout_write), com_addr(sa),
        UInt32(0),
    ) == 0:
        return Child()

    # The ends we keep must not be inherited, and this must happen before the
    # process is created. A write end the child also holds means the child
    # never sees end-of-file on its input; a read end it holds means we never
    # see end-of-file when it exits.
    var inherit = UInt32(winkb_constant["HANDLE_FLAG_INHERIT"]())
    _ = SetHandleInformation(our_write, inherit, UInt32(0))
    _ = SetHandleInformation(our_read, inherit, UInt32(0))

    var si = STARTUPINFOW()
    si.cb = UInt32(size_of[STARTUPINFOW]())
    si.dwFlags = UInt32(winkb_constant["STARTF_USESTDHANDLES"]())
    si.hStdInput = child_stdin_read
    si.hStdOutput = child_stdout_write
    if merge_stderr:
        # Both streams down the one pipe, interleaved the way the child wrote
        # them. A compiler puts its diagnostics on stderr and its progress on
        # stdout, and an editor that captures only stdout captures the half
        # nobody needs.
        si.hStdError = child_stdout_write
    else:
        # Otherwise the child's stderr goes to ours, so a server's log lands
        # in the console a person is already watching rather than into a
        # third pipe nobody drains.
        var GetStdHandle = win32[
            def (UInt32) thin abi("C") -> Int, "GetStdHandle"
        ]()
        si.hStdError = GetStdHandle(UInt32(0xFFFFFFF4))  # STD_ERROR_HANDLE

    # The Job Object first, configured kill-on-close: every process the
    # child starts joins the job, so ending the job ends the tree -- and if
    # this editor dies without ending anything, the handle's destruction does
    # it instead. This is what the design meant by "nothing zombies, by
    # construction"; TerminateProcess on one PID was never that.
    var CreateJobObjectW = win32[
        def (Int, Int) thin abi("C") -> Int, "CreateJobObjectW"
    ]()
    var SetInformationJobObject = win32[
        def (Int, c_int, Int, UInt32) thin abi("C") -> c_int,
        "SetInformationJobObject",
    ]()
    var job = CreateJobObjectW(0, 0)
    if job != 0:
        var ext_size = winkb_struct_size["JOBOBJECT_EXTENDED_LIMIT_INFORMATION"]()
        var limits = List[UInt8](length=ext_size, fill=0)
        # LimitFlags lives inside the basic block, which sits at the front of
        # the extended one; both offsets come from the metadata rather than a
        # count on fingers.
        var flags_at = winkb_field_offset[
            "JOBOBJECT_EXTENDED_LIMIT_INFORMATION", "BasicLimitInformation"
        ]() + winkb_field_offset[
            "JOBOBJECT_BASIC_LIMIT_INFORMATION", "LimitFlags"
        ]()
        Pointer[UInt32, MutAnyOrigin](
            unsafe_from_address=Int(limits.unsafe_ptr()) + flags_at
        )[] = UInt32(winkb_constant["JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE"]())
        if SetInformationJobObject(
            job,
            c_int(winkb_constant["JobObjectExtendedLimitInformation"]()),
            Int(limits.unsafe_ptr()),
            UInt32(ext_size),
        ) == 0:
            # A job that cannot be configured is a job that will not kill its
            # tree on close; better no job than a false promise.
            var CloseJob = win32[
                def (Int) thin abi("C") -> c_int, "CloseHandle"
            ]()
            _ = CloseJob(job)
            job = 0
        _ = limits

    var info = PROCESS_INFORMATION()
    # CreateProcessW may modify the command line in place, which is why it
    # takes a mutable buffer and not a literal.
    var line = utf16z(command)
    var cwd = utf16z(working_dir)
    # Suspended when there is a job to join: a child that runs before it is
    # in the job can spawn a grandchild that never joins it, and that
    # grandchild is exactly the orphan this machinery exists to prevent.
    var flags = winkb_constant["CREATE_NO_WINDOW"]()
    if job != 0:
        flags |= winkb_constant["CREATE_SUSPENDED"]()
    var ok = CreateProcessW(
        0,
        line.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        0,
        0,
        c_int(1),  # inherit handles, so the two pipe ends above reach it
        UInt32(flags),
        0,
        0 if working_dir.byte_length() == 0 else Int(cwd.unsafe_ptr()),
        com_addr(si),
        com_addr(info),
    )
    _ = line
    _ = cwd

    var CloseHandle = win32[def (Int) thin abi("C") -> c_int, "CloseHandle"]()
    # The child has its own copies now; ours would otherwise hold the pipes
    # open after it exits.
    _ = CloseHandle(child_stdin_read)
    _ = CloseHandle(child_stdout_write)

    if ok == 0:
        _ = CloseHandle(our_write)
        _ = CloseHandle(our_read)
        if job != 0:
            _ = CloseHandle(job)
        return Child()

    if job != 0:
        var AssignProcessToJobObject = win32[
            def (Int, Int) thin abi("C") -> c_int, "AssignProcessToJobObject"
        ]()
        if AssignProcessToJobObject(job, info.hProcess) == 0:
            # It could not join -- an old Windows without nested jobs, or a
            # job the process is already locked into. The child still runs;
            # it just runs with the one-process guarantee instead.
            _ = CloseHandle(job)
            job = 0
        var ResumeThread = win32[
            def (Int) thin abi("C") -> UInt32, "ResumeThread"
        ]()
        _ = ResumeThread(info.hThread)

    return Child(info.hProcess, info.hThread, our_write, our_read, job)


def waiting(handle: Int) raises -> Int:
    """How many bytes are readable right now, without blocking.

    `PeekNamedPipe` works on anonymous pipes despite the name, and is the
    supported way to ask. Making the handle non-blocking instead is documented
    as something not to do.
    """
    if handle == 0:
        return 0
    var PeekNamedPipe = win32[
        def (
            Int,
            Int,
            UInt32,
            Int,
            Pointer[UInt32, MutAnyOrigin],
            Int,
        ) thin abi("C") -> c_int,
        "PeekNamedPipe",
    ]()
    var available = UInt32(0)
    if PeekNamedPipe(
        handle, 0, UInt32(0), 0, com_addr(available), 0
    ) == 0:
        # The pipe is broken, which is how a child that exited reports itself.
        return -1
    return Int(available)


def read_some(handle: Int, buffer: Int, capacity: Int) raises -> Int:
    """Read up to `capacity` bytes, only as many as are already waiting."""
    var ready = waiting(handle)
    if ready <= 0:
        return ready
    var want = ready if ready < capacity else capacity
    var ReadFile = win32[
        def (
            Int, Int, UInt32, Pointer[UInt32, MutAnyOrigin], Int
        ) thin abi("C") -> c_int,
        "ReadFile",
    ]()
    var got = UInt32(0)
    if ReadFile(handle, buffer, UInt32(want), com_addr(got), 0) == 0:
        return -1
    return Int(got)


def write_all(handle: Int, text: String) raises -> Bool:
    """Write every byte, looping until the pipe has taken them all."""
    if handle == 0:
        return False
    var WriteFile = win32[
        def (
            Int, Int, UInt32, Pointer[UInt32, MutAnyOrigin], Int
        ) thin abi("C") -> c_int,
        "WriteFile",
    ]()
    var bytes = text.as_bytes()
    var total = len(bytes)
    var sent = 0
    while sent < total:
        var wrote = UInt32(0)
        if WriteFile(
            handle,
            Int(bytes.unsafe_ptr()) + sent,
            UInt32(total - sent),
            com_addr(wrote),
            0,
        ) == 0:
            return False
        if wrote == 0:
            return False
        sent += Int(wrote)
    _ = text
    return True


def kill(mut child: Child) raises:
    """End the child's whole tree and close both pipes.

    The job goes first: terminating it terminates every process the child
    started, which is what a person pressing Stop means. The direct
    terminate stays for the child that never got a job.
    """
    if child.process == 0:
        return
    var CloseHandle = win32[def (Int) thin abi("C") -> c_int, "CloseHandle"]()
    if child.job != 0:
        var TerminateJobObject = win32[
            def (Int, UInt32) thin abi("C") -> c_int, "TerminateJobObject"
        ]()
        _ = TerminateJobObject(child.job, UInt32(0))
        _ = CloseHandle(child.job)
    else:
        var TerminateProcess = win32[
            def (Int, UInt32) thin abi("C") -> c_int, "TerminateProcess"
        ]()
        _ = TerminateProcess(child.process, UInt32(0))
    _ = CloseHandle(child.writes_to)
    _ = CloseHandle(child.reads_from)
    _ = CloseHandle(child.thread)
    _ = CloseHandle(child.process)
    child.process = 0
    child.thread = 0
    child.writes_to = 0
    child.reads_from = 0
    child.job = 0
