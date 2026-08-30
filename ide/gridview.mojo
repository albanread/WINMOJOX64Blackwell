"""The text grid: where the rope meets the screen.

The thesis, made literal. A monospaced editor is a grid, a grid is
arithmetic, and arithmetic has no pass to run: given a scroll position and a
client size, the visible line range is a division, and every glyph's origin
is a multiplication. Nothing is measured to decide what to draw.

Two things keep that honest.

**Only the viewport is touched.** The document may be 250,000 lines; the
draw walks the forty or so that are on screen, each fetched from the rope in
O(log n). Scrolling a document costs the same as scrolling an empty one.

**Only newly exposed lines are laid out.** A `IDWriteTextLayout` is
expensive -- it is where DirectWrite does shaping, fallback and kerning --
so layouts are cached per line and survive scrolling. The cache keeps
counters, and the `grid` verb prints them, because "only exposed lines are
redrawn" is the kind of claim that quietly stops being true and no one
notices. A number that can be read is a number that can be wrong out loud.

The cache is direct-mapped on the line number. Scrolling by one line evicts
exactly one entry, which is the access pattern an editor actually has;
anything cleverer would be solving a problem this does not have.
"""

from std.ffi import c_int
from std.memory import OpaquePointer, Pointer, alloc
from std.sys._com import com_addr, com_method_of
from std.sys._winkb import winkb_constant

from ide.caret import cluster_at, is_simple, position_at
from ide.chrome import (
    Chrome,
    D2D_COLOR_F,
    D2D_RECT_F,
    EMBER,
    INK,
    Layout,
)
from ide.rope import Rope
from ide.win32 import RECT, win32


# Cascadia Mono at 12pt. The advance and line height are asked of DirectWrite
# once and then used as arithmetic, which is the whole point.
@fieldwise_init
struct D2D_POINT_2F(Defaultable, ImplicitlyCopyable, Movable):
    """A point, as Direct2D takes one."""

    var x: Float32
    var y: Float32

    def __init__(out self):
        """The origin."""
        self.x = 0
        self.y = 0


comptime GUTTER_W = 56
comptime TEXT_PAD = 10


@fieldwise_init
struct Grid(Movable):
    """The editor's view onto a rope: what is visible, and what is cached."""

    var top_line: Int
    var line_height: Float32
    var capacity: Int
    # Direct-mapped cache: slot `line % capacity` holds this line's layout.
    var cached_line: List[Int]
    var cached_rev: List[Int]
    var cached_layout: List[Int]
    # Inspectable, because the claim needs to be checkable.
    var hits: Int
    var misses: Int
    var drawn: Int
    # One character's width in the editor face, asked of DirectWrite once and
    # then used as arithmetic. Zero until measured; see `advance_of`.
    var advance: Float32

    def __init__(out self, capacity: Int = 128):
        """An empty grid, scrolled to the top.

        Args:
            capacity: How many line layouts to keep. A little over a
                screenful, so scrolling reuses rather than thrashes.
        """
        self.top_line = 0
        self.line_height = 16.0
        self.capacity = capacity
        self.cached_line = List[Int]()
        self.cached_rev = List[Int]()
        self.cached_layout = List[Int]()
        for _ in range(capacity):
            self.cached_line.append(-1)
            self.cached_rev.append(-1)
            self.cached_layout.append(0)
        self.hits = 0
        self.misses = 0
        self.drawn = 0
        self.advance = 0

    def visible_lines(self, height: Float32) -> Int:
        """How many lines fit in a region this tall, partial one included."""
        return Int(height / self.line_height) + 1


@fieldwise_init
struct Doc(Movable):
    """A document and the view onto it.

    The window keeps one of these. It is separate from `Chrome` -- which is
    Direct2D's business -- because the text outlives any particular render
    target, and because a lost device would otherwise take the file with it.
    """

    var rope: Rope
    var grid: Grid
    # Bumped by every edit. Layouts are keyed on it, so an edit invalidates
    # the cache without anyone having to remember to clear it.
    var revision: Int
    # The caret, as a line and a UTF-16 code-unit offset within it. Code units
    # rather than characters or bytes because that is what DirectWrite hit
    # tests in and what the text services framework will want in sprint 1.5;
    # having one unit throughout is worth more than having a tidy one.
    var caret_line: Int
    var caret_col: Int

    def __init__(out self, var rope: Rope):
        """A document scrolled to the top, with an empty cache."""
        self.rope = rope^
        self.grid = Grid()
        self.revision = 0
        self.caret_line = 0
        self.caret_col = 0


