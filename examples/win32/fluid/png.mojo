# ===----------------------------------------------------------------------=== #
# A PNG writer, in Mojo, with no library behind it.
#
# The macOS original deflates through libz, which is on every Mac. There is no
# equivalent guaranteed on Windows, and pulling in zlib to save a screenshot
# would be a strange dependency for an example about fluid dynamics -- so this
# writes the one kind of DEFLATE stream that needs no compressor at all:
# STORED blocks. A stored block is a three-byte header and then the bytes,
# uncompressed. The result is a completely ordinary PNG that every viewer
# opens; it is simply about as large as the pixels are.
#
# The two checksums are real, because a PNG with a wrong CRC is rejected:
# CRC-32 (reflected, polynomial 0xEDB88320) over each chunk's type and data,
# and Adler-32 over the uncompressed stream, as zlib requires.
#
# The file itself goes out through `std.windows.write_file`, which is
# CreateFileW / WriteFile / CloseHandle done once, properly, with the short
# write a real WriteFile is allowed to do already handled. There is no Windows
# in this file at all beyond that one call: what is left is PNG.
# ===----------------------------------------------------------------------=== #

from std.memory import Pointer, Span
from std.windows import write_file


comptime U8 = Pointer[UInt8, MutAnyOrigin]


# ===----------------------------------------------------------------------=== #
# Checksums
# ===----------------------------------------------------------------------=== #


def _crc_table() -> List[UInt32]:
    """The 256-entry CRC-32 table, built rather than transcribed."""
    var table = List[UInt32](length=256, fill=0)
    for n in range(256):
        var c = UInt32(n)
        for _k in range(8):
            if (c & UInt32(1)) != 0:
                c = UInt32(0xEDB88320) ^ (c >> 1)
            else:
                c = c >> 1
        table[n] = c
    return table^


def _crc32(table: List[UInt32], data: U8, n: Int) -> UInt32:
    var c = UInt32(0xFFFFFFFF)
    for i in range(n):
        c = table[Int((c ^ UInt32(data[unsafe_offset=i])) & UInt32(0xFF))] ^ (
            c >> 8
        )
    return c ^ UInt32(0xFFFFFFFF)


def _adler32(data: U8, n: Int) -> UInt32:
    """Adler-32, which is what the zlib wrapper carries."""
    var a = UInt32(1)
    var b = UInt32(0)
    for i in range(n):
        a = (a + UInt32(data[unsafe_offset=i])) % UInt32(65521)
        b = (b + a) % UInt32(65521)
    return (b << 16) | a


@always_inline
def _put32be(p: U8, off: Int, v: UInt32):
    """PNG is big-endian throughout; x86-64 is not."""
    p[unsafe_offset=off] = UInt8((v >> 24) & 0xFF)
    p[unsafe_offset = off + 1] = UInt8((v >> 16) & 0xFF)
    p[unsafe_offset = off + 2] = UInt8((v >> 8) & 0xFF)
    p[unsafe_offset = off + 3] = UInt8(v & 0xFF)


# ===----------------------------------------------------------------------=== #
# The file
# ===----------------------------------------------------------------------=== #

comptime STORED_MAX = 65535


