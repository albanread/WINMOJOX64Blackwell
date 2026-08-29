# A COM object implemented in Mojo, by hand -- the `class` synthesis spec,
# executable.
#
# Everything language_update.md says `class` will emit is built here manually,
# once, so the synthesis has a proven pattern to automate: a vtable of `fn`
# pointers in slot order, an object whose first word points at it, a refcount
# behind that word, QueryInterface honouring IUnknown by IID bytes and
# refusing everything else, AddRef/Release keeping an exact count.
#
# The object is then consumed through the SAME machinery every foreign COM
# object gets -- ComPtr and metadata-slotted dispatch -- so if the layout or
# slot order were wrong, the consumer side would prove it here rather than in
# a debugger later. This is also the escape hatch the design keeps: a vtable
# the metadata does not know, built from `fn`s.

from std.memory import Pointer, OpaquePointer
from std.sys._com import ComPtr, com_method_of, _guid_bytes
from std.sys._winkb import winkb_interface_iid

comptime E_NOINTERFACE_RAW = Int32(-2147467262)

# The object's layout, by index into an Int array:
#   [0] vtable pointer   [1] refcount   [2] magic


fn sink_query_interface(this: Int, riid: Int, ppv: Int) -> Int32:
    var iid = Pointer[UInt8, MutAnyOrigin](unsafe_from_address=riid)
    var want = _guid_bytes(winkb_interface_iid["IUnknown"]())
    for i in range(16):
        if iid.unsafe_offset(i)[] != want[i]:
            var out0 = Pointer[Int, MutAnyOrigin](unsafe_from_address=ppv)
            out0[] = 0
            return E_NOINTERFACE_RAW
    # Honoured: hand out this, pre-AddRef'd, as COM requires.
    var obj = Pointer[Int, MutAnyOrigin](unsafe_from_address=this)
    obj.unsafe_offset(1)[] += 1
    var out = Pointer[Int, MutAnyOrigin](unsafe_from_address=ppv)
    out[] = this
    return 0


fn sink_add_ref(this: Int) -> UInt32:
    var obj = Pointer[Int, MutAnyOrigin](unsafe_from_address=this)
    obj.unsafe_offset(1)[] += 1
    return UInt32(obj.unsafe_offset(1)[])


fn sink_release(this: Int) -> UInt32:
    var obj = Pointer[Int, MutAnyOrigin](unsafe_from_address=this)
    obj.unsafe_offset(1)[] -= 1
    # The count reaching zero would free here; this spike's storage is owned
    # by main so the death is observable instead.
    return UInt32(obj.unsafe_offset(1)[])


def fn_bits[Sig: TrivialRegisterPassable](f: Sig) -> Int:
    """The address bits of a thin fn value, for a vtable slot."""
    var v = f
    return Pointer(to=v).unsafe_bitcast[Int]()[]


def main() raises:
    # The vtable: IUnknown's three slots, in metadata order, as fn pointers.
    var vtbl = List[Int]()
    vtbl.append(
        fn_bits[def (Int, Int, Int) thin abi("C") -> Int32](
            sink_query_interface
        )
    )
    vtbl.append(fn_bits[def (Int) thin abi("C") -> UInt32](sink_add_ref))
    vtbl.append(fn_bits[def (Int) thin abi("C") -> UInt32](sink_release))

    # The object: vtable pointer first, then state.
    var storage = List[Int]()
    storage.append(Int(vtbl.unsafe_ptr()))  # [0] vtbl
    storage.append(1)  # [1] refcount: the creation reference
    storage.append(0x5AFE)  # [2] magic
    let this = Int(storage.unsafe_ptr())

    # Consume it exactly as a foreign object: adopt the creation reference.
    with_object(this)

    # Every ComPtr has died; the exact count proves the discipline.
    print("final refcount:", storage[1], "(expect 0)")
    if storage[1] != 0:
        raise Error("refcount did not balance")
    if storage[2] != 0x5AFE:
        raise Error("object state corrupted")
    print("S08 PASS")


def with_object(this: Int) raises:
    let a = ComPtr[StaticString("IUnknown")](adopt=this)

    # Dispatch through OUR vtable via the METADATA's slots: if the hand-built
    # order disagreed with IUnknown's recorded order, these calls would land
    # on the wrong functions and the counts would prove it.
    let up = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> UInt32,
        "IUnknown",
        "AddRef",
    ](a.interface())(a.interface())
    print("AddRef through metadata slot ->", up, "(expect 2)")
    let down = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> UInt32,
        "IUnknown",
        "Release",
    ](a.interface())(a.interface())
    print("Release through metadata slot ->", down, "(expect 1)")
    if up != 2 or down != 1:
        raise Error("slot dispatch hit the wrong function")

    # QI for IUnknown succeeds and adds a count; for IStream it must refuse.
    let b = a.query_interface[StaticString("IUnknown")]()
    print("QI(IUnknown): honoured")
    var refused = False
    try:
        let bad = a.query_interface[StaticString("IStream")]()
        _ = bad
    except:
        refused = True
    if not refused:
        raise Error("QI(IStream) should have been refused")
    print("QI(IStream): refused with E_NOINTERFACE, as declared")
    _ = b
