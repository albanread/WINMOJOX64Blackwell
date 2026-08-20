# ===----------------------------------------------------------------------=== #
# Shell services: known folders, environment expansion, message boxes.
#
# `SHGetKnownFolderPath` is the only correct way to find the Desktop or
# Documents. The environment variables people reach for instead (%USERPROFILE%
# and friends) are wrong the moment a folder has been redirected, which on any
# domain-joined or OneDrive-backed machine is most of them.
#
# The KNOWNFOLDERID GUIDs are written out below rather than queried from winkb,
# because winkb records the *names* of guid-kind constants but not their bytes
# -- `SELECT value_text FROM constants WHERE constant_name = 'FOLDERID_Documents'`
# returns NULL. Worth fixing at the knowledge-base end; until then these are
# transcribed from shlobj.h, in the same textual form the COM code uses for
# IIDs so that one GUID parser serves both.
# ===----------------------------------------------------------------------=== #

from std.ffi import c_int
from std.memory import Pointer
from std.sys._com import _guid_bytes
from std.sys._win32 import Win32Module
from std.windows.core import (
    WideString,
    from_wide,
    raise_if_failed,
    raise_last_error,
)


@fieldwise_init
struct KnownFolder(ImplicitlyCopyable, Movable):
    """A KNOWNFOLDERID, naming one of the shell's well-known directories.

    Use the constants on this type rather than constructing one.
    """

    var id: StaticString
    """The folder's GUID, in the usual textual form."""

    comptime DESKTOP = Self("B4BFCC3A-DB2C-424C-B029-7FE99A87C641")
    """The user's Desktop folder."""
    comptime DOCUMENTS = Self("FDD39AD0-238F-46AF-ADB4-6C85480369C7")
    """The user's Documents folder."""
    comptime DOWNLOADS = Self("374DE290-123F-4565-9164-39C4925E467B")
    """The user's Downloads folder."""
    comptime PICTURES = Self("33E28130-4E1E-4676-835A-98395C3BC3BB")
    """The user's Pictures folder."""
    comptime MUSIC = Self("4BD8D571-6D19-48D3-BE97-422220080E43")
    """The user's Music folder."""
    comptime VIDEOS = Self("18989B1D-99B5-455B-841C-AB7C74E4DDFC")
    """The user's Videos folder."""
    comptime PROFILE = Self("5E6C858F-0E22-4760-9AFE-EA3317B67173")
    """The user's profile folder, e.g. `C:\\Users\\alban`."""
    comptime LOCAL_APP_DATA = Self("F1B32785-6FBA-4FCF-9D55-7B8E7F157091")
    """The machine-local per-user application data folder."""
    comptime ROAMING_APP_DATA = Self("3EB685DB-65F9-4CF6-A03A-E3EF65729F3D")
    """The roaming per-user application data folder."""
    comptime PROGRAM_DATA = Self("62AB5D82-FDC1-4DC3-A9DD-070D1D495D97")
    """The machine-wide application data folder."""
    comptime PROGRAM_FILES = Self("905E63B6-C1BF-494E-B29C-65B732D3D21A")
    """The Program Files folder for the process's own architecture."""
    comptime WINDOWS = Self("F38BF404-1D43-42F2-9305-67DE0B28FC23")
    """The Windows directory."""
    comptime SYSTEM = Self("1AC14E77-02E7-4E5D-B744-2EB1AE5198B7")
    """The System32 directory."""
    comptime FONTS = Self("FD228CB7-AE11-4AE3-864C-16F3910AB8FE")
    """The Fonts directory."""


