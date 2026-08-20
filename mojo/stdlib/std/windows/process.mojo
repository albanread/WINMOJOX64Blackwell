# ===----------------------------------------------------------------------=== #
# Processes and the environment.
#
# `CreateProcessW` has two traps that cost everyone the same afternoon.
#
# It takes the command line as ONE string and parses it itself, using rules
# that are not the shell's and not `argv`'s. There is no array form. So
# `run(["git", "commit", "-m", "two words"])` has to do the quoting, and
# `quote_argument` below implements the MSVCRT rules that `CommandLineToArgvW`
# will apply at the other end.
#
# And its lpCommandLine parameter is `LPWSTR`, not `LPCWSTR` -- the callee may
# write into the buffer. Passing a string literal's storage is a documented way
# to corrupt memory. Everything here passes a `WideString` it owns.
#
# Capturing output needs one more piece: the pipe's write end must be
# inheritable and the read end must NOT be, or the child holds a copy of the
# read handle open and `ReadFile` never sees end-of-file. That deadlock is the
# single most common way this is got wrong.
# ===----------------------------------------------------------------------=== #

from std.ffi import c_int
from std.memory import Pointer
from std.sys._win32 import Win32Module
from std.sys._winkb import (
    winkb_constant,
    winkb_field_offset,
    winkb_struct_size,
)
from std.windows.core import (
    Handle,
    WideString,
    from_wide,
    last_error,
    raise_last_error,
)

comptime _INFINITE = UInt32(winkb_constant["INFINITE"]())
comptime _ERROR_BROKEN_PIPE = winkb_constant["ERROR_BROKEN_PIPE"]()


def quote_argument(argument: StringSlice) -> String:
    """Quotes one argument for a `CreateProcessW` command line.

    Implements the rules `CommandLineToArgvW` applies at the other end: a
    backslash is literal unless it precedes a quote, in which case runs of
    backslashes double. Getting this wrong is how a Windows path ending in a
    backslash escapes the closing quote and swallows the next argument.

    Args:
        argument: The argument as the callee should receive it.

    Returns:
        The argument, quoted if it needs to be.

    Example:

    ```mojo
    from std.windows import quote_argument

    def main():
        print(quote_argument("C:\\\\Program Files\\\\"))
    ```
    """
    var needs_quotes = argument.byte_length() == 0
    for byte in argument.as_bytes():
        if byte == UInt8(ord(" ")) or byte == UInt8(ord("\t")) or byte == UInt8(
            ord('"')
        ):
            needs_quotes = True
    if not needs_quotes:
        return String(argument)

    var out = String('"')
    var backslashes = 0
    for byte in argument.as_bytes():
        if byte == UInt8(ord("\\")):
            backslashes += 1
            continue
        if byte == UInt8(ord('"')):
            # Double the run, then escape the quote itself.
            for _ in range(backslashes * 2 + 1):
                out += "\\"
            backslashes = 0
        else:
            for _ in range(backslashes):
                out += "\\"
            backslashes = 0
        out += chr(Int(byte))
    # A trailing run precedes the closing quote, so it doubles too.
    for _ in range(backslashes * 2):
        out += "\\"
    out += '"'
    return out^


def build_command_line(arguments: List[String]) -> String:
    """Joins arguments into a command line `CreateProcessW` will parse back.

    Args:
        arguments: The program and its arguments, unquoted.

    Returns:
        One command line, each argument quoted as needed.
    """
    var out = String("")
    for i in range(len(arguments)):
        if i:
            out += " "
        out += quote_argument(arguments[i])
    return out^


def current_process_id() raises -> Int:
    """This process's id.

    Returns:
        The process id.

    Raises:
        If kernel32.dll cannot be reached.
    """
    return Int(
        Win32Module("kernel32.dll").function[def () thin abi("C") -> UInt32](
            "GetCurrentProcessId"
        )()
    )


