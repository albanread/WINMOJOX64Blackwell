# Mojo Windows x64 + NVIDIA Blackwell release

This is a standalone build for this Windows x64 machine and its NVIDIA RTX PRO
2000 Blackwell Laptop GPU. Mojo GPU code is compiled to PTX for `sm_120a` and
loaded through the NVIDIA driver by `nvptxrt`; no CUDA toolkit or Bazel is used
at runtime.

## Commands

- `mojo.cmd --version` runs the compiler.
- `mojo.cmd run examples\hello.mojo` runs a Mojo source file through the JIT.
- `mojo.cmd build examples\hello.mojo -o hello.exe` builds a Windows x64 EXE.
- `mojo-gpu-run.cmd file.mojo` JIT-runs for this GPU with `sm_120a` selected.
- `mojo-gpu-build.cmd file.mojo -o file.exe` builds for this GPU.
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
