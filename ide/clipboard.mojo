"""The Windows clipboard, in the two shapes an editor actually needs.

Griddle had no cut, no copy and no paste, which is a strange thing for a text
editor to be missing and a very short thing to fix -- the clipboard is four
calls and a memory handle. It is short and it is also the place where careful
programs go wrong, so this module is mostly comments about the three ways it
goes wrong.

THE OWNERSHIP HANDOVER. `SetClipboardData` takes an `HGLOBAL` and, when it
succeeds, takes the memory with it: the clipboard owns the block from that
moment and will free it itself the next time somebody empties the clipboard.
A caller that frees it too is freeing memory it no longer owns, which is a
heap corruption that shows up somewhere else entirely. A caller that does not
free it when `SetClipboardData` *fails* has leaked the block, because in that
case ownership never moved. Both mistakes are one line, they are the same
line, and only the return value distinguishes them. That is why the failure
path here calls `GlobalFree` and the success path deliberately does not, and
why this paragraph exists.

WHO ELSE HAS THE CLIPBOARD. There is one clipboard on the desktop and
`OpenClipboard` is a lock on it. Any process can hold it, and several of the
ones that hold it briefly are things everybody runs -- clipboard managers,
remote desktop, the terminal, an anti-virus scanner reading what was just
copied. A copy that fails outright because Explorer happened to be looking is
not a bug a user will report as a race; it is a bug they will report as
"copy doesn't work sometimes". So the open is retried a handful of times with
a short pause, and every path out of a successful open closes the clipboard,
including the ones that raise.

LINE ENDINGS. The clipboard's convention is CRLF and Griddle's rope holds LF.
Neither of those is negotiable -- CRLF is what Notepad and the shell and every
Windows text box expect to receive, and LF is what every line-counting routine
in the editor assumes it will find -- so the conversion happens here, at the
boundary, in both directions. Skipping it is invisible in a self-test and
extremely visible the first time somebody pastes into Notepad and gets one
enormous line, or pastes out of it and finds a box at the end of every line.

TEXT. `CF_UNICODETEXT` is UTF-16 and the editor is UTF-8, so both directions
convert, surrogate pairs included. An emoji is one codepoint here and two code
units there; a conversion that assumes one unit per character copies half an
emoji and pastes a replacement character, which is exactly the kind of defect
that survives a review because the test string was ASCII.
"""

from std.ffi import c_int
from std.memory import Pointer
from std.sys._winkb import winkb_constant

from ide.win32 import win32


# How hard to try for the clipboard before giving up. Six attempts twenty
# milliseconds apart is about a tenth of a second of patience, which is longer
# than any well-behaved holder keeps it and short enough that a genuinely
# stuck clipboard does not freeze the keystroke that asked.
comptime OPEN_ATTEMPTS = 6
comptime OPEN_PAUSE_MS = 20

# A ceiling on what a paste will read out of somebody else's memory. Fifty
# million UTF-16 units is a hundred megabytes of text, far more than anyone
# copies on purpose, and having a bound at all means a handle whose contents
# are not NUL-terminated cannot walk this process off the end of the block.
comptime MAX_UNITS = 50_000_000


# ── The primitives ──────────────────────────────────────────────────────────


