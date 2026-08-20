"""Function to create tools definitions per platform."""

load("@rules_cc//cc/toolchains:tool.bzl", "cc_tool")
load("@rules_cc//cc/toolchains:tool_map.bzl", "cc_tool_map")
load("//bazel:config.bzl", "TOP_LEVEL_TAG")

PLATFORMS = [
    "linux-aarch64",
    "linux-x86_64",
    "macos",
    "windows-arm64",
    "windows-x86_64",
]

# Platforms whose toolchain binaries carry a .exe suffix and which cannot run
# the .sh tool wrappers, so they bind the clang binaries directly instead.
WINDOWS_PLATFORMS = [
    "windows-arm64",
    "windows-x86_64",
]

def _is_windows(platform):
    return platform in WINDOWS_PLATFORMS

def _exe(platform):
    return ".exe" if _is_windows(platform) else ""

# buildifier: disable=unnamed-macro
def declare_tools():
    for platform in PLATFORMS:
        if _is_windows(platform):
            _declare_windows_tools(platform)
        else:
            _declare_tools(platform)

def _declare_windows_tools(platform):
    """Declare tools for a Windows platform.

    Windows cannot exec the multi-platform .sh wrappers, and there is no
    separate linker driver: the clang driver invokes lld-link itself.

    Everything else is declared exactly as on the other platforms. llvm-otool
    and llvm-install-name-tool read as Mach-O tools but LLVM does ship them in
    the Windows distribution, so they are declared rather than special-cased,
    which keeps the alias list in tools/BUILD.bazel uniform across platforms.
    dwp is the one real omission: split DWARF does not apply to PDB debug info.
    """
    ext = _exe(platform)

    cc_tool_map(
        name = "{}_tools".format(platform),
        tags = ["manual"],
        visibility = ["//bazel/internal/cc-toolchain:__subpackages__"],
        tools = {
            "@rules_cc//cc/toolchains/actions:ar_actions": ":{}-llvm-ar".format(platform),
            "@rules_cc//cc/toolchains/actions:assembly_actions": ":{}-clang".format(platform),
            "@rules_cc//cc/toolchains/actions:c_compile": ":{}-clang".format(platform),
            "@rules_cc//cc/toolchains/actions:cpp_compile_actions": ":{}-clang++".format(platform),
            "@rules_cc//cc/toolchains/actions:link_actions": ":{}-linker_driver".format(platform),
            "@rules_cc//cc/toolchains/actions:objcopy_embed_data": ":{}-llvm-objcopy".format(platform),
            "@rules_cc//cc/toolchains/actions:strip": ":{}-llvm-strip".format(platform),
        },
    )

    for tool in ["llvm-ar", "llvm-objcopy", "llvm-strip", "clang-format", "clangd"]:
        cc_tool(
            name = "{}-{}".format(platform, tool),
            src = "@clang-{}//:bin/{}{}".format(platform, tool, ext),
            tags = ["manual"],
        )

    cc_tool(
        name = "{}-clang-tidy".format(platform),
        src = "@clang-{}//:bin/clang-tidy{}".format(platform, ext),
        tags = [
            "manual",
            TOP_LEVEL_TAG,  # Used in .bazelrc
        ],
    )

    cc_tool(
        name = "{}-llvm-install-name-tool".format(platform),
        src = "@clang-{}//:bin/llvm-install-name-tool{}".format(platform, ext),
        data = ["@clang-{}//:bin/llvm-objcopy{}".format(platform, ext)],
        tags = ["manual"],
    )

    cc_tool(
        name = "{}-llvm-otool".format(platform),
        src = "@clang-{}//:bin/llvm-otool{}".format(platform, ext),
        data = ["@clang-{}//:bin/llvm-objdump{}".format(platform, ext)],
        tags = ["manual"],
    )

    # Driven through .bat wrappers rather than binding clang.exe directly. The
    # parse_headers feature works by setting PARSE_HEADER and expecting the
    # compiler wrapper to create that file, which is what the .sh wrappers do on
    # the other platforms; binding the binary directly means the marker is never
    # created and every header parse fails with "not all outputs were created".
    #
    # lld-link is the linker the clang driver spawns for a *-pc-windows-msvc
    # target, so it has to be present in the tool's runfiles.
    cc_tool(
        name = "{}-clang".format(platform),
        src = ":windows-clang.bat",
        data = [
            "@clang-{}//:bin/clang{}".format(platform, ext),
            "@clang-{}//:ld".format(platform),
        ],
        tags = ["manual"],
    )

    cc_tool(
        name = "{}-clang++".format(platform),
        src = ":windows-clang++.bat",
        data = [
            "@clang-{}//:bin/clang++{}".format(platform, ext),
            "@clang-{}//:bin/clang{}".format(platform, ext),
            "@clang-{}//:ld".format(platform),
        ],
        tags = ["manual"],
    )

    # Linking binds clang++.exe directly rather than going through the .bat.
    # cmd.exe truncates a command line at 8191 characters, well below the 32767
    # that CreateProcess itself allows, and linking LLVM blows past that: the
    # link of MSupportGlobals.dll failed with "The command line is too long".
    # Only the header-parsing actions need the wrapper's PARSE_HEADER marker, so
    # link actions have nothing to gain from it and everything to lose.
    cc_tool(
        name = "{}-linker_driver".format(platform),
        src = "@clang-{}//:bin/clang++{}".format(platform, ext),
        data = [
            "@clang-{}//:bin/clang{}".format(platform, ext),
            "@clang-{}//:ld".format(platform),
        ],
        tags = ["manual"],
    )

    for name in ["builtin_headers", "resource_directory_filegroup", "resource_directory"]:
        actual = "include" if name == "builtin_headers" else name
        native.alias(
            name = "{}-{}".format(platform, name),
            actual = "@clang-{}//:{}".format(platform, actual),
            tags = ["manual"],
            visibility = ["//visibility:private"],
        )

