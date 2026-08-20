# ===----------------------------------------------------------------------=== #
# The console.
#
# Two calls here are the difference between a program that looks broken on
# Windows and one that does not.
#
# `use_utf8_console` sets the console code page to 65001. Without it, every
# non-ASCII byte a Mojo program prints is decoded as CP437 or CP1252 and the
# output is mojibake -- not a Mojo bug, a console default from 1987.
#
# `enable_virtual_terminal` turns on ANSI escape handling, which conhost has
# supported since Windows 10 1511 but still leaves off by default. Without it
# a coloured progress bar prints its escape codes literally.
#
# Both are idempotent and cheap; calling them at the top of main is the normal
# thing to do.
# ===----------------------------------------------------------------------=== #

from std.ffi import c_int
from std.memory import Pointer
from std.sys._win32 import Win32Module
from std.sys._winkb import (
    winkb_constant,
    winkb_field_offset,
    winkb_struct_size,
)
from std.windows.core import WideString, raise_last_error

comptime _STD_OUTPUT_HANDLE = c_int(winkb_constant["STD_OUTPUT_HANDLE"]())
comptime _ENABLE_VIRTUAL_TERMINAL_PROCESSING = UInt32(
    winkb_constant["ENABLE_VIRTUAL_TERMINAL_PROCESSING"]()
)
comptime _CP_UTF8 = UInt32(winkb_constant["CP_UTF8"]())


def _std_output() raises -> Int:
    """The process's standard output handle.

    Returns:
        The handle; not owned, so it must not be closed.

    Raises:
        If there is no console attached.
    """
    var handle = Win32Module("kernel32.dll").function[
        def (c_int) thin abi("C") -> Int
    ]("GetStdHandle")(_STD_OUTPUT_HANDLE)
    if handle == 0 or handle == -1:
        raise Error("no standard output handle")
    return handle


def use_utf8_console() raises:
    """Switches the console's input and output code pages to UTF-8.

    Without this, printing anything outside ASCII produces mojibake, because
    the console still defaults to a legacy OEM code page.

    Raises:
        If the code page cannot be set, which normally means no console is
        attached.

    Example:

    ```mojo
    from std.windows import use_utf8_console

    def main() raises:
        use_utf8_console()
        print("café über 🐉")
    ```
    """
    var kernel32 = Win32Module("kernel32.dll")
    var set_output_cp = kernel32.function[
        def (UInt32) thin abi("C") -> c_int
    ]("SetConsoleOutputCP")
    var set_input_cp = kernel32.function[
        def (UInt32) thin abi("C") -> c_int
    ]("SetConsoleCP")
    if set_output_cp(_CP_UTF8) == 0:
        raise_last_error("SetConsoleOutputCP")
    # Input is best-effort: a redirected stdin has no code page and the
    # failure is not one the caller can do anything about.
    _ = set_input_cp(_CP_UTF8)


def enable_virtual_terminal() raises:
    """Turns on ANSI escape sequence handling for the console.

    Windows has supported VT sequences since Windows 10 1511 but leaves the
    mode off, so escape codes print literally until this is called.

    Raises:
        If the console mode cannot be changed.

    Example:

    ```mojo
    from std.windows import enable_virtual_terminal

    def main() raises:
        enable_virtual_terminal()
        print("\\x1b[32mgreen\\x1b[0m")
    ```
    """
    var kernel32 = Win32Module("kernel32.dll")
    var handle = _std_output()

    var mode = UInt32(0)
    if (
        kernel32.function[
            def (Int, Pointer[UInt32, MutAnyOrigin]) thin abi("C") -> c_int
        ]("GetConsoleMode")(
            handle, Pointer(to=mode).unsafe_origin_cast[MutAnyOrigin]()
        )
        == 0
    ):
        raise_last_error("GetConsoleMode")

    if (
        kernel32.function[def (Int, UInt32) thin abi("C") -> c_int](
            "SetConsoleMode"
        )(handle, mode | _ENABLE_VIRTUAL_TERMINAL_PROCESSING)
        == 0
    ):
        raise_last_error("SetConsoleMode")


def console_size() raises -> Tuple[Int, Int]:
    """The console window's size in character cells.

    Reports the *window*, not the screen buffer: the buffer is usually far
    taller than what the user can see, and wrapping to it is the classic
    off-by-a-scrollback bug.

    Returns:
        The width and height in cells.

    Raises:
        If there is no console to measure.
    """
    comptime INFO_BYTES = winkb_struct_size["CONSOLE_SCREEN_BUFFER_INFO"]()
    comptime WINDOW_AT = winkb_field_offset[
        "CONSOLE_SCREEN_BUFFER_INFO", "srWindow"
    ]()

    var info = List[UInt8](length=INFO_BYTES, fill=0)
    var base = info.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    if (
        Win32Module("kernel32.dll").function[
            def (Int, Pointer[UInt8, MutAnyOrigin]) thin abi("C") -> c_int
        ]("GetConsoleScreenBufferInfo")(_std_output(), base)
        == 0
    ):
        raise_last_error("GetConsoleScreenBufferInfo")

    # SMALL_RECT is four Int16: left, top, right, bottom -- inclusive, hence
    # the +1 on each span.
    var window = base.unsafe_offset(WINDOW_AT).unsafe_bitcast[Int16]()
    return (
        Int(window.unsafe_offset(2)[] - window[]) + 1,
        Int(window.unsafe_offset(3)[] - window.unsafe_offset(1)[]) + 1,
    )


def set_console_title(title: StringSlice) raises:
    """Sets the console window's title bar text.

    Args:
        title: The text to show.

    Raises:
        If the title cannot be set.
    """
    var wide = WideString(title)
    if (
        Win32Module("kernel32.dll").function[
            def (Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> c_int
        ]("SetConsoleTitleW")(wide.unsafe_ptr())
        == 0
    ):
        raise_last_error("SetConsoleTitleW")
