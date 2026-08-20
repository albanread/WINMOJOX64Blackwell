# ===----------------------------------------------------------------------=== #
# Windows time.
#
# Windows counts 100-nanosecond intervals since 1601-01-01 UTC, so every
# timestamp that comes out of the filesystem or the kernel needs converting
# before it means anything to the rest of the world. The offset to the Unix
# epoch is 11,644,473,600 seconds; getting it wrong puts every date in the
# seventeenth century, which is at least an obvious failure.
#
# FILETIME is two 32-bit halves rather than one 64-bit field, because it
# predates 64-bit alignment guarantees. It is not 8-byte aligned inside the
# structures that contain it -- WIN32_FIND_DATAW puts one at offset 4 -- so it
# must be read as two u32s, not bitcast to a u64.
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

comptime _EPOCH_DELTA_SECONDS = 11644473600
"""Seconds between 1601-01-01 and 1970-01-01."""


@fieldwise_init
struct DateTime(ImplicitlyCopyable, Movable, Writable):
    """A broken-down calendar time, as `SYSTEMTIME` reports it."""

    var year: Int
    """The full year, e.g. 2026."""
    var month: Int
    """The month, 1-12."""
    var day: Int
    """The day of the month, 1-31."""
    var hour: Int
    """The hour, 0-23."""
    var minute: Int
    """The minute, 0-59."""
    var second: Int
    """The second, 0-59."""
    var millisecond: Int
    """The millisecond, 0-999."""
    var day_of_week: Int
    """The day of the week, 0 for Sunday."""

    def write_to(self, mut writer: Some[Writer]):
        """Writes the time in ISO order, `YYYY-MM-DD HH:MM:SS`.

        Args:
            writer: Where to write.
        """
        def pad2(value: Int) -> String:
            return String("0") + String(value) if value < 10 else String(value)

        writer.write(
            self.year,
            "-",
            pad2(self.month),
            "-",
            pad2(self.day),
            " ",
            pad2(self.hour),
            ":",
            pad2(self.minute),
            ":",
            pad2(self.second),
        )


def filetime_to_unix_ns(filetime: Int) -> Int:
    """Converts a FILETIME tick count to Unix nanoseconds.

    Args:
        filetime: 100-nanosecond intervals since 1601-01-01 UTC.

    Returns:
        Nanoseconds since 1970-01-01 UTC. Zero in, zero out: a zero FILETIME
        means "not recorded", and mapping it to 1601 would be worse.
    """
    if filetime == 0:
        return 0
    return (filetime - _EPOCH_DELTA_SECONDS * 10000000) * 100


def unix_ns_to_filetime(nanoseconds: Int) -> Int:
    """Converts Unix nanoseconds to a FILETIME tick count.

    Args:
        nanoseconds: Nanoseconds since 1970-01-01 UTC.

    Returns:
        100-nanosecond intervals since 1601-01-01 UTC.
    """
    if nanoseconds == 0:
        return 0
    return nanoseconds // 100 + _EPOCH_DELTA_SECONDS * 10000000


def _read_filetime(base: Pointer[UInt8, MutAnyOrigin], offset: Int) -> Int:
    """Reads a FILETIME as one integer from two 32-bit halves.

    Read as halves on purpose: a FILETIME inside a larger structure is only
    4-byte aligned, so bitcasting to `UInt64` is an unaligned load.

    Args:
        base: The containing structure.
        offset: Where the FILETIME starts.

    Returns:
        The tick count.
    """
    var low = Int(base.unsafe_offset(offset).unsafe_bitcast[UInt32]()[])
    var high = Int(base.unsafe_offset(offset + 4).unsafe_bitcast[UInt32]()[])
    return (high << 32) | low


def system_time_ns() raises -> Int:
    """The current UTC time in Unix nanoseconds.

    Uses `GetSystemTimePreciseAsFileTime`, whose resolution is under a
    microsecond; `GetSystemTimeAsFileTime` is quantised to the ~15 ms
    scheduler tick.

    Returns:
        Nanoseconds since 1970-01-01 UTC.

    Raises:
        If kernel32.dll cannot be reached.
    """
    var ticks = UInt64(0)
    _ = Win32Module("kernel32.dll").function[
        def (Pointer[UInt64, MutAnyOrigin]) thin abi("C") -> None
    ]("GetSystemTimePreciseAsFileTime")(
        Pointer(to=ticks).unsafe_origin_cast[MutAnyOrigin]()
    )
    return filetime_to_unix_ns(Int(ticks))


