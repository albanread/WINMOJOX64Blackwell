# The C3 milestone: a COM object Mojo IMPLEMENTS, registered with Windows.
#
# IDropTarget is the drag-and-drop sink Explorer calls into when files are
# dropped on a window. Here Mojo builds one -- four methods plus IUnknown --
# and RegisterDragDrop hands it to OLE, which AddRefs it and holds it. The
# object's four callbacks are `fn`s; its state (a drop counter and the last
# key-state) lives in the block ComClassBuilder allocated.
#
# There is no interactive desktop in the test environment, so rather than
# wait for a human to drag a file, the object's own IDropTarget vtable is
# invoked directly through the metadata slots -- exactly what OLE's proxy
# does on a real drop -- and the state it accumulates is checked. The
# REGISTRATION is real: RegisterDragDrop succeeds against a live HWND, holds
# a reference (provable through the refcount), and RevokeDragDrop releases it.
#
# This is the executable specification the `class` keyword's synthesis
# automates: everything ComClassBuilder does by hand here, the compiler will
# emit from a `class DropTarget(IDropTarget):` declaration.

from std.memory import Pointer, OpaquePointer
from std.sys._com import ComPtr, com_method_of
from std.sys._win32 import Win32Module
from std.sys.com import (
    Apartment,
    ComClassBuilder,
    com_class_state,
)

comptime DROPEFFECT_NONE = UInt32(0)
comptime DROPEFFECT_COPY = UInt32(1)

# State layout, by word index into com_class_state:
comptime ST_DROPS = 0  # how many Drops arrived
comptime ST_ENTERS = 1  # how many DragEnters
comptime ST_LASTKEY = 2  # last grfKeyState seen


fn dt_drag_enter(
    this: Int, data: Int, key: UInt32, pt: Int, effect: Int
) -> Int32:
    var st = com_class_state(this)
    st.unsafe_offset(ST_ENTERS)[] += 1
    st.unsafe_offset(ST_LASTKEY)[] = Int(key)
    # Accept a copy.
    Pointer[UInt32, MutAnyOrigin](unsafe_from_address=effect)[] = DROPEFFECT_COPY
    return 0


fn dt_drag_over(this: Int, key: UInt32, pt: Int, effect: Int) -> Int32:
    Pointer[UInt32, MutAnyOrigin](unsafe_from_address=effect)[] = DROPEFFECT_COPY
    return 0


fn dt_drag_leave(this: Int) -> Int32:
    return 0


fn dt_drop(
    this: Int, data: Int, key: UInt32, pt: Int, effect: Int
) -> Int32:
    var st = com_class_state(this)
    st.unsafe_offset(ST_DROPS)[] += 1
    Pointer[UInt32, MutAnyOrigin](unsafe_from_address=effect)[] = DROPEFFECT_COPY
    return 0


def build_target() raises -> ComPtr[StaticString("IDropTarget")]:
    var b = ComClassBuilder[StaticString("IDropTarget")]()
    b.slot[
        "DragEnter", def (Int, Int, UInt32, Int, Int) thin abi("C") -> Int32
    ](dt_drag_enter)
    b.slot["DragOver", def (Int, UInt32, Int, Int) thin abi("C") -> Int32](
        dt_drag_over
    )
    b.slot["DragLeave", def (Int) thin abi("C") -> Int32](dt_drag_leave)
    b.slot["Drop", def (Int, Int, UInt32, Int, Int) thin abi("C") -> Int32](
        dt_drop
    )
    return b^.finish(state_words=3)


def refcount(p: ComPtr) -> UInt32:
    let up = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> UInt32,
        "IUnknown",
        "AddRef",
    ](p.interface())(p.interface())
    _ = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> UInt32,
        "IUnknown",
        "Release",
    ](p.interface())(p.interface())
    return up - 1


