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
# What the `class` keyword's synthesis will automate, available today as a
# library, following the Mac ports' sequencing: registrar machinery first,
# keyword on top of a proven runtime. spikes/com/s10 is the milestone consumer.
#
# One heap block per object:
#
#   word 0            vtable pointer (points into this same block)
#   word 1            refcount, atomic
#   word 2            accepted-IID table pointer (into this block)
#   word 3            accepted-IID count
#   word 4            destructor fn (0 for none; reserved for `class`)
#   word 5            byte offset from the object to the user state
#   words 6..6+n-1    the vtable: n = the interface's total slot count
#   then              the IID bytes, then the user state, zero-initialised
#
# AddRef, Release and QueryInterface are one generic implementation each,
# reading everything they need from the block -- an fn has no captures, so
# the object itself is the closure.
# ===----------------------------------------------------------------------=== #

comptime _COM_W_VTBL = 0
comptime _COM_W_REFS = 1
comptime _COM_W_IIDS = 2
comptime _COM_W_IIDN = 3
comptime _COM_W_DTOR = 4
comptime _COM_W_STATE_OFF = 5
comptime _COM_W_HDR = 6

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


def com_class_state(this: Int) -> Pointer[Int, MutAnyOrigin]:
    """The user-state words of a ComClassBuilder object, from a callback.

    Args:
        this: The interface pointer the callback received.

    Returns:
        A pointer to the first state word.
    """
    var obj = Pointer[Int, MutAnyOrigin](unsafe_from_address=this)
    return Pointer[Int, MutAnyOrigin](
        unsafe_from_address=this + obj.unsafe_offset(_COM_W_STATE_OFF)[]
    )


fn _com_class_add_ref(this: Int) -> UInt32:
    var refs = Pointer[Scalar[DType.uint64], MutAnyOrigin](
        unsafe_from_address=this + _COM_W_REFS * 8
    )
    var before = Atomic[Scalar[DType.uint64]].fetch_add(refs, 1)
    return UInt32(before + 1)


fn _com_class_release(this: Int) -> UInt32:
    var refs = Pointer[Scalar[DType.uint64], MutAnyOrigin](
        unsafe_from_address=this + _COM_W_REFS * 8
    )
    # No static fetch_sub; -1 on a uint64 wraps to the same decrement, and
    # the pre-value read back is what Release must return minus one.
    var before = Atomic[Scalar[DType.uint64]].fetch_add(
        refs, Scalar[DType.uint64](0) - 1
    )
    if before == 1:
        var obj = Pointer[Int, MutAnyOrigin](unsafe_from_address=this)
        var dtor_bits = obj.unsafe_offset(_COM_W_DTOR)[]
        if dtor_bits != 0:
            Pointer(to=dtor_bits).unsafe_bitcast[
                def (Int) thin abi("C") -> NoneType
            ]()[](this)
        obj.unsafe_free()
    return UInt32(before - 1)


fn _com_class_query_interface(this: Int, riid: Int, ppv: Int) -> Int32:
    var obj = Pointer[Int, MutAnyOrigin](unsafe_from_address=this)
    var iids = Pointer[UInt8, MutAnyOrigin](
        unsafe_from_address=obj.unsafe_offset(_COM_W_IIDS)[]
    )
    var count = obj.unsafe_offset(_COM_W_IIDN)[]
    var asked = Pointer[UInt8, MutAnyOrigin](unsafe_from_address=riid)
    var out = Pointer[Int, MutAnyOrigin](unsafe_from_address=ppv)
    for i in range(count):
        var hit = True
        for b in range(16):
            if iids.unsafe_offset(i * 16 + b)[] != asked.unsafe_offset(b)[]:
                hit = False
                break
        if hit:
            _ = _com_class_add_ref(this)
            out[] = this
            return 0
    out[] = 0
    return _E_NOINTERFACE_RAW


fn _com_class_notimpl(this: Int) -> Int32:
    # Serves ANY arity: extra arguments arrive in registers and shadow space
    # the callee never reads, and Win64 is caller-cleanup, so ignoring them
    # is sound. Opt-in per slot via `ComClassBuilder.notimpl`.
    return _E_NOTIMPL_RAW


