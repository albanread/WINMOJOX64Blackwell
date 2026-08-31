# Lexer tests. The colouring runs on the draw path and its output is turned
# straight into DirectWrite ranges, so a wrong offset here is a wrong colour on
# screen -- and a screenshot is a slow, coarse way to find out which byte the
# lexer disagreed about. These assert the runs directly.
#
# The byte offsets get their own cases because `_colour_layout` converts
# `byte_start` and `byte_len` into UTF-16 code units, and that conversion is
# only correct if the lexer's byte arithmetic is. `cols` counts codepoints and
# the two differ the moment a line contains anything outside the basic plane.
from syntax import (
    KIND_COMMENT,
    KIND_KEYWORD,
    KIND_NUMBER,
    KIND_PLAIN,
    KIND_STRING,
    highlight,
    highlight_runs,
    triple_state_after,
)


def name_of(kind: Int) -> String:
    if kind == KIND_COMMENT:
        return String("comment")
    if kind == KIND_STRING:
        return String("string")
    if kind == KIND_KEYWORD:
        return String("keyword")
    if kind == KIND_NUMBER:
        return String("number")
    return String("plain")


def check_int(name: String, got: Int, want: Int) -> Int:
    if got == want:
        print("  OK  ", name, "=", got)
        return 0
    print("  FAIL", name, "-- got", got, "want", want)
    return 1


def kind_at(line: String, col: Int) raises -> Int:
    """The colour of one column, through the expanded form the tests use."""
    var kinds = highlight(line)
    if col < 0 or col >= len(kinds):
        return -1
    return kinds[col]


def check_kind(name: String, line: String, col: Int, want: Int) raises -> Int:
    var got = kind_at(line, col)
    if got == want:
        print("  OK  ", name, "->", name_of(want))
        return 0
    print(
        "  FAIL", name, "-- col", col, "of", repr(line),
        "is", name_of(got), "want", name_of(want),
    )
    return 1


def check_span(
    name: String, line: String, index: Int, start: Int, length: Int
) raises -> Int:
    """A run's exact byte span, which is what the drawing code consumes."""
    var runs = highlight_runs(line)
    if index >= len(runs):
        print("  FAIL", name, "-- only", len(runs), "runs, wanted", index + 1)
        return 1
    var r = runs[index]
    if r.byte_start == start and r.byte_len == length:
        print("  OK  ", name, "bytes", start, "+", length)
        return 0
    print(
        "  FAIL", name, "-- run", index, "is bytes", r.byte_start, "+",
        r.byte_len, "want", start, "+", length,
    )
    return 1


