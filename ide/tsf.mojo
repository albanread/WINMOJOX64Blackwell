"""The text store: how Windows types into this editor.

Sprint 1.5, and the sprint the `class` keyword was built for. Text Services
Framework is how every input method on Windows -- Pinyin, Japanese IME,
handwriting, voice, and the ordinary dead keys and AltGr of a European
keyboard layout -- reaches an application. An editor that handles `WM_CHAR`
and stops there works for English and quietly fails for most of the world.

TSF does not send messages. It asks the application to implement
`ITextStoreACP`, a twenty-six method interface, and then *calls* it: to take a
lock, read a range of text, replace a range, ask where the caret is, ask where
a character is on screen so a candidate window can be placed beneath it. The
application is the server. This file is that server.

Which is why it is the showcase. Twenty-six COM methods, implemented in Mojo,
with the vtable in metadata slot order, the atomic refcount, the IID-routed
QueryInterface and the HRESULT trampolines all synthesised from a `class`
declaration -- and not one slot number, IID or vtable offset written by hand
anywhere below.

Two things the exercise taught, both worth having found:

**Arity was a wall, and it should not have been.** Eight of these methods take
more than four arguments and `GetText` takes nine, against a class surface
that stopped at four -- not by design, but because five trampolines had been
written and nobody had needed a sixth. The sprint plan said these would drop
to the raw `slot[]` form. Writing `com_tramp5` through `com_tramp9` was one
generated patch and a better answer. See `spikes/com/s20_class_wide_arity`.

**A class method answers S_OK or E_FAIL, and nothing else.** The trampoline
turns a clean return into zero and a raise into `E_FAIL`, so an interface that
uses specific HRESULTs as part of its contract -- `TS_E_INVALIDPOS` for a
range that does not exist, `TS_S_ASYNC` for a lock that will be granted later
-- cannot express them through the sugar. That is a real limit. It does not
bite here, because every one of those cases can be avoided rather than
reported: ranges are clamped to the document instead of refused, and locks are
granted synchronously instead of deferred. A store that wanted to defer a lock
would need the raw form. Written down because the next interface may not have
that luxury.
"""

from std.ffi import c_int
from std.memory import OpaquePointer, Pointer
from std.sys.info import size_of
from std.sys._com import ComPtr, com_addr, com_method_of, _guid_bytes
from std.sys.com import Com, co_create
from std.sys._winkb import (
    winkb_constant,
    winkb_interface_iid,
    winkb_struct_size,
)

from ide.chrome import Layout
from ide.doc import Doc
from ide.edit import apply, byte_at, caret_of_byte
from ide.gridview import GUTTER_W
from ide.rope import Rope
from ide.win32 import POINT, RECT, win32
from ide.window import doc_of


# ===----------------------------------------------------------------------===#
# The structures TSF passes across the boundary
#
# Every one asserted against the metadata at compile time. TSF writes into
# these through pointers we hand it, so a layout that disagrees with Windows
# is memory corruption in the input path -- the least debuggable place in an
# editor, because the corruption arrives from another process's IME.
# ===----------------------------------------------------------------------===#


@fieldwise_init
struct TS_STATUS(Defaultable, ImplicitlyCopyable, Movable):
    """What the store can currently do."""

    var dwDynamicFlags: UInt32
    var dwStaticFlags: UInt32

    def __init__(out self):
        """Editable, and not read-only."""
        self.dwDynamicFlags = 0
        self.dwStaticFlags = 0


@fieldwise_init
struct TS_SELECTIONSTYLE(Defaultable, ImplicitlyCopyable, Movable):
    """Which end of a selection is the active one."""

    var ase: UInt32
    var fInterimChar: Int32

    def __init__(out self):
        """The end is active, and this is not an interim character."""
        self.ase = 0
        self.fInterimChar = 0


@fieldwise_init
struct TS_SELECTION_ACP(Defaultable, ImplicitlyCopyable, Movable):
    """A selection, in absolute character positions."""

    var acpStart: Int32
    var acpEnd: Int32
    var style: TS_SELECTIONSTYLE

    def __init__(out self):
        """An empty selection at the start."""
        self.acpStart = 0
        self.acpEnd = 0
        self.style = TS_SELECTIONSTYLE()


@fieldwise_init
struct TS_TEXTCHANGE(Defaultable, ImplicitlyCopyable, Movable):
    """What a replacement did, so the sink can follow along."""

    var acpStart: Int32
    var acpOldEnd: Int32
    var acpNewEnd: Int32

    def __init__(out self):
        """Nothing changed."""
        self.acpStart = 0
        self.acpOldEnd = 0
        self.acpNewEnd = 0


@fieldwise_init
struct TS_RUNINFO(Defaultable, ImplicitlyCopyable, Movable):
    """A run of text or of hidden content. This store has only the former."""

    var uCount: UInt32
    var type: UInt32

    def __init__(out self):
        """An empty run of plain text."""
        self.uCount = 0
        self.type = 0


# ===----------------------------------------------------------------------===#
# Positions
#
# TSF counts in absolute character positions: UTF-16 code units from the start
# of the document, ignoring lines entirely. The editor counts in a line and an
# offset within it. Both are UTF-16 -- which is why the caret was defined in
# code units back in sprint 1.3 rather than in characters -- so the conversion
# is a walk of the rope and never a re-encoding.
# ===----------------------------------------------------------------------===#


def acp_of_caret(rope: Rope, line: Int, col: Int) -> Int:
    """The absolute character position of a caret."""
    return rope.byte_to_utf16(byte_at(rope, line, col))


