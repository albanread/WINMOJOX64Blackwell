# 2. Griddle

Griddle is the fork's IDE: a Mojo editor for Windows, written in Mojo, using
the same Win32 and COM metadata everything else in this guide describes. It
edits its own source.

This chapter is what it does. [The reference](../reference/03-griddle.md) is
the complete list of commands and shortcuts; this is the shape.

## The window

```
┌──────────────────────────────────────────────────────────────┐
│ File  Edit  Go  View  Build  Python  Examples  Help          │
├──────────┬───────────────────────────────────────────────────┤
│          │  main.mojo  ×  README.md                          │ tabs
│ project  ├───────────────────────────────────────────────────┤
│ tree     │                                                   │
│          │  the editor                                       │
│          │                                                   │
│          ├─────────────────────────┬─────────────────────────┤
│          │ problems / references / │ OUTPUT                  │
│          │ outline / variables /   │ builds, runs, scripts   │
│          │ toolchain / python      │                         │
├──────────┴─────────────────────────┴─────────────────────────┤
│ Ln 1, Col 1   UTF-8                                          │ status
└──────────────────────────────────────────────────────────────┘
```

The **bottom-left pane shows one list at a time**, and the View menu chooses
which. This is the one piece of the layout worth learning deliberately,
because a pane that changes what it holds is a pane you can lose track of:

| View menu | shows |
|:---|:---|
| Problems | what the language server thinks is wrong |
| Outline | the symbols in this file (Ctrl+Shift+O) |
| Toolchain | which compiler, debugger and GPU this installation is using |
| Python | the interpreter and environment this project builds against |

References and the debugger's variables take the same pane when they have
something to say. The status line at the bottom turns into a prompt when
something is being asked of you.

## Projects

**A project is a folder.** Open one — by opening a file in it, or by dropping
a folder on the window — and the sidebar is that folder, the language server
is rooted there, and a search searches it.

**Its entry point is `main.mojo`.** Build and Run compile the `main.mojo` in
the project root, whatever is on screen. Read a README, click into a helper,
press Ctrl+F5, and you build the project rather than the file you were
looking at. A loose file with no project around it builds itself.

Griddle remembers where you were. Closing it writes `.griddle-session.json`
in the project — the open files, the current one, the expanded folders — and
opening it again restores them. That file is one developer's window state
rather than a fact about the project, so it does not want to be in version
control.

## Editing

The ordinary things work and are not worth a table: typing, selection, undo
and redo, cut, copy, paste, select all. Two that are worth a sentence:

**The clipboard is the real Windows one.** Copy in Griddle and paste in
Notepad; copy in a browser and paste in Griddle. Line endings are converted
in both directions — CRLF outside, LF in the buffer — so pasted text does not
arrive with carriage returns in it.

**Copy with nothing selected takes the whole line**, newline included, and so
does Cut. That is what every editor you have used does, and it is what makes
Ctrl+X, move, Ctrl+V a way to move a line.

Auto-indent follows the line above, and a line that opens a block indents the
next one.

## Finding things

**Ctrl+F** asks. The status line becomes a prompt, offering whatever you
searched for last with the caret at the end of it — because somebody who found
four matches and pressed Ctrl+F again meant to search for something near it.

* **F3** / **Shift+F3** — the next and previous match; the search wraps
* **Ctrl+H** — replace what the last search found
* **Ctrl+Shift+F** — search the whole project; every hit is a place, and
  clicking one goes there
* **Ctrl+G** — go to a line

Search is fast enough not to think about: 104 MB scanned in about 47 ms on
the machine this was written on.

## Navigating

These come from the language server, so they need a `.mojo` file and a moment
for it to start:

| | |
|:---|:---|
| **F12** | go to the definition |
| **Alt+Left** | back — the jump stack, which is what makes following a definition into a definition survivable |
| **Shift+F12** | who uses this; the pane lists them and clicking one goes there |
| **Ctrl+I** | what is this — the type, or the live value if you are debugging |
| **Ctrl+Space** | what can go here |
| **Ctrl+Shift+O** | this file's symbols; click one |

## Building and running

