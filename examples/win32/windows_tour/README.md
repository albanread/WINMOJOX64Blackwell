# windows_tour

===----------------------------------------------------------------------=== #
Everything in std.windows, run against the real machine.

./examples/win32/build.sh windows_tour
./bazel-bin/examples/win32/windows_tour.exe

This is the acceptance test for the package, not a demo: each section prints
what the machine actually said, so a wrong struct offset or a mis-decoded
string is visible rather than merely absent. The registry section writes to
HKCU\Software\MojoWindowsTour and deletes it again; nothing else is
destructive.
===----------------------------------------------------------------------=== #

Run it from the IDE with Build > Run Without Debugging, or from a
terminal:

```
mojo run main.mojo
```
