# MUST FAIL: IStream derives from ISequentialStream, so a class implementing
# both has two interfaces that each declare Read and Write. Binding those to
# whichever interface happens to be listed first would fill a slot on one
# vtable and leave the other's hole -- silently, and only discoverable when a
# client that queried the other interface calls it. Ambiguity is refused.
class TwoStreams(IStream, ISequentialStream):
    var pos: Int

    def Read(mut self, pv: Int, cb: UInt32, got: Int) raises:
        pass


def main() raises:
    # The class must be BUILT for its factory to be instantiated: Mojo
    # instantiates generics lazily, so a class whose slots cannot be resolved
    # is diagnosed where it is turned into an object, not where it is written.
    var obj = TwoStreams(0).into_com()
    _ = obj
    print("must not compile")