def write_png(
    path: String,
    bgra: Pointer[UInt32, MutAnyOrigin],
    width: Int,
    height: Int,
) raises -> Bool:
    """Write one BGRA frame as a PNG.

    Returns False rather than raising on an I/O failure: a screenshot that
    cannot be saved must never take the demo down mid-drag.

    Args:
        path: Where to write. Created or truncated.
        bgra: `width * height` words of 0xAARRGGBB, row-major, top row first.
        width: Pixels across.
        height: Pixels down.

    Returns:
        True if the whole file reached the disk.

    Raises:
        If a Win32 entry point cannot be resolved at all.
    """
    # --- raw scanlines: one filter byte (0 = none) then RGB, alpha dropped ---
    var stride = width * 3 + 1
    var raw_n = stride * height
    var raw_store = List[UInt8](length=raw_n, fill=0)
    var raw = raw_store.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    for y in range(height):
        var row = y * stride
        raw[unsafe_offset=row] = 0
        for x in range(width):
            var px = bgra[unsafe_offset = y * width + x]
            var o = row + 1 + x * 3
            raw[unsafe_offset=o] = UInt8((px >> 16) & 0xFF)  # R
            raw[unsafe_offset = o + 1] = UInt8((px >> 8) & 0xFF)  # G
            raw[unsafe_offset = o + 2] = UInt8(px & 0xFF)  # B

    # --- zlib stream of STORED deflate blocks -------------------------------
    # 0x78 0x01: deflate, 32K window, no preset dictionary, fastest level.
    # (0x7801 is divisible by 31, which is the header's own check.)
    var blocks = (raw_n + STORED_MAX - 1) // STORED_MAX
    if blocks == 0:
        blocks = 1
    var z_n = 2 + blocks * 5 + raw_n + 4
    var z_store = List[UInt8](length=z_n, fill=0)
    var z = z_store.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    z[unsafe_offset=0] = 0x78
    z[unsafe_offset=1] = 0x01
    var zo = 2
    var done = 0
    for b in range(blocks):
        var take = raw_n - done
        if take > STORED_MAX:
            take = STORED_MAX
        # Byte-aligned block header: BFINAL in bit 0, BTYPE 00 = stored.
        # NLEN is LEN's one's complement in sixteen bits, spelled as the
        # subtraction rather than `~` so the width is not in doubt.
        var nlen = 0xFFFF - take
        z[unsafe_offset=zo] = UInt8(1) if b == blocks - 1 else UInt8(0)
        z[unsafe_offset = zo + 1] = UInt8(take & 0xFF)
        z[unsafe_offset = zo + 2] = UInt8((take >> 8) & 0xFF)
        z[unsafe_offset = zo + 3] = UInt8(nlen & 0xFF)
        z[unsafe_offset = zo + 4] = UInt8((nlen >> 8) & 0xFF)
        zo += 5
        for i in range(take):
            z[unsafe_offset = zo + i] = raw[unsafe_offset = done + i]
        zo += take
        done += take
    _put32be(z, zo, _adler32(raw, raw_n))
    zo += 4

    # --- the file: signature, IHDR, IDAT, IEND ------------------------------
    var file_n = 8 + (12 + 13) + (12 + z_n) + 12
    var out_store = List[UInt8](length=file_n, fill=0)
    var out = out_store.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    var sig: List[UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    for i in range(8):
        out[unsafe_offset=i] = sig[i]
    var table = _crc_table()
    var at = 8

    # IHDR: width, height, 8 bits, colour type 2 (truecolour), no interlace.
    _put32be(out, at, UInt32(13))
    var ihdr: List[UInt8] = [73, 72, 68, 82]  # 'IHDR'
    for i in range(4):
        out[unsafe_offset = at + 4 + i] = ihdr[i]
    _put32be(out, at + 8, UInt32(width))
    _put32be(out, at + 12, UInt32(height))
    out[unsafe_offset = at + 16] = 8
    out[unsafe_offset = at + 17] = 2
    out[unsafe_offset = at + 18] = 0
    out[unsafe_offset = at + 19] = 0
    out[unsafe_offset = at + 20] = 0
    # The CRC covers the type and the data, but not the length.
    _put32be(
        out, at + 21, _crc32(table, out.unsafe_offset(at + 4), 4 + 13)
    )
    at += 12 + 13

    _put32be(out, at, UInt32(z_n))
    var idat: List[UInt8] = [73, 68, 65, 84]  # 'IDAT'
    for i in range(4):
        out[unsafe_offset = at + 4 + i] = idat[i]
    for i in range(z_n):
        out[unsafe_offset = at + 8 + i] = z[unsafe_offset=i]
    _put32be(
        out, at + 8 + z_n, _crc32(table, out.unsafe_offset(at + 4), 4 + z_n)
    )
    at += 12 + z_n

    _put32be(out, at, UInt32(0))
    var iend: List[UInt8] = [73, 69, 78, 68]  # 'IEND'
    for i in range(4):
        out[unsafe_offset = at + 4 + i] = iend[i]
    _put32be(out, at + 8, _crc32(table, out.unsafe_offset(at + 4), 4))
    at += 12

    # --- the file -----------------------------------------------------------
    # `at` and not `len(out_store)`: they are equal, and saying which one is
    # meant costs nothing. The failure is swallowed rather than raised because
    # a screenshot that cannot be saved must not take the demo down mid-drag.
    var ok = True
    try:
        write_file(path, Span[UInt8, MutAnyOrigin](unsafe_ptr=out, length=at))
    except:
        ok = False
    # Keep the backing stores alive across every use above.
    _ = raw_store
    _ = z_store
    _ = out_store
    return ok
