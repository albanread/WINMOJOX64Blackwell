"""The 5x7 font, and the two ways layer 3 uses it.

One font table, two renderers. `TextOverlay` rasterises glyphs into an RGBA
buffer when you call it; `TextPlane` bakes the same table into a GPU atlas
and a shader draws cells from it. Neither has its own copy, so neither can
drift from the other.

Each glyph is seven bytes, one per row top to bottom, and bits 4..0 are the
five columns left to right -- bit 4 leftmost. Read a row in binary and you
can see the glyph: `0x0E` is `0b01110` is `.###.`.

Covered: `A`-`Z`, `0`-`9`, space, and `. , : - ' ! ? ( ) / + < > &`.
Lowercase folds to uppercase, because retro titles are conventionally all
caps and a missing lowercase glyph is worse than a fold. Anything else
renders as a hollow box -- visibly present and correctly spaced, never
silently dropped, so a character the font does not have looks like a gap in
the font rather than a bug in the game.
"""


comptime GLYPH_W = 5
comptime GLYPH_H = 7
comptime GLYPH_ADVANCE = GLYPH_W + 1
"""Glyph width plus one spacing column, so adjacent characters do not touch."""

comptime CELL_W = GLYPH_W + 1
comptime CELL_H = GLYPH_H + 1
"""Cell pitch for the text plane: the glyph plus one pixel of leading on each
axis, so stacked lines do not touch either. 6 x 8."""

comptime CELL_BYTES = 4
"""`[char, fg, bg, flags]`."""

comptime FLAG_TRANSPARENT_BG = 1
"""`flags` bit 0: draw no background, letting the picture below show through."""


def text_cols(viewport_w: Int) -> Int:
    """Never zero: a one-column plane is useless but a zero-column one is a
    division by zero in the shader."""
    let c = viewport_w // CELL_W
    return c if c > 0 else 1


def text_rows(viewport_h: Int) -> Int:
    let r = viewport_h // CELL_H
    return r if r > 0 else 1


def glyph_for(ch: Int) -> List[UInt8]:
    """The seven-byte bitmask for a character code. Lowercase folds up;
    anything unknown is the hollow placeholder."""
    var c = ch
    if c >= ord("a") and c <= ord("z"):
        c = c - ord("a") + ord("A")

    if c == ord(" "):
        return [0, 0, 0, 0, 0, 0, 0]

    if c >= ord("0") and c <= ord("9"):
        let d = c - ord("0")
        if d == 0:
            return [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E]
        if d == 1:
            return [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E]
        if d == 2:
            return [0x0E, 0x11, 0x01, 0x06, 0x08, 0x10, 0x1F]
        if d == 3:
            return [0x0E, 0x11, 0x01, 0x06, 0x01, 0x11, 0x0E]
        if d == 4:
            return [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02]
        if d == 5:
            return [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E]
        if d == 6:
            return [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E]
        if d == 7:
            return [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08]
        if d == 8:
            return [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E]
        return [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C]

    if c >= ord("A") and c <= ord("Z"):
        let i = c - ord("A")
        if i == 0:
            return [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11]
        if i == 1:
            return [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E]
        if i == 2:
            return [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E]
        if i == 3:
            return [0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C]
        if i == 4:
            return [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F]
        if i == 5:
            return [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10]
        if i == 6:
            return [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0E]
        if i == 7:
            return [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11]
        if i == 8:
            return [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E]
        if i == 9:
            return [0x07, 0x02, 0x02, 0x02, 0x12, 0x12, 0x0C]
        if i == 10:
            return [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11]
        if i == 11:
            return [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F]
        if i == 12:
            return [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11]
        if i == 13:
            return [0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11]
        if i == 14:
            return [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E]
        if i == 15:
            return [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10]
        if i == 16:
            return [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D]
        if i == 17:
            return [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11]
        if i == 18:
            return [0x0E, 0x11, 0x10, 0x0E, 0x01, 0x11, 0x0E]
        if i == 19:
            return [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04]
        if i == 20:
            return [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E]
        if i == 21:
            return [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04]
        if i == 22:
            return [0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11]
        if i == 23:
            return [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11]
        if i == 24:
            return [0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04]
        return [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F]

    if c == ord("."):
        return [0, 0, 0, 0, 0, 0x0C, 0x0C]
    if c == ord(","):
        return [0, 0, 0, 0, 0x06, 0x04, 0x08]
    if c == ord(":"):
        return [0, 0x0C, 0x0C, 0, 0x0C, 0x0C, 0]
    if c == ord("-"):
        return [0, 0, 0, 0x0E, 0, 0, 0]
    if c == ord("'"):
        return [0x04, 0x04, 0x08, 0, 0, 0, 0]
    if c == ord("!"):
        return [0x04, 0x04, 0x04, 0x04, 0x04, 0, 0x04]
    if c == ord("?"):
        return [0x0E, 0x11, 0x01, 0x06, 0x04, 0, 0x04]
    if c == ord("("):
        return [0x04, 0x08, 0x10, 0x10, 0x10, 0x08, 0x04]
    if c == ord(")"):
        return [0x04, 0x02, 0x01, 0x01, 0x01, 0x02, 0x04]
    if c == ord("/"):
        return [0x01, 0x01, 0x02, 0x04, 0x08, 0x10, 0x10]
    if c == ord("+"):
        return [0, 0x04, 0x04, 0x1F, 0x04, 0x04, 0]
    if c == ord("<"):
        return [0x01, 0x02, 0x04, 0x08, 0x04, 0x02, 0x01]
    if c == ord(">"):
        return [0x10, 0x08, 0x04, 0x02, 0x04, 0x08, 0x10]
    if c == ord("&"):
        return [0x0C, 0x12, 0x12, 0x0C, 0x15, 0x12, 0x0D]

    # The hollow placeholder box.
    return [0x1F, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1F]


