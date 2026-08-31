# Decoding a byte stream that arrives in fixed-size chunks.
#
# Three readers -- the debug adapter, the language server, and the compiler's
# output -- each read up to 64 KB from a pipe and turned the chunk straight
# into a String. Each of them reasoned carefully about NUL termination and
# not at all about where a codepoint ends, and a pipe does not deliver whole
# characters: a read boundary lands wherever 65536 bytes fall, which is
# sometimes in the middle of a multi-byte sequence.
#
# The String that comes back is then not valid UTF-8, and nothing complains
# until something iterates it. Roast crashed stepping the debugger with
#
#     `Optional.value()` called on empty `Optional`
#
# from std/collections/string/iterators.mojo, where the grapheme iterator
# unwraps `Codepoint.unsafe_decode_utf8_codepoint` -- which answers None for
# exactly this. It is data-dependent, so it crashes on the session where the
# boundary happens to split a character and not on the one before it.
#
# Replacing bad bytes would be wrong here: two of the three streams carry
# JSON that is about to be parsed, and a replacement character inside a
# string literal is corruption with a friendly face. The partial sequence is
# not damaged, only early, so it is held back and prepended to the next read.

from std.memory import OpaquePointer


def _needed_for(lead: Int) -> Int:
    """How many bytes the sequence starting with this lead byte occupies,
    or 0 if it is not a lead byte."""
    if lead & 0x80 == 0:
        return 1
    if lead & 0xE0 == 0xC0:
        return 2
    if lead & 0xF0 == 0xE0:
        return 3
    if lead & 0xF8 == 0xF0:
        return 4
    return 0


def complete_prefix(bytes: List[UInt8], n: Int) -> Int:
    """How many of the first `n` bytes end on a complete UTF-8 sequence.

    Walks back over at most three continuation bytes to the lead byte that
    owns them. If that sequence is not all here yet, the answer is the
    offset of the lead byte -- everything before it is whole.

    A byte that is not valid UTF-8 at all is left where it is: this holds
    back what is merely early, and does not try to repair what is wrong.
    """
    if n <= 0:
        return 0
    var k = n - 1
    var seen = 0
    while k >= 0 and seen < 3:
        let b = Int(bytes[k])
        if b & 0xC0 == 0x80:
            k -= 1
            seen += 1
            continue
        let need = _needed_for(b)
        if need == 0:
            return n
        return k if seen + 1 < need else n
    return n


def take_chunk(mut pending: List[UInt8], buf: OpaquePointer, n: Int) -> String:
    """The decodable part of `pending` + the first `n` bytes of `buf`.

    Whatever trailing bytes do not yet form a whole character are left in
    `pending` for the next read. `pending` is a byte list and not a String
    on purpose: a String holding half a codepoint is the exact thing this
    function exists to prevent, and it would be just as invalid held by us
    as it was held by the caller.
    """
    let src = buf.unsafe_bitcast[UInt8]()
    for i in range(n):
        pending.append(src[i])

    let total = len(pending)
    let cut = complete_prefix(pending, total)
    let text = String(StringSlice(unsafe_from_utf8=Span(pending)[0:cut]))
    # Keep only the tail. At most three bytes survive a read, so this is a
    # copy of nothing in every case that matters.
    var rest = List[UInt8]()
    for i in range(cut, total):
        rest.append(pending[i])
    pending = rest^
    return text^


def sanitized(text: String) -> String:
    """`text` with any byte that is not valid UTF-8 replaced by U+FFFD.

    For DISPLAY only, and the opposite policy from `take_chunk` on purpose.
    A partial sequence at a read boundary is early, so it is held back and
    completed. A variable's value out of the debuggee is not early -- it is
    whatever bytes were at that address, and there is no later read that
    completes them. Uninitialised memory rendered as a `String` is exactly
    that, and it reaches the locals view as arbitrary bytes.

    Left alone it crashes: the grapheme iterator unwraps an empty Optional
    from `Codepoint.unsafe_decode_utf8_codepoint`, which is what killed
    Roast when the locals view was drawn while stepping.
    """
    let raw = text.as_bytes()
    let n = len(raw)
    var out = List[UInt8]()
    var i = 0
    while i < n:
        let b = Int(raw[i])
        let need = _needed_for(b)
        # A continuation byte with no lead, or a byte that leads nothing.
        if need == 0:
            out.append(0xEF)
            out.append(0xBF)
            out.append(0xBD)
            i += 1
            continue
        # A sequence that runs off the end, or whose continuations are not
        # continuations, is replaced whole rather than byte by byte.
        var ok = i + need <= n
        if ok:
            for j in range(1, need):
                if Int(raw[i + j]) & 0xC0 != 0x80:
                    ok = False
                    break
        if not ok:
            out.append(0xEF)
            out.append(0xBF)
            out.append(0xBD)
            i += 1
            continue
        for j in range(need):
            out.append(raw[i + j])
        i += need
    return String(StringSlice(unsafe_from_utf8=Span(out)[0 : len(out)]))


def without_bom(var text: String) -> Tuple[String, Bool]:
    """The text with any leading byte-order mark removed, and whether one was.

    A UTF-8 BOM is EF BB BF. It carries no information here -- the file is
    UTF-8 either way -- but Windows writes one from Notepad and from
    PowerShell's `Set-Content -Encoding utf8`, so a good half of the files a
    person opens on this platform begin with three bytes that are not text.
    Shown as content they put every column on the first line out by three,
    and they made the first line of a script file unrunnable: `build` with a
    BOM in front of it is not the verb `build`.

    Whether there was one is returned rather than discarded so a save can put
    it back. An editor that quietly strips a BOM has rewritten a file the
    person only meant to read.

    Args:
        text: The file's contents, as read.

    Returns:
        The text without the mark, and True when one was removed.
    """
    var bytes = text.as_bytes()
    if (
        len(bytes) >= 3
        and bytes[0] == UInt8(0xEF)
        and bytes[1] == UInt8(0xBB)
        and bytes[2] == UInt8(0xBF)
    ):
        return (String(text[byte=3:]), True)
    return (text^, False)


def file_starts_with_bom(path: String) -> Bool:
    """Whether a file on disk begins with a byte-order mark.

    Asked of the file rather than carried out of the read, because the two
    places that load a document return different things -- one a `Rope`, one a
    `Doc` -- and threading a second value out of both is more machinery than
    reading three bytes again.

    Args:
        path: The file.

    Returns:
        True when the first three bytes are EF BB BF.
    """
    try:
        var handle = open(path, "r")
        var head = handle.read(3)
        handle.close()
        return without_bom(head^)[1]
    except:
        return False
