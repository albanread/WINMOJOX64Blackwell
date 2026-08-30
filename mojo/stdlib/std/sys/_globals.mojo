# ===----------------------------------------------------------------------=== #
# Process globals, reachable by name.
#
# A callback the operating system invokes gets no closure. A Win32 window
# procedure is captureless; so is a Cocoa selector, an ObjC block trampoline,
# and a C-ABI COM vtable slot. Each of them has to find its state somewhere
# other than in itself.
#
# Windows offers one place per window -- GWLP_USERDATA -- and this repository
# uses it for everything a window owns. What it does not offer is a place for
# state that belongs to the *process*: a language server client shared by
# every window, say, or a debug adapter connection. That is what this is.
#
# Taken from MojoCocoa's `std/objc/classes.mojo`, where it lives because the
# Mac port needed it first. Nothing about it is Cocoa: `pop.global_alloc` is a
# KGEN primitive, the storage is zero-initialised, and KGEN deduplicates by
# name so every call site with the same name gets the same slot. It is here
# rather than there so that a client of it -- `ide/lsp.mojo` -- can be shared
# between the two ports without either importing the other's platform module.
# ===----------------------------------------------------------------------=== #

from std.collections.string.string_span import _get_kgen_string
from std.memory import Pointer


def named_global[name: StaticString, T: AnyType]() -> Pointer[
    T, MutUntrackedOrigin
]:
    """A zero-initialised process global of type `T`, shared by name.

    One storage location per name, for state a captureless callback has to be
    able to find. The name is a compile-time string and the deduplication is
    KGEN's, so two call sites naming the same slot get the same memory without
    either having to know about the other.

    Parameters:
        name: The slot's name. Namespace it -- "lsp.task", not "task" --
            because the name is the only thing keeping two subsystems from
            sharing storage by accident.
        T: What is stored there.

    Returns:
        A pointer to the storage, zero-filled before first use.
    """
    comptime slot = StaticString(_get_kgen_string["winmojo.global/", name]())
    return Pointer[T, MutUntrackedOrigin](
        _mlir_value=__mlir_op.`pop.global_alloc`[
            name = _get_kgen_string[slot](),
            count = Int(1).__mlir_index__(),
            _type = Pointer[T, MutUntrackedOrigin]._mlir_type,
            alignment = Int(8).__mlir_index__(),
        ]()
    )