| | |
|:---|:---|
| **Ctrl+B** | build |
| **Ctrl+F5** | run without debugging |
| **Shift+F5** | stop whatever is running |

Output goes to the bottom-right pane, both streams, and **every
`path:line:column` in it is clickable** — including into a file you have not
opened. That is the edit-build-fix loop closing: the compiler says where, and
the editor takes you.

Dirty buffers are saved before a build, because the compiler reads the disk
and not your screen.

## Debugging

Griddle drives LLDB through the Debug Adapter Protocol, the same protocol an
editor would use for any other debugger.

| | |
|:---|:---|
| **F9** | toggle a breakpoint on this line |
| **F5** | build with debug information and start |
| **F10** / **F11** / **Shift+F11** | step over, into, out |
| **Ctrl+F10** | run to the cursor |
| **Ctrl+I** | what is this variable worth, right now |
| **Shift+F5** | stop |

While stopped, the bottom-left pane shows the call stack and the locals.
Clicking a frame walks the stack: the caret goes to that frame's line and the
locals become that frame's locals. Execution has not moved — reading a stack
is reading, not stepping.

> **Conditional breakpoints do not work, and Griddle says so when you set
> one.** The condition is sent correctly and this toolchain's LLDB ignores it,
> stopping every time, because its Mojo expression evaluator cannot evaluate
> the condition and LLDB fails safe. See
> [docs/debugger-conditions.md](../../docs/debugger-conditions.md) for the
> measurements. A conditional breakpoint that silently behaved like an
> unconditional one would be worse than not offering them.

## Python

Mojo can call Python, and a Mojo program that does loads CPython into itself.
That means a project's Python environment has to be settled before the program
starts, which is what this menu is for.

| Python menu | |
|:---|:---|
| Create or Repair Environment | makes a virtual environment for this project, or refreshes one |
| Install Project Dependencies | `requirements.txt`, or a `pyproject.toml` |
| Install Package… | asks for a name and installs it |
| Show Environment | the interpreter, the environment, and **the values Run will inject** |

Environments live outside the project, one per project, under
`%LOCALAPPDATA%\Griddle\Python\Environments`. The project directory is not
polluted and the environment survives a clean checkout.

The Show Environment view exists because when an import fails, those four
values are exactly what you need and no editor should keep them to itself.

One Windows-specific thing worth knowing: on this platform the compiler
runtime cannot discover CPython's library on its own, so Griddle names it.
The consequence is that **Python interop works inside the IDE and crashes
outside it** unless you set `MOJO_PYTHON_LIBRARY` yourself. `bifurcation` is
the example that shows the whole path.

## Examples

**Examples** lists what shipped, read from the installation rather than from a
list written in the source, so the menu cannot disagree with what is there.

Clicking one opens it as a project: the tree re-roots, every file in the
folder opens as a tab, and `main.mojo` ends up in front. Nothing is copied
first — you are editing the shipped copy, which is what every editor does with
a file it did not write.

## The toolchain view

**View → Toolchain** answers "which compiler am I actually using", with paths
it has checked rather than paths it expects:

```
toolchain 13
  root C:\WinMojo\current
  source beside the binary
  layout installed
  mojo Mojo 1.1.0.dev0 (deadbeef)
  lldb lldb version 24.0.0git
  gpu NVIDIA T1000 8GB, 7.5, 582.08, 8192 MiB
  ok compiler C:\WinMojo\current\bin\mojo.exe
  ...
```

A row marked `--` instead of `ok` is a component that is missing, which means
a build or a debug session that will fail with a confusing message later. It
also lists what it could not establish, rather than filling those in with
plausible guesses.

## Driving it without a keyboard

Every feature has a name, and the same names drive the editor from a script:

```
griddle.exe --open main.mojo --cmd "build;;build wait 60000;;output"
```

`help` lists all of them. `run-script <path>` replays a file of them, one per
line, `#` for a comment — so a session you drove by hand can be saved and
replayed, which is how this IDE is tested in CI. That is the same surface the
menus use, so a thing done from a menu and the same thing done from a script
are the same code and cannot disagree.

The [reference](../reference/03-griddle.md) has the complete list.
