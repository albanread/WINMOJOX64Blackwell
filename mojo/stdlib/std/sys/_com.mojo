# ===----------------------------------------------------------------------=== #
# Calling COM.
#
# A COM object is a pointer to a pointer to an array of function pointers. A
# call is therefore an indexed load from that array, which means the only fact
# a caller needs beyond the method's signature is which slot -- and slots are
# in the Win32 metadata, so `winkb_vtable_index` supplies them and nothing here
# has to be generated or kept in step with Windows by hand.
#
# That matters most for inherited methods. `IStream::Write` is inherited from
# `ISequentialStream`, which itself sits above `IUnknown`, so Write is slot 4
# rather than slot 0 -- exactly the arithmetic a hand-written binding gets
# wrong, silently, by calling whatever else happens to be in that slot.
# ===----------------------------------------------------------------------=== #

from std.memory import Pointer, OpaquePointer
from std.sys._winkb import winkb_interface_iid, winkb_vtable_index


@always_inline
def com_method[
    Sig: TrivialRegisterPassable, slot: Int
](this: OpaquePointer[MutUntrackedOrigin]) -> Sig:
    """Fetch the function in vtable `slot` of a COM object.

    `Sig` must be a thin C-ABI function type whose first parameter is the
    interface pointer, since COM passes `this` as an ordinary first argument.

    Parameters:
        Sig: The method's function type, e.g.
            `def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> UInt32`.
        slot: The vtable slot, normally from `winkb_vtable_index`.

    Args:
        this: The interface pointer.

    Returns:
        The method, ready to call with `this` as its first argument.
    """
    # *this is the vtable; the vtable is an array of function pointers.
    var vtable = this.unsafe_bitcast[OpaquePointer[MutUntrackedOrigin]]()[]
    var entry = vtable.unsafe_bitcast[
        OpaquePointer[MutUntrackedOrigin]
    ]().unsafe_offset(slot)[]
    return Pointer(to=entry).unsafe_bitcast[Sig]()[]


@always_inline
def com_method_of[
    Sig: TrivialRegisterPassable,
    interface_name: StaticString,
    method_name: StaticString,
](this: OpaquePointer[MutUntrackedOrigin]) -> Sig:
    """Fetch a COM method by name, taking its slot from the Win32 metadata.

    Name the interface that *declares* the method rather than the one being
    called through: metadata slots are absolute, so asking for
    `["ISequentialStream", "Write"]` yields 4, which is correct for any
    `IStream` too.

    Parameters:
        Sig: The method's thin C-ABI function type.
        interface_name: The interface declaring the method.
        method_name: The method's name.

    Args:
        this: The interface pointer.

    Returns:
        The method, ready to call with `this` as its first argument.
    """
    return com_method[Sig, winkb_vtable_index[interface_name, method_name]()](
        this
    )


def _hex_nibble(c: UInt8) -> Int:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return Int(c) - ord("0")
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return Int(c) - ord("a") + 10
    return Int(c) - ord("A") + 10


def _guid_bytes(text: StaticString) -> List[UInt8]:
    """The 16 bytes COM expects for a textual GUID.

    Not text order: the first three groups are little-endian integers and the
    last eight bytes literal. Wrong order yields E_NOINTERFACE, which looks
    like an unsupported interface rather than a mangled identifier.
    """
    var digits = List[UInt8]()
    for byte in text.as_bytes():
        if byte != UInt8(ord("-")):
            digits.append(byte)

    var raw = List[UInt8]()
    for i in range(16):
        raw.append(
            UInt8(
                _hex_nibble(digits[i * 2]) * 16 + _hex_nibble(digits[i * 2 + 1])
            )
        )

    var out = List[UInt8]()
    out.append(raw[3])
    out.append(raw[2])
    out.append(raw[1])
    out.append(raw[0])
    out.append(raw[5])
    out.append(raw[4])
    out.append(raw[7])
    out.append(raw[6])
    for i in range(8, 16):
        out.append(raw[i])
    return out^


