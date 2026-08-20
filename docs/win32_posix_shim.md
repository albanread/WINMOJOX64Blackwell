# The Win32 POSIX shim

The Mojo standard library reaches libc by name. Every `external_call["read"]`,
`external_call["symlink"]`, `external_call["posix_spawnp"]` is a C symbol that
has to exist at link time, or any program touching `os`, `subprocess` or
`io.file_descriptor` fails to link — not at the call, but for the whole binary.

Windows supplies some of those names, some under different names, and some not
at all. This file records which is which, what the shim does about the third
category, and — the part worth reading — where Windows cannot keep a POSIX
promise and the emulation is therefore approximate.

Implementation: [`KGEN/lib/CompilerRT/PosixWin32.cpp`](../KGEN/lib/CompilerRT/PosixWin32.cpp).
It lives in `CompilerRT` because that library is already linked into every Mojo
executable, so the symbols are present wherever the standard library needs them.

## Why not use an existing library

GNU's Windows ports — Cygwin, MSYS2, the glibc-derived layers — are GPL. This
tree is Apache 2.0 with LLVM exceptions and intends to stay that way, so they
are unusable regardless of technical merit.

Permissively-licensed options exist; [libunistd](https://github.com/robinrowe/libunistd)
(MIT) is the closest fit. It was not adopted because measuring the gap first
made it small. The MSVC CRT already provides most of what the standard library
asks for, and what remained was six functions plus process spawning — less code
than the dependency and its licence notice would have cost, and with no third
party in the provenance record that the licensing article depends on.

## Three categories

**Already present, under the same name.** `close`, `read`, `write`, `dup`,
`stat`, `fstat`, `chdir`, `mkdir`, `rmdir`, `getcwd`, `unlink`, `lseek`,
`isatty`, `fdopen`, `open` and about ninety more. `oldnames.lib` aliases the
legacy POSIX spellings to the CRT's underscore-prefixed ones. This library is
not linked by default when the linker is invoked directly — `cl.exe` requests
it through a `/DEFAULTLIB` directive in its own objects, and Mojo emits its own
objects — so `mojo build` asks for it explicitly.

**Present under a different name or shape.** `popen`, `pclose` and `pipe`.
The first two are pure forwarding to `_popen`/`_pclose`. `pipe` cannot be
aliased at all: the CRT's `_pipe` takes two extra arguments, and it needs
`_O_BINARY` passed explicitly or text mode translates CRLF inside the pipe and
corrupts any binary payload.

**Absent entirely.** `symlink`, `link`, `realpath`, `fchdir`, `fcntl`,
`getline`, `posix_spawnp`, `waitpid`, `kill`. These are implemented against
Win32.

## What each one maps to

| POSIX | Win32 | Notes |
| --- | --- | --- |
| `symlink` | `CreateSymbolicLinkW` | argument order inverts |
| `link` | `CreateHardLinkW` | argument order inverts |
| `realpath` | `CreateFileW` + `GetFinalPathNameByHandleW` | resolves by opening |
| `fchdir` | `GetFinalPathNameByHandleW` + `SetCurrentDirectoryW` | not atomic |
| `fcntl` | `GetHandleInformation` / `SetHandleInformation` | `F_GETFD`/`F_SETFD` only |
| `getline` | `getc` loop | plain C |
| `posix_spawnp` | `SearchPathW` + `CreateProcessW` | see below |
| `waitpid` | `WaitForSingleObject` + `GetExitCodeProcess` | via handle table |
| `kill` | `TerminateProcess` | no signal semantics |
| `pipe` | `_pipe` | needs `_O_BINARY` |
| `popen`/`pclose` | `_popen`/`_pclose` | forwarding only |

## Where the emulation is approximate

These are the parts to read before trusting the shim in a new situation. None
of them is a bug to be fixed later; each is a place where Windows has no
equivalent of the POSIX guarantee.

**Argument order inverts on both link calls.** POSIX names the target first,
`CreateSymbolicLinkW` and `CreateHardLinkW` name the new link first. Swapping
them produces a plausible-looking link pointing the wrong way, and a test that
only checks a link exists will not notice. The stdlib's own `test_link.mojo`
does catch it — it reads *through* the link and asserts the content, then
asserts `st_ino` matches and `st_nlink == 2`.

**A dangling symlink becomes a file symlink.** Windows fixes whether a symlink
is a file or directory link at creation time, so the target must be probed.
POSIX permits a symlink to a target that does not exist yet; here that is
created as a file link, which differs if the target later appears as a
directory.

**Symlink creation needs Developer Mode.** `CreateSymbolicLinkW` is passed
`SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE`, which only works if Developer
Mode is on. Without it, `symlink` fails with `EPERM`. This is the same machine
setting the Bazel runfiles strategy depends on — see the journal.

**`fchdir` is not atomic.** Windows has no directory-handle form of
`SetCurrentDirectory`, so the handle is resolved back to a path and that path
is entered. If the directory is renamed in between, we follow the name rather
than the handle.

**`fcntl` implements two commands.** `F_GETFD` and `F_SETFD` carrying
`FD_CLOEXEC` are the entire surface the standard library uses. Windows models
the same idea inverted — a handle is inheritable or not, and close-on-exec is
the absence of inheritance — so the flag is negated in both directions.
Anything else returns `EINVAL` rather than succeeding, because a silent no-op
here would surface much later as a descriptor leak.

**`realpath` requires the path to exist.** It resolves by opening the file and
asking Windows what it opened, which follows symlinks and normalises case and
8.3 names as POSIX expects — and, like POSIX, fails with `ENOENT` on a missing
component rather than returning a syntactically-cleaned string.

**`kill` is not signalling.** There is no signal delivery on Windows, so every
signal except `0` terminates the process, with no distinction between `TERM`
and `KILL` and no opportunity for the child to handle it. Signal `0` remains
the existence probe.

**A killed process is reported as exited.** `waitpid` encodes the exit code in
musl's layout, and a process terminated by `kill` above is reported as having
*exited* with that code rather than as signalled. This is deliberate:
`Process.wait()` raises outright on a status that has not exited, so reporting
a signal would turn a successful kill into an exception.

**`posix_spawnp` rejects file actions.** The standard library always passes
null for `file_actions` and `attrp`. If either ever becomes non-null the shim
returns `ENOSYS` rather than ignoring it, since ignoring a file action would
silently discard a redirection.

**Environment inheritance is a null, not a copy.** Windows keeps two
environments — the CRT's `_environ` array and the Win32 block that
`CreateProcessW` copies into a child — and they can disagree. `_get_environ()`
returns null on Windows, which means "inherit" to `CreateProcessW` and lets the
real block pass through untouched. That is exactly what its only caller asks
for, so the null is the accurate answer rather than a stub.

## Two details that are easy to get wrong

**Command-line quoting.** Windows has no argv; the child re-parses a single
string. The shim quotes by the inverse of the documented MSVCRT rule, in which
a backslash escapes only when it precedes a quote — so a run of backslashes
must be doubled in that position and left alone everywhere else. The naive
wrap-the-whole-thing-in-quotes corrupts any argument ending in a path
separator, which on Windows is common.

**pid reuse.** A Windows pid is reused once the process is gone, so waiting on
one by reopening it races. The handle `CreateProcessW` returns is kept in a
table keyed by the pid the shim reports, and `waitpid`/`kill` look it up rather
than reopening. The entry is dropped when the process is reaped.

## Allocation, and why it is safe

`realpath` and `getline` return `malloc`'d buffers for the caller to free.
That is only sound because every module in this build shares one CRT heap,
which is what `-fms-runtime-lib=dll` buys and why the dynamic CRT is
non-negotiable in this port. Under a static CRT these allocations would be
freed against a different heap — the same class of bug that made the
process-teardown corruption so hard to find. Both sites carry that note.

## What this is not

This is a compatibility shim, sized to the call sites the standard library
actually has. It is not a general POSIX layer and should not grow into one: a
native `win32` package is the intended home for Windows-shaped APIs, and
anything that wants real Windows semantics belongs there rather than behind a
POSIX name that promises something Windows cannot deliver.

`fork` is not implemented and should not be. It has no Win32 equivalent worth
the name, and nothing in the standard library needs it — `Process` is built on
`posix_spawnp`, which maps onto `CreateProcessW` cleanly.
