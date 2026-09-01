# 5. COM

Windows stopped adding plain C entry points for new subsystems a long time
ago. Direct2D, DirectWrite, WIC, the modern file dialogs, drag and drop, text
services, the audio stack — all of them are COM, and a program that wants any
of them has to speak it. This chapter is how, on this fork: what a COM object
is at the ABI level, how a call is spelled, who owns the reference, and the
two spelling mistakes that produce a program which builds, runs, reports
success, and does the wrong thing.

Everything here is in `std.sys._com` (the raw layer) and `std.sys.com` (the
typed layer above it). Both are ordinary Mojo you can read:
[`mojo/stdlib/std/sys/_com.mojo`](../../mojo/stdlib/std/sys/_com.mojo).

## An interface is a pointer to a table of function pointers

Strip away the vocabulary and a COM interface pointer is one thing: a pointer
to a pointer to an array of function pointers. Four facts follow, and they are
the whole ABI.

* **`this` is an ordinary first argument.** Every method takes the interface
  pointer as parameter zero, C calling convention, nothing hidden.
* **A method is found by position, not by name.** There are no names at
  runtime. Slot 0 is `QueryInterface`, slot 1 `AddRef`, slot 2 `Release`, and
  the interface's own methods follow.
* **The return is an `HRESULT`** — a signed 32-bit code, negative for failure.
* **Lifetime is a reference count** the object keeps for itself, raised by
  `AddRef` and lowered by `Release`. At zero it destroys itself.

So a call is an indexed load followed by an indirect call. This is the whole
of `com_method`, the primitive everything else in this chapter sits on:

```mojo
def com_method[
    Sig: TrivialRegisterPassable, slot: Int
](this: OpaquePointer[MutUntrackedOrigin]) -> Sig:
    # *this is the vtable; the vtable is an array of function pointers.
    var vtable = this.unsafe_bitcast[OpaquePointer[MutUntrackedOrigin]]()[]
    var entry = vtable.unsafe_bitcast[
        OpaquePointer[MutUntrackedOrigin]
    ]().unsafe_offset(slot)[]
    return Pointer(to=entry).unsafe_bitcast[Sig]()[]
```

Four instructions, the same four a C++ compiler emits for a virtual call.
There is no COM runtime in the middle and nothing to register. What is hard
about COM is not the dispatch; it is knowing the slot, and knowing who owes a
`Release`.

## The slot comes from the database

A hand-written binding counts slots, and counting is where hand-written
bindings go wrong — because the count includes everything the interface
inherited. `IStream` extends `ISequentialStream`, which extends `IUnknown`, so
`Write` is not slot 0 of `IStream`. It is slot 4 of the object.

This fork does not count. `winkb_vtable_index` — one of the metadata queries
[Chapter 4](04-calling-win32.md) introduced — asks the database during
compilation and folds to a constant:

```mojo
from std.sys._winkb import winkb_vtable_index


def main():
    print("IUnknown.QueryInterface", winkb_vtable_index["IUnknown", "QueryInterface"]())
    print("IUnknown.AddRef       ", winkb_vtable_index["IUnknown", "AddRef"]())
    print("IUnknown.Release      ", winkb_vtable_index["IUnknown", "Release"]())
    print("ISequentialStream.Read", winkb_vtable_index["ISequentialStream", "Read"]())
    print("IStream.Write         ", winkb_vtable_index["IStream", "Write"]())
    print("IStream.Seek          ", winkb_vtable_index["IStream", "Seek"]())
    print("IFileDialog.Show      ", winkb_vtable_index["IFileDialog", "Show"]())
    print("IFileDialog.GetResult ", winkb_vtable_index["IFileDialog", "GetResult"]())
```

```
IUnknown.QueryInterface 0
IUnknown.AddRef        1
IUnknown.Release       2
ISequentialStream.Read 3
IStream.Write          4
IStream.Seek           5
IFileDialog.Show       3
IFileDialog.GetResult  20
```

Two things to read out of that. `IStream.Write` answers 4, the slot the
inherited method really occupies, so you may name either the interface that
declares a method or the one you hold — the database walks the chain and the
answer is absolute either way. And `IFileDialog.GetResult` is 20, a number
nobody would care to arrive at by hand and nobody would notice being wrong by
one.

Getting the name wrong is a build failure that names the file and line:

```
note: the Win32 metadata has no 'vtable_index' for IStream, Wrlte
```

