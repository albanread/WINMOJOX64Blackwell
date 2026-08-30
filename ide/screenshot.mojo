"""The app photographs itself.

Sprint 0.3. Griddle renders its own window into a bitmap and encodes it to
PNG, which is how every later sprint gets to prove what it looks like rather
than assert it. The Mac team needed this to answer "does the ladybug icon
render" without a human; we need it for the same reason and one more --
their screenshots required a TCC grant that cannot be given headlessly,
while `PrintWindow` asks nobody's permission because it is not screen
capture. It is the window drawing itself into a device context we own, so
it works occluded, minimised, and on a desktop no one is looking at.

The encoding is Windows Imaging Component, driven through this repository's
own COM surface: `co_create` for the factory, then `Com[...]` typed calls
whose vtable slots, arities and argument widths all come from the metadata.
It is the first thing in the IDE that is a COM *client* of consequence, and
a fair test of that work -- five interfaces, ten calls, no hand-written
vtable arithmetic anywhere.
"""

from std.ffi import c_int
from std.memory import Pointer
from std.os.path import getsize
from std.sys.info import size_of
from std.sys._winkb import winkb_constant
from std.sys._com import ComPtr, _guid_bytes
from std.sys.com import Com, co_create

from ide.win32 import RECT, wide, win32


# The class and format identities WIC is asked for. Written here because the
# metadata carries these guids as names without values -- a recorded gap --
# so this is the one place in the IDE where a GUID is spelled by hand, and
# each is named so it can be checked against the SDK headers.
comptime CLSID_WICImagingFactory = StaticString(
    "cacaf262-9370-4615-a13b-9f5539da4c0a"
)
comptime GUID_ContainerFormatPng = StaticString(
    "1b7cfaf4-713f-473c-bbcd-6137425faeaf"
)
comptime GUID_WICPixelFormat32bppBGRA = StaticString(
    "6fddc324-4e03-4bfe-b185-3d77768dc90f"
)


@fieldwise_init
struct BITMAPINFOHEADER(Defaultable, Copyable, Movable):
    """How the DIB is laid out, as GDI wants it described."""

    var biSize: UInt32
    var biWidth: Int32
    var biHeight: Int32
    var biPlanes: UInt16
    var biBitCount: UInt16
    var biCompression: UInt32
    var biSizeImage: UInt32
    var biXPelsPerMeter: Int32
    var biYPelsPerMeter: Int32
    var biClrUsed: UInt32
    var biClrImportant: UInt32

    def __init__(out self):
        """An all-zero header."""
        self.biSize = 0
        self.biWidth = 0
        self.biHeight = 0
        self.biPlanes = 0
        self.biBitCount = 0
        self.biCompression = 0
        self.biSizeImage = 0
        self.biXPelsPerMeter = 0
        self.biYPelsPerMeter = 0
        self.biClrUsed = 0
        self.biClrImportant = 0


def _guid_bytes_for(text: StaticString) -> List[UInt8]:
    """The 16 bytes of a textual GUID, in COM's mixed-endian order."""
    return _guid_bytes(String(text))


def capture(hwnd: Int, path: String) raises -> Int:
    """Render `hwnd` to a PNG at `path`; answer the byte count written.

    Args:
        hwnd: The window to photograph -- ours.
        path: Where the PNG goes.

    Returns:
        The size of the file written, so a caller can tell an image from an
        empty file without opening it.

    Raises:
        If the window has no area, the bitmap cannot be made, or any step of
        the encode fails.
    """
    var GetClientRect = win32[
        def (Int, Pointer[RECT, MutAnyOrigin]) thin abi("C") -> c_int,
        "GetClientRect",
    ]()
    var GetDC = win32[def (Int) thin abi("C") -> Int, "GetDC"]()
    var ReleaseDC = win32[def (Int, Int) thin abi("C") -> c_int, "ReleaseDC"]()
    var CreateCompatibleDC = win32[
        def (Int) thin abi("C") -> Int, "CreateCompatibleDC"
    ]()
    var DeleteDC = win32[def (Int) thin abi("C") -> c_int, "DeleteDC"]()
    var DeleteObject = win32[def (Int) thin abi("C") -> c_int, "DeleteObject"]()
    var SelectObject = win32[
        def (Int, Int) thin abi("C") -> Int, "SelectObject"
    ]()
    var CreateDIBSection = win32[
        def (
            Int,
            Pointer[BITMAPINFOHEADER, MutAnyOrigin],
            UInt32,
            Pointer[Int, MutAnyOrigin],
            Int,
            UInt32,
        ) thin abi("C") -> Int,
        "CreateDIBSection",
    ]()
    var PrintWindow = win32[
        def (Int, Int, UInt32) thin abi("C") -> c_int, "PrintWindow"
    ]()

    var rc = RECT()
    _ = GetClientRect(hwnd, Pointer(to=rc).unsafe_origin_cast[MutAnyOrigin]())
    var width = Int(rc.right - rc.left)
    var height = Int(rc.bottom - rc.top)
    if width <= 0 or height <= 0:
        raise Error("the window has no client area to photograph")

    var screen = GetDC(0)
    var memdc = CreateCompatibleDC(screen)

    # Negative height asks GDI for a top-down bitmap, which is the order WIC
    # writes rows in; the alternative is copying the image twice to flip it.
    var bmi = BITMAPINFOHEADER()
    bmi.biSize = UInt32(size_of[BITMAPINFOHEADER]())
    bmi.biWidth = Int32(width)
    bmi.biHeight = Int32(-height)
    bmi.biPlanes = 1
    bmi.biBitCount = 32
    bmi.biCompression = UInt32(winkb_constant["BI_RGB"]())

    var bits = Int(0)
    var hbmp = CreateDIBSection(
        screen,
        Pointer(to=bmi).unsafe_origin_cast[MutAnyOrigin](),
        UInt32(winkb_constant["DIB_RGB_COLORS"]()),
        Pointer(to=bits).unsafe_origin_cast[MutAnyOrigin](),
        0,
        0,
    )
    if hbmp == 0 or bits == 0:
        _ = DeleteDC(memdc)
        _ = ReleaseDC(0, screen)
        raise Error("CreateDIBSection failed")

    var old = SelectObject(memdc, hbmp)

    # PW_RENDERFULLCONTENT is what makes this work for a window that is
    # covered or off-screen: it asks the window to draw itself rather than
    # copying whatever the screen happens to show.
    var printed = PrintWindow(
        hwnd, memdc, UInt32(winkb_constant["PW_RENDERFULLCONTENT"]())
    )

    var written = 0
    if printed != 0:
        written = _encode_png(path, width, height, bits)

    _ = SelectObject(memdc, old)
    _ = DeleteObject(hbmp)
    _ = DeleteDC(memdc)
    _ = ReleaseDC(0, screen)

    if printed == 0:
        raise Error("PrintWindow refused to render the window")
    return written