def get_environment(name: StringSlice) raises -> String:
    """Reads an environment variable.

    Args:
        name: The variable's name.

    Returns:
        The value, or an empty string if the variable is not set.

    Raises:
        If the query fails for a reason other than the variable being absent.
    """
    var wide_name = WideString(name)
    var buffer = List[UInt16](length=32768, fill=0)
    var written = Win32Module("kernel32.dll").function[
        def (
            Pointer[UInt16, MutAnyOrigin], Pointer[UInt16, MutAnyOrigin], UInt32
        ) thin abi("C") -> UInt32
    ]("GetEnvironmentVariableW")(
        wide_name.unsafe_ptr(),
        buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        UInt32(32768),
    )
    if written == 0:
        # ERROR_ENVVAR_NOT_FOUND (203) is not a failure worth raising over.
        return String("")
    return from_wide(
        buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](), Int(written)
    )


def set_environment(name: StringSlice, value: StringSlice) raises:
    """Sets an environment variable for this process and its children.

    Only this process: Windows has no way to change a running parent's
    environment, and the registry values under HKCU\\Environment are what a
    *new* shell will inherit, not this one.

    Args:
        name: The variable's name.
        value: The value; empty removes the variable.

    Raises:
        If the variable cannot be set.
    """
    var wide_name = WideString(name)
    var wide_value = WideString(value)
    if (
        Win32Module("kernel32.dll").function[
            def (
                Pointer[UInt16, MutAnyOrigin], Pointer[UInt16, MutAnyOrigin]
            ) thin abi("C") -> c_int
        ]("SetEnvironmentVariableW")(
            wide_name.unsafe_ptr(), wide_value.unsafe_ptr()
        )
        == 0
    ):
        raise_last_error("SetEnvironmentVariableW(" + String(name) + ")")


def environment() raises -> List[String]:
    """Every environment variable, as `NAME=value` entries.

    The block Windows returns is a run of NUL-terminated strings ending in a
    double NUL, and it starts with a few `=C:=...` entries recording the
    per-drive current directories. Those are skipped: they are real, but they
    are not variables anyone means.

    Returns:
        The entries, in the order Windows stores them.

    Raises:
        If the environment block cannot be read.
    """
    var kernel32 = Win32Module("kernel32.dll")
    var block = kernel32.function[def () thin abi("C") -> Int](
        "GetEnvironmentStringsW"
    )()
    if block == 0:
        raise_last_error("GetEnvironmentStringsW")

    var entries = List[String]()
    var cursor = block
    while True:
        var here = Pointer[UInt16, MutAnyOrigin](unsafe_from_address=cursor)
        var units = _wide_length(here)
        if units == 0:
            break  # the double NUL that ends the block
        var entry = from_wide(here, units)
        if not entry.startswith("="):
            entries.append(entry^)
        cursor += (units + 1) * 2

    _ = kernel32.function[def (Int) thin abi("C") -> c_int](
        "FreeEnvironmentStringsW"
    )(block)
    return entries^


def _wide_length(units: Pointer[UInt16, MutAnyOrigin]) -> Int:
    """The number of UTF-16 code units before the terminator.

    Args:
        units: A NUL-terminated UTF-16 buffer.

    Returns:
        The length in code units.
    """
    var n = 0
    while units.unsafe_offset(n)[] != 0:
        n += 1
    return n


def run(arguments: List[String], working_directory: StringSlice = "") raises -> Int:
    """Runs a program to completion and returns its exit code.

    Output goes wherever this process's output goes. Use `run_captured` to
    collect it instead.

    Args:
        arguments: The program and its arguments, unquoted.
        working_directory: Where to run it; empty means inherit.

    Returns:
        The program's exit code.

    Raises:
        If the program cannot be started.

    Example:

    ```mojo
    from std.windows import run

    def main() raises:
        _ = run([String("cmd.exe"), String("/c"), String("echo hello")])
    ```
    """
    var process = _spawn(arguments, working_directory, 0, 0)
    return _wait(process^)


