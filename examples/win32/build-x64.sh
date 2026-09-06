#!/usr/bin/env bash
# Builds one of the Win32 examples on x86_64, against the freshly-built stdlib.
#
#     ./examples/win32/build-x64.sh gamepane-canvas [more mojo build args...]
#
# The sibling `build.sh` is the ARM64 port's script and its clang, sysroot and
# MSVC linker paths all say arm64; running it here fails at `--target-cpu
# generic`, which is not a thing an x86_64 backend accepts. Everything else
# about the two is the same, and the reasoning for each variable is written out
# there -- import path, compiler-rt, PATH order against Git Bash's link.exe,
# LIB against the hermetic sysroot, and the winkb database that anything using
# winkb_struct_size needs to elaborate at all.
#
# Two additions this one needs and the ARM one does not:
#
#   * -I "$repo", because the game pane lives in a `gamepane` package at the
#     repository root rather than in the stdlib.
#   * nvptxrt.if.lib, the import library for the NVIDIA device runtime. It is
#     a DLL now (see the note in nvptx/runtime), so the link line names the
#     import lib and the DLL has to be beside the exe at run time.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
example="${1:?usage: build-x64.sh <example-name> [mojo build args...]}"
shift || true

bin_real="$(cd "$repo" && readlink -f bazel-bin)"
output_base="$(cd "$bin_real/../../../../.." && pwd)"
external="$output_base/external"
clang_bin="$external/+http_archive+clang-windows-x86_64/bin"
sysroot="$external/+windows_sysroot_repository+sysroot-windows-x86_64"
winkb="$external/+http_archive+winkb/windows_api.db"
[[ -f "$winkb" ]] || winkb="$external/+new_local_repository+winkb/windows_api.db"

msvc_link="$(ls -d "/c/Program Files/Microsoft Visual Studio"/*/*/VC/Tools/MSVC/*/bin/Hostx64/x64 2>/dev/null | sort | tail -1 || true)"
if [[ -z "$msvc_link" ]]; then
  echo "no MSVC x64 linker found; install the VS Build Tools x64 component" >&2
  exit 1
fi

out="${OUT_DIR:-$repo/build}"
mkdir -p "$out"

export PATH="$msvc_link:$clang_bin:$PATH"
export LIB="$(cygpath -w "$sysroot/vc_lib");$(cygpath -w "$sysroot/sdk_lib_ucrt");$(cygpath -w "$sysroot/sdk_lib_um")"
export MODULAR_MOJO_MAX_IMPORT_PATH="$repo/bazel-bin/mojo/stdlib/std"
export MODULAR_MOJO_MAX_COMPILERRT_PATH="$repo/bazel-bin/KGEN/KGENCompilerRTShared.dll"
export MODULAR_MOJO_MAX_WINKB_PATH="$winkb"

# --no-optimization is NOT a convenience and NOT a debug default. The pane's
# input state lives in `named_global` slots, and `pop.global_alloc`'s
# name-based deduplication does not survive optimization on this target: an
# optimized build gives every call site its own private zero-filled slot, so
# the key table's address is stored into one and read back from another as
# NULL. The pane then reports every key as up, forever, with no diagnostic.
# `tools/build-ide.ps1` passes the same flag for the same reason. Set
# OPTIMIZE=1 to override -- the pane raises at startup rather than running
# blind, so you will know rather than wonder.
opt=()
[[ "${OPTIMIZE:-0}" == "1" ]] || opt=(--no-optimization)

extra=(-I "$repo")
[[ -d "$repo/bazel-bin/max/mojo/max" ]] && extra+=(-I "$repo/bazel-bin/max/mojo/max")
if [[ -f "$repo/bazel-bin/dragon/runtime/dragonrt.lib" ]]; then
  extra+=(-Xlinker "$(cygpath -w "$repo/bazel-bin/dragon/runtime/dragonrt.lib")")
fi
if [[ -f "$repo/bazel-bin/nvptx/runtime/nvptxrt.if.lib" ]]; then
  extra+=(-Xlinker "$(cygpath -w "$repo/bazel-bin/nvptx/runtime/nvptxrt.if.lib")")
fi

"$repo/bazel-bin/KGEN/tools/mojo/mojo.exe" build \
  "${opt[@]}" \
  "${extra[@]}" \
  -o "$out/$example.exe" \
  "$repo/examples/win32/$example/main.mojo" "$@"

# PE has no rpath: the loader finds these beside the exe or on PATH, or the
# process dies with 0xC0000135 before main.
cp -f "$repo/bazel-bin/KGEN/KGENCompilerRTShared.dll" "$out/"
cp -f "$repo"/bazel-bin/KGEN/tools/mojo/*Globals.dll "$out/"
[[ -f "$repo/bazel-bin/nvptx/runtime/nvptxrt.dll" ]] &&
  cp -f "$repo/bazel-bin/nvptx/runtime/nvptxrt.dll" "$out/"
echo "built $out/$example.exe"
