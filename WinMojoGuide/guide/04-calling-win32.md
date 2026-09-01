# 4. Calling Win32

A binding in this fork states a name. The compiler supplies everything else.

"Everything else" is more than it sounds: which DLL exports a function, how
big a struct is and where each field sits, which vtable slot a COM method
occupies, what a named constant is worth. All of that is written down
precisely in a metadata database that ships with the toolchain, and the
compiler reads it while your program is being elaborated. There is no
generator, no translated header to keep in step with Windows, and no hex
copied out of `winuser.h`.

The point is not convenience. It is that the failures move to compile time.
A misspelled entry point does not build. A struct that has drifted from the
SDK does not build. A constant you never transcribed cannot be transcribed
the wrong way round.

## The database

It is a SQLite file, `windows_api.db`, about 86 MB, and on this machine it
holds 18,271 functions with their DLLs, 46,250 interface methods, 39,447
types with 66,708 struct fields, and 97,402 constants alongside 67,612
enumeration members.

The compiler finds it in one of two ways:

* `MODULAR_MOJO_MAX_WINKB_PATH`, if it is set, is the path it uses.
* Otherwise it looks for `lib/windows_api.db` inside the installation.

A normal install therefore needs no configuration, and the release's
`griddle.cmd` sets the variable anyway so that a copy that has been moved
still finds its own database. You need to set it by hand only when you are
running a compiler you built yourself, which [Appendix
A](09-building-from-source.md) covers.

```
set MODULAR_MOJO_MAX_WINKB_PATH=C:\path\to\windows_api.db
```

The database is opened read-only and is never created. Point the variable at
nothing and every query fails with the reason, on the line that asked:

```
note: cannot open the Win32 metadata database at 'F:/nope/nothing.db':
      unable to open database file
```

Point it at a file that is not this database and you get the SQL error
instead — `note: no such table: enum_members` — which is the same sentence in
a different accent. Neither of them invents an empty database and answers
from it, which is the failure that would matter: a wrong offset that
compiles.

Two queries exist to pin down which revision a binary was built against.
`winkb_db_schema_version()` is the schema — `6` here — and `winkb_db_hash()`
is the SHA-256 of the file itself, so a build record can name its metadata
exactly.

## The six questions

Everything in this chapter is built out of six queries from
`std.sys._winkb`. Each is a parametric function that folds to a constant
before any code is generated.

| Query | Takes | Answers |
|:---|:---|:---|
| `winkb_function_dll` | an export name | the DLL that exports it, as text |
| `winkb_constant` | a constant or flag name | its value, as a signed `Int` |
| `winkb_struct_size` | a struct name | its size in bytes |
| `winkb_field_offset` | a struct name and a field | the field's byte offset |
| `winkb_vtable_index` | an interface and a method | the zero-based vtable slot |
| `winkb_interface_iid` | an interface name | its IID, as text |

There are more — `winkb_struct_align`, `winkb_constant_text`,
`winkb_type_width`, and a family that describes COM method signatures — and
the reference will list them all. These six carry the weight.

```mojo
def main():
    print("CreateWindowExW lives in", winkb_function_dll["CreateWindowExW"]())
    print("WM_DESTROY is", winkb_constant["WM_DESTROY"]())
    print("WNDCLASSEXW is", winkb_struct_size["WNDCLASSEXW"](), "bytes")
    print(
        "  .lpfnWndProc at",
        winkb_field_offset["WNDCLASSEXW", "lpfnWndProc"](),
    )
    print("IStream::Read is slot", winkb_vtable_index["IStream", "Read"]())
    print("IStream is", winkb_interface_iid["IStream"]())
```

```
CreateWindowExW lives in USER32.dll
WM_DESTROY is 2
WNDCLASSEXW is 80 bytes
  .lpfnWndProc at 8
IStream::Read is slot 3
IStream is 0000000c-0000-0000-c000-000000000046
```

