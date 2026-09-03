"""One line to type into, which the editor has never had.

Every feature that needs a word from a person -- find, replace, go to line,
go to a symbol, install a package -- has until now been reachable only from
the agent surface, because the only place in Griddle a person could type was
the document. Ctrl+F searched for whatever the last search was, which is a
strange thing for a key called Find to do, and go-to-symbol had to be told
its name through `--cmd`.

This is that missing line. It draws where the status bar is, which is where
an editor has always put a question it wants answered now: `:` in vi, the
minibuffer in Emacs, the search bar in every browser. Taking over a line that
already exists rather than adding a region means no layout changes, no
resize arithmetic, and nothing moves on screen when it opens -- the status
text is replaced by the question and comes back when the question is
answered.

WHAT IT IS NOT. Not a widget, not an edit control, and not a second text
engine: it holds a String and a caret measured in codepoints, and every key
that reaches it does one obvious thing to those two. A one-line field is not
a document -- no selection, no undo, no wrapping, no IME composition -- and
building it out of the rope and the caret machinery would have meant carrying
all of that into a place that wants none of it. Fifty lines of String
handling is the smaller lie.

The kind is what makes one line serve six features. `accept` hands the text
back with the kind beside it, and the caller -- `ide/window.mojo`, which is
the only place that knows what a find or a goto means -- decides what to do
with it. This module never calls the editor.
"""

from std.sys._globals import named_global


# ── What is being asked ─────────────────────────────────────────────────────
# A number rather than an enum so the state can live in a `named_global`,
# which holds an Int. Zero is "nothing is being asked", so the ordinary state
# of the editor needs no separate flag.
comptime ASK_NOTHING = 0
comptime ASK_FIND = 1
comptime ASK_REPLACE_WITH = 2
comptime ASK_GOTO = 3
comptime ASK_SYMBOL = 4
comptime ASK_PACKAGE = 5
comptime ASK_OPEN = 6
comptime ASK_RENAME = 7

comptime g_kind = named_global["prompt.kind", Int]
comptime g_caret = named_global["prompt.caret", Int]

# The label and the text. Lists of one for the reason `ide/symbols.mojo`
# gives for its uri: a zero-initialised String is not a valid String, and a
# zero-initialised List is a valid empty one, so state that starts life as a
# global has to be a list before it can be a string.
comptime g_label = named_global["prompt.label", List[String]]
comptime g_text = named_global["prompt.text", List[String]]

# What was typed last time, per kind, so reopening a prompt offers it again.
# A person who searched for `caret_line`, looked at four matches and pressed
# Ctrl+F again meant to search for something near it, not to start from
# nothing.
comptime g_last = named_global["prompt.last", List[String]]


def _slot(mut cell: List[String]) -> String:
    return cell[0] if len(cell) > 0 else String("")


def _put(mut cell: List[String], var value: String):
    if len(cell) == 0:
        cell.append(value^)
    else:
        cell[0] = value^


def _remember(kind: Int, var value: String):
    """Keep the answer to one kind of question."""
    var last = g_last()
    while len(last[]) <= kind:
        last[].append(String(""))
    last[][kind] = value^


def recalled(kind: Int) -> String:
    """The last answer to this kind of question, or empty.

    Args:
        kind: One of the ASK_ constants.

    Returns:
        What was typed there last time.
    """
    var last = g_last()
    return last[][kind] if kind < len(last[]) else String("")


# ── Opening and closing ─────────────────────────────────────────────────────
def ask(kind: Int, var label: String, var initial: String):
    """Start asking for something.

    Args:
        kind: One of the ASK_ constants; what the answer is for.
        label: The question, drawn before the text.
        initial: What to start with, already selected in spirit -- the caret
            goes to the end of it, so typing continues rather than replaces.
            Passing the previous answer is what makes Ctrl+F twice in a row
            useful.
    """
    g_kind()[] = kind
    _put(g_label()[], label^)
    var start = initial^
    g_caret()[] = _length(start)
    _put(g_text()[], start^)


def cancel():
    """Stop asking, and keep nothing."""
    g_kind()[] = ASK_NOTHING


