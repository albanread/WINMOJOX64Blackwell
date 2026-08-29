# ===----------------------------------------------------------------------=== #
# COM, spoken from the metadata.
#
# This module is the consumption surface language_update.md specifies: typed
# COM calls whose vtable slots, arities and argument widths come from the
# Win32 metadata database at compile time, HRESULT as a distinct type whose
# failures raise, and apartment lifetime as a scope.
#
# The design rules are inherited and referenced rather than restated:
# never guess (an unmodelled signature is a compile error, not an inference);
# a configuration error must not wear a source error's clothes; the raw layer
# (`com_method_of` in std.sys._com) is permanent and this sits strictly above
# it. The width discipline is the Modula-2 port's f32 lesson: struct fields
# tolerate a lossy mapping, an interface ABI must be exact.
# ===----------------------------------------------------------------------=== #

from std.ffi import c_int
from std.sys import size_of
from std.sys._win32 import Win32Module
from std.memory import Pointer, OpaquePointer
from std.sys._com import ComPtr, com_method, _guid_bytes
from std.sys._winkb import (
    winkb_interface_iid,
    winkb_vtable_index,
    winkb_com_ret_type,
    winkb_com_param_count,
    winkb_com_param_type,
    winkb_type_width,
)

# ===----------------------------------------------------------------------=== #
# HResult
# ===----------------------------------------------------------------------=== #

comptime S_OK = HResult(0)
comptime S_FALSE = HResult(1)
comptime E_NOTIMPL = HResult(Int32(-2147467263))  # 0x80004001
comptime E_NOINTERFACE = HResult(Int32(-2147467262))  # 0x80004002
comptime E_FAIL = HResult(Int32(-2147467259))  # 0x80004005
comptime RPC_E_CHANGED_MODE = HResult(Int32(-2147417850))  # 0x80010106


struct HResult(Copyable, Movable, TrivialRegisterPassable):
    """A COM result code, held at its true width.

    The width is the point, not a detail. A virtual COM method returns its
    HRESULT in EAX, which zeroes the upper half of RAX -- so a negative code
    read into a 64-bit integer looks positive and a `< 0` test is always
    false. Holding the value as `Int32` makes the sign test correct by
    construction; the Modula-2 port caught this bug live and this type is why
    it cannot recur here.
    """

    var value: Int32
    """The raw 32-bit result code."""

    def __init__(out self, value: Int32):
        """Wraps a raw code.

        Args:
            value: The 32-bit HRESULT as returned by the call.
        """
        self.value = value

    def succeeded(self) -> Bool:
        """Whether the code reports success.

        Returns:
            True for S_OK, S_FALSE and every other non-negative code.
        """
        return self.value >= 0

    def failed(self) -> Bool:
        """Whether the code reports failure.

        Returns:
            True when the severity bit is set.
        """
        return self.value < 0

    def raise_for[context: StaticString](self) raises:
        """Raises if this code reports failure, naming the operation.

        The return value decides; any out-parameter is only meaningful after
        this returns.

        Parameters:
            context: What was being attempted, for the error text.

        Raises:
            If the code's severity bit is set.
        """
        if self.value < 0:
            raise Error(
                String(context) + " failed, hr = " + String(Int(self.value))
            )


# ===----------------------------------------------------------------------=== #
# Apartments
# ===----------------------------------------------------------------------=== #

comptime COINIT_APARTMENTTHREADED = 0x2
comptime COINIT_MULTITHREADED = 0x0


struct Apartment:
    """A COM apartment held for a scope.

    `with Apartment():` initialises COM on the current thread and
    uninitialises it on exit, balanced exactly once, which is the discipline
    CoInitializeEx demands and manual code forgets. S_FALSE (already
    initialised on this thread) still requires the balancing uninitialise and
    gets it; RPC_E_CHANGED_MODE (the thread already committed to the other
    model) raises and uninitialises nothing, because in that case the
    reference was never added.
    """

    var _ole32: Win32Module
    var _model: Int32
    var _owns: Bool

    def __init__(out self, *, multithreaded: Bool = False):
        """Prepares an apartment scope; nothing happens until entry.

        Args:
            multithreaded: True for the MTA; the default is the STA, which is
                what a thread that owns windows wants.
        """
        self._ole32 = Win32Module("ole32.dll")
        self._model = Int32(
            COINIT_MULTITHREADED if multithreaded else COINIT_APARTMENTTHREADED
        )
        self._owns = False

    def __enter__(mut self) raises:
        """Initialises COM on this thread.

        Raises:
            If the thread is already committed to the other apartment model,
            or initialisation fails outright.
        """
        var hr = HResult(
            self._ole32.function[
                def (Int, Int32) thin abi("C") -> Int32
            ]("CoInitializeEx")(0, self._model)
        )
        if hr.value == RPC_E_CHANGED_MODE.value:
            raise Error(
                "this thread is already committed to the other COM apartment"
                " model; CoInitializeEx returned RPC_E_CHANGED_MODE"
            )
        hr.raise_for["CoInitializeEx"]()
        # S_OK and S_FALSE both added a reference that must be released.
        self._owns = True

    def __exit__(mut self):
        """Uninitialises COM, balancing the successful initialise."""
        if self._owns:
            # __exit__ cannot raise, and `function[]` can (absent export), so
            # resolve by address here; ole32 exporting CoInitializeEx but not
            # CoUninitialize is not a real machine.
            var addr = self._ole32.address_of("CoUninitialize")
            if addr != 0:
                Pointer(to=addr).unsafe_bitcast[
                    def () thin abi("C") -> NoneType
                ]()[]()
            self._owns = False