Not one of those answers is written anywhere in the program. All six are in
the binary as constants.

### A name it does not know

```mojo
def main():
    print(winkb_constant["WM_FROBNICATE"]())
```

```
error: function instantiation failed
note: call expansion failed with parameter value(s): (...)
    print(winkb_constant["WM_FROBNICATE"]())
                                         ^
note: the Win32 metadata has no 'constant_value' for WM_FROBNICATE
```

Every query fails in that shape, and the quoted word is the query's internal
name rather than the Mojo function's: `constant_value`, `function_dll`,
`struct_size`, `field_offset`, `vtable_index`, `interface_iid`. Worth knowing
because it is what you grep for, and because a `field_offset` failure names
the struct and the field together — `no 'field_offset' for POINT, z` — which
tells you whether you got the struct wrong or only the spelling of one field.

## One line per entry point

The database says which DLL exports a function; the module cache loads it;
the loader gives you the address. Put together, an entry point costs one
call:

```mojo
def win32[Sig: TrivialRegisterPassable, name: StaticString]() raises -> Sig:
    """A Win32 entry point, typed, from whichever DLL the metadata names."""
    return Win32Module(String(winkb_function_dll[name]())).function[Sig](
        String(name)
    )


def main() raises:
    var GetTickCount64 = win32[
        def () thin abi("C") -> UInt64, "GetTickCount64"
    ]()
    print("up for", GetTickCount64() // 1000, "seconds")
```

That helper is in [`ide/win32.mojo`](../../ide/win32.mojo), and the same five
lines are copied into most of the examples that call Windows rather than
shared from one place, because an example that had to import the IDE in order
to make a system call would be teaching the wrong thing. Copy it too. It is
worth reading once, though, because each piece of it is there for a reason.

`Win32Module` (`std.sys._win32`) goes through a process-lifetime cache in the
compiler runtime rather than through `OwnedDLHandle`. An `OwnedDLHandle`
frees its library when it drops, which is wrong twice for Windows work: the
load-and-free churn is wasted, and Windows may still hold a callback into a
module the handle has already freed. Modules taken this way load once and
are never freed, which is what a Windows process does with `user32` anyway.

`.function[Sig]` raises if the module did not load or the export is absent.
The alternative — returning a null you then call — is how a typo becomes a
crash at an address rather than a message.

### `thin` is not optional

The signature type is spelled `def (...) thin abi("C") -> Ret`. Leave `thin`
out and it does not compile:

```mojo
    var GetTickCount = m.function[def () abi("C") -> UInt32]("GetTickCount")
```

```
error: invalid call to 'function': 'function' parameter 'Sig' has
       'TrivialRegisterPassable' type, but value has type
       'AnyTrait[def() abi("C") -> UInt32]'
```

A non-`thin` function value is a closure — code pointer plus captured
environment — and there is nothing on the other side of the ABI boundary to
receive the second half. `thin` is what makes the type a bare code pointer,
which is what `TrivialRegisterPassable` in the parameter is asking for. The
error names the trait rather than the missing word, so it is worth
recognising by shape.

### Spell every argument

This is the one that costs a day, because it does not fail.

```mojo
def main() raises:
    var MulDiv = win32[
        def (c_int, c_int, c_int) thin abi("C") -> c_int, "MulDiv"
    ]()
    print("declared in full:", MulDiv(c_int(100), c_int(3), c_int(2)))

    var MulDiv2 = win32[def (c_int, c_int) thin abi("C") -> c_int, "MulDiv"]()
    print("one argument short:", MulDiv2(c_int(100), c_int(3)))
```

```
declared in full: 150
one argument short: 0
```

`MulDiv(100, 3, 2)` is 150. The under-declared call never passes a
denominator, so `MulDiv` divides by whatever happened to be in that argument
register: on this machine, in an unoptimised build and an optimised one
alike, it answers 0. There is no warning, no error, and nothing in the output
that says a call went wrong — only an answer that is not the right one.

