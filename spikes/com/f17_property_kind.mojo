# MUST FAIL: a float where the SDK declares an integer. SetOptions takes a
# u32, and a Float32 is four bytes too -- the width check alone would pass
# it, and the callee would read reinterpreted bits. The kind check in the
# typed surface catches what the width check cannot see.

from std.sys.com import ComPtr, Com


class AutoList(IACList2):
    var options: UInt32

    def SetOptions(mut self, dwFlag: UInt32) raises:
        self.options = dwFlag

    def GetOptions(mut self, pdwflag: Pointer[UInt32, MutAnyOrigin]) raises:
        pdwflag[] = self.options


def main() raises:
    var obj = AutoList(0).into_com()
    var view = Com[StaticString("IACList2")](of=obj)
    view.SetOptions(Float32(1.0))
