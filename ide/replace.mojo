"""Replacing text: one at a time, or all of them at once.

Griddle could find text and could not change it, which made the find bar a
reading tool. This is the other half. It works on a `Rope` and nothing else --
no window, no view, no `griddle.mojo` -- because a replace is a pure function
of the text and the two strings, and because importing the window from here
would close a cycle: the window already imports the editing modules.

Matching is literal, case-sensitive and byte for byte. There is no regex here
and there is not meant to be one: the thing a person does forty times an hour
is change one identifier to another, and a literal matcher is the one that
never surprises them by treating a dot in a filename as a wildcard.

Three ways a replace-all hangs an editor, all three closed here and each
marked at the code that closes it:

  * An empty needle matches at every position forever.
  * A replacement containing the needle -- "a" becoming "aa" -- feeds itself
    if the output is rescanned.
  * Overlapping matches double-counted, so "aa" in "aaaa" replaces three
    times where a person counted two.

The rope's text is UTF-8, and none of this decodes it. It does not have to:
UTF-8 is self-synchronising, meaning lead bytes (0x00-0x7F, 0xC2-0xF4) and
continuation bytes (0x80-0xBF) are drawn from disjoint ranges. A well-formed
needle therefore cannot occur as a byte sequence starting or ending part-way
through some other character's encoding -- there is no alignment at which its
first byte, a lead byte, could match a continuation byte. So a byte-for-byte
match always begins and ends on a codepoint boundary, and splicing at those
offsets can never cut a multi-byte sequence in half. That is why there is no
boundary check anywhere below, and it is worth saying out loud rather than
leaving the next reader to convince themselves the omission was deliberate.
"""

from ide.rope import Rope


def replace_next(
    mut rope: Rope, needle: String, replacement: String, from_byte: Int
) raises -> Int:
    """Replace the first match at or after a byte offset.

    This does not wrap. `find_next` in ide/find.mojo does, because moving the
    caret back to the top of the file is free and reversible; silently editing
    text above where somebody is looking is neither. A Replace button that
    wants wrapping asks for it by calling again from zero, and then the
    wrapping is the caller's decision and visible in the caller's code.

    Args:
        rope: The document, replaced in place with the new tree. The old one
            is still valid and still shares everything untouched, so an undo
            stack that kept it costs nothing.
        needle: What to look for, matched literally.
        replacement: What to put there.
        from_byte: Where to start looking.

    Returns:
        The byte offset just past the text written, so a caller can pass it
        straight back in to reach the following match. -1 if there was no
        match, in which case the rope is untouched.

    Raises:
        If the rope's own walks do.
    """
    var width = needle.byte_length()
    # An empty needle matches at every offset, so "replace the next one" would
    # insert forever without ever moving. Nothing is the honest answer.
    if width == 0:
        return -1

    var start = from_byte
    if start < 0:
        start = 0
    var hit = rope.find(needle, start)
    if hit < 0:
        return -1

    var text = String(copy=replacement)
    var updated = rope.replace(hit, hit + width, text^)
    rope = updated^
    # Past what was written, not past what was matched. Returning the match's
    # old end would land inside the replacement whenever the replacement is
    # longer, and a caller looping on this would then rescan its own output --
    # the "a" -> "aa" runaway, arrived at from the other direction.
    return hit + replacement.byte_length()


def replace_all(
    mut rope: Rope, needle: String, replacement: String
) raises -> Int:
    """Replace every match in the document.

    Args:
        rope: The document, replaced in place with the new tree.
        needle: What to look for, matched literally.
        replacement: What to put there.

    Returns:
        How many replacements were made.

    Raises:
        If the rope's own walks do.
    """
    var width = needle.byte_length()
    # The classic hang. An empty needle matches between every pair of bytes,
    # so the obvious loop inserts and never advances; the editor stops
    # answering and the document grows until memory runs out.
    if width == 0:
        return 0

    var hits = _match_offsets(rope, needle)
    if len(hits) == 0:
        return 0

    var first = hits[0]
    var last_end = hits[len(hits) - 1] + width

    # One scan, one read, one rebuild -- not one rebuild per match. A rope
    # replace is O(log n) and cheap, but it is O(log n) *and it builds a new
    # tree*: doing it 37 times to change 37 words is 37 tree rebuilds and 37
    # intermediate ropes, every one of which is thrown away by the next. So
    # the offsets come out of a single tree walk, the affected span comes out
    # in a second walk as one flat String, the new text is spliced in that
    # flat String, and the tree is rebuilt exactly once at the end.
    #
    # The span is [first match, end of last match) rather than the whole
    # document, so text before and after all the matches is not copied out and
    # copied back, and a replace-all whose matches happen to sit inside one
    # leaf still takes the rope's O(log n) path-copy route.
    var span = rope.slice(first, last_end)
    var rebuilt = String()
    var at = 0
    for i in range(len(hits)):
        var relative = hits[i] - first
        if relative > at:
            rebuilt += span[byte=at:relative]
        rebuilt += replacement
        # Advance past the *needle* in the source, which is what makes a
        # replacement containing the needle safe: the output is never looked
        # at again, so "a" -> "aa" writes two bytes and moves on rather than
        # finding its own "a" and growing forever.
        at = relative + width
    # `at` is now exactly the span's length: the span was cut to end at the
    # last match's end, so there is no tail to append. Appending one anyway
    # would be harmless but would suggest to a reader that the span might
    # extend past the last match, which it cannot.

    var updated = rope.replace(first, last_end, rebuilt^)
    rope = updated^
    return len(hits)