def main() raises:
    var failures = 0

    print("syntax: keywords")
    failures += check_kind("def", String("def main():"), 0, KIND_KEYWORD)
    # The three this fork revived. An editor that greyed them out would be
    # wrong about the language it is for.
    failures += check_kind("fn", String("fn f(): pass"), 0, KIND_KEYWORD)
    failures += check_kind("let", String("let x = 1"), 0, KIND_KEYWORD)
    failures += check_kind("class", String("class T(IUnknown):"), 0, KIND_KEYWORD)
    failures += check_kind("comptime", String("comptime N = 4"), 0, KIND_KEYWORD)
    # A keyword is a whole word or it is nothing. `define` starting with `def`
    # is the mistake a substring match makes.
    failures += check_kind("define is not def", String("define = 1"), 0, KIND_PLAIN)
    failures += check_kind("classy is not class", String("classy = 1"), 0, KIND_PLAIN)
    failures += check_kind("undef is not def", String("undef = 1"), 0, KIND_PLAIN)
    # And the name after a keyword is not itself one.
    failures += check_kind("the name after def", String("def main():"), 4, KIND_PLAIN)

    print("syntax: comments")
    failures += check_kind("hash starts one", String("x = 1  # why"), 7, KIND_COMMENT)
    failures += check_kind("and runs to the end", String("x = 1  # why"), 11, KIND_COMMENT)
    failures += check_kind("code before it is not", String("x = 1  # why"), 0, KIND_PLAIN)
    # A hash inside a string is text. This is the case that makes a lexer a
    # lexer rather than a search for '#'.
    failures += check_kind("hash in a string", String('s = "a # b"'), 7, KIND_STRING)

    print("syntax: strings")
    failures += check_kind("double quoted", String('s = "hi"'), 4, KIND_STRING)
    failures += check_kind("single quoted", String("s = 'hi'"), 4, KIND_STRING)
    failures += check_kind("closing quote included", String('s = "hi"'), 7, KIND_STRING)
    failures += check_kind("after the string", String('s = "hi" + t'), 9, KIND_PLAIN)
    # An escaped quote does not end the string.
    failures += check_kind("escaped quote", String('s = "a\\"b" + t'), 8, KIND_STRING)
    # A quote of the other kind inside does not end it either.
    failures += check_kind("other quote inside", String("s = \"it's\""), 6, KIND_STRING)

    print("syntax: numbers")
    failures += check_kind("integer", String("x = 42"), 4, KIND_NUMBER)
    failures += check_kind("float", String("x = 3.14"), 6, KIND_NUMBER)
    failures += check_kind("underscored", String("x = 1_000"), 6, KIND_NUMBER)
    failures += check_kind("hex", String("x = 0x1F"), 6, KIND_NUMBER)
    # A number is not a number when it is part of a name: `x1` is one word.
    failures += check_kind("digit inside a name", String("x1 = 2"), 1, KIND_PLAIN)

    print("syntax: triple-quoted strings")
    var doc = String('    """Summary."""')
    failures += check_kind("opens", doc, 4, KIND_STRING)
    failures += check_kind("closes on the same line", doc, 17, KIND_STRING)
    # The case a per-line lexer gets wrong: a line that BEGINS inside a
    # docstring is string all through, even when it looks like code. Asserted
    # on the runs rather than through `highlight`, which has no way to be told
    # the line began mid-string -- the draw loop threads that state itself.
    var inside = String("    def not_really(): pass")
    var cont = highlight_runs(inside, True)
    failures += check_int("continuation is one run", len(cont), 1)
    failures += check_int(
        "and that run is string",
        cont[0].kind if len(cont) > 0 else -1,
        KIND_STRING,
    )
    failures += check_int(
        "covering the whole line",
        cont[0].byte_len if len(cont) > 0 else -1,
        len(inside.as_bytes()),
    )
    # The property, stated directly: the SAME line lexes two ways depending on
    # the state carried into it. Told it is inside a docstring it is one string
    # run; told it is not, `def` is a keyword and there are several runs. A
    # lexer that ignored `in_triple` would give the same answer twice.
    var not_inside = highlight_runs(inside, False)
    failures += check_int(
        "the same line lexes differently",
        Int(len(not_inside) > 1),
        1,
    )
    failures += check_kind(
        "outside a docstring def is a keyword", inside, 4, KIND_KEYWORD
    )
    # And the lexer resumes after the closing delimiter.
    var closes = String('    end."""  x = 1')
    var after = highlight_runs(closes, True)
    failures += check_int("resumes after the close", Int(len(after) > 1), 1)

    print("syntax: the state carried between lines")
    failures += check_int(
        "an opening docstring", Int(triple_state_after(String('x = """a'), False)), 1
    )
    failures += check_int(
        "a closing docstring", Int(triple_state_after(String('a"""'), True)), 0
    )
    failures += check_int(
        "one that opens and closes",
        Int(triple_state_after(String('x = """a"""'), False)),
        0,
    )
    failures += check_int(
        "plain code carries nothing",
        Int(triple_state_after(String("x = 1"), False)),
        0,
    )
    # An ordinary string containing three quotes must not open a docstring.
    failures += check_int(
        "a quote inside a string",
        Int(triple_state_after(String('s = "a\\"b"'), False)),
        0,
    )

    print("syntax: byte offsets, which become DirectWrite ranges")
    # Run 0 of `def main():` is the keyword: bytes 0..3.
    failures += check_span("keyword span", String("def main():"), 0, 0, 3)
    # A comment's span reaches the end of the line and no further.
    var commented = String("x = 1  # why")
    failures += check_span("comment span", commented, 3, 7, 5)
    # The one that matters: a line with multi-byte characters before the run.
    # `s = "` is 5 bytes, each `é` is 2, then `"` and a space: the hash is at
    # byte 11 where a column count would say 9. The byte offset is what the
    # UTF-16 range conversion starts from, so it is the one to assert.
    var wide = String("s = \"éé\" # t")
    var runs = highlight_runs(wide)
    var comment_start = -1
    for r in runs:
        if r.kind == KIND_COMMENT:
            comment_start = r.byte_start
    failures += check_int("comment after two 2-byte chars", comment_start, 11)

    print("syntax: whole lines")
    # Every column of a plain line is plain, and there is exactly one run for
    # it -- the merge is what keeps a line of text from becoming eighty runs.
    var plain = String("        total = count + extra")
    var plain_runs = highlight_runs(plain)
    var non_plain = 0
    for r in plain_runs:
        if r.kind != KIND_PLAIN:
            non_plain += 1
    failures += check_int("no colour in plain text", non_plain, 0)
    failures += check_int("and it is one merged run", len(plain_runs), 1)
    # An empty line has no runs and must not raise.
    failures += check_int("empty line", len(highlight_runs(String(""))), 0)

    print()
    if failures == 0:
        print("syntax OK")
    else:
        print("syntax FAILED:", failures)
        raise Error("syntax tests failed")
