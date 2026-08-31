"""Changing the document, and being able to change your mind.

Sprint 1.4. Every edit in this file is one call to `Rope.replace`, because
every edit *is* one: typing is a replace of an empty range, deleting is a
replace with empty text, backspace over a selection is a replace with empty
text over a wider range, and pasting over a selection is the general case
that all the others are special cases of. Writing four operations that share
one implementation is how the awkward combinations -- delete at the start of
a line with a selection running backwards up the file -- stop being separate
things that each need to be got right.

Undo is a list of previous documents rather than a log of inverse
operations. See `ide/doc.mojo` for why that is affordable; the consequence
here is that `undo` and `redo` are eight lines between them and cannot be
subtly wrong about an operation they were never told the shape of.

Positions come in two currencies and this file is where they are exchanged.
The caret is a line and a UTF-16 offset, because that is what DirectWrite and
the text services framework speak. The rope is bytes. Neither is converted by
hand: `line_start`, `byte_to_utf16` and `utf16_to_byte` already walk the tree
correctly, so `byte_at` is three of their calls rather than a loop over
codepoints that would be wrong for astral characters on a Tuesday.
"""

from ide.doc import Doc, Snapshot
from ide.rope import Rope


# A thousand is the depth the sprint measures and comfortably more than
# anyone reaches by hand. It is a cap rather than a target: unbounded history
# on a long editing session is a memory leak with a nice name.
comptime HISTORY_DEPTH = 1000


def byte_at(rope: Rope, line: Int, col: Int) -> Int:
    """The byte offset of a caret at `line`, `col` UTF-16 units in.

    Args:
        rope: The document.
        line: The line, zero-based.
        col: The offset within it, in UTF-16 code units.

    Returns:
        The byte offset into the whole document.
    """
    var start = rope.line_start(line)
    if col <= 0:
        return start
    # Line-relative to document-relative and back, through the rope's own
    # walkers. A caret past the end of its line clamps to the line's end
    # rather than running into the next one.
    var at = rope.utf16_to_byte(rope.byte_to_utf16(start) + col)
    var most = start + len(rope.line(line).as_bytes())
    return at if at <= most else most


def caret_of_byte(rope: Rope, offset: Int) -> Tuple[Int, Int]:
    """Which line and UTF-16 offset a byte offset lands on.

    Args:
        rope: The document.
        offset: A byte offset.

    Returns:
        The line and the UTF-16 offset within it.
    """
    var line = rope.line_of_offset(offset)
    var start = rope.line_start(line)
    return (line, rope.byte_to_utf16(offset) - rope.byte_to_utf16(start))


def selection_bytes(doc: Doc) -> Tuple[Int, Int]:
    """The selected byte range, low end first.

    A selection made by dragging upwards has its anchor after its caret, and
    every caller would otherwise have to remember that.

    Args:
        doc: The document.

    Returns:
        The start and end byte offsets, in order.
    """
    var a = byte_at(doc.rope, doc.anchor_line, doc.anchor_col)
    var b = byte_at(doc.rope, doc.caret_line, doc.caret_col)
    return (a, b) if a <= b else (b, a)


def remember(mut doc: Doc):
    """Push the document onto the history, before it changes.

    Called by `apply` and nowhere else, so there is exactly one place where
    history is recorded and no operation can forget to.
    """
    doc.past.append(doc.snapshot())
    if len(doc.past) > HISTORY_DEPTH:
        # Drop the oldest. A list rather than a ring because the shift costs
        # a memcpy of pointers once every thousand edits, and a ring costs a
        # modulo in the reader forever.
        var kept = List[Snapshot]()
        for i in range(1, len(doc.past)):
            kept.append(doc.past[i].copy())
        doc.past = kept^
    # A new edit ends the future. Keeping it would mean a history that forks,
    # which no editor offers and nobody can hold in their head.
    doc.future.clear()


def apply(mut doc: Doc, start: Int, end: Int, var text: String) raises:
    """Replace a byte range with text, and put the caret after it.

    The one edit. Insert passes an empty range, delete passes empty text, and
    typing over a selection passes both a range and text -- so there is one
    place where the rope changes, the history is recorded, the revision is
    bumped and the caret is placed.

    Args:
        doc: The document.
        start: The first byte to replace.
        end: One past the last.
        text: What to put there.

    Raises:
        If the rope refuses.
    """
    remember(doc)
    var added = len(text.as_bytes())
    doc.rope = doc.rope.replace(start, end, text^)
    doc.revision += 1
    doc.dirty = True
    var where = caret_of_byte(doc.rope, start + added)
    doc.caret_line = where[0]
    doc.caret_col = where[1]
    doc.anchor_line = doc.caret_line
    doc.anchor_col = doc.caret_col