The metadata knows every parameter of every function, and a future version of
the language may check the signature against it. Today it does not. Write out
every argument, including the ones you are passing zero for, and give the
return type its real width.

## Constants

`winkb_constant` covers plain constants and enumeration or flag members
alike, so `WM_DESTROY`, `CS_HREDRAW`, `SW_SHOW` and `WS_OVERLAPPEDWINDOW` all
answer from the same query even though the SDK reaches them by different
routes. So do the message-pump flags: `PM_REMOVE` is 1, `QS_ALLINPUT` is
1279, `WAIT_TIMEOUT` is 258, and none of them needs to be written down.

The value is the *signed* reading, which is the one that stays correct in
both directions — `HKEY_LOCAL_MACHINE` has to sign-extend to a pointer, and a
flag mask keeps its bits through a `UInt32()`. What it means in practice is
that a constant reaches you as an `Int` and the API you are comparing it
against may not answer in `Int`:

```mojo
def exists(path: StaticString) raises -> Bool:
    var GetFileAttributesW = win32[
        def (Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> UInt32,
        "GetFileAttributesW",
    ]()
    # The metadata's reading is signed and this API answers unsigned, so the
    # constant is narrowed once, here, to the width the comparison happens in.
    comptime INVALID = UInt32(winkb_constant["INVALID_FILE_ATTRIBUTES"]())
    var w = wide(path)
    var attributes = GetFileAttributesW(
        w.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    )
    _ = w
    return attributes != INVALID
```

```
kernel32.dll  -> True
no-such-file  -> False
```

`INVALID_FILE_ATTRIBUTES` is `-1`; `GetFileAttributesW` returns an unsigned
32-bit value. Comparing the two directly is a type error —
*value passed to 'rhs' cannot be converted from 'Int' to 'UInt32'* — so you
cannot walk into it by accident. You can walk into it by widening the API's
answer instead. Replace the last line with
`return Int(attributes) != winkb_constant["INVALID_FILE_ATTRIBUTES"]()` and it
compiles, is never equal, and says this:

```
kernel32.dll  -> True
no-such-file  -> True
```

Every file exists, including the ones that do not. That is why the narrowing
goes on the constant.

> [docs/mojo-traps.md](../../docs/mojo-traps.md) describes this as a
> comparison that compiles and can never be true. On this compiler the
> straightforward spelling does not compile at all, and only the widened form
> is silently wrong. The advice — narrow the constant to the API's width — is
> unchanged.

## Structs

Declaration order and natural alignment give a Mojo struct the same layout C
gives it. That is a fact you can check rather than trust:

```mojo
@fieldwise_init
struct POINT(Defaultable, ImplicitlyCopyable, Movable):
    var x: Int32
    var y: Int32

    def __init__(out self):
        self.x = 0
        self.y = 0


def main() raises:
    comptime assert (
        size_of[POINT]() == winkb_struct_size["POINT"]()
    ), "POINT does not match Windows"
    comptime assert (
        winkb_field_offset["POINT", "x"]() == 0
        and winkb_field_offset["POINT", "y"]() == 4
    ), "POINT fields are not where this code assumes"

    var GetCursorPos = win32[
        def (Pointer[POINT, MutAnyOrigin]) thin abi("C") -> c_int,
        "GetCursorPos",
    ]()
    var p = POINT()
    if GetCursorPos(com_addr(p)) == 0:
        raise Error("GetCursorPos failed")
    print("cursor at", p.x, p.y)
```

Get it wrong — drop `bottom` from a `RECT`, say — and the build stops with
the message you wrote:

```
error: function instantiation failed
note: constraint failed: RECT does not match Windows
```

Three things about this deserve saying plainly.

**Assert the size of everything you declare.** It is one line, it costs
nothing at run time, and the failure it prevents is a field written into the
wrong place, which presents as a blank window or a nonsense number a long way
from the declaration.