That is the trade this whole layer makes. A misspelling that would otherwise
be a jump into a neighbouring method — with a different signature, reading
your arguments as its own — is a compile error instead.

## An apartment, first

COM's threading model is per-thread state, and it has to be set up before the
first object is created. `Apartment` is that state held for a scope:

```mojo
from std.sys.com import Apartment, co_create

comptime CLSID_FileOpenDialog = "dc1c5a9c-e88a-4dde-a5a1-60f82a20aef7"


def main() raises:
    with Apartment():
        var dialog = co_create[CLSID_FileOpenDialog, "IFileDialog"]()
        print("activated:", Bool(dialog))
        # dialog is released here, inside the apartment that made it.
```

`with Apartment():` is `CoInitializeEx` on entry and `CoUninitialize` on exit,
balanced exactly once — which is the discipline `CoInitializeEx` demands and
hand-written code forgets. The default is the single-threaded apartment, which
is what a thread that owns windows wants; `Apartment(multithreaded=True)` is
the MTA, and `Apartment(ole=True)` initialises full OLE rather than bare COM,
which is what drag-and-drop registration and the OLE clipboard require. That
last one is single-threaded by definition, so it refuses to be combined with
`multithreaded`.

Two failure modes are worth knowing before you meet them. `S_FALSE` means the
thread was already initialised — it is not an error and it still owes a
balancing uninitialise, which the scope pays. `RPC_E_CHANGED_MODE` means the
thread has already committed to the other model; `Apartment` raises and
uninitialises nothing, because in that case no reference was ever added.

Without an apartment, activation fails rather than misbehaving:

```
CoCreateInstance failed, hr = -2147221008
```

That is `0x800401F0`, `CO_E_NOTINITIALIZED`. Codes print signed because that
is their true type — see the width note below — so the hexadecimal form MSDN
lists is the negative number's two's complement.

**Interface pointers must be released before the apartment closes.** Holding a
COM object past `CoUninitialize` and releasing it afterwards is a crash inside
`ole32` with no useful stack. Keeping every pointer inside the `with` block is
what guarantees the order, and it is why `examples/win32/abcplayer` keeps its
whole audio object in one.

## Getting hold of an object

There are three ways an interface pointer arrives, and all three end in a
`ComPtr`.

**Activation by class ID.** `co_create`, in the apartment example above, is
`CoCreateInstance` with the IID taken from the metadata by name. The class ID
is written at the call site as a literal, because the database carries
interfaces but not class IDs — its GUID-kind constants are present and
valueless, a recorded gap. So one GUID appears in your program, once, next to
the name it belongs to. The IID never does.

**A factory function.** Plenty of subsystems hand you an object through an
ordinary exported function with an out-parameter. The reference it gives back
is already counted, and `adopt=` takes exactly that reference without adding
another:

```mojo
from std.ffi import c_int, OwnedDLHandle
from std.memory import Pointer
from std.sys._com import ComPtr


def main() raises:
    var ole32 = OwnedDLHandle("ole32.dll")
    var create = ole32.get_function[c_int]("CreateStreamOnHGlobal")

    var stream_address: Int = 0
    var hr = create(Int(0), c_int(1), Pointer(to=stream_address))
    if hr != 0 or stream_address == 0:
        raise Error("could not create the stream")

    # The factory counted a reference for us; adopt takes it, and does not
    # add another.
    var stream = ComPtr[StaticString("IStream")](adopt=stream_address)
    var seq = stream.query_interface[StaticString("ISequentialStream")]()
    print("stream:", Bool(stream), " as ISequentialStream:", Bool(seq))
```

**Asking an object you already have.** `query_interface[Target]` is
`QueryInterface` with the IID inferred from the interface name, so no GUID
appears in user code and an IID that disagrees with the type it is stored in
is not expressible. It raises on `E_NOINTERFACE` rather than handing back a
null. The result arrives pre-`AddRef`'d and is adopted, so the count stays
exact.

## ComPtr: ownership the compiler enforces

`ComPtr[interface_name]` maps COM's reference counting onto Mojo's value
lifecycle, one to one:

| | |
|:---|:---|
| `ComPtr(adopt=address)` | takes a reference that already exists; **no** `AddRef` |
| `p.copy()` | `AddRef` |
| `p^` (move) | neither — the source is consumed without its destructor running |
| destruction | `Release` |
| `p.query_interface[T]()` | `AddRef` on the same object, adopted exactly |

