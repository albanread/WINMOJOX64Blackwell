"""What a blit *is*, with no idea how it will be executed.

The Amiga blitter's shape, scoped to the four operations that are actually
useful for compositing index buffers: an unconditional copy, a
colour-keyed copy where source index 0 means "leave the destination alone",
a bitwise combine with the destination, and a rectangular fill. A full
256-minterm three-input blitter is deliberately not here.

The record and the clipping live in this tier because neither needs a GPU.
A backend takes a validated `BlitRect` and runs it; the arithmetic that
decides whether a rectangle is legal, and what is left of it after both
planes have had their say, is the same on any of them.
"""


comptime OP_AND = 0
comptime OP_OR = 1
comptime OP_XOR = 2


@fieldwise_init
struct BlitRect(Copyable, Movable):
    """A clipped blit: where from, where to, and how much.

    `empty` rather than an error return, because clipping a rectangle to
    nothing is the ordinary outcome of moving a sprite off the edge, not a
    mistake anyone made.
    """

    var src_x: Int
    var src_y: Int
    var dst_x: Int
    var dst_y: Int
    var w: Int
    var h: Int

    def empty(self) -> Bool:
        return self.w <= 0 or self.h <= 0


def clip_blit(
    src_x: Int,
    src_y: Int,
    dst_x: Int,
    dst_y: Int,
    w: Int,
    h: Int,
    src_w: Int,
    src_h: Int,
    dst_w: Int,
    dst_h: Int,
) -> BlitRect:
    """Trim a requested blit to what both planes can actually supply.

    Clipping happens ONCE, here, rather than per pixel in the kernel: a
    thread that has to bounds-check both planes is a thread that branches,
    and the whole rectangle can be decided before a single one launches.
    That is also why an out-of-range blit is a no-op rather than a trap --
    the kernel is never told about the part that does not exist.

    Both origins move together. Trimming two pixels off the left of the
    destination must trim two off the source as well, or the copy shears.
    """
    var sx = src_x
    var sy = src_y
    var dx = dst_x
    var dy = dst_y
    var cw = w
    var ch = h

    # Negative origins: advance both, and shrink by as much as was skipped.
    if sx < 0:
        cw += sx
        dx -= sx
        sx = 0
    if sy < 0:
        ch += sy
        dy -= sy
        sy = 0
    if dx < 0:
        cw += dx
        sx -= dx
        dx = 0
    if dy < 0:
        ch += dy
        sy -= dy
        dy = 0

    # Far edges: whichever plane runs out first decides.
    if sx + cw > src_w:
        cw = src_w - sx
    if sy + ch > src_h:
        ch = src_h - sy
    if dx + cw > dst_w:
        cw = dst_w - dx
    if dy + ch > dst_h:
        ch = dst_h - dy

    if cw < 0:
        cw = 0
    if ch < 0:
        ch = 0
    return BlitRect(sx, sy, dx, dy, cw, ch)