**Never claim `TrivialRegisterPassable` for a struct you pass by pointer.**
It compiles. It then writes fields to the wrong offsets — `cbSize` reads back
as garbage, a function pointer as 18. Structs the OS fills in are
`(Defaultable, Copyable, Movable)`; register-passability is for things that
genuinely fit in a register.

**Pass addresses as `com_addr(x)`, never as `Int(Pointer(to=x))`.** The
integer form throws away the fact that the storage is still live, and an
optimising build is then entitled to fold the value away and reuse the slot.
This is not theoretical: it cost Griddle's first optimised build almost all
of its drawing, with `EndDraw` returning success the whole time.
[docs/addresses-and-optimization.md](../../docs/addresses-and-optimization.md)
has the assembly.

### Structs you never declare

Some structs are boxes: Windows fills them in, you read one field, and
writing out fourteen members to reach it is work that can go wrong. Size the
box from the metadata and read at the offsets it gives:

```mojo
def main() raises:
    # MEMORYSTATUSEX is never declared here, only sized: a box Windows fills
    # in, read back at the offsets the metadata gives.
    comptime SIZE = winkb_struct_size["MEMORYSTATUSEX"]()
    comptime TOTAL = winkb_field_offset["MEMORYSTATUSEX", "ullTotalPhys"]()
    comptime AVAIL = winkb_field_offset["MEMORYSTATUSEX", "ullAvailPhys"]()

    var box = List[UInt8](length=SIZE, fill=0)
    var raw = box.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    raw.unsafe_bitcast[UInt32]()[] = UInt32(SIZE)  # dwLength, at offset 0

    var GlobalMemoryStatusEx = win32[
        def (Pointer[UInt8, MutAnyOrigin]) thin abi("C") -> c_int,
        "GlobalMemoryStatusEx",
    ]()
    if GlobalMemoryStatusEx(raw) == 0:
        raise Error("GlobalMemoryStatusEx failed")

    var total = raw.unsafe_offset(TOTAL).unsafe_bitcast[UInt64]()[]
    var avail = raw.unsafe_offset(AVAIL).unsafe_bitcast[UInt64]()[]
    _ = box
    print("MEMORYSTATUSEX is", SIZE, "bytes; ullTotalPhys at", TOTAL)
    print("physical memory:", total // (1024 * 1024), "MiB")
    print("still free:     ", avail // (1024 * 1024), "MiB")
```

```
MEMORYSTATUSEX is 64 bytes; ullTotalPhys at 8
physical memory: 32473 MiB
still free:      20351 MiB
```

`life` does the same with `PAINTSTRUCT`, which it hands to `BeginPaint` and
`EndPaint` and never looks inside at all.

## The wide-string boundary

Call the `W` entry points. The `A` ones exist, they go through the process
code page, and on a machine whose code page is not UTF-8 they mangle anything
outside it silently. No `A` entry point is called anywhere in this tree — not
in the IDE, not in an example — and that is worth keeping to.

`W` means UTF-16, and Mojo strings are UTF-8, so the conversion is yours to
write. It is short, and it has one interesting case:

```mojo
def utf16(s: StringSlice) -> List[UInt16]:
    """A NUL-terminated UTF-16 copy of text."""
    var out = List[UInt16]()
    for c in s.codepoints():
        var v = Int(c)
        if v >= 0x10000:
            var u = v - 0x10000
            out.append(UInt16(0xD800 + (u >> 10)))
            out.append(UInt16(0xDC00 + (u & 0x3FF)))
        else:
            out.append(UInt16(v))
    out.append(0)
    return out^
```

Iterating `s.codepoints()` rather than `s.as_bytes()` is the whole of it. One
byte to one code unit is Latin-1, not UTF-8, and it is wrong for everything
above U+007F: the box-drawing character U+2502 is `e2 94 82` in UTF-8, and
byte-by-byte it reaches Windows as three characters beginning with
a-circumflex. Griddle's status line drew exactly that until
[`ide/chrome.mojo`](../../ide/chrome.mojo) grew this function.