def _encode_png(path: String, width: Int, height: Int, bits: Int) raises -> Int:
    """Write the pixels at `bits` to `path` as a PNG, through WIC.

    Every interface is held in a `ComPtr`, so each is released exactly once
    when this returns and none of them can be leaked by an early raise. The
    keep-alives at the end are not decoration: Mojo ends a value at its last
    use, and the last *use* of the stream is several calls before the last
    moment it must still exist -- releasing it early closes the file under
    the encoder that is still writing to it.

    Args:
        path: The output file.
        width: Image width in pixels.
        height: Image height in pixels.
        bits: The top-down 32bpp BGRA pixels.

    Returns:
        The file's size in bytes.

    Raises:
        If any WIC call fails.
    """
    var factory = co_create[CLSID_WICImagingFactory, "IWICImagingFactory"]()
    var f = Com[StaticString("IWICImagingFactory")](of=factory)

    var stream_ptr = Int(0)
    _ = f.CreateStream(
        Pointer(to=stream_ptr).unsafe_origin_cast[MutAnyOrigin]()
    )
    if stream_ptr == 0:
        raise Error("IWICImagingFactory::CreateStream produced nothing")
    var stream = ComPtr[StaticString("IWICStream")](adopt=stream_ptr)
    var s = Com[StaticString("IWICStream")](of=stream)

    var wide_path = wide_string(path)
    _ = s.InitializeFromFilename(
        wide_path.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        UInt32(0x40000000),  # GENERIC_WRITE
    )
    _ = wide_path

    var png = _guid_bytes_for(GUID_ContainerFormatPng)
    var encoder_ptr = Int(0)
    _ = f.CreateEncoder(
        Int(png.unsafe_ptr()),
        0,
        Pointer(to=encoder_ptr).unsafe_origin_cast[MutAnyOrigin](),
    )
    _ = png
    if encoder_ptr == 0:
        raise Error("WIC has no PNG encoder")
    var encoder = ComPtr[StaticString("IWICBitmapEncoder")](adopt=encoder_ptr)
    var e = Com[StaticString("IWICBitmapEncoder")](of=encoder)
    _ = e.Initialize(
        stream_ptr, UInt32(winkb_constant["WICBitmapEncoderNoCache"]())
    )

    var frame_ptr = Int(0)
    var props_ptr = Int(0)
    _ = e.CreateNewFrame(
        Pointer(to=frame_ptr).unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=props_ptr).unsafe_origin_cast[MutAnyOrigin](),
    )
    if frame_ptr == 0:
        raise Error("the encoder produced no frame")
    var frame = ComPtr[StaticString("IWICBitmapFrameEncode")](adopt=frame_ptr)
    var fr = Com[StaticString("IWICBitmapFrameEncode")](of=frame)
    _ = fr.Initialize(props_ptr)
    _ = fr.SetSize(UInt32(width), UInt32(height))

    var fmt = _guid_bytes_for(GUID_WICPixelFormat32bppBGRA)
    _ = fr.SetPixelFormat(Int(fmt.unsafe_ptr()))
    _ = fmt

    var stride = width * 4
    _ = fr.WritePixels(
        UInt32(height), UInt32(stride), UInt32(stride * height), bits
    )
    _ = fr.Commit()
    _ = e.Commit()

    # Everything above must still be alive at this point; see the docstring.
    _ = frame
    _ = encoder
    _ = stream
    _ = factory

    # Ask the filesystem rather than re-reading the image: the size is the
    # only thing wanted, and a caller uses it to tell a picture from an
    # empty file without opening either.
    return getsize(path)


def wide_string(s: String) -> List[UInt16]:
    """A NUL-terminated UTF-16 copy of a runtime string."""
    var out = List[UInt16]()
    for ch in s.codepoints():
        out.append(UInt16(Int(ch)))
    out.append(0)
    return out^