def caret_of_acp(rope: Rope, acp: Int) -> Tuple[Int, Int]:
    """The line and offset an absolute character position lands on."""
    var want = acp
    if want < 0:
        want = 0
    var most = rope.utf16_length()
    if want > most:
        want = most
    return caret_of_byte(rope, rope.utf16_to_byte(want))


def utf16_of(text: String) -> List[UInt16]:
    """UTF-16 code units for a string, surrogate pairs and all."""
    var out = List[UInt16]()
    for ch in text.codepoints():
        var v = Int(ch)
        if v >= 0x10000:
            var u = v - 0x10000
            out.append(UInt16(0xD800 + (u >> 10)))
            out.append(UInt16(0xDC00 + (u & 0x3FF)))
        else:
            out.append(UInt16(v))
    return out^


def string_of_utf16(buffer: Int, units: Int) -> String:
    """A string from a UTF-16 buffer, joining surrogate pairs."""
    var out = String("")
    var p = Pointer[UInt16, MutAnyOrigin](unsafe_from_address=buffer)
    var i = 0
    while i < units:
        var unit = Int(p.unsafe_offset(i)[])
        if unit >= 0xD800 and unit <= 0xDBFF and i + 1 < units:
            var low = Int(p.unsafe_offset(i + 1)[])
            if low >= 0xDC00 and low <= 0xDFFF:
                out += chr(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
                i += 2
                continue
        out += chr(unit)
        i += 1
    return out^


def sizes_agree() raises:
    """Every structure this file passes to Windows, checked against Windows."""
    comptime assert (
        size_of[TS_STATUS]() == winkb_struct_size["TS_STATUS"]()
    ), "TS_STATUS does not match Windows"
    comptime assert (
        size_of[TS_SELECTION_ACP]()
        == winkb_struct_size["TS_SELECTION_ACP"]()
    ), "TS_SELECTION_ACP does not match Windows"
    comptime assert (
        size_of[TS_TEXTCHANGE]() == winkb_struct_size["TS_TEXTCHANGE"]()
    ), "TS_TEXTCHANGE does not match Windows"
    comptime assert (
        size_of[TS_RUNINFO]() == winkb_struct_size["TS_RUNINFO"]()
    ), "TS_RUNINFO does not match Windows"


# ===----------------------------------------------------------------------===#
# The store
#
# Twenty-six methods, in metadata slot order, none of which is written here.
# `class TextStore(ITextStoreACP)` is the whole declaration; the vtable, the
# refcount, the QueryInterface and the HRESULT adapters come out of it.
#
# The store holds a window handle rather than a document. The document lives
# behind the HWND like everything else in this editor, so a store that
# outlives a document -- which TSF's own reference counting makes possible --
# finds that out at the call rather than dereferencing a stale pointer.
# ===----------------------------------------------------------------------===#


class TextStore(ITextStoreACP):
    var hwnd: Int
    # The sink TSF advised us of: how the store tells the input method that
    # text or selection changed underneath it. Zero until AdviseSink.
    var sink: Int
    var sink_mask: UInt32
    # Which lock is held, as TS_LF_READ or TS_LF_READWRITE, or zero for none.
    # TSF's contract is that nothing may read or write the document outside a
    # lock, and that the store is what enforces it.
    var lock: Int

    # ---- the lock protocol ---------------------------------------------

    def RequestLock(mut self, flags: UInt32, result: Int) raises:
        """Grant a document lock, synchronously, for the length of the call.

        The whole of TSF's concurrency model is here. An input method asks
        for a lock, the store calls back into it with the lock held, and the
        method does all its reading and writing inside that callback. Nothing
        is queued and nothing is asynchronous.

        A store may also defer -- answer TS_S_ASYNC now and grant later --
        and that is the one thing this store cannot express, because a class
        method returns S_OK or E_FAIL and nothing else. Granting immediately
        is correct, simpler, and what an editor with a single-threaded
        document should do anyway.
        """
        var out = Pointer[Int32, MutAnyOrigin](unsafe_from_address=result)
        if self.sink == 0:
            out[] = Int32(winkb_constant["TS_E_NOLOCK"]())
            return
        if self.lock != 0:
            # Already inside a lock: re-entering would let an input method
            # observe a document halfway through its own edit.
            out[] = Int32(winkb_constant["TS_E_SYNCHRONOUS"]())
            return

        self.lock = Int(flags)
        var sink = OpaquePointer[MutUntrackedOrigin](
            unsafe_from_address=self.sink
        )
        var granted = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], UInt32
            ) thin abi("C") -> Int32,
            "ITextStoreACPSink",
            "OnLockGranted",
        ](sink)(sink, flags)
        self.lock = 0
        out[] = granted

    def GetStatus(mut self, status: Int) raises:
        """Editable, and not a transitory document."""
        var out = Pointer[TS_STATUS, MutAnyOrigin](unsafe_from_address=status)
        out[] = TS_STATUS()

    def AdviseSink(mut self, iid: Int, unknown: Int, mask: UInt32) raises:
        """Take the sink TSF wants told about changes.

        The pointer arrives as an IUnknown and has to be asked for the sink
        interface; keeping the IUnknown and calling sink methods through it
        would dispatch into whatever the IUnknown vtable holds at those slots.
        """
        if unknown == 0:
            raise Error("AdviseSink was given nothing to advise")
        self.release_sink()
        var unk = OpaquePointer[MutUntrackedOrigin](unsafe_from_address=unknown)
        var wanted = _guid_bytes(
            String(winkb_interface_iid["ITextStoreACPSink"]())
        )
        var out = Int(0)
        var hr = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin],
                Int,
                Pointer[Int, MutAnyOrigin],
            ) thin abi("C") -> Int32,
            "IUnknown",
            "QueryInterface",
        ](unk)(unk, Int(wanted.unsafe_ptr()), com_addr(out))
        _ = wanted
        if hr != 0 or out == 0:
            raise Error("that sink is not an ITextStoreACPSink")
        # QueryInterface already counted a reference for us; adopting it is
        # what UnadviseSink gives back.
        self.sink = out
        self.sink_mask = mask

    def UnadviseSink(mut self, unknown: Int) raises:
        """Give the sink back."""
        self.release_sink()

    def release_sink(mut self):
        """Drop our reference to the sink, if we hold one.

        A helper, not a COM method -- no interface declares this name, so the
        class desugar leaves it an ordinary method of the struct. That rule is
        what lets a class hold helpers at all.
        """
        if self.sink == 0:
            return
        var sink = OpaquePointer[MutUntrackedOrigin](
            unsafe_from_address=self.sink
        )
        try:
            _ = com_method_of[
                def (
                    OpaquePointer[MutUntrackedOrigin]
                ) thin abi("C") -> UInt32,
                "IUnknown",
                "Release",
            ](sink)(sink)
        except:
            pass
        self.sink = 0
        self.sink_mask = 0

    # ---- reading the document ------------------------------------------

    def GetEndACP(mut self, end: Int) raises:
        """How long the document is, in UTF-16 code units."""
        var doc = self.document()
        Pointer[Int32, MutAnyOrigin](unsafe_from_address=end)[] = Int32(
            doc[].rope.utf16_length()
        )

    def GetSelection(
        mut self, index: UInt32, count: UInt32, out_sel: Int, fetched: Int
    ) raises:
        """Where the caret and the anchor are.

        One selection, always: this editor has no multiple cursors yet, and
        answering a count of one to every request is what a single-selection
        store does. `index` is TS_DEFAULT_SELECTION or zero; both mean the
        same thing here.
        """
        var got = Pointer[UInt32, MutAnyOrigin](unsafe_from_address=fetched)
        got[] = 0
        if count == 0 or out_sel == 0:
            return
        var doc = self.document()
        var anchor = acp_of_caret(
            doc[].rope, doc[].anchor_line, doc[].anchor_col
        )
        var caret = acp_of_caret(doc[].rope, doc[].caret_line, doc[].caret_col)
        var sel = TS_SELECTION_ACP()
        # TSF wants the range in order, and remembers which end is live in
        # `ase` -- so a selection dragged upwards keeps its direction without
        # the range ever being back to front.
        if anchor <= caret:
            sel.acpStart = Int32(anchor)
            sel.acpEnd = Int32(caret)
            sel.style.ase = UInt32(1)  # TS_AE_END
        else:
            sel.acpStart = Int32(caret)
            sel.acpEnd = Int32(anchor)
            sel.style.ase = UInt32(0)  # TS_AE_START
        Pointer[TS_SELECTION_ACP, MutAnyOrigin](
            unsafe_from_address=out_sel
        )[] = sel
        got[] = 1

    def SetSelection(mut self, count: UInt32, sel: Int) raises:
        """Put the caret and anchor where the input method wants them."""
        if count == 0 or sel == 0:
            return
        var doc = self.document()
        var want = Pointer[TS_SELECTION_ACP, MutAnyOrigin](
            unsafe_from_address=sel
        )[]
        var start = caret_of_acp(doc[].rope, Int(want.acpStart))
        var end = caret_of_acp(doc[].rope, Int(want.acpEnd))
        # `ase` says which end the caret is at; the other is the anchor.
        if want.style.ase == UInt32(0):  # TS_AE_START
            doc[].caret_line = start[0]
            doc[].caret_col = start[1]
            doc[].anchor_line = end[0]
            doc[].anchor_col = end[1]
        else:
            doc[].anchor_line = start[0]
            doc[].anchor_col = start[1]
            doc[].caret_line = end[0]
            doc[].caret_col = end[1]
        self.repaint()

    def GetText(
        mut self,
        start: Int32,
        end: Int32,
        buffer: Int,
        buffer_units: UInt32,
        copied: Int,
        runs: Int,
        runs_len: UInt32,
        runs_copied: Int,
        next_acp: Int,
    ) raises:
        """Copy a range of the document out, in UTF-16.

        Nine arguments, which is what made this sprint raise the class
        surface arity ceiling rather than drop to the raw form for one method.

        An end of -1 means "to the end of the document", which is how TSF asks
        for the rest without asking how long it is first. A range running past
        the end is clamped rather than refused: a store may answer
        TS_E_INVALIDPOS, and this one cannot -- see the note at the top of the
        file -- but clamping is what a forgiving store does anyway and no
        input method minds.
        """
        var doc = self.document()
        var total = doc[].rope.utf16_length()
        var from_acp = Int(start)
        if from_acp < 0:
            from_acp = 0
        if from_acp > total:
            from_acp = total
        var to_acp = total if end < 0 else Int(end)
        if to_acp > total:
            to_acp = total
        if to_acp < from_acp:
            to_acp = from_acp

        # The caller buffer is the real limit, whatever range was asked for.
        var wanted = to_acp - from_acp
        if buffer != 0 and Int(buffer_units) < wanted:
            wanted = Int(buffer_units)
        to_acp = from_acp + wanted

        var text = doc[].rope.slice(
            doc[].rope.utf16_to_byte(from_acp),
            doc[].rope.utf16_to_byte(to_acp),
        )
        var units = utf16_of(text)
        var n = len(units)
        if buffer != 0:
            var out = Pointer[UInt16, MutAnyOrigin](unsafe_from_address=buffer)
            for i in range(n):
                out.unsafe_offset(i)[] = units[i]
        if copied != 0:
            Pointer[UInt32, MutAnyOrigin](unsafe_from_address=copied)[] = (
                UInt32(n)
            )

        # One run, of plain text: this document has no hidden regions, and
        # saying so in a single entry is cheaper for the input method than
        # being handed the text a character at a time.
        if runs != 0 and runs_len > 0:
            var run = TS_RUNINFO()
            run.uCount = UInt32(n)
            run.type = 0  # TS_RT_PLAIN
            Pointer[TS_RUNINFO, MutAnyOrigin](unsafe_from_address=runs)[] = run
        if runs_copied != 0:
            var made = UInt32(0)
            if runs != 0 and runs_len > 0 and n > 0:
                made = UInt32(1)
            Pointer[UInt32, MutAnyOrigin](unsafe_from_address=runs_copied)[] = (
                made
            )
        if next_acp != 0:
            Pointer[Int32, MutAnyOrigin](unsafe_from_address=next_acp)[] = (
                Int32(from_acp + n)
            )

    # ---- writing the document -------------------------------------------

    def QueryInsert(
        mut self,
        start: Int32,
        end: Int32,
        length: UInt32,
        out_start: Int,
        out_end: Int,
    ) raises:
        """Where an insertion would actually land.

        A store may move it -- to avoid splitting a cluster, say. This one
        clamps to the document and otherwise agrees with what was asked.
        """
        var doc = self.document()
        var total = doc[].rope.utf16_length()
        var a = Int(start)
        var b = Int(end)
        if a < 0:
            a = 0
        if a > total:
            a = total
        if b < a:
            b = a
        if b > total:
            b = total
        Pointer[Int32, MutAnyOrigin](unsafe_from_address=out_start)[] = Int32(a)
        Pointer[Int32, MutAnyOrigin](unsafe_from_address=out_end)[] = Int32(b)

    def SetText(
        mut self,
        flags: UInt32,
        start: Int32,
        end: Int32,
        text: Int,
        units: UInt32,
        change: Int,
    ) raises:
        """Replace a range with text the input method composed."""
        var doc = self.document()
        var total = doc[].rope.utf16_length()
        var from_acp = Int(start)
        var to_acp = Int(end)
        if from_acp < 0:
            from_acp = 0
        if from_acp > total:
            from_acp = total
        if to_acp < from_acp:
            to_acp = from_acp
        if to_acp > total:
            to_acp = total

        var inserted = String("")
        if text != 0 and units > 0:
            inserted = string_of_utf16(text, Int(units))
        self.replace_acp(from_acp, to_acp, inserted, change)

    def InsertTextAtSelection(
        mut self,
        flags: UInt32,
        text: Int,
        units: UInt32,
        out_start: Int,
        out_end: Int,
        change: Int,
    ) raises:
        """Replace the selection with text, or say where that would land.

        TS_IE_CORRECTION in `flags` means "tell me where, do not do it": the
        input method is measuring, not committing. Doing the edit anyway is
        how a composition ends up typed twice.
        """
        var doc = self.document()
        var anchor = acp_of_caret(
            doc[].rope, doc[].anchor_line, doc[].anchor_col
        )
        var caret = acp_of_caret(doc[].rope, doc[].caret_line, doc[].caret_col)
        var from_acp = anchor
        var to_acp = caret
        if anchor > caret:
            from_acp = caret
            to_acp = anchor

        var inserted = String("")
        if text != 0 and units > 0:
            inserted = string_of_utf16(text, Int(units))
        var added = len(utf16_of(inserted))

        if (Int(flags) & winkb_constant["TS_IE_CORRECTION"]()) != 0:
            self.write_range(out_start, out_end, from_acp, from_acp + added)
            return

        self.replace_acp(from_acp, to_acp, inserted, change)
        self.write_range(out_start, out_end, from_acp, from_acp + added)

    # ---- where things are on screen -------------------------------------
    #
    # An input method needs these to put its candidate window under the text
    # being composed. Getting them wrong does not break typing; it puts the
    # candidate list in the corner of the screen, which is the tell of an
    # application that implemented TSF halfway.

    def GetWnd(mut self, view: UInt32, out_hwnd: Int) raises:
        """Which window this store draws into."""
        Pointer[Int, MutAnyOrigin](unsafe_from_address=out_hwnd)[] = self.hwnd

    def GetActiveView(mut self, view: Int) raises:
        """The one view. A store may have several; this one has a window."""
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=view)[] = UInt32(0)

    def GetScreenExt(mut self, view: UInt32, rect: Int) raises:
        """The editor field, in screen coordinates."""
        var r = self.editor_rect()
        Pointer[RECT, MutAnyOrigin](unsafe_from_address=rect)[] = r

    def GetTextExt(
        mut self, view: UInt32, start: Int32, end: Int32, rect: Int, clipped: Int
    ) raises:
        """The rectangle a range of text occupies, in screen coordinates.

        Answered from the same caret arithmetic the editor draws with, so the
        candidate window lands under the composition rather than near it.
        """
        var doc = self.document()
        var where = caret_of_acp(doc[].rope, Int(start))
        var box = self.editor_rect()
        var line_top = box.top + Int32(
            Float32(where[0] - doc[].grid.top_line) * doc[].grid.line_height
        )
        # The x of the range start, from the grid, offset by the gutter.
        var x = box.left + Int32(GUTTER_W) + Int32(
            Float32(where[1]) * doc[].grid.advance
        )
        var out = RECT()
        out.left = x
        out.top = line_top
        out.right = x + Int32(1)
        out.bottom = line_top + Int32(doc[].grid.line_height)
        Pointer[RECT, MutAnyOrigin](unsafe_from_address=rect)[] = out
        if clipped != 0:
            Pointer[Int32, MutAnyOrigin](unsafe_from_address=clipped)[] = 1

    def GetACPFromPoint(
        mut self, view: UInt32, point: Int, flags: UInt32, out_acp: Int
    ) raises:
        """Which character a screen point is over.

        Used by handwriting and by reconversion. The point arrives in screen
        coordinates and the editor thinks in client ones, so it is converted
        through the same call a click goes through.
        """
        var doc = self.document()
        var p = Pointer[Int32, MutAnyOrigin](unsafe_from_address=point)
        var box = self.editor_rect()
        var row = Int(
            Float32(p.unsafe_offset(1)[] - box.top) / doc[].grid.line_height
        )
        var line = doc[].grid.top_line + row
        var last = doc[].rope.line_count() - 1
        if line > last:
            line = last
        if line < 0:
            line = 0
        var into = Float32(p[] - box.left - Int32(GUTTER_W))
        if into < 0:
            into = 0
        var col = 0
        if doc[].grid.advance > 0:
            col = Int(into / doc[].grid.advance)
        Pointer[Int32, MutAnyOrigin](unsafe_from_address=out_acp)[] = Int32(
            acp_of_caret(doc[].rope, line, col)
        )

    # ---- what this store does not do -------------------------------------
    #
    # Every slot must be filled or the object refuses to exist -- a vtable
    # hole does not fail loudly at the call, it dispatches into whatever the
    # slot happens to hold. These raise, which the trampoline turns into
    # E_FAIL, and TSF treats a failing optional method as an unsupported one.
    #
    # Embedded objects are pictures and OLE items inside text. Attributes are
    # per-run properties an input method may ask about -- writing direction,
    # language, whether a run is a password field. Both are optional, both
    # are answered by declining, and both are here as named refusals rather
    # than silent holes.

    def GetFormattedText(mut self, start: Int32, end: Int32, out_obj: Int) raises:
        """No formatted text: this is a plain-text editor."""
        raise Error("GetFormattedText is not supported")

    def GetEmbedded(
        mut self, position: Int32, format: Int, iid: Int, out_obj: Int
    ) raises:
        """No embedded objects."""
        raise Error("GetEmbedded is not supported")

    def QueryInsertEmbedded(
        mut self, format: Int, etc: Int, insertable: Int
    ) raises:
        """Nothing may be embedded, and saying so is not a failure."""
        Pointer[Int32, MutAnyOrigin](unsafe_from_address=insertable)[] = 0

    def InsertEmbedded(
        mut self,
        flags: UInt32,
        start: Int32,
        end: Int32,
        obj: Int,
        change: Int,
    ) raises:
        """No embedded objects."""
        raise Error("InsertEmbedded is not supported")

    def InsertEmbeddedAtSelection(
        mut self,
        flags: UInt32,
        obj: Int,
        out_start: Int,
        out_end: Int,
        change: Int,
    ) raises:
        """No embedded objects."""
        raise Error("InsertEmbeddedAtSelection is not supported")

    def RequestSupportedAttrs(
        mut self, flags: UInt32, count: UInt32, attrs: Int
    ) raises:
        """No attributes are supported, which is answered by supporting none.

        S_OK with nothing retrievable, rather than a failure: an input method
        asking which attributes exist and being told the request failed will
        often stop asking anything else.
        """
        pass

    def RequestAttrsAtPosition(
        mut self, position: Int32, count: UInt32, attrs: Int, flags: UInt32
    ) raises:
        """No attributes at any position."""
        pass

    def RequestAttrsTransitioningAtPosition(
        mut self, position: Int32, count: UInt32, attrs: Int, flags: UInt32
    ) raises:
        """No attributes, so nothing transitions."""
        pass

    def FindNextAttrTransition(
        mut self,
        start: Int32,
        halt: Int32,
        count: UInt32,
        attrs: Int,
        flags: UInt32,
        out_next: Int,
        out_found: Int,
        out_run: Int,
    ) raises:
        """No attributes, so there is never a next transition."""
        if out_next != 0:
            Pointer[Int32, MutAnyOrigin](unsafe_from_address=out_next)[] = halt
        if out_found != 0:
            Pointer[Int32, MutAnyOrigin](unsafe_from_address=out_found)[] = 0
        if out_run != 0:
            Pointer[Int32, MutAnyOrigin](unsafe_from_address=out_run)[] = 0

    def RetrieveRequestedAttrs(
        mut self, count: UInt32, values: Int, fetched: Int
    ) raises:
        """Nothing was requested, so nothing comes back."""
        if fetched != 0:
            Pointer[UInt32, MutAnyOrigin](unsafe_from_address=fetched)[] = 0

    # ---- helpers ---------------------------------------------------------
    #
    # No interface declares these names, so the class desugar leaves them
    # ordinary methods of the struct rather than slots to fill. That rule --
    # a class may hold helpers -- is what makes a class readable instead of
    # being twenty-six methods with the shared parts copied between them.

    def document(mut self) raises -> Pointer[Doc, MutAnyOrigin]:
        """The document behind this store window."""
        var address = doc_of(self.hwnd)
        if address == 0:
            raise Error("this store has no document")
        return Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)

    def editor_rect(mut self) raises -> RECT:
        """The editor field, in screen coordinates."""
        var GetClientRect = win32[
            def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
            "GetClientRect",
        ]()
        var ClientToScreen = win32[
            def (Int, Pointer[POINT, MutAnyOrigin]) thin abi("C") -> c_int,
            "ClientToScreen",
        ]()
        var rc = RECT()
        _ = GetClientRect(self.hwnd, com_addr(rc))
        var editor = Layout(
            Int(rc.right - rc.left), Int(rc.bottom - rc.top)
        ).editor()
        # Two points converted rather than the rectangle, because
        # ClientToScreen takes a POINT and a RECT is two of them.
        var top_left = POINT(Int32(editor.left), Int32(editor.top))
        var bottom_right = POINT(Int32(editor.right), Int32(editor.bottom))
        _ = ClientToScreen(self.hwnd, com_addr(top_left))
        _ = ClientToScreen(self.hwnd, com_addr(bottom_right))
        return RECT(top_left.x, top_left.y, bottom_right.x, bottom_right.y)

    def write_range(mut self, out_start: Int, out_end: Int, a: Int, b: Int):
        """Fill in a pair of out-parameters, either of which may be absent."""
        if out_start != 0:
            Pointer[Int32, MutAnyOrigin](unsafe_from_address=out_start)[] = (
                Int32(a)
            )
        if out_end != 0:
            Pointer[Int32, MutAnyOrigin](unsafe_from_address=out_end)[] = (
                Int32(b)
            )

    def replace_acp(
        mut self, from_acp: Int, to_acp: Int, text: String, change: Int
    ) raises:
        """Replace a range given in absolute positions, and report the change.

        The one place TSF text reaches the document, so the one place the
        editor history is recorded for it. An input method commit is one undo
        step, which is what a person means by undoing a composition.
        """
        var doc = self.document()
        var start_byte = doc[].rope.utf16_to_byte(from_acp)
        var end_byte = doc[].rope.utf16_to_byte(to_acp)
        var added = len(utf16_of(text))
        apply(doc[], start_byte, end_byte, text)
        if change != 0:
            var report = TS_TEXTCHANGE()
            report.acpStart = Int32(from_acp)
            report.acpOldEnd = Int32(to_acp)
            report.acpNewEnd = Int32(from_acp + added)
            Pointer[TS_TEXTCHANGE, MutAnyOrigin](
                unsafe_from_address=change
            )[] = report
        self.repaint()

    def repaint(mut self) raises:
        """Mark the window for redraw after the store changed something."""
        var InvalidateRect = win32[
            def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
        ]()
        _ = InvalidateRect(self.hwnd, 0, c_int(0))


