# 1. Getting started

Twenty minutes, from a downloaded zip to a program you wrote, built and ran
in the IDE.

## Unpack it

Unzip the release anywhere you like. There is no installer to run and nothing
to configure:

```
winmojo-<revision>.zip
```

Unpack it into `C:\WinMojo`, or your Documents folder, or a memory stick. The
paths inside a release are absolute — the compiler is handed its driver, its
linker and its import path by name — so every launcher checks, on the way
past, whether the copy has moved since it was packaged and rewrites them if
it has. That check costs a few milliseconds and it is why the zip is the whole
product.

You get:

| | |
|:---|:---|
| `griddle.cmd` | the IDE |
| `mojo.cmd` | the compiler, with its environment already set |
| `bin\`, `lib\` | the toolchain: compiler, language server, debugger, linker, runtime |
| `examples\win32\` | the example projects |
| `install.ps1` | put it somewhere permanent, if you want that |

Double-click `griddle.cmd` and the IDE opens. That is the shortest path, and
if it works you can skip to [the first program](#your-first-program).

## Installing it properly, if you want to

You do not have to. The zip works where it stands. But if you would rather
have it in a fixed place, with a Start-menu entry and room for more than one
version:

```powershell
.\install.ps1
```

It copies into `%LOCALAPPDATA%\WinMojo\<revision>`, points a junction called
`current` at that version, and makes a Start-menu shortcut. No elevation, no
registry, no service. Later:

```powershell
.\install.ps1 -List                     # what is installed, and which is current
.\install.ps1 -Root D:\WinMojo          # somewhere else
.\install.ps1 -Uninstall -Version abc1234
```

Installing a newer package makes it current; the older one stays where it is
until you remove it. Uninstalling is deleting a directory, and the script says
so rather than pretending to be more than a copy.

## One thing you may still need

`mojo run` works out of the box. **`mojo build` needs Microsoft's import
libraries** — `kernel32.lib`, `ucrt.lib` and the rest — which cannot be
redistributed with this fork. If you have Visual Studio or the Visual Studio
Build Tools with the *Desktop development with C++* workload, they are already
on your machine and the launchers find them; the toolchain looks for every
edition and every side-by-side version rather than assuming one.

If they are missing you will see this, once, on stderr:

```
warning: no Visual Studio x64 toolchain was found.
         "mojo run" will still work. "mojo build" will fail to link,
         because the MSVC and UCRT import libraries cannot be located.
```

The fix is to install the Build Tools and choose the x64 C++ workload. It is
free, and it is the same requirement any native compiler on Windows has.

## Your first program

Open Griddle. **File → New**, then type:

```mojo
def main():
    var total = 0
    for i in range(10):
        total += i * i
    print("sum of squares:", total)
```

**File → Save As…** and save it as `main.mojo` in a folder of its own — say
`Documents\squares\main.mojo`. The folder matters, and the name matters:

> **A project is a folder, and its entry point is `main.mojo`.**
>
> Griddle builds and runs the `main.mojo` in the project root, not whichever
> file happens to be on screen. That is what lets you read a README, click
> into a helper module, and still have Run mean the same thing. A single file
> opened on its own with no project around it builds itself, which is what
> makes the rule invisible until you want it.

Now press **Ctrl+F5** (Build → Run Without Debugging). The bottom-right pane
shows the command, then the output:

```
> "...\bin\mojo.exe" run -I "..." -I . "...\squares\main.mojo"
sum of squares: 285

[exit 0 after 1633 ms]
```

Ten seconds of that was the compiler starting up. Mojo compiles ahead of time
and the first run of a session pays for it.

## When it does not compile

Break it deliberately — change `total` to `totl` on the last line and press
Ctrl+F5 again:

```
...\squares\main.mojo:5:20: error: use of unknown declaration 'totl'
    print("sum of squares:", totl)
                             ^~~~
```

**Click the line.** The editor takes you to line 5, column 20. Every
`path:line:column` in the output pane is a place, and clicking a place goes
there — including into files you have not opened, which is the case that
matters when the error is three modules away.

## Getting help from the language server

Griddle starts `mojo-lsp-server` for a `.mojo` file and gets diagnostics,
completion, hover, go-to-definition, references and the outline from it.

* **Ctrl+Space** — what can go here
* **F12** — go to the definition; **Alt+Left** comes back
* **Shift+F12** — who uses this
* **Ctrl+I** — what is this
* **Ctrl+Shift+O** — the file's outline, in the bottom pane; click a symbol

The bottom-left pane is one pane showing several lists — problems, references,
the outline, variables while debugging, the toolchain, Python. The **View**
menu says which, and is where to look when you wonder where your problem list
went.

## Running an example

**Examples** lists what shipped. Each is a project: clicking one re-roots the
sidebar at its folder, opens its files as tabs, and puts `main.mojo` in front.
Its README is a tab too, which is the point of examples being folders.

`windows_tour` is a good first one — it prints what the real machine says
about itself, so a wrong struct offset or a mis-decoded string is visible
rather than merely absent.

Three of the examples (`adreno_index_probe`, `adreno_saxpy`,
`adreno_saxpy_debug`) are Qualcomm programs. They build here and stop at
runtime with `nvptxrt does not implement device API 'adreno'`. That is a fact
about the example rather than about your installation, and their READMEs say
so.

## Where to go next

| If you want to | Read |
|:---|:---|
| know the IDE properly | [Chapter 2](02-griddle.md) |
| know how this Mojo differs from what you have read elsewhere | [Chapter 3](03-the-dialect.md) |
| call a Windows API | [Chapter 4](04-calling-win32.md) |
| use a COM interface | [Chapter 5](05-com.md) |
| write a GPU kernel | [the GPU guide](../gpu/) |
| see what the examples teach | [the examples](../examples/) |
