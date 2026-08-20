"""Create a local repository exposing the MSVC CRT and Windows SDK.

There is no `--sysroot` equivalent for a `*-pc-windows-msvc` target, so the
include and library directories have to be passed as ordinary `-isystem` and
`-L` flags. Bazel rejects absolute paths outside the execution root, so pointing
those flags straight at `C:\\Program Files\\...` fails with "references a path
outside of the execution root".

This rule therefore brings the toolchain directories inside the execution root
so they can be exposed as `directory` targets, the same shape
`macos_sysroot_repository` produces for the Xcode SDK.

Unlike the macOS rule it **copies** rather than symlinks. Bazel's `glob` does not
follow symlinked directories on Windows, so a symlinked tree globs to nothing:
the `directory` target then collapses to the repository root, no headers are
declared as action inputs, and the compile fails with "absolute path
inclusion(s) found". Copying costs a slower first fetch and a few hundred MB,
which is the price of the headers actually being visible to Bazel.

The result is deliberately non-hermetic in *content* — it mirrors whatever MSVC
and SDK are installed — because Microsoft's licence does not allow
redistributing the CRT headers and import libraries the way the Linux sysroots
are redistributed. It is hermetic in *shape*, which is what Bazel requires.
"""

_EMPTY_SUBPACKAGE_BUILD = """\
load("@bazel_skylib//rules/directory:directory.bzl", "directory")

package(default_visibility = ["//visibility:public"])

# Not a Windows host. Empty targets keep analysis working elsewhere.
directory(
    name = "dir",
    srcs = [],
)

filegroup(
    name = "files",
    srcs = [],
)
"""

# bazel_skylib's `directory` reports the path of the *package* it is declared
# in, not the common root of its srcs. Declaring them all in the repository root
# therefore collapses every one to the repository root, which silently produces
# five identical -isystem flags. Each directory needs its own package, so a
# BUILD file is written inside each copied tree.
_SUBPACKAGE_BUILD = """\
load("@bazel_skylib//rules/directory:directory.bzl", "directory")

package(default_visibility = ["//visibility:public"])

directory(
    name = "dir",
    srcs = glob(["**"], exclude = ["BUILD.bazel"], allow_empty = True),
)

filegroup(
    name = "files",
    srcs = glob(["**"], exclude = ["BUILD.bazel"], allow_empty = True),
)
"""

# name -> (kind, subpath under the located root)
# 'vc' entries resolve against the MSVC tools directory, 'sdk' against the
# Windows Kits root.
_INCLUDE_DIRS = [
    ("vc_include", "vc", "include"),
    ("sdk_ucrt", "sdk", "Include/{sdk_version}/ucrt"),
    ("sdk_shared", "sdk", "Include/{sdk_version}/shared"),
    ("sdk_um", "sdk", "Include/{sdk_version}/um"),
    ("sdk_winrt", "sdk", "Include/{sdk_version}/winrt"),
]

_LIB_DIRS = [
    ("vc_lib", "vc", "lib/{arch}"),
    ("sdk_lib_ucrt", "sdk", "Lib/{sdk_version}/ucrt/{arch}"),
    ("sdk_lib_um", "sdk", "Lib/{sdk_version}/um/{arch}"),
]

def _norm(path):
    return str(path).replace("\\", "/")

def _find_visual_studio(rctx):
    """Return the newest MSVC tools directory, e.g. .../VC/Tools/MSVC/14.51.36231."""
    program_files = rctx.getenv("ProgramFiles", "C:/Program Files")
    program_files_x86 = rctx.getenv("ProgramFiles(x86)", "C:/Program Files (x86)")

    roots = []
    vswhere = rctx.path(_norm(program_files_x86) + "/Microsoft Visual Studio/Installer/vswhere.exe")
    if vswhere.exists:
        result = rctx.execute([
            str(vswhere),
            "-latest",
            "-products",
            "*",
            "-property",
            "installationPath",
        ])
        if result.return_code == 0 and result.stdout.strip():
            roots.append(_norm(result.stdout.strip()))

    if not roots:
        # vswhere is not always installed; fall back to the standard layout.
        base = rctx.path(_norm(program_files) + "/Microsoft Visual Studio")
        if base.exists:
            for version_dir in base.readdir(watch = "no"):
                for edition in version_dir.readdir(watch = "no"):
                    roots.append(_norm(edition))

    for root in sorted(roots, reverse = True):
        tools = rctx.path(root + "/VC/Tools/MSVC")
        if not tools.exists:
            continue
        versions = sorted([c.basename for c in tools.readdir(watch = "no")], reverse = True)
        if versions:
            return root + "/VC/Tools/MSVC/" + versions[0]

    return None

