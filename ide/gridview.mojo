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

from ide.caret import cluster_at, is_simple, position_at
from ide.chrome import (
    Chrome,
    D2D_COLOR_F,
    D2D_RECT_F,
    EMBER,
    DIM,
    ERROR,
    INK,
    LINE,
    Layout,
    MATCH,
    POPUP,
    POPUP_SEL,
    SELECT,
    SYN_COMMENT,
    SYN_KEYWORD,
    SYN_NUMBER,
    SYN_STRING,
    WARN,
)
from ide.doc import Doc, Grid
from ide.diagnostics import (
    SEVERITY_ERROR,
    count_for_shown,
    nth_visible,
    on_line,
)
from ide.find import matches_in_line
from ide.lsp import (
    completion_count,
    g_comp_detail,
    g_comp_label,
    g_diag_col,
    g_diag_end,
    g_diag_line,
    g_diag_msg,
    g_diag_sev,
)
from ide.rope import Rope
from ide.win32 import scaled
from ide.syntax import (
    KIND_COMMENT,
    KIND_PLAIN,
    KIND_KEYWORD,
    KIND_NUMBER,
    KIND_STRING,
    highlight_runs,
    triple_state_after,
)


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


def draw_text(
    mut grid: Grid,
    chrome: Chrome,
    rope: Rope,
    region: D2D_RECT_F,
    revision: Int,
    caret_line: Int = -1,
    caret_col: Int = 0,
    anchor_line: Int = -1,
    anchor_col: Int = 0,
    needle: StringSlice = "",
    show_diagnostics: Bool = False,
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
        anchor_line: The selection's other end, or -1 for none.
        anchor_col: Its UTF-16 offset.
        needle: The current search, highlighted wherever it appears.
        show_diagnostics: Whether to underline what the language server
            objected to. Off when no server is running, so a document with no
            diagnostics and a document nobody has looked at are not drawn the
            same.

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
    # The gutter, in the device pixels this display actually has. Named once
    # rather than scaled at each of the eight places it is added to an x.
    var gutter = scaled(GUTTER_W, chrome.scale)

    # The selection, normalised so the drawing loop never has to think about
    # which end the person started from.
    var selected = anchor_line >= 0 and (
        anchor_line != caret_line or anchor_col != caret_col
    )
    var first_line = anchor_line
    var first_col = anchor_col
    var last_line = caret_line
    var last_col = caret_col
    if anchor_line > caret_line or (
        anchor_line == caret_line and anchor_col > caret_col
    ):
        first_line = caret_line
        first_col = caret_col
        last_line = anchor_line
        last_col = anchor_col

    # The docstring state for the first visible line, worked out once. Every
    # line after it takes the state the line before left behind.
    var in_triple = _starts_in_docstring(rope, grid.top_line)

    var row = 0
    while row < count:
        var line = grid.top_line + row
        if line >= total:
            break
        var y = region.top + Float32(row) * grid.line_height

        # Every match of the current search, under the glyphs. Searched
        # per visible line rather than once for the document: a file with a
        # million matches highlights the forty a person can see, and costs
        # what a file with three costs.
        if needle.byte_length() > 0:
            var line_text = rope.line(line)
            for at in matches_in_line(0, line_text, String(needle)):
                var from_col = _units_before(line_text, at)
                var to_col = from_col + _units_of(String(needle))
                var hx = caret_x(
                    grid, dwrite, chrome, rope, line, from_col, revision
                )
                var hx2 = caret_x(
                    grid, dwrite, chrome, rope, line, to_col, revision
                )
                if hx2 > hx:
                    _fill_rect(
                        this,
                        chrome.target,
                        region.left + gutter + hx,
                        y,
                        region.left + gutter + hx2,
                        y + grid.line_height,
                        MATCH,
                    )

        # Selection under the glyphs, so the text stays readable on top of
        # it rather than being drawn first and then covered.
        if selected and line >= first_line and line <= last_line:
            var from_x = caret_x(
                grid,
                dwrite,
                chrome,
                rope,
                line,
                first_col if line == first_line else 0,
                revision,
            )
            var to_x: Float32
            if line == last_line:
                to_x = caret_x(
                    grid, dwrite, chrome, rope, line, last_col, revision
                )
            else:
                # A line entirely inside the selection runs to its own end,
                # plus a little: the newline is selected too, and showing the
                # highlight stop at the last glyph makes a multi-line
                # selection look like it excluded the line breaks.
                to_x = _line_width(grid, dwrite, chrome, rope, line, revision)
                to_x += grid.advance
            if to_x > from_x:
                _fill_rect(
                    this,
                    chrome.target,
                    region.left + gutter + from_x,
                    y,
                    region.left + gutter + to_x,
                    y + grid.line_height,
                    SELECT,
                )

        var layout = _layout_for(
            grid, dwrite, chrome, rope, line, revision, in_triple
        )
        # Advance before drawing: what this line leaves open is what the next
        # one begins inside.
        in_triple = triple_state_after(rope.line(line), in_triple)
        if layout != 0:
            _draw_layout(
                this, layout, brush, region.left + gutter, y
            )
            grid.drawn += 1

        # The line number, laid out fresh each time: the gutter is narrow,
        # the strings are short, and caching them would double the cache to
        # save almost nothing.
        var number = String(line + 1)
        var num_layout = _make_layout(
            dwrite, chrome, number, scaled(GUTTER_W - TEXT_PAD, chrome.scale)
        )
        if num_layout != 0:
            _draw_layout(this, num_layout, gutter_brush, region.left + 6, y)
            _release(num_layout)

        # What the language server objected to, underlined. Drawn after
        # the line's text so it is not painted over, and inside the clip so a
        # long range stops at the edge of the field like everything else.
        if show_diagnostics:
            var which = on_line(line)
            if which >= 0:
                var from_col = g_diag_col()[][which]
                var to_col = g_diag_end()[][which]
                if to_col <= from_col:
                    to_col = from_col + 1
                var ax = caret_x(
                    grid, dwrite, chrome, rope, line, from_col, revision
                )
                var bx = caret_x(
                    grid, dwrite, chrome, rope, line, to_col, revision
                )
                if bx <= ax:
                    bx = ax + grid.advance
                var colour = ERROR
                if g_diag_sev()[][which] != SEVERITY_ERROR:
                    colour = WARN
                _squiggle(
                    this,
                    chrome.target,
                    region.left + gutter + ax,
                    region.left + gutter + bx,
                    y + grid.line_height - 2,
                    colour,
                )
                # And a mark in the gutter, which survives the text being
                # scrolled off the right edge.
                _fill_rect(
                    this,
                    chrome.target,
                    region.left + 2,
                    y + 4,
                    region.left + 5,
                    y + grid.line_height - 4,
                    colour,
                )

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
                + gutter
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
    in_triple: Bool = False,
) raises -> Int:
    """The cached layout for one line, making it only if it is not there.

    `in_triple` is passed in rather than worked out here. Deriving it per line
    meant `_starts_in_docstring` walking its whole lookback for every line on
    screen -- thirty-six lines times two hundred back is seven thousand rope
    reads for one frame, and a keystroke changes the revision so every frame
    paid it. Threaded down the visible range instead, it is two hundred reads
    once plus one per line. It was 21 ms a keystroke; see docs/latency.md.
    """
    var slot = line % grid.capacity
    if grid.cached_line[slot] == line and grid.cached_rev[slot] == revision:
        grid.hits += 1
        return grid.cached_layout[slot]

    grid.misses += 1
    # Whatever occupied this slot is now unreachable; let it go before the
    # slot is overwritten, or the layout leaks for the life of the window.
    _release(grid.cached_layout[slot])

    var text = rope.line(line)
    # Coloured here, once, and then cached with the layout: the lexer runs
    # when a line changes rather than when a frame is drawn.
    var made = _make_layout(
        dwrite, chrome, text, 4000.0, colour=True, in_triple=in_triple
    )
    grid.cached_line[slot] = line
    grid.cached_rev[slot] = revision
    grid.cached_layout[slot] = made
    return made


