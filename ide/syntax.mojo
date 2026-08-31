"""Colour, from a lexer that runs here rather than one that answers later.

Sprint 2.4. The language server can send semantic tokens -- it advertises the
capability -- and they are better than this: they know that `Com` is a struct
and `target` a variable, which no amount of local scanning can. But they arrive
after a parse, and a parse is most of a second on a cold file. An editor whose
text is grey until the server has an opinion feels broken for that second,
every time a file is opened. So the local lexer runs first and unconditionally.

Taken from MojoCocoa's `ide/gridview.mojo`, where it was written and where it
should keep being written. It is more careful than it looks and than a fresh
one would have been:

  - A line that STARTS inside a triple-quoted string is coloured as string up
    to the closing delimiter. A per-line lexer with nothing told it about the
    line before renders every continuation line of a docstring as code, which
    is the single most obvious way to look wrong.
  - Runs merge with the previous one when the colour matches, so a line of
    plain text is one run rather than eighty.
  - It walks bytes and allocates one Run per colour change. Their note records
    the shape it replaced -- a String per character, then the draw loop
    rebuilding those characters into runs with another append each -- and that
    this was running sixty lines' worth twice a second at idle, to blink a
    caret.

Both ports colour the same keywords, `let`, `fn` and `class` among them: each
fork revived them and an editor that greyed them out would be wrong about the
language it is for.

Taken unchanged, including `Run.cols`, which counts codepoints. DirectWrite
wants ranges in UTF-16 code units, and the two differ for anything outside the
basic plane -- so the conversion happens at the drawing site, from the exact
`byte_start` and `byte_len` the lexer also records, rather than by editing a
number this file is right about. A lexer shared between two ports is only
shared for as long as neither port edits it.
"""

comptime KIND_PLAIN = 0
comptime KIND_COMMENT = 1
comptime KIND_STRING = 2
comptime KIND_KEYWORD = 3
comptime KIND_NUMBER = 4


def _is_keyword(w: String) -> Bool:
    """cocoa-mojo's keywords, `let`, `fn` and `class` among them -- this fork
    revived the first two and made the third declare a real Objective-C
    class, and an editor that greys any of them out would be quietly wrong
    about the language it is for. The argument conventions (`imm`, `mut`,
    `out`, `deinit`, `where`) are contextual soft identifiers, coloured here
    on the same terms as each other."""
    return (
        w == "def" or w == "fn" or w == "let" or w == "var" or w == "class"
        or w == "struct"
        or w == "trait" or w == "comptime" or w == "alias" or w == "import"
        or w == "from" or w == "as" or w == "if" or w == "elif" or w == "else"
        or w == "while" or w == "for" or w == "in" or w == "return"
        or w == "raise" or w == "raises" or w == "try" or w == "except"
        or w == "with" or w == "yield" or w == "pass" or w == "break"
        or w == "continue" or w == "and" or w == "or" or w == "not"
        or w == "is" or w == "True" or w == "False" or w == "None"
        or w == "self" or w == "Self" or w == "imm" or w == "mut"
        or w == "out" or w == "deinit" or w == "ref" or w == "where"
    )


@fieldwise_init
struct Run(ImplicitlyCopyable, Movable):
    """One same-coloured stretch of a line: where it starts in columns and
    bytes, how far it runs in each, and its kind."""

    var col: Int
    var byte_start: Int
    var byte_len: Int
    var cols: Int
    var kind: Int


def _push_run(
    mut runs: List[Run],
    col: Int,
    byte_start: Int,
    byte_len: Int,
    cols: Int,
    kind: Int,
):
    """Append, merging with the previous run when the colour is the same."""
    let n = len(runs)
    if n > 0 and runs[n - 1].kind == kind:
        runs[n - 1].byte_len += byte_len
        runs[n - 1].cols += cols
        return
    runs.append(Run(col, byte_start, byte_len, cols, kind))


def _char_width(b: Int) -> Int:
    """Bytes in the UTF-8 sequence this lead byte starts."""
    if b >= 0xF0:
        return 4
    if b >= 0xE0:
        return 3
    if b >= 0xC0:
        return 2
    return 1


def triple_state_after(line: String, start_inside: Bool) -> Bool:
    """Whether the NEXT line starts inside a triple-quoted string.

    The lexer is per-line by design; this is the one bit of state a
    docstring needs carried across lines. Both quote styles count, and a
    backslash escapes inside a string the way the lexer already honours.
    """
    let bytes = line.as_bytes()
    let n = len(bytes)
    var inside = start_inside
    var quote = 0x22  # the delimiter of the string we are inside
    var i = 0
    while i < n:
        let b = Int(bytes[i])
        if inside:
            if b == 0x5C:
                i += 2
                continue
            if (
                b == quote
                and i + 2 < n
                and Int(bytes[i + 1]) == quote
                and Int(bytes[i + 2]) == quote
            ):
                inside = False
                i += 3
                continue
            i += 1
            continue
        if (b == 0x22 or b == 0x27) and i + 2 < n:
            if Int(bytes[i + 1]) == b and Int(bytes[i + 2]) == b:
                inside = True
                quote = b
                i += 3
                continue
        if b == 0x22 or b == 0x27:
            # An ordinary string: skip it whole so its contents cannot fake
            # a triple delimiter.
            let q = b
            var esc = False
            i += 1
            while i < n:
                let c = Int(bytes[i])
                i += 1
                if esc:
                    esc = False
                elif c == 0x5C:
                    esc = True
                elif c == q:
                    break
            continue
        if b == 0x23:
            return inside  # comment: nothing after it counts
        i += 1
    return inside