struct ComClassBuilder[interface_name: StaticString]:
    """Builds a live COM object implementing one interface chain.

    The three IUnknown slots are the library's; every other slot must be
    filled with an `fn` (`slot`) or explicitly declined (`notimpl`) before
    `finish` will produce an object -- an incompletely implemented interface
    is a construction error, never a silent vtable hole. Slot indices come
    from the metadata, so declaration order in user code is meaningless and
    cannot corrupt dispatch.

    v1 scope, recorded honestly: QueryInterface answers the primary interface
    and IUnknown; intermediate bases of a deeper chain are refused. The
    `fn` signatures themselves are not yet checked against the metadata --
    that is the `class` keyword's job, and this builder is the escape hatch
    that will remain when it lands.

    Parameters:
        interface_name: The COM interface the object implements.
    """

    var _slots: List[Int]
    var _iids: List[UInt8]

    def __init__(out self):
        """Prepares the builder with IUnknown's slots prefilled."""
        comptime total = winkb_com_method_count[Self.interface_name]()
        self._slots = List[Int]()
        for _ in range(total):
            self._slots.append(0)
        self._slots[0] = com_fn_bits[
            def (Int, Int, Int) thin abi("C") -> Int32
        ](_com_class_query_interface)
        self._slots[1] = com_fn_bits[def (Int) thin abi("C") -> UInt32](
            _com_class_add_ref
        )
        self._slots[2] = com_fn_bits[def (Int) thin abi("C") -> UInt32](
            _com_class_release
        )
        self._iids = _guid_bytes(winkb_interface_iid[Self.interface_name]())
        for b in _guid_bytes(winkb_interface_iid["IUnknown"]()):
            self._iids.append(b)

    def slot[
        method: StaticString, Sig: TrivialRegisterPassable
    ](mut self, f: Sig):
        """Fills one method slot, at the index the metadata records.

        Parameters:
            method: The method's name on the interface (or its chain).
            Sig: The fn's type. Its first parameter receives `this` as an
                Int; reach the object's state with `com_class_state`.

        Args:
            f: The implementation.
        """
        comptime index = winkb_vtable_index[Self.interface_name, method]()
        comptime assert index >= 3, (
            "the IUnknown slots are the library's; do not replace them"
        )
        self._slots[index] = com_fn_bits[Sig](f)

    def notimpl[method: StaticString](mut self):
        """Declines one method, visibly: its slot answers E_NOTIMPL.

        Parameters:
            method: The method being declined.
        """
        comptime index = winkb_vtable_index[Self.interface_name, method]()
        comptime assert index >= 3, (
            "the IUnknown slots are the library's; do not replace them"
        )
        self._slots[index] = com_fn_bits[def (Int) thin abi("C") -> Int32](
            _com_class_notimpl
        )

    def finish(
        var self, *, state_words: Int = 0
    ) raises -> ComPtr[Self.interface_name]:
        """Allocates and wires the object; the creation reference is adopted.

        Args:
            state_words: Zero-initialised Int-sized words of user state,
                reachable from callbacks via `com_class_state`.

        Returns:
            An owning pointer to the new object.

        Raises:
            If any slot is neither filled nor declined.
        """
        var missing = 0
        for i in range(len(self._slots)):
            if self._slots[i] == 0:
                missing += 1
        if missing != 0:
            raise Error(
                "ComClassBuilder["
                + String(Self.interface_name)
                + "]: "
                + String(missing)
                + " slot(s) neither implemented nor declined; fill each with"
                " slot[...] or decline it with notimpl[...] -- a silent"
                " vtable hole dispatches somewhere wrong, successfully"
            )

        var nslots = len(self._slots)
        var iid_words = (len(self._iids) + 7) // 8
        var total_words = _COM_W_HDR + nslots + iid_words + state_words
        # alloc[type](count): the count overload, not the Layout one.
        var block = alloc[Int](total_words, alignment=8)
        for i in range(total_words):
            block.unsafe_offset(i)[] = 0

        var base = Int(block)
        block.unsafe_offset(_COM_W_VTBL)[] = base + _COM_W_HDR * 8
        block.unsafe_offset(_COM_W_REFS)[] = 1
        block.unsafe_offset(_COM_W_IIDS)[] = base + (_COM_W_HDR + nslots) * 8
        block.unsafe_offset(_COM_W_IIDN)[] = len(self._iids) // 16
        block.unsafe_offset(_COM_W_STATE_OFF)[] = (
            _COM_W_HDR + nslots + iid_words
        ) * 8
        for i in range(nslots):
            block.unsafe_offset(_COM_W_HDR + i)[] = self._slots[i]
        var iid_bytes = Pointer[UInt8, MutAnyOrigin](
            unsafe_from_address=base + (_COM_W_HDR + nslots) * 8
        )
        for i in range(len(self._iids)):
            iid_bytes.unsafe_offset(i)[] = self._iids[i]

        return ComPtr[Self.interface_name](adopt=base)

    def finish_state[
        T: Movable & Deinitable
    ](var self, var state: T) raises -> ComPtr[Self.interface_name]:
        """Allocates the object with `state` moved into its state region.

        The state type `T` is the struct whose fields the callbacks mutate
        through `com_class_state`; the trampolines reconstruct a `T` from the
        same region. This is the `finish` a `class` uses -- the object owns a
        live `T` for its whole lifetime, destroyed when Release hits zero.

        Parameters:
            T: The state struct.

        Args:
            state: The initial state, moved in.

        Returns:
            An owning pointer to the new object.

        Raises:
            If any slot is neither implemented nor declined.
        """
        comptime words = (size_of[T]() + 7) // 8
        var ptr = self^.finish(state_words=words)
        var base = ptr.address()
        var state_off = Pointer[Int, MutAnyOrigin](
            unsafe_from_address=base
        ).unsafe_offset(_COM_W_STATE_OFF)[]
        Pointer[T, MutAnyOrigin](
            unsafe_from_address=base + state_off
        ).unsafe_write(state^)
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
    var obj = Pointer[Int, MutAnyOrigin](unsafe_from_address=this)
    return Pointer[T, MutAnyOrigin](
        unsafe_from_address=this + obj.unsafe_offset(_COM_W_STATE_OFF)[]
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