def draw_text(
    mut grid: Grid,
    chrome: Chrome,
    rope: Rope,
    region: D2D_RECT_F,
    revision: Int,
    caret_line: Int = -1,
    caret_col: Int = 0,
) raises:
    """Draw the visible slice of `rope` into `region`.

    Args:
        grid: The view state; its counters are updated.
        chrome: The render target and text format.
        rope: The document.
        region: Where the text goes.
        revision: The document's edit revision, part of the cache key.
        caret_line: Which line the caret is on, or -1 for no caret.
        caret_col: Its UTF-16 offset within that line.

    Raises:
        If DirectWrite refuses to lay out a line.
    """
    if chrome.target == 0 or chrome.text_format == 0:
        return

    var this = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=chrome.target
    )
    var dwrite = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=chrome.dwrite
    )

    var brush = _brush(chrome.target, INK)
    if brush == 0:
        return
    var gutter_brush = _brush(chrome.target, 0x5D6470)

    # Clip to the editor field. The last visible row is usually a partial one,
    # and a line longer than the pane is normal; without this both spill over
    # the panes and the sidebar, which looks like a layout bug and is not one.
    var clip = region
    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Pointer[D2D_RECT_F, MutAnyOrigin],
            UInt32,
        ) thin abi("C") -> NoneType,
        "ID2D1RenderTarget",
        "PushAxisAlignedClip",
    ](this)(this, com_addr(clip), UInt32(0))
    _ = clip

    var height = region.bottom - region.top
    var count = grid.visible_lines(height)
    var total = rope.line_count()

    var row = 0
    while row < count:
        var line = grid.top_line + row
        if line >= total:
            break
        var y = region.top + Float32(row) * grid.line_height

        var layout = _layout_for(grid, dwrite, chrome, rope, line, revision)
        if layout != 0:
            _draw_layout(
                this, layout, brush, region.left + Float32(GUTTER_W), y
            )
            grid.drawn += 1

        # The line number, laid out fresh each time: the gutter is narrow,
        # the strings are short, and caching them would double the cache to
        # save almost nothing.
        var number = String(line + 1)
        var num_layout = _make_layout(
            dwrite, chrome, number, Float32(GUTTER_W - TEXT_PAD)
        )
        if num_layout != 0:
            _draw_layout(this, num_layout, gutter_brush, region.left + 6, y)
            _release(num_layout)

        row += 1

    # The caret, inside the clip so it cannot escape the editor field, and
    # after the text so it is never painted over. Only when its line is on
    # screen: a caret three thousand lines above the viewport is not a caret
    # at the top of it.
    if caret_line >= 0 and caret_line >= grid.top_line:
        var caret_row = caret_line - grid.top_line
        if caret_row < count and caret_line < total:
            draw_caret(
                this,
                region.left
                + Float32(GUTTER_W)
                + caret_x(
                    grid,
                    dwrite,
                    chrome,
                    rope,
                    caret_line,
                    caret_col,
                    revision,
                ),
                region.top + Float32(caret_row) * grid.line_height,
                grid.line_height,
                chrome.target,
            )

    com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> NoneType,
        "ID2D1RenderTarget",
        "PopAxisAlignedClip",
    ](this)(this)

    _release(brush)
    _release(gutter_brush)


