"""The window's chrome, drawn by Direct2D.

Sprint 0.4. One HWND, and every region in it -- the activity rail, the
sidebar, the editor field, the two panes and the status bar -- is a
rectangle this file fills. There are no child controls and no layout engine,
which is the whole thesis: the editor's geometry is arithmetic on the client
size, and arithmetic has no pass to run.

Direct2D is GPU-accelerated by default here, which is the part that lands
harder on Windows than the Mac's Core Text into layers. The bring-up is
`ID2D1HwndRenderTarget` -- four calls, and the render target owns its own
presentation. DirectComposition is what milestone 1 wants for scrolling a
250k-line document without redrawing it, and it slots in underneath without
changing anything above; there is no reason to pay for it before the grid
exists to scroll.

Everything goes through this repository's own COM surface, in both of its
forms. Methods that answer an HRESULT -- the factories, the brush, `Resize`,
`EndDraw` -- are `Com[...]` calls, width-checked against the metadata. The
drawing calls are not: Direct2D's `BeginDraw`, `Clear`, `FillRectangle` and
`DrawText` all return void, because the API defers every error to `EndDraw`
rather than answering one per call. The typed surface refuses a void method
on purpose, so those go through `com_method_of` on the raw layer -- still at
a slot taken from the metadata, still with a spelled signature, just without
an HRESULT to check. This is the documented escape hatch doing its job the
first time a real client needed it.
"""

from std.sys._globals import named_global
from std.ffi import c_int
from std.memory import Pointer
from std.sys.info import size_of
from std.memory import OpaquePointer
from std.sys._com import ComPtr, com_addr, com_method_of, _guid_bytes
from std.sys._winkb import (
    winkb_constant,
    winkb_interface_iid,
    winkb_struct_size,
)
from std.sys.com import Com

from ide.win32 import RECT, dpi_scale, scaled, win32


# ===----------------------------------------------------------------------===#
# Colours
#
# The palette the design mock settled on, as premultiplied-free straight
# BGRA floats. Named rather than inlined so a theme is one edit, not a hunt.
# ===----------------------------------------------------------------------===#

comptime GROUND = 0x16181D  # the window behind everything
comptime PANEL = 0x1D2026  # editor field
comptime RAIL = 0x181B20  # activity rail
comptime SIDEBAR = 0x1A1D23  # file tree
comptime BAR = 0x191C21  # status bar
comptime LINE = 0x31353F  # hairline separators
comptime EMBER = 0xFF8C37  # the one accent
comptime PANEL2 = 0x23262E  # raised surfaces: a hovered or active rail cell
comptime FAINT = 0x5D6470  # idle iconography
comptime INK = 0xDFE3EA  # primary text
comptime DIM = 0x8B93A1  # secondary text
comptime SELECT = 0x2A3A55  # selected text, behind the glyphs
comptime MATCH = 0x4A3D1E  # every other match of the current search
comptime ERROR = 0xE05252  # a squiggle under something that is wrong
comptime SPLITTER_HOT = 0x4C8FD8  # a live splitter: the one blue in the chrome
comptime WARN = 0xD8A657  # and under something that is merely doubtful
comptime POPUP = 0x22262E  # the completion list's own ground
comptime POPUP_SEL = 0x2F3A4E  # and the row under the cursor
comptime STOPPED = 0x4A3A16  # the line a debugger is halted on

# Syntax colours. Chosen so the most common thing on screen is the quietest:
# most of a page of code is plain text, and a colour that shouts turns the
# whole window that colour. Keywords, strings, numbers and comments are rare
# enough each to carry a hue.
comptime SYN_COMMENT = 0x6B7280
comptime SYN_STRING = 0x8FBF7F
comptime SYN_KEYWORD = 0xC08FD8
comptime SYN_NUMBER = 0xE0A458


@fieldwise_init
struct D2D_COLOR_F(Defaultable, ImplicitlyCopyable, Movable):
    """A colour, as Direct2D takes one: straight RGBA floats."""

    var r: Float32
    var g: Float32
    var b: Float32
    var a: Float32

    def __init__(out self):
        """Opaque black."""
        self.r = 0
        self.g = 0
        self.b = 0
        self.a = 1

    @staticmethod
    def rgb(hex: Int) -> Self:
        """A colour from a 0xRRGGBB literal, opaque.

        Args:
            hex: The packed value.

        Returns:
            The colour.
        """
        return Self(
            Float32((hex >> 16) & 0xFF) / 255.0,
            Float32((hex >> 8) & 0xFF) / 255.0,
            Float32(hex & 0xFF) / 255.0,
            1.0,
        )


@fieldwise_init
struct D2D_RECT_F(Defaultable, ImplicitlyCopyable, Movable):
    """A rectangle in device-independent pixels."""

    var left: Float32
    var top: Float32
    var right: Float32
    var bottom: Float32

    def __init__(out self):
        """An empty rectangle."""
        self.left = 0
        self.top = 0
        self.right = 0
        self.bottom = 0