# ===----------------------------------------------------------------------===#
# Activation
#
# Six calls, in an order that matters. A thread manager is created and
# activated, which is what makes this thread visible to input methods at all.
# A document manager is a stack of contexts; a context is what actually holds
# a text store. The store is pushed onto the stack, and the stack is
# associated with the window -- so when the window takes focus, the input
# method finds the store behind it.
#
# The CLSID is written here rather than read from the metadata because the
# database carries interface IIDs but not class IDs: its guid-kind constants
# are present and valueless. That gap is already recorded against `co_create`,
# and this is its second consumer.
# ===----------------------------------------------------------------------===#

comptime CLSID_TF_ThreadMgr = StaticString(
    "529a9e6b-6587-4f23-ab9e-9c7d683e3c50"
)


@fieldwise_init
struct Tsf(Movable):
    """Everything TSF activation produced, kept for the life of the window.

    All four are owning pointers and all four must be kept. Dropping the
    context leaves the document manager holding a stack entry that no longer
    exists; dropping the store leaves TSF calling into freed memory the next
    time a key is pressed. This struct exists so that "keep these alive" is a
    thing the type system enforces rather than a comment.
    """

    var thread_mgr: ComPtr[StaticString("ITfThreadMgr")]
    var doc_mgr: ComPtr[StaticString("ITfDocumentMgr")]
    var context: ComPtr[StaticString("ITfContext")]
    var store: ComPtr[StaticString("ITextStoreACP")]
    # TSF's identifier for this client, needed to create a context and to
    # talk about edit sessions.
    var client_id: UInt32
    # The cookie a context hands back for the text store it was given.
    var edit_cookie: UInt32


