# ComPtr's ownership claims, asserted against a live COM object rather than
# stated. AddRef returns the new count, so every transition is observable:
#
#   adopt   -> count unchanged (the out-param's reference is the one adopted)
#   copy    -> +1
#   move    -> +0   (the elision C++ cannot prove)
#   deinit  -> -1
#   QI      -> +1 on the same underlying object, adopted exactly

from std.ffi import c_int, OwnedDLHandle
from std.memory import Pointer, OpaquePointer
from std.sys._com import ComPtr, com_method_of
from std.sys._winkb import winkb_db_hash, winkb_db_schema_version


def probe_count(p: ComPtr) -> UInt32:
    """The object's current refcount, via a balanced AddRef/Release pair."""
    var up = com_method_of[
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


def main() raises:
    print("metadata:", winkb_db_schema_version(), winkb_db_hash())

    var ole32 = OwnedDLHandle("ole32.dll")
    var create = ole32.get_function[c_int]("CreateStreamOnHGlobal")

    var stream_address: Int = 0
    var hr = create(Int(0), c_int(1), Pointer(to=stream_address))
    if hr != 0 or stream_address == 0:
        raise Error("could not create the stream")

    # Adopt: the factory's reference becomes ours, count stays 1.
    var a = ComPtr[StaticString("IStream")](adopt=stream_address)
    print("after adopt      count =", probe_count(a), "(expect 1)")

    # Copy: AddRef. Count 2 while both live.
    var b = a.copy()
    print("after copy       count =", probe_count(a), "(expect 2)")

    # Move: no refcount traffic. Count still 2 -- b is consumed, c holds it.
    var c = b^
    print("after move       count =", probe_count(a), "(expect 2)")

    # QueryInterface with the IID inferred from the type parameter: the same
    # object through its base interface, arriving pre-AddRef'd and adopted.
    var seq = a.query_interface[StaticString("ISequentialStream")]()
    print("after QI         count =", probe_count(a), "(expect 3)")
    print("QI non-null:", Bool(seq))

    # An interface the object does not implement must raise, not corrupt.
    var refused = False
    try:
        _ = a.query_interface[StaticString("ID3D11Device")]()
    except:
        refused = True
    print("unrelated QI raises:", refused, "(expect True)")

    # Hand everything back explicitly and watch the count walk down. The last
    # probe needs a live reference, so release c and seq first, keep a.
    _ = c^
    _ = seq^
    print("after drops      count =", probe_count(a), "(expect 1)")
    # a's own deinit takes it to zero when main ends.
