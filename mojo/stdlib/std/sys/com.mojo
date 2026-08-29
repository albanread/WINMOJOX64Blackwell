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

from std.atomic import Atomic
from std.ffi import c_int
from std.memory import alloc
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
    winkb_com_method_count,
    winkb_com_has_method,
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
    var _ole: Bool

    def __init__(out self, *, multithreaded: Bool = False, ole: Bool = False):
        """Prepares an apartment scope; nothing happens until entry.

        Args:
            multithreaded: True for the MTA; the default is the STA, which is
                what a thread that owns windows wants.
            ole: True to initialise full OLE rather than bare COM. Drag and
                drop registration and the OLE clipboard require it, and it is
                STA by definition, so it excludes `multithreaded`.
        """
        self._ole32 = Win32Module("ole32.dll")
        self._model = Int32(
            COINIT_MULTITHREADED if multithreaded else COINIT_APARTMENTTHREADED
        )
        self._owns = False
        self._ole = ole

    def __enter__(mut self) raises:
        """Initialises COM -- or, for `ole=True`, OLE -- on this thread.

        Raises:
            If the thread is already committed to the other apartment model,
            or initialisation fails outright.
        """
        if self._ole:
            if self._model != Int32(COINIT_APARTMENTTHREADED):
                raise Error("OLE apartments are single-threaded by definition")
            var ole_hr = HResult(
                self._ole32.function[def (Int) thin abi("C") -> Int32](
                    "OleInitialize"
                )(0)
            )
            if ole_hr.value == RPC_E_CHANGED_MODE.value:
                raise Error(
                    "this thread is already committed to the MTA;"
                    " OleInitialize returned RPC_E_CHANGED_MODE"
                )
            ole_hr.raise_for["OleInitialize"]()
            self._owns = True
            return
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
            # resolve by address here; ole32 exporting the initialiser but not
            # the uninitialiser is not a real machine.
            var addr = self._ole32.address_of(
                "OleUninitialize" if self._ole else "CoUninitialize"
            )
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


# ===----------------------------------------------------------------------=== #
# Implementing COM objects: the class runtime
#
# The runtime behind the `class` keyword, and a usable library in its own
# right. One heap block per object, holding every interface it implements.
#
# A COM interface pointer must point at a word holding that interface's vtable
# pointer -- so an object implementing several interfaces needs several such
# words at distinct addresses. This is the layout C++ multiple inheritance
# produces, and what Windows expects: one 2-word cell per interface, each
# carrying its own vtable pointer and the byte offset back to the block base.
# Any method, given the `this` it was called with, subtracts that offset and
# is back at the object.
#
#   word 0            refcount, atomic
#   word 1            accepted-IID table pointer (into this block)
#   word 2            accepted-IID count
#   word 3            destructor fn (0 for none)
#   word 4            byte offset from the base to the user state
#   word 5            pointer to the per-IID cell index table
#   words 6,7         cell 0: [vtable ptr][offset back to base]  <- iface 0 ptr
#   words 8,9         cell 1: ...                                <- iface 1 ptr
#   ...               one cell per implemented interface
#   then              the vtables, the IID bytes, the IID->cell table,
#                     then the user state, zero-initialised
#
# AddRef, Release and QueryInterface are one generic implementation each,
# reading everything they need from the block -- an `fn` has no captures, so
# the object itself is the closure.
#
# What this is not: a true COM tear-off, which allocates a secondary interface
# lazily on first QueryInterface to keep rarely-used interfaces out of the
# object. Every interface here is embedded and always present, which costs 16
# bytes each and buys simpler lifetime rules -- there is exactly one refcount
# and one allocation, so a client holding any interface keeps the whole object
# alive, and Release from any interface frees it exactly once.
# ===----------------------------------------------------------------------=== #

comptime _COM_H_REFS = 0
comptime _COM_H_IIDS = 1
comptime _COM_H_IIDN = 2
comptime _COM_H_DTOR = 3
comptime _COM_H_STATE_OFF = 4
comptime _COM_H_IIDCELLS = 5
comptime _COM_H_WORDS = 6
# Within a cell: the vtable pointer, then the offset back to the block base.
comptime _COM_C_VTBL = 0
comptime _COM_C_BACK = 1
comptime _COM_C_WORDS = 2

