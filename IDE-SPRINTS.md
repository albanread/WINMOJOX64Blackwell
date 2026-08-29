# Griddle sprints — each lands on main, each with its acceptance line

*The working breakdown of `IDE-DESIGN.md`'s milestones. The rules are the
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

## Milestone 0 — the shell, agent-drivable before it can edit

**0.1 — a window (M).** `ide/griddle.mojo`: register the class, create the
window (`CreateWindowExW`), run the message loop, dark title bar via
`DwmSetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE)`, clean exit. All
calls metadata-typed; no hand-declared prototypes anywhere in the IDE, ever
— the first violation is a design bug, not a shortcut.
*Acceptance: the window opens dark-chromed, survives resize, exits 0; a
second launch gets its own window.*

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
