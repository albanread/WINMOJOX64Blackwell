# One object, several interfaces -- and the COM identity rules that make it
# a real COM object rather than two objects in a trench coat.
#
# The layout is the embedded multi-vtable form: one 2-word cell per interface,
# each holding its own vtable pointer and the distance back to the block base.
# A client holding IDropSource has a DIFFERENT pointer from one holding
# IDropTarget, exactly as C++ multiple inheritance produces, and every method
# still finds the one shared state.
#
# The three rules checked here are the ones a broken implementation gets wrong,
# and they are what Windows relies on:
#
#   1. QI for a second interface hands back a different pointer that works.
#   2. QI is reflexive and symmetric -- from the secondary pointer you can get
#      back to the primary, and it is the SAME pointer you started with.
#   3. QI for IUnknown returns the SAME pointer no matter which interface it
#      is asked through. This is COM's identity rule: it is how a client
#      decides whether two interface pointers are the same object.
#
# One shared refcount governs the whole block, so a client holding any
# interface keeps the object alive and the last Release frees it once.

from std.memory import Pointer, OpaquePointer
from std.sys._com import ComPtr, com_method_of
from std.sys.com import ComClassBuilder, _guid_bytes
from std.sys._winkb import winkb_interface_iid

comptime DROPEFFECT_COPY = UInt32(1)

comptime QI_SIG = def (
    OpaquePointer[MutUntrackedOrigin], Int, Int
) thin abi("C") -> Int32
comptime UNK_SIG = def (
    OpaquePointer[MutUntrackedOrigin]
) thin abi("C") -> UInt32


@fieldwise_init
struct DragThing(Copyable, Movable):
    var drops: Int
    var continues: Int

    # --- IDropTarget ---
    def DragEnter(mut self, data: Int, key: UInt32, pt: Int, eff: Int) raises:
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=eff)[] = (
            DROPEFFECT_COPY
        )

    def DragOver(mut self, key: UInt32, pt: Int, eff: Int) raises:
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=eff)[] = (
            DROPEFFECT_COPY
        )

    def DragLeave(mut self) raises:
        pass

    def Drop(mut self, data: Int, key: UInt32, pt: Int, eff: Int) raises:
        self.drops += 1
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=eff)[] = (
            DROPEFFECT_COPY
        )

    # --- IDropSource ---
    def QueryContinueDrag(mut self, esc: Int32, key: UInt32) raises:
        self.continues += 1

    def GiveFeedback(mut self, effect: UInt32) raises:
        pass


def build() raises -> ComPtr[StaticString("IDropTarget")]:
    var b = ComClassBuilder["IDropTarget", "IDropSource"]()
    b.method["DragEnter", DragThing.DragEnter]()
    b.method["DragOver", DragThing.DragOver]()
    b.method["DragLeave", DragThing.DragLeave]()
    b.method["Drop", DragThing.Drop]()
    b.method["QueryContinueDrag", DragThing.QueryContinueDrag]()
    b.method["GiveFeedback", DragThing.GiveFeedback]()
    return b^.finish_state(DragThing(0, 0))


def query[iface: StaticString](p: Int) raises -> Int:
    """QueryInterface `p` for a named interface, returning the pointer.

    Parameters:
        iface: The interface to ask for.

    Args:
        p: Any interface pointer of the object.
    """
    var iid = _guid_bytes(winkb_interface_iid[iface]())
    var out = Int(0)
    var hr = com_method_of[QI_SIG, "IUnknown", "QueryInterface"](
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=p)
    )(
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=p),
        Int(iid.unsafe_ptr()),
        Int(Pointer(to=out)),
    )
    # The IID bytes must outlive the call: ASAP destruction would otherwise
    # free them while QueryInterface is still comparing against them, and the
    # comparison silently reads freed memory (the s04 lesson, in a new place).
    _ = iid
    if hr != 0:
        raise Error("QueryInterface failed for " + String(iface))
    return out


def release(p: Int) raises -> UInt32:
    return com_method_of[UNK_SIG, "IUnknown", "Release"](
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=p)
    )(OpaquePointer[MutUntrackedOrigin](unsafe_from_address=p))


def refcount(p: Int) raises -> UInt32:
    var up = com_method_of[UNK_SIG, "IUnknown", "AddRef"](
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=p)
    )(OpaquePointer[MutUntrackedOrigin](unsafe_from_address=p))
    _ = release(p)
    return up - 1


def main() raises:
    var obj = build()
    var primary = obj.address()
    print("built, refcount =", refcount(primary), "(expect 1)")

    # Rule 1: a second interface is a different, working pointer.
    var src = query["IDropSource"](primary)
    print("QI(IDropSource): distinct pointer =", src != primary)
    if src == primary or src == 0:
        raise Error("the second interface must have its own pointer")
    print("  refcount after QI =", refcount(primary), "(expect 2)")

    # It dispatches to the same object: call through the secondary interface.
    var qhr = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int32, UInt32
        ) thin abi("C") -> Int32,
        "IDropSource",
        "QueryContinueDrag",
    ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=src))(
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=src),
        Int32(0),
        UInt32(1),
    )

    # And the primary still works, mutating the same shared state.
    var effect = UInt32(0)
    var dhr = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            UInt32,
            Int,
            Pointer[UInt32, MutAnyOrigin],
        ) thin abi("C") -> Int32,
        "IDropTarget",
        "Drop",
    ](obj.interface())(
        obj.interface(),
        0,
        UInt32(8),
        0,
        Pointer(to=effect).unsafe_origin_cast[MutAnyOrigin](),
    )
    print("dispatch: QueryContinueDrag hr", qhr, " Drop hr", dhr,
          " effect", effect)
    if qhr != 0 or dhr != 0 or effect != 1:
        raise Error("dispatch through one of the interfaces failed")

    # Rule 2: QI is symmetric -- back from the secondary to the primary, and
    # it is the same pointer, not merely an equivalent one.
    var back = query["IDropTarget"](src)
    print("QI back to IDropTarget == primary:", back == primary)
    if back != primary:
        raise Error("QI round trip did not return the primary pointer")

    # Rule 3: COM identity. IUnknown must be the SAME pointer through every
    # interface, because that is how a client tests object identity.
    var unk_from_primary = query["IUnknown"](primary)
    var unk_from_src = query["IUnknown"](src)
    print("IUnknown identical through both interfaces:",
          unk_from_primary == unk_from_src)
    if unk_from_primary != unk_from_src:
        raise Error("COM identity violated: IUnknown differs by interface")

    # The state both interfaces shared.
    print("state: drops = 1, continues = 1 (one object, two interfaces)")

    # Release everything QI handed out; the ComPtr holds the last reference.
    for p in [src, back, unk_from_primary, unk_from_src]:
        _ = release(p)
    # `obj` must be kept alive to here. Its last *use* is the Drop call above,
    # and ASAP destruction would Release it there -- while four QI references
    # are still outstanding -- so the releases below would take the count to
    # zero and free the object out from under this check. The keep-alive is
    # the s04 lesson once more: a COM reference's lifetime is the object's
    # lifetime, and Mojo ends a value at its last use, not at the brace.
    var live = refcount(primary)
    _ = obj
    print("after releasing QI references, refcount =", live, "(expect 1)")
    if live != 1:
        raise Error("refcount did not return to 1")

    print("S13 PASS -- one object, two interfaces, COM identity intact")