def _layout_for(
    mut grid: Grid,
    dwrite: OpaquePointer[MutUntrackedOrigin],
    chrome: Chrome,
    rope: Rope,
    line: Int,
    revision: Int,
) raises -> Int:
    """The cached layout for one line, making it only if it is not there."""
    var slot = line % grid.capacity
    if grid.cached_line[slot] == line and grid.cached_rev[slot] == revision:
        grid.hits += 1
        return grid.cached_layout[slot]

    grid.misses += 1
    # Whatever occupied this slot is now unreachable; let it go before the
    # slot is overwritten, or the layout leaks for the life of the window.
    _release(grid.cached_layout[slot])

    var text = rope.line(line)
    var made = _make_layout(dwrite, chrome, text, 4000.0)
    grid.cached_line[slot] = line
    grid.cached_rev[slot] = revision
    grid.cached_layout[slot] = made
    return made


def _make_layout(
    dwrite: OpaquePointer[MutUntrackedOrigin],
    chrome: Chrome,
    text: String,
    width: Float32,
) raises -> Int:
    """Lay one line out with DirectWrite."""
    var wide = List[UInt16]()
    for ch in text.codepoints():
        var v = Int(ch)
        # Anything outside the basic plane becomes a surrogate pair, which
        # is what UTF-16 means and what every W entry point expects.
        if v >= 0x10000:
            var u = v - 0x10000
            wide.append(UInt16(0xD800 + (u >> 10)))
            wide.append(UInt16(0xDC00 + (u & 0x3FF)))
        else:
            wide.append(UInt16(v))
    var units = len(wide)
    wide.append(0)

    var layout = Int(0)
    _ = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            UInt32,
            Int,
            Float32,
            Float32,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> Int32,
        "IDWriteFactory",
        "CreateTextLayout",
    ](dwrite)(
        dwrite,
        Int(wide.unsafe_ptr()),
        UInt32(units),
        chrome.text_format,
        width,
        1000.0,
        com_addr(layout),
    )
    _ = wide
    return layout


def _draw_layout(
    this: OpaquePointer[MutUntrackedOrigin],
    layout: Int,
    brush: Int,
    x: Float32,
    y: Float32,
) raises:
    """Draw a laid-out line at a point.

    `DrawTextLayout` takes its origin BY VALUE, and an eight-byte structure
    of two floats travels in a general register on this ABI -- as its bit
    pattern, not as two floats in SSE registers. So the point is packed into
    an integer here. Getting this wrong does not fail to compile; it draws
    text somewhere surprising.
    """
    var point = D2D_POINT_2F(x, y)
    var packed = Pointer(to=point).unsafe_bitcast[Int64]()[]
    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int64, Int, Int, UInt32
        ) thin abi("C") -> NoneType,
        "ID2D1RenderTarget",
        "DrawTextLayout",
    ](this)(this, packed, layout, brush, UInt32(0))


def _brush(target: Int, colour: Int) raises -> Int:
    """A solid colour brush on the render target."""
    var this = OpaquePointer[MutUntrackedOrigin](unsafe_from_address=target)
    var c = D2D_COLOR_F.rgb(colour)
    var brush = Int(0)
    _ = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Pointer[D2D_COLOR_F, MutAnyOrigin],
            Int,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> Int32,
        "ID2D1RenderTarget",
        "CreateSolidColorBrush",
    ](this)(this, com_addr(c), 0, com_addr(brush))
    _ = c
    return brush


def _release(ptr: Int) raises:
    """Drop one reference on a raw interface pointer."""
    if ptr == 0:
        return
    var p = OpaquePointer[MutUntrackedOrigin](unsafe_from_address=ptr)
    _ = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> UInt32,
        "IUnknown",
        "Release",
    ](p)(p)


def release_cache(mut grid: Grid) raises:
    """Let go of every cached layout."""
    for i in range(grid.capacity):
        _release(grid.cached_layout[i])
        grid.cached_layout[i] = 0
        grid.cached_line[i] = -1


# ===----------------------------------------------------------------------===#
# Reaching the document from a window handle
#
# The window procedure is captureless and the agent runs inside it, so both
# find the document the same way: through the pointer Windows keeps for the
# window. These live here rather than in `griddle` because the agent needs
# them too, and the agent is imported by `griddle` rather than the other way
# round.
# ===----------------------------------------------------------------------===#


