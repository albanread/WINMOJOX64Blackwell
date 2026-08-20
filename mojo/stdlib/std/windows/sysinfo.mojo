# ===----------------------------------------------------------------------=== #
# What machine is this?
#
# Two of these are worth a warning.
#
# `GetVersionExW` lies. Since Windows 8.1 it reports 6.2 to any process without
# a compatibility manifest naming a newer release -- a shim to stop old
# programs refusing to run. `RtlGetVersion` in ntdll is not shimmed and is what
# every version check should use.
#
# `GetSystemInfo`'s dwNumberOfProcessors is capped at 64: it reports the
# process's own processor group, not the machine. `GetActiveProcessorCount`
# with ALL_PROCESSOR_GROUPS is the honest count. Irrelevant on a Snapdragon X
# with twelve cores, and load-bearing on a big server.
#
# Struct offsets come from winkb at compile time, so the 32-bit numbers that
# fill the internet cannot get in.
# ===----------------------------------------------------------------------=== #

from std.ffi import c_int
from std.memory import Pointer
from std.sys._win32 import Win32Module
from std.sys._winkb import (
    winkb_constant,
    winkb_field_offset,
    winkb_struct_size,
)
from std.windows.core import WideString, from_wide, raise_last_error


@fieldwise_init
struct WindowsVersion(Copyable, Movable, Writable):
    """A Windows version as the kernel reports it, unshimmed."""

    var major: Int
    """The major version, e.g. 10."""
    var minor: Int
    """The minor version."""
    var build: Int
    """The build number, which is what actually identifies a release."""

    def write_to(self, mut writer: Some[Writer]):
        """Writes the version as `major.minor.build`.

        Args:
            writer: Where to write.
        """
        writer.write(self.major, ".", self.minor, ".", self.build)


@fieldwise_init
struct MemoryStatus(Copyable, Movable):
    """A snapshot of the machine's memory, in bytes."""

    var load_percent: Int
    """Roughly how much physical memory is in use, 0-100."""
    var total_physical: Int
    """Installed physical memory visible to the OS."""
    var available_physical: Int
    """Physical memory available without paging."""
    var total_virtual: Int
    """The size of this process's virtual address space."""
    var available_virtual: Int
    """Unreserved, uncommitted space in this process's address space."""


def windows_version() raises -> WindowsVersion:
    """The real Windows version, from `RtlGetVersion`.

    Unlike `GetVersionExW`, this is not subject to the compatibility shim that
    reports 6.2 to unmanifested processes.

    Returns:
        The major, minor and build numbers.

    Raises:
        If ntdll.dll cannot be reached.

    Example:

    ```mojo
    from std.windows import windows_version

    def main() raises:
        print("Windows", windows_version())
    ```
    """
    comptime INFO_BYTES = winkb_struct_size["OSVERSIONINFOW"]()
    comptime SIZE_AT = winkb_field_offset["OSVERSIONINFOW", "dwOSVersionInfoSize"]()
    comptime MAJOR_AT = winkb_field_offset["OSVERSIONINFOW", "dwMajorVersion"]()
    comptime MINOR_AT = winkb_field_offset["OSVERSIONINFOW", "dwMinorVersion"]()
    comptime BUILD_AT = winkb_field_offset["OSVERSIONINFOW", "dwBuildNumber"]()

    var ntdll = Win32Module("ntdll.dll")
    if not ntdll:
        raise Error("cannot load ntdll.dll")

    var info = List[UInt8](length=INFO_BYTES, fill=0)
    var base = info.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    base.unsafe_offset(SIZE_AT).unsafe_bitcast[UInt32]()[] = UInt32(INFO_BYTES)

    var status = ntdll.function[
        def (Pointer[UInt8, MutAnyOrigin]) thin abi("C") -> Int32
    ]("RtlGetVersion")(base)
    if status != 0:
        raise Error("RtlGetVersion failed: status " + String(status))

    return WindowsVersion(
        Int(base.unsafe_offset(MAJOR_AT).unsafe_bitcast[UInt32]()[]),
        Int(base.unsafe_offset(MINOR_AT).unsafe_bitcast[UInt32]()[]),
        Int(base.unsafe_offset(BUILD_AT).unsafe_bitcast[UInt32]()[]),
    )


def memory_status() raises -> MemoryStatus:
    """A snapshot of physical and virtual memory.

    Returns:
        The current memory figures, in bytes.

    Raises:
        If the query fails.

    Example:

    ```mojo
    from std.windows import memory_status

    def main() raises:
        var mem = memory_status()
        print(mem.total_physical // (1 << 30), "GiB installed")
    ```
    """
    comptime BYTES = winkb_struct_size["MEMORYSTATUSEX"]()
    comptime LENGTH_AT = winkb_field_offset["MEMORYSTATUSEX", "dwLength"]()
    comptime LOAD_AT = winkb_field_offset["MEMORYSTATUSEX", "dwMemoryLoad"]()
    comptime TOTAL_PHYS_AT = winkb_field_offset["MEMORYSTATUSEX", "ullTotalPhys"]()
    comptime AVAIL_PHYS_AT = winkb_field_offset["MEMORYSTATUSEX", "ullAvailPhys"]()
    comptime TOTAL_VIRT_AT = winkb_field_offset["MEMORYSTATUSEX", "ullTotalVirtual"]()
    comptime AVAIL_VIRT_AT = winkb_field_offset["MEMORYSTATUSEX", "ullAvailVirtual"]()

    var status = List[UInt8](length=BYTES, fill=0)
    var base = status.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    # dwLength is how the call knows which version of the struct it was given;
    # leaving it zero makes the call fail rather than misbehave.
    base.unsafe_offset(LENGTH_AT).unsafe_bitcast[UInt32]()[] = UInt32(BYTES)

    var ok = Win32Module("kernel32.dll").function[
        def (Pointer[UInt8, MutAnyOrigin]) thin abi("C") -> c_int
    ]("GlobalMemoryStatusEx")(base)
    if ok == 0:
        raise_last_error("GlobalMemoryStatusEx")

    return MemoryStatus(
        Int(base.unsafe_offset(LOAD_AT).unsafe_bitcast[UInt32]()[]),
        Int(base.unsafe_offset(TOTAL_PHYS_AT).unsafe_bitcast[UInt64]()[]),
        Int(base.unsafe_offset(AVAIL_PHYS_AT).unsafe_bitcast[UInt64]()[]),
        Int(base.unsafe_offset(TOTAL_VIRT_AT).unsafe_bitcast[UInt64]()[]),
        Int(base.unsafe_offset(AVAIL_VIRT_AT).unsafe_bitcast[UInt64]()[]),
    )


