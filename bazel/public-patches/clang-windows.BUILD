load("@bazel_skylib//rules/directory:directory.bzl", "directory")

package(default_visibility = ["//visibility:public"])

# Windows counterpart of clang.BUILD. Three things differ in the upstream LLVM
# Windows distribution and each one breaks the shared file:
#   1. compiler-rt libraries are named clang_rt.* with no "lib" prefix, and live
#      under lib/clang/22/lib/windows rather than a target-triple directory.
#   2. there is no lib/clang/22/share, so the sanitizer ignore lists referenced
#      by the shared :include filegroup do not exist.
#   3. every executable carries a .exe suffix.
# Keeping this separate rather than relaxing the globs in clang.BUILD means a
# genuinely missing file on Linux or macOS still fails loudly instead of
# silently globbing to nothing.

exports_files(
    glob([
        "lib/clang/*/lib/*/clang_rt.*",
        "bin/*",
    ]),
)

filegroup(
    name = "clang",
    srcs = glob(["bin/clang*"]),
)

# Matches lld-link.exe, which is the linker the clang driver spawns for a
# *-pc-windows-msvc target.
filegroup(
    name = "ld",
    srcs = glob(["bin/*ld*"]),
)

filegroup(
    name = "include",
    srcs = ["lib/clang/22/include"],
)

directory(
    name = "include_dir",
    srcs = [":include"],
)

filegroup(
    name = "resource_directory_filegroup",
    srcs = ["lib/clang/22"],
)

directory(
    name = "resource_directory",
    srcs = [":resource_directory_filegroup"],
)

# compiler-rt's builtins, as a search path.
#
# LLVM emits calls to these for arithmetic no instruction implements: __divti3
# and __modti3 are 128-bit signed division and modulo, which the standard
# library reaches through Int128/UInt128. The clang driver adds this library to
# its own link jobs, but `mojo build` drives the linker directly and inherits
# only what the toolchain states, so the directory has to be a real -L entry.
# `directory` resolves to the repository root here rather than to the nested
# path, so the consumer appends lib/clang/22/lib/windows itself. The version is
# spelled out there exactly as it is for :include above.
filegroup(
    name = "root_filegroup",
    srcs = ["lib/clang/22/lib/windows"],
)

directory(
    name = "builtins_lib_dir",
    srcs = [":root_filegroup"],
)

filegroup(
    name = "builtins_lib_files",
    srcs = glob(["lib/clang/*/lib/windows/clang_rt.builtins-*.lib"]),
)

filegroup(
    name = "bin",
    srcs = glob(["bin/**"]),
)

filegroup(
    name = "ar",
    srcs = ["bin/llvm-ar.exe"],
)

filegroup(
    name = "as",
    srcs = ["bin/llvm-as.exe"],
)

filegroup(
    name = "nm",
    srcs = ["bin/llvm-nm.exe"],
)

filegroup(
    name = "objcopy",
    srcs = ["bin/llvm-objcopy.exe"],
)

filegroup(
    name = "objdump",
    srcs = ["bin/llvm-objdump.exe"],
)

filegroup(
    name = "profdata",
    srcs = ["bin/llvm-profdata.exe"],
)

filegroup(
    name = "dwp",
    srcs = ["bin/llvm-dwp.exe"],
)

filegroup(
    name = "ranlib",
    srcs = [
        "bin/llvm-ar.exe",
        "bin/llvm-ranlib.exe",
    ],
)

filegroup(
    name = "strip",
    srcs = [
        "bin/llvm-objcopy.exe",
        "bin/llvm-strip.exe",
    ],
)

filegroup(
    name = "clang-tidy",
    srcs = ["bin/clang-tidy.exe"],
)