struct ComPtr[interface_name: StaticString](Boolable, Copyable, Movable):
    """An owning COM interface pointer whose refcounting is the type's
    ownership semantics.

    The mapping is exact, and the compiler proves it instead of a reviewer
    auditing it:

    - copying AddRefs;
    - destruction Releases;
    - a move does neither, because `deinit move` consumes the source without
      running its destructor -- so idiomatic Mojo passing interface pointers
      around elides AddRef/Release pairs that C++ smart pointers pay on every
      copy.

    Construction from an out-parameter uses `adopt=`, which deliberately does
    NOT AddRef: COM out-parameters arrive with the callee's reference already
    counted, and the adopter takes ownership of it. AddReffing there leaks;
    failing to AddRef on a copy crashes. Both directions are now the
    compiler's problem.

    Parameters:
        interface_name: The COM interface, e.g. "IStream". Used to infer the
            IID for `query_interface`, so a GUID never appears in user code
            and an IID/type mismatch is not expressible.
    """

    var _address: Int

    def __init__(out self, *, adopt: Int):
        """Takes ownership of a pre-AddRef'd interface pointer.

        This is the out-parameter convention: the reference being adopted is
        the one the callee already counted, so no AddRef happens here.

        Args:
            adopt: The raw interface pointer, as received from an out-param.
        """
        self._address = adopt

    def __init__(out self, *, copy: Self):
        """Copies the pointer and AddRefs the underlying object.

        Args:
            copy: The value being copied.
        """
        self._address = copy._address
        if self._address != 0:
            _ = com_method[
                def (
                    OpaquePointer[MutUntrackedOrigin]
                ) thin abi("C") -> UInt32,
                winkb_vtable_index["IUnknown", "AddRef"](),
            ](copy.interface())(copy.interface())

    def __init__(out self, *, deinit move: Self):
        """Moves the pointer; the refcount is untouched.

        The source is consumed without its destructor running, so the
        AddRef/Release pair a copy would cost is elided entirely.

        Args:
            move: The value being moved from.
        """
        self._address = move._address

    def __deinit__(deinit self):
        """Releases the underlying object, if any."""
        if self._address != 0:
            _ = com_method[
                def (
                    OpaquePointer[MutUntrackedOrigin]
                ) thin abi("C") -> UInt32,
                winkb_vtable_index["IUnknown", "Release"](),
            ](self.interface())(self.interface())

    def __bool__(self) -> Bool:
        """Whether a pointer is held.

        Returns:
            True if non-null.
        """
        return self._address != 0

    def interface(self) -> OpaquePointer[MutUntrackedOrigin]:
        """The raw interface pointer, for `com_method` calls.

        Returns:
            The pointer; ownership stays with this value.
        """
        return OpaquePointer[MutUntrackedOrigin](
            unsafe_from_address=self._address
        )

    def query_interface[
        Target: StaticString
    ](self) raises -> ComPtr[Target]:
        """Asks the object for another interface, IID inferred from the type.

        The returned pointer arrives pre-AddRef'd from QueryInterface and is
        adopted, so the count stays exact.

        Parameters:
            Target: The interface to request, e.g. "ISequentialStream".

        Returns:
            An owning pointer to the requested interface.

        Raises:
            If the object does not implement it (E_NOINTERFACE), or the
            pointer is null.
        """
        if self._address == 0:
            raise Error("query_interface on a null ComPtr")

        var iid = _guid_bytes(winkb_interface_iid[Target]())
        var out_address: Int = 0
        var hr = com_method[
            def (
                OpaquePointer[MutUntrackedOrigin],
                Pointer[UInt8, MutAnyOrigin],
                Pointer[Int, MutAnyOrigin],
            ) thin abi("C") -> Int32,
            winkb_vtable_index["IUnknown", "QueryInterface"](),
        ](self.interface())(
            self.interface(),
            iid.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            Pointer(to=out_address).unsafe_origin_cast[MutAnyOrigin](),
        )
        if hr != 0:
            raise Error(
                "QueryInterface for "
                + String(Target)
                + " failed, hr = "
                + String(hr)
            )
        return ComPtr[Target](adopt=out_address)


# ===----------------------------------------------------------------------=== #
# A note on origins, which is where this is easy to get wrong
#
# Interface pointers use OpaquePointer[MutUntrackedOrigin], and that is the
# documented use of an untracked origin: memory from outside the Mojo program,
# aliasing no value the compiler manages.
#
# Everything ELSE a COM method touches -- out-parameters, descriptor structs,
# buffers -- IS Mojo-owned memory, and casting its pointer to an untracked
# origin tells the lifetime checker the pointer does not alias it. The
# compiler is then free to hand the callee a temporary: the call succeeds, the
# write lands nowhere, and the local keeps its old value. It can also appear
# to work, which is worse. This was found by sentinel: a counter set to 999
# survived a Write that reported success.
#
# So a Sig's pointer parameters are spelled over AnyOrigin, which keeps the
# aliasing ("might access any memory value"):
#
#     def (
#         OpaquePointer[MutUntrackedOrigin],      # this -- from Windows
#         Pointer[UInt32, MutAnyOrigin],          # out-param -- ours
#     ) thin abi("C") -> c_int
#
# and a call site casts to the SAME:
#
#     write(this, ..., Pointer(to=written).unsafe_origin_cast[MutAnyOrigin]())
#
# Variadic calls (external_call, _DLCallable) need no cast at all: pass
# Pointer(to=local) and the true origin is inferred, which is what the
# standard library itself does at every libc boundary.
# ===----------------------------------------------------------------------=== #
