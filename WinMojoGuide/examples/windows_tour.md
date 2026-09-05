# windows_tour — everything in std.windows, against the real machine

A console program with no window: about forty labelled lines, each showing
what *this machine* answered to one facility of `std.windows` — system
facts, timing, known folders, paths, a directory listing, the registry,
console setup, time, processes, files, the clipboard. The README says what
it is better than a demo could: **this is the acceptance test for the
package**, run against real hardware rather than asserted.

## Run it

```
./examples/win32/build.sh windows_tour
./bazel-bin/examples/win32/windows_tour.exe
```

or `mojo run main.mojo` from the folder. Nothing is destructive: the
registry section writes to `HKCU\Software\MojoWindowsTour` and deletes it
again.

## What to read in it

- **Console setup comes first** (`use_utf8_console`, `enable_virtual_terminal`,
  main.mojo:96) — without those two calls the console mangles non-ASCII and
  prints escape codes literally, and every later line looks broken when the
  program is right.
- **The registry round-trip** (main.mojo:207) creates a key, writes a
  `REG_SZ`, an integer and a `REG_EXPAND_SZ`, reads them back, then deletes
  everything — each call through metadata-resolved entry points.
- **Known folders** (main.mojo:137) exercises every `KnownFolder` id and
  prints the path — the README's comment is the lesson: *a transcribed GUID
  that is wrong resolves to nothing*, which is why the ids come from the
  metadata.
- **Machine facts** read `ProcessorNameString` from HKLM (main.mojo:180),
  with the note that `ProductName` still says "Windows 10" on Windows 11 —
  the build number printed above it is the one to believe.
- **Binary exactness** (main.mojo:264) round-trips all 256 byte values
  through a file and the clipboard, because a string facility that survives
  "café" can still corrupt byte 0x0D.

## What it teaches

That the whole Windows surface of the standard library — registry, folders,
clipboard, processes, files — works from one console program with no
hand-declared Win32 anywhere. When one of its lines fails after a change,
the tour names the facility before the test suite does.
