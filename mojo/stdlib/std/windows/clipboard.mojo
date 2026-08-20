# ===----------------------------------------------------------------------=== #
# The clipboard.
#
# The clipboard is a global lock. `OpenClipboard` can fail simply because
# another program is mid-copy, so both functions here retry briefly rather than
# raising on the first refusal -- a clipboard call that fails once in fifty for
# no reason the caller can act on is worse than a short wait.
#
# Ownership is the other half. `SetClipboardData` takes ownership of the moved
# global memory block, so the block must NOT be freed afterwards; `GlobalFree`
# on it is a use-after-free the moment anything pastes. `GetClipboardData`
# returns a handle the clipboard still owns, so its contents must be copied out
# before `CloseClipboard`.
# ===----------------------------------------------------------------------=== #

from std.ffi import c_int
from std.memory import Pointer
from std.sys._win32 import Win32Module
from std.sys._winkb import winkb_constant
from std.windows.core import WideString, from_wide, raise_last_error

comptime _CF_UNICODETEXT = UInt32(winkb_constant["CF_UNICODETEXT"]())
comptime _GMEM_MOVEABLE = UInt32(winkb_constant["GMEM_MOVEABLE"]())


def _open_clipboard() raises:
    """Opens the clipboard, retrying while another program holds it.

    Raises:
        If it is still unavailable after the retries.
    """
    var user32 = Win32Module("user32.dll")
    if not user32:
        raise Error("cannot load user32.dll")
    var open_it = user32.function[def (Int) thin abi("C") -> c_int](
        "OpenClipboard"
    )
    var sleep = Win32Module("kernel32.dll").function[
        def (UInt32) thin abi("C") -> None
    ]("Sleep")

    for _ in range(10):
        if open_it(Int(0)) != 0:
            return
        _ = sleep(UInt32(20))
    raise_last_error("OpenClipboard")


def get_clipboard_text() raises -> String:
    """The clipboard's contents as text.

    Returns:
        The text, or an empty string if the clipboard holds something else.

    Raises:
        If the clipboard cannot be opened.

    Example:

    ```mojo
    from std.windows import get_clipboard_text

    def main() raises:
        print(get_clipboard_text())
    ```
    """
    var user32 = Win32Module("user32.dll")
    var kernel32 = Win32Module("kernel32.dll")
    _open_clipboard()

    var handle = user32.function[def (UInt32) thin abi("C") -> Int](
        "GetClipboardData"
    )(_CF_UNICODETEXT)
    var text = String("")
    if handle != 0:
        # The clipboard still owns this block; lock it, copy out, unlock.
        var address = kernel32.function[def (Int) thin abi("C") -> Int](
            "GlobalLock"
        )(handle)
        if address != 0:
            text = from_wide(
                Pointer[UInt16, MutAnyOrigin](unsafe_from_address=address)
            )
            _ = kernel32.function[def (Int) thin abi("C") -> c_int](
                "GlobalUnlock"
            )(handle)

    _ = user32.function[def () thin abi("C") -> c_int]("CloseClipboard")()
    return text^


def set_clipboard_text(text: StringSlice) raises:
    """Replaces the clipboard's contents with text.

    Args:
        text: The text to put on the clipboard.

    Raises:
        If the clipboard cannot be opened or the memory cannot be allocated.

    Example:

    ```mojo
    from std.windows import set_clipboard_text

    def main() raises:
        set_clipboard_text("café über 🐉")
    ```
    """
    var user32 = Win32Module("user32.dll")
    var kernel32 = Win32Module("kernel32.dll")

    var wide = WideString(text)
    var bytes = (len(wide) + 1) * 2
    var block = kernel32.function[def (UInt32, Int) thin abi("C") -> Int](
        "GlobalAlloc"
    )(_GMEM_MOVEABLE, bytes)
    if block == 0:
        raise_last_error("GlobalAlloc")

    var address = kernel32.function[def (Int) thin abi("C") -> Int]("GlobalLock")(
        block
    )
    if address == 0:
        _ = kernel32.function[def (Int) thin abi("C") -> Int]("GlobalFree")(block)
        raise_last_error("GlobalLock")

    var destination = Pointer[UInt16, MutAnyOrigin](unsafe_from_address=address)
    var source = wide.unsafe_ptr()
    for i in range(len(wide) + 1):
        destination.unsafe_offset(i)[] = source.unsafe_offset(i)[]
    _ = kernel32.function[def (Int) thin abi("C") -> c_int]("GlobalUnlock")(block)

    _open_clipboard()
    _ = user32.function[def () thin abi("C") -> c_int]("EmptyClipboard")()
    var stored = user32.function[def (UInt32, Int) thin abi("C") -> Int](
        "SetClipboardData"
    )(_CF_UNICODETEXT, block)
    _ = user32.function[def () thin abi("C") -> c_int]("CloseClipboard")()

    if stored == 0:
        # Only now is the block still ours to free: a successful
        # SetClipboardData transfers ownership and freeing it would be a
        # use-after-free for whoever pastes next.
        _ = kernel32.function[def (Int) thin abi("C") -> Int]("GlobalFree")(block)
        raise Error("SetClipboardData failed")