# ===----------------------------------------------------------------------=== #
# Activation
# ===----------------------------------------------------------------------=== #

comptime CLSCTX_INPROC_SERVER = 0x1
comptime CLSCTX_LOCAL_SERVER = 0x4


def co_create[
    clsid: StaticString, interface_name: StaticString
]() raises -> ComPtr[interface_name]:
    """Creates a COM object and asks it for an interface, in one step.

    The interface's IID comes from the metadata; the CLSID is written at the
    call site because the metadata database does not yet carry CLSID values
    (its guid-kind constants are present but valueless -- a recorded WRASM
    gap). Write it once, next to a name, and nowhere else.

    Parameters:
        clsid: The class ID, e.g. "dc1c5a9c-e88a-4dde-a5a1-60f82a20aef7"
            for FileOpenDialog. Hyphenated hex, case-insensitive.
        interface_name: The interface to request, e.g. "IFileOpenDialog".

    Returns:
        An owning pointer to the requested interface.

    Raises:
        If the class is not registered, the interface is not implemented, or
        COM is not initialised on this thread.
    """
    var clsid_bytes = _guid_bytes(clsid)
    if len(clsid_bytes) != 16:
        raise Error("malformed CLSID: " + String(clsid))
    var iid_bytes = _guid_bytes(winkb_interface_iid[interface_name]())
    var out_address: Int = 0
    var hr = HResult(
        Win32Module("ole32.dll").function[
            def (
                Pointer[UInt8, MutAnyOrigin],
                Int,
                UInt32,
                Pointer[UInt8, MutAnyOrigin],
                Pointer[Int, MutAnyOrigin],
            ) thin abi("C") -> Int32
        ]("CoCreateInstance")(
            clsid_bytes.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            0,
            UInt32(CLSCTX_INPROC_SERVER | CLSCTX_LOCAL_SERVER),
            iid_bytes.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            Pointer(to=out_address).unsafe_origin_cast[MutAnyOrigin](),
        )
    )
    hr.raise_for["CoCreateInstance"]()
    return ComPtr[interface_name](adopt=out_address)


# ===----------------------------------------------------------------------=== #
# Typed calls: Com["IStream"] and the bound-method carrier
# ===----------------------------------------------------------------------=== #


def _is_ptr[t: StaticString]() -> Bool:
    """Whether a metadata type name is a pointer spelling ('...*')."""
    var bytes = t.as_bytes()
    return len(bytes) > 0 and bytes[len(bytes) - 1] == UInt8(ord("*"))


def _expected_width[t: StaticString]() -> Int:
    """The byte width the Win64 ABI passes for a metadata parameter type.

    Pointers and pointer-sized handles are 8. Primitives map by name. Anything
    else -- enums, by-value structs -- is sized by the metadata itself. A
    by-value struct wider than 8 bytes travels by reference on Win64, so its
    expected width is 8 and the caller passes a Pointer to it.
    """
    # One chain, deliberately: statements after a taken `comptime if ...
    # return` still elaborate, so the metadata fallback must sit in the final
    # `else` to be pruned when a primitive already answered.
    comptime if _is_ptr[t]():
        return 8
    elif t == "i8" or t == "u8" or t == "bool":
        return 1
    elif t == "i16" or t == "u16" or t == "char":
        return 2
    elif t == "i32" or t == "u32" or t == "f32":
        return 4
    elif (
        t == "i64" or t == "u64" or t == "f64" or t == "isize" or t == "usize"
    ):
        return 8
    else:
        comptime width = winkb_type_width[t]()
        comptime if width > 8:
            return 8  # by reference on Win64
        else:
            return width