def insert(mut doc: Doc, var text: String) raises:
    """Type text at the caret, replacing the selection if there is one."""
    var range = selection_bytes(doc)
    apply(doc, range[0], range[1], text^)


def delete_selection(mut doc: Doc) raises -> Bool:
    """Remove the selection if there is one; say whether there was."""
    if not doc.has_selection():
        return False
    var range = selection_bytes(doc)
    apply(doc, range[0], range[1], String(""))
    return True


def backspace(mut doc: Doc) raises:
    """Delete the selection, or the cluster before the caret.

    Before the caret, not one byte and not one code unit: a byte would split
    a UTF-8 sequence and a code unit would leave half an emoji. The previous
    caret stop is what a person means by "the last thing I typed", and the
    rope's UTF-16 walk gives it.
    """
    if delete_selection(doc):
        return
    var at = byte_at(doc.rope, doc.caret_line, doc.caret_col)
    if at == 0:
        return
    var u16 = doc.rope.byte_to_utf16(at)
    # One code unit back, then back again if that landed on a low surrogate:
    # a surrogate pair is one thing to delete, not two.
    var back = u16 - 1
    var from_byte = doc.rope.utf16_to_byte(back)
    if from_byte >= at and back > 0:
        from_byte = doc.rope.utf16_to_byte(back - 1)
    apply(doc, from_byte, at, String(""))


def delete_forward(mut doc: Doc) raises:
    """Delete the selection, or the cluster after the caret."""
    if delete_selection(doc):
        return
    var at = byte_at(doc.rope, doc.caret_line, doc.caret_col)
    if at >= doc.rope.byte_length():
        return
    var u16 = doc.rope.byte_to_utf16(at)
    var to_byte = doc.rope.utf16_to_byte(u16 + 1)
    if to_byte <= at:
        to_byte = doc.rope.utf16_to_byte(u16 + 2)
    if to_byte > doc.rope.byte_length():
        to_byte = doc.rope.byte_length()
    apply(doc, at, to_byte, String(""))


comptime INDENT = 4
"""Spaces per level. Mojo is written with spaces and this fork's own tree has
no tabs in it; an editor that inserts one produces a file that looks right
here and wrong everywhere else."""


def leading_space(line: String) -> String:
    """The whitespace a line begins with, verbatim.

    Verbatim rather than counted, because a file that is indented with tabs
    should keep being indented with tabs even by an editor that would not have
    chosen them. Copying what is there cannot make a file inconsistent; a
    count and a re-render can.

    Args:
        line: The line.

    Returns:
        Its leading run of spaces and tabs.
    """
    var bytes = line.as_bytes()
    var i = 0
    while i < len(bytes):
        var c = Int(bytes[i])
        if c != 0x20 and c != 0x09:
            break
        i += 1
    return String(line[byte=0:i])


def opens_a_block(line: String) -> Bool:
    """Whether a line ends in a colon, ignoring a trailing comment.

    The rule that makes an indentation-significant language bearable to type:
    `def main():` and the next line should already be indented. The comment is
    stripped first so `if x:  # why` counts, and a colon inside a string does
    not -- `print("a:")` opens nothing.

    Args:
        line: The line.

    Returns:
        True when the next line belongs inside a new block.
    """
    var bytes = line.as_bytes()
    var n = len(bytes)
    var last = -1
    var i = 0
    var quote = 0
    while i < n:
        var c = Int(bytes[i])
        if quote != 0:
            if c == 0x5C:
                i += 2
                continue
            if c == quote:
                quote = 0
            i += 1
            continue
        if c == 0x22 or c == 0x27:
            quote = c
            i += 1
            continue
        if c == 0x23:  # a comment: nothing after it is code
            break
        if c != 0x20 and c != 0x09:
            last = c
        i += 1
    return last == 0x3A  # ':'


def newline(mut doc: Doc) raises:
    """Split the line at the caret, keeping the indentation.

    Two rules, and no more: the new line starts with whatever the old one
    started with, and one level deeper when the old one ended in a colon.
    Anything cleverer -- guessing dedents, re-indenting what is already there
    -- is an editor moving code a person did not ask it to move, and in a
    language where indentation is the syntax that is not a small thing to be
    wrong about.
    """
    var here = doc.rope.line(doc.caret_line)
    var indent = leading_space(here)
    if opens_a_block(here):
        indent += " " * INDENT
    # The caret's own column matters: splitting a line in the middle should
    # not carry the indentation of text that is staying behind. Only the part
    # of the indentation that is actually before the caret is copied.
    var units = _units_before_col(here, doc.caret_col)
    if units < indent.byte_length():
        var cut = String(indent[byte=0:units])
        indent = cut^
    insert(doc, String("\n") + indent)