def activate(hwnd: Int) raises -> Tsf:
    """Make this window visible to every input method on the system.

    Args:
        hwnd: The window that will hold the focus.

    Returns:
        The activation, which must be kept for the life of the window.

    Raises:
        If TSF is unavailable or refuses any step. The caller should treat
        that as "no input methods", not as fatal: an editor with no text
        store still types ASCII through WM_CHAR, which is what every version
        of this editor before sprint 1.5 did.
    """
    sizes_agree()

    var thread_mgr = co_create[CLSID_TF_ThreadMgr, "ITfThreadMgr"]()
    # ComPtr owns the reference; Com is the typed, width-checked view onto it.
    # Two types rather than one because ownership and dispatch are different
    # questions, and conflating them is how a borrowed pointer gets released.
    var tm = Com[StaticString("ITfThreadMgr")](borrowed=thread_mgr.address())
    var client_id = UInt32(0)
    _ = tm.Activate(com_addr(client_id))

    var doc_mgr_out = Int(0)
    _ = tm.CreateDocumentMgr(com_addr(doc_mgr_out))
    if doc_mgr_out == 0:
        raise Error("CreateDocumentMgr produced nothing")
    var doc_mgr = ComPtr[StaticString("ITfDocumentMgr")](adopt=doc_mgr_out)
    var dm = Com[StaticString("ITfDocumentMgr")](borrowed=doc_mgr.address())

    var store = TextStore(hwnd, 0, UInt32(0), 0).into_com()
    var context_out = Int(0)
    var edit_cookie = UInt32(0)
    _ = dm.CreateContext(
        client_id,
        UInt32(0),
        store.address(),
        com_addr(context_out),
        com_addr(edit_cookie),
    )
    if context_out == 0:
        raise Error("CreateContext produced nothing")
    var context = ComPtr[StaticString("ITfContext")](adopt=context_out)

    _ = dm.Push(context.address())

    # Associating rather than calling SetFocus: association is per-window and
    # survives focus moving away and back, which is what an editor wants. The
    # previous association comes back and is released -- this window did not
    # have one, but a caller that ignored it would leak whatever did.
    var previous = Int(0)
    _ = tm.AssociateFocus(hwnd, doc_mgr.address(), com_addr(previous))
    if previous != 0:
        var prev = ComPtr[StaticString("ITfDocumentMgr")](adopt=previous)
        _ = prev

    return Tsf(
        thread_mgr^, doc_mgr^, context^, store^, client_id, edit_cookie
    )