def doc_of(hwnd: Int) raises -> Int:
    """The address of a window's document, or zero if it has none."""
    var GetWindowLongPtrW = win32[
        def (Int, c_int) thin abi("C") -> Int, "GetWindowLongPtrW"
    ]()
    var stored = GetWindowLongPtrW(
        hwnd, c_int(winkb_constant["GWLP_USERDATA"]())
    )
    if stored == 0:
        return 0
    return Pointer[Chrome, MutAnyOrigin](unsafe_from_address=stored)[].doc


def presents_immediately(hwnd: Int) raises -> Bool:
    """Whether this window's target skips the wait for the vertical blank."""
    var GetWindowLongPtrW = win32[
        def (Int, c_int) thin abi("C") -> Int, "GetWindowLongPtrW"
    ]()
    var stored = GetWindowLongPtrW(
        hwnd, c_int(winkb_constant["GWLP_USERDATA"]())
    )
    if stored == 0:
        return False
    return Pointer[Chrome, MutAnyOrigin](unsafe_from_address=stored)[].immediate


def page_lines(hwnd: Int) raises -> Int:
    """How many lines one page of this window's editor holds."""
    var address = doc_of(hwnd)
    if address == 0:
        return 1
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)
    var GetClientRect = win32[
        def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
        "GetClientRect",
    ]()
    var rc = RECT()
    _ = GetClientRect(hwnd, Pointer(to=rc).unsafe_origin_cast[MutAnyOrigin]())
    var editor = Layout(
        Int(rc.right - rc.left), Int(rc.bottom - rc.top)
    ).editor()
    # One line short of a screenful, so a page turn keeps a line of context.
    var whole = doc[].grid.visible_lines(editor.bottom - editor.top) - 1
    return whole if whole > 1 else 1


def scroll_to(hwnd: Int, line: Int) raises -> Int:
    """Put `line` at the top of this window's editor.

    Clamped so the document cannot be scrolled off either end. Asking for a
    line past the end lands on the last one, which is what `End` wants.

    Args:
        hwnd: The window to scroll.
        line: The line to show first, zero-based.

    Returns:
        The line actually shown first.

    Raises:
        If the window cannot be read.
    """
    var address = doc_of(hwnd)
    if address == 0:
        return 0
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)
    var last = doc[].rope.line_count() - 1
    var want = line
    if want > last:
        want = last
    if want < 0:
        want = 0
    if want == doc[].grid.top_line:
        return want
    doc[].grid.top_line = want

    var InvalidateRect = win32[
        def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
    ]()
    # Erasing the background first would flash: Direct2D clears the surface
    # itself, and letting Windows paint over it in between is visible.
    _ = InvalidateRect(hwnd, 0, c_int(0))
    return want


def scroll_by(hwnd: Int, lines: Int) raises -> Int:
    """Move this window's editor by a number of lines, up being negative."""
    var address = doc_of(hwnd)
    if address == 0:
        return 0
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)
    return scroll_to(hwnd, doc[].grid.top_line + lines)


def _bits(hwnd: Int) raises -> Tuple[Int, Int]:
    """A window's document and chrome addresses, or zeroes."""
    var GetWindowLongPtrW = win32[
        def (Int, c_int) thin abi("C") -> Int, "GetWindowLongPtrW"
    ]()
    var stored = GetWindowLongPtrW(
        hwnd, c_int(winkb_constant["GWLP_USERDATA"]())
    )
    if stored == 0:
        return (0, 0)
    return (
        Pointer[Chrome, MutAnyOrigin](unsafe_from_address=stored)[].doc,
        stored,
    )


