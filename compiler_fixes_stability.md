# compiler_fixes_stability — hardening before the IDE

*2026-08-29, written against commit `1b750f2`, where the suite stands at
22/22 (14 must-pass, 8 must-fail) and the GPU asyncrt tests at 7/7. This is
the defect register from a fresh review of the COM class runtime, the
trampolines, and the `class` desugar -- the work that stabilises the compiler
before the IDE is built on top of it. The companion design document is
`language_update.md`; this one is narrower: what is wrong, why it matters,
and the order to fix it in.*

## Where this stands

The proven ground, so the register below is read in proportion:

- Slot indices, arities, widths and IIDs come from the Win32 metadata
  database, never transcribed by hand. `s09` checks Mojo's calls against a
  cl.exe-built oracle object.
- `s13` verifies the three COM identity rules a broken multi-interface
  object violates silently: QI for a second interface returns a distinct
  working pointer; QI is symmetric and returns the *same* primary pointer;
  IUnknown is one pointer through every interface.
- One allocation and one atomic refcount govern each object; a client
  holding any interface keeps the whole object alive, and the last Release
  frees it exactly once. `s10` proves live OLE holds and releases a real
  reference.
- The `class` desugar is printable (`MOJO_DEBUG_COM_CLASS=1`): the generated
  source is ordinary Mojo, and `s11` is that source written by hand.

None of that is in question. The defects below are in the parts the tests
did not yet reach.

## The defect register

Ranked by how soon the IDE would trip over each.

### 1. Destructor leak: class state is never destroyed  *(severity: high)*

The block header reserves a destructor word (`_COM_H_DTOR`), and
`_com_class_release` calls it when the refcount hits zero -- but
`finish_state[T]` never fills it in. So the block is freed and `T`'s
destructor **never runs**.

Every current test passes because `DropTarget(Int, Int)` is trivial. The
moment a class holds a `String`, a `List`, or a `ComPtr` -- which an IDE
class will, on day one -- every object leaks its contents on Release.
Assignments *during* a method destroy the old value correctly; it is the
final values at object death that leak. The raw-words form
(`finish(state_words=)`, used by `s10`) is unaffected -- there is no `T` to
destroy.

**Fix.** A `_com_dtor[T]` thin `fn`, exactly parallel to the trampolines:
recover the state pointer from the block base, `unsafe_deinit_pointee` it.
`finish_state[T]` stores its bits in the dtor word. Add `T: Deinitable`'s
destructor to the test: an `s15` whose state holds a `String` and proves,
via a canary (e.g. a type whose destructor counts), that destruction runs
exactly once.

### 2. Any non-COM `def` breaks the class  *(severity: high)*

`parseClassStmt` scans the class body and wires **every** `def` into a slot.
A helper method -- `def reset(mut self)` -- or a user-written `__init__`
generates `__b.method["reset", X.reset]()`, which fails the
`_cell_of` constraint ("no implemented interface declares this method"),
reported from inside the synthesized buffer. The unwritten rule today is
*a class body may contain only COM methods*, which no user would guess and
the error does not explain.

**Fix.** Guard each generated wire call with a comptime-if on
`winkb_com_has_method` across the interface list, so a non-COM `def` becomes
an ordinary method of the struct and is simply not wired. The cost of the
guard, stated honestly: a *typo'd* COM method (`DragEntr`) is then also "not
a COM method", so it stops being a compile-time error -- it becomes a
missing slot, caught by `finish()`'s completeness check when the object is
constructed. That net already exists and already refuses to produce the
object; the typo is caught later but never silently.

**Follow-up that makes the net worth more:** `finish()` currently reports
*how many* slots are missing, not *which*. Naming them needs one new
metadata query (vtable index → method name over the chain CTE) plus its
`_winkb` wrapper -- modest, and it turns "3 slot(s) missing" into
"DragEnter, DragOver, Drop missing", which is the difference between a net
and a good net.

### 3. No signature check on the implementation side  *(severity: high)*

`f02`/`f03` refuse wrong arity and wrong width when *calling* COM. Nothing
checks them when *implementing* it. `method[name, m]` picks the trampoline
from the **method's own arity** and never compares it to the metadata's:

- Method declares *fewer* args than the slot: Win64 is caller-cleanup, so
  the extra args are silently ignored, the call "succeeds", and out-params
  (e.g. the DROPEFFECT) are never written. Half-works: the worst kind.
- Method declares *more* args than the slot: the trampoline reads registers
  and stack the caller never set. Garbage arguments; undefined behaviour.

This is a hole exactly where the Mac ports said the interesting half lives.

**Fix.** In each `method` overload, comptime-assert
`winkb_com_param_count[iface, name]()` equals the overload's arity, and each
`size_of[A_i]` matches `winkb_type_width` of the metadata's parameter type
-- the same checks `com_method_of` already applies on the consumption side,
mirrored. Two new must-fails: a class method with wrong arity (`f09`), and
one with a wrong-width argument (`f10`).

### 4. Diagnostics point into `<class Name>`, not the user's file