The move is the interesting row. `deinit move` consumes the source *without*
running its destructor, so passing an interface pointer around in idiomatic
Mojo elides the `AddRef`/`Release` pair a C++ smart pointer pays on every copy
— and it does so by construction rather than by the optimiser noticing.

None of that is asserted here on trust.
[`examples/win32/comptr`](../../examples/win32/comptr/main.mojo) exercises
every transition against a live COM object, using the fact that `AddRef`
returns the new count:

```mojo
    # Adopt: the factory's reference becomes ours, count stays 1.
    var a = ComPtr[StaticString("IStream")](adopt=stream_address)
    print("after adopt      count =", probe_count(a), "(expect 1)")

    # Copy: AddRef. Count 2 while both live.
    var b = a.copy()
    print("after copy       count =", probe_count(a), "(expect 2)")

    # Move: no refcount traffic. Count still 2 -- b is consumed, c holds it.
    var c = b^
    print("after move       count =", probe_count(a), "(expect 2)")
```

```
after adopt      count = 1 (expect 1)
after copy       count = 2 (expect 2)
after move       count = 2 (expect 2)
after QI         count = 3 (expect 3)
QI non-null: True
unrelated QI raises: True (expect True)
after drops      count = 1 (expect 1)
```

**What a `ComPtr` does not own is everything that is not an interface.** A
string a method allocated for you — `IShellItem::GetDisplayName` is the usual
one — belongs to the task allocator and wants `CoTaskMemFree`. A medium filled
in by `IDataObject::GetData` wants `ReleaseStgMedium`. An interface pointer
that arrives through an out-parameter, such as `IFileDialog::GetResult`, is a
reference you now owe: adopt it into a `ComPtr` and it releases itself.

## Ownership is not liveness

Here is the sharp edge, and it is sharp enough to be worth its own section.

A Mojo value dies at its last use **by name**, and taking an interface pointer
out of a `ComPtr` is a use that ends there. The pointer is a plain address; it
does not keep the `ComPtr` alive. So this shape —

```
var this = p.interface()      # p's last use by name
...
call through this             # p was destroyed before we got here
```

— releases the object and then calls through it. At `-O0`, with no optimiser
involved. The generated code says so plainly:

```
callq  ComPtr::interface
callq  ComPtr::__deinit__
callq  *%rax                  # the method, on a released object
```

Two spellings avoid it, and one of them is already all over this tree:

* **Make the calls in a function that takes the `ComPtr` as a parameter.** A
  borrowed parameter is alive for the whole of the callee, because the caller
  still owns it. That is why `comptr`'s `probe_count(p: ComPtr)` is a function
  rather than a block of inline code.
* **End the scope with `_ = p`.** An explicit final use puts the destructor
  after the last call, which is checkable in the assembly and worth checking
  the first time you rely on it.

A call whose arguments include a real `Pointer` over `MutAnyOrigin` — which is
what `com_addr` produces — also keeps every Mojo value alive across the call,
because that origin means "might access any memory value". That is why most
correctly-spelled call sites never meet this problem. It is a consequence, not
a guarantee to lean on: a method with no pointer arguments at all, `Show` or
`AddRef`, has nothing to pin its owner.

This is not hypothetical, and it is not only a beginner's mistake. Griddle's
own file dialogs have it. `open_dialog` in `ide/window.mojo` reads:

```mojo
    var dialog = co_create[CLSID_FileOpenDialog, "IFileDialog"]()
    var path = _ask(dialog.address(), hwnd, String(""))
```

and `save_dialog` is the same two lines with the save class ID. `dialog`'s
last use by name is `.address()`, and the code generated for both is
`co_create`, `ComPtr::address`, `ComPtr::__deinit__`, `_ask` — the dialog is
released before the function that drives it is entered. The same shape,
reduced to a program that asks the object for its refcount immediately
afterwards, dies with `Exception Code: 0xC0000005`. Whether the real one
crashes depends on whether anything has reused the block yet, which is the
property that makes this class of defect turn up months later and somewhere
else. `_ = dialog` after the call is the whole fix.

## Spelling a call

A call needs the method's signature as a thin C-ABI function type, the
interface and method names, and the interface pointer twice — once to find the
function, once as its first argument:

