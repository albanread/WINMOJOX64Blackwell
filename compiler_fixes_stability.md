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

## Progress — 2026-08-29, after the fixing pass

Steps 0-6 of the order below are done. What changed against the register:

| defect | outcome |
|---|---|
| 1 destructor leak | **fixed** — `_com_class_dtor[T]` wired by `finish_state`; `s15` is the canary and was verified to FAIL without the fix |
| 2 non-COM `def`s | **fixed** — `wire_if_com` plus a catch-all overload; `s16`. See the measured Mojo facts below |
| 3 no signature check | **fixed** — arity and width asserted against the metadata; `f09`, `f10`. The runner's must-fail glob had silently skipped `f10` |
| 4 diagnostics in `<class Name>` | still deferred to the IDE's diagnostics design, as planned |
| 5 untested edges | **empty body** fixed (it swallowed the rest of the file; now a located error, `f11`); **nested class** already refused correctly (`f12`); **CRLF** works, checked by the runner on a converted copy since git normalises committed files; **move-only state** fixed — the desugar derived `Copyable` and so refused any class holding an owned `ComPtr`, which is the ordinary IDE case (`s19`) |
| 6 base-chain QI | **fixed** — `com_chain_iids` returns a whole chain in one query, so depth is never unrolled; `s18` queries an IStream object for ISequentialStream and calls Read through it |
| 7 STA threading | **documented** — `ComClassBuilder`'s docstring states that these are single-threaded apartment objects: the refcount is atomic, the state is not, which is correct under `Apartment` and races in an MTA |

### One defect the register did not predict

**A nested class hung the compiler.** Not a poor diagnostic -- an infinite
loop: 5.5 million identical "must be declared at module scope" errors and no
termination. `parseClassStmt` rejected the nested case and recovered *before*
consuming the `class` keyword, and `skipUntilIndentation` stops on the current
token when it already sits at the target indentation, so the statement loop
re-entered on the same token forever.

MojoCocoa's `parseClassStmt` carries a comment about exactly this hazard,
which was read during the implementation and not carried across. Recovery now
consumes a token before skipping, the keyword is consumed before any
diagnostic can recover, and all five malformed-header paths (no name, broken
interface list, missing colon, empty list, class inside a function) were
checked to terminate.

The harness had the same gap: a hang read as a slow run, so the suite simply
never finished. Every compile is now capped, and a timeout is recorded as a
failure with its own message -- a must-fail test only means something if the
compiler survives it.

Also added, because defect 2 moved a typo from compile time to construction
time: `finish` now **names** the slots it is missing (`com_method_at_slot`),
so a mistyped `Drpo` reports "unfilled slot(s): IDropTarget.Drop" rather than
a count. `s17` makes the typo deliberately.

### Two Mojo facts this pass measured

Both were assumptions worth testing, and one of them was wrong:

- **`comptime if` prunes instantiation but NOT overload conversion.** A
  guarded call still resolves its overloads and still fails on a type
  mismatch, while a `comptime assert` inside a pruned branch never fires.
  That is why filtering helpers needs both a guard *and* a catch-all
  overload: neither alone covers every shape a class body can hold.
- **Generics instantiate lazily**, so a class whose slots cannot be resolved
  compiles cleanly until `into_com()` is called. Every must-fail that tests a
  class has to build an object, or it passes for the wrong reason.

### Stability

- `com-c4-green` tags `1b750f2`, the pre-fix known-good point.
- COM suite: **28/28** after defect 6; the edge additions (`s19`, `f11`,
  `f12`, the CRLF check) are being verified as this is written.
- The stdlib battery ran once and is **not yet a clean gate**: 14 pass, 1
  fails to build, 4 fail, and 350 skipped because the build abort cut the run
  short. Every failure was checked and none are ours -- `test_ffi` is an
  upstream test that supports only Linux and macOS (`comptime assert False,
  "test not implemented for the platform"`, no COM references), three are
  clang-tidy on C support files, one is lit configuration. It needs a
  `--keep_going` re-run to mean anything, which is step 7.

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
