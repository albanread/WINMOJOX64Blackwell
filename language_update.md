# language_update — `class`, `let`, and `fn` for COM

*2026-08-26. Written against this tree at `4aa5bec` and a survey of MojoCocoa
at `ce53b96`. Status: design, nothing below is built. The sibling documents to
read beside this one are MojoCocoa's `COCOA_CLASS_DESIGN.md` and
`COCOA_LET_DESIGN.md`, which record the decisions this document inherits, and
`COCOA_DESIGN.md` in MojoMacX64, which we have not yet pulled and should.*

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

| keyword | this tree at `4aa5bec` | MojoCocoa's use | our use |
|---|---|---|---|
| `class` | **Reserved, stubbed.** `ParserStmts.cpp:4067` parses the keyword and emits "classes are not supported yet" | an Objective-C class, on an attributed `StructDeclOp` | a COM object implementing N interfaces, on the same attributed `StructDeclOp` |
| `let` | **Absent.** No `kw_let`, no `kLetPat` | immutable binding, lowered onto the pre-existing `PatternDeclKind::kBind` | identical — port as-is |
| `fn` | **Parses, then refuses.** `DeclResolution.cpp:1958` emits "'fn' has been removed; use 'def' instead" with a FixIt | revived as *foreign-callable*: C ABI, non-raising, no captures | identical revival — the keyword for anything Windows calls |

So: `class` needs its stub replaced with a real parse (MojoCocoa's is 111
lines, `ParserStmts.cpp:4076-4187` there); `let` is a mechanical port their
own design doc sizes as "a handful of parser changes"; `fn` is the deletion of
one error and the attachment of a contract that already exists in this tree as
`abi("C")` — their `fn` merely engages it by default.

What we already have underneath, verified in this tree:

| piece | where | state |
|---|---|---|
| metadata database | `windows_api.db` via `@winkb` archive, from WRASM releases | 86 MB, fetched, hash-pinned |
| compiler hook | `winkb_query` in `KGENAttrs.cpp` + `IREvaluatorContext.cpp:1115` | working; used by `winkb_struct_size` etc. |
| query surface | `std/sys/_winkb.mojo` | 7 queries incl. `vtable_index`, `interface_iid` |
| ownership type | `ComPtr` in `std/sys/_com.mojo` (287 lines) | adopt / copy=AddRef / move / deinit=Release / `query_interface[T]` — proven live in `examples/win32/comptr.mojo` |
| raw dispatch | `com_method_of` | works, but the caller hand-writes the signature |

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

**The gating gap is metadata, and it is the first work item.** Their database
answers 25 named queries; ours answers 7. The missing 18 are all method
signatures — return kind, return type, per-argument ABI classification —
which is precisely what typed calls and comptime checking consume. WRASM must
grow the equivalent of `method_ret_kind` / `method_ret_class` / `method_abi`
for COM methods, from WinMD/typelibs, with **Win64 classification** (simpler
than their AAPCS64: four register slots, shadow space, >8-byte or
non-power-of-two returns go indirect). Until those tables exist, nothing in
§2–§6 can be verified.

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

| # | lands | verified by |
|---|---|---|
| C0 | WRASM emits COM method tables (ret kind/class, arg ABI classes, slot order) + the ~18 new named queries; `db_hash` bumps | queries answer for `IFileOpenDialog` and disagree nowhere with `cl.exe`'s headers |
| C1 | `Com[...]` typed receivers; HRESULT raises; out-params become returns | the §3 file-dialog snippet runs; must-fail: wrong arity, wrong arg register class, unknown method |
| C2 | `let` and `fn` land (port + revival) | `wnd_proc` as `fn` drives a real window; `let` rebinding is a compile error |
| C3 | `class` over one interface: vtable, AddRef/Release, QI, trampolines | `DropTarget` receives a real drag from Explorer onto an IDE window; refcount probe balances |
| C4 | multiple interfaces + this-adjustment; `raises` bridge | one object answering two IIDs, `cl.exe` oracle calls both; shuffled-source must-fail proves slot order comes from metadata |
| C5 | `IDispatch` implementation support + BSTR/VARIANT | the IDE exposes one automation object a PowerShell script can call — the AppleScript-dictionary analogue, which makes the IDE's scripting surface *be* this work |

C3 is deliberately the IDE's drop-target because the IDE plan (their
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
