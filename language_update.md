# language_update — `class`, `let`, and `fn` for COM

*2026-08-26, revised 2026-08-29. Written against a survey of MojoCocoa at
`ce53b96`, MojoMacX64's `COCOA_DESIGN.md` (D1-D6), and a deep survey of
NewModula2's shipped COM implementation. Status: **C0-C2 are built and
verified** -- `let`, `fn`, the metadata queries, `Com[...]` typed receivers,
`HResult`, `Apartment`, `co_create`, and a 14-check spike suite under
`spikes/com/` whose must-fail half refuses to compile and whose s09 is a
cl.exe-built oracle object driven from Mojo. **C3's runtime landed too**: `ComClassBuilder` implements live COM objects (`s10` registers a real IDropTarget with OLE), so the `class` keyword now has a proven runtime to synthesise onto -- that synthesis is the remaining work.
The sibling documents to read beside this one are MojoCocoa's
`COCOA_CLASS_DESIGN.md` and `COCOA_LET_DESIGN.md`.*

The Mac ports gave Mojo an object story by teaching three keywords to speak
the platform's object system: `class` declares a Cocoa class, `let` binds
immutably, `fn` marks a function the foreign side may call. This document
specifies the same three keywords for Windows, where the platform's object
system is COM.

The governing thesis is inherited unchanged from MojoCocoa's README: **the
compiler is the binding generator.** No wrapper files are generated, no
bindings are checked in. `Com["IFileOpenDialog"]` is a string parameter, and
the reachable API surface is whatever the metadata database knows. Our
database already exists — `windows_api.db`, 86 MB, built by the WRASM sibling
repository, consumed through `winkb_query` — so unlike the Mac ports we start
with the metadata pipeline already wired into the compiler.

MojoCocoa's own policy statement (STATUS.md:158) names this division of
labour: *"The object-oriented story is the platform's — Cocoa here, COM on
Windows."* This is the COM half.

---

## 1. Where each keyword stands today

Checked against this tree, not assumed. The three keywords are in three
different states, and all three states are convenient:

| keyword | state | notes |
|---|---|---|
| `class` | **Reserved, and it now guides** (`ParserStmts.cpp:4077`) | its *runtime and library form are built and tested*. `class Name(IFace):` parses its header and emits a located diagnostic showing the exact working form for that interface -- struct of state + `ComClassBuilder`/`com_trampN` factory. The keyword that compiles a declaration *down to* that form is the one piece left, and is pure sugar over a working system (see the cost note below). |
| `let` | **BUILT.** `kLetPat` onto `PatternDeclKind::kBind`, ported from the Mac ports across nine files | exercised by every spike; `f0*` prove nothing about it because rebinding is caught in `ExprNodes.cpp`'s existing kBind machinery |
| `fn` | **BUILT.** The removal error at `DeclResolution.cpp:1958` became the foreign-callable capture; `setCABI(true)` engages the existing `abi("C")` machinery | `s07` hands one to EnumWindows; `s08` builds a vtable of them; `f05` proves `fn ... raises` refuses to compile |

The layers as they now stand:

| piece | where | state |
|---|---|---|
| metadata database | `windows_api.db` via `@winkb`, from WRASM releases -- the same artefact NewModula2's pipeline builds | 86 MB, hash-pinned; method tables present, CLSID values absent |
| compiler hook | `winkb_query` in `KGENAttrs.cpp` + `IREvaluatorContext.cpp` | 13 named queries; every COM method query chain-walks in SQL |
| query surface | `std/sys/_winkb.mojo` | wrappers for all 13 |
| ownership type | `ComPtr` in `std/sys/_com.mojo` | adopt / copy=AddRef / move / deinit=Release / `query_interface[T]` |
| raw dispatch | `com_method_of` | permanent bottom layer, per the M2 rule |
| typed surface | **`std/sys/com.mojo`** | `Com[...]` receivers, `HResult`, `Apartment`, `co_create` |
| proof | **`spikes/com/`** | 9 must-pass, 5 must-fail, one cl.exe oracle, `run-com-checks.ps1` |

