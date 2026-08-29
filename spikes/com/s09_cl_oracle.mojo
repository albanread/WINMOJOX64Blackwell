# The cl.exe oracle, consumed: MSVC built the object, Mojo calls it typed.
#
# The metadata says what and where; only a foreign compiler can confirm how
# the bytes pass. This drives an MSVC-authored ISequentialStream through the
# same Com[...] surface as every other spike -- slot order, this-passing,
# argument widths and HRESULT reading all land on code cl.exe emitted, so a
# disagreement anywhere in the ABI shows up as a wrong sum, not an argument.
#
# The runner builds oracle_stream.dll first; run s09 through it.

from std.memory import Pointer
from std.sys._win32 import Win32Module
from std.sys._com import ComPtr
from std.sys.com import Com


def main() raises:
    let create = Win32Module("spikes/com/oracle_stream.dll").function[
        def (Pointer[Int, MutAnyOrigin]) thin abi("C") -> Int32
    ]("CreateOracleStream")

    var address: Int = 0
    let hr = create(Pointer(to=address).unsafe_origin_cast[MutAnyOrigin]())
    if hr != 0 or address == 0:
        raise Error("oracle refused to create")

    let obj = ComPtr[StaticString("ISequentialStream")](adopt=address)
    let s = Com[StaticString("ISequentialStream")](of=obj)

    # Write bytes whose sum is unmistakable: 1+2+...+16 = 136.
    var payload = List[UInt8]()
    for i in range(16):
        payload.append(UInt8(i + 1))
    var written = UInt32(0)
    _ = s.Write(
        payload.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        UInt32(16),
        Pointer(to=written).unsafe_origin_cast[MutAnyOrigin](),
    )
    print("oracle took", written, "bytes (expect 16)")
    if written != 16:
        raise Error("Write count wrong")

    # Read >= 8 bytes: the oracle answers with the running sum in the first 8.
    var sum = UInt64(0)
    var got = UInt32(0)
    _ = s.Read(
        Pointer(to=sum).unsafe_origin_cast[MutAnyOrigin](),
        UInt32(8),
        Pointer(to=got).unsafe_origin_cast[MutAnyOrigin](),
    )
    print("oracle's sum of our bytes:", sum, "(expect 136)")
    if sum != 136 or got != 8:
        raise Error("the two compilers disagree about the ABI")

    # QI both ways through cl.exe's QueryInterface.
    let unk = obj.query_interface[StaticString("IUnknown")]()
    print("QI(IUnknown) against MSVC:", Bool(unk))
    var refused = False
    try:
        let bad = obj.query_interface[StaticString("IStream")]()
        _ = bad
    except:
        refused = True
    if not refused:
        raise Error("oracle honoured an interface it does not implement")
    print("QI(IStream) correctly refused by the oracle")
    print("S09 PASS -- cl.exe and mojo agree on every byte")
