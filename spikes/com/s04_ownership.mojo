# ComPtr's ownership, asserted against a live refcount -- with `let`.
#
# Every transition is observable through AddRef's return value: adopt leaves
# the count alone, copy adds one, a move adds nothing (the elision C++ cannot
# prove), deinit subtracts one, QI adds one on the same object. The bindings
# are `let` where they are bindings, which is everywhere.

from std.ffi import c_int, OwnedDLHandle
from std.memory import Pointer, OpaquePointer
from std.sys._com import ComPtr, com_method_of


def probe_count(p: ComPtr) -> UInt32:
    """The current refcount, via a balanced AddRef/Release pair."""
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


def check(label: StaticString, got: UInt32, want: UInt32) raises:
    print(" ", label, "count =", got, "(expect", want, ")")
    if got != want:
        raise Error("refcount broke at " + String(label))


def main() raises:
    let ole32 = OwnedDLHandle("ole32.dll")
    let create = ole32.get_function[c_int]("CreateStreamOnHGlobal")
    var stream_address: Int = 0
    let hr = create(Int(0), c_int(1), Pointer(to=stream_address))
    if hr != 0 or stream_address == 0:
        raise Error("could not create the stream")

    let a = ComPtr[StaticString("IStream")](adopt=stream_address)
    check("adopt", probe_count(a), 1)

    let b = a.copy()
    check("copy ", probe_count(a), 2)

    let c = b^
    check("move ", probe_count(a), 2)

    let seq = a.query_interface[StaticString("ISequentialStream")]()
    check("QI   ", probe_count(a), 3)
    if not seq:
        raise Error("QI returned null with S_OK")

    # An interface the object does not implement raises and changes nothing.
    var raised = False
    try:
        let nope = a.query_interface[StaticString("IPersistFile")]()
        _ = nope
    except:
        raised = True
    if not raised:
        raise Error("QI for an unimplemented interface did not raise")
    check("bad QI", probe_count(a), 3)

    # Keep-alives, and a lesson worth its comment: Mojo destroys a value
    # after its LAST USE, not at scope end -- so without these, `seq` dies
    # right after its null check and its Release fires BEFORE the counts
    # above are probed. ASAP destruction and COM refcounts compose exactly;
    # they just make "still alive" something the source must say.
    _ = seq
    _ = c
    print("S04 PASS")