def _check_arg[
    interface_name: StaticString,
    method: StaticString,
    ordinal: StaticString,
    A: AnyType,
]():
    """Compile-time check of one argument against the metadata.

    Width only, for now: it catches the recorded disaster class (an f32 slot
    fed an 8-byte double corrupts the virtual call), and the register-file
    half (int vs float of equal width) is named future work in
    language_update.md rather than silently skipped.
    """
    comptime declared = winkb_com_param_type[interface_name, method, ordinal]()
    comptime expect = _expected_width[declared]()
    comptime assert size_of[A]() == expect, (
        "argument width disagrees with the metadata for this parameter of "
        + String(interface_name)
        + "."
        + String(method)
        + ": the SDK declares '"
        + String(declared)
        + "'. Pass a value of that width; pointers and out-parameters are"
        " 8-byte Pointers"
    )


def _check_hresult_method[
    interface_name: StaticString, method: StaticString, arity: Int
]():
    """The shared compile-time gate for a typed call.

    Existence is checked by the slot query itself -- an unknown method fails
    elaboration with the metadata's own diagnostic. This adds arity, and the
    v1 scope rule: the typed surface speaks HRESULT-returning methods, which
    is the COM convention; the rare non-HRESULT method (AddRef, Release --
    already the ownership type's job) stays on the raw layer.
    """
    comptime declared_arity = winkb_com_param_count[interface_name, method]()
    comptime assert declared_arity == arity, (
        "wrong argument count for "
        + String(interface_name)
        + "."
        + String(method)
        + ": the SDK declares a different arity. Out-parameters count; pass"
        " a Pointer for each"
    )
    comptime ret = winkb_com_ret_type[interface_name, method]()
    comptime assert ret == "Windows.Win32.Foundation.HRESULT", (
        "the typed surface only speaks HRESULT-returning methods;"
        " this one returns '"
        + String(winkb_com_ret_type[interface_name, method]())
        + "' -- call it through com_method_of on the raw layer"
    )