def _make_layout(
    dwrite: OpaquePointer[MutUntrackedOrigin],
    chrome: Chrome,
    text: String,
    width: Float32,
    colour: Bool = False,
    in_triple: Bool = False,
) raises -> Int:
    """Lay one line out with DirectWrite, optionally coloured.

    Args:
        dwrite: The factory.
        chrome: For the text format and the render target.
        text: The line.
        width: How wide to lay it out.
        colour: Whether to run the lexer over it and set colour ranges.
        in_triple: Whether this line begins inside a triple-quoted string.

    Returns:
        The layout, or zero.

    Raises:
        If DirectWrite refuses.
    """
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
    if colour and layout != 0:
        _colour_layout(layout, chrome, text, in_triple)
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


# ===----------------------------------------------------------------------===#


def status_line(doc: Doc) raises -> String:
    """What the status bar says: position, selection, and whether it is saved.

    One-based, because that is what a person counts in and what every compiler
    diagnostic says. Everything inside is zero-based; this is the one place
    the two meet.
    """
    var out = (
        String("Ln ") + String(doc.caret_line + 1)
        + ", Col " + String(doc.caret_col + 1)
    )
    if doc.has_selection():
        # How much is selected, in the same units the caret is in. A person
        # dragging a selection wants to know how much they have, and lines is
        # the number that matters once it is more than one.
        var lines = doc.caret_line - doc.anchor_line
        if lines < 0:
            lines = -lines
        if lines > 0:
            out += "  (" + String(lines + 1) + " lines selected)"
        else:
            var cols = doc.caret_col - doc.anchor_col
            if cols < 0:
                cols = -cols
            out += "  (" + String(cols) + " selected)"
    out += "    UTF-8"
    if doc.dirty:
        out += "    modified"
    return out