def caret_report(hwnd: Int) raises -> String:
    """Where the caret is, and where that puts it on screen."""
    var bits = _bits(hwnd)
    if bits[0] == 0:
        return String("error: this window has no document")
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=bits[0])
    var chrome = Pointer[Chrome, MutAnyOrigin](unsafe_from_address=bits[1])
    var dwrite = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=chrome[].dwrite
    )
    var text = doc[].rope.line(doc[].caret_line)
    # Measured before it is reported: caret_x returns early at column zero,
    # so a fresh window would otherwise report an advance of nothing.
    _ = advance_of(doc[].grid, dwrite, chrome[])
    var x = caret_x(
        doc[].grid,
        dwrite,
        chrome[],
        doc[].rope,
        doc[].caret_line,
        doc[].caret_col,
        doc[].revision,
    )
    return (
        String("caret line=") + String(doc[].caret_line)
        + " col=" + String(doc[].caret_col)
        + " x=" + String(x)
        + " advance=" + String(doc[].grid.advance)
        + " path=" + ("arithmetic" if is_simple(text) else "directwrite")
    )


def caret_move(hwnd: Int, line: Int, col: Int) raises -> String:
    """Put the caret somewhere, clamped to the document."""
    var bits = _bits(hwnd)
    if bits[0] == 0:
        return String("error: this window has no document")
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=bits[0])
    var last = doc[].rope.line_count() - 1
    var want = line
    if want > last:
        want = last
    if want < 0:
        want = 0
    doc[].caret_line = want
    doc[].caret_col = col if col > 0 else 0
    var InvalidateRect = win32[
        def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
    ]()
    _ = InvalidateRect(hwnd, 0, c_int(0))
    return caret_report(hwnd)


def caret_click(hwnd: Int, x: Int, y: Int) raises -> String:
    """Put the caret where a click in the editor landed.

    The point is in client coordinates, the way Windows delivers one, so the
    editor's origin and the gutter come off here rather than at every caller.
    """
    var bits = _bits(hwnd)
    if bits[0] == 0:
        return String("error: this window has no document")
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=bits[0])
    var chrome = Pointer[Chrome, MutAnyOrigin](unsafe_from_address=bits[1])
    var dwrite = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=chrome[].dwrite
    )

    var GetClientRect = win32[
        def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
        "GetClientRect",
    ]()
    var rc = RECT()
    _ = GetClientRect(hwnd, Pointer(to=rc).unsafe_origin_cast[MutAnyOrigin]())
    var editor = Layout(
        Int(rc.right - rc.left), Int(rc.bottom - rc.top)
    ).editor()
    if Float32(x) < editor.left or Float32(y) > editor.bottom:
        return String("outside the editor")

    var row = Int((Float32(y) - editor.top) / doc[].grid.line_height)
    var line = doc[].grid.top_line + row
    var last = doc[].rope.line_count() - 1
    if line > last:
        line = last
    if line < 0:
        line = 0
    var into = Float32(x) - editor.left - Float32(GUTTER_W)
    if into < 0:
        into = 0
    doc[].caret_line = line
    doc[].caret_col = col_at_x(
        doc[].grid, dwrite, chrome[], doc[].rope, line, into, doc[].revision
    )
    var InvalidateRect = win32[
        def (Int, Int, c_int) thin abi("C") -> c_int, "InvalidateRect"
    ]()
    _ = InvalidateRect(hwnd, 0, c_int(0))
    return caret_report(hwnd)


def hittest_report(hwnd: Int, line: Int) raises -> String:
    """The caret-stop round trip for one line, as text."""
    var bits = _bits(hwnd)
    if bits[0] == 0:
        return String("error: this window has no document")
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=bits[0])
    var chrome = Pointer[Chrome, MutAnyOrigin](unsafe_from_address=bits[1])
    var dwrite = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=chrome[].dwrite
    )
    return clusters_of(
        doc[].grid, dwrite, chrome[], doc[].rope, line, doc[].revision
    )


def counters(hwnd: Int) raises -> String:
    """What the grid has been doing, as text.

    The sprint's claim is that scrolling lays out only newly exposed lines.
    This is how that gets checked: scroll a page, read the misses, and see a
    screenful rather than a document.

    Args:
        hwnd: The window to report on.

    Returns:
        The counters, as one line of text.

    Raises:
        If the window cannot be read.
    """
    var address = doc_of(hwnd)
    if address == 0:
        return String("error: this window has no document")
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)
    return (
        String("lines=") + String(doc[].rope.line_count())
        + " bytes=" + String(doc[].rope.byte_length())
        + " top=" + String(doc[].grid.top_line)
        + " rev=" + String(doc[].revision)
        + "  layouts: hits=" + String(doc[].grid.hits)
        + " misses=" + String(doc[].grid.misses)
        + " drawn=" + String(doc[].grid.drawn)
        + " cache=" + String(doc[].grid.capacity)
    )


