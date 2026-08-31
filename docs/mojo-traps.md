# Traps this codebase has actually stood on

Not language complaints and not a style guide. Each of these cost real time in
`ide/`, each was found by a failure that pointed somewhere else, and each is
written down so the next person recognises the symptom rather than the cause.

## `with open(...)` does not close the file at the end of the block

The `FileHandle` is destroyed when the **function** returns, not when the
indentation ends. So this leaves the file open:

```mojo
with open(path, "w") as f:
    f.write(text)
# the handle is STILL open here
_ = MoveFileExW(temporary, path, MOVEFILE_REPLACE_EXISTING)   # fails
```

`MoveFileExW` returns `ERROR_SHARING_VIOLATION` (32), every time, reliably.
Isolated with a probe that did the same thing two ways in one scope:

    with-block, same scope, move error: 32
    explicit close, same scope, move error: 0

So a write that is followed by a rename must close explicitly:

```mojo
var f = open(path, "w")
f.write(text)
f.close()
```

This is invisible anywhere a file is only read, which is why every other
`with open` in `ide/` is fine and why this took a while to believe. Found
writing `ide/session.mojo`, whose whole job is write-then-rename.

## A constant from the metadata may be signed where the API is not

`INVALID_FILE_ATTRIBUTES` comes out of `windows_api.db` as `-1`.
`GetFileAttributesW` returns an unsigned 32-bit value. Comparing them directly
is a test that can never be true, so every path looks as though it exists:

```mojo
if attributes == winkb_constant["INVALID_FILE_ATTRIBUTES"]():   # never
```

Mask to the width the API actually returns. The metadata is right about the
bit pattern and says nothing about how you are going to read it.

## `Int(Pointer(to=x))` discards the origin

Correct in debug, silently wrong optimized: the optimizer is entitled to fold
away a value nothing is holding. Use `com_addr()`, which keeps a real
`Pointer`. Written up in full in
[addresses-and-optimization.md](addresses-and-optimization.md) — it cost an
afternoon and a blank window.

## Self-aliasing slice assignment is a compile error

```mojo
s = String(s[byte=0:n])        # error: aliasing values passed immutably
var cut = String(s[byte=0:n])  # this
s = cut^
```

The message names `args` and `String.__init__` and does not mention that the
problem is assigning a slice of a thing to itself.

## `.strip()` returns a span, not a `String`

Assigning it where a `String` is wanted fails with a conversion error about
`StringSpan` origins. Wrap it: `String(x.strip())`.

## `List[Int]` is `Copyable` but not `ImplicitlyCopyable`

A struct with one in it cannot have its copy constructor synthesized, so a
struct that must be `ImplicitlyCopyable` has to spell out
`__init__(out self, *, copy: Self)` by hand. `ide/session.mojo`'s `OpenFile`
does exactly this.

## The Bash tool eats backslash escapes in heredocs

Not Mojo's fault, but it has broken this tree more often than anything above.
Writing Mojo source through `cat <<'EOF'` turns `"\n"` into a real newline and
`"\\"` into `"\"`, producing unterminated strings and paths with control
characters in them — `Windows Kits\10\bin` arrived as `Windows Kits` plus two
backspace characters. Use the Write tool for source, or build the escape from
`chr(92)` in a Python script.

## `mojo.exe` refuses a source file with a byte-order mark

    subject.mojo:1:1: error: unexpected character
    def main():

with nothing visibly wrong on line 1. The three bytes are there and the
compiler will not have them.

This matters on Windows more than it sounds, because the obvious way to write
a file from PowerShell produces one:

```bash
'def main(): pass' | Set-Content -Path x.mojo -Encoding utf8
```

Windows PowerShell's `utf8` means UTF-8 *with* a BOM. Notepad's "UTF-8" did
too until recently. So a Mojo file created by the most natural command on the
platform does not compile, and the error names a character it does not print.

For a generated file, write it without one:

```bash
[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
```

Griddle hides a BOM rather than deleting it — `pipeutf8.without_bom` strips it
on the way in and `save` writes it back — so a `.txt` a person opened keeps
its mark. That is right for a text file and unhelpful for a `.mojo` one, which
will still not compile until the mark is gone. Worth knowing rather than
worth guessing at: an editor that silently rewrote the file would be worse.

One more, because it is the same mistake one level down: the BOM is *one*
codepoint, U+FEFF, whose UTF-8 encoding is EF BB BF. Writing `chr(0xEF)`,
`chr(0xBB)` and `chr(0xBF)` produces three codepoints and six bytes of
mojibake — `c3 af c2 bb c2 bf`. It cost a build to notice.