comptime _E_NOTIMPL_RAW = Int32(-2147467263)
comptime _E_NOINTERFACE_RAW = Int32(-2147467262)


def com_fn_bits[Sig: TrivialRegisterPassable](f: Sig) -> Int:
    """The address bits of a thin fn value, for a vtable slot.

    Parameters:
        Sig: The fn's type.

    Args:
        f: The fn.

    Returns:
        Its address, as an Int.
    """
    var v = f
    return Pointer(to=v).unsafe_bitcast[Int]()[]


fn _com_cell_offset(cell: Int) -> Int:
    """Byte offset from the block base to a cell -- the interface pointer."""
    return (_COM_H_WORDS + cell * _COM_C_WORDS) * 8


fn com_class_base(this: Int) -> Int:
    """The object's block base, from any of its interface pointers.

    Every cell stores its own distance back to the base, so a method never
    needs to know which interface it was reached through.

    Args:
        this: An interface pointer belonging to the object.

    Returns:
        The address of the block base.
    """
    return (
        this
        - Pointer[Int, MutAnyOrigin](unsafe_from_address=this).unsafe_offset(
            _COM_C_BACK
        )[]
    )


def com_class_state(this: Int) -> Pointer[Int, MutAnyOrigin]:
    """The user-state words of a ComClassBuilder object, from a callback.

    Args:
        this: The interface pointer the callback received -- any of the
            object's interfaces.

    Returns:
        A pointer to the first state word.
    """
    var base = com_class_base(this)
    return Pointer[Int, MutAnyOrigin](
        unsafe_from_address=base
        + Pointer[Int, MutAnyOrigin](unsafe_from_address=base).unsafe_offset(
            _COM_H_STATE_OFF
        )[]
    )


fn _com_class_add_ref(this: Int) -> UInt32:
    var refs = Pointer[Scalar[DType.uint64], MutAnyOrigin](
        unsafe_from_address=com_class_base(this) + _COM_H_REFS * 8
    )
    return UInt32(
        Atomic[Scalar[DType.uint64]].fetch_add(
            refs, Scalar[DType.uint64](1)
        )
        + 1
    )


fn _com_class_release(this: Int) -> UInt32:
    var base = com_class_base(this)
    var refs = Pointer[Scalar[DType.uint64], MutAnyOrigin](
        unsafe_from_address=base + _COM_H_REFS * 8
    )
    # No static fetch_sub exists; adding the wrapped -1 is the same operation
    # on a uint64, and these callbacks are fns that cannot hold an Atomic by
    # reference.
    var before = Atomic[Scalar[DType.uint64]].fetch_add(
        refs, Scalar[DType.uint64](0) - 1
    )
    if before == 1:
        var obj = Pointer[Int, MutAnyOrigin](unsafe_from_address=base)
        var dtor_bits = obj.unsafe_offset(_COM_H_DTOR)[]
        if dtor_bits != 0:
            Pointer(to=dtor_bits).unsafe_bitcast[
                def (Int) thin abi("C") -> NoneType
            ]()[](base)
        obj.unsafe_free()
    return UInt32(before - 1)


fn _com_class_query_interface(this: Int, riid: Int, ppv: Int) -> Int32:
    var base = com_class_base(this)
    var hdr = Pointer[Int, MutAnyOrigin](unsafe_from_address=base)
    var iids = Pointer[UInt8, MutAnyOrigin](
        unsafe_from_address=hdr.unsafe_offset(_COM_H_IIDS)[]
    )
    var cells = Pointer[Int, MutAnyOrigin](
        unsafe_from_address=hdr.unsafe_offset(_COM_H_IIDCELLS)[]
    )
    var count = hdr.unsafe_offset(_COM_H_IIDN)[]
    var asked = Pointer[UInt8, MutAnyOrigin](unsafe_from_address=riid)
    var out = Pointer[Int, MutAnyOrigin](unsafe_from_address=ppv)
    for i in range(count):
        var hit = True
        for b in range(16):
            if iids.unsafe_offset(i * 16 + b)[] != asked.unsafe_offset(b)[]:
                hit = False
                break
        if hit:
            # Hand back the pointer for the cell that IID names, not the one
            # the caller happened to hold: that is the whole point of QI.
            var target = base + _com_cell_offset(cells.unsafe_offset(i)[])
            _ = _com_class_add_ref(target)
            out[] = target
            return 0
    out[] = 0
    return _E_NOINTERFACE_RAW


