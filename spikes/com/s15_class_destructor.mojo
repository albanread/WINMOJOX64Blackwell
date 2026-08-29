# A COM class owns its state, and the last Release destroys it -- exactly
# once, not zero times and not twice.
#
# This is the defect trivial state hides. A DropTarget of two Ints leaks
# nothing when the block is freed without running a destructor, so every
# earlier spike passed while the destructor word sat empty. A class holding a
# String, a List or a ComPtr would have leaked its contents on every Release.
#
# The canary is a counter incremented by a destructor, so the test can tell
# apart the three outcomes that matter: never destroyed (the leak), destroyed
# twice (a double-free waiting to happen), and destroyed once at the right
# moment -- when the refcount reaches zero, not when the builder's temporary
# goes out of scope.

from std.memory import Pointer, OpaquePointer
from std.sys._com import ComPtr, com_method_of
from std.sys.com import ComClassBuilder

comptime UNK_SIG = def (
    OpaquePointer[MutUntrackedOrigin]
) thin abi("C") -> UInt32

struct Canary(Movable, Deinitable):
    """Counts its own destruction, and carries a heap value worth leaking.

    Mojo has no global variables, so the counter lives in the caller's frame
    and the canary holds its address. That also makes the check sharper: the
    counter outlives the object by construction, so a bump arriving after the
    object is gone would still be seen.
    """

    var name: String
    var counter: Int

    def __init__(out self, var name: String, counter: Int):
        self.name = name^
        self.counter = counter

    def __del__(deinit self):
        Pointer[Int, MutAnyOrigin](unsafe_from_address=self.counter)[] += 1


@fieldwise_init
struct Holder(Movable, Deinitable):
    var canary: Canary
    var drops: Int

    def DragEnter(mut self, data: Int, key: UInt32, pt: Int, eff: Int) raises:
        pass

    def DragOver(mut self, key: UInt32, pt: Int, eff: Int) raises:
        pass

    def DragLeave(mut self) raises:
        pass

    def Drop(mut self, data: Int, key: UInt32, pt: Int, eff: Int) raises:
        self.drops += 1


def build(counter: Int) raises -> ComPtr[StaticString("IDropTarget")]:
    var b = ComClassBuilder["IDropTarget"]()
    b.method["DragEnter", Holder.DragEnter]()
    b.method["DragOver", Holder.DragOver]()
    b.method["DragLeave", Holder.DragLeave]()
    b.method["Drop", Holder.Drop]()
    return b^.finish_state(
        Holder(Canary(String("held by the object"), counter), 0)
    )


def add_ref(p: Int) raises -> UInt32:
    return com_method_of[UNK_SIG, "IUnknown", "AddRef"](
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=p)
    )(OpaquePointer[MutUntrackedOrigin](unsafe_from_address=p))


def release(p: Int) raises -> UInt32:
    return com_method_of[UNK_SIG, "IUnknown", "Release"](
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=p)
    )(OpaquePointer[MutUntrackedOrigin](unsafe_from_address=p))


def main() raises:
    var destroyed = 0
    var counter = Int(Pointer(to=destroyed))
    print("before build, destroyed =", destroyed, "(expect 0)")

    var obj = build(counter)
    var p = obj.address()
    if destroyed != 0:
        raise Error("state was destroyed while the object was still alive")
    print("built and holding a String, destroyed =", destroyed, "(expect 0)")

    # A second reference: the object must survive the first Release. This is
    # the check that separates "destroyed when the refcount hits zero" from
    # "destroyed on any Release".
    var n = add_ref(p)
    print("after AddRef, refcount =", n, "(expect 2)")
    var left = release(p)
    print("after one Release, refcount =", left, " destroyed =", destroyed,
          "(expect 1, 0)")
    if destroyed != 0:
        raise Error("state destroyed while a reference was still held")

    # Drop the last reference by consuming the ComPtr. Its own Release takes
    # the count to zero, which must run the destructor exactly once.
    _ = obj^
    print("after final Release, destroyed =", destroyed, "(expect 1)")
    if destroyed == 0:
        raise Error(
            "the object was freed without destroying its state: a class"
            " holding a String, List or ComPtr leaks its contents"
        )
    if destroyed > 1:
        raise Error("state destroyed more than once")

    print("S15 PASS -- class state destroyed exactly once, at refcount zero")
