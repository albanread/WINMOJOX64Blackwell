# ===----------------------------------------------------------------------=== #
# Cached Win32 module and entry-point access.
#
# `OwnedDLHandle` frees its library on drop, which is wrong for Win32 work
# twice over: the churn of load/free per scope is wasted work, and Windows may
# still hold callbacks into a module the handle just freed. This wrapper goes
# through a process-lifetime cache in the compiler runtime
# (KGEN_CompilerRT_Win32Module in PosixWin32.cpp): each module loads once and
# is never freed, which for user32/kernel32/d3d11 is what any Windows process
# does anyway. Mojo has no mutable-global idiom in this snapshot, so the cache
# lives in C++, where it is one lock and one map.
# ===----------------------------------------------------------------------=== #

from std.ffi import external_call
from std.memory import Pointer, OpaquePointer


@fieldwise_init
struct Win32Module(Boolable, ImplicitlyCopyable, RegisterPassable):
    """A non-owning handle to a cached Win32 module.

    Copies freely; nothing is freed on drop, because the cache owns the module
    for the life of the process.
    """

    var _module: Int

    def __init__(out self, var name: String):
        """Fetches the named module through the process-lifetime cache.

        Args:
            name: The module name, e.g. "user32.dll".
        """
        self._module = external_call["KGEN_CompilerRT_Win32Module", Int](
            name.as_c_string_slice()
        )

    def __bool__(self) -> Bool:
        """Whether the module loaded.

        Returns:
            True if the module is available.
        """
        return self._module != 0

    def address_of(self, var name: String) -> Int:
        """The address of an exported entry point, or 0 if absent.

        Args:
            name: The export's name.

        Returns:
            The entry point's address, or 0.
        """
        return external_call["KGEN_CompilerRT_Win32Symbol", Int](
            self._module, name.as_c_string_slice()
        )

    def function[
        Sig: TrivialRegisterPassable
    ](self, var name: String) raises -> Sig:
        """An exported entry point as a callable.

        `Sig` must be a thin C-ABI function type; spell every argument, since
        an under-declared signature compiles and then corrupts the call.

        Parameters:
            Sig: The entry point's function type.

        Args:
            name: The export's name.

        Returns:
            The entry point, ready to call.

        Raises:
            If the module did not load or the export is absent.
        """
        var entry = self.address_of(name)  # copy; the name is still needed below
        if entry == 0:
            raise Error("Win32 entry point not found: " + name)
        return Pointer(to=entry).unsafe_bitcast[Sig]()[]