fn _com_class_dtor[T: Deinitable](base: Int) -> None:
    """Destroys the state a `finish_state` object owns.

    Release stores nothing about `T`, so the type is baked into this thunk at
    the point the object is built and reached through the block's destructor
    word. Without it the block is freed and `T`'s destructor never runs: a
    class holding a String, a List or a ComPtr leaks its contents on the last
    Release, and trivial state hides it completely.

    Parameters:
        T: The state struct.

    Args:
        base: The object's block base, as Release passes it.
    """
    Pointer[T, MutAnyOrigin](
        unsafe_from_address=base
        + Pointer[Int, MutAnyOrigin](unsafe_from_address=base).unsafe_offset(
            _COM_H_STATE_OFF
        )[]
    ).unsafe_deinit_pointee()


fn _com_class_notimpl(this: Int) -> Int32:
    # Serves ANY arity: extra arguments arrive in registers and shadow space
    # the callee never reads, and Win64 is caller-cleanup, so ignoring them
    # is sound. Opt-in per slot via `ComClassBuilder.notimpl`.
    return _E_NOTIMPL_RAW


struct ComClassBuilder[*interfaces: StaticString]:
    """Builds a live COM object implementing one or more interface chains.

    The three IUnknown slots of every interface are the library's; each other
    slot must be filled (`slot`/`method`) or explicitly declined (`notimpl`)
    before `finish` will produce an object -- an incompletely implemented
    interface is a construction error, never a silent vtable hole. Slot
    indices come from the metadata, so declaration order in user code is
    meaningless and cannot corrupt dispatch.

    With several interfaces, a method is routed to the one that declares it;
    `method` and `slot` take the name alone and find its interface. A name
    declared by more than one of them is ambiguous and refused.

    v1 scope, recorded honestly: QueryInterface answers each implemented
    interface and IUnknown, but not the intermediate bases of a deeper chain
    (IDropTarget and IDropSource derive straight from IUnknown, so the
    drag-and-drop pair is complete; an IStream would not answer to
    ISequentialStream). The fn signatures themselves are not checked against
    the metadata -- the `class` keyword's trampolines do that.

    Parameters:
        interfaces: The COM interfaces the object implements, primary first.
    """

    var _slots: List[List[Int]]
    var _iids: List[UInt8]
    var _iid_cells: List[Int]

    def __init__(out self):
        """Prepares the builder with every interface's IUnknown prefilled."""
        self._slots = List[List[Int]]()
        self._iids = List[UInt8]()
        self._iid_cells = List[Int]()

        comptime for c in range(len(Self.interfaces)):
            var v = List[Int]()
            for _ in range(winkb_com_method_count[Self.interfaces[c]]()):
                v.append(0)
            # Every COM interface begins with IUnknown's three slots, and each
            # cell needs its own copy: the vtable a client holds must answer
            # QueryInterface/AddRef/Release whichever interface it reached.
            v[0] = com_fn_bits[def (Int, Int, Int) thin abi("C") -> Int32](
                _com_class_query_interface
            )
            v[1] = com_fn_bits[def (Int) thin abi("C") -> UInt32](
                _com_class_add_ref
            )
            v[2] = com_fn_bits[def (Int) thin abi("C") -> UInt32](
                _com_class_release
            )
            self._slots.append(v^)
            for b in _guid_bytes(winkb_interface_iid[Self.interfaces[c]]()):
                self._iids.append(b)
            self._iid_cells.append(c)

        # IUnknown resolves to the primary interface, as COM requires: the
        # identity pointer must be the same one every time it is asked for.
        for b in _guid_bytes(winkb_interface_iid["IUnknown"]()):
            self._iids.append(b)
        self._iid_cells.append(0)

    @staticmethod
    def _cell_of[method: StaticString]() -> Int:
        """Which implemented interface declares `method`; -1 if none."""
        var found = -1
        comptime for c in range(len(Self.interfaces)):
            comptime if winkb_com_has_method[Self.interfaces[c], method]():
                if found < 0:
                    found = c
        return found

    @staticmethod
    def _declarers_of[method: StaticString]() -> Int:
        """How many implemented interfaces declare `method`.

        More than one means the name is ambiguous, and binding it to whichever
        interface happens to be listed first would put the implementation in a
        slot the caller never meant -- silently, and only on one of the two
        vtables. Counting lets that be refused instead.
        """
        var n = 0
        comptime for c in range(len(Self.interfaces)):
            comptime if winkb_com_has_method[Self.interfaces[c], method]():
                n += 1
        return n

    def slot[
        method: StaticString, Sig: TrivialRegisterPassable
    ](mut self, f: Sig):
        """Fills one method slot, at the index the metadata records.

        Parameters:
            method: The method's name, on any implemented interface.
            Sig: The fn's type. Its first parameter receives `this` as an
                Int; reach the object's state with `com_class_state`.

        Args:
            f: The implementation.
        """
        comptime cell = Self._cell_of[method]()
        comptime assert cell >= 0, (
            "no implemented interface declares this method"
        )
        comptime index = winkb_vtable_index[Self.interfaces[cell], method]()
        comptime assert index >= 3, (
            "the IUnknown slots are the library's; do not replace them"
        )
        comptime assert Self._declarers_of[method]() == 1, (
            "ambiguous method name: more than one implemented interface"
            " declares it, so which vtable slot it belongs in is undefined"
        )
        self._slots[cell][index] = com_fn_bits[Sig](f)

    def method[
        T: AnyType, //, name: StaticString, m: def (mut T) raises thin -> None
    ](mut self):
        """Fills slot `name` with a zero-argument method, arity chosen for you.

        The uniform form the `class` keyword emits: name the method, hand the
        method value, and the overload set picks the trampoline matching its
        arity. The caller never spells com_trampN or counts arguments, and
        with several interfaces the slot is found on whichever declares it.

        Parameters:
            T: The implementing struct, inferred from the method.
            name: The COM method name.
            m: The method, e.g. `DropTarget.DragLeave`.
        """
        # The implementation side is checked exactly as the calling side is:
        # a method whose shape disagrees with the metadata fills a slot that
        # half-works. Win64 is caller-cleanup, so too few arguments are
        # silently ignored -- the call "succeeds" and out-parameters are never
        # written -- and too many read registers the caller never set.
        comptime _c = Self._cell_of[name]()
        comptime assert _c >= 0, (
            "no implemented interface declares this method"
        )
        _check_hresult_method[Self.interfaces[_c], name, 0]()
        self.slot[name](com_tramp0[m])

    def method[
        T: AnyType,
        A0: AnyType,
        //,
        name: StaticString,
        m: def (mut T, A0) raises thin -> None,
    ](mut self):
        """Fills slot `name` with a one-argument method.

        Parameters:
            T: The implementing struct.
            A0: The argument type.
            name: The COM method name.
            m: The method.
        """
        # The implementation side is checked exactly as the calling side is:
        # a method whose shape disagrees with the metadata fills a slot that
        # half-works. Win64 is caller-cleanup, so too few arguments are
        # silently ignored -- the call "succeeds" and out-parameters are never
        # written -- and too many read registers the caller never set.
        comptime _c = Self._cell_of[name]()
        comptime assert _c >= 0, (
            "no implemented interface declares this method"
        )
        _check_hresult_method[Self.interfaces[_c], name, 1]()
        _check_arg[Self.interfaces[_c], name, "0", A0]()
        self.slot[name](com_tramp1[m])

    def method[
        T: AnyType,
        A0: AnyType,
        A1: AnyType,
        //,
        name: StaticString,
        m: def (mut T, A0, A1) raises thin -> None,
    ](mut self):
        """Fills slot `name` with a two-argument method.

        Parameters:
            T: The implementing struct.
            A0: The first argument type.
            A1: The second argument type.
            name: The COM method name.
            m: The method.
        """
        # The implementation side is checked exactly as the calling side is:
        # a method whose shape disagrees with the metadata fills a slot that
        # half-works. Win64 is caller-cleanup, so too few arguments are
        # silently ignored -- the call "succeeds" and out-parameters are never
        # written -- and too many read registers the caller never set.
        comptime _c = Self._cell_of[name]()
        comptime assert _c >= 0, (
            "no implemented interface declares this method"
        )
        _check_hresult_method[Self.interfaces[_c], name, 2]()
        _check_arg[Self.interfaces[_c], name, "0", A0]()
        _check_arg[Self.interfaces[_c], name, "1", A1]()
        self.slot[name](com_tramp2[m])

    def method[
        T: AnyType,
        A0: AnyType,
        A1: AnyType,
        A2: AnyType,
        //,
        name: StaticString,
        m: def (mut T, A0, A1, A2) raises thin -> None,
    ](mut self):
        """Fills slot `name` with a three-argument method.

        Parameters:
            T: The implementing struct.
            A0: The first argument type.
            A1: The second argument type.
            A2: The third argument type.
            name: The COM method name.
            m: The method.
        """
        # The implementation side is checked exactly as the calling side is:
        # a method whose shape disagrees with the metadata fills a slot that
        # half-works. Win64 is caller-cleanup, so too few arguments are
        # silently ignored -- the call "succeeds" and out-parameters are never
        # written -- and too many read registers the caller never set.
        comptime _c = Self._cell_of[name]()
        comptime assert _c >= 0, (
            "no implemented interface declares this method"
        )
        _check_hresult_method[Self.interfaces[_c], name, 3]()
        _check_arg[Self.interfaces[_c], name, "0", A0]()
        _check_arg[Self.interfaces[_c], name, "1", A1]()
        _check_arg[Self.interfaces[_c], name, "2", A2]()
        self.slot[name](com_tramp3[m])

    def method[
        T: AnyType,
        A0: AnyType,
        A1: AnyType,
        A2: AnyType,
        A3: AnyType,
        //,
        name: StaticString,
        m: def (mut T, A0, A1, A2, A3) raises thin -> None,
    ](mut self):
        """Fills slot `name` with a four-argument method.

        Parameters:
            T: The implementing struct.
            A0: The first argument type.
            A1: The second argument type.
            A2: The third argument type.
            A3: The fourth argument type.
            name: The COM method name.
            m: The method.
        """
        # The implementation side is checked exactly as the calling side is:
        # a method whose shape disagrees with the metadata fills a slot that
        # half-works. Win64 is caller-cleanup, so too few arguments are
        # silently ignored -- the call "succeeds" and out-parameters are never
        # written -- and too many read registers the caller never set.
        comptime _c = Self._cell_of[name]()
        comptime assert _c >= 0, (
            "no implemented interface declares this method"
        )
        _check_hresult_method[Self.interfaces[_c], name, 4]()
        _check_arg[Self.interfaces[_c], name, "0", A0]()
        _check_arg[Self.interfaces[_c], name, "1", A1]()
        _check_arg[Self.interfaces[_c], name, "2", A2]()
        _check_arg[Self.interfaces[_c], name, "3", A3]()
        self.slot[name](com_tramp4[m])

    def wire_if_com[
        T: AnyType, //, name: StaticString, m: def (mut T) raises thin -> None
    ](mut self):
        """Wires a zero-argument method into its slot, if it is a COM method.

        What the `class` keyword emits for every `def` in a class body. A
        class may hold helpers -- `def reset(mut self)` -- and those are
        ordinary methods of the struct, not slots to fill; wiring every `def`
        unconditionally would reject them with a constraint failure from
        inside generated source, for a rule nobody would guess.

        The cost, stated plainly: a mistyped COM name (`DragEntr`) is also
        "not a COM method", so it stops being a compile-time error and
        becomes a missing slot -- caught by `finish`, which refuses to build
        an object with a hole, at construction rather than compilation.

        Parameters:
            T: The implementing struct, inferred from the method.
            name: The method's name.
            m: The method.
        """
        # comptime-if prunes INSTANTIATION, so an undeclared name never
        # reaches `method`'s constraints. It does not prune overload
        # conversion, which is why the catch-all overload below is also
        # needed: together they cover every shape a class body can hold.
        comptime if Self._cell_of[name]() >= 0:
            self.method[name, m]()

    def wire_if_com[
        T: AnyType,
        A0: AnyType,
        //,
        name: StaticString,
        m: def (mut T, A0) raises thin -> None,
    ](mut self):
        """Wires a one-argument method into its slot, if it is a COM method.

        Parameters:
            T: The implementing struct.
            A0: The argument type.
            name: The method's name.
            m: The method.
        """
        # comptime-if prunes INSTANTIATION, so an undeclared name never
        # reaches `method`'s constraints. It does not prune overload
        # conversion, which is why the catch-all overload below is also
        # needed: together they cover every shape a class body can hold.
        comptime if Self._cell_of[name]() >= 0:
            self.method[name, m]()

    def wire_if_com[
        T: AnyType,
        A0: AnyType,
        A1: AnyType,
        //,
        name: StaticString,
        m: def (mut T, A0, A1) raises thin -> None,
    ](mut self):
        """Wires a two-argument method into its slot, if it is a COM method.

        Parameters:
            T: The implementing struct.
            A0: The first argument type.
            A1: The second argument type.
            name: The method's name.
            m: The method.
        """
        # comptime-if prunes INSTANTIATION, so an undeclared name never
        # reaches `method`'s constraints. It does not prune overload
        # conversion, which is why the catch-all overload below is also
        # needed: together they cover every shape a class body can hold.
        comptime if Self._cell_of[name]() >= 0:
            self.method[name, m]()

    def wire_if_com[
        T: AnyType,
        A0: AnyType,
        A1: AnyType,
        A2: AnyType,
        //,
        name: StaticString,
        m: def (mut T, A0, A1, A2) raises thin -> None,
    ](mut self):
        """Wires a three-argument method into its slot, if it is a COM method.

        Parameters:
            T: The implementing struct.
            A0: The first argument type.
            A1: The second argument type.
            A2: The third argument type.
            name: The method's name.
            m: The method.
        """
        # comptime-if prunes INSTANTIATION, so an undeclared name never
        # reaches `method`'s constraints. It does not prune overload
        # conversion, which is why the catch-all overload below is also
        # needed: together they cover every shape a class body can hold.
        comptime if Self._cell_of[name]() >= 0:
            self.method[name, m]()

    def wire_if_com[
        T: AnyType,
        A0: AnyType,
        A1: AnyType,
        A2: AnyType,
        A3: AnyType,
        //,
        name: StaticString,
        m: def (mut T, A0, A1, A2, A3) raises thin -> None,
    ](mut self):
        """Wires a four-argument method into its slot, if it is a COM method.

        Parameters:
            T: The implementing struct.
            A0: The first argument type.
            A1: The second argument type.
            A2: The third argument type.
            A3: The fourth argument type.
            name: The method's name.
            m: The method.
        """
        # comptime-if prunes INSTANTIATION, so an undeclared name never
        # reaches `method`'s constraints. It does not prune overload
        # conversion, which is why the catch-all overload below is also
        # needed: together they cover every shape a class body can hold.
        comptime if Self._cell_of[name]() >= 0:
            self.method[name, m]()

    def wire_if_com[
        F: AnyType, //, name: StaticString, m: F
    ](mut self):
        """Absorbs a class method that is not shaped like a COM method.

        The overload the `class` desugar falls back to. A class body may hold
        helpers -- `def total(self) -> Int` -- and wiring every `def` into a
        slot would reject them for a rule nobody would guess. Overload
        resolution picks a COM-shaped overload when the signature fits one;
        anything else lands here and stays an ordinary method of the struct.

        `comptime if` cannot do this job: it does not prune type checking, so
        a guarded call still resolves its overloads and still fails. The
        filtering has to happen in the overload set itself.

        The name is still checked, which is what keeps the net tight: if an
        implemented interface *does* declare this name, then the method was
        meant to be a COM method and its signature is simply wrong -- say so,
        rather than silently leaving the slot empty.

        Parameters:
            F: The method's type, whatever it is.
            name: The method's name.
            m: The method.
        """
        comptime assert Self._cell_of[name]() < 0, (
            "'"
            + String(name)
            + "' is declared by an implemented COM interface, but this"
            " signature cannot fill its slot: a COM method takes `mut self`,"
            " is `raises`, returns nothing, and takes at most four arguments"
        )

    def notimpl[method: StaticString](mut self):
        """Declines one method, visibly: its slot answers E_NOTIMPL.

        Parameters:
            method: The method being declined.
        """
        comptime cell = Self._cell_of[method]()
        comptime assert cell >= 0, (
            "no implemented interface declares this method"
        )
        comptime index = winkb_vtable_index[Self.interfaces[cell], method]()
        comptime assert index >= 3, (
            "the IUnknown slots are the library's; do not replace them"
        )
        comptime assert Self._declarers_of[method]() == 1, (
            "ambiguous method name: more than one implemented interface"
            " declares it, so which vtable slot it belongs in is undefined"
        )
        self._slots[cell][index] = com_fn_bits[
            def (Int) thin abi("C") -> Int32
        ](_com_class_notimpl)

    def finish(
        var self, *, state_words: Int = 0
    ) raises -> ComPtr[Self.interfaces[0]]:
        """Allocates and wires the object; the creation reference is adopted.

        Args:
            state_words: Zero-initialised Int-sized words of user state,
                reachable from callbacks via `com_class_state`.

        Returns:
            An owning pointer to the new object's primary interface.

        Raises:
            If any slot is neither filled nor declined.
        """
        var missing = 0
        for c in range(len(self._slots)):
            for i in range(len(self._slots[c])):
                if self._slots[c][i] == 0:
                    missing += 1
        if missing != 0:
            raise Error(
                "ComClassBuilder["
                + String(Self.interfaces[0])
                + "]: "
                + String(missing)
                + " slot(s) neither implemented nor declined; fill each with"
                " slot[...] or decline it with notimpl[...] -- a silent"
                " vtable hole dispatches somewhere wrong, successfully"
            )

        var ncells = len(self._slots)
        var vtable_words = 0
        for c in range(ncells):
            vtable_words += len(self._slots[c])
        var iid_words = (len(self._iids) + 7) // 8
        var cells_words = len(self._iid_cells)
        var total_words = (
            _COM_H_WORDS
            + ncells * _COM_C_WORDS
            + vtable_words
            + iid_words
            + cells_words
            + state_words
        )
        var block = alloc[Int](total_words, alignment=8)
        for i in range(total_words):
            block.unsafe_offset(i)[] = 0

        var base = Int(block)
        var vt_word = _COM_H_WORDS + ncells * _COM_C_WORDS
        var iid_word = vt_word + vtable_words
        var cellidx_word = iid_word + iid_words

        block.unsafe_offset(_COM_H_REFS)[] = 1
        block.unsafe_offset(_COM_H_IIDS)[] = base + iid_word * 8
        block.unsafe_offset(_COM_H_IIDN)[] = len(self._iids) // 16
        block.unsafe_offset(_COM_H_IIDCELLS)[] = base + cellidx_word * 8
        block.unsafe_offset(_COM_H_STATE_OFF)[] = (
            cellidx_word + cells_words
        ) * 8

        var w = vt_word
        for c in range(ncells):
            var cell_word = _COM_H_WORDS + c * _COM_C_WORDS
            block.unsafe_offset(cell_word + _COM_C_VTBL)[] = base + w * 8
            block.unsafe_offset(cell_word + _COM_C_BACK)[] = _com_cell_offset(c)
            for i in range(len(self._slots[c])):
                block.unsafe_offset(w)[] = self._slots[c][i]
                w += 1

        var iid_bytes = Pointer[UInt8, MutAnyOrigin](
            unsafe_from_address=base + iid_word * 8
        )
        for i in range(len(self._iids)):
            iid_bytes.unsafe_offset(i)[] = self._iids[i]
        for i in range(len(self._iid_cells)):
            block.unsafe_offset(cellidx_word + i)[] = self._iid_cells[i]

        return ComPtr[Self.interfaces[0]](adopt=base + _com_cell_offset(0))

    def finish_state[
        T: Movable & Deinitable
    ](var self, var state: T) raises -> ComPtr[Self.interfaces[0]]:
        """Allocates the object with `state` moved into its state region.

        The state type `T` is the struct whose fields the callbacks mutate;
        the trampolines reconstruct a `T` from the same region. This is the
        `finish` a `class` uses -- the object owns a live `T` for its whole
        lifetime, destroyed when Release hits zero.

        Parameters:
            T: The state struct.

        Args:
            state: The initial state, moved in.

        Returns:
            An owning pointer to the new object's primary interface.

        Raises:
            If any slot is neither implemented nor declined.
        """
        comptime words = (size_of[T]() + 7) // 8
        var ptr = self^.finish(state_words=words)
        var base = com_class_base(ptr.address())
        var hdr = Pointer[Int, MutAnyOrigin](unsafe_from_address=base)
        var state_off = hdr.unsafe_offset(_COM_H_STATE_OFF)[]
        Pointer[T, MutAnyOrigin](
            unsafe_from_address=base + state_off
        ).unsafe_write(state^)
        # The object owns a live `T` from here until the last Release, which
        # reaches this thunk through the destructor word. Set it only after
        # the state is initialised: a raise between the two would otherwise
        # destroy a value that was never constructed.
        hdr.unsafe_offset(_COM_H_DTOR)[] = com_fn_bits[
            def (Int) thin abi("C") -> NoneType
        ](_com_class_dtor[T])
        return ptr^