def _declare_tools(platform):
    cc_tool_map(
        name = "{}_tools".format(platform),
        tags = ["manual"],
        visibility = ["//bazel/internal/cc-toolchain:__subpackages__"],
        tools = {
            "@rules_cc//cc/toolchains/actions:ar_actions": ":{}-llvm-ar".format(platform),
            "@rules_cc//cc/toolchains/actions:assembly_actions": ":{}-clang".format(platform),
            "@rules_cc//cc/toolchains/actions:c_compile": ":{}-clang".format(platform),
            "@rules_cc//cc/toolchains/actions:cpp_compile_actions": ":{}-clang++".format(platform),
            "@rules_cc//cc/toolchains/actions:link_actions": ":{}-linker_driver".format(platform),
            "@rules_cc//cc/toolchains/actions:objc_compile": ":{}-clang".format(platform),
            "@rules_cc//cc/toolchains/actions:objcopy_embed_data": ":{}-llvm-objcopy".format(platform),
            "@rules_cc//cc/toolchains/actions:strip": ":{}-llvm-strip".format(platform),
            "@rules_cc//cc/toolchains/actions:dwp": ":{}-llvm-dwp".format(platform),
        },
    )

    cc_tool(
        name = "{}-llvm-ar".format(platform),
        src = "@clang-{}//:bin/llvm-ar".format(platform),
        tags = ["manual"],
    )

    cc_tool(
        name = "{}-llvm-objcopy".format(platform),
        src = "@clang-{}//:bin/llvm-objcopy".format(platform),
        tags = ["manual"],
    )

    cc_tool(
        name = "{}-llvm-strip".format(platform),
        src = "@clang-{}//:bin/llvm-strip".format(platform),
        tags = ["manual"],
    )

    cc_tool(
        name = "{}-llvm-dwp".format(platform),
        src = "@clang-{}//:bin/llvm-dwp".format(platform),
        tags = ["manual"],
    )

    cc_tool(
        name = "{}-clang-tidy".format(platform),
        src = "@clang-{}//:bin/clang-tidy".format(platform),
        tags = [
            "manual",
            TOP_LEVEL_TAG,  # Used in .bazelrc
        ],
    )

    native.alias(
        name = "{}-builtin_headers".format(platform),
        actual = "@clang-{}//:include".format(platform),
        tags = ["manual"],
        visibility = ["//visibility:private"],
    )

    native.alias(
        name = "{}-resource_directory_filegroup".format(platform),
        actual = "@clang-{}//:resource_directory_filegroup".format(platform),
        tags = ["manual"],
        visibility = ["//visibility:private"],
    )

    native.alias(
        name = "{}-resource_directory".format(platform),
        actual = "@clang-{}//:resource_directory".format(platform),
        tags = ["manual"],
        visibility = ["//visibility:private"],
    )

    cc_tool(
        name = "{}-clang-format".format(platform),
        src = "@clang-{}//:bin/clang-format".format(platform),
        tags = ["manual"],
    )

    cc_tool(
        name = "{}-clangd".format(platform),
        src = "@clang-{}//:bin/clangd".format(platform),
        tags = ["manual"],
    )

    cc_tool(
        name = "{}-llvm-install-name-tool".format(platform),
        src = "@clang-{}//:bin/llvm-install-name-tool".format(platform),
        data = ["@clang-{}//:bin/llvm-objcopy".format(platform)],
        tags = ["manual"],
    )

    cc_tool(
        name = "{}-llvm-otool".format(platform),
        src = "@clang-{}//:bin/llvm-otool".format(platform),
        data = ["@clang-{}//:bin/llvm-objdump".format(platform)],
        tags = ["manual"],
    )

    cc_tool(
        name = "{}-single-platform-clang".format(platform),
        src = ":multi-platform-clang.sh",
        data = ["@clang-{}//:bin/clang".format(platform)],
        tags = ["manual"],
    )

    native.alias(
        name = "{}-clang".format(platform),
        actual = select({
            "//:host_modular_config_ci_build": ":{}-single-platform-clang".format(platform),
            "//conditions:default": ":multi-platform-clang",
        }),
        tags = ["manual"],
    )

    cc_tool(
        name = "{}-single-platform-clang++".format(platform),
        src = ":multi-platform-clang++.sh",
        data = ["@clang-{}//:bin/clang++".format(platform)],
        tags = ["manual"],
    )

    native.alias(
        name = "{}-clang++".format(platform),
        actual = select({
            "//:host_modular_config_ci_build": ":{}-single-platform-clang++".format(platform),
            "//conditions:default": ":multi-platform-clang++",
        }),
        tags = ["manual"],
    )

    cc_tool(
        name = "{}-single-platform-linker_driver".format(platform),
        src = ":linker-driver.sh",
        data = [
            "@clang-{}//:bin/clang".format(platform),
            "@clang-{}//:bin/clang++".format(platform),  # symlink to clang
            "@clang-{}//:bin/dsymutil".format(platform),
            "@clang-{}//:ld".format(platform),
        ],
        tags = [
            "manual",
            # HACK: until our lld contains this fix https://github.com/llvm/llvm-project/commit/9234066476aa82cfac3cee564883a3124df4584e
            # This tag is meaningless to us but changes this behavior https://github.com/bazelbuild/bazel/blob/4c664d9ba50e7d7aea66a0547a5bac3ca8d264e5/src/main/starlark/builtins_bzl/common/cc/link/finalize_link_action.bzl#L363
            "requires_darwin",
        ],
    )

    native.alias(
        name = "{}-linker_driver".format(platform),
        actual = select({
            "//:host_modular_config_ci_build": ":{}-single-platform-linker_driver".format(platform),
            "//conditions:default": ":multi-platform-linker_driver",
        }),
        tags = ["manual"],
    )
