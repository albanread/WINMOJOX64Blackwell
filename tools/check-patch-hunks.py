#!/usr/bin/env python3
"""Validate unified-diff hunk headers before bazel ever sees them.

A wrong @@ line count fails inside bazel's repo fetch, and on this tree
that costs a full LLVM re-extract to discover -- minutes, to learn that a
number is off by one. The counts are checkable in milliseconds here.

Run it after editing anything in bazel/public-patches/ and before any
build. It exits non-zero if a header disagrees with its body.

Blank context lines appear both as a single space and as a truly empty
line, depending on which tool produced the patch; both count as context.
The trailing empty string left by the final newline is stripped first, and
a no-newline-at-end-of-file marker counts as nothing.
"""

import re
import sys

NO_NEWLINE_MARKER = "\\"


def check(path):
    raw = open(path, "rb").read()
    lines = raw.decode("utf-8").replace("\r\n", "\n").split("\n")
    while lines and lines[-1] == "":
        lines.pop()

    ok = True
    i = 0
    while i < len(lines):
        header = re.match(r"@@ -(\d+),(\d+) \+(\d+),(\d+) @@", lines[i])
        if not header:
            i += 1
            continue

        want_old = int(header.group(2))
        want_new = int(header.group(4))
        # Consume exactly as many lines as the header declares, the way a
        # real applier does. Reading to the next "@@" instead would count a
        # blank separator line after a complete hunk, which belongs to
        # neither -- that reads as an off-by-one in both directions and is
        # the tool crying wolf on patches that apply perfectly well.
        j = i + 1
        ctx = add = rem = 0
        while j < len(lines) and not lines[j].startswith(("@@", "--- ")):
            if ctx + rem >= want_old and ctx + add >= want_new:
                break
            line = lines[j]
            if line.startswith("+"):
                add += 1
            elif line.startswith("-"):
                rem += 1
            elif line.startswith(" ") or line == "":
                ctx += 1
            elif line.startswith(NO_NEWLINE_MARKER):
                pass
            else:
                break
            j += 1

        got_old, got_new = ctx + rem, ctx + add
        if (got_old, got_new) != (want_old, want_new):
            ok = False
            print(
                f"  BAD line {i + 1}: header -{want_old} +{want_new}, "
                f"counted -{got_old} +{got_new} (hunk body is short)"
            )
        # Skip any blank separator before the next hunk.
        while j < len(lines) and lines[j] == "":
            j += 1
        i = j

    print(f"{'VALID  ' if ok else 'INVALID'} {path}")
    return ok


if __name__ == "__main__":
    paths = sys.argv[1:]
    if not paths:
        sys.exit("usage: check-patch-hunks.py <patch>...")
    sys.exit(0 if all([check(p) for p in paths]) else 1)