@fieldwise_init
struct D2D1_PIXEL_FORMAT(Defaultable, ImplicitlyCopyable, Movable):
    """The render target's format and alpha handling."""

    var format: UInt32
    var alphaMode: UInt32

    def __init__(out self):
        """Unknown format, unknown alpha -- Direct2D then picks."""
        self.format = 0
        self.alphaMode = 0


@fieldwise_init
struct D2D1_RENDER_TARGET_PROPERTIES(Defaultable, ImplicitlyCopyable, Movable):
    """How the render target should be made."""

    var type: UInt32
    var pixelFormat: D2D1_PIXEL_FORMAT
    var dpiX: Float32
    var dpiY: Float32
    var usage: UInt32
    var minLevel: UInt32

    def __init__(out self):
        """Defaults throughout: Direct2D chooses the hardware path."""
        self.type = 0
        self.pixelFormat = D2D1_PIXEL_FORMAT()
        self.dpiX = 0
        self.dpiY = 0
        self.usage = 0
        self.minLevel = 0


@fieldwise_init
struct D2D_SIZE_U(Defaultable, ImplicitlyCopyable, Movable):
    """A size in whole pixels."""

    var width: UInt32
    var height: UInt32

    def __init__(out self):
        """Zero by zero."""
        self.width = 0
        self.height = 0


@fieldwise_init
struct D2D1_HWND_RENDER_TARGET_PROPERTIES(Defaultable, ImplicitlyCopyable, Movable):
    """Which window the render target presents to, and how big it is."""

    var hwnd: Int
    var pixelSize: D2D_SIZE_U
    var presentOptions: UInt32

    def __init__(out self):
        """No window yet."""
        self.hwnd = 0
        self.pixelSize = D2D_SIZE_U()
        self.presentOptions = 0


# ===----------------------------------------------------------------------===#
# Layout
#
# The whole geometry of the IDE, as arithmetic. No measurement pass, no
# constraint solving: given a client size, every region is known.
# ===----------------------------------------------------------------------===#

comptime RAIL_W = 52
comptime SIDEBAR_W = 208  # the default; `sidebar_width` is what is drawn
comptime STATUS_H = 28
comptime PANE_H = 140  # the default; `pane_height` is what is drawn

# The two movable edges, in design pixels, at their defaults until somebody
# drags one. Held here rather than in the Layout because a Layout is built
# fresh for every frame and every hit test -- it is a view of the window size,
# not a place to keep anything.
#
# The bounds are not taste. A sidebar dragged to nothing is a sidebar nobody
# can get back, because there is no longer anything to grab; the same is true
# of the pane. The upper bounds keep the editor from disappearing instead.
comptime SIDEBAR_MIN = 80
comptime SIDEBAR_MAX = 600
comptime PANE_MIN = 60
comptime PANE_MAX = 700

# Which splitter the pointer is on, or is dragging: 1 the sidebar's, 2 the
# bottom panes', 0 neither. Drawn brighter so the edge says it can be moved
# before anybody tries -- a hairline that does nothing and a hairline that
# resizes the window look identical otherwise.
comptime g_hot_splitter = named_global["chrome.splitter.hot", Int]


def hot_splitter() -> Int:
    """Which splitter is live.

    Returns:
        1, 2, or 0 for none.
    """
    return g_hot_splitter()[]


def set_hot_splitter(which: Int):
    """Say which splitter the pointer is on.

    Args:
        which: 1 the sidebar's, 2 the bottom panes', 0 neither.
    """
    g_hot_splitter()[] = which


# Which rail cell the pointer is over, and which view the pane is showing.
# Globals for the same reason the splitters' are: paint and the mouse live
# in different modules with one captureless procedure between them.
# What the file tree is a tree OF. Held here because the heading is drawn
# here and the answer is known in the window procedure, which is the same
# division set_tab_labels makes: this module draws words it is handed and
# does not learn what a project is.
comptime g_project_label = named_global["chrome.project", String]

comptime g_hot_rail = named_global["chrome.hotrail", Int]
comptime g_rail_active = named_global["chrome.railactive", Int]

# The rail's geometry, shared by the draw and the hit test so they cannot
# disagree: cells start under a small margin and repeat on a fixed pitch,
# a 40px button with its label riding underneath.
comptime RAIL_TOP = 10
comptime RAIL_PITCH = 57
comptime RAIL_CELL = 52


def set_project_label(var name: String):
    """Say which project the file tree is showing.

    Args:
        name: The project's own name, or empty for none.
    """
    g_project_label()[] = name^


def project_label() -> String:
    """The heading over the file tree.

    Returns:
        The project's name, or the application's when there is no project --
        an empty heading over a populated tree reads as a drawing fault.
    """
    var name = g_project_label()[]
    return String("GRIDDLE") if name == "" else name^


def hot_rail() -> Int:
    """Which rail cell is under the pointer.

    Returns:
        1 to 4, or 0 for none.
    """
    return g_hot_rail()[]


def set_hot_rail(which: Int):
    """Say which rail cell the pointer is on.

    Args:
        which: 1 to 4, or 0 for none.
    """
    g_hot_rail()[] = which


