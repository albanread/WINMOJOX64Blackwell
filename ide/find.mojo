"""Finding text, without ever making a copy of it.

Sprint 1.6. The whole of this file is bookkeeping around three rope methods
that already existed and already did the hard part: `find`, `find_last` and
`find_all_in` walk the tree's leaves and scan them where they lie. Nothing is
flattened, which matters more than it sounds -- flattening a 100 MB document
to search it would copy 100 MB per keystroke while somebody holds F3 down,
and the point of a rope is that the text is already in memory in pieces worth
scanning in place.

A match that straddles a leaf boundary is the one thing a leaf walk can miss,
and the rope handles it by scanning each leaf together with the last
`len(needle) - 1` bytes of the one before. That is the only place a split
match can hide.

Two different searches happen here and they have different shapes.

**Find next** is one match, from a position, and it stops as soon as it has
one. Cost is the distance to the match, not the size of the document.

**Highlight all** is every match, but only within the lines currently on
screen -- a range of a few thousand bytes, asked for afresh each frame. A
document with a million matches highlights exactly the ones a person can see,
and costs the same as a document with three.
"""

from ide.doc import Doc
from ide.edit import caret_of_byte


def find_next(mut doc: Doc, needle: String, from_byte: Int) raises -> Int:
    """The next match at or after a byte offset, wrapping once.

    Wrapping is what every editor does and what nobody thinks about until it
    is missing. It happens once: a needle that is not in the document returns
    -1 rather than searching forever.

    Args:
        doc: The document.
        needle: What to look for.
        from_byte: Where to start.

    Returns:
        The match's byte offset, or -1.
    """
    if needle.byte_length() == 0:
        return -1
    var hit = doc.rope.find(needle, from_byte)
    if hit < 0 and from_byte > 0:
        hit = doc.rope.find(needle, 0)
    return hit


def find_prev(mut doc: Doc, needle: String, before_byte: Int) raises -> Int:
    """The last match starting before a byte offset, wrapping once.

    Backwards, in chunks, so the cost is the distance to the match rather
    than the size of the document.

    The rope has a `find_last`, and it says of itself that it is forward
    search with the last qualifying hit kept -- "not worth the second code
    path until someone is searching backwards through 100 MB". Sprint 1.6 is
    someone searching backwards through 100 MB: measured, that shape costs
    271 ms on a 14 MB document, which extrapolates to about two seconds on
    the size the acceptance names, for one press of Shift+F3.

    So this walks back a window at a time and asks for every match inside it,
    which is one tree walk per window rather than one per match. A match near
    the caret is found in the first window. The windows overlap by the length
    of the needle less one, because that is exactly how far a match can
    straddle a boundary.

    Args:
        doc: The document.
        needle: What to look for.
        before_byte: Search strictly before this.

    Returns:
        The match's byte offset, or -1.
    """
    var width = needle.byte_length()
    if width == 0:
        return -1

    var hit = _last_before(doc, needle, before_byte)
    if hit < 0 and before_byte < doc.rope.byte_length():
        # Wrap: nothing behind the caret, so the last match in the document.
        hit = _last_before(doc, needle, doc.rope.byte_length())
    return hit


# Sixty-four kilobytes: comfortably more than a screenful of text, so the
# common case -- the previous match is nearby -- takes one window, and small
# enough that a document with a match every few bytes does not collect
# millions of offsets into a list nobody reads.
comptime BACK_WINDOW = 1 << 16


def _last_before(mut doc: Doc, needle: String, before: Int) raises -> Int:
    """The last match beginning strictly before `before`, or -1."""
    var width = needle.byte_length()
    var end = before
    while end > 0:
        var start = end - BACK_WINDOW
        if start < 0:
            start = 0
        # Reach back by the needle length less one, so a match straddling the
        # window boundary is inside this window rather than lost between two.
        var lo = start - (width - 1)
        if lo < 0:
            lo = 0
        var hits = doc.rope.find_all_in(needle, lo, end)
        var best = -1
        for h in hits:
            if h < before and h > best:
                best = h
        if best >= 0:
            return best
        if start == 0:
            break
        end = start
    return -1


def select_match(mut doc: Doc, at: Int, needle: String) raises:
    """Put the caret at the end of a match and the anchor at its start.

    Selecting the match rather than merely landing on it is what makes the
    next keystroke replace it, which is what a person expects after finding
    something.
    """
    var start = caret_of_byte(doc.rope, at)
    var end = caret_of_byte(doc.rope, at + needle.byte_length())
    doc.anchor_line = start[0]
    doc.anchor_col = start[1]
    doc.caret_line = end[0]
    doc.caret_col = end[1]


def matches_in_line(rope_line_start: Int, line: String, needle: String) -> List[Int]:
    """Where a needle occurs within one line, as offsets from its start.

    Used by the draw, once per visible line. The line is already a String by
    the time it is being drawn, so this searches what is there rather than
    asking the rope again.

    Args:
        rope_line_start: Unused by the search; kept so callers read clearly.
        line: The line's text.
        needle: What to look for.

    Returns:
        Byte offsets within the line.
    """
    var out = List[Int]()
    if needle.byte_length() == 0 or line.byte_length() == 0:
        return out^
    var at = 0
    while True:
        var hit = line.find(needle, at)
        if hit < 0:
            break
        out.append(hit)
        at = hit + 1
    return out^