def deactivate(mut tsf: Tsf) raises:
    """Take the window back out of TSF, in the order activation built it up.

    Pop before Deactivate: a document manager with a context still on its
    stack, belonging to a thread manager that has been deactivated, is a
    shutdown order that works on most machines and hangs on some.
    """
    var dm = Com[StaticString("ITfDocumentMgr")](borrowed=tsf.doc_mgr.address())
    var tm = Com[StaticString("ITfThreadMgr")](borrowed=tsf.thread_mgr.address())
    _ = dm.Pop(UInt32(0))
    _ = tm.Deactivate()


# ===----------------------------------------------------------------------===#
# A sink, so the store can be checked the way an input method drives it
#
# The lock protocol cannot be checked from outside: `RequestLock` does not
# return text, it calls back. So the check needs to be a client -- an object
# implementing `ITextStoreACPSink` that, when the lock is granted, does the
# reading and writing an input method would and records what it saw.
#
# Which makes this the second `class` in the file, and the one that shows the
# shape is not a one-off: eight methods, a different interface, the same
# declaration.
# ===----------------------------------------------------------------------===#


@fieldwise_init
struct SinkReport(Defaultable, ImplicitlyCopyable, Movable):
    """What a sink saw, in storage its caller owns.

    The sink itself lives inside a COM object, and a COM object is reached
    through a vtable rather than through a Mojo value -- there is no way to
    look back inside it afterwards. So the findings go where the caller can
    read them, which is the same shape `spikes/com/s15_class_destructor` uses
    to observe a destructor from outside.
    """

    var lock_flags: Int
    var read_units: Int
    var end_acp: Int
    var sel_start: Int
    var sel_end: Int
    var text_changes: Int
    var selection_changes: Int
    var first_char: Int

    def __init__(out self):
        """Nothing seen yet."""
        self.lock_flags = 0
        self.read_units = 0
        self.end_acp = 0
        self.sel_start = 0
        self.sel_end = 0
        self.text_changes = 0
        self.selection_changes = 0
        self.first_char = 0


