"""W1: derive the device-runtime ABI specification from Modular's own bindings.

`max/mojo/max/gpu/host/*.mojo` declares every `AsyncRT_*` symbol it calls, and
most declarations carry the real C prototype in a comment directly above. This
walks those declarations and emits `ABI.md`.

Generated, never hand-edited: rerun after any rebase onto upstream and diff the
result. That is the whole point - the spec cannot silently drift.

    python dragon/runtime/extract_abi.py [--check]

`--check` exits non-zero if ABI.md is stale, for use in CI.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field

REPO = pathlib.Path(__file__).resolve().parents[2]
SOURCES = sorted((REPO / "max/mojo/max/gpu/host").glob("*.mojo"))
OUT = REPO / "dragon/runtime/ABI.md"

# The symbols needed to load and launch one kernel and read the result back.
# Everything else can wait or be stubbed. Hand-picked, not derived - so the
# generator checks them against reality and complains if one is missing.
BRINGUP = {
    "AsyncRT_DeviceContext_create",
    "AsyncRT_DeviceContext_release",
    "AsyncRT_DeviceContext_retain",
    "AsyncRT_DeviceContext_id",
    "AsyncRT_DeviceContext_deviceName",
    "AsyncRT_DeviceContext_archName",
    "AsyncRT_DeviceContext_deviceApi",
    "AsyncRT_DeviceContext_getApiVersion",
    "AsyncRT_DeviceContext_numberOfDevices",
    "AsyncRT_DeviceContext_synchronize",
    "AsyncRT_DeviceContext_setAsCurrent",
    "AsyncRT_DeviceContext_strfree",
    "AsyncRT_DeviceContext_getMemoryInfo",
    "AsyncRT_DeviceContext_maxSingleAllocationSize",
    "AsyncRT_DeviceContext_createBuffer_async",
    "AsyncRT_DeviceContext_createBuffer_owning",
    "AsyncRT_DeviceContext_createHostBuffer",
    "AsyncRT_DeviceContext_HtoD_async",
    "AsyncRT_DeviceContext_DtoH_async",
    "AsyncRT_DeviceContext_DtoD_async",
    "AsyncRT_DeviceContext_setMemory_async",
    "AsyncRT_DeviceContext_createStream",
    "AsyncRT_DeviceContext_stream",
    "AsyncRT_DeviceContext_loadFunction",
    "AsyncRT_DeviceContext_enqueueFunctionDirect",
    "AsyncRT_DeviceBuffer_bytesize",
    "AsyncRT_DeviceBuffer_retain",
    "AsyncRT_DeviceBuffer_release",
    "AsyncRT_DeviceStream_retain",
    "AsyncRT_DeviceStream_release",
    "AsyncRT_DeviceStream_synchronize",
    "AsyncRT_DeviceFunction_retain",
    "AsyncRT_DeviceFunction_release",
}

VENDOR_WORDS = ("cuda", "hip", "metal", "nvshmem", "rocshmem")
MULTIGPU_WORDS = ("peeraccess", "canaccess", "multicast")


@dataclass
class Sym:
    name: str
    ret: str = ""
    args: list = field(default_factory=list)
    proto: str = ""
    sites: list = field(default_factory=list)

    @property
    def tier(self) -> str:
        low = self.name.lower()
        if any(w in low for w in VENDOR_WORDS):
            return "vendor"
        if "devicegraph" in low:
            return "graph"
        if any(w in low for w in MULTIGPU_WORDS):
            return "multigpu"
        return "core"


def split_top(s: str) -> list:
    """Split on commas that are not inside brackets."""
    out, depth, cur = [], 0, []
    for ch in s:
        if ch in "[(":
            depth += 1
        elif ch in "])":
            depth -= 1
        if ch == "," and depth == 0:
            out.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    if "".join(cur).strip():
        out.append("".join(cur).strip())
    return out


SCAN_BACK = 14
BLOCK_END = re.compile(r"^\s*(def|fn|struct|trait|comptime|@)")


def preceding_prototype(lines: list, idx: int, symbol: str) -> str:
    """Recover the C prototype comment above an `external_call`.

    The comment is not always on the line directly above: the call is often
    wrapped, as in `_checked(\\n external_call[...]`, which puts a bare `(` in
    between. So scan back over intervening code, collecting each contiguous
    comment block, and accept the first one that names the symbol.

    Naming the symbol is what makes the wider scan safe - these files carry
    plenty of ordinary prose comments, and none of them mention the C symbol.
    """
    i = idx - 1
    limit = max(0, idx - SCAN_BACK)
    while i >= limit:
        stripped = lines[i].strip()
        if stripped.startswith("#"):
            block = []
            while i >= 0 and lines[i].strip().startswith("#"):
                block.append(lines[i].strip().lstrip("#").strip())
                i -= 1
            text = re.sub(r"\s+", " ", " ".join(reversed(block))).strip()
            if symbol in text:
                return text
            continue
        # Do not cross out of the enclosing declaration.
        if BLOCK_END.match(lines[i]):
            break
        i -= 1
    return ""


def extract() -> dict:
    syms = {}
    for path in SOURCES:
        text = path.read_text(encoding="utf-8", errors="replace")
        lines = text.split("\n")
        for m in re.finditer(r"external_call\[", text):
            start = m.end()
            depth, j = 1, start
            while j < len(text) and depth:
                if text[j] == "[":
                    depth += 1
                elif text[j] == "]":
                    depth -= 1
                j += 1
            parts = split_top(text[start : j - 1])
            if not parts:
                continue
            name_m = re.match(r'^"([A-Za-z_0-9]+)"$', parts[0].strip())
            if not name_m:
                continue
            name = name_m.group(1)
            line_no = text[: m.start()].count("\n")
            sym = syms.setdefault(name, Sym(name))
            if not sym.ret and len(parts) > 1:
                sym.ret = parts[1]
                sym.args = parts[2:]
            if not sym.proto:
                sym.proto = preceding_prototype(lines, line_no, name)
            sym.sites.append(path.name + ":" + str(line_no + 1))
    return syms


TIER_TABLE = (
    ("core", "**must implement**"),
    ("graph", "capture/replay - stub as unsupported at first"),
    ("vendor", "CUDA/HIP/Metal escape hatches - not applicable, omit"),
    ("multigpu", "peer access and multicast - single GPU here, stub"),
)

TIER_SECTIONS = (
    ("core", "Core", "Everything a working device backend needs."),
    (
        "graph",
        "Graph capture",
        "CUDA-graph-style record and replay. An Adreno backend can report this "
        "unsupported until there is a reason not to.",
    ),
    (
        "vendor",
        "Vendor escape hatches",
        "These hand out the underlying CUDA/HIP/Metal handle, or use a "
        "vendor-only feature. There is no Snapdragon equivalent and no reason "
        "to invent one - leave them unimplemented.",
    ),
    (
        "multigpu",
        "Multi-device",
        "Peer access and multicast across several GPUs. This machine has one "
        "integrated GPU.",
    ),
)


def render(syms: dict) -> str:
    by_tier = defaultdict(list)
    for s in syms.values():
        by_tier[s.tier].append(s)
    for v in by_tier.values():
        v.sort(key=lambda s: s.name)

    n = len(syms)
    documented = sum(1 for s in syms.values() if s.proto)
    pct = 100 * documented // max(n, 1)
    cstring = sum(1 for x in syms.values() if "CString" in x.ret)
    groups = Counter(s.name.split("_")[1] for s in syms.values())

    L = []
    w = L.append
    w("# Device runtime ABI")
    w("")
    w("<!-- GENERATED by dragon/runtime/extract_abi.py - do not hand-edit. -->")
    w("")
    w("The C ABI that `max/mojo/max/gpu/host/*.mojo` calls into, and that a")
    w("Snapdragon device backend has to satisfy. Modular does not publish the")
    w("implementation, but every symbol is *declared* here, and most declarations")
    w("carry the real C prototype in a comment above them.")
    w("")
    w(
        "**" + str(n) + " symbols**, " + str(documented) + " of them ("
        + str(pct) + "%) with a C prototype recovered from the bindings."
    )
    w("")
    w("## What the ABI tells us about adding a backend")
    w("")
    w("Three structural facts, read off the recovered prototypes. These are not")
    w("in any Modular document.")
    w("")
    w("**1. The device runtime is a string-dispatched factory.**")
    w("")
    w("```c")
    w("const char *AsyncRT_DeviceContext_create(")
    w("    const DeviceContext **result, const char *api, int id)")
    w("```")
    w("")
    w("`api` is a plain runtime string, documented as `\"cpu\"`, `\"cuda\"`, `\"hip\"`")
    w("(and `\"metal\"` per `info.mojo`). It is not an enum and not a compile-time")
    w("parameter. A Snapdragon device registers by answering to a new string -")
    w("and since we implement the runtime, we own that dispatch outright.")
    w("")
    w("**2. `\"cpu\"` is a device like any other.** AsyncRT's `CPUDevice` is")
    w("published, and it is reached through this same interface. It is therefore a")
    w("working reference implementation of the ABI's shape, in open source, that")
    w("we can read while building ours.")
    w("")
    w(
        "**3. Errors come back as owned strings, not codes.** " + str(cstring)
        + " of the " + str(n) + " symbols return `const char *`. The convention,"
        + " traced through `_checked` -> `_raise_checked_impl` ->"
    )
    w("`_string_from_owned_charptr`:")
    w("**null means success**; non-null is an error message the *caller* owns and")
    w("must release with `AsyncRT_DeviceContext_strfree`. An implementation has to")
    w("match that ownership rule exactly or it leaks on every error path.")
    w("")
    w("## Tiers")
    w("")
    w("| Tier | Count | Meaning for a Snapdragon backend |")
    w("|---|---|---|")
    for tier, meaning in TIER_TABLE:
        w("| `" + tier + "` | " + str(len(by_tier.get(tier, []))) + " | " + meaning + " |")
    w("")
    w("Of the core tier, **" + str(len(BRINGUP)) + "** are the bring-up subset:")
    w("enough to load and launch one kernel and read the result back. Marked")
    w("[BRINGUP] below and listed together at the end.")
    w("")
    w("## Symbols by object")
    w("")
    w("| Object | Symbols |")
    w("|---|---|")
    for g, c in groups.most_common():
        w("| `AsyncRT_" + g + "_*` | " + str(c) + " |")
    w("")

    for tier, title, blurb in TIER_SECTIONS:
        group = by_tier.get(tier, [])
        if not group:
            continue
        w("## " + title + " (" + str(len(group)) + ")")
        w("")
        w(blurb)
        w("")
        for s in group:
            mark = " [BRINGUP]" if s.name in BRINGUP else ""
            w("### `" + s.name + "`" + mark)
            w("")
            if s.proto:
                w("```c")
                w(s.proto)
                w("```")
                w("")
            else:
                w("*No C prototype in the bindings.* Mojo signature only:")
                w("")
            w("- Mojo return: `" + (s.ret or "?") + "`")
            if s.args:
                w("- Mojo params:")
                for a in s.args:
                    w("  - `" + a + "`")
            w("- Declared at: " + ", ".join(s.sites[:3]))
            if len(s.sites) > 3:
                w("  (+" + str(len(s.sites) - 3) + " more call sites)")
            w("")

    w("## Bring-up subset")
    w("")
    w("Implement these first. Everything else can wait or be stubbed.")
    w("")
    present = sorted(BRINGUP & set(syms))
    missing = sorted(BRINGUP - set(syms))
    for name in present:
        w("- `" + name + "`")
    if missing:
        w("")
        w("**Named in the bring-up list but absent from the bindings.** Either")
        w("renamed upstream or misspelled here - fix before relying on this list:")
        w("")
        for name in missing:
            w("- `" + name + "`")
    w("")
    return "\n".join(L)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if ABI.md is stale")
    a = ap.parse_args()

    if not SOURCES:
        print("no binding sources found - wrong repo root?", file=sys.stderr)
        return 2

    syms = extract()
    text = render(syms)

    if a.check:
        old = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if old != text:
            print(str(OUT) + " is stale; rerun extract_abi.py", file=sys.stderr)
            return 1
        print(str(OUT) + " up to date (" + str(len(syms)) + " symbols)")
        return 0

    OUT.write_text(text, encoding="utf-8")
    documented = sum(1 for s in syms.values() if s.proto)
    tiers = Counter(s.tier for s in syms.values())
    print("wrote " + str(OUT.relative_to(REPO)))
    print("  " + str(len(syms)) + " symbols, " + str(documented) + " with C prototypes")
    print("  tiers: " + str(dict(tiers)))
    print("  bring-up present: " + str(len(BRINGUP & set(syms))) + "/" + str(len(BRINGUP)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
