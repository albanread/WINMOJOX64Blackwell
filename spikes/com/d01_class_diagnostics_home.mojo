# A mistake inside a class body reports the user's own file and line.
#
# This is a spike that must FAIL to compile, and it is here in the must-pass
# set because what is being checked is not whether it compiles -- it does not
# -- but *where* the compiler says the problem is. run-com-checks.ps1 reads
# the diagnostic text.
#
# Before sprint 2.3 the answer was `<class Target>:14:20`: a line in a buffer
# nobody has ever seen, in a file that does not exist. The `class` keyword is
# a source-level desugar, so the body is copied verbatim into a generated
# buffer and parsed there, and every diagnostic inside it came back against
# that buffer.
#
# The fix is to make the generated buffer agree with the original rather than
# to translate afterwards. The body is copied verbatim, indentation and all,
# so padding the generated preamble to the same height as everything above
# the body in the user's file makes every line and every column inside the
# body match exactly -- and then naming the buffer after that file makes the
# diagnostic indistinguishable from a real one, because it is one.
#
# The mistake below is on line 34, column 20. Nothing else in this file is
# wrong.

class Target(IDropTarget):
    var drops: Int

    def DragEnter(mut self, d: Int, k: UInt32, p: Int, e: Int) raises:
        pass

    def DragOver(mut self, k: UInt32, p: Int, e: Int) raises:
        pass

    def DragLeave(mut self) raises:
        var oops = definitely_not_a_function()

    def Drop(mut self, d: Int, k: UInt32, p: Int, e: Int) raises:
        self.drops += 1


def main() raises:
    var t = Target(0).into_com()
    _ = t
