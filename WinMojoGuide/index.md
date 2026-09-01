# WinMojo

**Writing native Windows applications in Mojo, on a compiler that reads the
Windows API.**

WinMojo is an unofficial fork of Mojo for Windows on x64 with NVIDIA GPUs. It
is three things at once: a compiler and standard library that run natively on
Windows, a metadata layer — `std.sys._winkb` — that answers questions about
Win32 and COM *while your program is being compiled*, and **Griddle**, a
Windows IDE for Mojo, written in Mojo.

The point of the metadata layer is that a Windows binding states a name and
the compiler supplies everything else. A misspelled entry point is a compile
error. A struct that has drifted from the SDK fails to build. A COM method
called at the wrong vtable slot is a compile error rather than a jump into
whatever happened to be there.

```mojo
comptime assert size_of[WNDCLASSEXW]() == winkb_struct_size["WNDCLASSEXW"]()

var CreateWindowExW = win32[
    def (UInt32, Pointer[UInt16, MutAnyOrigin], ...) thin abi("C") -> Int,
    "CreateWindowExW",
]()
```

Nothing above names a DLL. `winkb_function_dll["CreateWindowExW"]` does, from
the database, and if the name is wrong the program does not build.

## Getting it

Download the release zip and unpack it anywhere — a folder in your profile, a
second drive, a memory stick. The first command you run repoints the
installation at wherever it landed, so there is nothing to configure and no
installer to trust.

    winmojo-<revision>.zip

Inside are the compiler, the standard library, the language server, the
debugger, the examples, and Griddle. `griddle.cmd` starts the IDE;
`mojo.cmd` is the compiler with its environment already set.

To put it somewhere permanent and keep several versions side by side, run
`install.ps1` from the unpacked folder. It copies into
`%LOCALAPPDATA%\WinMojo\<revision>`, points a `current` junction at it, and
adds a Start-menu shortcut. It needs no elevation, writes nothing to the
registry, and uninstalling is deleting a directory.

[Chapter 1](guide/01-getting-started.md) takes it from there. Building the
fork from source is [Appendix A](guide/09-building-from-source.md), and you
do not need it to write anything.

## These documents

| Document | What it is |
|:---|:---|
| [Programmer's Guide](guide/) | Read this first. Installing the toolchain, the IDE, the dialect this fork froze, calling Win32, using COM, and a walked-through application. |
| [Reference](reference/) | Look things up here. Every `winkb` query, the metadata database, Griddle's command surface, and every keyboard shortcut. |
| [GPU programming](gpu/) | Mojo functions that run on the NVIDIA card: the execution model, memory, and how to build, run and check them. |
| [The examples](examples/) | What each shipped example teaches, what it demonstrates about Windows, and which ones will not run on your machine and why. |

## What this fork is not

It is a fork, frozen at one commit of Mojo, and it does not accept
contributions. Changes meant for Mojo or MAX themselves belong upstream at
[modular/modular](https://github.com/modular/modular). Nothing here is
supported by Modular, and nothing here should be read as their work.

Two consequences worth stating early:

**The dialect is frozen.** Mojo has been changing quickly, and most writing
about it — including some of Modular's own, and most of what a language model
will tell you — describes a version this fork is not. Where this guide and
another source disagree about syntax, this guide is describing the compiler
in your hands. [The dialect chapter](guide/03-the-dialect.md) lists every
difference that has bitten somebody.

**The platform support is one machine's worth.** It is developed on Windows 11
x64 against an NVIDIA T1000 — Turing, `sm_75`. Anything that depends on a
newer architecture is untested here and is said so where it comes up.

## A note on honesty in this guide

Where something does not work, this guide says so, in the place you would look
for it rather than in a footnote. Where a number appears, it was measured on
the machine described above rather than estimated. Where an example ships that
cannot run on your hardware, its own page says which hardware it needs.

That is not modesty. A guide that overstates what a tool does costs its reader
an afternoon each time, and this tool has enough real edges to be going on
with.