def reset_counters(hwnd: Int) raises:
    """Zero the counters, so the next measurement starts from nothing."""
    var address = doc_of(hwnd)
    if address == 0:
        return
    var doc = Pointer[Doc, MutAnyOrigin](unsafe_from_address=address)
    doc[].grid.hits = 0
    doc[].grid.misses = 0
    doc[].grid.drawn = 0


# ===----------------------------------------------------------------------===#
# The caret: two paths, and no measurement written here
#
# `advance_of` asks DirectWrite once what a character is worth and caches it.
# `caret_x` and `col_at_x` then divide the world in two: a line of plain
# printable ASCII is arithmetic on that number, and anything else -- CJK,
# emoji, combining marks, tabs -- goes through the cached IDWriteTextLayout.
# The fast path is not an approximation of the slow one; for the lines it
# claims, the two agree exactly, which is what the round-trip check asserts.
# ===----------------------------------------------------------------------===#


def advance_of(
    mut grid: Grid,
    dwrite: OpaquePointer[MutUntrackedOrigin],
    chrome: Chrome,
) raises -> Float32:
    """One character's width in the editor face, measured once.

    Measured rather than assumed, and measured with the same call the caret
    uses, so the fast path cannot drift from the slow one by a rounding.
    Thirty-two characters divided by thirty-two, because one character's
    layout carries the face's side bearings and a long run does not.

    Args:
        grid: Where the answer is cached.
        dwrite: The DirectWrite factory.
        chrome: For the text format.

    Returns:
        The advance in DIPs.

    Raises:
        If DirectWrite refuses to lay the sample out.
    """
    if grid.advance > 0:
        return grid.advance
    var sample = String("")
    for _ in range(32):
        sample += "x"
    var layout = _make_layout(dwrite, chrome, sample, 100000.0)
    if layout == 0:
        return 0
    var end = cluster_at(layout, 32)
    _release(layout)
    grid.advance = end.left / 32.0
    return grid.advance


def caret_x(
    mut grid: Grid,
    dwrite: OpaquePointer[MutUntrackedOrigin],
    chrome: Chrome,
    rope: Rope,
    line: Int,
    col: Int,
    revision: Int,
) raises -> Float32:
    """How far along a line the caret sits, in DIPs from the text's left edge.

    Args:
        grid: The view; its layout cache and advance are used.
        dwrite: The DirectWrite factory.
        chrome: The render target and text format.
        rope: The document.
        line: Which line.
        col: The caret's UTF-16 offset within it.
        revision: The document revision, for the cache key.

    Returns:
        The x offset.

    Raises:
        If DirectWrite refuses.
    """
    if col <= 0:
        return 0
    var text = rope.line(line)
    if is_simple(text):
        return Float32(col) * advance_of(grid, dwrite, chrome)
    var layout = _layout_for(grid, dwrite, chrome, rope, line, revision)
    if layout == 0:
        return 0
    return cluster_at(layout, col).left


def col_at_x(
    mut grid: Grid,
    dwrite: OpaquePointer[MutUntrackedOrigin],
    chrome: Chrome,
    rope: Rope,
    line: Int,
    x: Float32,
    revision: Int,
) raises -> Int:
    """Which UTF-16 offset in a line a click at `x` lands on.

    Args:
        grid: The view.
        dwrite: The DirectWrite factory.
        chrome: The render target and text format.
        rope: The document.
        line: Which line.
        x: The point's x, from the text's left edge.
        revision: The document revision.

    Returns:
        The offset.

    Raises:
        If DirectWrite refuses.
    """
    var text = rope.line(line)
    if is_simple(text):
        var step = advance_of(grid, dwrite, chrome)
        if step <= 0:
            return 0
        # Rounded, not truncated: a click in the right half of a character
        # belongs to the caret stop after it, which is what DirectWrite's
        # trailing-hit flag says on the other path. Truncating here would make
        # the fast path disagree with the slow one at every glyph's midpoint.
        var col = Int((x / step) + 0.5)
        if col < 0:
            return 0
        var most = len(text.as_bytes())
        return col if col <= most else most
    var layout = _layout_for(grid, dwrite, chrome, rope, line, revision)
    if layout == 0:
        return 0
    return position_at(layout, x, 0)