```mojo
from std.ffi import c_int, OwnedDLHandle
from std.memory import OpaquePointer, Pointer
from std.sys._com import ComPtr, com_addr, com_method_of


def main() raises:
    var ole32 = OwnedDLHandle("ole32.dll")
    var create = ole32.get_function[c_int]("CreateStreamOnHGlobal")
    var stream_address: Int = 0
    if create(Int(0), c_int(1), Pointer(to=stream_address)) != 0:
        raise Error("could not create the stream")
    var stream = ComPtr[StaticString("IStream")](adopt=stream_address)

    var payload = UInt32(0xC0FFEE42)
    var written = UInt32(0)
    var hr = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],  # this: Windows' memory
            Pointer[UInt32, MutAnyOrigin],      # the bytes: ours
            UInt32,
            Pointer[UInt32, MutAnyOrigin],      # the out-parameter: ours
        ) thin abi("C") -> Int32,
        "ISequentialStream",
        "Write",
    ](stream.interface())(
        stream.interface(), com_addr(payload), UInt32(4), com_addr(written)
    )

    if hr < 0:
        raise Error("Write failed, hr = " + String(hr))
    print("wrote", written, "bytes")
    _ = stream
```

Four details in there are load-bearing.

**`thin` is required.** Without it the function type is not
`TrivialRegisterPassable` and the parameter will not bind.

**Spell every argument.** An under-declared signature compiles and then
corrupts the call silently. There is no arity check at this layer; the typed
layer later in this chapter adds one.

**The origins are not decoration.** `this` is `MutUntrackedOrigin` because it
is memory from outside the Mojo program, aliasing nothing the compiler
manages. Everything else a COM method touches — out-parameters, descriptor
structs, buffers — **is** Mojo's memory, and must be `MutAnyOrigin`. Casting
your own local to an untracked origin tells the lifetime checker the pointer
does not alias it, and the compiler is then free to hand the callee a
temporary: the call succeeds, the write lands nowhere, and your local keeps
its old value. It was found here with a sentinel: a counter set to 999
survived a `Write` that reported success. It also sometimes appears to work,
which is worse. [Chapter 3](03-the-dialect.md) has the general rule; this is
the shape it takes at a COM call.

**The return type is `Int32`, never `Int`.** A COM method returns its HRESULT
in EAX, and the upper half of RAX is not part of the answer. Declared as
`Int`, `E_NOINTERFACE` reads back as `2147500034` and `hr < 0` is false;
declared as `Int32` it reads `-2147467262` and the test is correct. Those two
numbers are the same call, on the same object, differing only in the declared
width. `HResult` in `std.sys.com` exists to hold this at its true width so the
question cannot be got wrong twice.

## `com_addr`, and why the integer form is a defect

COM takes structures by pointer everywhere: a colour, a rectangle, a format,
an out-parameter. The obvious spelling for "the address of this local" is
`Int(Pointer(to=x))`, and it is wrong. Not unidiomatic — wrong.

**Rule: spell every by-pointer argument `com_addr(x)`, and give the parameter
a `Pointer[T, MutAnyOrigin]` in the signature.**

Here is the same `Write` as above with the two addresses laundered through
integers, which is the only change:

```mojo
    # WRONG. Compiles, passes the right numbers, and is a defect.
    var hr = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int, UInt32, Int
        ) thin abi("C") -> Int32,
        "ISequentialStream",
        "Write",
    ](this)(
        this, Int(Pointer(to=payload)), UInt32(4), Int(Pointer(to=written))
    )
```

It builds without a diagnostic. It dies at `-O0` with
`Exception Code: 0xC0000005`, and the assembly for the two versions differs
in exactly one way: with `com_addr` the order is `interface`, call,
`__deinit__`; with the integers it is `interface`, `__deinit__`, call. Erasing
the origins removed the last thing telling the compiler that this call touches
Mojo's memory at all, so the `ComPtr` was free to die first.

The other half of the damage is subtler and is the one that cost a working
day. An integer address erases the origin, so the local's last recorded use is
the address-taking; nothing then says the storage is read afterwards, and
dropping its initialising store and reusing its slot is the correct thing for
an optimiser to do with what it was told. Griddle's first optimised build
opened its window, worked its menu, registered its drop target and got `S_OK`
out of `EndDraw`. It drew almost nothing, because `FillRectangle` was handed
the *colour* struct as its rectangle — the two locals had been merged into one
stack slot — and drew a rectangle three hundredths of a pixel wide, faithfully,
in the right colour, eleven times a frame. The unoptimised build of identical
source was correct.