def make_hidden_window() raises -> Int:
    let user32 = Win32Module("user32.dll")
    let kernel32 = Win32Module("kernel32.dll")
    let hinst = kernel32.function[def (Int) thin abi("C") -> Int](
        "GetModuleHandleW"
    )(0)
    # HWND_MESSAGE parent (-3) makes a message-only window: no display needed,
    # and RegisterDragDrop is happy with it.
    var name = List[UInt16]()
    for ch in "STATIC".codepoints():
        name.append(UInt16(Int(ch)))
    name.append(0)
    let hwnd = user32.function[
        def (
            UInt32, Int, Int, UInt32, Int32, Int32, Int32, Int32, Int, Int,
            Int, Int,
        ) thin abi("C") -> Int
    ]("CreateWindowExW")(
        UInt32(0),
        Int(name.unsafe_ptr()),
        0,
        UInt32(0),
        0, 0, 0, 0,
        -3,  # HWND_MESSAGE
        0,
        hinst,
        0,
    )
    if hwnd == 0:
        raise Error("CreateWindowExW failed")
    return hwnd


def main() raises:
    with Apartment(ole=True):
        let hwnd = make_hidden_window()

        let target = build_target()
        print("target built, refcount =", refcount(target), "(expect 1)")

        # Register with OLE. It AddRefs and holds the object.
        let ole32 = Win32Module("ole32.dll")
        let reg = ole32.function[
            def (Int, Int) thin abi("C") -> Int32
        ]("RegisterDragDrop")(hwnd, target.address())
        # RegisterDragDrop needs the window's thread to have OLE; it does.
        print("RegisterDragDrop hr =", reg, "(expect 0)")
        if reg != 0:
            raise Error("RegisterDragDrop failed")
        print("registered, refcount =", refcount(target),
              "(expect 2: ours + OLE's)")
        if refcount(target) != 2:
            raise Error("OLE did not hold a reference")

        # Simulate what OLE's proxy does on a real drop: drive the object's
        # own vtable through the metadata slots. A POINTL is 8 bytes, passed
        # by value in a register on Win64.
        var effect = UInt32(0)
        var pt: Int = 0  # POINTL {0,0}
        var enter = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], Int, UInt32, Int,
                Pointer[UInt32, MutAnyOrigin],
            ) thin abi("C") -> Int32,
            "IDropTarget",
            "DragEnter",
        ](target.interface())(
            target.interface(), 0, UInt32(0x8),  # MK_CONTROL
            pt, Pointer(to=effect).unsafe_origin_cast[MutAnyOrigin](),
        )
        print("DragEnter hr =", enter, "effect =", effect,
              "(expect 0, 1=COPY)")

        var drop_effect = UInt32(0)
        var drop = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], Int, UInt32, Int,
                Pointer[UInt32, MutAnyOrigin],
            ) thin abi("C") -> Int32,
            "IDropTarget",
            "Drop",
        ](target.interface())(
            target.interface(), 0, UInt32(0x8), pt,
            Pointer(to=drop_effect).unsafe_origin_cast[MutAnyOrigin](),
        )
        print("Drop hr =", drop, "effect =", drop_effect)

        # The state the callbacks accumulated, read from the object's block.
        var st = com_class_state(target.address())
        print("state: enters =", st.unsafe_offset(0 + 1)[],
              " drops =", st.unsafe_offset(0)[],
              " lastkey = 0x", String(st.unsafe_offset(2)[]))
        if st.unsafe_offset(1)[] != 1 or st.unsafe_offset(0)[] != 1:
            raise Error("callbacks did not run against object state")
        if st.unsafe_offset(2)[] != 8:
            raise Error("key state did not reach the callback")
        if effect != 1 or drop_effect != 1:
            raise Error("effect out-param not written")

        # Revoke: OLE releases its reference.
        _ = ole32.function[def (Int) thin abi("C") -> Int32](
            "RevokeDragDrop"
        )(hwnd)
        print("revoked, refcount =", refcount(target), "(expect 1)")
        if refcount(target) != 1:
            raise Error("RevokeDragDrop did not release")

        # target's ComPtr Releases at scope exit, freeing the object.
    print("S10 PASS -- Mojo implemented a COM object, Windows held it")