You do not have to keep this function. `std.windows.core.WideString`
is the same conversion, kept in one place and NUL-terminated for the `W`
entry points, and `from_wide` is the return journey for strings Windows hands
back. Nine of the shipped examples each carried a private copy of this loop
before the library grew one; several of the copies had the Latin-1 bug. Write
it once to understand it, then import it.

The branch above U+FFFF is the surrogate pair. UTF-16 has no other way to say
a character outside the basic plane, and a person searching for an emoji is
an ordinary thing to happen. Windows counts what you give it in code units,
and it is worth watching the three numbers disagree:

```mojo
def main() raises:
    var lstrlenW = win32[
        def (Pointer[UInt16, MutAnyOrigin]) thin abi("C") -> c_int, "lstrlenW"
    ]()

    var text = String("ab") + chr(0x2502) + chr(0x1F600)
    var w = utf16(text)
    var units = Int(lstrlenW(w.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()))

    print("UTF-8 bytes:", text.byte_length())
    print("codepoints: ", len(text.codepoints()))
    print("UTF-16 units:", units)
    for i in range(units):
        print("   ", hex(w[i]))
    print("round trip:", from_utf16(w, units) == text)
```

```
UTF-8 bytes: 9
codepoints:  4
UTF-16 units: 5
    0x61
    0x62
    0x2502
    0xd83d
    0xde00
round trip: True
```

Four characters, nine bytes, five units. This is also why `len(s)` on a
string is a compile error in this dialect: the three answers are all correct
and you have to say which one you meant.

Coming back the other way — a buffer Windows filled in, turned into a
`String` — the pair has to be recombined, and here it is not a matter of
taste:

```mojo
def from_utf16(units: List[UInt16], count: Int) -> String:
    """Text back from a buffer Windows filled in."""
    var out = String("")
    var i = 0
    while i < count:
        var u = Int(units[i])
        if u >= 0xD800 and u <= 0xDBFF and i + 1 < count:
            var low = Int(units[i + 1])
            out += chr(0x10000 + ((u - 0xD800) << 10) + (low - 0xDC00))
            i += 2
        else:
            out += chr(u)
            i += 1
    return out^
```

The obvious shorter loop — `out += chr(Int(units[i]))` for every unit — does
not merely produce wrong text. `chr` rejects a lone surrogate and aborts the
process:

```
ABORT: chr(55357) is not a valid Unicode codepoint
Exception Code: 0xC000001D
```

> `absolute()` in [`ide/win32.mojo`](../../ide/win32.mojo) decodes
> `GetFullPathNameW`'s result with the shorter loop, and encodes its input
> one byte to one unit. It is correct for the ASCII paths Griddle hands it
> and it would abort on a project path containing an astral character. If you
> are copying from that file, copy `utf16` from `chrome.mojo` instead.

## Callbacks Windows calls

A window procedure is a function Windows calls, which puts three constraints
on it. Two of them the compiler enforces.

**It must be a captureless C-ABI function.** Declare it with `@export`, give
it `abi("C")`, and take its address with `_fn_ptr_as_opaque` — which lives in
`std.python._cpython` because reinterpreting a C function as a `void *` was
first needed for CPython, and is the same operation here.

**It may not raise.** An `abi("C")` function is a non-raising context, so any
call that can fail has to be caught inside:

```
error: cannot call function that may raise in a context that cannot raise
note: try surrounding the call in a 'try' block
note: or mark surrounding function as 'raises'
```

Take the compiler's second suggestion and it gives you a better error:

```
error: 'abi("C")' function may not be marked 'raises'; remove 'raises' or
       use 'abi("Mojo")'
```