def _units_before_col(line: String, col: Int) -> Int:
    """How many bytes of a line precede a UTF-16 column.

    Only ever asked about the leading whitespace, which is ASCII, so this is
    the simple walk rather than the general one.

    Args:
        line: The line.
        col: A UTF-16 offset into it.

    Returns:
        The byte offset, clamped to the line's length.
    """
    var n = line.byte_length()
    return n if col >= n else col


def undo(mut doc: Doc) raises -> Bool:
    """Step back one edit. Says whether there was one.

    The current document goes onto the future before the past comes off it,
    so redo is the same operation in the other direction and neither needs to
    know what the edit was.
    """
    if len(doc.past) == 0:
        return False
    doc.future.append(doc.snapshot())
    var was = doc.past.pop()
    doc.rope = was.rope.copy()
    doc.caret_line = was.caret_line
    doc.caret_col = was.caret_col
    doc.anchor_line = was.anchor_line
    doc.anchor_col = was.anchor_col
    doc.revision += 1
    doc.dirty = True
    return True


def redo(mut doc: Doc) raises -> Bool:
    """Step forward again. Says whether there was anywhere to go."""
    if len(doc.future) == 0:
        return False
    doc.past.append(doc.snapshot())
    var next = doc.future.pop()
    doc.rope = next.rope.copy()
    doc.caret_line = next.caret_line
    doc.caret_col = next.caret_col
    doc.anchor_line = next.anchor_line
    doc.anchor_col = next.anchor_col
    doc.revision += 1
    doc.dirty = True
    return True


# ===----------------------------------------------------------------------===#
# Moving the caret
#
# Left and right step by caret stops rather than by code units, for the same
# reason backspace does: an emoji is one thing to walk past. The rope's UTF-16
# walk supplies the stops, so nothing here counts bytes.
# ===----------------------------------------------------------------------===#


def move_to(mut doc: Doc, line: Int, col: Int, extend: Bool = False):
    """Put the caret somewhere, clamped, optionally dragging the selection.

    Args:
        doc: The document.
        line: The line to land on.
        col: The UTF-16 offset within it.
        extend: Keep the anchor where it is, so the selection grows.
    """
    var last = doc.rope.line_count() - 1
    var want = line
    if want > last:
        want = last
    if want < 0:
        want = 0
    doc.caret_line = want
    doc.caret_col = col if col > 0 else 0
    if not extend:
        doc.anchor_line = doc.caret_line
        doc.anchor_col = doc.caret_col


def move_horizontal(mut doc: Doc, by: Int, extend: Bool = False) raises:
    """One caret stop left or right, wrapping across line ends.

    Args:
        doc: The document.
        by: -1 for left, 1 for right.
        extend: Whether to drag the selection with it.
    """
    var at = byte_at(doc.rope, doc.caret_line, doc.caret_col)
    var u16 = doc.rope.byte_to_utf16(at)
    var want = u16 + by
    if want < 0:
        want = 0
    var total = doc.rope.utf16_length()
    if want > total:
        want = total
    var to_byte = doc.rope.utf16_to_byte(want)
    # A move that did not move landed inside a surrogate pair; go one further
    # in the same direction, which is where the caret stop actually is.
    if to_byte == at and want != u16:
        to_byte = doc.rope.utf16_to_byte(want + by)
    var where = caret_of_byte(doc.rope, to_byte)
    move_to(doc, where[0], where[1], extend)


def move_vertical(mut doc: Doc, by: Int, extend: Bool = False):
    """A line up or down, keeping the column where it can."""
    move_to(doc, doc.caret_line + by, doc.caret_col, extend)


def move_line_edge(mut doc: Doc, to_end: Bool, extend: Bool = False) raises:
    """Home and End: the start of the line, or its last caret stop."""
    if not to_end:
        move_to(doc, doc.caret_line, 0, extend)
        return
    var text = doc.rope.line(doc.caret_line)
    var units = 0
    for ch in text.codepoints():
        units += 2 if Int(ch) >= 0x10000 else 1
    move_to(doc, doc.caret_line, units, extend)


def select_all(mut doc: Doc) raises:
    """Anchor at the start, caret at the very end."""
    doc.anchor_line = 0
    doc.anchor_col = 0
    var last = doc.rope.line_count() - 1
    doc.caret_line = last
    var text = doc.rope.line(last)
    var units = 0
    for ch in text.codepoints():
        units += 2 if Int(ch) >= 0x10000 else 1
    doc.caret_col = units


def selected_text(doc: Doc) raises -> String:
    """Whatever is selected, or an empty string."""
    if not doc.has_selection():
        return String("")
    var range = selection_bytes(doc)
    return doc.rope.slice(range[0], range[1])
