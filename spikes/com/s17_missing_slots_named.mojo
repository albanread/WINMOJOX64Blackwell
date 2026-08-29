# An incomplete class names the slots it left empty.
#
# This is the net under the rule that lets a class hold helpers (s16): since
# a name no interface declares is treated as an ordinary method, a MISTYPED
# COM name -- `Drpo` for `Drop` -- is no longer a compile error. It has to be
# caught somewhere, and "3 slot(s) neither implemented nor declined" is not
# an answer anyone can act on. `finish` names them, per interface.
#
# The check is that the object refuses to exist. A vtable hole does not fail
# loudly at the call: Windows dispatches to whatever the slot holds and the
# call succeeds into nothing.

from std.sys.com import ComClassBuilder


class Typo(IDropTarget):
    var n: Int

    def DragEnter(mut self, d: Int, k: UInt32, p: Int, e: Int) raises:
        pass

    def DragOver(mut self, k: UInt32, p: Int, e: Int) raises:
        pass

    def DragLeave(mut self) raises:
        pass

    def Drpo(mut self, d: Int, k: UInt32, p: Int, e: Int) raises:
        # Deliberate typo: this is a helper as far as the metadata knows.
        self.n += 1


def main() raises:
    var caught = String("")
    try:
        var o = Typo(0).into_com()
        _ = o
    except e:
        caught = String(e)

    print("refused with:", caught)
    if "Drop" not in caught:
        raise Error("the diagnostic must name the missing method")
    if "unfilled slot" not in caught:
        raise Error("the diagnostic must say the slot is unfilled")
    print("S17 PASS -- an incomplete class names its unfilled slots")