Two consequences for how you find the next one:

* **A debugger will not show it.** When behaviour differs between optimisation
  levels, the tool is `mojo build --emit asm` at both levels, diffed. That is
  the first move, not the fourth.
* **Do not reach for `print`.** A diagnostic placed after the call is itself a
  use, and extends the lifetime it is trying to observe. Printing every
  argument showed all of them correct while the drawing stayed wrong.

`tools/check-ide.ps1` greps `ide/` for `Int(Pointer(to=` and fails if it comes
back — a lint rather than a test, deliberately, because the consequence does
not appear in the build the checks run against. The full account, with the
assembly, is [`docs/addresses-and-optimization.md`](../../docs/addresses-and-optimization.md).

One case is genuinely different: an address that is *stored* and outlives the
expression, such as a counter handed to a COM object that bumps it from its
destructor. That is not a by-pointer call argument, and the rule does not
reach it.

## The typed layer

Everything above is `std.sys._com`, which is permanent and is what the rest of
the tree is written against. Above it, `Com[interface_name]` dispatches by
method name and checks what it can:

```mojo
from std.ffi import c_int, OwnedDLHandle
from std.memory import Pointer
from std.sys._com import ComPtr, com_addr
from std.sys.com import Com


def main() raises:
    var ole32 = OwnedDLHandle("ole32.dll")
    var create = ole32.get_function[c_int]("CreateStreamOnHGlobal")
    var stream_address: Int = 0
    if create(Int(0), c_int(1), Pointer(to=stream_address)) != 0:
        raise Error("could not create the stream")
    var stream = ComPtr[StaticString("IStream")](adopt=stream_address)

    var s = Com[StaticString("IStream")](of=stream)
    var payload = UInt32(0xC0FFEE42)
    var written = UInt32(0)
    _ = s.Write(com_addr(payload), UInt32(4), com_addr(written))
    print("wrote", written, "bytes")
    _ = stream
```

The method name arrives as a compile-time parameter, so the call can consult
the metadata about itself: the slot, the declared arity, and each argument's
width. A misspelled name, a missing out-parameter, or an `Int32` where the SDK
says `i64` are all compile errors. A failing HRESULT raises, with the method
named.

Its limits are worth stating plainly. It speaks only HRESULT-returning
methods — `AddRef` and `Release` are the ownership type's job and stay on the
raw layer. It checks argument *widths*, not register classes, so an integer
passed where a float is expected is still yours to get right. And a `Com` is a
non-owning view: it neither `AddRef`s nor `Release`s, and must not outlive the
`ComPtr` it was made from.

## A worked example

The shell's file dialog, activated and driven without ever being shown:
an apartment, an object created by class ID, an out-parameter through the raw
layer, a `QueryInterface`, a call through the typed layer, and a refcount that
is checked rather than assumed. Add `Show(hwnd)` and it is Griddle's
**File → Open** — [`ide/window.mojo`](../../ide/window.mojo)'s `open_dialog`,
which is also where the missing keep-alive above was found.