def run_captured(
    arguments: List[String], working_directory: StringSlice = ""
) raises -> Tuple[Int, String]:
    """Runs a program and collects everything it wrote to stdout and stderr.

    Args:
        arguments: The program and its arguments, unquoted.
        working_directory: Where to run it; empty means inherit.

    Returns:
        The exit code and the captured output.

    Raises:
        If the program cannot be started or the pipe fails.

    Example:

    ```mojo
    from std.windows import run_captured

    def main() raises:
        var result = run_captured([String("cmd.exe"), String("/c"), String("ver")])
        print(result[1])
    ```
    """
    comptime SA_BYTES = winkb_struct_size["SECURITY_ATTRIBUTES"]()
    comptime SA_LENGTH_AT = winkb_field_offset["SECURITY_ATTRIBUTES", "nLength"]()
    comptime SA_INHERIT_AT = winkb_field_offset[
        "SECURITY_ATTRIBUTES", "bInheritHandle"
    ]()

    var kernel32 = Win32Module("kernel32.dll")

    var security = List[UInt8](length=SA_BYTES, fill=0)
    var sa = security.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    sa.unsafe_offset(SA_LENGTH_AT).unsafe_bitcast[UInt32]()[] = UInt32(SA_BYTES)
    sa.unsafe_offset(SA_INHERIT_AT).unsafe_bitcast[Int32]()[] = Int32(1)

    var read_end = Int(0)
    var write_end = Int(0)
    if (
        kernel32.function[
            def (
                Pointer[Int, MutAnyOrigin],
                Pointer[Int, MutAnyOrigin],
                Pointer[UInt8, MutAnyOrigin],
                UInt32,
            ) thin abi("C") -> c_int
        ]("CreatePipe")(
            Pointer(to=read_end).unsafe_origin_cast[MutAnyOrigin](),
            Pointer(to=write_end).unsafe_origin_cast[MutAnyOrigin](),
            sa,
            UInt32(0),
        )
        == 0
    ):
        raise_last_error("CreatePipe")

    # The read end must NOT be inheritable. If the child gets a copy, the pipe
    # never reaches end-of-file after the child exits and the read below hangs
    # forever. HANDLE_FLAG_INHERIT is 1; clearing it is the whole fix.
    _ = kernel32.function[
        def (Int, UInt32, UInt32) thin abi("C") -> c_int
    ]("SetHandleInformation")(
        read_end,
        UInt32(winkb_constant["HANDLE_FLAG_INHERIT"]()),
        UInt32(0),
    )

    var reader = Handle(adopt=read_end)
    var process: Handle
    try:
        process = _spawn(arguments, working_directory, write_end, write_end)
    except e:
        _ = kernel32.function[def (Int) thin abi("C") -> c_int]("CloseHandle")(
            write_end
        )
        raise e

    # Close our copy of the write end *before* reading, for the same reason:
    # while this process holds one, the pipe cannot reach end-of-file.
    _ = kernel32.function[def (Int) thin abi("C") -> c_int]("CloseHandle")(
        write_end
    )

    var read_file = kernel32.function[
        def (
            Int,
            Pointer[UInt8, MutAnyOrigin],
            UInt32,
            Pointer[UInt32, MutAnyOrigin],
            Int,
        ) thin abi("C") -> c_int
    ]("ReadFile")

    var output = String("")
    var chunk = List[UInt8](length=4096, fill=0)
    while True:
        var got = UInt32(0)
        var ok = read_file(
            reader.value(),
            chunk.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            UInt32(4096),
            Pointer(to=got).unsafe_origin_cast[MutAnyOrigin](),
            Int(0),
        )
        if ok == 0:
            # ERROR_BROKEN_PIPE is the normal end: the child closed its end.
            if Int(last_error()) != _ERROR_BROKEN_PIPE:
                raise_last_error("ReadFile")
            break
        if got == 0:
            break
        output += String(
            unsafe_from_utf8=Span(chunk)[: Int(got)]
        )

    return (_wait(process^), output^)


