# Programmer's Guide

Read these in order the first time. Each chapter assumes the ones before it.

| | Chapter | What it covers |
|---:|:---|:---|
| 1 | [Getting started](01-getting-started.md) | Unpacking a release, installing it if you want to, and writing, building and running your first program in the IDE. |
| 2 | [Griddle](02-griddle.md) | The IDE: projects, editing, finding, navigating, building, debugging, Python, and driving it from a script. |
| 3 | The dialect | *Not yet written.* Where this fork's Mojo differs from what is written elsewhere, and why each difference exists. Until it is, [docs/DIALECT-NOTES.md](../../docs/DIALECT-NOTES.md) and [docs/mojo-traps.md](../../docs/mojo-traps.md) are the honest version. |
| 4 | Calling Win32 | *Not yet written.* The metadata layer, `win32[]`, structs whose layouts are asserted against the SDK, and the wide-string boundary. |
| 5 | COM | *Not yet written.* `ComPtr`, `com_method_of`, ownership, and what the `class` work is for. |
| 6 | An application | *Not yet written.* A window, a message loop and a picture, built up from nothing. |
| 7 | Concurrency | *Not yet written.* Processes, pipes, and why the message loop must never block. |
| 8 | Griddle read as a program | *Not yet written.* The IDE's own source as the largest program in the dialect. |
| A | Building from source | *Not yet written.* Bazel, the disk cache, and the traps recorded in [docs/](../../docs/). |

## What is written, and what is not

Chapters 1 and 2 are written and are accurate against the current build —
chapter 2's tables come out of the running program.

The rest are listed because the shape of the guide is a decision worth making
early, and because a reader deserves to know what is missing rather than
discovering it. Where a chapter is not written, the existing engineering notes
under [docs/](../../docs/) cover the same ground less kindly: they were
written to stop somebody losing an afternoon twice, and several of them will
be the raw material for these chapters.

Nothing here is a placeholder pretending to be a chapter.