def rail_active() -> Int:
    """The view the ember bar marks.

    Returns:
        1 editor, 2 Python, 4 toolchain. 3 is the Examples menu, which is
        a door rather than a place, so it is never the active view.
    """
    var it = g_rail_active()[]
    return 1 if it == 0 else it


def set_rail_active(which: Int):
    """Say which view the pane is showing.

    Args:
        which: 1 editor, 2 Python, 4 toolchain.
    """
    g_rail_active()[] = which


def rail_item(x: Int, y: Int, scale: Float32) -> Int:
    """Which rail cell a client point is in.

    Args:
        x: Client x.
        y: Client y.
        scale: Device pixels per design pixel.

    Returns:
        1 to 4, or 0 for none.
    """
    if Float32(x) >= scaled(RAIL_W, scale):
        return 0
    for i in range(4):
        var top = scaled(RAIL_TOP + i * RAIL_PITCH, scale)
        if Float32(y) >= top and Float32(y) < top + scaled(RAIL_CELL, scale):
            return i + 1
    return 0


comptime g_sidebar_w = named_global["chrome.sidebar.w", Int]
comptime g_pane_h = named_global["chrome.pane.h", Int]


def sidebar_width() -> Int:
    """The sidebar's width in design pixels.

    Returns:
        What was dragged, or the default before anything was.
    """
    var w = g_sidebar_w()[]
    return SIDEBAR_W if w == 0 else w


def set_sidebar_width(w: Int):
    """Move the splitter between the sidebar and the editor.

    Args:
        w: The wanted width in design pixels; clamped.
    """
    var want = w
    if want < SIDEBAR_MIN:
        want = SIDEBAR_MIN
    if want > SIDEBAR_MAX:
        want = SIDEBAR_MAX
    g_sidebar_w()[] = want


def pane_height() -> Int:
    """The bottom panes' height in design pixels.

    Returns:
        What was dragged, or the default before anything was.
    """
    var h = g_pane_h()[]
    return PANE_H if h == 0 else h


def set_pane_height(h: Int):
    """Move the splitter between the editor and the bottom panes.

    Args:
        h: The wanted height in design pixels; clamped.
    """
    var want = h
    if want < PANE_MIN:
        want = PANE_MIN
    if want > PANE_MAX:
        want = PANE_MAX
    g_pane_h()[] = want
comptime TAB_H = 30

# How wide a splitter is to the mouse, in design pixels. It draws as a
# hairline and grabs as a band.
comptime SPLITTER_GRAB = 6
"""The tab strip, above the editor field. One row, always present: a strip
that appears when a second file opens moves every line of the first one down
by thirty pixels while somebody is reading it."""


@fieldwise_init
struct Layout(ImplicitlyCopyable, Movable):
    """Where every region sits, for a given client size.

    The constants above are written at 96 DPI and multiplied by `scale` here,
    so the arithmetic stays the readable kind while the rectangles come out in
    the device pixels the display actually has. `scaled` rounds, which is what
    keeps two regions meant to share an edge sharing it.
    """

    var width: Int
    var height: Int
    var scale: Float32

    def rail_w(self) -> Float32:
        """The rail's width in device pixels."""
        return scaled(RAIL_W, self.scale)

    def tabs(self) -> D2D_RECT_F:
        """The tab strip, across the top of the editor field."""
        return D2D_RECT_F(
            self.gutter_x(), 0, Float32(self.width),
            scaled(TAB_H, self.scale),
        )

    def gutter_x(self) -> Float32:
        """Where the editor field begins: past the rail and the sidebar."""
        return scaled(RAIL_W + sidebar_width(), self.scale)

    def _bar_top(self) -> Float32:
        """The top of the status bar."""
        return Float32(self.height) - scaled(STATUS_H, self.scale)

    def _pane_top(self) -> Float32:
        """The top of the bottom panes."""
        return self._bar_top() - scaled(pane_height(), self.scale)

    def sidebar_splitter(self) -> D2D_RECT_F:
        """The band that resizes the sidebar.

        Wider than the line it appears to be, and deliberately: a one-pixel
        target is a target nobody can hit, and at 150% scaling it is not even
        one pixel. Six design pixels centred on the edge is what a person can
        grab without noticing they aimed.
        """
        var x = self.gutter_x()
        var half = scaled(SPLITTER_GRAB, self.scale) * 0.5
        return D2D_RECT_F(x - half, 0, x + half, self._bar_top())

    def pane_splitter(self) -> D2D_RECT_F:
        """The band that resizes the bottom panes."""
        var y = self._pane_top()
        var half = scaled(SPLITTER_GRAB, self.scale) * 0.5
        return D2D_RECT_F(
            self.gutter_x(), y - half, Float32(self.width), y + half
        )

    def _split(self) -> Float32:
        """Where the issues pane ends and the output pane begins."""
        var left = self.gutter_x()
        return left + Float32(Int((Float32(self.width) - left) / 2))

    def rail(self) -> D2D_RECT_F:
        """The activity rail down the left edge."""
        return D2D_RECT_F(0, 0, self.rail_w(), self._bar_top())

    def sidebar(self) -> D2D_RECT_F:
        """The file tree, beside the rail."""
        return D2D_RECT_F(
            self.rail_w(), 0, self.gutter_x(), self._bar_top()
        )

    def editor(self) -> D2D_RECT_F:
        """The text grid: everything the tabs, panes and bars do not take."""
        return D2D_RECT_F(
            self.gutter_x(),
            scaled(TAB_H, self.scale),
            Float32(self.width),
            self._pane_top(),
        )

    def issues(self) -> D2D_RECT_F:
        """The issues pane, bottom left of the editor field."""
        return D2D_RECT_F(
            self.gutter_x(), self._pane_top(), self._split(), self._bar_top()
        )

    def output(self) -> D2D_RECT_F:
        """The build and run pane, beside the issues."""
        return D2D_RECT_F(
            self._split(),
            self._pane_top(),
            Float32(self.width),
            self._bar_top(),
        )

    def status(self) -> D2D_RECT_F:
        """The status bar along the bottom."""
        return D2D_RECT_F(
            0, self._bar_top(), Float32(self.width), Float32(self.height)
        )


