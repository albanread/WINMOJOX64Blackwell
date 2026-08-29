# The COM-class pattern in pure Mojo -- the desugar target of the `class`
# keyword, and the escape hatch that outlives it.
#
# A COM class is an ordinary struct of state with raising methods, plus a
# factory that wires each method into its metadata slot through com_trampN.
# The trampoline recovers the struct from the object's block, forwards the
# call, and turns a raise into an HRESULT -- so the method reads like Mojo and
# dispatches like COM. finish_state moves the struct into the object, which
# owns it until Release hits zero.
#
# Compare s10: the same object, there built from raw fn pointers and manual
# vtable words. This is what `class DropTarget(IDropTarget):` compiles to.
from std.memory import Pointer, OpaquePointer
from std.sys._com import ComPtr, com_method_of
from std.sys.com import (
    ComClassBuilder, com_tramp0, com_tramp3, com_tramp4,
)

comptime DROPEFFECT_COPY = UInt32(1)


@fieldwise_init
struct DropTarget(Copyable, Movable):
    var enters: Int
    var drops: Int
    var lastkey: UInt32

    def DragEnter(mut self, data: Int, key: UInt32, pt: Int, effect: Int) raises:
        self.enters += 1
        self.lastkey = key
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=effect)[] = DROPEFFECT_COPY

    def DragOver(mut self, key: UInt32, pt: Int, effect: Int) raises:
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=effect)[] = DROPEFFECT_COPY

    def DragLeave(mut self) raises:
        pass

    def Drop(mut self, data: Int, key: UInt32, pt: Int, effect: Int) raises:
        self.drops += 1
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=effect)[] = DROPEFFECT_COPY


def make_drop_target() raises -> ComPtr[StaticString("IDropTarget")]:
    var b = ComClassBuilder[StaticString("IDropTarget")]()
    b.slot["DragEnter"](com_tramp4[DropTarget.DragEnter])
    b.slot["DragOver"](com_tramp3[DropTarget.DragOver])
    b.slot["DragLeave"](com_tramp0[DropTarget.DragLeave])
    b.slot["Drop"](com_tramp4[DropTarget.Drop])
    return b^.finish_state(DropTarget(0, 0, 0))


def main() raises:
    var t = make_drop_target()
    var effect = UInt32(0)
    var enter = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin], Int, UInt32, Int,
             Pointer[UInt32, MutAnyOrigin]) thin abi("C") -> Int32,
        "IDropTarget", "DragEnter",
    ](t.interface())(t.interface(), 0, UInt32(8), 0,
        Pointer(to=effect).unsafe_origin_cast[MutAnyOrigin]())
    var de = UInt32(0)
    var drop = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin], Int, UInt32, Int,
             Pointer[UInt32, MutAnyOrigin]) thin abi("C") -> Int32,
        "IDropTarget", "Drop",
    ](t.interface())(t.interface(), 0, UInt32(8), 0,
        Pointer(to=de).unsafe_origin_cast[MutAnyOrigin]())
    print("DragEnter hr", enter, "effect", effect, " Drop hr", drop, "effect", de)
    if enter != 0 or drop != 0 or effect != 1 or de != 1:
        raise Error("dispatch failed")
    print("S11 PASS -- a COM class in pure Mojo, methods reached via com_trampN")
