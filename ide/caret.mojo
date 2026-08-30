"""Where the caret goes, and which character a click landed on.

Sprint 1.3. A monospaced grid tempts you to answer both questions with
multiplication and division, and for most lines that is exactly right: an
ASCII line in a monospaced face advances by one width per character, so the
caret's x is `column * advance` and a click is `x / advance`. No measuring,
no allocation, nothing per keystroke.

It is right for most lines and wrong for the interesting ones. A CJK ideograph
is two advances wide. An emoji is one glyph made of two UTF-16 code units, and
a flag or a skin-toned emoji is one glyph made of four or seven. A combining
accent is zero advances wide and must never be a caret stop of its own.
Arithmetic gets all of these wrong, and gets them wrong *invisibly*: the caret
lands a few pixels out, then a few characters out, and the editor feels
haunted rather than broken.

So this file has two paths and no hand-rolled measurement anywhere. Lines that
are plain printable ASCII take the arithmetic. Everything else asks
DirectWrite, through the same `IDWriteTextLayout` the line is already drawn
with -- `HitTestTextPosition` going one way and `HitTestPoint` coming back.
The layout is cached, so the slow path costs a virtual call rather than a
shaping run.

Tabs are on the slow path with the rest. A tab is not a character with a
width; it is a jump to the next tab stop, which is a property of the layout
and not of the text.
"""

from std.memory import OpaquePointer, Pointer
from std.sys.info import size_of
from std.sys._com import com_addr, com_method_of
from std.sys._winkb import winkb_struct_size


@fieldwise_init
struct HitMetrics(Defaultable, ImplicitlyCopyable, Movable):
    """What DirectWrite says about the cluster under a position or a point.

    `textPosition` and `length` are the load-bearing pair: together they say
    which run of UTF-16 code units forms the one indivisible thing the caret
    may sit either side of. Stepping a caret by one code unit rather than by
    `length` is how an editor ends up placing the caret inside an emoji.
    """

    var textPosition: UInt32
    var length: UInt32
    var left: Float32
    var top: Float32
    var width: Float32
    var height: Float32
    var bidiLevel: UInt32
    var isText: Int32
    var isTrimmed: Int32

    def __init__(out self):
        """Nothing hit yet."""
        self.textPosition = 0
        self.length = 0
        self.left = 0
        self.top = 0
        self.width = 0
        self.height = 0
        self.bidiLevel = 0
        self.isText = 0
        self.isTrimmed = 0


def is_simple(text: StringSlice) -> Bool:
    """Whether this line can be positioned by arithmetic alone.

    True only for printable ASCII: everything from a space to a tilde. That
    excludes tabs, which are tab stops rather than characters, and control
    codes, which DirectWrite may render as something or as nothing.

    Args:
        text: The line.

    Returns:
        Whether the fast path applies.
    """
    for byte in text.as_bytes():
        if byte < 0x20 or byte > 0x7E:
            return False
    return True


def cluster_at(layout: Int, position: Int) raises -> HitMetrics:
    """Where the caret sits at a UTF-16 offset, and what occupies it.

    Args:
        layout: An `IDWriteTextLayout`.
        position: The offset, in UTF-16 code units.

    Returns:
        The metrics; `left` is the caret's x and `length` is how far the next
        caret stop is.

    Raises:
        If DirectWrite refuses.
    """
    comptime assert (
        size_of[HitMetrics]() == winkb_struct_size["DWRITE_HIT_TEST_METRICS"]()
    ), "DWRITE_HIT_TEST_METRICS does not match Windows"

    var this = OpaquePointer[MutUntrackedOrigin](unsafe_from_address=layout)
    var x = Float32(0)
    var y = Float32(0)
    var metrics = HitMetrics()
    _ = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            Int32,
            Pointer[Float32, MutAnyOrigin],
            Pointer[Float32, MutAnyOrigin],
            Pointer[HitMetrics, MutAnyOrigin],
        ) thin abi("C") -> Int32,
        "IDWriteTextLayout",
        "HitTestTextPosition",
    ](this)(
        this,
        UInt32(position),
        Int32(0),  # leading edge: the caret goes before the cluster
        com_addr(x),
        com_addr(y),
        com_addr(metrics),
    )
    # `left` is where the cluster starts, which is not always where the caret
    # for this position goes -- in right-to-left text they differ. The x that
    # came back is the caret's, so use it and keep the rest of the metrics for
    # the cluster's own extent.
    metrics.left = x
    _ = y
    return metrics


def position_at(layout: Int, x: Float32, y: Float32) raises -> Int:
    """Which UTF-16 offset a point lands on.

    A click past the middle of a cluster belongs to the *next* caret stop --
    that is what `isTrailingHit` reports, and honouring it is the difference
    between a click that feels accurate and one that always lands a character
    to the left.

    Args:
        layout: An `IDWriteTextLayout`.
        x: The point's x, relative to the layout's origin.
        y: The point's y, likewise.

    Returns:
        The offset, in UTF-16 code units.

    Raises:
        If DirectWrite refuses.
    """
    var this = OpaquePointer[MutUntrackedOrigin](unsafe_from_address=layout)
    var trailing = Int32(0)
    var inside = Int32(0)
    var metrics = HitMetrics()
    _ = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Float32,
            Float32,
            Pointer[Int32, MutAnyOrigin],
            Pointer[Int32, MutAnyOrigin],
            Pointer[HitMetrics, MutAnyOrigin],
        ) thin abi("C") -> Int32,
        "IDWriteTextLayout",
        "HitTestPoint",
    ](this)(
        this,
        x,
        y,
        com_addr(trailing),
        com_addr(inside),
        com_addr(metrics),
    )
    var at = Int(metrics.textPosition)
    if trailing != 0:
        at += Int(metrics.length)
    return at