def _spawn(
    arguments: List[String],
    working_directory: StringSlice,
    stdout_handle: Int,
    stderr_handle: Int,
) raises -> Handle:
    """Starts a process and returns an owning handle to it.

    Args:
        arguments: The program and its arguments, unquoted.
        working_directory: Where to run it; empty means inherit.
        stdout_handle: A handle for the child's stdout, or 0 to inherit.
        stderr_handle: A handle for the child's stderr, or 0 to inherit.

    Returns:
        The process handle.

    Raises:
        If the process cannot be created.
    """
    comptime STARTUP_BYTES = winkb_struct_size["STARTUPINFOW"]()
    comptime CB_AT = winkb_field_offset["STARTUPINFOW", "cb"]()
    comptime FLAGS_AT = winkb_field_offset["STARTUPINFOW", "dwFlags"]()
    comptime STDIN_AT = winkb_field_offset["STARTUPINFOW", "hStdInput"]()
    comptime STDOUT_AT = winkb_field_offset["STARTUPINFOW", "hStdOutput"]()
    comptime STDERR_AT = winkb_field_offset["STARTUPINFOW", "hStdError"]()
    comptime PI_BYTES = winkb_struct_size["PROCESS_INFORMATION"]()
    comptime HPROCESS_AT = winkb_field_offset["PROCESS_INFORMATION", "hProcess"]()
    comptime HTHREAD_AT = winkb_field_offset["PROCESS_INFORMATION", "hThread"]()

    if len(arguments) == 0:
        raise Error("run needs at least a program name")

    var kernel32 = Win32Module("kernel32.dll")

    var startup = List[UInt8](length=STARTUP_BYTES, fill=0)
    var si = startup.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    si.unsafe_offset(CB_AT).unsafe_bitcast[UInt32]()[] = UInt32(STARTUP_BYTES)

    var inherit = stdout_handle != 0 or stderr_handle != 0
    if inherit:
        # STARTF_USESTDHANDLES is 0x100. Without it the handles below are
        # ignored and the child writes to the parent's console -- which looks
        # like it worked, because the output appears, just not in the pipe.
        # (1 is STARTF_USESHOWWINDOW, and that is the mistake this comment is
        # here to stop.)
        si.unsafe_offset(FLAGS_AT).unsafe_bitcast[UInt32]()[] = UInt32(
            winkb_constant["STARTF_USESTDHANDLES"]()
        )
        si.unsafe_offset(STDOUT_AT).unsafe_bitcast[Int]()[] = stdout_handle
        si.unsafe_offset(STDERR_AT).unsafe_bitcast[Int]()[] = stderr_handle
        si.unsafe_offset(STDIN_AT).unsafe_bitcast[Int]()[] = (
            kernel32.function[def (c_int) thin abi("C") -> Int]("GetStdHandle")(
                c_int(winkb_constant["STD_INPUT_HANDLE"]())
            )
        )

    var info = List[UInt8](length=PI_BYTES, fill=0)
    var pi = info.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()

    # lpCommandLine is LPWSTR, not LPCWSTR: CreateProcessW may write into it,
    # so it gets a buffer we own.
    var command = WideString(build_command_line(arguments))
    var directory = WideString(working_directory)

    var created = kernel32.function[
        def (
            Int,
            Pointer[UInt16, MutAnyOrigin],
            Int,
            Int,
            c_int,
            UInt32,
            Int,
            Int,
            Pointer[UInt8, MutAnyOrigin],
            Pointer[UInt8, MutAnyOrigin],
        ) thin abi("C") -> c_int
    ]("CreateProcessW")(
        Int(0),  # lpApplicationName: let the command line name the program
        command.unsafe_ptr(),
        Int(0),  # process attributes
        Int(0),  # thread attributes
        c_int(1) if inherit else c_int(0),
        UInt32(0),  # creation flags
        Int(0),  # inherit our environment
        # lpCurrentDirectory is nullable and Mojo's Pointer is not, so this
        # parameter is spelled as an address: 0 means "inherit ours", and an
        # empty string here would be an invalid directory rather than a
        # default.
        Int(directory.unsafe_ptr()) if working_directory.byte_length() else 0,
        si,
        pi,
    )
    if created == 0:
        raise_last_error("CreateProcessW(" + arguments[0] + ")")

    # The thread handle is of no use here and leaks if it is not closed.
    _ = kernel32.function[def (Int) thin abi("C") -> c_int]("CloseHandle")(
        pi.unsafe_offset(HTHREAD_AT).unsafe_bitcast[Int]()[]
    )
    return Handle(adopt=pi.unsafe_offset(HPROCESS_AT).unsafe_bitcast[Int]()[])


