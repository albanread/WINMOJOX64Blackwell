"""Everything `std.windows.gui` offers, in one program that runs.

A window, a class, a procedure, a loop and a picture -- the whole of what the
module is for, in ninety lines. It is here rather than in the examples because
it is a check rather than a demonstration: if this draws, the module works on
this machine, and if it does not, nothing built on the module will either.

    ./bazel-bin/KGEN/tools/mojo/mojo.exe build --no-optimization         -I mojo/stdlib -I . -o build/gui_smoke.exe spikes/win32/gui_smoke.mojo
    GUI_FRAMES=30 ./build/gui_smoke.exe

`GUI_FRAMES=N` draws N frames, reads the window's own pixels back through its
device context and prints what it found, then exits -- so this can be run with
nobody at the keyboard. Reading the pixels back is the point: a frame that was
drawn into a buffer nobody presented looks exactly like a frame that worked,
which is the lesson of docs/occlusion.md.

Last measured on the T1000 box: client 684x441, 30 frames, 5 of 5 sampled
pixels carrying the gradient.
"""

from std.ffi import c_int
from std.memory import Pointer, Span, alloc
from std.os import getenv
from std.sys._winkb import winkb_constant
from std.windows.gui import (
    Window,
    WindowClass,
    default_handler,
    present_bgra,
    pump,
    quit,
    win32,
)

comptime W = 320
comptime H = 200


@export("gui_proof_wndproc")
def gui_proof_wndproc(
    hwnd: Int, message: UInt32, wparam: Int, lparam: Int
) abi("C") -> Int:
    """Close on request; let Windows have everything else.

    Never raises: unwinding through a Windows frame is undefined, so every
    failure is swallowed here.
    """
    try:
        if message == UInt32(winkb_constant["WM_DESTROY"]()):
            quit(0)
            return 0
        return default_handler(hwnd, message, wparam, lparam)
    except:
        return 0


def main() raises:
    var klass = WindowClass("GuiProofWindow", gui_proof_wndproc)
    var window = Window(klass, "std.windows.gui", 700, 480)
    window.show()

    var pixels = alloc[UInt32](W * H, alignment=8)
    var frames = 0
    var wanted = 0
    var door = getenv("GUI_FRAMES")
    if door != "":
        wanted = Int(door)

    var client = window.client_size()
    print("window", window.handle, " client", client.width(), "x", client.height())

    while pump():
        # A moving gradient, so a frame that did not change is visible as one.
        for y in range(H):
            for x in range(W):
                var r = UInt32((x * 255) // W)
                var g = UInt32((y * 255) // H)
                var b = UInt32((frames * 4) & 0xFF)
                pixels.unsafe_offset(y * W + x)[] = (
                    (r << 16) | (g << 8) | b
                )
        present_bgra(window.handle, Span(unsafe_ptr=pixels, length=W * H), W, H)
        frames += 1
        if wanted > 0 and frames >= wanted:
            break

    print("frames", frames)
    if wanted > 0:
        # Read the window back through its own device context, which is the
        # only way to prove the pixels reached the screen rather than the
        # buffer.
        var GetDC = win32[def (Int) thin abi("C") -> Int, "GetDC"]()
        var GetPixel = win32[
            def (Int, c_int, c_int) thin abi("C") -> UInt32, "GetPixel"
        ]()
        var ReleaseDC = win32[
            def (Int, Int) thin abi("C") -> c_int, "ReleaseDC"
        ]()
        var dc = GetDC(window.handle)
        var seen = 0
        var samples = String("")
        for i in range(5):
            var px = GetPixel(dc, c_int(40 + i * 60), c_int(40 + i * 40))
            samples += " " + hex(Int(px))
            if px != 0xFFFFFFFF:
                seen += 1
        _ = ReleaseDC(window.handle, dc)
        print("sampled", seen, "of 5 real pixels:", samples)
    pixels.unsafe_free()