# ===----------------------------------------------------------------------=== #
# Method trampolines: the bridge a COM vtable slot needs
#
# A vtable slot is a captureless C-ABI `fn(this, args...) -> HRESULT`. A Mojo
# method is `def M(mut self, args...) raises`. These generics are the adapter,
# one per arity: recover the object's `T` state from `this`, forward to the
# method, and translate a raise into E_FAIL and a clean return into S_OK.
# Because the method arrives as a compile-time parameter, each specialisation
# is a distinct captureless function whose address goes straight into a slot --
# no closure, no per-object cost.
#
# This is what `class` synthesis emits: one `slot[name, com_trampN[T, M]]` per
# method. The library form below is usable directly, and remains the escape
# hatch for anything the keyword does not cover.
# ===----------------------------------------------------------------------=== #

comptime _E_FAIL_RAW = Int32(-2147467259)


fn _com_self[T: AnyType](this: Int) -> Pointer[T, MutAnyOrigin]:
    # `this` may be any of the object's interface pointers; the cell it points
    # at carries the distance back to the block base, where the state offset
    # lives. So a method reached through a secondary interface finds the same
    # state as one reached through the primary.
    var base = com_class_base(this)
    return Pointer[T, MutAnyOrigin](
        unsafe_from_address=base
        + Pointer[Int, MutAnyOrigin](unsafe_from_address=base).unsafe_offset(
            _COM_H_STATE_OFF
        )[]
    )