def highlight_runs(line: String, in_triple: Bool = False) -> List[Run]:
    """The line as same-coloured runs.

    A lexer rather than a parser, and deliberately: this is on the draw path
    and has to be right about comments, strings and keywords without knowing
    anything else. It walks bytes and allocates one Run per colour change --
    the old shape built a String PER CHARACTER and a kind per character, and
    the draw loop then rebuilt those characters into runs with another String
    append each. Sixty lines of that per frame, twice a second at idle for
    the caret blink, was the editor lexing the world to blink a cursor.
    """
    var runs = List[Run]()
    let bytes = line.as_bytes()
    let n = len(bytes)
    var i = 0
    var col = 0
    # A line that STARTS inside a docstring is string-coloured up to the
    # closing delimiter, or wholly, and the lexer resumes after it. This is
    # the fix for continuation lines rendering as code: the lexer was
    # per-line and nothing told it the line began mid-string.
    if in_triple:
        var j = 0
        var cols = 0
        var closed = False
        while j < n:
            let c = Int(bytes[j])
            if c == 0x5C:
                var w = 1
                if j + 1 < n:
                    w = 2
                var k = j
                while k < j + w:
                    if (Int(bytes[k]) & 0xC0) != 0x80:
                        cols += 1
                    k += 1
                j += w
                continue
            if (
                c == 0x22
                and j + 2 < n
                and Int(bytes[j + 1]) == 0x22
                and Int(bytes[j + 2]) == 0x22
            ):
                cols += 3
                j += 3
                closed = True
                break
            if (Int(bytes[j]) & 0xC0) != 0x80:
                cols += 1
            j += 1
        if not closed and j >= n and n >= 3:
            # The delimiter may sit at the very end of the line.
            if (
                Int(bytes[n - 3]) == 0x22
                and Int(bytes[n - 2]) == 0x22
                and Int(bytes[n - 1]) == 0x22
            ):
                closed = True
        _push_run(runs, col, 0, j, cols, KIND_STRING)
        col += cols
        i = j
    while i < n:
        let b = Int(bytes[i])
        if b == 0x23:  # '#' -- comment to end of line, nothing else after
            var cols = 0
            var j = i
            while j < n:
                if (Int(bytes[j]) & 0xC0) != 0x80:
                    cols += 1
                j += 1
            _push_run(runs, col, i, n - i, cols, KIND_COMMENT)
            break
        if (
            (b == 0x22 or b == 0x27)
            and i + 2 < n
            and Int(bytes[i + 1]) == b
            and Int(bytes[i + 2]) == b
        ):
            # A triple-quoted string opening here. Colour to its close on
            # this line, or to the end -- the carried state (threaded by the
            # draw loop through triple_state_after) covers the lines after.
            let q3 = b
            var j = i + 3
            var cols = 3
            while j < n:
                let c = Int(bytes[j])
                if c == 0x5C and j + 1 < n:
                    if (Int(bytes[j]) & 0xC0) != 0x80:
                        cols += 1
                    if (Int(bytes[j + 1]) & 0xC0) != 0x80:
                        cols += 1
                    j += 2
                    continue
                if (
                    c == q3
                    and j + 2 < n
                    and Int(bytes[j + 1]) == q3
                    and Int(bytes[j + 2]) == q3
                ):
                    cols += 3
                    j += 3
                    break
                if (c & 0xC0) != 0x80:
                    cols += 1
                j += 1
            _push_run(runs, col, i, j - i, cols, KIND_STRING)
            col += cols
            i = j
            continue
        if b == 0x22 or b == 0x27:  # a string, escapes included
            let quote = b
            var j = i + 1
            var cols = 1
            var escaped = False
            while j < n:
                let c = Int(bytes[j])
                if (c & 0xC0) != 0x80:
                    cols += 1
                j += 1
                if escaped:
                    escaped = False
                elif c == 0x5C:
                    escaped = True
                elif c == quote:
                    break
            _push_run(runs, col, i, j - i, cols, KIND_STRING)
            col += cols
            i = j
            continue
        if b >= 0x30 and b <= 0x39:  # a number, with . _ and suffix letters
            var j = i
            var cols = 0
            while j < n:
                let c = Int(bytes[j])
                if not (
                    (c >= 0x30 and c <= 0x39)
                    or c == 0x2E
                    or c == 0x5F
                    or (c >= 0x61 and c <= 0x7A)
                    or (c >= 0x41 and c <= 0x5A)
                ):
                    break
                cols += 1
                j += 1
            _push_run(runs, col, i, j - i, cols, KIND_NUMBER)
            col += cols
            i = j
            continue
        let ident = (
            (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) or b == 0x5F
        )
        if ident:
            var j = i
            while j < n:
                let c = Int(bytes[j])
                if not (
                    (c >= 0x41 and c <= 0x5A)
                    or (c >= 0x61 and c <= 0x7A)
                    or (c >= 0x30 and c <= 0x39)
                    or c == 0x5F
                ):
                    break
                j += 1
            let word = String(line[byte=i:j])
            let kind = KIND_KEYWORD if _is_keyword(word) else KIND_PLAIN
            _push_run(runs, col, i, j - i, j - i, kind)
            col += j - i
            i = j
            continue
        # Anything else is one plain character, however many bytes wide.
        let w = _char_width(b)
        _push_run(runs, col, i, min(w, n - i), 1, KIND_PLAIN)
        col += 1
        i += w
    return runs^


def highlight(line: String) -> List[Int]:
    """One kind per character -- the runs, expanded. The draw loop reads the
    runs directly; this shape remains for the tests, which assert per-character
    and would hide an off-by-one if they asserted runs."""
    var kinds = List[Int]()
    for r in highlight_runs(line):
        for _ in range(r.cols):
            kinds.append(r.kind)
    return kinds^
