# The Mojo language server on Windows

Sprint 2.1. The server had never been built or run on Windows. This sprint
does both, with `tools/lsp-probe.py` and nothing else — deliberately away from
the editor, so that when something is wrong there is only one thing it can be.

```bash
./bazelw.cmd build //KGEN/tools/mojo-lsp-server
python tools/lsp-probe.py            # or --verbose for every byte both ways
```

## Getting it to build: three fixes

**`unistd.h`.** `mojo-lsp-server.cpp` included it for one call, `isatty(STDOUT_FILENO)`,
used to print a "this is not meant to be run directly" warning. LLVM's
portable equivalent is `llvm::sys::Process::StandardOutIsDisplayed()`, and
`llvm/Support/Process.h` was already included in the same file.

**`uniform_int_distribution<unsigned char>`.** `[rand.req.genl]/1.5` lists the
types that template accepts and character types are not among them. libstdc++
allows it anyway; the MSVC standard library enforces the rule with a
`static_assert`. Widened to `unsigned` with a cast on the way out.

**`IdnToAscii` / `IdnToUnicode` undefined at link.** curl is built here with
`USE_WIN32_IDN` and resolves them from `Normaliz.lib`. Every other tool in the
tree already names `-lnormaliz -lws2_32` in its linkopts, with a comment
saying why; the language server target simply never got them.

None of the three is deep. All three are the kind of thing that only appears
the first time something is built on a platform.

## What works

- **The handshake.** `initialize` answers in ~25 ms with twelve capabilities:
  code actions, completion, definition, hover, inlay hints, references,
  rename, semantic tokens, signature help, and notebook sync.
- **Diagnostics.** `didOpen` on a file with an undefined name produces
  `use of unknown declaration '...'` on the right line, with a range covering
  the whole call. A cold parse of a small file takes about 810 ms.
- **Completion by identifier prefix.** Asking at `tar` in a file that uses
  `Com[StaticString("IDropTarget")]` returns the names in scope, including the
  COM-typed variable. So the server parses this repository's own idiom.
- **Shutdown.** Clean.

## What does not, and what that means for later sprints

**A completion sent while the server is reparsing is rejected.** It comes back
`-32801 ContentModified`, `"outdated request"`. This is easy to mistake for a
server that cannot complete at all — it was, here, for three attempts. The
server publishes diagnostics when a parse finishes, so that is the signal to
wait for.

*For sprint 2.2*, which wires `didChange` to every keystroke: a completion
request must either wait for the diagnostics of its own document version or be
retried when it is refused. Firing one per keystroke and taking the first
answer will drop most of them.

**Member completion after `.` returns nothing.** Not because the document is
mid-edit: a fully valid file with the cursor inside `p.x` returns nothing, and
so does `self.` in a file that compiles. `.` is the trigger character the
server itself advertises. Identifier-prefix completion works in the same
files, so this is specific to member access.

*For sprint 2.4*, whose differentiator is completion inside a `Com[...]` chain
offering the interface's methods: that will not come from this server as it
stands. 2.4 already anticipates "server-side extension in our fork if the
protocol needs help; we own both ends" — this is that, and it is a larger
piece of work than the sprint's size suggests.

## One thing that is not about the server at all

The probe's first sample used `Com[StaticString("IDropTargt")]` — a misspelled
interface — expecting a diagnostic. There is none, and the server was right:
**the compiler accepts that file too.** `Com`'s interface name is checked when
a method is dispatched through it, not when the type is written, so a typo in
an interface name survives until something is called on it.

That is worth knowing on its own. It is the one hole in an otherwise
metadata-checked COM surface, and it is the reverse of the usual complaint:
here the type is more permissive than the call.