def count_matches(rope: Rope, needle: String) raises -> Int:
    """How many replacements a replace-all would make, changing nothing.

    This is what a "Replace All (37)" label is made of, and it has to agree
    with what `replace_all` then does or the label is a lie. Both count the
    same way, through `_match_offsets`, which is the only reason they agree.

    Args:
        rope: The document, unchanged.
        needle: What to look for, matched literally.

    Returns:
        The number of non-overlapping matches.

    Raises:
        If the rope's own walks do.
    """
    if needle.byte_length() == 0:
        return 0
    return len(_match_offsets(rope, needle))


def preview_replacements(
    rope: Rope, needle: String, replacement: String, limit: Int = 50
) raises -> List[String]:
    """What each replacement would do, as lines a person can read.

    Replace-all across a project is the edit people most regret, and the
    reason is always the same: they agreed to a count without seeing a single
    case. Rows read "LINE: before  ->  after" with a one-based LINE, matching
    what the gutter shows, so a wrong guess is visible before it is made
    rather than after.

    This does not collect every match first. It walks forward one match at a
    time and stops at `limit`, so previewing a needle with two million matches
    costs the same as previewing one with fifty -- nobody reads past the first
    screenful anyway, and building the other 1,999,950 rows would freeze the
    dialog it is meant to fill.

    Args:
        rope: The document, unchanged.
        needle: What to look for, matched literally.
        replacement: What would be put there.
        limit: At most this many rows.

    Returns:
        Up to `limit` rows, in document order.

    Raises:
        If the rope's own walks do.
    """
    var rows = List[String]()
    var width = needle.byte_length()
    # Same empty-needle guard, same reason: without it this fills the list to
    # `limit` with identical rows describing an edit that would never finish.
    if width == 0 or limit <= 0:
        return rows^

    var total = rope.byte_length()
    var at = 0
    while len(rows) < limit:
        var hit = rope.find(needle, at)
        if hit < 0:
            break

        var line_index = rope.line_of_offset(hit)
        var line_start = rope.line_start(line_index)
        var before = rope.line(line_index)

        var low = hit - line_start
        var high = low + width
        # A needle containing a newline matches across lines, and only its
        # first line is being shown. Clipping keeps the row honest about the
        # part of it that lives on this line instead of slicing past the end
        # of the string, which would be a crash rather than a preview.
        if high > before.byte_length():
            high = before.byte_length()

        var after = String(before[byte=0:low])
        after += replacement
        after += before[byte=high : before.byte_length()]

        var row = String(line_index + 1)
        row += ": "
        row += _single_line(before)
        row += "  ->  "
        row += _single_line(after)
        rows.append(row^)

        # Resume after the needle, never one byte on. One byte on would report
        # three replacements for "aa" in "aaaa" while `replace_all` makes two,
        # and a preview that disagrees with the edit is worse than no preview.
        at = hit + width
        if at >= total:
            break
    return rows^


def _match_offsets(rope: Rope, needle: String) raises -> List[Int]:
    """Byte offsets of every non-overlapping match, in document order.

    The single definition of "a match" that `replace_all` and `count_matches`
    both use. Two functions counting independently is how a confirmation
    dialog ends up promising 37 and delivering 39.

    `find_all_in` is one tree walk for the whole document -- what this is
    built on rather than a loop over `find`, which walks from the root each
    time and would make this O(matches x document). But it advances one byte
    per hit, so it reports *overlapping* matches: "aa" in "aaaa" comes back as
    offsets 0, 1 and 2. A replace cannot use the middle one, because by the
    time the match at 0 has been rewritten the bytes at 1 are gone. So a hit
    counts only if it begins at or after the end of the last one kept, which
    is the same rule the eye applies reading left to right.

    Args:
        rope: The document.
        needle: What to look for, matched literally. Assumed non-empty; the
            callers check, and this returns nothing if they did not.

    Returns:
        Offsets in increasing order, each at least `needle` long apart.

    Raises:
        If the rope's own walk does.
    """
    var found = List[Int]()
    var width = needle.byte_length()
    if width == 0:
        return found^

    var raw = rope.find_all_in(needle, 0, rope.byte_length())
    var next_allowed = 0
    for i in range(len(raw)):
        var hit = raw[i]
        if hit >= next_allowed:
            found.append(hit)
            next_allowed = hit + width
    return found^


def _single_line(text: String) raises -> String:
    """A string with its line breaks and tabs shown rather than obeyed.

    A preview row is one row. If a replacement contains a newline -- and
    turning a long argument list into several lines is a real thing people
    replace text to do -- then pasting it in raw would break one row into
    three and destroy the alignment that makes the list scannable. Showing the
    escape is both compact and closer to what was actually typed.

    Args:
        text: The line, before or after.

    Returns:
        The same text on one line.

    Raises:
        If the string operations do.
    """
    # Each step reads a fresh value into a fresh name. Writing this as
    # `text = text.replace(...)` would be assigning a slice of a value into
    # the value being sliced, which Mojo rejects outright.
    var no_return = text.replace("\r", "\\r")
    var no_newline = no_return.replace("\n", "\\n")
    var no_tab = no_newline.replace("\t", "\\t")
    return no_tab^