Which is the right answer. Unwinding a Mojo exception through a Windows stack
frame is undefined, and this is one of the rare cases where the language
makes the mistake unavailable rather than merely documenting it. Wrap the
body in `try` / `except` and return a default from the `except`.

**It cannot capture, so state travels through Windows.** The usual channel is
the window's own user data: heap-allocate the state, `SetWindowLongPtrW` it
into `GWLP_USERDATA`, and read it back with `GetWindowLongPtrW` at the top of
every message. Windows starts sending messages *during* `CreateWindowExW`,
before you have had a chance to store anything, so the read has to tolerate a
zero and hand those early messages to `DefWindowProcW`. `life` shows the
whole pattern; the program below does not need state and so does not have it.

## The smallest window

A window class, a window, a procedure and a loop. Nothing here names a DLL, a
message number, a style bit or a struct size.

Everything this section builds also ships built: `std.windows.gui` is the
class, the window, the loop and the pixels in four declarations, and the
[std.windows reference](../reference/04-std-windows.md) documents it. The
section builds it from parts anyway, because seeing every part is the point
of the chapter -- and because the library's parts are these exact calls.

```mojo
# The smallest program that opens a window and pumps messages.

from std.ffi import c_int
from std.memory import Pointer
from std.python._cpython import _fn_ptr_as_opaque
from std.sys.info import size_of
from std.sys._com import com_addr
from std.sys._win32 import Win32Module
from std.sys._winkb import (
    winkb_constant,
    winkb_function_dll,
    winkb_struct_size,
)


def win32[Sig: TrivialRegisterPassable, name: StaticString]() raises -> Sig:
    """A Win32 entry point, typed, from whichever DLL the metadata names."""
    return Win32Module(String(winkb_function_dll[name]())).function[Sig](
        String(name)
    )


def wide(s: StaticString) -> List[UInt16]:
    """A NUL-terminated UTF-16 buffer. ASCII in, which these two names are."""
    var out = List[UInt16]()
    for byte in s.as_bytes():
        out.append(UInt16(Int(byte)))
    out.append(0)
    return out^


@fieldwise_init
struct WNDCLASSEXW(Defaultable, Copyable, Movable):
    var cbSize: UInt32
    var style: UInt32
    var lpfnWndProc: Int
    var cbClsExtra: c_int
    var cbWndExtra: c_int
    var hInstance: Int
    var hIcon: Int
    var hCursor: Int
    var hbrBackground: Int
    var lpszMenuName: Int
    var lpszClassName: Int
    var hIconSm: Int

    def __init__(out self):
        self.cbSize = 0
        self.style = 0
        self.lpfnWndProc = 0
        self.cbClsExtra = 0
        self.cbWndExtra = 0
        self.hInstance = 0
        self.hIcon = 0
        self.hCursor = 0
        self.hbrBackground = 0
        self.lpszMenuName = 0
        self.lpszClassName = 0
        self.hIconSm = 0


@fieldwise_init
struct MSG(Defaultable, Copyable, Movable):
    var hwnd: Int
    var message: UInt32
    var wParam: Int
    var lParam: Int
    var time: UInt32
    var ptX: Int32
    var ptY: Int32
    var lPrivate: UInt32

    def __init__(out self):
        self.hwnd = 0
        self.message = 0
        self.wParam = 0
        self.lParam = 0
        self.time = 0
        self.ptX = 0
        self.ptY = 0
        self.lPrivate = 0


comptime WndProcType = def (Int, UInt32, Int, Int) thin abi("C") -> Int


@export("smallest_wndproc")
def smallest_wndproc(
    hwnd: Int, message: UInt32, wparam: Int, lparam: Int
) abi("C") -> Int:
    """Windows calls this. It must never raise, so everything is caught."""
    try:
        if message == UInt32(winkb_constant["WM_DESTROY"]()):
            var PostQuitMessage = win32[
                def (c_int) thin abi("C") -> NoneType, "PostQuitMessage"
            ]()
            _ = PostQuitMessage(c_int(0))
            return 0
        var DefWindowProcW = win32[WndProcType, "DefWindowProcW"]()
        return DefWindowProcW(hwnd, message, wparam, lparam)
    except:
        return 0


def main() raises:
    comptime assert (
        size_of[WNDCLASSEXW]() == winkb_struct_size["WNDCLASSEXW"]()
    ), "WNDCLASSEXW does not match Windows"
    comptime assert (
        size_of[MSG]() == winkb_struct_size["MSG"]()
    ), "MSG does not match Windows"

    var GetModuleHandleW = win32[
        def (Int) thin abi("C") -> Int, "GetModuleHandleW"
    ]()
    var GetLastError = win32[def () thin abi("C") -> UInt32, "GetLastError"]()
    var RegisterClassExW = win32[
        def (Pointer[WNDCLASSEXW, MutAnyOrigin]) thin abi("C") -> UInt16,
        "RegisterClassExW",
    ]()
    var CreateWindowExW = win32[
        def (
            UInt32,
            Pointer[UInt16, MutAnyOrigin],
            Pointer[UInt16, MutAnyOrigin],
            UInt32,
            c_int,
            c_int,
            c_int,
            c_int,
            Int,
            Int,
            Int,
            Int,
        ) thin abi("C") -> Int,
        "CreateWindowExW",
    ]()
    var ShowWindow = win32[
        def (Int, c_int) thin abi("C") -> c_int, "ShowWindow"
    ]()
    var GetMessageW = win32[
        def (
            Pointer[MSG, MutAnyOrigin], Int, UInt32, UInt32
        ) thin abi("C") -> c_int,
        "GetMessageW",
    ]()
    var TranslateMessage = win32[
        def (Pointer[MSG, MutAnyOrigin]) thin abi("C") -> c_int,
        "TranslateMessage",
    ]()
    var DispatchMessageW = win32[
        def (Pointer[MSG, MutAnyOrigin]) thin abi("C") -> Int,
        "DispatchMessageW",
    ]()

    var instance = GetModuleHandleW(0)
    var class_name = wide("MojoSmallestWindow")
    var title = wide("The smallest window")

    # A `def` cannot be handed to Windows directly: it goes through a thin
    # C-ABI fn value first, and the named type is shared with DefWindowProcW
    # so the two cannot drift apart.
    var proc: WndProcType = smallest_wndproc

    var wc = WNDCLASSEXW()
    wc.cbSize = UInt32(size_of[WNDCLASSEXW]())
    wc.style = UInt32(
        winkb_constant["CS_HREDRAW"]() | winkb_constant["CS_VREDRAW"]()
    )
    wc.lpfnWndProc = Int(_fn_ptr_as_opaque(proc))
    wc.hInstance = instance
    wc.hbrBackground = winkb_constant["COLOR_WINDOW"]() + 1
    wc.lpszClassName = Int(class_name.unsafe_ptr())

    if RegisterClassExW(com_addr(wc)) == 0:
        raise Error(
            "RegisterClassExW failed, GetLastError = " + String(GetLastError())
        )

    comptime CW_USEDEFAULT = winkb_constant["CW_USEDEFAULT"]()
    var hwnd = CreateWindowExW(
        UInt32(0),
        class_name.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        title.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        UInt32(winkb_constant["WS_OVERLAPPEDWINDOW"]()),
        c_int(CW_USEDEFAULT),
        c_int(CW_USEDEFAULT),
        c_int(640),
        c_int(400),
        0,
        0,
        instance,
        0,
    )
    if hwnd == 0:
        raise Error(
            "CreateWindowExW failed, GetLastError = " + String(GetLastError())
        )
    _ = ShowWindow(hwnd, c_int(winkb_constant["SW_SHOW"]()))

    var msg = MSG()
    var dispatched = 0
    while True:
        var got = GetMessageW(com_addr(msg), 0, 0, 0)
        if got == 0:
            break
        if got == -1:
            raise Error(
                "GetMessageW failed, GetLastError = " + String(GetLastError())
            )
        _ = TranslateMessage(com_addr(msg))
        _ = DispatchMessageW(com_addr(msg))
        dispatched += 1

    _ = class_name
    _ = title
    print("dispatched", dispatched, "messages")
```

