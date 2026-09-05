"""Layer 1's arithmetic: slots, the palette split, scrolling, and every
drawing primitive -- none of which needs to know what a GPU is.

An index plane is a rectangle of bytes, `stride` apart per row. That is all
a Bresenham line needs, so the primitives live here, in the tier a game
imports, and the backend's only job is to say where the bytes are. Ported
from the Rust as written, including the parts that look like they could be
tidied: the midpoint circle's eight-way symmetry, the disc's four spans per
step, `blit`'s "extra bytes ignored, short slice fills the prefix".

**The palette split is the interesting arithmetic.** Index 0 is always
transparent and can never be assigned. Indices 1..15 are PER SCANLINE --
sixteen colours for every line of the viewport, which is what makes copper
bars and per-line gradients cost nothing. Indices 16..255 are the 240 GLOBAL
colours. So the palette is `viewport_h × 16 + 240` entries, the per-line
block first, and the shader resolves an index by asking which half it is in.
"""

from std.math import floor


comptime NUM_BUFFERS = 8
"""Eight slots: FRONT, BACK, and six for assets."""

comptime FRONT = 0
comptime BACK = 1

comptime TRANSPARENT = UInt8(0)
"""Index 0. No draw call means to write it, and `cls(0)` is exactly how a
plane is cleared to fully see-through."""

comptime GLOBAL_COLORS = 240
"""Indices 16..255."""

comptime LINE_COLORS = 16
"""Entries reserved per scanline: 0..15, of which 0 is never assignable."""


# ── the palette's index arithmetic ──────────────────────────────────────────


def palette_entries(viewport_height: Int) -> Int:
    """`viewport_h × 16 + 240` -- the whole palette, in entries."""
    return viewport_height * LINE_COLORS + GLOBAL_COLORS


def palette_global_base(viewport_height: Int) -> Int:
    """Where the 240 global entries begin, in entries."""
    return viewport_height * LINE_COLORS


def palette_line_entry(line: Int, index: Int) -> Int:
    """Entry for colour `index` (1..15) on scanline `line`."""
    return line * LINE_COLORS + index


def palette_global_entry(viewport_height: Int, index: Int) -> Int:
    """Entry for global colour `index` (16..255)."""
    return palette_global_base(viewport_height) + (index - 16)


def hsv_to_rgb(h: Float32, s: Float32, v: Float32) -> Tuple[Int, Int, Int]:
    """Ported as written, truncation and all -- the default palette's hue
    wheel has to come out the same colours as the Rust's."""
    let i = floor(h * 6.0)
    let f = h * 6.0 - i
    let p = v * (1.0 - s)
    let q = v * (1.0 - f * s)
    let t = v * (1.0 - (1.0 - f) * s)
    var sector = Int(i) % 6
    if sector < 0:
        sector += 6
    var r = v
    var g = t
    var b = p
    if sector == 1:
        r, g, b = q, v, p
    elif sector == 2:
        r, g, b = p, v, t
    elif sector == 3:
        r, g, b = p, q, v
    elif sector == 4:
        r, g, b = t, p, v
    elif sector == 5:
        r, g, b = v, p, q
    return (Int(r * 255.0), Int(g * 255.0), Int(b * 255.0))


def clamp_scroll(x: Int, world: Int, viewport: Int) -> Int:
    """A scroll offset the viewport can actually read from: 0 to the
    overscan margin, which is what `world - viewport` is."""
    let hi = world - viewport
    if hi <= 0:
        return 0
    if x < 0:
        return 0
    if x > hi:
        return hi
    return x


# ── the plane: a rectangle of index bytes ───────────────────────────────────


