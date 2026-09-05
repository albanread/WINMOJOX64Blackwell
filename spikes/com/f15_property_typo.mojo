# MUST FAIL: a typo'd property name. There is no SetOptons on IACList2, and
# the metadata's refusal is the diagnostic: the compiler names the interface
# and the property rather than dropping the write or inventing a runtime
# lookup. A property that does not exist cannot be written.

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
    view.optons = 2
