# `fn` handed to Windows as a callback, the revival's proof.
#
# EnumWindows calls back once per top-level window on the callee's terms: C
# ABI, no error channel, no captured state -- exactly the contract `fn`
# declares. State travels the honest way, through the LPARAM, as an address
# the callback dereferences. A def with captures could not be passed here at
# all, which is the point of having the keyword.

from std.memory import Pointer
from std.sys._com import com_addr
from std.sys._win32 import Win32Module


fn count_window(hwnd: Int, lparam: Int) -> Int32:
    # lparam is the address of the caller's counter.
    var counter = Pointer[Int, MutAnyOrigin](unsafe_from_address=lparam)
    counter[] += 1
    return 1  # continue enumeration


def main() raises:
    let enum_windows = Win32Module("user32.dll").function[
        def (
            def (Int, Int) thin abi("C") -> Int32,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> Int32
    ]("EnumWindows")

    var count: Int = 0
    let ok = enum_windows(count_window, com_addr(count))
    print("EnumWindows returned", ok, "and visited", count, "windows")
    if ok == 0 or count == 0:
        raise Error("enumeration failed or found nothing")
    print("S07 PASS")