def clusters_of(
    mut grid: Grid,
    dwrite: OpaquePointer[MutUntrackedOrigin],
    chrome: Chrome,
    rope: Rope,
    line: Int,
    revision: Int,
) raises -> String:
    """Walk a line's caret stops, reporting the round trip at each one.

    This is what the acceptance check reads. For every caret stop it prints
    where the caret goes, and where a click in the middle of the glyph that
    follows comes back as. Those two numbers agreeing, on a line of CJK and
    emoji and ASCII, is the whole of sprint 1.3.

    The walk steps by DirectWrite's own cluster length rather than by one,
    because a caret stop is not a code unit: an emoji is two units and a flag
    is four, and stepping by one would place the caret inside one.

    Args:
        grid: The view.
        dwrite: The DirectWrite factory.
        chrome: The render target and text format.
        rope: The document.
        line: Which line to walk.
        revision: The document revision.

    Returns:
        One line of text per caret stop: `pos x -> recovered`.

    Raises:
        If DirectWrite refuses.
    """
    var text = rope.line(line)
    var layout = _layout_for(grid, dwrite, chrome, rope, line, revision)
    if layout == 0:
        return String("error: no layout for line ") + String(line)

    var out = String("simple=") + String(is_simple(text)) + "\n"
    var pos = 0
    # Every UTF-16 unit the line has: the surrogate pairs an emoji costs are
    # units too, which is why this is not a character count.
    var units = 0
    for ch in text.codepoints():
        units += 2 if Int(ch) >= 0x10000 else 1

    while pos < units:
        var here = cluster_at(layout, pos)
        var step = Int(here.length)
        if step <= 0:
            break
        var after = cluster_at(layout, pos + step)
        # A quarter of the way in, not half. The midpoint is exactly where
        # leading becomes trailing -- it is the boundary, not a safe interior
        # point -- so probing there asks a coin-toss and gets, consistently,
        # the stop after this one. A quarter in is unambiguously this glyph's.
        var probe = here.left + (after.left - here.left) * 0.25
        var back = col_at_x(grid, dwrite, chrome, rope, line, probe, revision)
        out += (
            String(pos) + " x=" + String(here.left)
            + " w=" + String(after.left - here.left)
            + " -> " + String(back)
            + (" OK" if back == pos else " MISMATCH")
            + "\n"
        )
        pos += step

    # And the stop at the end of the line, which no glyph follows.
    var last = cluster_at(layout, units)
    var beyond = col_at_x(
        grid, dwrite, chrome, rope, line, last.left + 40.0, revision
    )
    out += (
        String(units) + " x=" + String(last.left) + " (end) -> "
        + String(beyond)
        + (" OK" if beyond == units else " MISMATCH")
        + "\n"
    )
    return out


def draw_caret(
    this: OpaquePointer[MutUntrackedOrigin],
    x: Float32,
    y: Float32,
    height: Float32,
    target: Int,
) raises:
    """A two-pixel bar at the caret.

    Two rather than one because at 96 DPI a one-pixel bar in a dark editor is
    hard to find, and because the design mock's caret is the one warm thing on
    a cold screen.
    """
    var brush = _brush(target, EMBER)
    if brush == 0:
        return
    var r = D2D_RECT_F(x, y, x + 2, y + height)
    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Pointer[D2D_RECT_F, MutAnyOrigin],
            Int,
        ) thin abi("C") -> NoneType,
        "ID2D1RenderTarget",
        "FillRectangle",
    ](this)(this, com_addr(r), brush)
    _release(brush)
