# Griddle sprints — each lands on main, each with its acceptance line

*The working breakdown of `IDE-DESIGN.md`'s milestones — beginning with
sprint 0.0, the debugger, which stands before the window. The rules are the
Mac team's, because they were earned: every sprint lands on main green, every
sprint ends with an acceptance line that a script or a screenshot can check,
and the agent surface exists from sprint 2 so that every later sprint is
verifiable headless. `check-ide.ps1` grows one check per sprint and never
shrinks. A sprint that cannot state its acceptance line in one sentence is
two sprints.*

*Effort marks: (S) an afternoon · (M) a day or two · (L) the better part of
a week. The Mac calibration held for them; ours gets recalibrated after
milestone 0 against actuals.*

---

## Sprint 0.0 — the debugger stands up first

*Added after the first cut of this plan shipped without it. The Mac team's
design mentions `lldb-dap` in a services list; their reality was a compiler
campaign — an 886-line spike (`spikes/MOJOLLDB-SPIKE.md`) and dozens of
commits to get a variable's name and value from a stopped program to their
IDE. An IDE that cannot show `total = 10` at a breakpoint is a text editor
with opinions. This stands up before the window does, because it depends on
nothing the window provides — and because every later milestone gets to
assume a debugger that answers.*

**0.0.1 — the compiler emits debug info our debugger can read (M).** The
battle opened immediately, two layers deep. Format: MLIR's
`DebugTranslation` force-sets the `CodeView` module flag on MSVC triples
"unless set explicitly", so Mojo emitted `.debug$S`/`.debug$T` — CodeView,
unreadable by `MojoDWARFParser`, which is a DWARF parser by construction.
`ObjectCompiler` now sets `CodeView=0` explicitly; the backend emits
DWARF-in-COFF. Link: no `/debug` flag of any kind was passed, so even those
sections were dropped and `--debug-level full` produced images with **zero
debug info** — every breakpoint pending forever. `mojo-build.cpp` now links
`/debug:dwarf /OPT:NOREF` for debug builds. Windows has no dsymutil: the
executable IS the debug artifact, which quietly deletes the Mac's post-link
DIE-offset-rewrite problem from our future sidecar work.
*Acceptance MET (2026-08-30): the image carries `.debug_info` (61 KB),
`.debug_line`, `.debug_str`, `.debug_abbrev`, `.debug_ranges`, `.debug_loc`,
and `breakpoint set --file dbgfix.mojo --line 3` resolves to
`dbgfix.exe`dbgfix::add(...) + 24 at dbgfix.mojo:3:5` instead of staying
pending.*

*Standing rule for every debug sprint: the debuggee is built
`--no-optimization --debug-level full`. Optimized-with-symbols is a valid
build a user can ask for, and the debugger must not lie about it (locals
report as optimized out, honestly) — but it is never what the Debug button
produces.*

**0.0.2 — the CLI answers `frame variable` (M).** The fork already ships
`mojo-lldb.exe`, `lldb24.0.0git.dll` and `MojoLLDB.dll` (the export-`.def`
fight was this battle's opening move, months early). Load the plugin, break
in the five-line fixture, and ask.
*Acceptance MET:*

    (lldb) frame variable
    (__mlir_type.`!kgen.scalar<index>`) a = 0
    (__mlir_type.`!kgen.scalar<index>`) b = 0
    (__mlir_type.`!kgen.scalar<index>`) sum = 0

*and `bt` demangles the whole stack: `dbgfix::add(a=0, b=0)` →
`dbgfix::main()` → `std::builtin::_startup::__wrap_and_execute_main`. The
type rendering is the Mac's level-1 storage debugging, character for
character -- the same known frontier, not a Windows shortfall.*

**0.0.3 — lldb-dap builds and the probe passes (M).** `lldb-dap` was never
built here (the release manifest stops at the CLI), and building it
re-fought the exports war on the front only Windows has: `dllimport` is
prescriptive where Mach-O visibility is additive, so class-annotating
`FileSystem` (header-inline ctor), and the SB API's own
`LLDB_API=dllimport` meeting `SBCommand`'s implicit destructor and
`Status::takeError` (inline-only), each demanded imports no object defines
under `-O2`. This is why the Mac tree built dap "first try" and their
commits cannot help here. Fixes: `FileSystem` un-annotated with the reason
recorded beside it, two out-of-line members added to the export def, and
`llvm-lldb-dap-windows-inline-api.patch` compiles dap with **both**
annotation macros empty on Windows (`LLDB_API=`, `LLDB_PRIVATE_EXPORT=` —
the second needed an `#ifndef` guard added to the exports patch to be
overridable at all) — inline members inline, everything else through the
import library's thunks. `tools/dap-probe.py` is the
`lsp-probe` sibling: framing, `launch` with `initCommands: ["plugin load
MojoLLDB.dll"]`, breakpoint, stop, `stackTrace`, `scopes`, `variables` —
pass **only** if variables come back with values.
*Acceptance MET: `DAP PROBE PASS -- breakpoint verified, 3 variable(s) with
values`, headless, against `lldb-dap.exe` (2.4 MB, built here for the first
time). The session runs initialize → launch(initCommands: plugin load) →
setBreakpoints(verified) → stopped → stackTrace(`dbgfix::add(...)`) →
scopes(`Locals`) → variables.*