@fieldwise_init
struct Plane(Copyable, Movable):
    """A writable index plane -- where the bytes are, and how to find a row.

    Deliberately not an owner. The backend allocates, this draws, and the
    two never have to agree about anything except these four numbers. It is
    also what keeps every primitive below platform-neutral: none of them can
    tell a Metal buffer from a `List`.

    Rows are `stride` bytes apart, NOT `width`. The stride is the width
    rounded up to the device's texture alignment, so on Apple silicon they
    differ for most widths, and code that assumes `y * width + x` draws a
    diagonal smear.
    """

    var base: Pointer[UInt8, MutUntrackedOrigin]
    var stride: Int
    var width: Int
    var height: Int

    def inside(self, x: Int, y: Int) -> Bool:
        return x >= 0 and y >= 0 and x < self.width and y < self.height

    def cls(self, index: UInt8):
        """Fill the plane. The padding between `width` and `stride` is filled
        too -- nothing samples it, and leaving stale bytes in a gap is the
        kind of thing that shows up later as a one-pixel seam."""
        for i in range(self.stride * self.height):
            self.base[unsafe_offset=i] = index

    def pset(self, x: Int, y: Int, index: UInt8):
        """Out of bounds is a no-op, not a trap: a game that draws a sprite
        half off the edge is doing something normal."""
        if self.inside(x, y):
            self.base[unsafe_offset = y * self.stride + x] = index

    def pget(self, x: Int, y: Int) -> UInt8:
        """Transparent when out of bounds, for the same reason."""
        if not self.inside(x, y):
            return TRANSPARENT
        return self.base[unsafe_offset = y * self.stride + x]

    def blit(self, data: Span[UInt8, _]):
        """Overwrite the plane from row-major indices, in one pass -- the
        bulk path for a CPU-generated frame that would otherwise cost a
        `pset` per pixel.

        Length-safe in both directions: extra bytes are ignored, and a short
        span fills only the prefix, leaving the tail as it was. The source is
        `width`-packed while the plane is `stride`-packed, so this walks rows
        rather than copying one run.
        """
        var read = 0
        let n = len(data)
        for y in range(self.height):
            for x in range(self.width):
                if read >= n:
                    return
                self.base[unsafe_offset = y * self.stride + x] = data[read]
                read += 1

    def fill_rect(self, x: Int, y: Int, w: Int, h: Int, index: UInt8):
        for row in range(y, y + h):
            for col in range(x, x + w):
                self.pset(col, row, index)

    def line(self, x0: Int, y0: Int, x1: Int, y1: Int, index: UInt8):
        """Bresenham."""
        var cx = x0
        var cy = y0
        let dx = abs(x1 - x0)
        let sx = 1 if x0 < x1 else -1
        let dy = -abs(y1 - y0)
        let sy = 1 if y0 < y1 else -1
        var err = dx + dy
        while True:
            self.pset(cx, cy, index)
            if cx == x1 and cy == y1:
                break
            let e2 = 2 * err
            if e2 >= dy:
                err += dy
                cx += sx
            if e2 <= dx:
                err += dx
                cy += sy

    def circle(self, cx: Int, cy: Int, r: Int, index: UInt8):
        """Midpoint circle, outline only -- eight points per step, one per
        octant."""
        var x = r
        var y = 0
        var err = 0
        while x >= y:
            self.pset(cx + x, cy + y, index)
            self.pset(cx + y, cy + x, index)
            self.pset(cx - y, cy + x, index)
            self.pset(cx - x, cy + y, index)
            self.pset(cx - x, cy - y, index)
            self.pset(cx - y, cy - x, index)
            self.pset(cx + y, cy - x, index)
            self.pset(cx + x, cy - y, index)
            y += 1
            err += 1 + 2 * y
            if 2 * (err - x) + 1 > 0:
                x -= 1
                err += 1 - 2 * x

    def disc(self, cx: Int, cy: Int, r: Int, index: UInt8):
        """The same midpoint test, drawing horizontal spans instead of
        outline points."""
        var x = r
        var y = 0
        var err = 0
        while x >= y:
            self.fill_rect(cx - x, cy + y, 2 * x + 1, 1, index)
            self.fill_rect(cx - x, cy - y, 2 * x + 1, 1, index)
            self.fill_rect(cx - y, cy + x, 2 * y + 1, 1, index)
            self.fill_rect(cx - y, cy - x, 2 * y + 1, 1, index)
            y += 1
            err += 1 + 2 * y
            if 2 * (err - x) + 1 > 0:
                x -= 1
                err += 1 - 2 * x