### Lessons the implementation itself paid for

Recorded here because each cost a debugging cycle and will be reached for
again:

- **`comptime if` does not prune what follows it.** A taken `comptime if ...
  return` still elaborates the statements after the block, so a metadata
  query used as a fallback must sit in the final `else` of one chain or it
  elaborates -- and errors -- even when a primitive already answered
  (`_expected_width` in com.mojo carries the comment).
- **ASAP destruction and COM refcounts compose exactly, and that is a trap.**
  Mojo destroys a value after its last use, not at scope end, so a `ComPtr`'s
  Release fires the moment the binding goes cold -- before the refcount
  assertion three lines later. `s04` pins this with keep-alives and a
  comment. `class` synthesis must document the same for sinks handed to
  Windows: the OS's reference is the one that keeps the object alive, and
  `RegisterDragDrop`'s AddRef is doing real work.
- **`OwnedDLHandle.get_function[T]` takes a return type, not a signature.**
  Feeding it a full fn type compiles and then miscalls. The typed-signature
  accessor is `Win32Module(...).function[Sig]` from `std.sys._win32`, which
  is what `std/windows/process.mojo` uses; com.mojo now does the same, and
  `Apartment.__exit__` resolves by `address_of` because `__exit__` cannot
  raise.
- **The GUID pin caught its own author.** The s03 regression was first
  written with five zero bytes where `c000-000000000046` has six; it failed
  its own check on the first run. That is the check working, and it stays in
  the spike's comment.

---

## 2. `class` — declaring a COM object

### The syntax

```mojo
class DropTarget(IDropTarget):
    var hwnd: Int
    var files: List[String]

    def DragEnter(self, data: Com["IDataObject"], key_state: UInt32,
                  pt: POINTL, effect: Pointer[UInt32, MutAnyOrigin]) raises:
        effect[] = DROPEFFECT_COPY

    def DragOver(self, key_state: UInt32, pt: POINTL,
                 effect: Pointer[UInt32, MutAnyOrigin]) raises:
        effect[] = DROPEFFECT_COPY

    def DragLeave(self) raises:
        pass

    def Drop(self, data: Com["IDataObject"], key_state: UInt32,
             pt: POINTL, effect: Pointer[UInt32, MutAnyOrigin]) raises:
        self.open_dropped(data)
```

```mojo
let target = DropTarget(hwnd=main_hwnd, files=List[String]())
RegisterDragDrop(main_hwnd, target.as_com["IDropTarget"]())
```

The base list names the **COM interfaces the class implements** — one or
several. As in MojoCocoa, bases are recorded as strings on the declaration and
resolved against the metadata, not against Mojo symbols; there is no Mojo type
named `IDropTarget` anywhere.

### What it lowers to

Follow MojoCocoa's structural decision exactly (`COCOA_CLASS_DESIGN.md:32-56`):
`class` lowers onto the **existing `StructDeclOp`** with new attributes, not a
new op. Their reasoning was about Mojo, not Objective-C — `StructDeclOp` has
241 references across the type system, LLDB, completion and signature
printing, and every one of those keeps working for free. Our attributes:

```tablegen
UnitAttr:$comClass,
OptionalAttr<StrArrayAttr>:$comInterfaces,   // ["IDropTarget"]
OptionalAttr<StrAttr>:$comClsid,             // optional, for registered classes
```

### What synthesis emits — and what it no longer has to

This is where COM is **strictly cheaper** than Cocoa. Their hardest sprint —
the only one sized "L", with the note *"no partial credit — a half-registered
class proves nothing"* — was runtime class registration: a 760-line
`ObjCClassRegistrar` plus ~515 lines of compiler synthesis, because
Objective-C classes are built by calling the runtime at startup and ivar
offsets are only settled then. **COM has no runtime registration. The vtable
is a constant.** Synthesis therefore emits, at compile time:

