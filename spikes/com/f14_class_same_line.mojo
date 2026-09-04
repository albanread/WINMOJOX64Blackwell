# MUST FAIL: a class body on the header's own line. The body capture walks
# back from the first body token to the start of its line, and a same-line
# token's line IS the header's line -- so the captured text began with
# `class SameLine(IDropTarget):` itself, the generated struct grew a nested
# class in place of its state, and the refusal arrived as a module-scope
# error pointed at the header line, which reads perfectly fine. The parser
# now says the body starts on the line below and stops there.
#
# The end-of-file form (`class X(IFoo):` as the last line, no newline, no
# body token with an indentation record) reached the same capture and is
# covered by the same guard; a must-fail file cannot end that way and still
# be committed as text, so it is named here instead of tested separately.
class SameLine(IDropTarget): var n: Int

    def DragEnter(mut self) raises:
        pass


def main():
    print("must not compile")
