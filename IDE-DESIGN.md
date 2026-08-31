# Griddle — a Mojo IDE, written in win-mojo

*Working name: the editor is a grid; a griddle is a grid that cooks. Sibling
of the Mac team's Roast — cocoa gets roasted, mojo gets griddled. Rename
freely.*

This is the design for a native Windows IDE written in the language it edits,
translated from MojoCocoa's `IDE-DESIGN.md` (863 lines, read at `5d823062`).
The architecture, the text engine, and the budgets are inherited whole,
because they were argued well and proven there. What changes is every pane of
glass between the rope and the screen — and all of it is Windows-specific on
purpose, because this IDE is the showcase for what win-mojo can do.

The thesis is theirs, and it lands harder here: **a monospaced editor is a
grid, a grid is arithmetic, and arithmetic beats a layout engine.** On the
Mac that arithmetic feeds Core Text into layers; here it feeds Direct2D and
DirectWrite over DirectComposition, which is **GPU-accelerated by default**.
A browser editor pays DOM → style → layout → paint → composite on every
keystroke; this design's keystroke path is microseconds of CPU and one
compositor frame, and everything below exists to keep that true.

## What it stands on

Every row verified in this repository; nothing is aspiration dressed as
inventory.

| piece | where | proven by |
|---|---|---|
| native windows, messages, typed Win32 calls | `std/sys/_win32.mojo` + `windows_api.db` | `examples/win32/windows_tour.mojo`, `nvidia_mandelbrot.mojo` |
| Direct3D from Mojo | the same metadata surface | `examples/win32/d3dwindow.mojo`, `d3djulia.mojo` |
| COM consumption, typed and checked | `std.sys.com` — `Com[...]`, arity/width gates | spikes s01–s09, the cl.exe oracle |
| COM *implementation* — objects Windows holds | `class Name(IFace)` → `ComClassBuilder` | s10 (OLE AddRefs us), s12–s14, suite 32/32 |
| the `class` / `let` / `fn` keywords | KGEN parser | the whole spike suite; tagged `com-c4-hardened` |
| the metadata database | `windows_api.db` — 86 MB, schema 6, 46,250 interface methods | every compile-time slot, arity, width and IID in the suite |
| AOT build and run | `mojo.exe build` | the release pipeline; every spike |
| GPU at interactive rates | CUDA sm_75 (T1000 here, sm_120a on the Blackwell box) | the mandelbrot; the matmul competition |
| language intelligence | `//KGEN/tools/mojo-lsp-server` | target in tree — **not yet exercised on Windows**; milestone 2 starts by probing it |
| debugger | `mojo-lldb.exe`, `lldb24.0.0git.dll`, `MojoLLDB.dll` all build and ship in the release | sprint 0.0 (below and in `IDE-SPRINTS.md`): the `/debug:dwarf` link fix, `lldb-dap`, and `tools/dap-probe.py` |

One verified fact carries more of this design than any other: **the entire
IDE surface is rows in the database.** `ITextStoreACP` (26 methods),
`ITfThreadMgr`, `ID2D1HwndRenderTarget`, `IDWriteFactory`,
`IDWriteTextLayout` (39 methods), `IDCompositionDevice`,
`ICustomDestinationList`, `IFileOpenDialog` — and `CreateWindowExW`,
`DwmSetWindowAttribute`, `D2D1CreateFactory`, `DWriteCreateFactory`,
`RegisterDragDrop`, `CreateProcessW`, `CreateJobObjectW`,
`ReadDirectoryChangesW`, `PrintWindow`, each with its DLL. The Mac team
hand-declared Core Text through `external_call`; we ask the database and get
arity and width checking for free. The IDE is not adjacent to the COM work —
it is its consumer.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│ one HWND · Win32 menu bar · custom-drawn everything else     │
├──────┬─────────────┬─────────────────────────────────────────┤
│ rail │ sidebar     │ GridView (D2D/DWrite on DirectComp)     │
│ EDIT │ lazy tree   │   ├─ rope snapshot (immutable)          │
│ PY   │ (FindFirst  │   ├─ glyph-run cache (visible lines)    │
│ EX   │  FileW,     │   └─ gutter: numbers + diagnostics      │
│ TOOL │  on demand) │                                         │
├──────┴─────────────┴──────────┬──────────────────────────────┤
│ issues pane                   │ output pane (build/run)      │
├───────────────────────────────┴──────────────────────────────┤
│ status: ln:col · UTF-8 · LSP ● · edit µs · Hz · GPU          │
└──────────────────────────────────────────────────────────────┘
      │ JSON-RPC over pipes             │ CreateProcessW
      ▼                                 ▼ (inside a Job Object)
 mojo-lsp-server.exe (one/project)   winmojo build / spawn
