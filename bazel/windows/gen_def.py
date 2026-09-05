"""Write a module-definition file listing a DLL's exports.

    gen_def.py <in.dll> <out.def>

The import library for nvptxrt.dll is built from this file with
`lld-link /DEF`, because the Bazel Windows toolchain hands the linker
`/IMPLIB:ignored` and no interface library survives a cc_binary or a
cc_shared_library link. Reading the export table of the DLL that was
actually built -- rather than grepping the source for NVPTXRT_EXPORT --
means the import library cannot disagree with the DLL it stands for.

Pure PE parsing, no third-party modules: this runs inside a Bazel action.
"""
import struct
import sys


def _u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def _u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def exports(path):
    b = open(path, "rb").read()
    if b[:2] != b"MZ":
        raise SystemExit(f"{path}: not a PE file")
    pe = _u32(b, 0x3C)
    if b[pe:pe + 4] != b"PE\0\0":
        raise SystemExit(f"{path}: no PE signature")
    coff = pe + 4
    sections = _u16(b, coff + 2)
    opt_size = _u16(b, coff + 16)
    opt = coff + 20
    magic = _u16(b, opt)
    if magic != 0x20B:
        raise SystemExit(f"{path}: not PE32+ (magic {magic:#x})")
    # Data directory 0 is the export table.
    export_rva = _u32(b, opt + 112)
    if not export_rva:
        return []
    table = opt + opt_size
    ranges = []
    for i in range(sections):
        s = table + i * 40
        vsize = _u32(b, s + 8)
        vaddr = _u32(b, s + 12)
        rsize = _u32(b, s + 16)
        raw = _u32(b, s + 20)
        ranges.append((vaddr, max(vsize, rsize), raw))

    def offset(rva):
        for vaddr, size, raw in ranges:
            if vaddr <= rva < vaddr + size:
                return raw + (rva - vaddr)
        raise SystemExit(f"{path}: RVA {rva:#x} in no section")

    e = offset(export_rva)
    count = _u32(b, e + 24)          # NumberOfNames
    names_rva = _u32(b, e + 32)      # AddressOfNames
    names = offset(names_rva)
    out = []
    for i in range(count):
        p = offset(_u32(b, names + i * 4))
        end = b.index(b"\0", p)
        out.append(b[p:end].decode("ascii"))
    return sorted(out)


def main(argv):
    if len(argv) != 3:
        raise SystemExit(__doc__)
    dll, out = argv[1], argv[2]
    names = exports(dll)
    if not names:
        raise SystemExit(f"{dll}: exports nothing")
    import os
    lines = [f"LIBRARY {os.path.basename(dll)}", "EXPORTS"]
    lines += [f"    {n}" for n in names]
    with open(out, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{out}: {len(names)} exports of {os.path.basename(dll)}")


if __name__ == "__main__":
    main(sys.argv)