*One rendering note the IDE inherits: lldb-dap returns scalars as sixteen
hex digits, two spaces, then the decimal — `'0000000000000000  0'`. The Mac
team's `variable_value()` drops the hex when the shape matches exactly and
passes anything else through unchanged; ours needs the same, and the probe
prints the raw string so the shape stays visible rather than being quietly
prettified.*

**0.0.4 — port the Mac plugin fixes (M).** Their fixes are on their main
and not in our tree; each is small and named:
- **Idempotent target registration** (`Plugin.cpp`): ask the registry
  before `InitializeAllTargets`. Their one real crash ("Cannot choose
  between targets"); harmless here today because Windows DLLs do not unify
  symbols, load-bearing the moment the plugin is linked statically.
- **Expression parser self-location**: `dladdr` → `GetModuleFileNameW` on
  the DLL, `WINMOJO_ROOT` as override, so `expr` finds the stdlib.
- **Diagnostics hand-off**: errors were cleared unconditionally after
  broadcast, so every expression failure printed as nothing; make the
  hand-off conditional on a listener.
*Acceptance MET: `expr String("hi ") + String(42)` evaluates in the
debuggee, and `expr nonexistent_thing + 1` answers "use of unknown
declaration". The order mattered: the diagnostics fix had to land first,
because until it did the stdlib failure was an EMPTY error that read as the
debugger dying. One new export --
`Broadcaster::BroadcasterImpl::EventTypeHasListeners` -- is what makes
"is anyone listening?" answerable from a plugin. Self-location is
`GetModuleHandleEx` on our own address plus `GetModuleFileNameW`, the
Windows spelling of their `dladdr`, and it works with no environment set.*

*Known frontier, inherited not introduced: the CLI's fix-it rewrites
`1 + 41` to `_ = 1 + 41`, which runs and answers nothing. Frame locals are
still not injected into the JIT, so `total + 41` cannot work yet -- the Mac
spike's two erasures. Both are the semantic-type work, deferred with their
map.*

**0.0.5 — the check and the ship (S).** `check-ide.ps1` gains the dap-probe
as a required check whenever the plugin ships; the release manifest gains
`lldb-dap.exe`; a missing-variables regression is treated as packaging
breakage, exactly the Mac rule.
*Acceptance MET against the build tree: `tools/check-debugger.ps1` reports
**5 checks: 5 passed** -- fixture builds, DWARF in the image, breakpoint
binds, `frame variable` returns a/b/sum, DAP probe gets 3 variables -- with
no `WINMOJO_ROOT` set, so plugin self-location carries it. `-Root <release>`
runs the same five against a packaged layout, which is how a packaging
regression gets caught; running it that way waits on the next release build.
The manifest now ships `lldb-dap.exe`.*

**Deliberately deferred, with their map in hand:** semantic types. The Mac
spike proved the deep problem is two compiler erasures (representation and
declaration), decided per-type by `decl.isSingleElement()`, contagious
through members — `Int` and every one-field wrapper share one storage DIE.
Their remedy is a semantic sidecar joined on `(binary identity, canonical
DIE offset)`, one record to many dies (81% of variable dies are
multiplicity). We inherit that design wholesale when we get there; sprint
0.0 delivers storage-level debugging — real names, real values, raw types —
which is what their IDE shipped first too.

---

## Milestone 0 — the shell, agent-drivable before it can edit

**0.1 — a window (M).** `ide/griddle.mojo`: register the class, create the
window (`CreateWindowExW`), run the message loop, dark title bar via
`DwmSetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE)`, clean exit. All
calls metadata-typed; no hand-declared prototypes anywhere in the IDE, ever
— the first violation is a design bug, not a shortcut.
*Acceptance MET (2026-08-30):*

    griddle: window 525510 open  dark-titlebar hr = 0 (0 = accepted)
    griddle: client 1184 x 761
    griddle: client 624 x 441 after resize
    griddle: alive after resize: True
    griddle: closed cleanly            exit=0

*Two instances run at once and get distinct windows. The dark caption is
reported as an HRESULT rather than assumed -- "the call was made" and
"Windows accepted it" are different claims. Every call is metadata-typed and
every constant comes from `windows_api.db`: `WS_OVERLAPPEDWINDOW`,
`CW_USEDEFAULT`, `SW_SHOW`, `WM_DESTROY`, `SWP_NOZORDER` and
`DWMWA_USE_IMMERSIVE_DARK_MODE` are all queried, not spelled, and
`WNDCLASSEXW`/`MSG` layouts are asserted against Windows at compile time.*

*One environment fact worth having early, found here: a window created by a
process this build harness launches is not on the harness's interactive
desktop, so cross-process `EnumWindows` finds nothing for a window that
plainly exists and has a valid HWND. The app therefore inspects itself
(`--selftest`), which is also the honest shape -- sprint 0.3's screenshot
renders our own view hierarchy for the same reason.*

**0.2 — the agent surface, first light (M).** `WM_COPYDATA` in:
`verb args…` plus the sender's HWND; `WM_COPYDATA` back with the reply.
One dispatcher: `agent_command(text) -> text`. Verbs: `status`, `help`.
`tools/griddle-cmd.ps1` wraps send/receive for scripts, and
`tools/check-ide.ps1` is born with one check.
*Acceptance: `check-ide.ps1` reports `OK agent round trip` from a process
that never touches the UI.*

**0.3 — the app photographs itself (S).** `screenshot <path>`: render our
own client area to PNG (WIC encoder; `PrintWindow` on our own HWND as the
fallback spelling). No permissions exist to ask for on Windows; the verb
must work with the window occluded.
*Acceptance: PNG magic + sane byte count from an unattended run, window
covered by another.*

**0.4 — chrome, custom-drawn (L).** One HWND: D2D device + DComp swapchain
bring-up; draw the rail, sidebar strip, pane splits and status bar as
rects and text; real Win32 menu bar. Agent verbs: `views`,
`menu <Title> > <Item>` by visible name — the master key that puts every
future menued feature on the surface at a stroke.
*Acceptance: the screenshot shows all regions; `menu File > Exit` invoked by
name exits 0.*

**0.5 — drop-to-open, the dogfood moment (S).** The IDE registers its own
`class DropTarget(IDropTarget)` — the C3 milestone was named for this
window before the window existed. Dropped file paths echo to the status
line (the editor arrives in M1).
*Acceptance: the s10 harness drives a simulated drop and the path appears;
one manual drag from Explorer, documented as manual.*

---

## Milestone 1 — rope, grid, input: the long pole, and the latency claim

**1.1 — the rope (L).** `ide/rope.mojo`, ported from the Mac design:
B-tree, 4 KB UTF-8 leaves, fanout 32, `(bytes, newlines)` on every node;
persistent replace; line↔offset walks; snapshot = root copy. Port their
test suite shape (37 checks) rather than inventing one. Flag for the
oracle: this file is platform-free and shared.
*Acceptance: 250k lines built < 100 ms on this box; replace µs-scale;
rope checks green.*

**1.2 — the grid draws (L).** `ide/gridview.mojo`: DWrite text format
(Cascadia → Consolas), viewport→line-range mapping, glyph-run cache keyed
`(line, ropeRev, tokensRev)`, wheel scroll redraws only exposed lines —
cache hit counters printed so the claim is inspectable.
*Acceptance: a 250k-line file on screen; scroll a full page and the counter
shows only newly exposed lines drawn.*

**1.3 — caret truth (M).** ASCII fast path by arithmetic; any line with
non-ASCII gets x-positions and hit testing from `IDWriteTextLayout`
(`HitTestPoint` / `HitTestTextPosition`). Never hand-rolled.
*Acceptance: click lands the caret correctly on a line mixing CJK, emoji
and ASCII, verified against DWrite's own metrics in a check.*

**1.4 — editing (L).** Insert, delete, newline, selection; undo = the stack
of old roots, redo; dirty flag. Agent verbs: `type <text>`, `goto
<line>[:col]`, `caret`.
*Acceptance: the editing check suite (their 59-check shape) green; undo
depth 1000 costs kilobytes, measured.*

**1.5 — TSF, the COM showcase (L).** `ITfThreadMgr` activation;
`ITextStoreACP` implemented with the `class` keyword where arities fit and
the raw `slot[]` form where they don't (`GetText` is nine parameters —
first real consumer of the escape hatch; write down what it teaches).
Composition underline; commit; dead keys and AltGr through the same path.
*Acceptance: automated — the store's lock/GetText/SetText contract unit-
checked; manual, documented as such — composition through a real IME
(Pinyin) commits correctly. Day one of the sprint, not month three.*