class CheckSink(ITextStoreACPSink):
    # The store to drive when the lock arrives, and where to write what was
    # seen. Both addresses rather than pointers: this object is reached
    # through a C-ABI vtable, where nothing carries an origin.
    var store: Int
    var report: Int

    def OnLockGranted(mut self, flags: UInt32) raises:
        """Read the document, the way an input method does under a lock."""
        self.seen()[].lock_flags = Int(flags)
        var store = OpaquePointer[MutUntrackedOrigin](
            unsafe_from_address=self.store
        )

        var end = Int32(0)
        _ = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin],
                Pointer[Int32, MutAnyOrigin],
            ) thin abi("C") -> Int32,
            "ITextStoreACP",
            "GetEndACP",
        ](store)(store, com_addr(end))
        self.seen()[].end_acp = Int(end)

        var selection = TS_SELECTION_ACP()
        var fetched = UInt32(0)
        _ = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin],
                UInt32,
                UInt32,
                Pointer[TS_SELECTION_ACP, MutAnyOrigin],
                Pointer[UInt32, MutAnyOrigin],
            ) thin abi("C") -> Int32,
            "ITextStoreACP",
            "GetSelection",
        ](store)(
            store,
            UInt32(0xFFFFFFFF),
            UInt32(1),
            com_addr(selection),
            com_addr(fetched),
        )
        self.seen()[].sel_start = Int(selection.acpStart)
        self.seen()[].sel_end = Int(selection.acpEnd)

        # The nine-argument one. A buffer big enough for the whole of a small
        # document, asked for with an end of -1: read to the end without
        # having asked how long the end is.
        var buffer = List[UInt16]()
        for _ in range(256):
            buffer.append(0)
        var copied = UInt32(0)
        var runs = TS_RUNINFO()
        var runs_copied = UInt32(0)
        var next_acp = Int32(0)
        _ = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin],
                Int32,
                Int32,
                Int,
                UInt32,
                Pointer[UInt32, MutAnyOrigin],
                Pointer[TS_RUNINFO, MutAnyOrigin],
                UInt32,
                Pointer[UInt32, MutAnyOrigin],
                Pointer[Int32, MutAnyOrigin],
            ) thin abi("C") -> Int32,
            "ITextStoreACP",
            "GetText",
        ](store)(
            store,
            Int32(0),
            Int32(-1),
            Int(buffer.unsafe_ptr()),
            UInt32(256),
            com_addr(copied),
            com_addr(runs),
            UInt32(1),
            com_addr(runs_copied),
            com_addr(next_acp),
        )
        self.seen()[].read_units = Int(copied)
        self.seen()[].first_char = Int(buffer[0]) if Int(copied) > 0 else 0
        _ = buffer

    def seen(mut self) -> Pointer[SinkReport, MutAnyOrigin]:
        """Where to write what this sink observed. A helper, not a slot."""
        return Pointer[SinkReport, MutAnyOrigin](
            unsafe_from_address=self.report
        )

    def OnTextChange(mut self, flags: UInt32, change: Int) raises:
        """The document changed under us."""
        self.seen()[].text_changes += 1

    def OnSelectionChange(mut self) raises:
        """The caret moved under us."""
        self.seen()[].selection_changes += 1

    def OnLayoutChange(mut self, code: UInt32, view: UInt32) raises:
        """The window moved or resized; candidate windows want to know."""
        pass

    def OnStatusChange(mut self, flags: UInt32) raises:
        """The document became read-only, or stopped being."""
        pass

    def OnAttrsChange(
        mut self, start: Int32, end: Int32, count: UInt32, attrs: Int
    ) raises:
        """No attributes are supported, so none ever change."""
        pass

    def OnStartEditTransaction(mut self) raises:
        """A group of edits begins."""
        pass

    def OnEndEditTransaction(mut self) raises:
        """And ends. Grouping them into one undo step is sprint 1.5 work
        that a composition does not need: a commit arrives as one SetText."""
        pass


