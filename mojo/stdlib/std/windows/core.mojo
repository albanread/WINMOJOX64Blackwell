# ===----------------------------------------------------------------------=== #
# The three things every Windows call needs.
#
# Wide strings, because the W entry points are the real ones and Mojo strings
# are UTF-8. Errors, because Windows reports failure three mutually
# incompatible ways and none of them is an exception. Handles, because the
# alternative is leaking them.
#
# Everything here is the substrate the rest of the Windows surface is built
# on, and it is deliberately small: if a helper is not needed by two callers,
# it does not belong here.
# ===----------------------------------------------------------------------=== #

from std.ffi import c_int
from std.memory import Pointer, OpaquePointer
from std.sys._win32 import Win32Module
from std.sys._winkb import winkb_constant


# ===----------------------------------------------------------------------=== #
# Wide strings
# ===----------------------------------------------------------------------=== #


struct WideString(Copyable, Movable, Sized):
    """A NUL-terminated UTF-16 buffer, for the W entry points.

    Windows' real API is UTF-16 and Mojo's strings are UTF-8, so every call
    that names a file, a registry key, or a window crosses this boundary. The
    conversion goes through `MultiByteToWideChar` rather than being open-coded
    per code point, so surrogate pairs and invalid input behave the way the
    rest of Windows expects.

    The buffer is owned; `unsafe_ptr()` is valid while the value is alive.
    """

    var _units: List[UInt16]

    def __init__(out self, text: StringSlice) raises:
        """Converts UTF-8 to a NUL-terminated UTF-16 buffer.

        Args:
            text: The text to convert.

        Raises:
            If the text is not valid UTF-8.
        """
        var kernel32 = Win32Module("kernel32.dll")
        var to_wide = kernel32.function[
            def (
                UInt32,
                UInt32,
                Pointer[UInt8, ImmutAnyOrigin],
                c_int,
                Pointer[UInt16, MutAnyOrigin],
                c_int,
            ) thin abi("C") -> c_int
        ]("MultiByteToWideChar")

        var bytes = text.as_bytes()
        var n = len(bytes)
        self._units = List[UInt16]()
        if n == 0:
            self._units.append(0)
            return

        # MB_ERR_INVALID_CHARS: refuse malformed input rather than
        # silently substituting replacement characters.
        var src = bytes.unsafe_ptr().as_imm().unsafe_origin_cast[ImmutAnyOrigin]()
        var needed = to_wide(
            UInt32(winkb_constant["CP_UTF8"]()),
            UInt32(winkb_constant["MB_ERR_INVALID_CHARS"]()),
            src,
            c_int(n),
            Pointer[UInt16, MutAnyOrigin](unsafe_from_address=1),
            c_int(0),
        )
        if needed <= 0:
            raise Error("cannot convert to UTF-16: invalid UTF-8 input")

        self._units = List[UInt16](length=Int(needed) + 1, fill=0)
        var written = to_wide(
            UInt32(winkb_constant["CP_UTF8"]()),
            UInt32(winkb_constant["MB_ERR_INVALID_CHARS"]()),
            src,
            c_int(n),
            self._units.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            needed,
        )
        if written != needed:
            raise Error("cannot convert to UTF-16: conversion failed")
        self._units[Int(needed)] = 0

    def __init__(out self, *, copy: Self):
        """Copies the buffer.

        Args:
            copy: The value being copied.
        """
        self._units = copy._units.copy()

    def __init__(out self, *, deinit move: Self):
        """Moves the buffer.

        Args:
            move: The value being moved from.
        """
        self._units = move._units^

    def __len__(self) -> Int:
        """The number of UTF-16 code units, excluding the terminator.

        Returns:
            The length in code units.
        """
        return len(self._units) - 1 if len(self._units) else 0

    def unsafe_ptr(mut self) -> Pointer[UInt16, MutAnyOrigin]:
        """The buffer, for passing to a W entry point.

        Valid while this value is alive.

        Returns:
            A pointer to the NUL-terminated UTF-16 buffer.
        """
        return self._units.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()


def from_wide(units: Pointer[UInt16, MutAnyOrigin], count: Int = -1) raises -> String:
    """Converts a UTF-16 buffer back to a Mojo string.

    Args:
        units: The UTF-16 buffer.
        count: Code units to convert, or -1 for NUL-terminated.

    Returns:
        The text as UTF-8.

    Raises:
        If the conversion fails.
    """
    var kernel32 = Win32Module("kernel32.dll")
    var to_utf8 = kernel32.function[
        def (
            UInt32,
            UInt32,
            Pointer[UInt16, MutAnyOrigin],
            c_int,
            Pointer[UInt8, MutAnyOrigin],
            c_int,
            Int,
            Int,
        ) thin abi("C") -> c_int
    ]("WideCharToMultiByte")

    var needed = to_utf8(
        UInt32(winkb_constant["CP_UTF8"]()),
        UInt32(0),
        units,
        c_int(count),
        Pointer[UInt8, MutAnyOrigin](unsafe_from_address=1),
        c_int(0),
        Int(0),
        Int(0),
    )
    if needed <= 0:
        return String("")

    var bytes = List[UInt8](length=Int(needed), fill=0)
    var written = to_utf8(
        UInt32(winkb_constant["CP_UTF8"]()),
        UInt32(0),
        units,
        c_int(count),
        bytes.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        needed,
        Int(0),
        Int(0),
    )
    if written <= 0:
        raise Error("cannot convert from UTF-16")

    # A NUL-terminated source counts its terminator; a counted one does not.
    var size = Int(written) - 1 if count < 0 else Int(written)
    return String(unsafe_from_utf8=Span(bytes)[:size])