1. **One static vtable per implemented interface**, a constant array of
   function pointers, slots ordered **by the metadata** (see §7 — never by
   source order).
2. **The object layout**: `{ vtbl_ptr_0, …, vtbl_ptr_N-1, refcount: Atomic
   [UInt32], mojo fields… }`. No box, no offset globals — the layout is ours,
   known at compile time. The entire `box_offset` apparatus
   (`DeclResolution.cpp:2005` there) has no counterpart here.
3. **`AddRef` / `Release`**, atomic, `Release` destroying the Mojo fields and
   freeing the allocation at zero. A `class` instance is heap-allocated and
   refcount-owned from birth — a COM object handed to the OS must outlive the
   scope that made it, so there is no stack form.
4. **`QueryInterface`**, comparing against the IID of each implemented
   interface (from `winkb_interface_iid`, baked at compile time) plus
   `IUnknown`, answering with the correctly adjusted pointer.
5. **This-adjustment trampolines.** The COM caller passes the *interface*
   pointer as argument 0; with several interfaces those differ from the object
   address by the vtable-slot offset. The trampoline subtracts the offset,
   then calls the Mojo method. This is the exact structural twin of their
   `synthesizeObjCTrampoline` dropping `_cmd` — a small C-ABI adapter between
   what the platform sends and what the method wants.
6. **The HRESULT bridge** (§5): a method written `raises` gets a trampoline
   that catches and converts; nothing unwinds across the boundary, for the
   same reason theirs never unwinds into `objc_msgSend`.

### Method matching — simpler than selectors, one new hazard

Cocoa needed a name-mangling convention (`set_frame_size` → `setFrameSize:`,
underscore-to-colon, colon count checked against arity) because selectors are
not identifiers. **COM method names are ordinary identifiers, so there is no
mangling at all**: the method is written with the metadata's own name,
`DragEnter`, and matched exactly. `@com("Name")` exists as the override
attribute for collisions with Mojo keywords, mirroring `@objc("...")`, and a
leading underscore keeps a method private and out of every vtable — the same
rule doing the same work.

The verification discipline transfers verbatim: every declared method is
checked against the metadata's signature for that slot, and a class that
implements an interface **must implement every slot** or name a default
(E_NOTIMPL synthesis is opt-in per method via `@com_notimpl`, never silent).
An unmodelable signature **fails the build** — MojoCocoa's "never guess" rule,
which their must-fail spikes exist to enforce.

The new hazard is **slot order** (§9, risk 1): Cocoa dispatches by name, so a
misplaced method still lands; COM dispatches by index, so a vtable ordered by
anything other than the metadata calls the wrong method *silently and
successfully*. Slot order comes from `winkb_vtable_index` per method, never
from source order, and the must-fail suite includes a shuffled-source case
proving order-independence.

---

## 3. `let` — the binding, ported honestly

`let` is the same keyword with the same meaning: an immutable binding, lowered
onto the existing `kBind` pattern kind, exactly as `COCOA_LET_DESIGN.md:91-104`
chose *because the machinery decided* — a handful of parser changes and no new
elaborator work. Port it as-is: lexer keyword, `kLetPat`, the `kBind` mapping.

Two honesty clauses, both inherited from their own corrections:

- **`let` carries no ownership semantics.** Their README says ARC "rides
  underneath" `let`; their design doc flatly corrects it — *"it lives in
  `ObjCRef`, not the keyword"*. Same here: refcounting lives in `ComPtr` and
  in `class` synthesis. `let d = dialog` binds a name; it is `ComPtr.copy()`
  that calls `AddRef`, visibly.
- **`let x = i` binds, it does not snapshot** — the trap that cost them a
  lexer bug (`COCOA_LET_DESIGN.md:476-495`). Carried into our docs from day
  one.