def _fill_rect(
    this: OpaquePointer[MutUntrackedOrigin],
    target: Int,
    left: Float32,
    top: Float32,
    right: Float32,
    bottom: Float32,
    colour: Int,
) raises:
    """One filled rectangle, for the selection band."""
    var brush = _brush(target, colour)
    if brush == 0:
        return
    var r = D2D_RECT_F(left, top, right, bottom)
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


def _line_width(
    mut grid: Grid,
    dwrite: OpaquePointer[MutUntrackedOrigin],
    chrome: Chrome,
    rope: Rope,
    line: Int,
    revision: Int,
) raises -> Float32:
    """How far a line's text reaches, in DIPs from the text's left edge."""
    var text = rope.line(line)
    var units = 0
    for ch in text.codepoints():
        units += 2 if Int(ch) >= 0x10000 else 1
    return caret_x(grid, dwrite, chrome, rope, line, units, revision)


def _units_of(text: String) -> Int:
    """How many UTF-16 code units a string is."""
    var n = 0
    for ch in text.codepoints():
        n += 2 if Int(ch) >= 0x10000 else 1
    return n


def _units_before(text: String, byte_offset: Int) -> Int:
    """How many UTF-16 code units precede a byte offset in a line.

    The rope answers in bytes and the caret counts in code units, and for an
    ASCII line those are the same number -- which is exactly why this has to
    exist: the case where they differ is the case that would otherwise be
    silently wrong.
    """
    if byte_offset <= 0:
        return 0
    var seen = 0
    var units = 0
    for ch in text.codepoints():
        var v = Int(ch)
        var width = 1
        if v >= 0x10000:
            width = 4
        elif v >= 0x800:
            width = 3
        elif v >= 0x80:
            width = 2
        if seen >= byte_offset:
            break
        seen += width
        units += 2 if v >= 0x10000 else 1
    return units


