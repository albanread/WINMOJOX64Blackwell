# ===----------------------------------------------------------------------=== #
# The filesystem, as Windows actually has it.
#
# `std.os` is written against POSIX and the shim in CompilerRT covers what can
# be emulated. This module is the rest: attributes that have no POSIX
# equivalent, a directory walk that returns metadata with each entry instead of
# forcing a stat per name, and the path services (`GetFullPathNameW`,
# `GetTempPathW`) that respect Windows' own rules for what a path means.
#
# WIN32_FIND_DATAW is 592 bytes with cFileName at 44 -- on 64-bit. The 32-bit
# numbers differ and are what most sample code shows, so every offset here
# comes from winkb at compile time rather than from a header transcription.
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
from std.windows.time import _read_filetime, filetime_to_unix_ns

comptime FILE_ATTRIBUTE_READONLY = UInt32(
    winkb_constant["FILE_ATTRIBUTE_READONLY"]()
)
"""The file cannot be written to or deleted."""
comptime FILE_ATTRIBUTE_HIDDEN = UInt32(
    winkb_constant["FILE_ATTRIBUTE_HIDDEN"]()
)
"""The file is not shown in an ordinary directory listing."""
comptime FILE_ATTRIBUTE_SYSTEM = UInt32(
    winkb_constant["FILE_ATTRIBUTE_SYSTEM"]()
)
"""The file belongs to the operating system."""
comptime FILE_ATTRIBUTE_DIRECTORY = UInt32(
    winkb_constant["FILE_ATTRIBUTE_DIRECTORY"]()
)
"""The entry is a directory."""
comptime FILE_ATTRIBUTE_ARCHIVE = UInt32(
    winkb_constant["FILE_ATTRIBUTE_ARCHIVE"]()
)
"""The file has changed since it was last backed up."""
comptime FILE_ATTRIBUTE_REPARSE_POINT = UInt32(
    winkb_constant["FILE_ATTRIBUTE_REPARSE_POINT"]()
)
"""The entry is a symlink, junction, or other reparse point."""

comptime _INVALID_FILE_ATTRIBUTES = UInt32(0xFFFFFFFF)
comptime _ERROR_NO_MORE_FILES = winkb_constant["ERROR_NO_MORE_FILES"]()


@fieldwise_init
struct DirEntry(Copyable, Movable):
    """One entry from a directory listing, with the metadata the walk already
    had to read.

    `FindNextFileW` returns attributes, size and timestamps along with the
    name, so a listing that also reports them costs nothing; asking
    POSIX-style, with a stat per name, costs one syscall per file.
    """

    var name: String
    """The entry's name, without any directory part."""
    var attributes: UInt32
    """The `FILE_ATTRIBUTE_*` bits."""
    var size: Int
    """The file's size in bytes; meaningless for directories."""
    var modified: Int
    """Last write time, in Unix nanoseconds; zero if not recorded."""
    var created: Int
    """Creation time, in Unix nanoseconds; zero if not recorded."""

    def is_directory(self) -> Bool:
        """Whether this entry is a directory.

        Returns:
            True for directories.
        """
        return (self.attributes & FILE_ATTRIBUTE_DIRECTORY) != 0

    def is_hidden(self) -> Bool:
        """Whether this entry is hidden.

        Returns:
            True for hidden entries.
        """
        return (self.attributes & FILE_ATTRIBUTE_HIDDEN) != 0


