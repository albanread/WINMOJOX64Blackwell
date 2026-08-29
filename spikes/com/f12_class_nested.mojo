# MUST FAIL: a nested class. The body is captured verbatim, so an inner class
# reaches the sub-parse, where the module-scope rule refuses it -- the same
# rule a nested struct meets, reported against the inner class.
#
# This case did not merely produce a bad message: it HUNG the compiler. The
# rejection recovered before the `class` keyword had been consumed, and
# skipUntilIndentation stops on the current token when it already sits at the
# target indentation -- so the statement loop re-entered on the same token
# forever, emitting five and a half million identical diagnostics. Recovery
# now consumes a token first, and every malformed-header path was checked to
# terminate. A must-fail test is only meaningful if the compiler survives it.
class Outer(IDropTarget):
    var n: Int

    class Inner(IDropSource):
        var m: Int


def main():
    print("must not compile")
