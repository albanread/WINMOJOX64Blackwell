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
# KGEN primitive and the storage is zero-initialised. It is here rather than
# there so that a client of it -- `ide/lsp.mojo` -- can be shared between the
# two ports without either importing the other's platform module.
#
# THIS ONLY WORKS IN AN UNOPTIMIZED BUILD, and the failure is silent.
#
# The deduplication is KGEN's, and it does not survive optimization on this
# target. Unoptimized, every call naming the same slot returns the same
# address and this behaves as documented. Optimized, each call to
# `pop.global_alloc` emits a FRESH allocation -- two calls in one function
# return addresses eight bytes apart:
#
#     comptime G = named_global["thing", Int]
#     G()[] = 1
#     print(G()[])        # --no-optimization: 1.   optimized: 0.
#
# Nothing warns. The storage is zero-initialised, so a global that is being
# written through one slot and read through another is indistinguishable from
# one nobody has written to yet -- which is what makes this worth a warning
# block rather than a footnote.
#
# Binding the POINTER at module scope instead of the function does NOT fix
# it: `comptime` is an alias, substituted at each use, so every use still
# evaluates its own `pop.global_alloc`. (And the same binding inside a
# function body is rejected outright: "cannot use a dynamic value in comptime
# initializer".) There is no spelling of this that is safe under
# optimization; the build flag is the fix.
#
# Every consumer in this repository is therefore built with
# `--no-optimization`: `tools/build-ide.ps1` (Griddle, 174 of these across 19
# files) and `examples/win32/build-x64.sh` (the game pane). Griddle's
# `-Optimized` path does not have that protection and every global in it is
# silently dead. `gamepane/window.mojo` checks its own global at startup and
# raises rather than running with no input, which is the pattern to copy
# anywhere this matters.
# ===----------------------------------------------------------------------=== #

from std.collections.string.string_span import _get_kgen_string
from std.memory import Pointer


def named_global[name: StaticString, T: AnyType]() -> Pointer[
    T, MutUntrackedOrigin
]:
    """A zero-initialised process global of type `T`, shared by name.

    One storage location per name, for state a captureless callback has to be
    able to find.

    Build with `--no-optimization`. The name-based deduplication this relies
    on does not survive optimization, and when it fails it fails silently --
    see the note at the top of this file.

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