def file_attributes(path: StringSlice) raises -> UInt32:
    """The `FILE_ATTRIBUTE_*` bits for a path.

    Args:
        path: The path to inspect.

    Returns:
        The attribute bits.

    Raises:
        If the path does not exist or cannot be reached.
    """
    var wide = WideString(path)
    var bits = Win32Module("kernel32.dll").function[
        def (Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> UInt32
    ]("GetFileAttributesW")(wide.unsafe_ptr())
    if bits == _INVALID_FILE_ATTRIBUTES:
        raise_last_error("GetFileAttributesW(" + String(path) + ")")
    return bits


def path_exists(path: StringSlice) -> Bool:
    """Whether a path exists.

    Args:
        path: The path to test.

    Returns:
        True if something is there, file or directory.
    """
    try:
        _ = file_attributes(path)
        return True
    except:
        return False


def is_directory(path: StringSlice) -> Bool:
    """Whether a path names a directory.

    Args:
        path: The path to test.

    Returns:
        True for an existing directory.
    """
    try:
        return (file_attributes(path) & FILE_ATTRIBUTE_DIRECTORY) != 0
    except:
        return False


def list_directory(path: StringSlice) raises -> List[DirEntry]:
    """Lists a directory, with each entry's attributes and size.

    `.` and `..` are omitted.

    Args:
        path: The directory to list, without a trailing wildcard.

    Returns:
        The entries, in the order the filesystem reports them.

    Raises:
        If the directory cannot be opened.

    Example:

    ```mojo
    from std.windows import list_directory

    def main() raises:
        for entry in list_directory("C:\\\\Windows"):
            if entry.is_directory():
                print(entry.name)
    ```
    """
    comptime ATTRS_AT = winkb_field_offset["WIN32_FIND_DATAW", "dwFileAttributes"]()
    comptime SIZE_HIGH_AT = winkb_field_offset["WIN32_FIND_DATAW", "nFileSizeHigh"]()
    comptime SIZE_LOW_AT = winkb_field_offset["WIN32_FIND_DATAW", "nFileSizeLow"]()
    comptime NAME_AT = winkb_field_offset["WIN32_FIND_DATAW", "cFileName"]()
    comptime CREATED_AT = winkb_field_offset["WIN32_FIND_DATAW", "ftCreationTime"]()
    comptime WRITTEN_AT = winkb_field_offset["WIN32_FIND_DATAW", "ftLastWriteTime"]()
    comptime FIND_BYTES = winkb_struct_size["WIN32_FIND_DATAW"]()

    var kernel32 = Win32Module("kernel32.dll")
    var find_next = kernel32.function[
        def (
            Int, Pointer[UInt8, MutAnyOrigin]
        ) thin abi("C") -> c_int
    ]("FindNextFileW")

    var pattern = WideString(String(path) + "\\*")
    var data = List[UInt8](length=FIND_BYTES, fill=0)
    var base = data.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()

    var search = kernel32.function[
        def (
            Pointer[UInt16, MutAnyOrigin], Pointer[UInt8, MutAnyOrigin]
        ) thin abi("C") -> Int
    ]("FindFirstFileW")(pattern.unsafe_ptr(), base)
    if search == 0 or search == -1:
        raise_last_error("FindFirstFileW(" + String(path) + ")")

    var entries = List[DirEntry]()
    while True:
        var name = from_wide(
            base.unsafe_offset(NAME_AT).unsafe_bitcast[UInt16]()
        )
        if name != "." and name != "..":
            var high = Int(
                base.unsafe_offset(SIZE_HIGH_AT).unsafe_bitcast[UInt32]()[]
            )
            var low = Int(
                base.unsafe_offset(SIZE_LOW_AT).unsafe_bitcast[UInt32]()[]
            )
            entries.append(
                DirEntry(
                    name^,
                    base.unsafe_offset(ATTRS_AT).unsafe_bitcast[UInt32]()[],
                    (high << 32) | low,
                    filetime_to_unix_ns(_read_filetime(base, WRITTEN_AT)),
                    filetime_to_unix_ns(_read_filetime(base, CREATED_AT)),
                )
            )
        if find_next(search, base) == 0:
            break

    # FindClose, not CloseHandle: a find handle is its own kind, and the
    # mismatch is the sort that only shows up under handle-leak testing.
    _ = kernel32.function[def (Int) thin abi("C") -> c_int]("FindClose")(search)

    var code = last_error()
    if Int(code) != _ERROR_NO_MORE_FILES and code != 0:
        raise Error(
            "FindNextFileW(" + String(path) + ") failed with error "
            + String(code)
        )
    return entries^


def full_path(path: StringSlice) raises -> String:
    """Resolves a path to a full, absolute one.

    Applies Windows' own rules -- including the per-drive current directory,
    which no POSIX-shaped path routine knows about.

    Args:
        path: A relative or absolute path.

    Returns:
        The absolute path.

    Raises:
        If the path cannot be resolved.
    """
    var kernel32 = Win32Module("kernel32.dll")
    var resolve = kernel32.function[
        def (
            Pointer[UInt16, MutAnyOrigin],
            UInt32,
            Pointer[UInt16, MutAnyOrigin],
            Int,
        ) thin abi("C") -> UInt32
    ]("GetFullPathNameW")

    var wide = WideString(path)
    var needed = resolve(
        wide.unsafe_ptr(),
        UInt32(0),
        Pointer[UInt16, MutAnyOrigin](unsafe_from_address=1),
        Int(0),
    )
    if needed == 0:
        raise_last_error("GetFullPathNameW(" + String(path) + ")")

    var buffer = List[UInt16](length=Int(needed) + 1, fill=0)
    var written = resolve(
        wide.unsafe_ptr(),
        needed + 1,
        buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        Int(0),
    )
    if written == 0:
        raise_last_error("GetFullPathNameW(" + String(path) + ")")
    return from_wide(
        buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](), Int(written)
    )