def accept() -> Tuple[Int, String]:
    """Stop asking, and hand back what was typed.

    Returns:
        The kind and the text. The kind is `ASK_NOTHING` when nothing was
        being asked, which a caller can treat as "this key was not mine".
    """
    var kind = g_kind()[]
    var text = _slot(g_text()[])
    g_kind()[] = ASK_NOTHING
    if kind != ASK_NOTHING:
        _remember(kind, String(text))
    return (kind, text^)


def asking() -> Bool:
    """Whether the prompt is open and owns the keyboard.

    Returns:
        True while a question is on screen.
    """
    return g_kind()[] != ASK_NOTHING


def asking_kind() -> Int:
    """Which question is open.

    Returns:
        One of the ASK_ constants.
    """
    return g_kind()[]


def prompt_label() -> String:
    """The question, for the status line to draw.

    Returns:
        The label, or empty when nothing is being asked.
    """
    return _slot(g_label()[]) if asking() else String("")


def prompt_text() -> String:
    """What has been typed so far.

    Returns:
        The text, or empty.
    """
    return _slot(g_text()[])


def prompt_caret() -> Int:
    """Where the caret is, in codepoints from the start.

    Returns:
        The position.
    """
    return g_caret()[]


# ── Typing into it ──────────────────────────────────────────────────────────
def put(codepoint: Int):
    """Insert one character at the caret.

    Args:
        codepoint: What was typed, as a Unicode scalar. Control characters
            are ignored here rather than by the caller, so every path in has
            the same rule.
    """
    if not asking():
        return
    if codepoint < 0x20 or codepoint == 0x7F:
        return
    var text = _slot(g_text()[])
    var at = _byte_of(text, g_caret()[])
    _put(g_text()[], String(text[byte=:at]) + chr(codepoint) + text[byte=at:])
    g_caret()[] += 1


def backspace():
    """Delete the character before the caret."""
    if not asking() or g_caret()[] <= 0:
        return
    var text = _slot(g_text()[])
    var start = _byte_of(text, g_caret()[] - 1)
    var finish = _byte_of(text, g_caret()[])
    _put(g_text()[], String(text[byte=:start]) + text[byte=finish:])
    g_caret()[] -= 1


def delete_forward():
    """Delete the character after the caret."""
    if not asking():
        return
    var text = _slot(g_text()[])
    if g_caret()[] >= _length(text):
        return
    var start = _byte_of(text, g_caret()[])
    var finish = _byte_of(text, g_caret()[] + 1)
    _put(g_text()[], String(text[byte=:start]) + text[byte=finish:])


def move(by: Int):
    """Move the caret, clamped to the text.

    Args:
        by: How far, negative for left.
    """
    if not asking():
        return
    var where = g_caret()[] + by
    var limit = _length(_slot(g_text()[]))
    if where < 0:
        where = 0
    if where > limit:
        where = limit
    g_caret()[] = where


def move_to_start():
    """Home."""
    g_caret()[] = 0


def move_to_end():
    """End."""
    g_caret()[] = _length(_slot(g_text()[]))


def clear():
    """Empty the line, keeping the question open."""
    if not asking():
        return
    _put(g_text()[], String(""))
    g_caret()[] = 0


# ── Counting characters rather than bytes ───────────────────────────────────
# The caret is in codepoints because that is what an arrow key moves by. A
# person who typed an accented letter presses Left once to get past it, and a
# caret in bytes would need two presses and would land in the middle of a
# character on the way.
def _length(s: String) -> Int:
    var n = 0
    for _ in s.codepoints():
        n += 1
    return n


def _byte_of(s: String, position: Int) -> Int:
    if position <= 0:
        return 0
    var seen = 0
    var at = 0
    var bytes = s.as_bytes()
    while at < len(bytes):
        # A UTF-8 continuation byte is 10xxxxxx; every other byte starts a
        # character. Counting the starts is counting the characters.
        if (Int(bytes[at]) & 0xC0) != 0x80:
            if seen == position:
                return at
            seen += 1
        at += 1
    return len(bytes)


def prompt_report() -> String:
    """The prompt as text, so a check can read it without a screenshot.

    Returns:
        `prompt <label> | <text> | caret <n>`, or that nothing is being asked.
    """
    if not asking():
        return String("no prompt")
    return (
        String("prompt ") + prompt_label() + " | " + prompt_text()
        + " | caret " + String(prompt_caret())
    )