# ===----------------------------------------------------------------------===#
# The render target
# ===----------------------------------------------------------------------===#


@fieldwise_init
struct Chrome(ImplicitlyCopyable, Movable):
    """Everything needed to draw, as raw interface addresses.

    Raw rather than owning, because this lives in the window's user data
    across message dispatches and a captureless window procedure has to be
    able to pick it up again. `release` is called once, when the window goes
    away.
    """

    var factory: Int
    var target: Int
    var dwrite: Int
    var text_format: Int
    # Two more faces at other sizes: the rail's glyphs draw larger than
    # the text and its labels smaller, and a text format bakes its size
    # in at creation.
    var icon_format: Int
    var tiny_format: Int
    # The drop target's interface pointer. It lives here because this struct
    # is what the window keeps, and a captureless procedure has exactly one
    # place to look for anything.
    var drop_target: Int
    # The document being edited, as a `Doc*`. An address rather than the
    # struct because this module must not know what a rope is -- and because
    # the window procedure has one pointer to work with and everything it
    # needs has to be reachable from it.
    var doc: Int
    # Whether this target presents without waiting for the vertical blank.
    # Kept because a lost device has to be rebuilt the same way it was built,
    # and because a measurement that silently reverts to vsync is a lie.
    var immediate: Bool
    # The TSF activation, as a `Tsf*`. Here for the same reason the drop
    # target is: the window procedure has one pointer to work with, and
    # everything the window owns has to be reachable from it.
    var tsf: Int
    # Device pixels per design pixel, from the display this window is on.
    # Everything drawn multiplies by it, including the font: the text format
    # is made at this size, so a redraw at a new scale needs a new format --
    # which is why a DPI change goes through the same rebuild a lost device
    # does. The zoom control the View menu will grow folds into this number.
    var scale: Float32
    # The four syntax brushes, made once with the render target rather than
    # per coloured run. A run is a word: making and dropping a Direct2D brush
    # for each one, on every line, on every keystroke, is the shape that makes
    # a coloured editor slower than a plain one. They belong to the target, so
    # they are rebuilt whenever it is.
    var brush_comment: Int
    var brush_string: Int
    var brush_keyword: Int
    var brush_number: Int

    def __init__(out self):
        """Nothing brought up yet."""
        self.factory = 0
        self.target = 0
        self.dwrite = 0
        self.text_format = 0
        self.icon_format = 0
        self.tiny_format = 0
        self.drop_target = 0
        self.doc = 0
        self.immediate = False
        self.tsf = 0
        self.scale = 1.0
        self.brush_comment = 0
        self.brush_string = 0
        self.brush_keyword = 0
        self.brush_number = 0