**1.6 — find (M).** Literal find on the rope (leaf walk, never flattening),
highlight all, F3 / Shift+F3. Agent verb: `find <text>`.
*Acceptance: literal find over 100 MB < 200 ms.*

**1.7 — the budget run (S).** Scripted keystroke storm; PresentMon records
input-to-photon; numbers go into `IDE-DESIGN.md` beside the budgets.
*Acceptance: keystroke → photon ≤ 1 frame at this display's refresh, or a
named, filed reason why not.*

---

## Milestone 2 — the language server

**2.1 — probe before UI (M).** Build `//KGEN/tools/mojo-lsp-server`; drive
it from `tools/lsp-probe.py` alone: initialize, didOpen, a diagnostic, a
completion. The server has never been exercised on Windows; this sprint is
where its surprises surface, deliberately away from the editor.
*Acceptance: the probe transcript shows the handshake, one diagnostic and
one completion on a COM-using file.*

**2.2 — diagnostics in the editor (M).** Spawn per project; incremental
`didChange` from the rope's edit spans; squiggles + gutter + issues pane;
click to jump, opening files as needed.
*Acceptance: a file with a broken import shows its squiggle; clicking the
issue lands on the line.*

**2.3 — diagnostics come home (M).** The deferred compiler item: the
synthesized buffer is named `<class Name at file.mojo:line>`; the IDE maps
in-body positions back through the known preamble offset. CLI users get
the better buffer name even without the IDE.
*Acceptance: an error inside a `class` body jumps to the user's own file
and line, not `<class Name>:25`.*

