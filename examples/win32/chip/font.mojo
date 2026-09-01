# ===----------------------------------------------------------------------=== #
# A character ROM, and the two-line blitter that reads it.
#
# The Mac version drew its text with NSFont and NSString's drawAtPoint:. There
# is no equivalent here that would survive what this window does: the whole
# screen is a BGRA buffer that StretchDIBits scales to whatever size the
# window has been dragged to, and text drawn onto the device context AFTER
# that stretch keeps its own size and drifts out of the layout the moment
# anyone resizes. GDI text and a stretched buffer are two coordinate systems.
#
# So the text is in the buffer, which means it needs a font, which on a
# machine like this one means eight bytes per character -- exactly the way the
# 8 KB character ROM at $D000 held one. Every glyph below is 8x8, bit 7
# leftmost, and `draw_text` scales it by whole pixels so a doubled character
# has hard edges rather than a grey fringe.
#
# The set is 32..95: space, punctuation, digits and capitals. A C64 had no
# lower case on this screen either, and `draw_text` folds the case for the
# same reason the machine did.
# ===----------------------------------------------------------------------=== #

from std.ffi import external_call
from std.memory import Pointer, OpaquePointer

comptime GLYPH_FIRST = 32
comptime GLYPH_LAST = 95
comptime GLYPH_COUNT = GLYPH_LAST - GLYPH_FIRST + 1
comptime GLYPH_H = 8
comptime GLYPH_W = 8

# Eight bytes a glyph, two hex digits a byte, in ASCII order from space.
comptime GLYPH_HEX = StaticString(
    "0000000000000000" "1818181818001800" "3636360000000000" "36367E367E363600"
    "183E603C067C1800" "63660C183066C600" "386C3876DCCC3B00" "1818180000000000"
    "0C18303030180C00" "30180C0C0C183000" "002418FF18240000" "0018187E18180000"
    "0000000000181830" "0000007E00000000" "0000000000181800" "03060C183060C000"
    "3C666E7A72663C00" "1838181818183C00" "3C66060C30607E00" "3C66061C06663C00"
    "0E1E36667F060F00" "7E607C0606663C00" "3C66607C66663C00" "7E660C1830303000"
    "3C66663C66663C00" "3C66663E06663C00" "0018180000181800" "0018180000181830"
    "060C1830180C0600" "00007E007E000000" "6030180C18306000" "3C66060C18001800"
    "3C666E6E60663C00" "3C66667E66666600" "7C66667C66667C00" "3C66606060663C00"
    "7C66666666667C00" "7E60607C60607E00" "7E60607C60606000" "3C66606E66663C00"
    "6666667E66666600" "3C18181818183C00" "0E06060666663C00" "666C7870786C6600"
    "6060606060607E00" "667E7E6E66666600" "66767E7E6E666600" "3C66666666663C00"
    "7C66667C60606000" "3C6666666E6C3B00" "7C66667C786C6600" "3C66603C06663C00"
    "7E18181818181800" "6666666666663C00" "66666666663C1800" "6666666E7E7E6600"
    "66663C183C666600" "66663C1818181800" "7E060C1830607E00" "3C30303030303C00"
    "C06030180C060300" "3C0C0C0C0C0C3C00" "183C660000000000" "00000000000000FF"
)


@always_inline
def _nibble(c: Int) -> Int:
    if c >= 48 and c <= 57:
        return c - 48
    return c - 55  # 'A'..'F'


def font_rom() raises -> Int:
    """Decode the ROM into 512 bytes on the heap. Returns its address.

    A heap block rather than a `List` because the window procedure is
    captureless: everything the drawing reaches has to hang off the one
    pointer Windows keeps for the window, and a Mojo-owned collection cannot.
    """
    var rom = external_call["calloc", OpaquePointer[MutUntrackedOrigin]](
        Int(GLYPH_COUNT * GLYPH_H), Int(1)
    ).unsafe_bitcast[UInt8]()
    var hex = GLYPH_HEX.as_bytes()
    if len(hex) != GLYPH_COUNT * GLYPH_H * 2:
        raise Error("the character ROM is the wrong length")
    for i in range(GLYPH_COUNT * GLYPH_H):
        rom[unsafe_offset=i] = UInt8(
            _nibble(Int(hex[i * 2])) * 16 + _nibble(Int(hex[i * 2 + 1]))
        )
    return Int(rom)


@always_inline
def glyph_index(code: Int) -> Int:
    """Fold to the ROM's range: lower case becomes upper, the rest a space."""
    var c = code
    if c >= 97 and c <= 122:
        c -= 32
    if c < GLYPH_FIRST or c > GLYPH_LAST:
        c = GLYPH_FIRST
    return c - GLYPH_FIRST


def text_width(text: String, scale: Int) -> Int:
    return len(text.as_bytes()) * GLYPH_W * scale


def draw_text(
    frame: Pointer[UInt32, MutUntrackedOrigin],
    pitch: Int,
    height: Int,
    rom_addr: Int,
    x: Int,
    y: Int,
    text: String,
    scale: Int,
    colour: UInt32,
):
    """Stamp `text` into a BGRA buffer at (x, y), scaled by whole pixels.

    Clipped on all four sides rather than trusted: the voice lines are built
    from register values, and a wide number is the sort of thing that would
    otherwise run off the end of a row and reappear at the start of the next.
    """
    var rom = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=rom_addr)
    var bytes = text.as_bytes()
    for k in range(len(bytes)):
        var g = glyph_index(Int(bytes[k])) * GLYPH_H
        var gx = x + k * GLYPH_W * scale
        if gx >= pitch:
            return
        for row in range(GLYPH_H):
            var bits = Int(rom[unsafe_offset = g + row])
            if bits == 0:
                continue
            for col in range(GLYPH_W):
                if (bits & (128 >> col)) == 0:
                    continue
                var px0 = gx + col * scale
                var py0 = y + row * scale
                for dy in range(scale):
                    var py = py0 + dy
                    if py < 0 or py >= height:
                        continue
                    var base = py * pitch
                    for dx in range(scale):
                        var px = px0 + dx
                        if px < 0 or px >= pitch:
                            continue
                        frame[unsafe_offset = base + px] = colour
