from std.sys._winkb import (
    winkb_struct_size,
    winkb_struct_align,
    winkb_field_offset,
    winkb_vtable_index,
    winkb_function_dll,
)


# The declaration states names; the compiler supplies the facts and checks them.
@fieldwise_init
struct RECT(Defaultable, TrivialRegisterPassable):
    var left: Int32
    var top: Int32
    var right: Int32
    var bottom: Int32

    def __init__(out self):
        self.left = 0
        self.top = 0
        self.right = 0
        self.bottom = 0


def main():
    print("RECT size   =", winkb_struct_size["RECT"]())
    print("RECT align  =", winkb_struct_align["RECT"]())
    print("RECT.bottom @", winkb_field_offset["RECT", "bottom"]())
    print("OVERLAPPED  =", winkb_struct_size["OVERLAPPED"]())
    print("hEvent      @", winkb_field_offset["OVERLAPPED", "hEvent"]())
    print("GetCursorPos in", winkb_function_dll["GetCursorPos"]())
    print("IUnknown::Release slot", winkb_vtable_index["IUnknown", "Release"]())

    # The layout of the Mojo declaration above is checked against Windows
    # itself. Nobody wrote 16 here; the metadata did.
    comptime assert (
        winkb_struct_size["RECT"]() == 16
    ), "RECT does not match the Win32 layout"
