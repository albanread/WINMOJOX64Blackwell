# A COM class is still a struct: it may hold helper methods that are not COM
# methods at all, and they stay ordinary methods.
#
# Wiring every `def` in a class body into a vtable slot made an unwritten
# rule -- "a class body may contain only COM methods" -- that nobody would
# guess and no diagnostic explained. Here `note`, `reset` and `total` are
# helpers; only the four IDropTarget methods reach slots.
#
# Two Mojo facts make this work, and they had to be measured rather than
# assumed. `comptime if` prunes INSTANTIATION -- so an undeclared name never
# reaches the slot constraints -- but it does NOT prune overload conversion,
# so a helper whose signature matches no COM shape still has to land
# somewhere. A catch-all overload absorbs those, and checks the name: if an
# interface *does* declare it, the method was meant to be a COM method and
# its signature is simply wrong, which is said plainly rather than left as a
# silently empty slot (f09/f10 and the wrong-shape case cover that).

from std.memory import Pointer

comptime COPY = UInt32(1)


class Target(IDropTarget):
    var drops: Int
    var label: String

    def DragEnter(mut self, d: Int, k: UInt32, p: Int, e: Int) raises:
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=e)[] = COPY

    def DragOver(mut self, k: UInt32, p: Int, e: Int) raises:
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=e)[] = COPY

    def DragLeave(mut self) raises:
        pass

    def Drop(mut self, d: Int, k: UInt32, p: Int, e: Int) raises:
        self.drops += 1
        self.note("dropped")
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=e)[] = COPY

    # --- helpers: NOT COM methods, must stay ordinary methods ---
    def note(mut self, what: String):
        self.label = what

    def reset(mut self):
        self.drops = 0

    def total(self) -> Int:
        return self.drops


def main() raises:
    var t = Target(0, String("idle"))
    t.note("hello")            # helper callable directly on the struct
    print("helper works:", t.total(), t.label)
    var obj = t^.into_com()
    print("S16 PASS -- a class may hold non-COM helper methods:", Bool(obj))
