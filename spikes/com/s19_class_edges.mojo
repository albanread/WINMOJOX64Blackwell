# Edges of the `class` grammar that generated code makes easy to get wrong.
#
# A source-level desugar has a failure mode a hand-written parser does not:
# when the capture is wrong, the error surfaces inside generated source and
# names something the user never wrote. These are the cases that did that, or
# would have.
#
#   move-only state -- a class holding an owned ComPtr is the ordinary case
#     for an IDE, and deriving Copyable refused it. The desugar derives
#     Movable only: into_com consumes `self^`, and finish_state asks for no
#     more than Movable & Deinitable.
#
#   CRLF source -- the body is captured verbatim from the file, so a file
#     saved with Windows line endings puts \r inside the generated struct.
#     The sub-lexer tolerates it exactly as the main one does; asserted here
#     rather than assumed, since every editor on this platform can produce it.
#
# Two more are must-fails rather than passes, because refusing is the correct
# behaviour: an empty class body (f11) and a nested class (f12).

from std.sys._com import ComPtr


struct MoveOnly(Movable, Deinitable):
    """Move-only, like an owned COM reference."""

    var n: Int

    def __init__(out self, n: Int):
        self.n = n


class Holder(IDropTarget):
    var owned: MoveOnly
    var drops: Int

    def DragEnter(mut self, d: Int, k: UInt32, p: Int, e: Int) raises:
        pass

    def DragOver(mut self, k: UInt32, p: Int, e: Int) raises:
        pass

    def DragLeave(mut self) raises:
        pass

    def Drop(mut self, d: Int, k: UInt32, p: Int, e: Int) raises:
        self.drops += 1


def main() raises:
    var h = Holder(MoveOnly(7), 0).into_com()
    if not h:
        raise Error("a class holding a move-only field must build")
    print("move-only state: built")
    _ = h
    print("S19 PASS -- a class may own move-only state")