Why bother, then? Because the consumption surface reads as it should:

```mojo
with apartment(STA):
    let dialog = CoClass["FileOpenDialog"].create["IFileOpenDialog"]()
    dialog.SetTitle(w"Open Project")
    dialog.Show(owner_hwnd)
    let item = dialog.GetResult()
    let path = item.GetDisplayName(SIGDN_FILESYSPATH)
```

Every binding above is single-assignment and reads as declaration, which is
the entire argument their doc makes for the keyword.

---

## 4. `fn` — the keyword for anything Windows calls

Revival, not invention: delete the "'fn' has been removed" error at
`DeclResolution.cpp:1958` and attach MojoCocoa's contract — **C ABI,
non-raising, no captures, foreign-callable** — which in this tree already
exists as `abi("C")`; `fn` engages it by default, exactly as theirs does
(`DeclResolution.cpp:3356-3364` there).

`fn` earns its keep on Windows three times over:

1. **Win32 callbacks.** The IDE's first file needs one:

   ```mojo
   fn wnd_proc(hwnd: Int, msg: UInt32, wparam: UInt64, lparam: Int64) -> Int64:
       ...
   ```

   WndProc, EnumWindowsProc, timer procs, thread procs, hook procs — the
   x64 calling convention is single, so `fn` is sufficient without a
   `stdcall` annotation.

2. **Vtable entries are `fn`-shaped.** Everything `class` synthesis emits into
   a vtable is a foreign-callable function; `fn` is the user-visible name for
   the same contract the trampolines obey.

3. **The escape hatch.** A hand-built vtable of `fn` pointers, no metadata
   involved, is the COM analogue of their `add_method_unchecked` — the
   documented back door for the interface the database does not know, kept
   deliberately ugly so the checked path stays the path of least resistance.

---

## 5. HRESULT: the error convention is the default, not a special case

In Cocoa, error bridging (`msg_send_raising`) is opt-in per call, because only
some methods take an `NSError**`. **In COM every method returns an HRESULT**,
so the bridge is the default in both directions:

- **Consuming** (typed calls, §6): a failing HRESULT raises; the out-param
  becomes the return value. `dialog.Show(hwnd)` raises on failure rather than
  handing back a code to ignore. The discipline is inherited from their
  `error.mojo`: *the return value decides; the out-param is only then
  meaningful.* A `raw` variant returning the HRESULT exists for the cases
  (`S_FALSE`, `E_PENDING`) where the code is data.
- **Implementing** (`class` methods): a method written `raises` has its error
  caught in the trampoline and converted (an `HResultError` carries its code
  through; anything else becomes `E_FAIL`); a method written `-> HRESULT`
  passes through untouched. Nothing ever unwinds across the boundary.

---

## 6. Typed receivers: `Com[...]`, and the metadata it needs

The call syntax above (`dialog.SetTitle(...)`) is MojoCocoa's `typed.mojo`
trick transplanted: `Com[interface]` implements `__getattr_param__[name]` so
the *attribute name arrives as a compile-time parameter*, a `Bound[iface,
name]` carrier ferries it to the call site (arity is only known there), and
`__call__` overloads per arity do the dispatch. Dispatch itself is **simpler
than theirs**: no msgSend variant selection, no selector slot globals — their
single largest performance mechanism deletes entirely. Load the vtable, index
by `winkb_vtable_index` (a compile-time constant), cast the slot to the
per-signature function type, call. The per-signature cast and the comptime
argument checking (`runtime.mojo:262-314` there) transfer verbatim.