def processor_count() raises -> Int:
    """The number of active logical processors on the whole machine.

    Uses `GetActiveProcessorCount(ALL_PROCESSOR_GROUPS)`, not
    `GetSystemInfo`, whose count stops at the calling process's own processor
    group and so caps at 64.

    Returns:
        The logical processor count.

    Raises:
        If the query fails.
    """
    var count = Win32Module("kernel32.dll").function[
        def (UInt16) thin abi("C") -> UInt32
    ]("GetActiveProcessorCount")(
        UInt16(winkb_constant["ALL_PROCESSOR_GROUPS"]())
    )
    if count == 0:
        raise_last_error("GetActiveProcessorCount")
    return Int(count)


def computer_name() raises -> String:
    """This machine's DNS host name.

    Returns:
        The host name.

    Raises:
        If the query fails.
    """
    var get_name = Win32Module("kernel32.dll").function[
        def (
            c_int, Pointer[UInt16, MutAnyOrigin], Pointer[UInt32, MutAnyOrigin]
        ) thin abi("C") -> c_int
    ]("GetComputerNameExW")

    # 256 is the documented ceiling for a DNS host name.
    var buffer = List[UInt16](length=256, fill=0)
    var size = UInt32(256)
    if (
        get_name(
            c_int(winkb_constant["ComputerNameDnsHostname"]()),
            buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            Pointer(to=size).unsafe_origin_cast[MutAnyOrigin](),
        )
        == 0
    ):
        raise_last_error("GetComputerNameExW")
    return from_wide(
        buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](), Int(size)
    )


def user_name() raises -> String:
    """The user this process is running as.

    Returns:
        The account name, without a domain prefix.

    Raises:
        If the query fails.
    """
    var advapi32 = Win32Module("advapi32.dll")
    if not advapi32:
        raise Error("cannot load advapi32.dll")

    # UNLEN + 1 = 257, and this call counts the terminator in both directions.
    var buffer = List[UInt16](length=257, fill=0)
    var size = UInt32(257)
    if (
        advapi32.function[
            def (
                Pointer[UInt16, MutAnyOrigin], Pointer[UInt32, MutAnyOrigin]
            ) thin abi("C") -> c_int
        ]("GetUserNameW")(
            buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            Pointer(to=size).unsafe_origin_cast[MutAnyOrigin](),
        )
        == 0
    ):
        raise_last_error("GetUserNameW")
    return from_wide(
        buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        Int(size) - 1 if size > 0 else 0,
    )


def uptime_ms() raises -> Int:
    """Milliseconds since the machine booted.

    `GetTickCount64`, not `GetTickCount`: the 32-bit one wraps after 49.7 days
    and the bug it causes surfaces seven weeks after anyone could reproduce it.

    Returns:
        Milliseconds since boot.

    Raises:
        If kernel32.dll cannot be reached.
    """
    return Int(
        Win32Module("kernel32.dll").function[
            def () thin abi("C") -> UInt64
        ]("GetTickCount64")()
    )


def performance_counter() raises -> Int:
    """The high-resolution performance counter's current value.

    Divide a difference of two readings by `performance_frequency()` to get
    seconds. This is the timer to measure with; `GetTickCount64` has a
    resolution of about 15 ms.

    Returns:
        The counter's current tick value.

    Raises:
        If the query fails.
    """
    var ticks = Int64(0)
    if (
        Win32Module("kernel32.dll").function[
            def (Pointer[Int64, MutAnyOrigin]) thin abi("C") -> c_int
        ]("QueryPerformanceCounter")(
            Pointer(to=ticks).unsafe_origin_cast[MutAnyOrigin]()
        )
        == 0
    ):
        raise_last_error("QueryPerformanceCounter")
    return Int(ticks)


def performance_frequency() raises -> Int:
    """Ticks per second for `performance_counter`.

    Fixed at boot, so it is safe to read once and keep.

    Returns:
        The counter's frequency in hertz.

    Raises:
        If the query fails.
    """
    var hz = Int64(0)
    if (
        Win32Module("kernel32.dll").function[
            def (Pointer[Int64, MutAnyOrigin]) thin abi("C") -> c_int
        ]("QueryPerformanceFrequency")(
            Pointer(to=hz).unsafe_origin_cast[MutAnyOrigin]()
        )
        == 0
    ):
        raise_last_error("QueryPerformanceFrequency")
    return Int(hz)