```

Three processes, and the reasons transfer without edits:

- **The editor never parses Mojo.** The language server does — diagnostics,
  completion, definition, rename, semantic tokens. The editor is written in
  Mojo, so LSP over stdin/stdout is the boundary.
- **The editor never runs user code in-process.** Run = AOT build + spawn.
  JIT'd code calling `exit()` takes its host with it; the editor is
  precisely the host that must survive. On Windows the child runs **inside a
  Job Object**, so Stop is `TerminateJobObject` and the whole child tree
  dies with it — the zombie-process class the Mac design lists as its actual
  crash source is retired here by construction.
- **We own both ends of the wire.** The server is in this tree. Where LSP is
  thin — project symbol index, build-on-save, and above all the
  `windows_api.db` completion — we extend our server rather than work
  around a vendor's.

One deliberate Windows shape: **one HWND, everything custom-drawn.** The
menu bar is a real Win32 menu (native, free, and the agent can invoke it by
name); the rail, sidebar, panes and status bar are drawn by the same D2D
pass that draws the text. No child-control zoo, no WinUI, no XAML — a layout
engine is the thing the thesis refuses. This also keeps keyboard focus
trivial, which matters because TSF wants one clear focus owner.

## The text engine: a persistent rope

Inherited verbatim — the rope is the one structure that carries the whole
design, and nothing about it is platform-specific. B-tree rope, UTF-8 leaves
of ~4 KB, fanout 32, every node caching `(bytes, newlines)`. Persistent:
an edit copies the ≤4-node path and returns a new root, so **undo is a stack
of old roots**, **snapshots are one pointer copy** (background LSP sync,
search and save read a snapshot on another thread with no lock), and **a
save cannot be torn by typing**. Their engine measurements — 2.4 µs edit,
5 ms to build 250k lines, 400 ns snapshot — are measurements of this design;
ours get taken on this machine at milestone 1.

This is the first piece of real cross-port code sharing: the rope, the JSON
layer, and the LSP client logic are platform-free. They belong in the oracle
so the sister ports write them once — findings have crossed the oracle all
year; this is code.

## The render path, and why it beats a browser here too

`GridView` owns no text storage — it borrows the current rope root and
draws, through a `D2D1CreateFactory` / `DWriteCreateFactory` pair the
database already describes.

- **Layout is arithmetic.** Fixed-pitch font: x = column × advance, y = line
  × lineHeight, document height = lineCount × lineHeight. No layout pass
  exists to be slow.
- **Draw only the viewport.** The dirty rect maps to a line range; each line
  comes from the rope (O(log n) + O(len)) and is drawn as a cached glyph
  run keyed on `(line, ropeRevision, tokensRevision)`. Scrolling redraws
  only newly exposed lines; DirectComposition translates the rest.
- **Unicode without lies.** The rule transfers intact: **cells for layout,
  DirectWrite for truth.** Pure-ASCII lines take the arithmetic path; any
  line with CJK, emoji or combining marks gets x-positions and hit testing
  from `IDWriteTextLayout` — `HitTestTextPosition` / `HitTestPoint`, never
  hand-rolled, because DirectWrite already knows where the glyphs are.
- **Selection, caret, squiggles** are rects and underlines on a grid.
  Diagnostics paint as gutter marks plus an underline layer.
- The editor font is Cascadia Code with Consolas as fallback — both ship
  with Windows.

The budget, and what enforces it:

| action | budget | measured | mechanism |
|---|---|---|---|
| keystroke → glyph | ≤ 1 frame (6.9 ms @ 144 Hz, 16.7 @ 60) | **4.99 ms** of work, 29.9% of a frame at 60 Hz; 0 frames missed in 200 | O(log n) rope edit + the visible lines relaid + vsync present |
| open 250k lines → first paint | < 100 ms | **16.7 ms** to build the rope | single-pass rope build; paint visible only |
| full-speed scroll | 0 dropped frames | **0** in 120, worst frame 17.7 ms | draw exposed lines from the layout cache |
| literal find, 100 MB | < 200 ms | **11.8 ms** over 104 MB | leaf walk; the buffer is never flattened |
| completion popup | < 50 ms after reply | built, sprint 2.4 | the list is drawn in the frame; the server did the work |

The keystroke figure moved from 0.85 ms to 4.99 ms in sprint 2.4, and both
halves of that are worth naming. Syntax colouring now runs on every line that
is laid out, and the window is half again larger because the process became
DPI-aware, so there are 36 lines on screen where there were 26. Neither is
free and neither is a regression to fix — they are the cost of the feature and
of drawing at the display's real resolution.

What *was* a regression, briefly, is worth recording: the first version asked
`_starts_in_docstring` for every line it drew, and that walks two hundred
lines back each time. Thirty-six lines on screen made it seven thousand rope
reads a frame, and a keystroke changes the revision so every frame paid it in
full — **21.1 ms, 127% of a frame**. The state is threaded down the visible
range instead, which is two hundred reads once plus one per line. Caching the
four syntax brushes on the chrome rather than making one per coloured word
was the obvious other suspect and turned out to be worth nothing measurable;
it stayed anyway, because a Direct2D object per word per line per keystroke is
not a thing to leave in on the grounds that it did not show up.

All measured on this machine (60 Hz display) with the optimized build, by
`tools/check-ide.ps1` and the `storm`, `frame` and `find-bench` verbs. The
debug build — which is what ships, because sprint 0.0 wants it debuggable —
costs 3.4 ms of work per keystroke rather than 0.85, still a fifth of a frame.

**The keystroke number, precisely.** What is measured is the WM_CHAR handler
being entered to the last drawing command being issued: the whole of this
application's response. It does not include the keyboard, its driver and the
message queue on one side, or scanout and panel response on the other. It does
not track document size — it is the same on a 14 MB document as on a 104 MB
one — which is the entire thesis and the reason the budget is holdable at all.
It tracks the number of lines on screen, which is the right thing for it to
track.

Add one refresh interval for the wait at the vertical blank and that is
keystroke-to-photon less the two hops above: worst observed 20.3 ms against a
33.3 ms ceiling for "made the frame after the one it arrived in". Nothing
missed a frame in any run.

**PresentMon, and why not.** The plan was to measure input-to-photon with
PresentMon, which reads both missing hops out of ETW. It is not installed
here, and downloading and running an external binary is a decision for a
person rather than something a sprint should do on its own. The application
half is measured precisely instead, and the two unmeasured hops are named
rather than folded into a number that would look more complete than it is.
See `docs/latency.md`.

### Scale: DPI now, zoom later, one number

Every measurement in the editor is written once at 96 DPI — `RAIL_W = 52`,
`GUTTER_W = 56`, `LINE_H = 16` — and multiplied through `scaled()` in
`ide/win32.mojo`. Exactly one function knows what a pixel is worth.

The process declares itself per-monitor-DPI-aware in `ide/griddle.manifest`,
embedded into the executable by `mt.exe` at build time, with a
`SetProcessDpiAwarenessContext` call in `main` as the fallback for a binary
run without it. Without that declaration Windows reports a smaller desktop
than there is, lets the process draw at that size and stretches the result:
blurry text in an editor, which is the one thing an editor may not have. On
the machine this was written on the desktop is 2560×1440 at 150%, reported as
1707×960 — everything was being scaled up by half again.

`WM_DPICHANGED` takes the window rect Windows suggests and then goes through
the same rebuild a lost device does. It has to: the font size is baked into
the text format, and every cached line layout was made with that format.

**The View menu's zoom belongs here, and is one line when it comes.** A person
zooming in and a person dragging the window to a denser display want the same
thing — everything bigger by the same factor — so zoom multiplies this scale
rather than forking a second one, and every rectangle, the gutter, the row
height and the font follow for free. Ctrl+`+`, Ctrl+`-`, Ctrl+`0`, and View →
Zoom In / Zoom Out / Reset Zoom naming the same three. What that sprint has to
do beyond the multiply is invalidate the layout cache and rebuild the text
format, which is what `recreate` already does for a DPI change — so the work
is a zoom factor on the `Doc`, three menu items, and reusing that path.

**Milestone 7, optional:** a D3D11 glyph-atlas renderer on the machinery
`d3djulia` already proves, for guaranteed high-refresh scrolling. D2D is
expected to hold the budget without it — it is already the GPU. Measure
before building it.

## Input is TSF, fully — and it is the COM showcase

The Mac design names NSTextInputClient as the place native editors quietly
fail, schedules it first among the hard things, and tests with a real IME on
day one. The Windows analog is sharper in both directions.

**Text Services Framework is a COM interface the app must implement** —
`ITextStoreACP`: 26 methods of sessions, locks, and change notification,
plus `ITfThreadMgr` activation. That is exactly the shape the `class`
keyword and `ComClassBuilder` were hardened for, which makes TSF both the
highest-risk item and the proof in anger: **if the keyword can carry a text
store, the COM story is real.** It is milestone 1, not month three, and the
acceptance is composition through an actual IME.

One known seam, named now: several `ITextStoreACP` methods are wider than
the four-argument trampoline family (`GetText` alone takes nine). The raw
`slot[]` escape hatch already accepts any arity — that is what it is for —
and extending `com_trampN` upward is mechanical when the ergonomics earn
it. The text store will use both forms, deliberately, and document which and
why.

Dead keys, AltGr, and the emoji panel (Win+.) all arrive through the same
machinery; none of them get special cases.

## The debugger — the battle the first draft of this document forgot

The Mac team's design mentions `lldb-dap` in a services list, and that
understates their reality so badly it nearly misled this one: getting
variable names and values from a stopped Mojo program to their IDE was a
**compiler campaign**, fought across dozens of commits and an 886-line spike
document (`spikes/MOJOLLDB-SPIKE.md`, read in full at `5d823062`). This
section exists so we inherit the war, not just the treaty.

**Their findings, imported.** Variables fail to inspect not for lack of
DWARF — the DWARF is rich — but because `DW_AT_language(DW_LANG_Mojo)`
makes LLDB demand a TypeSystem plugin: no plugin, no variables, even for a
plain `Int`. `KGEN/lib/MojoLLDB` is that plugin (TypeSystem, DWARF parser,
formatters, a JIT expression parser, break-on-raise). It must load into an
lldb built from the **same tree** — ABI, `lldb_private` symbol visibility,
and LLVM global state each independently rule out anyone else's lldb. Their
deeper discovery is a compiler truth we now hold too: **debug info suffers
two erasures**, representation (`Meters` lowers to `index`) and declaration
(the tie to the real decl is gone), decided per-type by
`decl.isSingleElement()` — so `Int` and every one-field wrapper share one
storage DIE, and the erasure is contagious through members (`p.x` falls even
when `Point` survives). Their remedy-in-progress is a **semantic sidecar**
beside the debug info, joined by `(binary identity, canonical DIE offset)`,
one record to many dies — 81% of variable dies are multiplicity, so a 1:1
map presents as flakiness. None of that is Mac-specific; when we reach
semantic types, we implement their contract rather than rediscovering it.

**Where this fork already was**, verified: the release manifest ships
`mojo-lldb.exe`, `lldb24.0.0git.dll`, `MojoLLDB.dll`, `lldb-argdumper.exe`
and `mojo-repl-entry-point.exe` — the export-`.def` fight
(`lldb-windows-private.exports.def`, and the `opt`-elided-destructor scar
recorded in project memory) was this battle's Windows opening, already won
before the IDE existed.

**The verdict (2026-08-30): the debugger answers on Windows.**

    (lldb) frame variable
    (__mlir_type.`!kgen.scalar<index>`) a = 0
    (__mlir_type.`!kgen.scalar<index>`) b = 0
    (__mlir_type.`!kgen.scalar<index>`) sum = 0

    DAP PROBE PASS -- breakpoint verified, 3 variable(s) with values

Both paths: the CLI, and the DAP wire the IDE will actually use. The stack
demangles whole (`dbgfix::add(a=0, b=0)` → `dbgfix::main()` →
`__wrap_and_execute_main`), and the type rendering matches the Mac's
character for character — the same level-1 storage frontier, not a Windows
shortfall. Sprints 0.0.1-0.0.3 are done; what follows is the story of what
had to be fixed to get there.

**What the spike found, each with its fix:**

- **Debug info was wrong twice before the debugger ever saw it.** First
  the format: MLIR's `DebugTranslation` force-sets the `CodeView` module
  flag on MSVC triples "unless set explicitly", so Mojo emitted
  `.debug$S`/`.debug$T` — CodeView, which `MojoDWARFParser` cannot read;
  the plugin is a DWARF debugger by construction. `ObjectCompiler` now sets
  `CodeView=0` explicitly and the backend emits DWARF-in-COFF. Second the
  link: the Windows link line passed no `/debug` flag in any form, so even
  those sections were dropped and the image had **no debug info at all** —
  LLDB left every breakpoint pending forever, which reads as a debugger
  defect and was two missing decisions. `mojo-build.cpp` now links
  `/debug:dwarf /OPT:NOREF` for debug builds. Windows has no dsymutil; the
  executable *is* the debug artifact — which also deletes the Mac's
  post-link DIE-offset rewrite problem from our sidecar future.
- **`dllimport` and inline members, the Windows-only trench.** The
  exports patch class-annotated `FileSystem`, whose default constructor is
  header-inline; class-level `dllimport` *forbids* using the inline body,
  and `lldb-dap` was the first consumer to touch it. The same disease in
  the SB API: `SBCommand`'s implicit destructor and `Status::takeError`
  exist only inline, so dap's default `LLDB_API=dllimport` demanded
  imports no object ever defines. Mach-O never meets any of this —
  visibility annotations are additive, which is why the Mac tree built
  dap "first try, no source changes" and their commits cannot carry this
  part. Fixes: `FileSystem` un-annotated (functions resolve through the
  import library's thunks with no annotation), two out-of-line
  `FileSystem` members added to the export def, and a new overlay patch
  compiles dap with `LLDB_API=` empty on Windows.
- **`lldb-dap` was never built here** — the target exists; the release
  manifest stops at the CLI. Built now, probed by `tools/dap-probe.py`
  (our `lsp-probe` sibling: framing, launch-with-`initCommands`,
  breakpoint, stop, scopes, variables — pass only if variables come back
  with values).
- **Their plugin fixes are not in our tree** and get ported in sprint 0.0:
  idempotent target registration (their one real crash — harmless here
  today because Windows DLLs don't unify symbols, load-bearing the moment
  the plugin is ever linked statically), the expression parser's
  self-location (`dladdr` → `GetModuleFileNameW`, `WINMOJO_ROOT`
  override), and the diagnostics hand-off that erased every expression
  error when no listener was attached.

**Windows differences that matter, called now:** no dsymutil (offsets
final at link — the sidecar join simplifies), no DevToolsSecurity (no
authorization wall, nothing to hang headless runs), `link.exe` name
collisions (the compiler shells to `link`; under an MSYS shell that
resolves to coreutils' `/usr/bin/link` — the toolchain lookup must pin the
real linker, not trust PATH), and Job-Object process control instead of
their stranded-`SIGSTOP` cleanup.

**The build matrix, made explicit.** Debug means
`--no-optimization --debug-level full`, always — the IDE's Debug action
never hands the debugger an optimized binary. The Mac team paid for this
twice: optimized builds delete locals from the DWARF entirely (`total` and
`sum` simply absent, breakpoints sliding out of loops), and their dap test
passed for the wrong reason until it built `-O0`. Run stays optimized;
Debug is a different artifact in `build\debug\`, not a flag on the same
one — so switching between them never silently rebuilds the other's output.
The inverse rule guards the other direction: requesting symbols must never
secretly deoptimize, which is why `/debug:dwarf` is a linker decision and
optimization stays exactly what the user chose. And the toolchain itself
stays `-c opt`: the inline-member fights above are fixed by not demanding
imports for inline members, never by deoptimizing the debugger.

**In the IDE**, the surface is theirs: `lldb-dap` per session, plugin via
`initCommands`, locals pane from `scopes`/`variables`, break-on-raise as a
Debug-menu toggle, stepping through the real toolbar buttons, `evaluate`
as an explicit gesture because it runs Mojo in the debuggee. The
`Document`/console machinery they bolted it onto is the same machinery our
milestones 2-4 build.

## Language intelligence

One `mojo-lsp-server.exe` per project window, spawned like any child here —
`CreateProcessW`, pipes, JSON-RPC with `Content-Length` framing. The server
is in this tree; milestone 2 begins by building it and probing the wire with
a script, the way the Mac team's `lsp-probe` did, before any UI consumes it.

- `initialize` / `didOpen` on open; **incremental `didChange` from the
  rope's edit spans** — the span is known exactly, so this is free.
- **Diagnostics** → gutter, squiggles, issues pane; click to jump.
- **Completion** — and the reason it will feel different from every other
  editor: inside a `class` body the popup offers the interface's **unfilled
  slots** with true arities from `windows_api.db`; inside `Com[...]` call
  chains it offers the interface's methods the same way. This is the analog
  of the Mac's Cocoa-database completion, and our database side is already
  wired into the compiler.
- A tiny local lexer colors keywords/strings/comments instantly while
  semantic tokens are in flight, then yields.
- Definition, references, hover, rename, signature help: straight protocol
  work.

**Diagnostics come home.** `compiler_fixes_stability.md` defect 4 deferred
one thing to exactly this design: errors inside a `class` body report
against the synthesized buffer (`<class Name>:25`), not the user's file.
The fix is split where it belongs — the compiler names the synthesized
buffer with its origin (`<class Name at dragthing.mojo:7>`), and the IDE's
diagnostic pipeline maps body line numbers back through the known preamble
offset. Sprinted in milestone 2; the CLI benefits from the buffer naming
even without the IDE.

Known capacity issue, inherited: the server re-parses the stdlib per open
document. Mitigation now: cap synced documents. Fix later: in our fork,
because we own it.

## Build and run

- **Build** = save every dirty buffer, then `winmojo build <entry> -o
  build\<stem>.exe`. Diagnostics are the `path:line:col: severity: message`
  shape; parse into the issues pane; click to jump — opening the file if
  needed, because the error is often in something the entry point imported.
- **Run** = Build, then spawn the binary **in a Job Object** with cwd set to
  the project folder, stdout/stderr on one pipe into the output pane. One
  pane for both streams, because a build that succeeds and then runs is one
  continuous thing to read. Stop terminates the job — the whole tree, no
  survivors.
- **Entry point**, cheapest test first, inherited with its scars: 1.
  `main.mojo` in the root; 2. the file on screen if it is in the root and
  declares a top-level `main`; 3. the one non-test file in the root that
  does; 4. the file on screen. "Declares" means at the start of a line —
  their doc records a substring scan nominating the build script as the
  editor's entry point. Save-all before build is not optional: the compiler
  reads the disk, and building without it looks precisely like the compiler
  ignoring your fix.
- **A project is a folder.** No project file, no workspace format, no index.
  `mojoproject.toml` can arrive when something needs it.
- F5 run, Ctrl+B build. `Griddle builds Griddle` is milestone 4's
  acceptance, as `Roast builds Roast` was theirs.

## Python is embedded; environments are not

`std.python` loads CPython into the running Mojo program — there is no
Python worker process. The design transfers from the Mac nearly clause for
clause, and Windows makes the hard part easier: the toolchain carries the
**python.org embeddable package**, an artifact that exists precisely to be
redistributed like this. No framework surgery, no load-command rewriting.

Each project gets a venv at:

```
%LOCALAPPDATA%\WinMojo\Python\Environments\<fnv1a-hash>\py-<minor>
```

The FNV-1a hash keeps source paths and punctuation out of directory names
and stops projects with the same basename sharing packages; the Python-minor
component makes a runtime upgrade create a compatible environment rather
than pointing a new CPython at the old `site-packages`.

Before Build, Run, or LSP launch, Griddle overlays the inherited
environment:

| value | role |
|---|---|
| `MOJO_PYTHON_LIBRARY` | the toolchain's `python3xx.dll`, loaded into the Mojo process |
| `MOJO_PYTHON` | the venv's `Scripts\python.exe` |
| `PYTHONHOME` | the toolchain's relocated standard library |
| `VIRTUAL_ENV` | the project environment's identity for child tools |

plus `PYTHONNOUSERSITE=1`, so a successful import cannot secretly depend on
the user's global packages. pip is only ever invoked as
`venv\Scripts\python.exe -m pip` in the console — never imported into an
initialized interpreter, and no shell ever parses a requirement. The Python
view can create or repair the venv, install `requirements.txt`, or add one
package.

The smoke test that proves both halves at once is inherited verbatim: create
a real venv, compile a Mojo program, and have it import a marker module from
that venv.

## Examples are managed, not scattered

The toolchain ships `share\examples` — and every example named in this
design exists in `examples/win32/` today: `nvidia_mandelbrot` (CUDA into a
native window, sm_75 here and sm_120a on the Blackwell box), `d3djulia`,
`d3dwindow`, `windows_tour`, `winkb_queries`, and the COM `class` showcases.
The Examples view presents them as cards with Run and Open.

First open copies the example into `Documents\WinMojo Examples\` — the
installed copies stay pristine, so experimenting is free and Reset always
heals, the same contract the Mac's File → Reset keeps. Run uses the same
build path as any project.

## Scriptable, the Windows way

The Mac's agent surface — one dispatcher, text verbs, replies as text, the
app photographing itself — transfers whole, minus an entire category of
problems: **Windows has no TCC.** Nothing here needs a permission grant.

- **Transport: `WM_COPYDATA`,** the classic text-in/text-out message. The
  sender (a script, CI, an assistant) creates a message-only window, sends
  `verb args…` with its own HWND in the payload, and the reply comes back
  the same way. Works headless; needs no registration.
- **One dispatcher.** The handlers unwrap the text, call
  `agent_command(text) -> text`, wrap the reply — the same functions the
  menus call, so every agent run is also a UI test.
- **The verb set** starts as theirs: `open · goto · save · type · find ·
  build · run · stop · status · console · caret · file · views · setting ·
  menu <Title> > <Item> · screenshot <path>`. Menu invocation by visible
  name is the master key — every menued feature joins the surface at a
  stroke.
- **The screenshot is the app rendering itself** — the D2D target into a
  WIC bitmap, PNG out. View drawing, not screen capture; works occluded.
  `PrintWindow` on our own HWND is the fallback spelling. It answers "does
  the window look right" from inside the process, unattended.
- **`IDispatch` later, not first.** COM automation is the platform's real
  scripting registry and the analog of the sdef — and it is C5 on the
  language plan. When `IDispatch` lands in `std.sys.com`, Griddle registers
  an automation object whose one method is `DoCommand(text) -> text`, and
  PowerShell drives the same dispatcher through `New-Object -ComObject`.
  Raw `WM_COPYDATA` works everywhere regardless; the automation object is
  polish, not plumbing.
- **`griddle --cmd "status"`** wraps the send for scripts, so CI greps text
  without knowing any of the above.

The design rules are inherited because they were earned: verbs press the
real controls; slow operations answer `requested` and the agent confirms by
reading state; no verb touches a shell; receiving is inert without a sender.

`check-ide.ps1` is this surface's first consumer and exists from milestone
0 — the shell is agent-drivable before it can edit text, which is what made
the Mac's later sprints cheap.

## The toolchain is the product

The Mac doc argues its way to an installed toolchain across three sections
and seven sprints. We start where they arrived, and Windows removes their
two hardest problems.

```
%LOCALAPPDATA%\WinMojo\
  current  →  0.4.0-blackwell        directory junction — no privilege
  0.4.0-blackwell\
    bin\      winmojo.exe · mojo-lsp-server.exe
    lib\      mojo\{stdlib, max, kernels}
    share\    examples · windows_api.db · griddle-source
    Python\   CPython 3.12, embeddable package
  0.3.9\                             versions coexist; `current` moves
  Python\Environments\<hash>\py-3.12 per-project venvs

