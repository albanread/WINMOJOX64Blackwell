# The `class` keyword: the point of the whole exercise.
#
# Compare s10 (raw fn pointers, manual vtable words) and s11 (struct plus a
# hand-written ComClassBuilder factory). This is the same COM object, written
# the way a Windows programmer should write one: name the interface, declare
# the state, write the methods. The compiler generates the rest -- the
# @fieldwise_init struct, the aliased imports, and the into_com() factory that
# fills each metadata slot through the arity-matched trampoline.
#
# Run with MOJO_DEBUG_COM_CLASS=1 to see exactly what it desugars to; the
# generated source is ordinary Mojo, and s11 is that source written by hand.
from std.memory import Pointer, OpaquePointer
from std.sys._com import ComPtr, com_method_of

comptime DROPEFFECT_COPY = UInt32(1)


class DropTarget(IDropTarget):
    var drops: Int
    var enters: Int

    def DragEnter(mut self, data: Int, key: UInt32, pt: Int, effect: Int) raises:
        self.enters += 1
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=effect)[] = DROPEFFECT_COPY

    def DragOver(mut self, key: UInt32, pt: Int, effect: Int) raises:
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=effect)[] = DROPEFFECT_COPY

    def DragLeave(mut self) raises:
        pass

    def Drop(mut self, data: Int, key: UInt32, pt: Int, effect: Int) raises:
        self.drops += 1
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=effect)[] = DROPEFFECT_COPY


def main() raises:
    var obj = DropTarget(0, 0).into_com()
    print("class DropTarget compiled and built a COM object:", Bool(obj))

    var effect = UInt32(0)
    var hr = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin], Int, UInt32, Int,
             Pointer[UInt32, MutAnyOrigin]) thin abi("C") -> Int32,
        "IDropTarget", "Drop",
    ](obj.interface())(obj.interface(), 0, UInt32(8), 0,
        Pointer(to=effect).unsafe_origin_cast[MutAnyOrigin]())
    print("Drop dispatched via metadata slot: hr", hr, "effect", effect)
    if hr != 0 or effect != 1:
        raise Error("class-synthesised dispatch failed")
    print("S12 PASS -- the class keyword: clean syntax, real COM object")
