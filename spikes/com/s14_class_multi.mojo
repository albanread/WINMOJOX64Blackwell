# The `class` keyword with several interfaces -- the whole tear-off milestone
# reduced to a declaration.
#
# `class DragThing(IDropTarget, IDropSource):` is a full drag-and-drop
# participant: Explorer's drop side and the drag source side, one object, one
# state, one refcount. The compiler emits a ComClassBuilder over both
# interfaces and routes each method to whichever one declares it.
#
# s13 proves the COM identity rules on the same layout, written as a library.
# This proves the keyword reaches it.

from std.memory import Pointer, OpaquePointer
from std.sys._com import ComPtr, com_method_of
from std.sys.com import _guid_bytes
from std.sys._winkb import winkb_interface_iid

comptime COPY = UInt32(1)


class DragThing(IDropTarget, IDropSource):
    var drops: Int
    var continues: Int

    def DragEnter(mut self, d: Int, k: UInt32, p: Int, e: Int) raises:
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=e)[] = COPY

    def DragOver(mut self, k: UInt32, p: Int, e: Int) raises:
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=e)[] = COPY

    def DragLeave(mut self) raises:
        pass

    def Drop(mut self, d: Int, k: UInt32, p: Int, e: Int) raises:
        self.drops += 1
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=e)[] = COPY

    def QueryContinueDrag(mut self, esc: Int32, k: UInt32) raises:
        self.continues += 1

    def GiveFeedback(mut self, effect: UInt32) raises:
        pass


def main() raises:
    var obj = DragThing(0, 0).into_com()
    var primary = obj.address()

    var iid = _guid_bytes(winkb_interface_iid["IDropSource"]())
    var out = Int(0)
    var hr = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin], Int, Int) thin abi("C") -> Int32,
        "IUnknown", "QueryInterface",
    ](obj.interface())(obj.interface(), Int(iid.unsafe_ptr()),
                       Int(Pointer(to=out)))
    _ = iid
    print("class with two interfaces: QI hr", hr, " distinct ptr:", out != primary)
    if hr != 0 or out == primary:
        raise Error("multi-interface class failed QI")

    var qhr = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin], Int32, UInt32) thin abi("C") -> Int32,
        "IDropSource", "QueryContinueDrag",
    ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=out))(
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=out),
        Int32(0), UInt32(1))
    print("called IDropSource method through the class: hr", qhr)
    _ = obj
    print("S14 PASS -- a class implementing two COM interfaces")