@fieldwise_init
struct _ComBound[interface_name: StaticString, method: StaticString](
    TrivialRegisterPassable
):
    """A method name bound to an interface pointer, awaiting its arguments.

    Exists because the argument count is only known at the call, so the
    attribute reference cannot check or dispatch by itself; this carries the
    names to the `__call__` that can. The same shape as the Mac ports'
    `Bound`, minus everything selectors required.
    """

    var _this: OpaquePointer[MutUntrackedOrigin]

    def __call__(self) raises -> HResult:
        """Calls a zero-argument COM method.

        Returns:
            The successful HResult (S_OK or another success code).

        Raises:
            If the method reports failure.
        """
        _check_hresult_method[Self.interface_name, Self.method, 0]()
        var hr = HResult(
            com_method[
                def (
                    OpaquePointer[MutUntrackedOrigin]
                ) thin abi("C") -> Int32,
                winkb_vtable_index[Self.interface_name, Self.method](),
            ](self._this)(self._this)
        )
        hr.raise_for[Self.method]()
        return hr

    def __call__[A0: TrivialRegisterPassable](self, a0: A0) raises -> HResult:
        """Calls a one-argument COM method.

        Parameters:
            A0: The argument's Mojo type; width-checked against the SDK.

        Args:
            a0: The argument.

        Returns:
            The successful HResult.

        Raises:
            If the method reports failure.
        """
        _check_hresult_method[Self.interface_name, Self.method, 1]()
        _check_arg[Self.interface_name, Self.method, "0", A0]()
        var hr = HResult(
            com_method[
                def (
                    OpaquePointer[MutUntrackedOrigin], A0
                ) thin abi("C") -> Int32,
                winkb_vtable_index[Self.interface_name, Self.method](),
            ](self._this)(self._this, a0)
        )
        hr.raise_for[Self.method]()
        return hr

    def __call__[
        A0: TrivialRegisterPassable, A1: TrivialRegisterPassable
    ](self, a0: A0, a1: A1) raises -> HResult:
        """Calls a two-argument COM method.

        Parameters:
            A0: The first argument's Mojo type; width-checked.
            A1: The second argument's Mojo type; width-checked.

        Args:
            a0: The first argument.
            a1: The second argument.

        Returns:
            The successful HResult.

        Raises:
            If the method reports failure.
        """
        _check_hresult_method[Self.interface_name, Self.method, 2]()
        _check_arg[Self.interface_name, Self.method, "0", A0]()
        _check_arg[Self.interface_name, Self.method, "1", A1]()
        var hr = HResult(
            com_method[
                def (
                    OpaquePointer[MutUntrackedOrigin], A0, A1
                ) thin abi("C") -> Int32,
                winkb_vtable_index[Self.interface_name, Self.method](),
            ](self._this)(self._this, a0, a1)
        )
        hr.raise_for[Self.method]()
        return hr

    def __call__[
        A0: TrivialRegisterPassable,
        A1: TrivialRegisterPassable,
        A2: TrivialRegisterPassable,
    ](self, a0: A0, a1: A1, a2: A2) raises -> HResult:
        """Calls a three-argument COM method.

        Parameters:
            A0: The first argument's Mojo type; width-checked.
            A1: The second argument's Mojo type; width-checked.
            A2: The third argument's Mojo type; width-checked.

        Args:
            a0: The first argument.
            a1: The second argument.
            a2: The third argument.

        Returns:
            The successful HResult.

        Raises:
            If the method reports failure.
        """
        _check_hresult_method[Self.interface_name, Self.method, 3]()
        _check_arg[Self.interface_name, Self.method, "0", A0]()
        _check_arg[Self.interface_name, Self.method, "1", A1]()
        _check_arg[Self.interface_name, Self.method, "2", A2]()
        var hr = HResult(
            com_method[
                def (
                    OpaquePointer[MutUntrackedOrigin], A0, A1, A2
                ) thin abi("C") -> Int32,
                winkb_vtable_index[Self.interface_name, Self.method](),
            ](self._this)(self._this, a0, a1, a2)
        )
        hr.raise_for[Self.method]()
        return hr

    def __call__[
        A0: TrivialRegisterPassable,
        A1: TrivialRegisterPassable,
        A2: TrivialRegisterPassable,
        A3: TrivialRegisterPassable,
    ](self, a0: A0, a1: A1, a2: A2, a3: A3) raises -> HResult:
        """Calls a four-argument COM method.

        Parameters:
            A0: The first argument's Mojo type; width-checked.
            A1: The second argument's Mojo type; width-checked.
            A2: The third argument's Mojo type; width-checked.
            A3: The fourth argument's Mojo type; width-checked.

        Args:
            a0: The first argument.
            a1: The second argument.
            a2: The third argument.
            a3: The fourth argument.

        Returns:
            The successful HResult.

        Raises:
            If the method reports failure.
        """
        _check_hresult_method[Self.interface_name, Self.method, 4]()
        _check_arg[Self.interface_name, Self.method, "0", A0]()
        _check_arg[Self.interface_name, Self.method, "1", A1]()
        _check_arg[Self.interface_name, Self.method, "2", A2]()
        _check_arg[Self.interface_name, Self.method, "3", A3]()
        var hr = HResult(
            com_method[
                def (
                    OpaquePointer[MutUntrackedOrigin], A0, A1, A2, A3
                ) thin abi("C") -> Int32,
                winkb_vtable_index[Self.interface_name, Self.method](),
            ](self._this)(self._this, a0, a1, a2, a3)
        )
        hr.raise_for[Self.method]()
        return hr


struct Com[interface_name: StaticString](TrivialRegisterPassable):
    """A typed, non-owning view of a COM interface for making calls.

    `Com["IStream"](of=stream).Write(ptr, n, out)` dispatches through the
    vtable slot the metadata records for Write, checks the arity and every
    argument's width at compile time, and raises if the HRESULT reports
    failure. The interface name is a string parameter, so the reachable
    surface is whatever the metadata knows -- nothing here is generated.

    Ownership stays with the `ComPtr` this views; a `Com` neither AddRefs nor
    Releases, and must not outlive its source.

    Parameters:
        interface_name: The COM interface, e.g. "IStream". Methods from its
            whole inheritance chain are callable, at their absolute slots.
    """

    var _this: OpaquePointer[MutUntrackedOrigin]

    def __init__(out self, *, of: ComPtr[Self.interface_name]):
        """Views an owning pointer, without touching its refcount.

        Args:
            of: The owning pointer to call through.
        """
        self._this = of.interface()

    def __getattr_param__[
        name: StringLiteral
    ](self) -> _ComBound[Self.interface_name, name]:
        """Binds a method name for calling.

        The name arrives as a compile-time parameter -- the whole mechanism --
        so the call that follows can consult the metadata about it.

        Parameters:
            name: The method name, exactly as the SDK spells it.

        Returns:
            The bound method, awaiting arguments.
        """
        return _ComBound[Self.interface_name, name](self._this)