fn com_tramp0[
    T: AnyType, //, m: def (mut T) raises thin -> None
](this: Int) -> Int32:
    """Slot adapter for a zero-argument COM method."""
    try:
        m(_com_self[T](this)[])
        return 0
    except:
        return _E_FAIL_RAW


fn com_tramp1[
    T: AnyType, A0: AnyType, //, m: def (mut T, A0) raises thin -> None
](this: Int, a0: A0) -> Int32:
    """Slot adapter for a one-argument COM method."""
    try:
        m(_com_self[T](this)[], a0)
        return 0
    except:
        return _E_FAIL_RAW


fn com_tramp2[
    T: AnyType,
    A0: AnyType,
    A1: AnyType,
    //,
    m: def (mut T, A0, A1) raises thin -> None,
](this: Int, a0: A0, a1: A1) -> Int32:
    """Slot adapter for a two-argument COM method."""
    try:
        m(_com_self[T](this)[], a0, a1)
        return 0
    except:
        return _E_FAIL_RAW


fn com_tramp3[
    T: AnyType,
    A0: AnyType,
    A1: AnyType,
    A2: AnyType,
    //,
    m: def (mut T, A0, A1, A2) raises thin -> None,
](this: Int, a0: A0, a1: A1, a2: A2) -> Int32:
    """Slot adapter for a three-argument COM method."""
    try:
        m(_com_self[T](this)[], a0, a1, a2)
        return 0
    except:
        return _E_FAIL_RAW


fn com_tramp4[
    T: AnyType,
    A0: AnyType,
    A1: AnyType,
    A2: AnyType,
    A3: AnyType,
    //,
    m: def (mut T, A0, A1, A2, A3) raises thin -> None,
](this: Int, a0: A0, a1: A1, a2: A2, a3: A3) -> Int32:
    """Slot adapter for a four-argument COM method."""
    try:
        m(_com_self[T](this)[], a0, a1, a2, a3)
        return 0
    except:
        return _E_FAIL_RAW