Built and run, it opens a window titled *The smallest window*, 640 × 400 on
screen, with a white client area — `COLOR_WINDOW` on this machine, painted by
`DefWindowProcW` out of the class brush. It sits there until you close it,
then:

```
dispatched 12 messages
```

and exit code 0. The count varies — twelve is what closing it after two
seconds without touching it cost here, eleven and thirteen on neighbouring
runs — because activation, focus and paint messages are not deterministic.
That the number is small and that the program exits at all is the thing to
notice: `WM_DESTROY` reaches the procedure, `PostQuitMessage` puts `WM_QUIT`
on the queue, `GetMessageW` returns 0, and the loop ends. A window that
closes and leaves its process running is always a missing `PostQuitMessage`.

Four details in that listing are load-bearing and easy to lose:

* `CreateWindowExW` is given the **outer** size, frame and title bar
  included, which is why the window measures 640 × 400 and its client area
  does not. To ask for a client area of a given size, put the rectangle you
  want through `AdjustWindowRectEx` first, as `life` does.
* `GetMessageW` returns `-1` on failure, not 0, so the loop tests both. A
  loop written as `while GetMessageW(...) != 0:` spins forever on the failure
  it was meant to notice.
* `TranslateMessage` is what turns `WM_KEYDOWN` into `WM_CHAR`. This program
  reads no keys, so it changes nothing here — omit it in a program that does
  and nothing you type ever arrives.