def temp_path() raises -> String:
    """The directory Windows designates for temporary files.

    Returns:
        The path, with its trailing backslash.

    Raises:
        If the query fails.
    """
    var buffer = List[UInt16](length=32768, fill=0)
    var written = Win32Module("kernel32.dll").function[
        def (UInt32, Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> UInt32
    ]("GetTempPath2W")(UInt32(32768), buffer.unsafe_ptr().unsafe_origin_cast[
        MutAnyOrigin
    ]())
    if written == 0:
        raise_last_error("GetTempPath2W")
    return from_wide(
        buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](), Int(written)
    )


def current_directory() raises -> String:
    """The process's current directory.

    Returns:
        The absolute path.

    Raises:
        If the query fails.
    """
    var buffer = List[UInt16](length=32768, fill=0)
    var written = Win32Module("kernel32.dll").function[
        def (UInt32, Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> UInt32
    ]("GetCurrentDirectoryW")(
        UInt32(32768), buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    )
    if written == 0:
        raise_last_error("GetCurrentDirectoryW")
    return from_wide(
        buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](), Int(written)
    )


def set_current_directory(path: StringSlice) raises:
    """Changes the process's current directory.

    Args:
        path: The directory to move to.

    Raises:
        If the directory does not exist or cannot be entered.
    """
    var wide = WideString(path)
    if (
        Win32Module("kernel32.dll").function[
            def (Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> c_int
        ]("SetCurrentDirectoryW")(wide.unsafe_ptr())
        == 0
    ):
        raise_last_error("SetCurrentDirectoryW(" + String(path) + ")")


def module_path() raises -> String:
    """The full path of the running executable.

    Returns:
        The .exe's path.

    Raises:
        If the query fails.
    """
    var buffer = List[UInt16](length=32768, fill=0)
    var written = Win32Module("kernel32.dll").function[
        def (Int, Pointer[UInt16, MutAnyOrigin], UInt32) thin abi("C") -> UInt32
    ]("GetModuleFileNameW")(
        Int(0),  # NULL means the process's own image
        buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        UInt32(32768),
    )
    if written == 0:
        raise_last_error("GetModuleFileNameW")
    return from_wide(
        buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](), Int(written)
    )


def create_directory(path: StringSlice) raises:
    """Creates a directory. The parent must already exist.

    Args:
        path: The directory to create.

    Raises:
        If it exists already or the parent does not.
    """
    var wide = WideString(path)
    if (
        Win32Module("kernel32.dll").function[
            def (Pointer[UInt16, MutAnyOrigin], Int) thin abi("C") -> c_int
        ]("CreateDirectoryW")(wide.unsafe_ptr(), Int(0))
        == 0
    ):
        raise_last_error("CreateDirectoryW(" + String(path) + ")")


