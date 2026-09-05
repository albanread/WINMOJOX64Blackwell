# The COM extension

COM is this platform's object system, and the extension makes it Mojo's:
ownership that the compiler proves, dispatch through metadata-derived vtable
slots, and a `class` keyword that implements an interface as directly as it
is spelled. The layers, bottom to top:

| layer | module | what it is |
|:---|:---|:---|
| ownership | `std.sys._com` | `ComPtr` — the owning interface pointer |
| raw dispatch | `std.sys._com` | `com_method` / `com_method_of` — slot-resolved calls |
| typed surface | `std.sys.com` | `Com[...]` receivers, `HResult`, `Apartment`, `co_create` |
| objects | `std.sys.com` + the parser | `ComClassBuilder`, and the `class` keyword over it |

`ComPtr` and `com_method_of` are the permanent floor: everything above is
built from them in Mojo, and they remain usable when a vtable the metadata
does not know has to be built by hand.

## `ComPtr[interface_name]` — ownership

```mojo
var stream = ComPtr[StaticString("IStream")](adopt=addr)   # out-param: already counted
var clone  = stream                                        # copy: AddRefs
var moved  = stream^                                       # move: neither
```

The refcounting is the type's semantics, and the compiler proves the
mapping rather than a reviewer auditing it:

| operation | refcount traffic |
|:---|:---|
| `adopt=` | none — a COM out-parameter arrives pre-counted; adding would leak |
| copy | `AddRef` |
| move (`value^`) | none — `deinit move` consumes the source without its destructor |
| `__deinit__` | `Release` |
| `query_interface[Target]()` | the new pointer arrives pre-counted and is adopted |

`query_interface` infers the IID from the type parameter — a GUID never
appears in user code, and asking for an interface the target does not
implement raises `E_NOINTERFACE` rather than returning a junk pointer.
`address()` hands the raw address to APIs that want one;
`if ptr:` is the null test (`Boolable`).

**The trap that is a feature:** Mojo destroys a value at its last use, so a
`ComPtr` Releases the moment its binding goes cold — potentially lines
before the block ends. Where order matters (a Release after
`CoUninitialize` is a crash in ole32), name a keep-alive or control the
scope deliberately. [comptr](../examples/comptr.md) asserts every row of the
table above against a live object.

## Dispatch — `com_method` and `com_method_of`

```mojo
comptime SIG = def (OpaquePointer[MutUntrackedOrigin], Int,
                    Pointer[Int, MutAnyOrigin]) thin abi("C") -> Int32

var qi = com_method_of[SIG, "IUnknown", "QueryInterface"](
    OpaquePointer[MutUntrackedOrigin](unsafe_from_address=p)
)
var hr = qi(iid_addr, out_addr)
```

The vtable slot is `winkb_vtable_index` — resolved at compile time, so the
call is the same four instructions C++ pays, and a method the interface
does not have is a compile error rather than a jump into slot N of
something else. On the *typed* layer, `Com[...]` wraps the same machinery
into method-bearing receivers:

```mojo
let s = Com[StaticString("IStream")](of=stream)
let hr = s.Read(buf, len, Pointer(to=read))
```

Spell every argument of the signature. An under-declared one compiles and
corrupts the call silently — the standing FFI warning, with teeth.

## `HResult`, `Apartment`, `co_create`

```mojo
let hr = HResult(raw)
if hr.failed():
    hr.raise_for["CoCreateInstance"]()     # raises, naming the context

with Apartment(multithreaded=True):        # or False for the STA a window thread needs
    var storage = co_create["CLSID_MMDeviceEnumerator", "IMMDeviceEnumerator"](clsctx=1)
```

`HResult` carries the raw value with `succeeded`/`failed`/`raise_for`;
`S_OK`, `E_NOINTERFACE` and friends are `comptime` constants of it.
`Apartment` is a context manager: `__enter__` calls `CoInitializeEx` (the
MTA by default, OLE layers with `ole=True`), `__exit__` unwinds — and
cannot raise, which is why release order belongs to the caller (see the
rule below). `co_create` resolves the CLSID and interface by *name* through
the metadata and returns an adopted `ComPtr`.

The rule the examples run on: **every Release lands inside the Apartment
that owns the object.** A `RenderStream` dropped after `Apartment.__exit__`
is a crash in ole32 with a stack that names nothing in your file
([abcplayer](../examples/abcplayer.md) documents the exact ordering).