**The metadata gap closed on inspection.** The database already held the
method tables -- `interface_methods` (46,250 rows with absolute
`vtable_index` and return types) and `interface_method_params` (79,208 typed
rows) -- because `windows_api.db` is the same artefact NewModula2's
winapi-gen pipeline builds; only the *queries* were missing. Six were added
(`com_method_ret_type`, `com_method_param_count`, `com_method_param_type`,
`com_method_count`, `com_interface_base`, `type_width`), all walking the
inheritance chain in SQL with a recursive CTE seeded on `iid IS NOT NULL`
(the definitive interface signal; the winmd importer's kind classifier
mislabels). Fixing the pre-existing `vtable_index` query to chain-walk came
with it -- it could not previously answer (IStream, Read).

**The one genuine WRASM gap left: CLSID values.** All 5,837 guid-kind
constants are present but valueless, and coclasses land as `kind='struct'`
with no IID. Until the generator grows them, activation writes its one GUID
at the call site (`co_create`'s documented convention), validated at run
time. Everything else in §2-§6 is now verified by `spikes/com/`.

Three database-side decisions inherited unchanged: named queries only (a
caller asks `vtable_index`, never a SELECT); `db_hash` pins the metadata
revision into every artefact; `availability()` distinguishes "no database
configured" from "no such interface" — *a configuration error must not wear a
source error's clothes.*

And one compiler-side decision inherited unchanged, learned there at
retrofit cost (`KGENAttrs.cpp:3767-3790`): **fold at attribute level, diagnose
at elaboration.** `winkb_query` currently resolves in both places already —
keep it that way for every new query, so a *type* may be conditioned on the
metadata while errors still arrive with source locations.

---

## 7. What the Cocoa analogy deletes, and what it adds

Machinery we do **not** port, because COM lacks the problem:

| theirs | why it vanishes |
|---|---|
| selector interning + per-selector global slots | a vtable index is a compile-time integer |
| `objc_msgSend` variants (`_stret`, `_fpret`) | one calling convention, one indirect call |
| `ObjCClassRegistrar` + runtime registration (~1,275 lines total) | the vtable is a constant |
| ivar boxes and offset globals | object layout is ours at compile time |
| `@encode` strings and their parser | metadata is structured (WinMD), not stringly |
| underscore→colon selector derivation | COM names are identifiers; no mangling |
| flat global class namespace + collision escape | GUIDs are collision-free by construction |
| autorelease pools, zeroing weak refs, blocks | no analogue; callbacks are interfaces, which is what `class` builds |
| the two-oracle (runtime dump vs headers) split | typelibs/WinMD are one authoritative source |

Machinery we add, with no Cocoa precedent:

| ours | note |
|---|---|
| `QueryInterface` synthesis + IID matching | a runtime type conversion Cocoa doesn't have; consumption side already exists as `ComPtr.query_interface[T]` |
| this-adjustment thunks | multiple interfaces per object |
| static vtable emission in metadata slot order | see risk 1 |
| apartments: `with apartment(STA):` | scoped-RAII shape borrowed from `autoreleasepool`; the IDE's UI thread is STA, workers MTA |
| `BSTR` / `VARIANT` ownership types | needed by milestone C5 (automation), not before |
| class factories / registration / ROT | only when a class must be visible outside the process — C5 |

---

## 8. Milestones, each verifiable

Their verification discipline arrives whole: a check-script where the
**must-fail half is the interesting half**, and a foreign-compiler ABI oracle
— theirs is clang, **ours is `cl.exe`**: an MSVC-built DLL that implements and
consumes our interfaces, linked against the Mojo binary, and the two must
agree on every byte.

| # | lands | verified by | state |
|---|---|---|---|
| C0 | COM method queries over the existing tables; chain-walk everywhere | `spikes/com/s01_metadata.mojo` pins slots, arities, types, widths, the base chain, and the db hash | **DONE** |
| C1 | `Com[...]` typed receivers; `HResult` raises; width checks | `s05` round-trips bytes through a live IStream; `s06` drives the shell's FileOpenDialog headless; `f01-f04` refuse unknown method / wrong arity / wrong width / unknown interface | **DONE** |
| C2 | `let` and `fn` (port + revival) | `s07` hands an `fn` to EnumWindows; `f05` proves `fn raises` refuses; `let` used throughout | **DONE** |
| C2.5 | the foreign-compiler oracle | `s09`: an MSVC-built ISequentialStream consumed through the typed surface -- Write's byte-sum read back exact, QI honoured and refused correctly | **DONE** |
| C3-runtime | `ComClassBuilder`: static vtable in metadata order, atomic AddRef/Release, IID-checking QI, completeness-or-E_NOTIMPL | `s10` builds an IDropTarget, RegisterDragDrop holds it (refcount 1->2), drop callbacks accumulate state, RevokeDragDrop releases (2->1); `f06` refuses a class that overrides IUnknown | **DONE** |
| C3-library | `com_tramp0..4` + `finish_state`: a COM class as a struct + small factory | `s11` rebuilds the IDropTarget as a `DropTarget` struct with raising methods, no raw fn pointers | **DONE** |
| C3-guidance | `class Name(IFace):` parses its header and hands back the library form for that interface | writing `class DropTarget(IDropTarget):` emits the exact struct-plus-factory to write instead | **DONE** |
| C3-keyword | compile a `class` declaration down to the library form | `class DropTarget(IDropTarget):` compiles to what s11 writes by hand | design (see cost note) |
| C4 | multiple interfaces (tear-off first, per the M2 cost model) + `raises` bridge | one object answering two IIDs; the cl.exe oracle calls both; shuffled-source must-fail proves slot order comes from metadata | design |
| C5 | `IDispatch` + BSTR/VARIANT | the IDE exposes one automation object a PowerShell script can call | design |

**Cost note on the remaining keyword.** The runtime, the trampolines, and the
library form are done and tested (17/17), so a COM class is already writable
in pure Mojo: a struct of state with raising methods and a four-to-six-line
factory (`s11`). What remains -- compiling `class Name(IFace):` *down to* that
factory -- is genuine compiler synthesis of one method body: a
`ComClassBuilder` construction, one `b.slot["M"](com_trampN[Name.M])` per
method at the metadata's arity, and a `finish_state`. The Mac ports sized the
equivalent as their one "L", "no partial credit" sprint, and the hard part
here is the same: forming, in MLIR, a reference to `com_trampN` specialised on
a method of the struct being defined. It is sugar over a working system, so it
is scoped separately and left for a deliberate, reviewed pass rather than
folded in with the runtime. Until then the keyword guides to the library form.

C3-library is the IDE's drop-target because the IDE plan (their
`IDE-DESIGN.md`, ours to be written against it) is the consumer that keeps
this honest: every milestone above is a capability the editor needs anyway.

---

## 9. Risks, named

1. **Slot order is the silent killer.** A vtable ordered by source or by
   alphabet dispatches wrong and *succeeds*. Metadata is the only order
   source; the shuffled-source must-fail test is non-negotiable; the `cl.exe`
   oracle exists chiefly for this.
2. **Signed constants.** Their SQL comments cite "the sister port's
   `HKEY_LOCAL_MACHINE` lesson (D6)" — a Win32 constant sign-extension bug we
   apparently already paid for, recorded in `COCOA_DESIGN.md` in MojoMacX64,
   **which is not yet cloned here**. Pull it before C0 and mine the D-series.
3. **Apartment misuse.** Calling an STA object from the wrong thread fails at
   a distance. `with apartment(...)` scoping plus a debug-build thread
   assertion in synthesized trampolines is the containment; full marshalling
   is explicitly out of scope.
4. **Metadata staleness wearing a source error's clothes.** `db_hash` +
   `availability()` from day one, per §6.
5. **`class` keyword expectations.** Upstream reserved `class` and may one day
   ship its own. Same standing policy as MojoCocoa's STATUS.md: this fork is
   frozen; the platform's object story is ours to define here.