def _squiggle(
    this: OpaquePointer[MutUntrackedOrigin],
    target: Int,
    left: Float32,
    right: Float32,
    y: Float32,
    colour: Int,
) raises:
    """A wavy underline, as a run of two-pixel blocks alternating height.

    Not a real sine wave and not a dotted line: at this size the eye reads
    "not straight" and nothing more, and a run of rectangles costs one brush
    and no geometry. Direct2D can stroke a path, but a path per diagnostic per
    frame is a lot of allocation for something two pixels tall.
    """
    var brush = _brush(target, colour)
    if brush == 0:
        return
    var x = left
    var up = True
    while x < right:
        var top = y if up else y + 1.5
        var r = D2D_RECT_F(x, top, x + 2, top + 1.5)
        com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin],
                Pointer[D2D_RECT_F, MutAnyOrigin],
                Int,
            ) thin abi("C") -> NoneType,
            "ID2D1RenderTarget",
            "FillRectangle",
        ](this)(this, com_addr(r), brush)
        x += 2
        up = not up
    _release(brush)


comptime ISSUE_ROW_H = 18
comptime ISSUE_TOP_PAD = 26


def draw_issues(
    mut grid: Grid,
    chrome: Chrome,
    region: D2D_RECT_F,
) raises:
    """List the language server's complaints in the issues pane.

    One row each, newest interpretation of the file first -- which is to say
    in the order the server sent them, because that is document order and a
    person reading a list of problems in a file reads it top to bottom.

    Rows are laid out fresh rather than cached. The pane holds six of them and
    they change only when the server speaks, so the cache would be six entries
    that never get a hit worth having.

    Args:
        grid: The view, for its measured advance.
        chrome: The render target and text format.
        region: The issues pane.

    Raises:
        If DirectWrite refuses.
    """
    if chrome.target == 0 or chrome.text_format == 0:
        return
    var total = count_for_shown()
    if total == 0:
        return

    var this = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=chrome.target
    )
    var dwrite = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=chrome.dwrite
    )
    var ink = _brush(chrome.target, INK)
    if ink == 0:
        return

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

    var rows = Int(
        (region.bottom - region.top - scaled(ISSUE_TOP_PAD, chrome.scale))
        / scaled(ISSUE_ROW_H, chrome.scale)
    )
    var n = 0
    while n < total and n < rows:
        var which = nth_visible(n)
        if which < 0:
            break
        var y = (
            region.top
            + scaled(ISSUE_TOP_PAD, chrome.scale)
            + Float32(n) * scaled(ISSUE_ROW_H, chrome.scale)
        )
        # A dot in the row's severity colour, so the list scans by shape
        # rather than by reading every line.
        var colour = ERROR
        if g_diag_sev()[][which] != SEVERITY_ERROR:
            colour = WARN
        _fill_rect(
            this, chrome.target,
            region.left + 12, y + 5, region.left + 18, y + 11, colour,
        )
        var text = (
            String(g_diag_line()[][which] + 1)
            + ":" + String(g_diag_col()[][which] + 1)
            + "  " + g_diag_msg()[][which]
        )
        # Wide enough never to wrap: a wrapped row is two rows tall, and
        # every row below it then sits a line lower than the click handler
        # thinks it does. The clip cuts a long message off instead, which is
        # what a one-line list should do.
        var layout = _make_layout(dwrite, chrome, text, 100000.0)
        if layout != 0:
            _draw_layout(this, layout, ink, region.left + 26, y)
            _release(layout)
        n += 1

    com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> NoneType,
        "ID2D1RenderTarget",
        "PopAxisAlignedClip",
    ](this)(this)
    _release(ink)