**2.4 — completion (L).** The popup; local-lexer coloring instantly,
semantic tokens when they arrive; and the differentiator — inside a
`class` body, completion offers the interface's **unfilled slots** with
true arities from `windows_api.db`; inside `Com[...]` chains, the
interface's methods. Server-side extension in our fork if the protocol
needs help; we own both ends.
*Acceptance: in a class missing `DragOver`, the popup offers it with
`(key: UInt32, pt: Int, effect: Int) raises` sourced from the metadata.*

**2.5 — navigation (M).** Definition, hover, references, rename.
*Acceptance: rename a symbol used across two files; both change; undo
restores both.*

---

## Milestone 3 — documents: the refactor before the feature

**3.1 — Document (L).** The forty-globals gathering: rope, caret,
selection, undo stack, marked range, revision, URI, dirty flag into a
`Document`; the app holds a list and an index; the grid draws the current
one. Tab strip in the title bar area, custom-drawn.
*Acceptance: two documents, two tabs; switching preserves caret and undo
history in both; re-opening a file selects its tab rather than
duplicating.*

**3.2 — open and save (M).** `IFileOpenDialog` / save dialog through the
metadata (more COM dogfood); Ctrl+O/S; dirty dot; save-all; the
Run-on-unsaved question answered: Build saves every dirty buffer first,
because the compiler reads the disk.
*Acceptance: agent script opens, types, saves; the SAVED file's bytes
contain the typed text.*

