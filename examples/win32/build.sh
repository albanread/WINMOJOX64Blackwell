#!/usr/bin/env bash
# Builds one of the Win32 examples against the freshly-built stdlib.
#
#     ./examples/win32/build.sh winstr_smoke [more mojo build args...]
#
# Three things have to be told to `mojo build` on this machine, and each is a
# Windows-specific trap worth naming:
#
#   * MODULAR_MOJO_MAX_IMPORT_PATH -- use the stdlib we just built, not an
#     installed one. There isn't an installed one; this is the port.
#
#   * MODULAR_MOJO_MAX_COMPILERRT_PATH -- points at the .dll; mojo-build
#     substitutes the .lib sibling for the link line (see PORT-JOURNAL).
#
#   * PATH -- Git Bash ships its own coreutils `link.exe` in /usr/bin, which
#     wins findProgramByName("link.exe") and then rejects MSVC's `/X` style
#     flags with "link: unknown option -- X". The MSVC linker has to come
#     first. Same story for clang.
#
#   * LIB -- the linker resolves msvcrt/ucrt/kernel32 through the LIB
#     environment variable, and Bazel's hermetic sysroot is not on it. We
#     point at the same sysroot the toolchain uses rather than whatever a
#     Developer Command Prompt would have set, so an example links against
#     exactly what the compiler was built against.
#
# --target-cpu generic is also deliberate: the default neoverse-n1 scheduling
# model is incomplete for some of the load/store pair instructions the backend
# emits here, and an assertions-enabled LLVM aborts on it (TargetSchedule.cpp
# "incomplete machine model"). Snapdragon X is Oryon, not an N1, so the proxy
# was never right anyway.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
example="${1:?usage: build.sh <example-name> [mojo build args...]}"
shift || true

# bazel-bin is a junction into the output base; walking up from its real path
# finds the repositories without hardcoding a user name.
#
# Two `external` directories exist and they are not interchangeable. The one
# under execroot is a symlink FOREST containing only what the most recent
# build needed -- winkb vanishes from it the moment a build does not use it.
# The one directly under the output base is the real store. Prefer that.
bin_real="$(cd "$repo" && readlink -f bazel-bin)"
output_base="$(cd "$bin_real/../../../../.." && pwd)"
external="$output_base/external"
clang_bin="$external/+http_archive+clang-windows-arm64/bin"
sysroot="$external/+windows_sysroot_repository+sysroot-windows-arm64"
winkb="$external/+new_local_repository+winkb/windows_api.db"

msvc_link="$(ls -d "/c/Program Files/Microsoft Visual Studio"/*/*/VC/Tools/MSVC/*/bin/Hostarm64/arm64 2>/dev/null | sort | tail -1 || true)"
if [[ -z "$msvc_link" ]]; then
  echo "no MSVC ARM64 linker found; install the VS Build Tools ARM64 component" >&2
  exit 1
fi

out="${OUT_DIR:-$repo/bazel-bin/examples/win32}"
mkdir -p "$out"

export PATH="$msvc_link:$clang_bin:$PATH"
export LIB="$(cygpath -w "$sysroot/vc_lib");$(cygpath -w "$sysroot/sdk_lib_ucrt");$(cygpath -w "$sysroot/sdk_lib_um")"
export MODULAR_MOJO_MAX_IMPORT_PATH="$repo/bazel-bin/mojo/stdlib/std"
export MODULAR_MOJO_MAX_COMPILERRT_PATH="$repo/bazel-bin/KGEN/KGENCompilerRTShared.dll"
# The Windows knowledge base. Under Bazel this arrives as a toolchain input;
# a standalone build has to be told where it is, and anything using
# winkb_struct_size or winkb_field_offset fails to elaborate without it.
export MODULAR_MOJO_MAX_WINKB_PATH="$winkb"

# -I for anything beyond std. MODULAR_MOJO_MAX_IMPORT_PATH names one place;
# the `max` package (GPU work) is a separate build output, so it comes in on
# the command line. Built by `bazelw build //max/mojo/max:max`.
extra=()
[[ -d "$repo/bazel-bin/max/mojo/max" ]] && extra=(-I "$repo/bazel-bin/max/mojo/max")

# The device runtime, when it has been built (`bazelw build
# //dragon/runtime:dragonrt`). Bazel-driven builds get it through the wheel
# remap in bazel/api.bzl; a standalone build has to name the .lib itself or
# every AsyncRT_* symbol is unresolved. A static lib contributes nothing to
# binaries that reference none of it, so adding it unconditionally is safe.
if [[ -f "$repo/bazel-bin/dragon/runtime/dragonrt.lib" ]]; then
  extra+=(-Xlinker "$(cygpath -w "$repo/bazel-bin/dragon/runtime/dragonrt.lib")")
fi

"$repo/bazel-bin/KGEN/tools/mojo/mojo.exe" build \
  --target-cpu generic \
  "${extra[@]}" \
  -o "$out/$example.exe" \
  "$repo/examples/win32/$example.mojo" "$@"

# The built exe imports KGENCompilerRTShared.dll, which in turn imports
# AsyncRTRuntimeGlobals.dll and MSupportGlobals.dll. PE has no rpath, so the
# loader finds these beside the exe or on PATH, or not at all -- and when it
# does not, the process dies with a silent 0xC0000135 before main. Copying the
# set beside the exe is what makes an example runnable by double-clicking it.
cp -f "$repo/bazel-bin/KGEN/KGENCompilerRTShared.dll" "$out/"
cp -f "$repo"/bazel-bin/KGEN/tools/mojo/*Globals.dll "$out/"
echo "built $out/$example.exe"
