# MUST FAIL: the IUnknown slots belong to the library; a class may not
# supply its own AddRef. The builder rejects it at compile time.
from std.sys.com import ComClassBuilder


fn my_add_ref(this: Int) -> UInt32:
    return 1


def main() raises:
    var b = ComClassBuilder[StaticString("IDropTarget")]()
    b.slot["AddRef", def (Int) thin abi("C") -> UInt32](my_add_ref)
    _ = b^.finish()
