# Programmer's Guide

Read these in order the first time. Each chapter assumes the ones before it.

| | Chapter | What it covers |
|---:|:---|:---|
| 1 | [Getting started](01-getting-started.md) | Unpacking a release, installing it if you want to, and writing, building and running your first program in the IDE. |
| 2 | [Griddle](02-griddle.md) | The IDE: projects, editing, finding, navigating, building, debugging, Python, and driving it from a script. |
| 3 | [The dialect](03-the-dialect.md) | Where this fork's Mojo differs from what is written elsewhere, and why each difference exists. |
| 4 | [Calling Win32](04-calling-win32.md) | The metadata layer, `win32[]`, structs whose layouts are asserted against the SDK, and the wide-string boundary. |
| 5 | [COM](05-com.md) | `ComPtr`, `com_method_of`, ownership, apartments, and the release-order rule that keeps ole32 out of your crash dumps. |
| 6 | An application | *Not yet written.* A window, a message loop and a picture, built up from nothing. |
| 7 | Concurrency | *Not yet written.* Processes, pipes, and why the message loop must never block. |
| 8 | Griddle read as a program | *Not yet written.* The IDE's own source as the largest program in the dialect. |
| A | Building from source | *Not yet written.* Bazel, the disk cache, and the traps recorded in [docs/](../../docs/). |

## What is written, and what is not

Chapters 1 through 5 are written and are accurate against the current
build — chapter 2's tables come out of the running program, and chapters 4
and 5's programs compile against the current compiler. The
[std.windows reference](../reference/04-std-windows.md) sits beside them:
chapters 4 and 5 teach the floor, the reference documents the library
standing on it.

The rest are listed because the shape of the guide is a decision worth making
early, and because a reader deserves to know what is missing rather than
discovering it. Where a chapter is not written, the existing engineering notes
under [docs/](../../docs/) cover the same ground less kindly: they were
written to stop somebody losing an afternoon twice, and several of them will
be the raw material for these chapters.

Nothing here is a placeholder pretending to be a chapter.