def remove_directory(path: StringSlice) raises:
    """Removes an empty directory.

    Args:
        path: The directory to remove.

    Raises:
        If it is missing, not empty, or in use.
    """
    var wide = WideString(path)
    if (
        Win32Module("kernel32.dll").function[
            def (Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> c_int
        ]("RemoveDirectoryW")(wide.unsafe_ptr())
        == 0
    ):
        raise_last_error("RemoveDirectoryW(" + String(path) + ")")


def delete_file(path: StringSlice) raises:
    """Deletes a file.

    Args:
        path: The file to delete.

    Raises:
        If it is missing, read-only, or open elsewhere.
    """
    var wide = WideString(path)
    if (
        Win32Module("kernel32.dll").function[
            def (Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> c_int
        ]("DeleteFileW")(wide.unsafe_ptr())
        == 0
    ):
        raise_last_error("DeleteFileW(" + String(path) + ")")


def copy_file(source: StringSlice, dest: StringSlice, overwrite: Bool = False) raises:
    """Copies a file, preserving its attributes.

    Args:
        source: The file to copy.
        dest: Where to put the copy.
        overwrite: Whether to replace an existing destination.

    Raises:
        If the copy fails.
    """
    var from_wide_path = WideString(source)
    var to_wide_path = WideString(dest)
    if (
        Win32Module("kernel32.dll").function[
            def (
                Pointer[UInt16, MutAnyOrigin],
                Pointer[UInt16, MutAnyOrigin],
                c_int,
            ) thin abi("C") -> c_int
        ]("CopyFileW")(
            from_wide_path.unsafe_ptr(),
            to_wide_path.unsafe_ptr(),
            c_int(0) if overwrite else c_int(1),  # bFailIfExists
        )
        == 0
    ):
        raise_last_error("CopyFileW(" + String(source) + ")")


def move_file(source: StringSlice, dest: StringSlice, overwrite: Bool = True) raises:
    """Moves or renames a file, across volumes if necessary.

    Args:
        source: The file to move.
        dest: Where it should end up.
        overwrite: Whether to replace an existing destination.

    Raises:
        If the move fails.
    """
    var from_wide_path = WideString(source)
    var to_wide_path = WideString(dest)
    # MOVEFILE_COPY_ALLOWED is what lets this cross volumes at all.
    comptime COPY_ALLOWED = UInt32(winkb_constant["MOVEFILE_COPY_ALLOWED"]())
    comptime REPLACE = UInt32(winkb_constant["MOVEFILE_REPLACE_EXISTING"]())
    var flags = COPY_ALLOWED | (REPLACE if overwrite else UInt32(0))
    if (
        Win32Module("kernel32.dll").function[
            def (
                Pointer[UInt16, MutAnyOrigin],
                Pointer[UInt16, MutAnyOrigin],
                UInt32,
            ) thin abi("C") -> c_int
        ]("MoveFileExW")(
            from_wide_path.unsafe_ptr(), to_wide_path.unsafe_ptr(), flags
        )
        == 0
    ):
        raise_last_error("MoveFileExW(" + String(source) + ")")


def disk_free_space(path: StringSlice) raises -> Tuple[Int, Int]:
    """Free and total bytes on the volume containing a path.

    The free figure honours any per-user quota, so it is what this process can
    actually write, not what the volume happens to have spare.

    Args:
        path: Any path on the volume.

    Returns:
        The free bytes available to this user, and the volume's total bytes.

    Raises:
        If the query fails.
    """
    var wide = WideString(path)
    var free_to_caller = UInt64(0)
    var total = UInt64(0)
    if (
        Win32Module("kernel32.dll").function[
            def (
                Pointer[UInt16, MutAnyOrigin],
                Pointer[UInt64, MutAnyOrigin],
                Pointer[UInt64, MutAnyOrigin],
                Int,
            ) thin abi("C") -> c_int
        ]("GetDiskFreeSpaceExW")(
            wide.unsafe_ptr(),
            Pointer(to=free_to_caller).unsafe_origin_cast[MutAnyOrigin](),
            Pointer(to=total).unsafe_origin_cast[MutAnyOrigin](),
            Int(0),  # total free, ignoring quota; not reported
        )
        == 0
    ):
        raise_last_error("GetDiskFreeSpaceExW(" + String(path) + ")")
    return (Int(free_to_caller), Int(total))


def read_file(path: StringSlice) raises -> List[UInt8]:
    """Reads a whole file as bytes.

    Bytes, exactly as stored: `CreateFileW` has no text mode, so nothing
    translates line endings on the way in or out. That matters for anything
    that is not text -- an image written through a translating writer has
    every 0x0A turned into 0x0D 0x0A and is silently corrupt.

    Args:
        path: The file to read.

    Returns:
        The file's contents.

    Raises:
        If the file cannot be opened or read.
    """
    var wide = WideString(path)
    var kernel32 = Win32Module("kernel32.dll")

    var raw = kernel32.function[
        def (
            Pointer[UInt16, MutAnyOrigin], UInt32, UInt32, Int, UInt32, UInt32, Int
        ) thin abi("C") -> Int
    ]("CreateFileW")(
        wide.unsafe_ptr(),
        UInt32(winkb_constant["GENERIC_READ"]() & 0xFFFFFFFF),
        UInt32(winkb_constant["FILE_SHARE_READ"]()),
        Int(0),  # default security
        UInt32(winkb_constant["OPEN_EXISTING"]()),
        UInt32(winkb_constant["FILE_ATTRIBUTE_NORMAL"]()),
        Int(0),  # no template
    )
    var handle = Handle(adopt=raw)
    if not handle:
        raise_last_error("CreateFileW(" + String(path) + ")")

    var size = UInt64(0)
    if (
        kernel32.function[
            def (Int, Pointer[UInt64, MutAnyOrigin]) thin abi("C") -> c_int
        ]("GetFileSizeEx")(
            handle.value(), Pointer(to=size).unsafe_origin_cast[MutAnyOrigin]()
        )
        == 0
    ):
        raise_last_error("GetFileSizeEx(" + String(path) + ")")

    var bytes = List[UInt8](length=Int(size), fill=0)
    if size == 0:
        return bytes^

    var read = kernel32.function[
        def (
            Int, Pointer[UInt8, MutAnyOrigin], UInt32, Pointer[UInt32, MutAnyOrigin], Int
        ) thin abi("C") -> c_int
    ]("ReadFile")

    # ReadFile is not obliged to return everything at once, so loop until the
    # file is exhausted rather than trusting one call.
    var done = 0
    while done < Int(size):
        var got = UInt32(0)
        if (
            read(
                handle.value(),
                bytes.unsafe_ptr()
                .unsafe_offset(done)
                .unsafe_origin_cast[MutAnyOrigin](),
                UInt32(Int(size) - done),
                Pointer(to=got).unsafe_origin_cast[MutAnyOrigin](),
                Int(0),
            )
            == 0
        ):
            raise_last_error("ReadFile(" + String(path) + ")")
        if got == 0:
            break
        done += Int(got)
    return bytes^


def write_file(path: StringSlice, data: Span[UInt8, _]) raises:
    """Writes bytes to a file, replacing anything already there.

    Bytes, exactly as given -- see `read_file` for why that is worth saying.

    Args:
        path: The file to write.
        data: The bytes to write.

    Raises:
        If the file cannot be created or written.

    Example:

    ```mojo
    from std.windows import write_file

    def main() raises:
        var bytes = List[UInt8](length=4, fill=65)
        write_file("aaaa.txt", Span(bytes))
    ```
    """
    var wide = WideString(path)
    var kernel32 = Win32Module("kernel32.dll")

    var raw = kernel32.function[
        def (
            Pointer[UInt16, MutAnyOrigin], UInt32, UInt32, Int, UInt32, UInt32, Int
        ) thin abi("C") -> Int
    ]("CreateFileW")(
        wide.unsafe_ptr(),
        UInt32(winkb_constant["GENERIC_WRITE"]() & 0xFFFFFFFF),
        UInt32(0),  # exclusive while we write
        Int(0),
        UInt32(winkb_constant["CREATE_ALWAYS"]()),
        UInt32(winkb_constant["FILE_ATTRIBUTE_NORMAL"]()),
        Int(0),
    )
    var handle = Handle(adopt=raw)
    if not handle:
        raise_last_error("CreateFileW(" + String(path) + ")")

    var write = kernel32.function[
        def (
            Int, Pointer[UInt8, MutAnyOrigin], UInt32, Pointer[UInt32, MutAnyOrigin], Int
        ) thin abi("C") -> c_int
    ]("WriteFile")

    # Same reasoning as the read loop: a short write is legal.
    var done = 0
    while done < len(data):
        var put = UInt32(0)
        if (
            write(
                handle.value(),
                data.unsafe_ptr()
                .unsafe_offset(done)
                .unsafe_mut_cast[True]()
                .unsafe_origin_cast[MutAnyOrigin](),
                UInt32(len(data) - done),
                Pointer(to=put).unsafe_origin_cast[MutAnyOrigin](),
                Int(0),
            )
            == 0
        ):
            raise_last_error("WriteFile(" + String(path) + ")")
        if put == 0:
            raise Error("WriteFile(" + String(path) + ") wrote nothing")
        done += Int(put)