def _wait(var process: Handle) raises -> Int:
    """Waits for a process and returns its exit code.

    Args:
        process: The process handle; closed on return.

    Returns:
        The exit code.

    Raises:
        If the wait or the query fails.
    """
    var kernel32 = Win32Module("kernel32.dll")
    _ = kernel32.function[def (Int, UInt32) thin abi("C") -> UInt32](
        "WaitForSingleObject"
    )(process.value(), _INFINITE)

    var code = UInt32(0)
    if (
        kernel32.function[
            def (Int, Pointer[UInt32, MutAnyOrigin]) thin abi("C") -> c_int
        ]("GetExitCodeProcess")(
            process.value(), Pointer(to=code).unsafe_origin_cast[MutAnyOrigin]()
        )
        == 0
    ):
        raise_last_error("GetExitCodeProcess")
    return Int(code)


def is_elevated() raises -> Bool:
    """Whether this process is running with administrator rights.

    Asks the process token, not the user's group membership: on a machine
    with UAC on, an administrator's ordinary process is *not* elevated, and
    checking group membership would say it was.

    Returns:
        True if the token is elevated.

    Raises:
        If the token cannot be opened or queried.
    """
    comptime ELEVATION_BYTES = winkb_struct_size["TOKEN_ELEVATION"]()

    var kernel32 = Win32Module("kernel32.dll")
    var advapi32 = Win32Module("advapi32.dll")
    if not advapi32:
        raise Error("cannot load advapi32.dll")

    var process = kernel32.function[def () thin abi("C") -> Int](
        "GetCurrentProcess"
    )()
    var token_value = Int(0)
    if (
        advapi32.function[
            def (Int, UInt32, Pointer[Int, MutAnyOrigin]) thin abi("C") -> c_int
        ]("OpenProcessToken")(
            process,
            UInt32(winkb_constant["TOKEN_QUERY"]()),
            Pointer(to=token_value).unsafe_origin_cast[MutAnyOrigin](),
        )
        == 0
    ):
        raise_last_error("OpenProcessToken")
    var token = Handle(adopt=token_value)

    var elevation = List[UInt8](length=ELEVATION_BYTES, fill=0)
    var returned = UInt32(0)
    if (
        advapi32.function[
            def (
                Int,
                c_int,
                Pointer[UInt8, MutAnyOrigin],
                UInt32,
                Pointer[UInt32, MutAnyOrigin],
            ) thin abi("C") -> c_int
        ]("GetTokenInformation")(
            token.value(),
            c_int(winkb_constant["TokenElevation"]()),
            elevation.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            UInt32(ELEVATION_BYTES),
            Pointer(to=returned).unsafe_origin_cast[MutAnyOrigin](),
        )
        == 0
    ):
        raise_last_error("GetTokenInformation")

    return (
        elevation.unsafe_ptr()
        .unsafe_origin_cast[MutAnyOrigin]()
        .unsafe_bitcast[UInt32]()[]
        != 0
    )
