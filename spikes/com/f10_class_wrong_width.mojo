# MUST FAIL: grfKeyState is a 4-byte u32; this one declares a 1-byte UInt8.
# The recorded disaster class -- a narrow value where the vtable slot expects
# a wide one reads the wrong register bytes, and the method sees garbage key
# state on every drag.
class NarrowKey(IDropTarget):
    var drops: Int

    def DragEnter(mut self, d: Int, k: UInt32, p: Int, e: Int) raises:
        pass

    def DragOver(mut self, k: UInt32, p: Int, e: Int) raises:
        pass

    def DragLeave(mut self) raises:
        pass

    def Drop(mut self, d: Int, k: UInt8, p: Int, e: Int) raises:
        self.drops += 1


def main() raises:
    var obj = NarrowKey(0).into_com()
    _ = obj
    print("must not compile")