Documents\WinMojo Examples\          user-editable copies
```

- **No installer privilege problem exists.** `%LOCALAPPDATA%` is the user's
  own — no admin, no UAC, ever. VS Code ships its default install exactly
  this way. v1 "installer" is a zip plus a first-run junction; a signed
  `Install Griddle.exe` with Install / Reset / Uninstall buttons (and the
  same flags for CI: `--install --root <scratch>`, `--reset`,
  `--uninstall [--user-data]`) can follow when release polish earns it.
- **The database ships, honestly.** Their `cocoa.sqlite` snapshots whichever
  Mac cut the release and drifts the moment Xcode updates, so they generate
  on install. Win32 metadata is a **versioned artifact** — the same 86 MB
  describes the same Windows everywhere. Their hardest install problem is
  absent here by construction.
- **One lookup, from day one:** `WINMOJO_ROOT` (a harness pointing somewhere
  deliberate) → `%LOCALAPPDATA%\WinMojo\current` → beside the binary (a
  development tree). A root counts only if `bin\winmojo.exe` is really
  there. Their doc records three generations of path-guessing that this
  list replaces; we skip the generations.
- **Reset never touches user space.** Re-copying a version heals a toolchain
  that was experimented on; `Documents\WinMojo Examples` and the venvs
  survive untouched.
- **Junction, not symlink**, because `CreateSymbolicLinkW` wants developer
  mode or a privilege and `mklink /J` wants neither. The lookup only ever
  resolves a directory, so the distinction costs nothing.

The warm-compiler service — a resident process holding a parsed stdlib
behind a named pipe, turning cold builds into requests — is the same future
their doc names. Named pipes are the Windows-native shape for it. Direction,
not plan; nothing below depends on it.

## What the stdlib must grow

Each small, each reusable beyond the IDE, each honest about origin:

1. **`std.rope`** — the persistent rope. Port the Mac team's design;
   share it back through the oracle.
2. **JSON** — port `ide/json.mojo` from the Mac tree (30 tests,
   platform-free) rather than writing a second one.
3. **East Asian width table** — cell-width classification for the grid.
4. **`ide/proc.mojo`** — CreateProcessW + pipes + Job Object, guarded the
   way this platform wants: launch failures *return* on Windows rather than
   raise, and we check.
5. **`ReadDirectoryChangesW` wrapper** — external-change detection.
6. **Trampoline arity ≥ 5** — or the documented raw-`slot[]` pattern for
   wide COM methods; TSF forces the question, above.
7. **D2D/DWrite/DComp declarations — none needed.** They are database rows;
   consumption is the existing `Com[...]` surface. This line exists to
   record the absence of work.

## Deliberately not building

- **No WinUI, no XAML, no Electron, no web view.** A layout engine is the
  thing the thesis refuses; raw Win32 + D2D is the point.
- **No plugin system in v1** — the agent surface plus our own server
  extensions cover it.
- **No admin installer.** User-space or nothing.
- **No minimap, no proportional fonts.**
- **No in-process compiler.** The subprocess story is simpler and
  crash-isolated.

## Milestones, each verifiable

| # | lands | verified by |
|---|---|---|
| 0 | shell: window, dark title bar, menus, custom-drawn chrome, **agent surface + self-screenshot**, drop-to-open | `check-ide.ps1` drives it headless; PNG from an unattended run; a dropped file's path echoed |
| 1 | **rope · D2D grid · TSF · caret · selection · undo · find** — the long pole | 250k lines < 100 ms; keystroke storm under PresentMon ≤ 1 frame; **composition through a real IME**; rope + editing check suites |
| 2 | LSP: probe, diagnostics, completion (incl. `windows_api.db` slots), definition; **diagnostics mapped out of `<class>` buffers** | completing an unfilled COM slot with true arity; clicking an in-class error lands in the user's file |
| 3 | documents: the globals-to-`Document` refactor, tabs, open/save (`IFileOpenDialog`), dirty tracking, watcher; **the View menu, including Zoom In / Out / Reset** | two tabs; re-open selects, not duplicates; Run-on-unsaved answered by save-all; zoom changes the reported `scale` and every region with it |
| 4 | build, run, console, jump-to-error, Examples view | **Griddle builds Griddle**; the mandelbrot runs from its card |
| 5 | projects: lazy tree, project search, jump list MRU | open `ide/`, click through, search across it; recent projects on the taskbar |
| 6 | Python & Toolchain views: venvs, four env values, version switcher, lookup | a compiled Mojo program imports a marker module from the project venv |
| 7 | (optional) D3D11 glyph atlas | built only if PresentMon says D2D drops frames |

Rough effort, calibrated against theirs: 0 is a week, 1 is the long pole at
two to three, 2 and 3 a week or two each, 4 a week. A dogfoodable editor in
roughly two months, with the latency claim tested at milestone 1 — which is
the point of the ordering.

## Risks, named

- **TSF is where native Windows editors quietly fail.** Scheduled first
  among the hard things; unit checks on the store's lock/GetText/SetText
  contract; composition through a real IME as the manual acceptance —
  documented as manual because IME grants and layouts cannot be scripted
  honestly.
- **Grid vs. glyph truth:** any place column math bypasses DirectWrite on a
  non-ASCII line is a caret bug. The rule is the defense; review for it.
- **Wide COM methods** (TSF's nine-parameter calls) exercise the raw-slot
  escape hatch — the first consumer outside the spike suite. Expect it to
  teach something; budget for what it teaches.
- **The LSP server is unexercised on Windows.** It builds; nothing has
  spoken to it. Milestone 2 opens with the probe script, before any UI
  depends on the answers.
- **LSP memory per open document** — inherited; cap synced documents now,
  fix in our fork later.
- **Child processes:** Job Objects retire the zombie class, but launch
  failures on Windows *return* rather than raise — every spawn checks, and
  `ide/proc.mojo` owns the discipline in one place.
- **250k-file trees:** the sidebar lists children lazily via
  `FindFirstFileW` and never stats a directory it hasn't opened; project
  search shells to ripgrep when present.

---

*The compiler this rides on: COM suite 32/32, GPU asyncrt 7/7, stdlib
baseline recorded in `docs/STDLIB-TEST-BASELINE.md`, tagged
`com-c4-hardened`. The sprint breakdown lives in `IDE-SPRINTS.md`. An
unofficial fork; not affiliated with Modular.*