def _find_windows_sdk(rctx):
    """Return (sdk_root, sdk_version) for the newest installed Windows SDK."""
    program_files_x86 = rctx.getenv("ProgramFiles(x86)", "C:/Program Files (x86)")
    root = _norm(program_files_x86) + "/Windows Kits/10"
    include = rctx.path(root + "/Include")
    if not include.exists:
        return None, None

    versions = []
    for child in include.readdir(watch = "no"):
        # A usable SDK has the ucrt headers under its version directory.
        if rctx.path(str(child) + "/ucrt").exists:
            versions.append(child.basename)

    if not versions:
        return None, None
    return root, sorted(versions, reverse = True)[0]

def _windows_sysroot_repository_impl(rctx):
    all_names = [entry[0] for entry in _INCLUDE_DIRS + _LIB_DIRS]

    rctx.file("BUILD.bazel", "# Intentionally empty; each directory is its own package.\n")

    if not rctx.os.name.startswith("windows"):
        for name in all_names:
            rctx.file(name + "/BUILD.bazel", _EMPTY_SUBPACKAGE_BUILD)
        return

    vc_dir = _find_visual_studio(rctx)
    if not vc_dir:
        fail("Could not locate an MSVC installation. Install the Visual Studio " +
             "'Desktop development with C++' workload, including the ARM64 build tools.")

    sdk_root, sdk_version = _find_windows_sdk(rctx)
    if not sdk_root:
        fail("Could not locate a Windows 10/11 SDK under " +
             "'{}/Windows Kits/10'.".format(rctx.getenv("ProgramFiles(x86)", "C:/Program Files (x86)")))

    arch = rctx.attr.target_arch
    roots = {"vc": vc_dir, "sdk": sdk_root}

    for name, kind, template in _INCLUDE_DIRS + _LIB_DIRS:
        subpath = template.format(sdk_version = sdk_version, arch = arch)
        source = roots[kind] + "/" + subpath
        if not rctx.path(source).exists:
            fail("Expected toolchain directory does not exist: {}\n".format(source) +
                 "The MSVC '{}' build tools or the matching SDK components may not be installed.".format(arch))

        # robocopy /E mirrors the tree. Its exit codes are a bitmask where
        # anything below 8 means success (1 = files copied, 2 = extra files,
        # 4 = mismatches); 8 and above are genuine failures. Treating it like a
        # normal command and checking for zero would fail every time.
        result = rctx.execute([
            "robocopy",
            source.replace("/", "\\"),
            str(rctx.path(name)).replace("/", "\\"),
            "/E",
            "/NFL",
            "/NDL",
            "/NJH",
            "/NJS",
            "/NP",
            "/R:1",
            "/W:1",
        ])
        if result.return_code >= 8:
            fail("Failed copying {} into the sysroot repository (robocopy exit {}):\n{}".format(
                source,
                result.return_code,
                result.stdout + result.stderr,
            ))

        rctx.file(name + "/BUILD.bazel", _SUBPACKAGE_BUILD)

windows_sysroot_repository = repository_rule(
    implementation = _windows_sysroot_repository_impl,
    attrs = {
        "target_arch": attr.string(
            default = "arm64",
            doc = "MSVC/SDK library architecture directory name, e.g. arm64 or x64.",
        ),
    },
    environ = [
        "ProgramFiles",
        "ProgramFiles(x86)",
    ],
    local = True,
    configure = True,
)