## GUIDs

`_guid_bytes(text)` converts a textual GUID to COM's mixed-endian 16 bytes,
raising on anything that is not 32 hex digits — a malformed IID from the
metadata is named, not folded into plausible-looking wrong bytes (which
would surface much later as an unexplained `E_NOINTERFACE`). IIDs in user
code come from `winkb_interface_iid`; D3D's `_uuidof`-style constants are
`_guid_bytes(winkb_interface_iid["ID3D11Texture2D"]())`.

## `class` — implementing an interface

```mojo
class Target(IDropTarget):
    var drops: Int
    var enters: Int

    def DragEnter(mut self, d: Int, k: UInt32, p: Int, e: Int) raises:
        self.enters += 1

    def DragOver(mut self, k: UInt32, p: Int, e: Int) raises:
        pass

    def DragLeave(mut self) raises:
        pass

    def Drop(mut self, d: Int, k: UInt32, p: Int, e: Int) raises:
        self.drops += 1

def main() raises:
    var target = Target(0, 0).into_com()   # fields init positionally; a ComPtr, refcount 1
```

State is declared with `var` and initialises positionally — the desugar
gives the struct `@fieldwise_init`, so there is no `__init__` to write and
none to accidentally wire as a slot. A method a slot expects but the body
omits is not a hole: `into_com` refuses to build, naming each one —
`IDropTarget.DragLeave` — because *a silent vtable hole dispatches
somewhere wrong, successfully*. Slots can also be declined explicitly with
`notimpl`.

Name the interface or interfaces, declare state with `var`, write the
methods. `into_com()` builds the object: one allocation, a vtable cell per
interface, each slot wired to the method the *metadata* says it holds —
methods matched by name and checked against the interface's declared
arity and argument widths, so a wrong signature refuses to compile rather
than corrupting a call. Helpers in the body that no interface declares stay
ordinary methods; a slot nothing fills is named by `into_com`'s diagnostic
(`IFace.Method`) instead of becoming a jump into nothing.

The rules the compiler enforces:

- a `class` is declared at module scope;
- the body starts on the line below the header (a same-line body is
  diagnosed, once, at the header);
- the class needs a body — a bodiless class is refused rather than allowed
  to swallow the file;
- only base-indent `def`s are wired as slots (Mojo has no local defs; a
  nested `def` belongs to something the sub-parse will refuse anyway);
- every `def` raises nothing the trampoline cannot answer — a method that
  raises maps to `E_FAIL` at the boundary;
- `class Name(IA, IB)` builds one object with a vtable cell per interface;
  `query_interface` across the cells honours COM identity — the same
  object, and the primary cell answers for `IUnknown`.

The keyword is a *source-level desugar*: the parser captures the body and
generates the `@fieldwise_init` struct plus the `into_com()` factory the
library form spells by hand, then sub-parses that into the module — every
later stage sees an ordinary struct, and diagnostics inside the body land
on the user's own line numbers. `MOJO_DEBUG_COM_CLASS=1` prints the
generated source; it is meant to be inspectable, not magic.

Destruction: the object's state is destroyed at refcount zero through a
destructor thunk — a class holding a `String` or a `ComPtr` frees what it
owns, exactly when COM says the last reference went away. A sink handed to
the OS (`RegisterDragDrop` and friends) is kept alive by *Windows's*
reference; the Mojo-side one going cold releases only the caller's.

## What the metadata does not know

CLSID *values* are absent from the database (names only), so the two
constructor GUIDs a program needs are pinned by hand with comments —
`CLSID_MMDeviceEnumerator` in the audio stacks, `CLSID_FileOpenDialog` in
abcplayer. Everything else about COM — IIDs, slots, arities, chains — is
the metadata's, not the source's.

## The proof suite

[spikes/com/](../../spikes/com/) is the executable specification:
`run-com-checks.ps1` runs 36 checks — 21 must-pass spikes (metadata,
HRESULTs, GUID conversion, ownership, typed calls, apartments, `fn`
callbacks, a hand-built vtable, a cl.exe-built oracle object, and the
`class` forms), 13 must-fail spikes that each refuse to compile for the
reason named in their header (unknown method, wrong arity, wrong width,
ambiguous slots, nested class, same-line body...), a CRLF source check, and
a diagnostics-location check. A must-fail that compiles is reported as a
broken check, not a lucky day.
