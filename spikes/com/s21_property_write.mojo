# The property write: `view.options = 2` means SetOptions(2).
#
# The write-shaped sibling of the typed call surface. The name arrives at
# the compiler as a parameter, the setter it means -- 'Set' plus the
# capitalised name -- is settled against the metadata at compile time, and
# the dispatch goes through the setter's vtable slot with the same arity
# and argument checks any typed call gets. A bare literal adopts the
# setter's declared type; a typed value keeps the exact-type path; both
# read back through GetOptions unchanged.

from std.sys.com import ComPtr, Com
from std.memory import Pointer


class AutoList(IACList2):
    var options: UInt32

    def SetOptions(mut self, dwFlag: UInt32) raises:
        self.options = dwFlag

    def GetOptions(mut self, pdwflag: Pointer[UInt32, MutAnyOrigin]) raises:
        pdwflag[] = self.options

    def Expand(mut self, penum: Pointer[UInt8, MutAnyOrigin]) raises:
        pass


def main() raises:
    var obj = AutoList(0).into_com()
    var view = Com[StaticString("IACList2")](of=obj)

    # The property write: view.options = 2 means SetOptions(2).
    view.options = 2
    var got = UInt32(0)
    view.GetOptions(Pointer(to=got).unsafe_origin_cast[MutAnyOrigin]())
    print("wrote 2, read back:", got)
    if got != 2:
        raise Error("the property write did not land")

    view.options = 0x80
    view.GetOptions(Pointer(to=got).unsafe_origin_cast[MutAnyOrigin]())
    print("wrote 128, read back:", got)
    if got != 128:
        raise Error("second property write did not land")

    # A typed value keeps the exact-type path.
    view.options = UInt32(7)
    view.GetOptions(Pointer(to=got).unsafe_origin_cast[MutAnyOrigin]())
    print("wrote 7, read back:", got)
    if got != 7:
        raise Error("typed property write did not land")
    print("S21 PASS -- the property write dispatches through SetOptions")
