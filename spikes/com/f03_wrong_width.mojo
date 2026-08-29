# MUST FAIL: Seek's first parameter is an i64; feeding 4 bytes where the ABI
# passes 8 is the class of silent corruption the width check exists to stop.
from std.memory import Pointer
from std.sys._com import ComPtr
from std.sys.com import Com


def main() raises:
    let p = ComPtr[StaticString("IStream")](adopt=0)
    let s = Com[StaticString("IStream")](of=p)
    var pos = UInt64(0)
    _ = s.Seek(
        Int32(0),  # the SDK says i64
        UInt32(0),
        Pointer(to=pos).unsafe_origin_cast[MutAnyOrigin](),
    )
