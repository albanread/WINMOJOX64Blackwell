#!/bin/bash
# Reproduce exactly what the windows-arm64 cc_toolchain would run, using the
# real flag set from args/BUILD.bazel plus the sysroot paths that
# windows_sysroot_repository generated. Not a vanilla clang smoke test.

CLANG="C:/users/alban/_bazel_alban/rme75s5o/external/+http_archive+clang-windows-arm64/bin/clang++.exe"
VC="C:/Program Files/Microsoft Visual Studio/18/Professional/VC/Tools/MSVC/14.51.36231"
SDK="C:/Program Files (x86)/Windows Kits/10"
SDKV="10.0.26100.0"

SRC="$1"
OUT="$2"

INCLUDES=(
  -isystem "$VC/include"
  -isystem "$SDK/Include/$SDKV/ucrt"
  -isystem "$SDK/Include/$SDKV/shared"
  -isystem "$SDK/Include/$SDKV/um"
  -isystem "$SDK/Include/$SDKV/winrt"
)

LIBS=(
  -L"$VC/lib/arm64"
  -L"$SDK/Lib/$SDKV/ucrt/arm64"
  -L"$SDK/Lib/$SDKV/um/arm64"
)

# compile_and_link_args + cpp_compile_args
BASE=(
  -no-canonical-prefixes
  --target=aarch64-pc-windows-msvc
  -std=c++20
)

# compile_args, minus the two we exclude on Windows (-fPIC, -fno-autolink)
COMPILE=(
  -fcolor-diagnostics
  -ffile-compilation-dir=.
  -fno-exceptions
  -fno-omit-frame-pointer
  -fno-rtti
  -fstack-protector
  -funwind-tables
  -fvisibility-inlines-hidden
  -fvisibility=hidden
  -DGOOGLE_PROTOBUF_NO_RTTI=1
  -DLLVM_BUILD_STATIC
  -U_FORTIFY_SOURCE
  -DMLIR_USE_FALLBACK_TYPE_IDS=1
)

WARNINGS=(
  -Wall -Wextra -pedantic
  -Wcast-qual -Wcovered-switch-default -Wctad-maybe-unsupported
  -Wdelete-non-virtual-dtor -Wimplicit-fallthrough -Wmisleading-indentation
  -Wmissing-field-initializers -Wnon-virtual-dtor -Wself-assign
  -Wstring-conversion -Wsuggest-override -Wthread-safety -Wwrite-strings -Wundef
  -Wno-unused-parameter
  -Werror=unused-command-line-argument
  -Werror=return-type-c-linkage
  -Werror=global-constructors
)

LINK=(-fuse-ld=lld)

echo "### 1. compile+link with the FULL toolchain flag set"
"$CLANG" "${BASE[@]}" "${COMPILE[@]}" "${WARNINGS[@]}" "${INCLUDES[@]}" \
         "${LINK[@]}" "${LIBS[@]}" "$SRC" -o "$OUT" 2>&1 | head -40
echo "EXIT=${PIPESTATUS[0]}"
