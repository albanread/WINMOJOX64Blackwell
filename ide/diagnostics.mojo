"""Diagnostics, from the language server onto the screen.

Sprint 2.2. The client underneath this is MojoCocoa's, ported: it already
tracks which diagnostics belong to which document, which of them are for the
file being shown, and how to drop the ones for a file that changed. This is
the part that turns those into something a person can see and click.

Three places a diagnostic appears, each answering a different question:

**A squiggle under the text** says *this*, precisely, pointing at the columns
the server named. It is drawn under the glyphs like the selection, so the code
stays readable on top of it.

**A mark in the gutter** says *this line*, and survives being scrolled past --
you can see there is a problem on a line whose text is off the right edge.

**The issues pane** says *this file*, and is the only one of the three that
works when the problem is somewhere you are not looking. Clicking a row goes
there, which is the whole reason the pane is worth its hundred and forty
pixels.

The document is told about edits by version, and the server answers by
version. A diagnostic for version 7 drawn over a document at version 9 points
at columns that have moved, so the version the diagnostics were computed for
is kept and stale ones are drawn faded rather than moved or hidden -- moving
them would be a guess, and hiding them makes the editor flicker clean on every
keystroke.
"""

from std.ffi import c_int
from std.memory import OpaquePointer, Pointer

from ide.chrome import Chrome, D2D_RECT_F, Layout
from ide.doc import Doc
from ide.lsp import (
    diagnostic_count,
    diag_visible,
    g_diag_col,
    g_diag_end,
    g_diag_line,
    g_diag_msg,
    g_diag_sev,
    g_diag_uri,
    shown_uri,
)


# Severity, as LSP numbers them. Only the first two are drawn differently;
# hints and information are drawn like a warning, because an editor with four
# shades of underline is an editor nobody can read at a glance.
comptime SEVERITY_ERROR = 1
comptime SEVERITY_WARNING = 2


def count_for_shown() -> Int:
    """How many diagnostics belong to the document on screen."""
    var n = 0
    for i in range(diagnostic_count()):
        if diag_visible(i):
            n += 1
    return n


def worst_severity() -> Int:
    """The most serious severity among the visible diagnostics, or zero."""
    var worst = 0
    for i in range(diagnostic_count()):
        if not diag_visible(i):
            continue
        var s = g_diag_sev()[][i]
        if worst == 0 or s < worst:
            worst = s
    return worst


def on_line(line: Int) -> Int:
    """The index of the first visible diagnostic on `line`, or -1.

    Args:
        line: A zero-based line number.

    Returns:
        An index into the diagnostic arrays, or -1.
    """
    for i in range(diagnostic_count()):
        if diag_visible(i) and g_diag_line()[][i] == line:
            return i
    return -1


def summary() -> String:
    """Every diagnostic for the shown document, one per line.

    What the `issues` verb answers and what the issues pane draws, so a check
    and a person are reading the same list.
    """
    var total = diagnostic_count()
    var mine = count_for_shown()
    if mine == 0:
        return (
            String("no issues")
            if total == 0
            else String("no issues in this file (")
            + String(total)
            + " elsewhere)"
        )
    var out = String("")
    for i in range(total):
        if not diag_visible(i):
            continue
        out += (
            String("error" if g_diag_sev()[][i] == SEVERITY_ERROR else "warning")
            + " " + String(g_diag_line()[][i] + 1)
            + ":" + String(g_diag_col()[][i] + 1)
            + "  " + g_diag_msg()[][i]
            + "\n"
        )
    return out^


def nth_visible(n: Int) -> Int:
    """The index of the nth visible diagnostic, or -1.

    Used by the issues pane, where row n is the nth issue in this file rather
    than the nth the server has ever sent.
    """
    var seen = 0
    for i in range(diagnostic_count()):
        if not diag_visible(i):
            continue
        if seen == n:
            return i
        seen += 1
    return -1