def bring_up(
    hwnd: Int, width: Int, height: Int, immediate: Bool = False
) raises -> Chrome:
    """Create the Direct2D and DirectWrite objects this window draws with.

    Args:
        hwnd: The window to present to.
        width: Client width in pixels.
        height: Client height in pixels.
        immediate: Present without waiting for the vertical blank. Off, because
            tearing is not what anyone wants to look at. On, a frame costs what
            it costs rather than what the display refreshes at, which is the
            only way to find out how much headroom the grid actually has.

    Returns:
        The chrome, ready to draw.

    Raises:
        If Direct2D or DirectWrite refuses.
    """
    comptime assert (
        size_of[D2D1_RENDER_TARGET_PROPERTIES]()
        == winkb_struct_size["D2D1_RENDER_TARGET_PROPERTIES"]()
    ), "D2D1_RENDER_TARGET_PROPERTIES does not match Windows"
    comptime assert (
        size_of[D2D1_HWND_RENDER_TARGET_PROPERTIES]()
        == winkb_struct_size["D2D1_HWND_RENDER_TARGET_PROPERTIES"]()
    ), "D2D1_HWND_RENDER_TARGET_PROPERTIES does not match Windows"

    var chrome = Chrome()
    # Read once, here, and carried on the chrome: every rectangle and the
    # font size come from it, so a single reading keeps them consistent even
    # if the window is moved mid-frame.
    chrome.scale = dpi_scale(hwnd)

    # The two factories are plain exports; everything after them is COM.
    var D2D1CreateFactory = win32[
        def (
            UInt32, Int, Int, Pointer[Int, MutAnyOrigin]
        ) thin abi("C") -> Int32,
        "D2D1CreateFactory",
    ]()
    var DWriteCreateFactory = win32[
        def (UInt32, Int, Pointer[Int, MutAnyOrigin]) thin abi("C") -> Int32,
        "DWriteCreateFactory",
    ]()

    var d2d_iid = iid_bytes["ID2D1Factory"]()
    var hr = D2D1CreateFactory(
        0,  # D2D1_FACTORY_TYPE_SINGLE_THREADED
        Int(d2d_iid.unsafe_ptr()),
        0,
        Pointer(to=chrome.factory).unsafe_origin_cast[MutAnyOrigin](),
    )
    _ = d2d_iid
    if hr != 0 or chrome.factory == 0:
        raise Error("D2D1CreateFactory failed, hr = " + String(hr))

    var rt_props = D2D1_RENDER_TARGET_PROPERTIES()
    # Pin the render target to 96 DPI so one device-independent pixel is one
    # device pixel. The whole layout is arithmetic on the client size in
    # PIXELS -- that is the thesis -- and leaving Direct2D to scale by the
    # display's DPI silently multiplies every rectangle, which puts the
    # status bar off the bottom of a window it is supposed to sit in. The
    # editor grid will want the same identity mapping for glyph positions.
    rt_props.dpiX = 96.0
    rt_props.dpiY = 96.0
    var hwnd_props = D2D1_HWND_RENDER_TARGET_PROPERTIES()
    hwnd_props.hwnd = hwnd
    hwnd_props.pixelSize = D2D_SIZE_U(UInt32(width), UInt32(height))
    chrome.immediate = immediate
    if immediate:
        # From the metadata, not from memory: this enumeration has a
        # RETAIN_CONTENTS at 1 and an IMMEDIATELY at 2, and guessing picked
        # the wrong one -- which does not fail, it just quietly keeps
        # presenting on the vertical blank and reports the refresh rate as
        # though it were the frame cost.
        hwnd_props.presentOptions = UInt32(
            winkb_constant["D2D1_PRESENT_OPTIONS_IMMEDIATELY"]()
        )

    var factory = Com[StaticString("ID2D1Factory")](borrowed=chrome.factory)
    _ = factory.CreateHwndRenderTarget(
        com_addr(rt_props),
        com_addr(hwnd_props),
        com_addr(chrome.target),
    )
    _ = rt_props
    _ = hwnd_props
    if chrome.target == 0:
        raise Error("CreateHwndRenderTarget produced nothing")

    var dw_iid = iid_bytes["IDWriteFactory"]()
    hr = DWriteCreateFactory(
        0,  # DWRITE_FACTORY_TYPE_SHARED
        Int(dw_iid.unsafe_ptr()),
        com_addr(chrome.dwrite),
    )
    _ = dw_iid
    if hr != 0 or chrome.dwrite == 0:
        raise Error("DWriteCreateFactory failed, hr = " + String(hr))

    # Cascadia Mono is the editor face; Consolas is the fallback every
    # Windows has. DirectWrite falls back on its own when the family is
    # absent, so naming the preferred one is enough.
    var family = utf16("Cascadia Mono")
    var locale = utf16("en-us")
    var dwrite = Com[StaticString("IDWriteFactory")](borrowed=chrome.dwrite)
    _ = dwrite.CreateTextFormat(
        Int(family.unsafe_ptr()),
        Int(0),  # the system font collection
        UInt32(400),  # DWRITE_FONT_WEIGHT_NORMAL
        UInt32(0),  # DWRITE_FONT_STYLE_NORMAL
        UInt32(5),  # DWRITE_FONT_STRETCH_NORMAL
        Float32(12.0) * chrome.scale,
        Int(locale.unsafe_ptr()),
        com_addr(chrome.text_format),
    )
    _ = family
    _ = locale
    if chrome.text_format == 0:
        raise Error("CreateTextFormat produced nothing")

    # The rail's two sizes, same family -- DirectWrite finds the symbol
    # glyphs by fallback on its own -- and centred both ways, because a
    # glyph in a button is centred or it is visibly not.
    var rail_family = utf16("Cascadia Mono")
    var rail_locale = utf16("en-us")
    _ = dwrite.CreateTextFormat(
        Int(rail_family.unsafe_ptr()),
        Int(0),
        UInt32(400),
        UInt32(0),
        UInt32(5),
        Float32(16.0) * chrome.scale,
        Int(rail_locale.unsafe_ptr()),
        com_addr(chrome.icon_format),
    )
    _ = dwrite.CreateTextFormat(
        Int(rail_family.unsafe_ptr()),
        Int(0),
        UInt32(400),
        UInt32(0),
        UInt32(5),
        Float32(8.5) * chrome.scale,
        Int(rail_locale.unsafe_ptr()),
        com_addr(chrome.tiny_format),
    )
    _ = rail_family
    _ = rail_locale
    for centred in [chrome.icon_format, chrome.tiny_format]:
        if centred == 0:
            continue
        var fmt = OpaquePointer[MutUntrackedOrigin](
            unsafe_from_address=centred
        )
        # DWRITE_TEXT_ALIGNMENT_CENTER and DWRITE_PARAGRAPH_ALIGNMENT_CENTER
        # are both 2, which is a coincidence and not a shared meaning.
        _ = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], c_int
            ) thin abi("C") -> Int32,
            "IDWriteTextFormat",
            "SetTextAlignment",
        ](fmt)(fmt, c_int(2))
        _ = com_method_of[
            def (
                OpaquePointer[MutUntrackedOrigin], c_int
            ) thin abi("C") -> Int32,
            "IDWriteTextFormat",
            "SetParagraphAlignment",
        ](fmt)(fmt, c_int(2))

    # The syntax brushes, now that there is a target to make them on.
    chrome.brush_comment = _solid(chrome.target, SYN_COMMENT)
    chrome.brush_string = _solid(chrome.target, SYN_STRING)
    chrome.brush_keyword = _solid(chrome.target, SYN_KEYWORD)
    chrome.brush_number = _solid(chrome.target, SYN_NUMBER)

    return chrome