def to_local_time(unix_ns: Int) raises -> DateTime:
    """Breaks a Unix timestamp down into local calendar fields.

    Local, not UTC: the conversion goes through `FileTimeToLocalFileTime`, so
    it applies the time zone *and the DST rule in force on that date* rather
    than today's offset.

    Args:
        unix_ns: Nanoseconds since 1970-01-01 UTC.

    Returns:
        The local date and time.

    Raises:
        If the conversion fails.

    Example:

    ```mojo
    from std.windows import system_time_ns, to_local_time

    def main() raises:
        print(to_local_time(system_time_ns()))
    ```
    """
    comptime SYSTEMTIME_BYTES = winkb_struct_size["SYSTEMTIME"]()
    comptime YEAR_AT = winkb_field_offset["SYSTEMTIME", "wYear"]()
    comptime MONTH_AT = winkb_field_offset["SYSTEMTIME", "wMonth"]()
    comptime DOW_AT = winkb_field_offset["SYSTEMTIME", "wDayOfWeek"]()
    comptime DAY_AT = winkb_field_offset["SYSTEMTIME", "wDay"]()
    comptime HOUR_AT = winkb_field_offset["SYSTEMTIME", "wHour"]()
    comptime MINUTE_AT = winkb_field_offset["SYSTEMTIME", "wMinute"]()
    comptime SECOND_AT = winkb_field_offset["SYSTEMTIME", "wSecond"]()
    comptime MS_AT = winkb_field_offset["SYSTEMTIME", "wMilliseconds"]()

    var kernel32 = Win32Module("kernel32.dll")
    var utc = UInt64(unix_ns_to_filetime(unix_ns))
    var local = UInt64(0)
    if (
        kernel32.function[
            def (
                Pointer[UInt64, MutAnyOrigin], Pointer[UInt64, MutAnyOrigin]
            ) thin abi("C") -> c_int
        ]("FileTimeToLocalFileTime")(
            Pointer(to=utc).unsafe_origin_cast[MutAnyOrigin](),
            Pointer(to=local).unsafe_origin_cast[MutAnyOrigin](),
        )
        == 0
    ):
        raise_last_error("FileTimeToLocalFileTime")

    var parts = List[UInt8](length=SYSTEMTIME_BYTES, fill=0)
    var base = parts.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    if (
        kernel32.function[
            def (
                Pointer[UInt64, MutAnyOrigin], Pointer[UInt8, MutAnyOrigin]
            ) thin abi("C") -> c_int
        ]("FileTimeToSystemTime")(
            Pointer(to=local).unsafe_origin_cast[MutAnyOrigin](), base
        )
        == 0
    ):
        raise_last_error("FileTimeToSystemTime")

    return DateTime(
        Int(base.unsafe_offset(YEAR_AT).unsafe_bitcast[UInt16]()[]),
        Int(base.unsafe_offset(MONTH_AT).unsafe_bitcast[UInt16]()[]),
        Int(base.unsafe_offset(DAY_AT).unsafe_bitcast[UInt16]()[]),
        Int(base.unsafe_offset(HOUR_AT).unsafe_bitcast[UInt16]()[]),
        Int(base.unsafe_offset(MINUTE_AT).unsafe_bitcast[UInt16]()[]),
        Int(base.unsafe_offset(SECOND_AT).unsafe_bitcast[UInt16]()[]),
        Int(base.unsafe_offset(MS_AT).unsafe_bitcast[UInt16]()[]),
        Int(base.unsafe_offset(DOW_AT).unsafe_bitcast[UInt16]()[]),
    )


def file_times(path: StringSlice) raises -> Tuple[Int, Int, Int]:
    """A file's creation, access and modification times.

    One call, not three: `GetFileAttributesExW` reads the directory entry
    once, where three separate queries would each pay for the lookup.

    Args:
        path: The file or directory to inspect.

    Returns:
        Creation, last-access and last-write times, each in Unix nanoseconds.
        A zero means the filesystem does not record that one.

    Raises:
        If the path cannot be reached.
    """
    comptime DATA_BYTES = winkb_struct_size["WIN32_FILE_ATTRIBUTE_DATA"]()
    comptime CREATED_AT = winkb_field_offset[
        "WIN32_FILE_ATTRIBUTE_DATA", "ftCreationTime"
    ]()
    comptime ACCESSED_AT = winkb_field_offset[
        "WIN32_FILE_ATTRIBUTE_DATA", "ftLastAccessTime"
    ]()
    comptime WRITTEN_AT = winkb_field_offset[
        "WIN32_FILE_ATTRIBUTE_DATA", "ftLastWriteTime"
    ]()

    var wide = WideString(path)
    var data = List[UInt8](length=DATA_BYTES, fill=0)
    var base = data.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    if (
        Win32Module("kernel32.dll").function[
            def (
                Pointer[UInt16, MutAnyOrigin], c_int, Pointer[UInt8, MutAnyOrigin]
            ) thin abi("C") -> c_int
        ]("GetFileAttributesExW")(
            wide.unsafe_ptr(),
            c_int(winkb_constant["GetFileExInfoStandard"]()),
            base,
        )
        == 0
    ):
        raise_last_error("GetFileAttributesExW(" + String(path) + ")")

    return (
        filetime_to_unix_ns(_read_filetime(base, CREATED_AT)),
        filetime_to_unix_ns(_read_filetime(base, ACCESSED_AT)),
        filetime_to_unix_ns(_read_filetime(base, WRITTEN_AT)),
    )