def known_folder(folder: KnownFolder) raises -> String:
    """The path of one of the shell's well-known folders.

    Correct where `%USERPROFILE%`-style guesswork is not: this follows folder
    redirection, so it finds a Documents folder that lives on OneDrive or on a
    network share.

    Args:
        folder: Which folder, e.g. `KnownFolder.DOCUMENTS`.

    Returns:
        The folder's full path.

    Raises:
        If the folder is not present on this machine.

    Example:

    ```mojo
    from std.windows import KnownFolder, known_folder

    def main() raises:
        print(known_folder(KnownFolder.LOCAL_APP_DATA))
    ```
    """
    var shell32 = Win32Module("shell32.dll")
    if not shell32:
        raise Error("cannot load shell32.dll")

    var guid = _guid_bytes(folder.id)
    var path_addr = Int(0)
    raise_if_failed(
        shell32.function[
            def (
                Pointer[UInt8, MutAnyOrigin],
                UInt32,
                Int,
                Pointer[Int, MutAnyOrigin],
            ) thin abi("C") -> Int32
        ]("SHGetKnownFolderPath")(
            guid.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            UInt32(0),  # no KF_FLAG_*: return the path as it is configured
            Int(0),  # current user's token
            Pointer(to=path_addr).unsafe_origin_cast[MutAnyOrigin](),
        ),
        "SHGetKnownFolderPath",
    )

    var path = from_wide(
        Pointer[UInt16, MutAnyOrigin](unsafe_from_address=path_addr)
    )

    # The shell allocated this with CoTaskMemAlloc, so only CoTaskMemFree will
    # do -- free() would be a heap mismatch, silent until it isn't.
    var ole32 = Win32Module("ole32.dll")
    if ole32:
        try:
            _ = ole32.function[def (Int) thin abi("C") -> None]("CoTaskMemFree")(
                path_addr
            )
        except:
            pass
    return path^


def expand_environment(text: StringSlice) raises -> String:
    """Expands `%NAME%` references against the process environment.

    Args:
        text: Text that may contain `%NAME%` references.

    Returns:
        The text with every reference replaced. Unknown names are left as
        written, which is what Windows itself does.

    Raises:
        If the expansion call fails.

    Example:

    ```mojo
    from std.windows import expand_environment

    def main() raises:
        print(expand_environment("%SystemRoot%"))
    ```
    """
    var kernel32 = Win32Module("kernel32.dll")
    var expand = kernel32.function[
        def (
            Pointer[UInt16, MutAnyOrigin],
            Pointer[UInt16, MutAnyOrigin],
            UInt32,
        ) thin abi("C") -> UInt32
    ]("ExpandEnvironmentStringsW")

    var source = WideString(text)
    # The size call counts code units including the terminator; 32767 is the
    # documented ceiling, so a second failure is a real error, not a retry.
    var needed = expand(
        source.unsafe_ptr(),
        Pointer[UInt16, MutAnyOrigin](unsafe_from_address=1),
        UInt32(0),
    )
    if needed == 0:
        raise_last_error("ExpandEnvironmentStringsW")

    var buffer = List[UInt16](length=Int(needed) + 1, fill=0)
    var written = expand(
        source.unsafe_ptr(),
        buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        needed + 1,
    )
    if written == 0:
        raise_last_error("ExpandEnvironmentStringsW")
    return from_wide(buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]())


def message_box(
    text: StringSlice, title: StringSlice = "Mojo", flags: UInt32 = 0
) raises -> Int:
    """Shows a modal message box and returns which button was pressed.

    Args:
        text: The message body.
        title: The window caption.
        flags: `MB_*` flags, e.g. `1` for OK/Cancel or `0x30` for a warning
            icon. Zero gives a plain OK box.

    Returns:
        The `IDOK`/`IDCANCEL`/... code of the button pressed.

    Raises:
        If user32.dll cannot be loaded.

    Example:

    ```mojo
    from std.windows import message_box

    def main() raises:
        _ = message_box("Built on Windows ARM64.", "Mojo")
    ```
    """
    var user32 = Win32Module("user32.dll")
    if not user32:
        raise Error("cannot load user32.dll")
    var body = WideString(text)
    var caption = WideString(title)
    return Int(
        user32.function[
            def (
                Int,
                Pointer[UInt16, MutAnyOrigin],
                Pointer[UInt16, MutAnyOrigin],
                UInt32,
            ) thin abi("C") -> c_int
        ]("MessageBoxW")(
            Int(0), body.unsafe_ptr(), caption.unsafe_ptr(), flags
        )
    )