def issue_row_at(region: D2D_RECT_F, y: Float32, scale: Float32 = 1.0) -> Int:
    """Which issue row a click at `y` is on, or -1.

    Args:
        region: The issues pane.
        y: A client y coordinate.
        scale: Device pixels per design pixel, so the rows this measures are
            the rows `draw_issues` drew.

    Returns:
        The row index, or -1 if the click is above the first row.
    """
    var into = y - region.top - scaled(ISSUE_TOP_PAD, scale)
    if into < 0:
        return -1
    return Int(into / scaled(ISSUE_ROW_H, scale))


comptime POPUP_ROW_H = 17
comptime POPUP_WIDTH = 520
comptime POPUP_MAX_ROWS = 8


def draw_popup(
    mut grid: Grid,
    chrome: Chrome,
    rope: Rope,
    region: D2D_RECT_F,
    caret_line: Int,
    caret_col: Int,
    chosen: Int,
    revision: Int,
) raises:
    """The completion list, under the caret.

    Drawn last and clipped to the editor, so it sits over the text without
    escaping the field. It follows the caret rather than living in a corner,
    because the point of a completion popup is that the eye does not have to
    go anywhere to read it.

    Args:
        grid: The view.
        chrome: The render target and text format.
        rope: The document, for the caret's x.
        region: The editor field.
        caret_line: Where the caret is.
        caret_col: And its offset.
        chosen: Which row is selected.
        revision: The document revision.

    Raises:
        If DirectWrite refuses.
    """
    var total = completion_count()
    if total == 0 or chrome.target == 0 or chrome.text_format == 0:
        return

    var this = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=chrome.target
    )
    var dwrite = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=chrome.dwrite
    )

    var rows = total if total < POPUP_MAX_ROWS else POPUP_MAX_ROWS
    # Scroll the window of rows so the chosen one is always inside it.
    var first = 0
    if chosen >= rows:
        first = chosen - rows + 1

    var caret_row = caret_line - grid.top_line
    var x = region.left + scaled(GUTTER_W, chrome.scale) + caret_x(
        grid, dwrite, chrome, rope, caret_line, caret_col, revision
    )
    var y = region.top + Float32(caret_row + 1) * grid.line_height + 2
    var row_h = scaled(POPUP_ROW_H, chrome.scale)
    var pad = scaled(4, chrome.scale)
    var height = Float32(rows) * row_h + pad * 2
    # Above the caret instead, if there is no room below. An editor that puts
    # its popup off the bottom of the window has a popup nobody can read.
    if y + height > region.bottom:
        y = region.top + Float32(caret_row) * grid.line_height - height - 2
    if y < region.top:
        y = region.top
    var right = x + scaled(POPUP_WIDTH, chrome.scale)
    if right > region.right - 8:
        right = region.right - 8
        x = right - scaled(POPUP_WIDTH, chrome.scale)
    if x < region.left:
        x = region.left

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

    _fill_rect(this, chrome.target, x, y, right, y + height, POPUP)
    # A hairline, so the list reads as sitting on top of the code rather than
    # being part of it.
    _fill_rect(this, chrome.target, x, y, right, y + 1, LINE)
    _fill_rect(this, chrome.target, x, y + height - 1, right, y + height, LINE)

    var ink = _brush(chrome.target, INK)
    var dim = _brush(chrome.target, DIM)
    if ink == 0:
        return

    for n in range(rows):
        var which = first + n
        if which >= total:
            break
        var row_y = y + pad + Float32(n) * row_h
        if which == chosen:
            _fill_rect(
                this, chrome.target,
                x + 1, row_y, right - 1, row_y + row_h,
                POPUP_SEL,
            )
        var label = g_comp_label()[][which]
        var layout = _make_layout(dwrite, chrome, label, 100000.0)
        if layout != 0:
            _draw_layout(this, layout, ink, x + 10, row_y)
            _release(layout)
        # The signature, dimmer and to the right: it is the reason to choose
        # this row, but the name is what is being looked for.
        var detail = g_comp_detail()[][which]
        if detail.byte_length() > 0 and dim != 0:
            var dlayout = _make_layout(dwrite, chrome, detail, 100000.0)
            if dlayout != 0:
                _draw_layout(
                    this, dlayout, dim,
                    x + 10 + Float32(len(label.as_bytes()) + 2) * grid.advance,
                    row_y,
                )
                _release(dlayout)

    com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> NoneType,
        "ID2D1RenderTarget",
        "PopAxisAlignedClip",
    ](this)(this)
    _release(ink)
    _release(dim)