def _solid(target: Int, colour: Int) raises -> Int:
    """A solid colour brush on the render target.

    The same call `gridview._brush` makes; here because the syntax brushes are
    made once, with the target, and kept on the chrome beside it.

    Args:
        target: The render target.
        colour: A 0xRRGGBB literal.

    Returns:
        The brush, or zero.

    Raises:
        If Direct2D refuses.
    """
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


def draw(
    chrome: Chrome, width: Int, height: Int, status: StringSlice = "Ln 1, Col 1"
) raises -> Layout:
    """Paint every region of the chrome, and leave the batch open.

    Everything Direct2D draws between `BeginDraw` and `EndDraw` is one batch,
    so the text cannot be a second call that opens its own -- and the chrome
    cannot draw it either, because the grid knows about the rope and this
    module deliberately does not. So the batch is left open and the returned
    layout says where the text goes; `finish` closes it. The window procedure
    is the one place that knows about both halves, which is where a decision
    that needs both belongs.

    Args:
        chrome: The render target and its friends.
        width: Client width.
        height: Client height.
        status: What the status bar should say. Composed by the caller,
            because this module knows about rectangles and not about carets.

    Returns:
        Where every region landed, for whoever draws into them next.

    Raises:
        If a Direct2D call fails.
    """
    var layout = Layout(width, height, chrome.scale)
    if chrome.target == 0:
        return layout
    var rt = Com[StaticString("ID2D1HwndRenderTarget")](borrowed=chrome.target)

    # Resize first: a window that grew since the last paint would otherwise
    # present a stretched copy of the old surface.
    var size = D2D_SIZE_U(UInt32(width), UInt32(height))
    _ = rt.Resize(com_addr(size))
    _ = size

    var this = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=chrome.target
    )
    com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> NoneType,
        "ID2D1HwndRenderTarget",
        "BeginDraw",
    ](this)(this)

    var ground = D2D_COLOR_F.rgb(GROUND)
    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Pointer[D2D_COLOR_F, MutAnyOrigin],
        ) thin abi("C") -> NoneType,
        "ID2D1HwndRenderTarget",
        "Clear",
    ](this)(this, com_addr(ground))
    _ = ground

    _fill(chrome.target, layout.tabs(), RAIL)
    _fill(chrome.target, layout.editor(), PANEL)
    _fill(chrome.target, layout.rail(), RAIL)
    _fill(chrome.target, layout.sidebar(), SIDEBAR)
    _fill(chrome.target, layout.issues(), PANEL)
    _fill(chrome.target, layout.output(), PANEL)
    _fill(chrome.target, layout.status(), BAR)

    # Hairlines where regions meet. Drawn as thin filled rectangles rather
    # than strokes: a stroke straddles its line and lands on half-pixels.
    #
    # Off the layout's rectangles, like everything else. Written longhand from
    # the constants they were the same arithmetic the layout does, until the
    # layout started scaling and they did not -- so the panes moved and their
    # borders stayed behind.
    var hair = scaled(1, chrome.scale)
    var rail = layout.rail()
    var editor = layout.editor()
    var bar = layout.status()
    _fill(
        chrome.target,
        D2D_RECT_F(rail.right, 0, rail.right + hair, bar.top),
        LINE,
    )
    # The two movable ones are drawn thicker and blue while the pointer is on
    # them or dragging them. A hairline that does nothing and a hairline that
    # resizes the window look identical, and the difference is worth showing
    # before somebody has to discover it by trying.
    var hot = hot_splitter()
    var live = scaled(3, chrome.scale)
    _fill(
        chrome.target,
        D2D_RECT_F(
            editor.left,
            0,
            editor.left + (live if hot == 1 else hair),
            bar.top,
        ),
        SPLITTER_HOT if hot == 1 else LINE,
    )
    _fill(
        chrome.target,
        D2D_RECT_F(0, bar.top - hair, Float32(width), bar.top),
        LINE,
    )
    _fill(
        chrome.target,
        D2D_RECT_F(
            editor.left,
            editor.bottom - (live if hot == 2 else hair),
            Float32(width),
            editor.bottom,
        ),
        SPLITTER_HOT if hot == 2 else LINE,
    )

    # The rail's four views, as the design drew them: a glyph in a 40px
    # cell, a tiny label under it, hover lifting the cell, and the ember
    # bar beside whichever view the pane is showing. Geometry comes from
    # the same constants the hit test reads, so a click lands where the
    # eye says it will.
    var glyphs = List[String]()
    glyphs.append(chr(0x2317))   # EDIT
    glyphs.append(chr(0x1F40D))  # PY
    glyphs.append(chr(0x25A6))   # EX
    glyphs.append(chr(0x2692))   # TOOL
    var titles = List[String]()
    titles.append(String("EDIT"))
    titles.append(String("PY"))
    titles.append(String("EX"))
    titles.append(String("TOOL"))
    var active = rail_active()
    var pointer_on = hot_rail()
    for i in range(4):
        var which = i + 1
        var top = scaled(RAIL_TOP + i * RAIL_PITCH, chrome.scale)
        var button = D2D_RECT_F(
            scaled(6, chrome.scale),
            top,
            scaled(46, chrome.scale),
            top + scaled(40, chrome.scale),
        )
        if which == active or which == pointer_on:
            _fill(chrome.target, button, PANEL2)
        if which == active:
            _fill(
                chrome.target,
                D2D_RECT_F(
                    0,
                    top + scaled(9, chrome.scale),
                    scaled(3, chrome.scale),
                    top + scaled(31, chrome.scale),
                ),
                EMBER,
            )
        var ink = FAINT
        if which == active:
            ink = EMBER
        elif which == pointer_on:
            ink = DIM
        _boxed(chrome, glyphs[i], chrome.icon_format, button, ink)
        _boxed(
            chrome,
            titles[i],
            chrome.tiny_format,
            D2D_RECT_F(
                0,
                button.bottom,
                scaled(RAIL_CELL, chrome.scale),
                button.bottom + scaled(12, chrome.scale),
            ),
            FAINT,
        )

    # Every one of these is placed off the layout's own rectangles rather than
    # off the constants. They used to be written out longhand -- `RAIL_W +
    # SIDEBAR_W + 12`, `height - STATUS_H - PANE_H + 8` -- which was the same
    # arithmetic the layout does and stopped being so the moment the layout
    # started scaling: the panes moved and their headings stayed at 96 DPI.
    # Neither bottom pane has a fixed heading, and both for the same reason:
    # what they are showing changes, so the thing that draws the contents is
    # the only thing that knows what to call them. The left one shows
    # problems, references, variables, the outline, the toolchain or Python.
    # The right one was labelled here, from when OUTPUT was all it could ever
    # say -- and then `draw_output` grew a heading of its own that also
    # reports "running" or a line count. Both were being drawn, two design
    # pixels apart, and the word looked blurred rather than doubled, which is
    # why it survived this long.
    _label(
        chrome, project_label(), layout.rail_w() + scaled(14, chrome.scale),
        scaled(10, chrome.scale), DIM,
    )
    _label(
        chrome, status, scaled(12, chrome.scale),
        layout.status().top + scaled(7, chrome.scale), DIM,
    )

    return layout