An error inside a class body is reported at `<class DropTarget>:25:12` --
the synthesized buffer's name and line numbers, offset by the generated
preamble. Tolerable for now (the body text is verbatim, so the code in the
message is recognisable), but it is an IDE blocker later: the IDE must map
diagnostics to source positions.

**Disposition: recorded, deliberately deferred.** The clean fix is to
translate positions in the synthesized buffer back through the known offset
of the captured body; do it when the IDE's diagnostic plumbing is designed,
not speculatively before.

### 5. Untested edges of the `class` grammar

Each of these needs a test (graceful error or defined behaviour), because
each currently produces either broken generated code or a confusing message:

| edge | expected today | wanted |
|---|---|---|
| empty class body | base indent computed from the *next* statement's line; generated `into_com` lands at the wrong indentation; confusing parse error | a located "a COM class needs at least one method" error |
| nested `class` inside a class body | captured into the body verbatim; fails somewhere downstream | the module-scope check already exists for structs; make the nested case a located error |
| CRLF source file | body captured verbatim including `\r`; the sub-lexer tolerates CRLF like the main one, but this is asserted, not tested | one spike saved with CRLF endings |
| dunder methods (`__init__`, `__del__`) | wired as COM methods; constraint failure | fixed by defect 2's guard; add to its test |
| non-Copyable field in a class | generated struct derives `(Copyable, Movable)`; derivation fails in the synthesized buffer | relax the desugar to `(Movable)` -- `into_com` consumes `self^` and `finish_state` needs only `Movable & Deinitable` |

### 6. QueryInterface does not answer intermediate bases

An object built over `IStream` answers QI for `IStream` and `IUnknown`, but
not `ISequentialStream` -- a conforming client that queries the base gets
E_NOINTERFACE. Fine for the drag-and-drop pair (both derive directly from
IUnknown), wrong for deeper chains, and the IDE will meet one (IStream on
IDataObject transfers is the obvious candidate).

**Fix.** At builder init, walk `winkb_com_interface_base` from each
implemented interface up to (not including) IUnknown, appending each base's
IID to the accepted table mapped to the *same cell* -- a base's vtable is a
prefix of the derived one, so the pointer is already correct. One spike:
an `IStream`-shaped object answering `ISequentialStream`.

### 7. Threading is STA-only, undocumented

AddRef/Release are atomic, but state mutation through methods is not
synchronized -- correct under `Apartment` (STA/OLE) semantics, where COM
serialises calls onto one thread. An object registered from an MTA would
race. **Fix:** say so in `ComClassBuilder`'s docstring and in
`language_update.md`; enforcement (apartment checks at build time) is not
worth its complexity today.

## Known behaviours to keep in mind (not defects)

- **Lazy instantiation.** Mojo instantiates generics at use, so a class
  whose slots cannot be resolved compiles cleanly until `into_com()` is
  actually called. `f07` had to *build* its object to trigger the ambiguity
  refusal. A broken class is diagnosed at use, not declaration.
- **ASAP destruction vs COM lifetimes.** Twice more in this milestone: IID
  bytes freed while QueryInterface was still comparing against them, and a
  `ComPtr` dying at its last use while QI references were outstanding. The
  pattern is recorded in `s13`'s comments; every raw-pointer handoff to COM
  needs its keep-alive.
- **Embedded multi-vtable, not lazy tear-off.** Every interface costs 16
  bytes in the block and is always present; in exchange, one allocation and
  one refcount. A true lazy tear-off is a memory optimisation with split
  lifetime rules -- not needed at IDE scale, revisit only if objects with
  many rarely-queried interfaces appear.

## Stability actions (beyond the fixes)

1. **Run the full stdlib battery.** Three parser changes have landed (`let`,
   `fn`, `class`). The spike runner compiles a large slice of the stdlib via
   imports on every run -- real but partial coverage. One clean
   `./bazelw.cmd test //mojo/stdlib/...` sweep is the honest gate before
   declaring the compiler stable. Run it once now, and again after the
   fixes above.
2. **Tag the known-good point.** `com-c4-green` at `1b750f2` (suite 22/22,
   GPU 7/7). Costs nothing; means IDE-era debugging can always answer "did
   the toolchain move, or did my program?"
3. **Keep the must-fail discipline.** Every fix above that adds a check adds
   its refusing test in the same commit. The suite's value is that the
   interesting half refuses.

## Order of work

| step | what | size |
|---|---|---|
| 0 | tag `com-c4-green`; kick off the stdlib battery | minutes |
| 1 | defect 1: `_com_dtor[T]`, wired by `finish_state`; s15 destructor-runs-once | small |
| 2 | defect 3: arity + width asserts in `method`; f09/f10 | small |
| 3 | defect 2: comptime-if guard per generated wire call; helpers-allowed test; dunder case | small-medium |
| 4 | defect 2 follow-up: name the missing slots (one new metadata query) | small |
| 5 | defect 6: base-chain IIDs at init; ISequentialStream spike | small |
| 6 | defect 5 edges: empty body, nested class, CRLF, Movable-only derivation | medium |
| 7 | defect 7: STA docstrings; re-run battery; move the tag forward | minutes |

Defect 4 (diagnostic mapping) is deferred to the IDE's diagnostics design on
purpose; it is the only item on this page that waits.
