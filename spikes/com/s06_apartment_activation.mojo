# An apartment held for a scope, and a real coclass activated inside it.
#
# `with Apartment():` is CoInitializeEx/CoUninitialize balanced by the scope,
# STA by default. Inside it, co_create activates the shell's FileOpenDialog
# -- a genuine out-of-tree COM server -- and typed calls drive it headlessly:
# set a title, read the options word back. No UI is shown.
#
# The CLSID literal is deliberate and documented: the metadata's guid-kind
# constants carry no values yet (the recorded WRASM gap), so the one GUID a
# program needs is written once, at the activation site, next to the name.

from std.memory import Pointer
from std.sys._com import ComPtr
from std.sys.com import Apartment, Com, co_create


def main() raises:
    with Apartment():
        let dialog = co_create[
            "dc1c5a9c-e88a-4dde-a5a1-60f82a20aef7",  # CLSID_FileOpenDialog
            "IFileDialog",
        ]()
        print("FileOpenDialog activated:", Bool(dialog))

        let d = Com[StaticString("IFileDialog")](of=dialog)

        # SetTitle takes a PCWSTR: UTF-16, NUL-terminated, pointer-width 8.
        var title = List[UInt16]()
        for ch in "Open Project".codepoints():
            title.append(UInt16(Int(ch)))
        title.append(0)
        _ = d.SetTitle(
            title.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
        )
        print("SetTitle: ok (typed, slot from metadata)")

        # GetOptions: the out-param pattern, u32* at width 8.
        var options = UInt32(0)
        _ = d.GetOptions(
            Pointer(to=options).unsafe_origin_cast[MutAnyOrigin]()
        )
        print("GetOptions =", options, "(nonzero expected: defaults are set)")
        if options == 0:
            raise Error("options came back empty")

        # dialog Releases at scope exit; the apartment closes after it.
    print("apartment closed, object released")
    print("S06 PASS")