```mojo
from std.memory import OpaquePointer, Pointer
from std.sys._com import ComPtr, com_addr, com_method_of
from std.sys.com import Apartment, Com, co_create
from std.sys._winkb import winkb_constant

# The metadata carries interfaces but not class IDs, so this one GUID is
# written here, next to the name it belongs to, and nowhere else.
comptime CLSID_FileOpenDialog = "dc1c5a9c-e88a-4dde-a5a1-60f82a20aef7"


def refcount(p: ComPtr) -> Int:
    """The object's current refcount, via a balanced AddRef/Release.

    `p` is a parameter, so the caller's value is alive for the whole of this
    function -- which is the point: an interface pointer does not keep its
    owner alive by itself.
    """
    var up = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> UInt32,
        "IUnknown",
        "AddRef",
    ](p.interface())(p.interface())
    _ = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> UInt32,
        "IUnknown",
        "Release",
    ](p.interface())(p.interface())
    return Int(up) - 1


def utf16z(s: String) -> List[UInt16]:
    """A NUL-terminated UTF-16 copy, for a PCWSTR parameter."""
    var units = List[UInt16]()
    for ch in s.codepoints():
        units.append(UInt16(Int(ch)))
    units.append(0)
    return units^


def main() raises:
    with Apartment():
        var dialog = co_create[CLSID_FileOpenDialog, "IFileDialog"]()
        print("activated, refs =", refcount(dialog), "(expect 1)")

        # The raw layer: an out-parameter, by pointer, through com_addr.
        var options = UInt32(0)
        var hr = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin],
                Pointer[UInt32, MutAnyOrigin],
            ) thin abi("C") -> Int32,
            "IFileDialog",
            "GetOptions",
        ](dialog.interface())(dialog.interface(), com_addr(options))
        if hr < 0:
            raise Error("GetOptions failed, hr = " + String(hr))
        var must_exist = UInt32(winkb_constant["FOS_FILEMUSTEXIST"]())
        print("options =", options, " FOS_FILEMUSTEXIST set:",
              (options & must_exist) != 0)

        # QueryInterface, with the IID inferred from the name. The answer
        # arrives pre-AddRef'd and is adopted, so the count is exact.
        var open = dialog.query_interface[StaticString("IFileOpenDialog")]()
        print("as IFileOpenDialog:", Bool(open), " refs =", refcount(dialog),
              "(expect 2)")

        # The typed layer: the slot, the arity and the argument widths come
        # from the metadata, and a failing HRESULT raises.
        var title = utf16z(String("Open a project"))
        _ = Com[StaticString("IFileDialog")](of=dialog).SetTitle(
            title.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
        )
        _ = title
        print("title set")

        # Both pointers release here, inside the apartment that made them.
        # `_ = dialog` is what stops its destructor being hoisted above the
        # last call that uses it.
        _ = open^
        _ = dialog
    print("apartment closed")
```

```
activated, refs = 1 (expect 1)
options = 6152  FOS_FILEMUSTEXIST set: True
as IFileOpenDialog: True  refs = 2 (expect 2)
title set
apartment closed
```

`6152` is `0x1808`: the defaults the shell sets before anyone asks. Nothing in
that program names a DLL, a vtable index or an IID.

## What is not covered

**Implementing a COM interface** — an object of yours that Windows calls
back — is the other half, and it is a language feature rather than a library
one. `class DropTarget(IDropTarget)` in
[`ide/drop.mojo`](../../ide/drop.mojo) is the real example: Griddle's drag and
drop, with the vtable in metadata slot order, an atomic refcount, an
IID-checking `QueryInterface` and the raising-method trampolines all
synthesised. `ComClassBuilder` in `std.sys.com` is the same machinery as a
library. Read those two, then `spikes/com/s10_droptarget.mojo`, which builds
the same object by hand out of raw function pointers and vtable words — that
is what the compiler now emits from a `class` declaration, and
`s12_class_keyword.mojo` is the same object written with the keyword.

**Marshalling between apartments** — proxies, stubs, `CoMarshalInterface`,
the free-threaded marshaler — is untried here. Every object in this tree is
used on the thread that created it.

**Automation** — `IDispatch`, `VARIANT`, `BSTR`, type libraries, late binding
— is untouched, though the interfaces themselves are in the metadata:
`IDispatch.Invoke` is slot 6 with eight parameters and the raw layer will call
it. What is missing is the value model, and the database is actively unhelpful
there. `winkb_struct_size["VARIANT"]` answers **8**, where the real x64
`VARIANT` is 24 bytes, and the type carries no fields at all —
`no 'field_offset' for VARIANT, vt`. A `comptime assert` against the metadata
would therefore bless a struct a third of the right size, which is the one
failure mode this whole layer exists to prevent. Anything doing automation
here has to model `VARIANT` by hand and know why.

**Connection points and event sinks.** `IConnectionPoint::Advise` is slot 5 in
the database, and the sink you hand it is a COM object of your own, so both
halves exist. Nothing in this tree has wired them together.

**A complete worked client.** `std.windows.audio` is this whole
chapter running in production: activation by class ID, `com_method_of` slot
calls, ownership in `ComPtr`, release order against the apartment, and an
event-driven render loop on top. When a COM question here feels abstract,
that file -- and `spikes/win32/audio_smoke.mojo`, which proves it against the
endpoint's own peak meter -- is the concrete answer.

**Class IDs are not in the metadata.** The database's GUID-kind constants are
present and valueless, which is a recorded gap rather than a decision, so
every `co_create` call site carries its own CLSID literal. Interface IIDs are
in the database and never need writing down.