# ===----------------------------------------------------------------------=== #
# Errors
# ===----------------------------------------------------------------------=== #


def last_error() -> UInt32:
    """The calling thread's last Win32 error code.

    Returns:
        The value of `GetLastError`.
    """
    try:
        return Win32Module("kernel32.dll").function[
            def () thin abi("C") -> UInt32
        ]("GetLastError")()
    except:
        return 0


def error_message(code: UInt32) -> String:
    """The system's own text for a Win32 error code.

    Windows already has the message; asking for it beats printing a bare
    number and making the reader look it up.

    Args:
        code: A Win32 error code, usually from `last_error`.

    Returns:
        The message, or a bare code if the lookup fails.
    """
    try:
        var kernel32 = Win32Module("kernel32.dll")
        var format_message = kernel32.function[
            def (
                UInt32,
                Int,
                UInt32,
                UInt32,
                Pointer[UInt16, MutAnyOrigin],
                UInt32,
                Int,
            ) thin abi("C") -> UInt32
        ]("FormatMessageW")

        # FROM_SYSTEM | IGNORE_INSERTS: the message is Windows' own and takes
        # no arguments from us, which is also what makes it safe to format.
        comptime FLAGS = UInt32(
            winkb_constant["FORMAT_MESSAGE_FROM_SYSTEM"]()
            | winkb_constant["FORMAT_MESSAGE_IGNORE_INSERTS"]()
        )
        var buffer = List[UInt16](length=512, fill=0)
        var n = format_message(
            FLAGS,
            Int(0),
            code,
            UInt32(0),
            buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            UInt32(512),
            Int(0),
        )
        if n == 0:
            return String("error ") + String(code)

        # Trim the trailing CRLF the system appends.
        var end = Int(n)
        while end > 0 and (
            buffer[end - 1] == UInt16(13) or buffer[end - 1] == UInt16(10)
        ):
            end -= 1
        return from_wide(
            buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](), end
        )
    except:
        return String("error ") + String(code)


def raise_last_error(what: StringSlice) raises:
    """Raises with the calling thread's last error, decoded.

    The BOOL-plus-GetLastError convention in one call: check the return, then
    `raise_last_error("CreateFileW")`.

    Args:
        what: The operation that failed, named for the reader.

    Raises:
        Always.
    """
    var code = last_error()
    raise Error(String(what) + " failed: " + error_message(code) + " (" + String(code) + ")")


def raise_if_failed(hresult: Int32, what: StringSlice) raises:
    """Raises if an HRESULT indicates failure.

    The COM convention: negative means failure, and the facility code is
    decoded by the same message table as a Win32 error.

    Args:
        hresult: The HRESULT to check.
        what: The operation that produced it.

    Raises:
        If `hresult` is negative.
    """
    if hresult < 0:
        raise Error(
            String(what)
            + " failed: "
            + error_message(UInt32(Int(hresult) & 0xFFFFFFFF))
            + " (hr=0x"
            + hex(Int(hresult) & 0xFFFFFFFF)
            + ")"
        )


# ===----------------------------------------------------------------------=== #
# Handles
# ===----------------------------------------------------------------------=== #


struct Handle(Boolable, Movable):
    """An owning Win32 HANDLE, closed when it goes out of scope.

    Move-only on purpose: duplicating a handle is `DuplicateHandle`, not a
    copy, so a copyable wrapper would close the same handle twice. A move
    transfers ownership and costs nothing, which is the same reasoning that
    makes `ComPtr`'s move free.

    `INVALID_HANDLE_VALUE` and null both count as empty, since Windows uses
    whichever suits the API.
    """

    var _value: Int

    def __init__(out self, *, adopt: Int):
        """Takes ownership of a raw handle.

        Args:
            adopt: The handle, as returned by a Win32 call.
        """
        self._value = adopt

    def __init__(out self, *, deinit move: Self):
        """Moves ownership; nothing is closed.

        Args:
            move: The value being moved from.
        """
        self._value = move._value

    def __deinit__(deinit self):
        """Closes the handle, if it is a real one."""
        if self.__bool__():
            try:
                _ = Win32Module("kernel32.dll").function[
                    def (Int) thin abi("C") -> c_int
                ]("CloseHandle")(self._value)
            except:
                pass

    def __bool__(self) -> Bool:
        """Whether this holds a usable handle.

        Returns:
            False for null or `INVALID_HANDLE_VALUE`.
        """
        return self._value != 0 and self._value != -1

    def value(self) -> Int:
        """The raw handle, for passing to Win32.

        Ownership stays here; do not close it.

        Returns:
            The handle value.
        """
        return self._value

    def release(mut self) -> Int:
        """Gives up ownership and returns the raw handle.

        The caller becomes responsible for closing it.

        Returns:
            The handle value.
        """
        var v = self._value
        self._value = 0
        return v
