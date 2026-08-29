# MUST FAIL: a COM class implementing two interfaces needs tear-off vtables,
# which the runtime does not build yet. Refusing beats emitting an object whose
# QueryInterface lies about what it supports.
class Both(IDropTarget, IDropSource):
    var n: Int
    def DragLeave(mut self) raises:
        pass


def main():
    print("must not compile")
