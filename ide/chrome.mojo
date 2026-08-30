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

from ide.win32 import RECT, win32


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
comptime INK = 0xDFE3EA  # primary text
comptime DIM = 0x8B93A1  # secondary text
comptime SELECT = 0x2A3A55  # selected text, behind the glyphs


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
comptime SIDEBAR_W = 208
comptime STATUS_H = 28
comptime PANE_H = 140


@fieldwise_init
struct Layout(ImplicitlyCopyable, Movable):
    """Where every region sits, for a given client size."""

    var width: Int
    var height: Int

    def rail(self) -> D2D_RECT_F:
        """The activity rail down the left edge."""
        return D2D_RECT_F(
            0, 0, Float32(RAIL_W), Float32(self.height - STATUS_H)
        )

    def sidebar(self) -> D2D_RECT_F:
        """The file tree, beside the rail."""
        return D2D_RECT_F(
            Float32(RAIL_W),
            0,
            Float32(RAIL_W + SIDEBAR_W),
            Float32(self.height - STATUS_H),
        )

    def editor(self) -> D2D_RECT_F:
        """The text grid: everything the panes and bars do not take."""
        return D2D_RECT_F(
            Float32(RAIL_W + SIDEBAR_W),
            0,
            Float32(self.width),
            Float32(self.height - STATUS_H - PANE_H),
        )

    def issues(self) -> D2D_RECT_F:
        """The issues pane, bottom left of the editor field."""
        var split = (self.width + RAIL_W + SIDEBAR_W) // 2
        return D2D_RECT_F(
            Float32(RAIL_W + SIDEBAR_W),
            Float32(self.height - STATUS_H - PANE_H),
            Float32(split),
            Float32(self.height - STATUS_H),
        )

    def output(self) -> D2D_RECT_F:
        """The build and run pane, beside the issues."""
        var split = (self.width + RAIL_W + SIDEBAR_W) // 2
        return D2D_RECT_F(
            Float32(split),
            Float32(self.height - STATUS_H - PANE_H),
            Float32(self.width),
            Float32(self.height - STATUS_H),
        )

    def status(self) -> D2D_RECT_F:
        """The status bar along the bottom."""
        return D2D_RECT_F(
            0,
            Float32(self.height - STATUS_H),
            Float32(self.width),
            Float32(self.height),
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

    def __init__(out self):
        """Nothing brought up yet."""
        self.factory = 0
        self.target = 0
        self.dwrite = 0
        self.text_format = 0
        self.drop_target = 0
        self.doc = 0
        self.immediate = False


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
        Float32(12.0),
        Int(locale.unsafe_ptr()),
        com_addr(chrome.text_format),
    )
    _ = family
    _ = locale
    if chrome.text_format == 0:
        raise Error("CreateTextFormat produced nothing")

    return chrome


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
    var layout = Layout(width, height)
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

    _fill(chrome.target, layout.editor(), PANEL)
    _fill(chrome.target, layout.rail(), RAIL)
    _fill(chrome.target, layout.sidebar(), SIDEBAR)
    _fill(chrome.target, layout.issues(), PANEL)
    _fill(chrome.target, layout.output(), PANEL)
    _fill(chrome.target, layout.status(), BAR)

    # Hairlines where regions meet. Drawn as thin filled rectangles rather
    # than strokes: a stroke straddles its line and lands on half-pixels.
    _fill(
        chrome.target,
        D2D_RECT_F(
            Float32(RAIL_W), 0, Float32(RAIL_W + 1), Float32(height - STATUS_H)
        ),
        LINE,
    )
    _fill(
        chrome.target,
        D2D_RECT_F(
            Float32(RAIL_W + SIDEBAR_W),
            0,
            Float32(RAIL_W + SIDEBAR_W + 1),
            Float32(height - STATUS_H),
        ),
        LINE,
    )
    _fill(
        chrome.target,
        D2D_RECT_F(
            0,
            Float32(height - STATUS_H - 1),
            Float32(width),
            Float32(height - STATUS_H),
        ),
        LINE,
    )
    _fill(
        chrome.target,
        D2D_RECT_F(
            Float32(RAIL_W + SIDEBAR_W),
            Float32(height - STATUS_H - PANE_H - 1),
            Float32(width),
            Float32(height - STATUS_H - PANE_H),
        ),
        LINE,
    )

    # The rail's selected item, as the one piece of accent on screen.
    _fill(chrome.target, D2D_RECT_F(0, 12, 3, 44), EMBER)

    _label(chrome, "GRIDDLE", Float32(RAIL_W + 14), 10, DIM)
    _label(chrome, "ISSUES", Float32(RAIL_W + SIDEBAR_W + 12),
           Float32(height - STATUS_H - PANE_H + 8), DIM)
    _label(chrome, "OUTPUT",
           Float32((width + RAIL_W + SIDEBAR_W) // 2 + 12),
           Float32(height - STATUS_H - PANE_H + 8), DIM)
    _label(chrome, status, 12, Float32(height - STATUS_H + 7), DIM)

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
    _release(chrome.text_format)
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
    """A NUL-terminated UTF-16 copy of ASCII text."""
    var out = List[UInt16]()
    for byte in s.as_bytes():
        out.append(UInt16(Int(byte)))
    out.append(0)
    return out^