* The message loop is not optional and it may not block. Windows declares a
  thread that has not pumped for about five seconds to be hung, takes the
  window's surface away from it and draws a ghost.
  [docs/event-loop.md](../../docs/event-loop.md) has what a program owes its
  queue, and `drain` and `settle` in `ide/win32.mojo` are the two functions
  that discharge it.

## What is not covered

**COM** is [Chapter 5](05-com.md): `ComPtr`, `com_method_of`, vtable slots
and IIDs, and what `winkb_vtable_index` and `winkb_interface_iid` are
actually for. This chapter uses them only as examples of queries.

**Origins** — when a pointer needs `unsafe_origin_cast`, and why a variadic
call does not — are [Chapter 3](03-the-dialect.md). The rule used throughout
this chapter is the short version: a declared signature takes
`Pointer[T, MutAnyOrigin]` and the call site casts to match, which
`com_addr` does for you.

**Drawing** is Chapter 6. The window above paints nothing of its own, which
is why it has no `WM_PAINT` handler; a program that draws needs one, and
needs `PAINTSTRUCT`, `BeginPaint` and a decision about what draws the pixels.
`life` uses `StretchDIBits`, Griddle uses Direct2D.

**The remaining queries** — `winkb_struct_align`, `winkb_constant_text`,
`winkb_type_width`, and the `winkb_com_*` family that describes method
signatures — are in the reference rather than here, because they exist to
build tools rather than to call an API.

**The library above this chapter.** Everything here is the floor.
`std.windows` -- [documented in the reference](../reference/04-std-windows.md)
-- is what the floor supports: `core` owns the wide-string boundary, `gui`
the window and the loop, `audio` the WASAPI render path, and each records in
one place the trap this chapter can only warn about. The rule is small: when
the library already does the thing, import it; when it does not, this chapter
is how you write the call -- and if what you wrote turns out to be general,
it belongs in the library.

**Checking a signature against the metadata** is not something the compiler
does. The database knows every parameter of every function; nothing today
compares your declaration to it. That is the largest gap in this chapter and
it is the reason "spell every argument" is a rule you have to keep rather
than one you are held to.
