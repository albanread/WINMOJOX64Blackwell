"""The direct framebuffer's geometry and palette, with no Metal in sight.

`DirectPane` is the pane a game writes into a byte at a time -- a plasma, a
raycaster, a live Julia set, anything where every pixel changes every frame
and there is nothing small to send. Two facts about it are the game's
business rather than the backend's, and they live here.

**The stride is not the width.** A row occupies `stride` bytes even when
only `width` of them are visible, because a buffer-backed texture's
`bytesPerRow` must be a multiple of the device's linear alignment. A writer
addresses `fb[y * stride + x]`, and a demo that assumes `y * width + x`
draws a diagonal smear at any width the alignment does not divide. On this
machine the alignment for `R8Uint` is 16, so a 321-wide pane has a 336-byte
row: the awkward case is the common case.

**The palette is 256 RGBA floats.** Index to colour costs nothing per frame
because the fragment shader does the lookup; the game just says which colour
each index is.
"""


comptime PALETTE_SIZE = 256
"""One entry per value an index byte can hold."""


def stride_for(width: Int, alignment: Int) -> Int:
    """`width` rounded UP to `alignment` -- never less than the width, and
    the NEXT multiple up rather than any further one."""
    let a = alignment if alignment > 0 else 1
    return ((width + a - 1) // a) * a


def buffer_len_for(stride: Int, height: Int) -> Int:
    """Total writable bytes: what bounds a length-checked view."""
    return stride * height


struct Palette(Copyable, Movable):
    """256 `float4`s in the layout `constant float4* pal` expects: RGBA,
    each component 0..1, entries back to back with no padding."""

    var v: List[Float32]
    var dirty: Bool

    def __init__(out self):
        self.v = List[Float32](length=PALETTE_SIZE * 4, fill=0.0)
        # Opaque black, not transparent black: an untouched index should
        # read as a colour rather than as a hole in the frame.
        for i in range(PALETTE_SIZE):
            self.v[i * 4 + 3] = 1.0
        self.dirty = True

    def set_rgb(mut self, index: Int, r: Int, g: Int, b: Int):
        """Entry `index` from three 0..255 bytes. Out of range is ignored."""
        if index < 0 or index >= PALETTE_SIZE:
            return
        self.v[index * 4 + 0] = Float32(r) / 255.0
        self.v[index * 4 + 1] = Float32(g) / 255.0
        self.v[index * 4 + 2] = Float32(b) / 255.0
        self.v[index * 4 + 3] = 1.0
        self.dirty = True

    def rgb(self, index: Int) -> Tuple[Int, Int, Int]:
        if index < 0 or index >= PALETTE_SIZE:
            return (0, 0, 0)
        return (
            Int(self.v[index * 4 + 0] * 255.0 + 0.5),
            Int(self.v[index * 4 + 1] * 255.0 + 0.5),
            Int(self.v[index * 4 + 2] * 255.0 + 0.5),
        )

    def byte_length(self) -> Int:
        return len(self.v) * 4