@fieldwise_init
struct RgbaCanvas(Copyable, Movable):
    """A writable RGBA8 rectangle: where the bytes are, and how wide.

    The same idea as `Plane`, for the one surface in the game pane that is
    colours rather than indices. Rasterising a glyph into it is arithmetic,
    so it lives in this tier and the backend only says where the bytes are.
    """

    var base: Pointer[UInt8, MutUntrackedOrigin]
    var width: Int
    var height: Int

    def clear(self):
        for i in range(self.width * self.height * 4):
            self.base[unsafe_offset=i] = 0

    def set_pixel(self, x: Int, y: Int, r: Int, g: Int, b: Int):
        if x < 0 or y < 0 or x >= self.width or y >= self.height:
            return
        let i = (y * self.width + x) * 4
        self.base[unsafe_offset = i + 0] = UInt8(r & 255)
        self.base[unsafe_offset = i + 1] = UInt8(g & 255)
        self.base[unsafe_offset = i + 2] = UInt8(b & 255)
        self.base[unsafe_offset = i + 3] = 255

    def draw_char(
        self, x: Int, y: Int, ch: Int, r: Int, g: Int, b: Int, scale: Int
    ):
        """One glyph, top-left at (x, y), each font pixel a scale x scale
        block."""
        let s = scale if scale > 1 else 1
        let rows = glyph_for(ch)
        for row in range(GLYPH_H):
            let mask = Int(rows[row])
            for col in range(GLYPH_W):
                # Bit GLYPH_W - 1 is the LEFTMOST column.
                if mask & (1 << (GLYPH_W - 1 - col)) != 0:
                    for dy in range(s):
                        for dx in range(s):
                            self.set_pixel(
                                x + col * s + dx, y + row * s + dy, r, g, b
                            )

    def draw_text(
        self, x: Int, y: Int, text: String, r: Int, g: Int, b: Int, scale: Int
    ):
        """A string, left to right. The advance is `(5 + 1) * scale`, so a
        string of n characters spans `n * 6 * scale` pixels including the
        trailing spacing column, and is `7 * scale` tall."""
        let s = scale if scale > 1 else 1
        let advance = GLYPH_ADVANCE * s
        var i = 0
        for c in text.codepoints():
            self.draw_char(x + i * advance, y, Int(c.to_u32()), r, g, b, s)
            i += 1