def self_check(hwnd: Int) raises -> String:
    """Drive the store the way an input method would, and report what it did.

    Not a simulation of TSF: the calls below go through the store own vtable,
    at the slots the metadata records, with a real sink advised the way TSF
    advises one. What it cannot cover is a real input method choosing to make
    those calls, which is the manual half and is documented as such.

    Args:
        hwnd: The window whose store to drive.

    Returns:
        What happened, as text.

    Raises:
        If the store cannot be built or a call fails outright.
    """
    var store = TextStore(hwnd, 0, UInt32(0), 0).into_com()
    var this = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=store.address()
    )
    var report = SinkReport()
    var sink = CheckSink(store.address(), Int(com_addr(report))).into_com()

    var out = String("")

    # A lock before there is a sink must be refused: TSF grants locks so the
    # sink can be called back, and there is nothing to call.
    var early = Int32(0)
    _ = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            Pointer[Int32, MutAnyOrigin],
        ) thin abi("C") -> Int32,
        "ITextStoreACP",
        "RequestLock",
    ](this)(this, UInt32(winkb_constant["TS_LF_READ"]()), com_addr(early))
    var no_lock = Int32(winkb_constant["TS_E_NOLOCK"]())
    out += "lock-before-sink: " + ("refused" if early == no_lock else "GRANTED, wrong") + "\n"

    _ = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int, Int, UInt32
        ) thin abi("C") -> Int32,
        "ITextStoreACP",
        "AdviseSink",
    ](this)(this, 0, sink.address(), UInt32(0))
    out += "advise: sink taken\n"

    # A read lock. The sink reads the document from inside the callback,
    # which is the only place TSF allows it.
    var granted = Int32(0)
    var hr = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            Pointer[Int32, MutAnyOrigin],
        ) thin abi("C") -> Int32,
        "ITextStoreACP",
        "RequestLock",
    ](this)(
        this, UInt32(winkb_constant["TS_LF_READWRITE"]()), com_addr(granted)
    )
    out += "lock: hr=" + String(hr) + " session=" + String(granted) + "\n"

    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=doc_of(hwnd))
    var expect = doc[].rope.utf16_length()
    out += (
        "under-lock read: end=" + String(report.end_acp)
        + " expected=" + String(expect)
        + " units=" + String(report.read_units)
        + " selection=" + String(report.sel_start) + ".."
        + String(report.sel_end)
        + " flags=" + String(report.lock_flags) + "\n"
    )

    # SetText, the way a committed composition arrives: replace a range with
    # text and be told what changed.
    var wide = utf16_of(String("TSF"))
    var change = TS_TEXTCHANGE()
    var set_hr = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            Int32,
            Int32,
            Int,
            UInt32,
            Pointer[TS_TEXTCHANGE, MutAnyOrigin],
        ) thin abi("C") -> Int32,
        "ITextStoreACP",
        "SetText",
    ](this)(
        this,
        UInt32(0),
        Int32(0),
        Int32(0),
        Int(wide.unsafe_ptr()),
        UInt32(len(wide)),
        com_addr(change),
    )
    _ = wide
    out += (
        "settext: hr=" + String(set_hr)
        + " change=" + String(change.acpStart) + ".."
        + String(change.acpOldEnd) + "->" + String(change.acpNewEnd)
        + " first line now: " + doc[].rope.line(0) + "\n"
    )

    # And the selection, set through the store and read back from the editor.
    var want = TS_SELECTION_ACP()
    want.acpStart = Int32(1)
    want.acpEnd = Int32(3)
    want.style.ase = UInt32(1)
    _ = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            Pointer[TS_SELECTION_ACP, MutAnyOrigin],
        ) thin abi("C") -> Int32,
        "ITextStoreACP",
        "SetSelection",
    ](this)(this, UInt32(1), com_addr(want))
    var anchor = acp_of_caret(
        doc[].rope, doc[].anchor_line, doc[].anchor_col
    )
    var caret = acp_of_caret(doc[].rope, doc[].caret_line, doc[].caret_col)
    out += (
        "setselection: anchor=" + String(anchor) + " caret=" + String(caret)
        + " (wanted 1..3)\n"
    )

    _ = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin], Int) thin abi("C") -> Int32,
        "ITextStoreACP",
        "UnadviseSink",
    ](this)(this, sink.address())
    out += "unadvise: sink released\n"
    _ = sink
    _ = store
    _ = report
    return out