**3.3 — the sidebar is a real tree (M).** Lazy children via
`FindFirstFileW`, cached per directory, dotfiles and `build\` hidden;
click opens; nothing is stat'd until its parent expands.
*Acceptance: open a folder with a quarter-million files beneath it;
expansion of one directory costs that directory only (counter shown).*

**3.4 — external changes (M).** `ReadDirectoryChangesW` on the project
root; a changed-on-disk document offers reload (or reloads silently when
clean).
*Acceptance: touch an open, clean file externally; the buffer updates;
touch a dirty one; the prompt appears.*

---

## Milestone 4 — build and run

**4.1 — proc.mojo (M).** `CreateProcessW` + pipes + **Job Object**; drain
without blocking from the message loop; launch failures *return* on
Windows and every call checks. This file owns the discipline; nothing
else spawns.
*Acceptance: Stop on a child that spawned a grandchild kills both —
`TerminateJobObject`, no survivors, proven by pid liveness.*

**4.2 — Build (M).** Entry-point rule inherited with its scars (main.mojo
→ on-screen root file declaring line-start `main` → the one non-test
candidate → the file on screen); save-all first; `path:line:col` parsed
into issues; jump opens the file if it is not open.
*Acceptance: an error in an imported, never-opened file jumps there.*

**4.3 — Run (M).** Build then spawn in the job, cwd = project, both streams
into one output pane; F5 / Ctrl+B; run only on exit 0.
*Acceptance: `examples/win32/nvidia_mandelbrot.mojo` builds and opens its
GPU window from F5.*

**4.4 — Examples view (M).** Cards from the toolchain's `share\examples`;
first open copies to `Documents\WinMojo Examples\`; Run uses 4.2/4.3
unchanged.
*Acceptance: run the mandelbrot from its card; the pristine copy's mtime
is untouched.*

**4.5 — Griddle builds Griddle (S).** The dogfood line, same as theirs.
*Acceptance: the IDE builds its own source tree and the binary it produced
opens a window.*

---

## Milestone 5 — projects

**5.1 — project polish (M).** Folder = project everywhere; MRU; jump list
via `ICustomDestinationList` (COM consumption on the shell side).
*Acceptance: two recent projects appear on the taskbar right-click and
open on click.*

**5.2 — project search (M).** ripgrep when present, rope scan otherwise;
results pane; click jumps.
*Acceptance: search the IDE's own folder for a string; every hit opens on
its line.*

---

## Milestone 6 — Python and the toolchain, surfaced

**6.1 — the lookup and the Toolchain view (M).** `WINMOJO_ROOT` →
`%LOCALAPPDATA%\WinMojo\current` → beside-the-binary, every candidate
checked for `bin\winmojo.exe`; the view lists versions, components, GPU;
`Make current` re-points the junction.
*Acceptance: a bare `griddle.exe` with an empty environment finds the
installed toolchain; sabotage the stdlib copy, watch a build fail,
re-point, watch it pass.*

**6.2 — Python environments (L).** Embeddable CPython in the toolchain;
venv per project at `Environments\<fnv1a>\py-<minor>`; the four env
values plus `PYTHONNOUSERSITE=1` injected before Build/Run/LSP; pip only
as `venv\Scripts\python.exe -m pip` in the console.
*Acceptance: the inherited smoke test — a compiled Mojo program imports a
marker module from the project venv.*

**6.3 — the Python view (M).** Create/Repair; install `requirements.txt`;
add one package; the "what Run injects" table shown, not hidden.
*Acceptance: install lands in the venv and not the user site; the view's
paths match the process's actual environment.*

---

## Milestone 7 — close the loop

**7.1 — the full verb set (M).** `open · save · goto · type · find · tabs ·
tab <n> · views · setting · console · file · caret` complete;
`run-script <path>` replays a saved session; CI runs
edit → build → diagnostics headless.
*Acceptance: the whole flow driven externally in CI on the built app.*

**7.2 — IDispatch, when C5 lands (M).** The automation object:
`Griddle.Application` with one method, `DoCommand(text) -> text`, onto the
same dispatcher; PowerShell drives it via `New-Object -ComObject`. Blocked
on the language plan's C5; the WM_COPYDATA surface is not.
*Acceptance: the PowerShell one-liner round-trips `status`.*

**7.3 — the glyph atlas, only if earned (L).** D3D11 atlas on the
`d3djulia` machinery, built only if 1.7's PresentMon numbers say D2D
drops frames.
*Acceptance: the measurement that justified it, then the measurement that
retires it.*

---

## Standing rules

- **Green in, green out.** A sprint merges with `check-ide.ps1` green and
  one check longer; the COM spike suite and the GPU tier stay green
  beside it.
- **No hand-declared Win32.** If a call is not in `windows_api.db`, that is
  a database question first and a workaround never.
- **Manual steps are documented as manual** (the IME sentence, the Explorer
  drag), because a check that cannot be honest is worse than no check.
- **What a sprint teaches gets written down** in the sprint's commit — the
  Mac doc's habit of recording the discovery beside the code is most of
  why translating it was cheap.