def finish(chrome: Chrome) raises -> Int:
    """Close the batch `draw` opened and present it.

    Direct2D reports nothing per call: every failure between `BeginDraw` and
    here is deferred to this one HRESULT. It is returned rather than raised
    because `D2DERR_RECREATE_TARGET` is not really an error -- it means the
    device was lost, and the caller's answer is to build a new target, not to
    unwind. That is also why this goes through the raw layer: a `Com[...]`
    call raises on any failing HRESULT, which is right nearly everywhere and
    wrong here, where the interesting answer is a failing one.

    Args:
        chrome: The render target.

    Returns:
        The batch's HRESULT, or zero when there was nothing to close.

    Raises:
        If the call itself cannot be made.
    """
    if chrome.target == 0:
        return 0
    var this = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=chrome.target
    )
    var tag1 = Int(0)
    var tag2 = Int(0)
    var hr = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Pointer[Int, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> Int32,
        "ID2D1HwndRenderTarget",
        "EndDraw",
    ](this)(this, com_addr(tag1), com_addr(tag2))
    _ = tag1
    _ = tag2
    return Int(hr)


def _fill(target: Int, rect: D2D_RECT_F, colour: Int) raises:
    """Fill one rectangle in a solid colour."""
    var rt = Com[StaticString("ID2D1HwndRenderTarget")](borrowed=target)
    var c = D2D_COLOR_F.rgb(colour)
    var brush = Int(0)
    _ = rt.CreateSolidColorBrush(
        com_addr(c),
        0,
        com_addr(brush),
    )
    _ = c
    if brush == 0:
        return
    var r = rect
    var this = OpaquePointer[MutUntrackedOrigin](unsafe_from_address=target)
    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Pointer[D2D_RECT_F, MutAnyOrigin],
            Int,
        ) thin abi("C") -> NoneType,
        "ID2D1HwndRenderTarget",
        "FillRectangle",
    ](this)(this, com_addr(r), brush)
    _ = r
    _release(brush)