def _colour_layout(
    layout: Int, chrome: Chrome, text: String, in_triple: Bool
) raises:
    """Paint the lexer's runs onto a laid-out line.

    `SetDrawingEffect` takes an IUnknown and Direct2D honours it when it is a
    brush, so a line is laid out once and drawn once however many colours it
    has. The alternative -- a layout per run, or a draw call per run -- is the
    shape that makes a syntax-coloured editor slower than a plain one.

    The four brushes are made once, with the render target, and kept on the
    chrome. Making one per run instead is what an obvious first version does,
    and it costs a Direct2D object per word per line per keystroke. The layout
    takes its own reference on each, which is dropped when the layout is.

    Ranges are in UTF-16 code units. The lexer counts codepoints, which is the
    same number until a line contains an emoji, so the conversion is from its
    exact byte offsets rather than from its column count.
    """
    var this = OpaquePointer[MutUntrackedOrigin](unsafe_from_address=layout)
    for run in highlight_runs(text, in_triple):
        if run.kind == KIND_PLAIN:
            continue
        var brush = chrome.brush_comment
        if run.kind == KIND_STRING:
            brush = chrome.brush_string
        elif run.kind == KIND_KEYWORD:
            brush = chrome.brush_keyword
        elif run.kind == KIND_NUMBER:
            brush = chrome.brush_number

        if brush == 0:
            continue
        var range = DWRITE_TEXT_RANGE(
            UInt32(_units_before(text, run.byte_start)),
            UInt32(
                _units_before(text, run.byte_start + run.byte_len)
                - _units_before(text, run.byte_start)
            ),
        )
        # The range is eight bytes and goes by value, which on this ABI means
        # in a register as its bit pattern -- the same shape as the point in
        # `_draw_layout`, and wrong the same silent way if it is passed by
        # address instead.
        var packed = Pointer(to=range).unsafe_bitcast[Int64]()[]
        com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], Int, Int64
            ) thin abi("C") -> Int32,
            "IDWriteTextLayout",
            "SetDrawingEffect",
        ](this)(this, brush, packed)
        _ = range


@fieldwise_init
struct DWRITE_TEXT_RANGE(Defaultable, ImplicitlyCopyable, Movable):
    """A run of text, in UTF-16 code units."""

    var startPosition: UInt32
    var length: UInt32

    def __init__(out self):
        """An empty range at the start."""
        self.startPosition = 0
        self.length = 0


# How far back to look for an unterminated docstring. Two hundred lines is
# further than any docstring in this tree and a fifth of a millisecond of rope
# walking; scanning from the top of the file would be correct and would cost
# the whole file on every newly exposed line.
comptime DOCSTRING_LOOKBACK = 200


def _starts_in_docstring(rope: Rope, line: Int) raises -> Bool:
    """Whether a line begins inside a triple-quoted string.

    The lexer is per-line, and this is the one piece of state a docstring
    needs carried across lines -- without it every continuation line of every
    docstring renders as code, which is the most obvious way for a
    syntax-coloured editor to look wrong.

    Bounded rather than exact. A docstring longer than the lookback would be
    mis-coloured from that point on; the alternative is reading from the start
    of the file each time a line scrolls into view, which on a 250,000-line
    document is the whole document per keystroke.
    """
    var from_line = line - DOCSTRING_LOOKBACK
    if from_line < 0:
        from_line = 0
    var inside = False
    for i in range(from_line, line):
        inside = triple_state_after(rope.line(i), inside)
    return inside