def set_clipboard_text(text: String, owner: Int = 0) raises -> Bool:
    """Put text on the clipboard as `CF_UNICODETEXT`.

    Args:
        text: What to copy, UTF-8, with LF line endings as the rope holds
            them. It is converted to UTF-16 with CRLF endings on the way out.
        owner: The window that will own the clipboard, or 0 for none. Zero is
            allowed and means the clipboard is associated with the current
            task rather than a window; a window that intends to serve delayed
            rendering later would pass its own handle.

    Returns:
        True if the text is now on the clipboard. False if the clipboard could
        not be opened after several tries, or if Windows refused the data --
        both of which are conditions a caller shows in the status bar rather
        than crashing over.

    Raises:
        If an entry point cannot be resolved, which would mean a Windows
        without USER32 or KERNEL32 and is not a condition to plan for.
    """
    var OpenClipboard = win32[
        def (Int) thin abi("C") -> c_int, "OpenClipboard"
    ]()
    var CloseClipboard = win32[
        def () thin abi("C") -> c_int, "CloseClipboard"
    ]()
    var EmptyClipboard = win32[
        def () thin abi("C") -> c_int, "EmptyClipboard"
    ]()
    var SetClipboardData = win32[
        def (UInt32, Int) thin abi("C") -> Int, "SetClipboardData"
    ]()
    var GlobalAlloc = win32[
        def (UInt32, Int) thin abi("C") -> Int, "GlobalAlloc"
    ]()
    var GlobalLock = win32[def (Int) thin abi("C") -> Int, "GlobalLock"]()
    var GlobalUnlock = win32[def (Int) thin abi("C") -> c_int, "GlobalUnlock"]()
    var GlobalFree = win32[def (Int) thin abi("C") -> Int, "GlobalFree"]()

    # Converted before the clipboard is opened. Everything between the open
    # and the close is a lock held against the whole desktop, so the only work
    # that belongs in there is the work that has to be.
    var units = _utf16_crlf(text)

    if not _open(OpenClipboard, owner):
        return False

    # GMEM_MOVEABLE, not GMEM_FIXED: the clipboard requires a moveable handle,
    # because what it hands other processes is a handle and not an address.
    # The size includes the terminating NUL, which `_utf16_crlf` appends --
    # `CF_UNICODETEXT` is defined as a NUL-terminated string and a reader that
    # trusts that is entitled to.
    var handle = GlobalAlloc(
        UInt32(winkb_constant["GMEM_MOVEABLE"]()), len(units) * 2
    )
    if handle == 0:
        _ = CloseClipboard()
        return False

    var address = GlobalLock(handle)
    if address == 0:
        # Ours still: nothing has been offered to the clipboard yet.
        _ = GlobalFree(handle)
        _ = CloseClipboard()
        return False

    var out = Pointer[UInt16, MutAnyOrigin](unsafe_from_address=address)
    for i in range(len(units)):
        out.unsafe_offset(i)[] = units[i]
    _ = GlobalUnlock(handle)
    # `units` must outlive the copy above; Mojo would otherwise be free to end
    # it at its last subscript, which is inside the loop.
    _ = units

    # Emptied only now, after the block is allocated and filled.
    # `SetClipboardData` requires that we have emptied the clipboard first --
    # that is what makes us its owner -- but emptying it before the
    # allocation would mean an out-of-memory copy destroys whatever the user
    # had copied before, which is a worse outcome than a copy that quietly
    # does nothing.
    _ = EmptyClipboard()

    var placed = SetClipboardData(
        UInt32(winkb_constant["CF_UNICODETEXT"]()), handle
    )
    if placed == 0:
        # The handover did not happen, so the block is still ours and freeing
        # it is required. See the module docstring: this line and the absence
        # of it below are the whole ownership rule.
        _ = GlobalFree(handle)
        _ = CloseClipboard()
        return False

    # Deliberately no GlobalFree here. The clipboard owns `handle` from this
    # point and will free it itself; freeing it here would corrupt the heap of
    # whichever process pastes next.
    _ = CloseClipboard()
    return True


def clipboard_text(owner: Int = 0) raises -> String:
    """The clipboard's text, UTF-8, with LF line endings.

    Args:
        owner: The window opening the clipboard, or 0 for none.

    Returns:
        The text, or an empty string when the clipboard holds no text at all.
        Empty is not an error and must not be reported as one: a user who
        copied a bitmap and then pressed Ctrl+V has done nothing wrong, and an
        editor that raises at them for it is broken in a way the ordinary case
        will hit constantly.

    Raises:
        If an entry point cannot be resolved.
    """
    var OpenClipboard = win32[
        def (Int) thin abi("C") -> c_int, "OpenClipboard"
    ]()
    var CloseClipboard = win32[
        def () thin abi("C") -> c_int, "CloseClipboard"
    ]()
    var GetClipboardData = win32[
        def (UInt32) thin abi("C") -> Int, "GetClipboardData"
    ]()
    var IsClipboardFormatAvailable = win32[
        def (UInt32) thin abi("C") -> c_int, "IsClipboardFormatAvailable"
    ]()
    var GlobalLock = win32[def (Int) thin abi("C") -> Int, "GlobalLock"]()
    var GlobalUnlock = win32[def (Int) thin abi("C") -> c_int, "GlobalUnlock"]()
    var GlobalSize = win32[def (Int) thin abi("C") -> Int, "GlobalSize"]()

    var format = UInt32(winkb_constant["CF_UNICODETEXT"]())

    # Asked before opening, because this needs no lock. A clipboard holding a
    # screenshot is the common case for "paste did nothing", and answering it
    # without taking the desktop-wide lock away from whoever else wants it is
    # simply better manners.
    if IsClipboardFormatAvailable(format) == 0:
        return String("")

    if not _open(OpenClipboard, owner):
        return String("")

    # The format can have gone away between the question and the lock; and a
    # handle of zero is also how `GetClipboardData` reports a format that is
    # advertised but rendered on demand by a process that has since exited.
    var handle = GetClipboardData(format)
    if handle == 0:
        _ = CloseClipboard()
        return String("")

    var address = GlobalLock(handle)
    if address == 0:
        _ = CloseClipboard()
        return String("")

    # `GlobalSize` is the bound, the NUL is the terminator, and both are
    # needed: the size alone would include the terminator and any slack the
    # allocator rounded up to, and the terminator alone would trust another
    # process to have written one.
    var limit = GlobalSize(handle) // 2
    if limit > MAX_UNITS:
        limit = MAX_UNITS

    var text = _string_lf(address, limit)

    _ = GlobalUnlock(handle)
    # Nothing is freed here. The handle belongs to the clipboard, not to us,
    # and it stops being valid the moment the clipboard closes -- which is why
    # the string above is built while it is still open rather than after.
    _ = CloseClipboard()
    return text^