def _boxed(
    chrome: Chrome,
    text: StringSlice,
    format: Int,
    box: D2D_RECT_F,
    colour: Int,
) raises:
    """Draw text centred in a rectangle, in the given face and colour."""
    if format == 0:
        return
    var rt = Com[StaticString("ID2D1HwndRenderTarget")](
        borrowed=chrome.target
    )
    var c = D2D_COLOR_F.rgb(colour)
    var brush = Int(0)
    _ = rt.CreateSolidColorBrush(com_addr(c), 0, com_addr(brush))
    _ = c
    if brush == 0:
        return
    var wide_text = utf16(text)
    var count = len(wide_text) - 1
    var rect = box
    var this = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=chrome.target
    )
    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            UInt32,
            Int,
            Pointer[D2D_RECT_F, MutAnyOrigin],
            Int,
            UInt32,
            UInt32,
        ) thin abi("C") -> NoneType,
        "ID2D1HwndRenderTarget",
        "DrawText",
    ](this)(
        this,
        Int(wide_text.unsafe_ptr()),
        UInt32(count),
        format,
        com_addr(rect),
        brush,
        UInt32(0),
        UInt32(0),  # DWRITE_MEASURING_MODE_NATURAL
    )
    _ = wide_text
    _release(brush)


def _label(chrome: Chrome, text: StringSlice,
           x: Float32, y: Float32, colour: Int) raises:
    """Draw one short label at a point.

    The length comes from the text rather than from the caller. It used to be
    a parameter, and one call site had been passing eight for a seven-letter
    word since sprint 0.4 -- drawing the NUL, which is invisible, which is why
    it survived.
    """
    var rt = Com[StaticString("ID2D1HwndRenderTarget")](
        borrowed=chrome.target
    )
    var c = D2D_COLOR_F.rgb(colour)
    var brush = Int(0)
    _ = rt.CreateSolidColorBrush(
        com_addr(c),
        0,
        com_addr(brush),
    )
    _ = c
    if brush == 0:
        return
    var wide_text = utf16(text)
    var count = len(wide_text) - 1  # the NUL is not a character
    var box = D2D_RECT_F(x, y, x + 400, y + 24)
    var this = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=chrome.target
    )
    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            UInt32,
            Int,
            Pointer[D2D_RECT_F, MutAnyOrigin],
            Int,
            UInt32,
            UInt32,
        ) thin abi("C") -> NoneType,
        "ID2D1HwndRenderTarget",
        "DrawText",
    ](this)(
        this,
        Int(wide_text.unsafe_ptr()),
        UInt32(count),
        chrome.text_format,
        com_addr(box),
        brush,
        UInt32(0),
        UInt32(0),
    )
    _ = wide_text
    _ = box
    _release(brush)


def release(chrome: Chrome) raises:
    """Drop every interface the chrome holds."""
    _release(chrome.brush_comment)
    _release(chrome.brush_string)
    _release(chrome.brush_keyword)
    _release(chrome.brush_number)
    _release(chrome.text_format)
    _release(chrome.icon_format)
    _release(chrome.tiny_format)
    _release(chrome.dwrite)
    _release(chrome.target)
    _release(chrome.factory)


def _release(ptr: Int) raises:
    """Drop one reference on a raw interface pointer."""
    if ptr == 0:
        return
    _ = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> UInt32,
        "IUnknown",
        "Release",
    ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=ptr))(
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=ptr)
    )


def iid_bytes[name: StaticString]() -> List[UInt8]:
    """The 16 IID bytes of a named interface, from the metadata.

    Parameters:
        name: The interface, e.g. "ID2D1Factory".

    Returns:
        Its IID, in COM's mixed-endian byte order.
    """
    return _guid_bytes(String(winkb_interface_iid[name]()))


def utf16(s: StringSlice) -> List[UInt16]:
    """A NUL-terminated UTF-16 copy of text.

    It used to copy one byte to one unit, which is Latin-1 rather than UTF-8,
    and its docstring said "ASCII text" -- true of every label there was:
    GRIDDLE, OUTPUT, and a status line of digits and commas. The status line
    now carries whatever a person types into the prompt, so the shortcut
    became visible the first time something non-ASCII went through it: the
    caret glyph U+2502 is E2 94 82 in UTF-8, and one-byte-per-unit drew it as
    three Latin-1 characters starting with an a-circumflex.

    Surrogate pairs are here for the same reason they are in the clipboard:
    UTF-16 has no other way to say a character above the basic plane, and a
    search for an emoji is a perfectly ordinary thing to type.
    """
    var out = List[UInt16]()
    for c in s.codepoints():
        var v = Int(c)
        if v >= 0x10000:
            var u = v - 0x10000
            out.append(UInt16(0xD800 + (u >> 10)))
            out.append(UInt16(0xDC00 + (u & 0x3FF)))
        else:
            out.append(UInt16(v))
    out.append(0)
    return out^
