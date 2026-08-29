# The flagship consumer spike: typed COM calls on a live object.
#
# Com["IStream"] dispatches Write/Seek/Read by name through metadata slots --
# Write is slot 4 via ISequentialStream, Seek slot 5 -- with arity and widths
# checked at compile time and HRESULT raising on failure. Round-trips real
# bytes so a wrong slot or a corrupted ABI cannot pass.

from std.ffi import c_int, OwnedDLHandle
from std.memory import Pointer
from std.sys._com import ComPtr
from std.sys.com import Com, HResult


def main() raises:
    let ole32 = OwnedDLHandle("ole32.dll")
    let create = ole32.get_function[c_int]("CreateStreamOnHGlobal")

    var stream_address: Int = 0
    let hr0 = create(Int(0), c_int(1), Pointer(to=stream_address))
    if hr0 != 0 or stream_address == 0:
        raise Error("could not create the stream")

    let stream = ComPtr[StaticString("IStream")](adopt=stream_address)
    let s = Com[StaticString("IStream")](of=stream)

    # Write 4 bytes through the typed surface.
    var payload = UInt32(0xC0FFEE42)
    var written = UInt32(0)
    _ = s.Write(
        Pointer(to=payload).unsafe_origin_cast[MutAnyOrigin](),
        UInt32(4),
        Pointer(to=written).unsafe_origin_cast[MutAnyOrigin](),
    )
    print("wrote", written, "bytes (expect 4)")

    # Seek back to 0. dlibMove is an i64, origin an enum (STREAM_SEEK_SET=0),
    # and the new position an out u64 pointer.
    var newpos = UInt64(999)
    _ = s.Seek(
        Int64(0),
        UInt32(0),
        Pointer(to=newpos).unsafe_origin_cast[MutAnyOrigin](),
    )
    print("seek landed at", newpos, "(expect 0)")

    # Read the bytes back and compare.
    var readback = UInt32(0)
    var got = UInt32(0)
    _ = s.Read(
        Pointer(to=readback).unsafe_origin_cast[MutAnyOrigin](),
        UInt32(4),
        Pointer(to=got).unsafe_origin_cast[MutAnyOrigin](),
    )
    print("read", got, "bytes back (expect 4)")
    if readback != payload:
        raise Error("round-trip mismatch")
    print("round-trip EXACT:", readback, "(expect 3237998146)")

    # A failing HRESULT must raise. Seek with an invalid origin is a genuine
    # failure on every stream (Commit is not: HGlobal streams no-op it).
    var raised = False
    try:
        var junk = UInt64(0)
        _ = s.Seek(
            Int64(0),
            UInt32(99),
            Pointer(to=junk).unsafe_origin_cast[MutAnyOrigin](),
        )
    except:
        raised = True
    print("invalid Seek raised:", raised, "(expect True)")
    if not raised:
        raise Error("a failing HRESULT did not raise")
    print("S05 PASS")
