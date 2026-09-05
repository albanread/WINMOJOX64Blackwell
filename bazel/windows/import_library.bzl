"""An import library for a Windows DLL, as a declared Bazel output.

The Windows toolchain hands a cc_binary DLL link `/IMPLIB:ignored` and keeps
no interface library for it or for a cc_shared_library, so a DLL built that
way -- nvptxrt.dll -- has nothing a program can link against. (The tree's
own modular_shared_library rule is different: it links with
emit_interface_shared_library and declares its .lib itself, which is why
MojoLLDB.lib needs no help from here.)

This rebuilds the import library from the DLL's own export table, so it
cannot disagree with the DLL it stands for, and it is a real output: built
on demand, rebuilt when the DLL changes, never missing.
"""

def windows_import_library(name, dll, out, **kwargs):
    """Declares `out`, an import library for the DLL file `dll`.

    Args:
        name: The target name.
        dll: Label of the DLL file (a rule's output file label, e.g.
            ":nvptxrt.dll" or "MojoLLDB.dll").
        out: The import library's file name, e.g. "nvptxrt.if.lib". Pick a
            name that does not collide with a static archive the package
            also builds.
        **kwargs: Passed to the underlying genrule (visibility, tags).
    """
    def_file = name + ".def"
    native.genrule(
        name = name,
        srcs = [dll],
        outs = [def_file, out],
        # Dash-form linker flags: the genrule shell on Windows is MSYS bash,
        # which rewrites an argument beginning with a slash as a path.
        cmd = (
            "$(location //bazel/windows:gen_def) $(location {dll}) $(location {deffile}) && " +
            "$(location @llvm-project//lld:lld) -flavor link " +
            "-def:$(location {deffile}) -machine:x64 -out:$(location {out})"
        ).format(dll = dll, deffile = def_file, out = out),
        target_compatible_with = [
            "@platforms//cpu:x86_64",
            "@platforms//os:windows",
        ],
        tools = [
            "//bazel/windows:gen_def",
            "@llvm-project//lld:lld",
        ],
        **kwargs
    )
