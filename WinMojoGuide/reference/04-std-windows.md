# std.windows

The Windows facilities the standard library already provides. Reach for these
before writing a Win32 call of your own — not because calling Win32 directly
is discouraged, but because somebody has already got these particular details
right, and the details are where Windows bites.

That is worth stating plainly, because this fork's whole point is that Mojo
can talk to Windows at the bottom. It can, and you should when you need to.
Reuse is not the opposite of that. `std.windows` is what stops nine programs
each writing their own worse copy of the same forty lines — which is not a
hypothetical: nine of the shipped examples had each declared `WNDCLASSEXW`
from scratch and written a `wide()` that handled ASCII and nothing else, while
`std.windows.core` had a correct `WideString` all along.

| Module | What it covers |
|:---|:---|
| [`core`](#stdwindowscore) | Wide strings, error codes, handles |
| [`gui`](#stdwindowsgui) | Windows, message loops, pixels |
| [`audio`](#stdwindowsaudio) | Sound out, through WASAPI |
| [`clipboard`](#stdwindowsclipboard) | Text in and out of the system clipboard |
| [`console`](#stdwindowsconsole) | The console: size, colour, virtual terminal |
| [`fs`](#stdwindowsfs) | Files, directories, attributes, times |
| [`process`](#stdwindowsprocess) | Spawning, waiting, environment |
| [`registry`](#stdwindowsregistry) | Reading and writing the registry |
| [`shell`](#stdwindowsshell) | Known folders, associations |
| [`sysinfo`](#stdwindowssysinfo) | The machine: version, memory, names |
| [`time`](#stdwindowstime) | Windows time, and converting it |

---

## std.windows.core

The boundary layer everything else is built on.

**`WideString`** is a NUL-terminated UTF-16 buffer built from a Mojo string.
Every W-suffixed Windows entry point wants one, and every one of them is a
place where a hand-rolled converter goes wrong: the naive version — one byte
to one unit — is Latin-1 rather than UTF-8, and it turns any character above
127 into mojibake and any character above the basic plane into nonsense.

```mojo
from std.windows.core import WideString

var title = WideString("Grüße 😀")
_ = SetWindowTextW(hwnd, title.unsafe_ptr())
```

**`from_wide(pointer, count)`** goes the other way, for the strings Windows
hands back.

**`last_error()`**, **`error_message(code)`**, **`raise_last_error(what)`** and
**`raise_if_failed(hresult, what)`** turn Windows' two error conventions —
`GetLastError` for Win32, an `HRESULT` for COM — into Mojo errors that say
what failed and why, rather than a number the reader has to look up.

**`Handle`** owns a Windows handle and closes it.

---

## std.windows.gui

A window, a message loop, and a way to get pixels on screen. It is not a
widget library: there is no layout, no controls, no event objects and no
inheritance. A Windows program is a class, a window, a procedure and a loop,
and this supplies those four.

```mojo
from std.windows.gui import (
    Window, WindowClass, default_handler, present_bgra, pump, quit,
)

@export("my_wndproc")
def my_wndproc(hwnd: Int, message: UInt32, w: Int, l: Int) abi("C") -> Int:
    try:
        if message == UInt32(winkb_constant["WM_DESTROY"]()):
            quit(0)
            return 0
        return default_handler(hwnd, message, w, l)
    except:
        return 0          # a window procedure must never raise


def main() raises:
    var klass = WindowClass("MyWindow", my_wndproc)
    var window = Window(klass, "My program", 1024, 640)
    window.show()
    while pump():
        present_bgra(window.handle, pixels, WIDTH, HEIGHT)
```

| | |
|:---|:---|
| `win32[Signature, "Name"]()` | A typed entry point, from whichever DLL the metadata names. The signature must be spelled in full: an under-declared one compiles and then corrupts the call. |
| `WindowClass(name, procedure)` | Registers a class. Loads an arrow cursor, because a class whose `hCursor` is zero is one Windows never sets a cursor for. |
| `Window(klass, title, w, h)` | Creates a window. The size is the OUTER size; ask `client_size()` for the drawable area rather than subtracting a guess. |
| `window.show()` | On screen, and asks for the first paint. |
| `window.client_size()` | The drawable rectangle. |
| `pump()` | Handles everything waiting and returns. For a program with work between frames. False when it is time to stop. |
| `run()` | Waits for messages until told to quit. For a program with nothing to do between them — it sleeps in the kernel, which is the difference between idle at 0% and idle at 100%. |
| `quit(code)` | Asks the loop to stop. |
| `default_handler(...)` | What Windows does with a message you did not want. Every procedure must end in this, or the window cannot be moved, resized or closed. |
| `present_bgra(hwnd, pixels, w, h)` | Puts a buffer on the window, scaled to fill it. |
| `WNDCLASSEXW`, `MSG`, `RECT`, `POINT`, `BITMAPINFOHEADER` | The structures, each asserted against the SDK at compile time. |

Three things the module makes explicit because they are what people get wrong:

`present_bgra` takes a **`Span`**, not a pointer, so the buffer carries its own
length. A picture whose size does not match its dimensions is refused here
instead of being read past the end of by the graphics driver.

The bitmap height it passes to `StretchDIBits` is **negative**. A top-down DIB
is what an ordinary drawing routine produces; a positive height means
bottom-up, which is why a first attempt comes out upside down.

Declaring these structures `TrivialRegisterPassable` is a **silent
catastrophe** — on a structure this size it changes how fields are laid out and
passed, `cbSize` reads back as rubbish, and `RegisterClassExW` refuses a class
that looks perfectly correct in the source. They are `Defaultable, Copyable,
Movable`.

`spikes/win32/gui_smoke.mojo` uses the whole module in ninety lines and reads
the window's own pixels back afterwards to prove they arrived.

---

## std.windows.audio

Sound out, through WASAPI, which is COM. Shared mode and event-driven,
because both of those were measured rather than assumed on the machine this
was developed on: the mix format is refused in exclusive mode here, and an
event-driven stream woke every 9.993 ms on average against 13.998 ms for
polling.

See `examples/win32/chip` and `examples/win32/abcplayer` for it doing real
work, and `spikes/win32/audio_smoke.mojo` for the smallest thing that makes a
noise — and then asks the endpoint's own peak meter whether it really did.

The format is **read, not assumed**. It is 48 kHz stereo float on most
machines and it is not guaranteed to be, so ask the stream what it got.

---

## std.windows.clipboard

`get_clipboard_text()` and `set_clipboard_text(text)`. The clipboard is one
lock for the whole desktop, so both can fail because another program is
holding it, and that is different from the clipboard being empty. See
`ide/clipboard.mojo` for an editor's use of it, including why line endings are
converted in both directions.

## std.windows.console

Console size, colours, and turning on virtual-terminal processing so ANSI
escapes work.

## std.windows.fs

Files and directories: existence, attributes, times, listing, and the
atomic-rename dance that makes a save safe. Note the trap recorded in
`docs/mojo-traps.md`: `with open(...)` does not release the handle at the end
of its block, so a write-then-rename must close explicitly or fail with a
sharing violation.

## std.windows.process

Spawning a child, waiting for it, reading its output, and setting environment
variables a child will inherit.

## std.windows.registry

`RegKey`, `HKEY_CURRENT_USER` and the rest. `examples/win32/windows_tour`
writes a value under `HKCU\Software\MojoWindowsTour` and deletes it again.

## std.windows.shell

Known folders — Documents, AppData, Desktop — resolved properly rather than
built from `%USERPROFILE%` and a guess, because they are not always where you
think.

## std.windows.sysinfo

The Windows version, the computer and user names, memory. `windows_tour`
prints all of it, which is the point of that example: a wrong struct offset
shows up as a wrong number rather than as nothing at all.

## std.windows.time

`FILETIME` and `SYSTEMTIME`, and converting between Windows' epoch and a
sensible one.

---

## When to go under it

Any time you need to. This is a fork whose reason to exist is that Mojo can
call Windows directly, with the compiler checking the call against the SDK —
`winkb_constant`, `winkb_struct_size`, `win32[]` and `com_method_of` are the
front door and not an escape hatch. [Chapter 4](../guide/04-calling-win32.md)
is about exactly that.

The rule is smaller than it sounds: if `std.windows` already does the thing,
use it, because the copy you write will be the ninth and the details it gets
wrong will be the ones that took somebody an afternoon. If it does not, write
the call — and if what you wrote turns out to be general, it belongs here.
