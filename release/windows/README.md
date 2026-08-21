# Mojo Windows x64 + NVIDIA release

This is a standalone Windows x64 build. Mojo GPU code is compiled to PTX and
loaded through the NVIDIA driver by `nvptxrt`; no CUDA toolkit or Bazel is used
at runtime.

The GPU target is not fixed at packaging time. The launchers pass the generic
`cuda` selector, which resolves to whichever supported card is installed, so
the same release works on any of them. Pass `--target-accelerator` explicitly
to compile for a different card than the one present.

## Commands

- `mojo.cmd --version` runs the compiler.
- `mojo.cmd run examples\hello.mojo` runs a Mojo source file through the JIT.
- `mojo.cmd build examples\hello.mojo -o hello.exe` builds a Windows x64 EXE.
- `mojo-gpu-run.cmd file.mojo` JIT-runs for the installed GPU.
- `mojo-gpu-build.cmd file.mojo -o file.exe` builds for the installed GPU.
- `mojo.cmd repl` starts the LLDB-backed Mojo REPL.
- `mandelbrot.cmd` runs the prebuilt windowed NVIDIA Mandelbrot example.
- `mojo-shell.cmd` opens a command prompt with the release DLL and MSVC paths.

The launchers set `MODULAR_HOME`, package lookup, debugger paths, Crashpad,
Windows API metadata, runtime DLL lookup, and the installed Visual Studio x64
library environment. Executables built against the shared Mojo runtime should
be run from `mojo-shell.cmd`, or with this release's `lib` directory on `PATH`.

The release contains the Mojo compiler, `std` and `max` packages, LLDB and the
Mojo debugger plugin, Crashpad, `lld`, the Windows API database, and the
open-source NVIDIA PTX driver runtime. The proprietary NVIDIA display driver is
still required to execute PTX on the GPU; no proprietary CUDA compiler or CUDA
runtime is bundled.
