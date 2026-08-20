#!/usr/bin/env bash
# JIT-runs a Win32 example straight from source -- no linker, no .exe.
#
#     ./examples/win32/run.sh adreno_mandelbrot        # GPU examples
#     ./examples/win32/run.sh windows_tour             # plain ones too
#
# Same environment as build.sh, but the program goes through `mojo run`:
# the ARM64 COFF objects are linked in-process by RuntimeDyld and the
# device runtime arrives as a DLL through -Xlinker, which is `mojo run`'s
# spelling for "load this into the JIT session".
#
# --target-accelerator is applied automatically when the source mentions
# the GPU, since passing it for a CPU-only program costs a warning and
# omitting it for a GPU one costs the kernel.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
example="${1:?usage: run.sh <example-name> [args...]}"
shift || true

bin_real="$(cd "$repo" && readlink -f bazel-bin)"
output_base="$(cd "$bin_real/../../../../.." && pwd)"
external="$output_base/external"

export MODULAR_MOJO_MAX_IMPORT_PATH="$repo/bazel-bin/mojo/stdlib/std"
export MODULAR_MOJO_MAX_COMPILERRT_PATH="$repo/bazel-bin/KGEN/KGENCompilerRTShared.dll"
export MODULAR_MOJO_MAX_WINKB_PATH="$external/+new_local_repository+winkb/windows_api.db"

extra=()
[[ -d "$repo/bazel-bin/max/mojo/max" ]] && extra+=(-I "$repo/bazel-bin/max/mojo/max")
if grep -q "target-accelerator\|max.gpu" "$repo/examples/win32/$example.mojo"; then
  extra+=(--target-accelerator adreno-x1)
  if [[ -f "$repo/bazel-bin/dragon/runtime/dragonrt.dll" ]]; then
    extra+=(-Xlinker "$(cygpath -w "$repo/bazel-bin/dragon/runtime/dragonrt.dll")")
  else
    echo "note: dragonrt.dll not built; run ./bazelw build //dragon/runtime:dragonrt.dll" >&2
  fi
fi

exec "$repo/bazel-bin/KGEN/tools/mojo/mojo.exe" run \
  --target-cpu generic \
  "${extra[@]}" \
  "$repo/examples/win32/$example.mojo" "$@"