# ── The clipboard lock ──────────────────────────────────────────────────────


def _open(
    OpenClipboard: def (Int) thin abi("C") -> c_int,
    owner: Int,
) raises -> Bool:
    """Open the clipboard, waiting a little for whoever else has it.

    Args:
        OpenClipboard: The entry point, resolved by the caller so that a
            failure to resolve it is reported once rather than per attempt.
        owner: The window to associate the clipboard with, or 0.

    Returns:
        True if the clipboard is now open and the caller owes a
        `CloseClipboard`. False if it stayed busy, in which case there is
        nothing to close.

    Raises:
        If `Sleep` cannot be resolved.
    """
    var Sleep = win32[def (UInt32) thin abi("C") -> NoneType, "Sleep"]()
    for attempt in range(OPEN_ATTEMPTS):
        if OpenClipboard(owner) != 0:
            return True
        # No pause after the last attempt: it would be a pause before
        # returning failure, which helps nobody.
        if attempt + 1 < OPEN_ATTEMPTS:
            Sleep(UInt32(OPEN_PAUSE_MS))
    return False


# ── The two conversions ─────────────────────────────────────────────────────


def _utf16_crlf(text: String) -> List[UInt16]:
    """UTF-16 code units for `text`, every line ending widened to CRLF.

    The rule is exactly the mirror of `_string_lf`: whatever a line break was
    spelled as -- LF, CRLF, or a bare CR -- one CRLF comes out. Stating it
    that way rather than as "insert a CR before each LF" is what keeps two
    things from going wrong. Text that already held CRLF must not become
    CRCRLF, which pastes as a blank line between every line; and a bare CR
    must not travel as a bare CR, which every Windows text box draws as a box
    and treats as no line break at all.

    Args:
        text: UTF-8 text as the rope holds it, LF endings and all.

    Returns:
        The code units, terminated by a zero. `CF_UNICODETEXT` is defined as
        a NUL-terminated string, so the terminator is part of the data and
        not an afterthought.
    """
    var out = List[UInt16]()
    var previous = 0
    for ch in text.codepoints():
        var v = Int(ch)

        if v == 0x0D:
            # A CR, whether it stands alone or begins a CRLF, is one break.
            out.append(UInt16(0x0D))
            out.append(UInt16(0x0A))
            previous = v
            continue

        if v == 0x0A:
            # The LF of a CRLF whose break was already emitted above.
            if previous != 0x0D:
                out.append(UInt16(0x0D))
                out.append(UInt16(0x0A))
            previous = v
            continue

        if v >= 0x10000:
            # Above the basic plane a codepoint is a surrogate pair. An emoji
            # is the everyday example and the one that catches this.
            var u = v - 0x10000
            out.append(UInt16(0xD800 + (u >> 10)))
            out.append(UInt16(0xDC00 + (u & 0x3FF)))
        else:
            out.append(UInt16(v))
        previous = v

    out.append(0)
    return out^


def _string_lf(buffer: Int, limit: Int) -> String:
    """A String from UTF-16 at `buffer`, CRLF endings narrowed to LF.

    Stops at the first NUL or after `limit` units, whichever comes first.

    Args:
        buffer: The address of the code units.
        limit: How many units may be read at most.

    Returns:
        UTF-8 text with LF line endings, ready for the rope.
    """
    var out = String("")
    var p = Pointer[UInt16, MutAnyOrigin](unsafe_from_address=buffer)
    var i = 0
    while i < limit:
        var unit = Int(p.unsafe_offset(i)[])
        if unit == 0:
            break

        if unit == 0x0D:
            # CRLF collapses to LF, and a lone CR becomes one too. The second
            # half of that is a decision rather than a rule: nothing in the
            # editor can usefully hold a bare carriage return -- it would draw
            # as a box and count as no line break at all -- and old-Mac text
            # does still turn up in the wild. Turning it into the line break
            # it was meant to be is what every other editor does.
            if i + 1 < limit and Int(p.unsafe_offset(i + 1)[]) == 0x0A:
                i += 1
            out += chr(0x0A)
            i += 1
            continue

        if unit >= 0xD800 and unit <= 0xDBFF and i + 1 < limit:
            var low = Int(p.unsafe_offset(i + 1)[])
            if low >= 0xDC00 and low <= 0xDFFF:
                out += chr(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
                i += 2
                continue

        if unit >= 0xD800 and unit <= 0xDFFF:
            # A surrogate with no partner. UTF-16 permits the byte pattern and
            # UTF-8 has no encoding for it, so the alternative to substituting
            # here is producing a String whose bytes are not valid UTF-8 --
            # which everything downstream, the rope included, is entitled to
            # assume they are.
            out += chr(0xFFFD)
            i += 1
            continue

        out += chr(unit)
        i += 1
    return out^
