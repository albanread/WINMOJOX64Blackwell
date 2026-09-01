# 3. The dialect

This fork is frozen at one commit of Mojo, and the language moved on. Almost
everything written about Mojo — the manual, the talks, the blog posts, and
every language model that read them — describes a version this is not. Not in
the corners: in the first line of the first example.

This chapter is the list of differences that have cost somebody an afternoon,
each with the reason it exists. Every program on this page was compiled by
the build that shipped with your copy, and the outputs are what it printed.

The rule underneath all of it: **the compiler in your hands is the authority.**
When this guide and another source disagree, believe the compiler. When this
guide and the compiler disagree, the guide is wrong and wants fixing.

## The one-page version

| You will read | This compiler wants | What happens if you do not |
|:---|:---|:---|
| `from sys import argv` | `from std.sys import argv` | `unable to locate module 'sys'` |
| `alias N = 4` | `comptime N = 4` | warning, with a fix-it |
| `@parameter if` / `@parameter for` | `comptime if` / `comptime for` | warning, with a fix-it |
| `fn` for an ordinary function | `def` — `fn` means something else here | it compiles and means C ABI |
| `len(s)` on a string | `s.byte_length()` | error naming all three answers |
| `s[0:3]` | `s[byte=0:3]` or `s[codepoint=0:3]` | error naming both spellings |
| `UnsafePointer` | `Pointer` | warning; it is the same type |
| `__copyinit__`, `__moveinit__` | `__init__(out self, *, copy: Self)` and `(*, deinit move: Self)` | nothing — they are ordinary methods that never run |
| `__del__` | `__deinit__` | warning, with a fix-it |
| `@register_passable` | conform to `RegisterPassable` | `decorator @register_passable is removed` |
| `List[T](a, b, c)` | `var xs: List[T] = [a, b, c]` | `no matching function in initialization` |
| `InlineArray`, `Stringable` | `List`; `Writable` | `use of unknown declaration` |
| `for x in (a, b, c)` | a `List`, or unroll it | `'Tuple[...]' does not implement the '__iter__' method` |

The compiler's own diagnostics are the best migration guide there is: most of
them name the replacement and offer to apply it. The rest of this chapter is
the cases where the diagnostic is not enough, or where there is no diagnostic
at all.

## Imports name `std`

The standard library is a package called `std`, and every import says so.

```mojo
from std.sys import argv
from std.math import sqrt
from std.sys._winkb import winkb_function_dll

def main():
    print("argv[0]:", argv()[0])
    print("sqrt(2):", sqrt(2.0))
    print("CreateWindowExW lives in", winkb_function_dll["CreateWindowExW"]())
```

```
argv[0]: E:\WinMojo\build\doc_check.exe
sqrt(2): 1.4142135623730951
CreateWindowExW lives in USER32.dll
```

Every tutorial you will find writes `from sys import argv`, `from memory import
UnsafePointer`, `from collections import List`. Those are the old top-level
module names, and they are gone; the modules are the same modules, one package
deeper. The error is unambiguous —

```
error: unable to locate module 'sys'
```

— so this one costs a minute rather than an afternoon. It is first here because
it is the difference you will meet first, and because seeing it tells you that
the rest of the page you were reading is also from before the move.

`print`, `String`, `List`, `Int`, `Pointer` and the rest of the prelude need no
import at all.

## `comptime`, where you have read `alias`

Everything that happens at compile time is spelled `comptime`. It is one
keyword doing four jobs that used to have four spellings.

```mojo
from std.sys.info import CompilationTarget, size_of
from std.sys._winkb import winkb_struct_size


@fieldwise_init
struct POINT(Copyable, Movable):
    var x: Int32
    var y: Int32


comptime MAX_LINES = 10000
comptime PRODUCT = StaticString("griddle")


def main():
    comptime assert size_of[POINT]() == winkb_struct_size["POINT"](), (
        "POINT has drifted from the Windows SDK"
    )

    comptime if CompilationTarget.is_windows():
        print(PRODUCT, "keeps", MAX_LINES, "lines of build output")
    else:
        CompilationTarget.unsupported_target_error[operation="griddle"]()

    comptime for shift in range(4):
        print("1 <<", shift, "=", 1 << shift)
```

```
griddle keeps 10000 lines of build output
1 << 0 = 1
1 << 1 = 2
1 << 2 = 4
1 << 3 = 8
```

`comptime X = ...` replaces `alias`, `comptime if` replaces `@parameter if`,
`comptime for` replaces `@parameter for`, and `comptime assert` replaces
`__comptime_assert`. The old spellings still compile and warn.

This is not a cosmetic rename you can ignore. The standard library in this tree
uses `comptime` 3,361 times and `alias` 51, and the 51 are residue. Any code
you find that writes `alias` was written before the change, which tells you
something about everything else on that page.

The `comptime if` above is worth a second look: the branch not taken is never
elaborated, so the `unsupported_target_error` in the `else` is not a runtime
check that never fires — it is a compile error that would have fired on Linux.
That is how the standard library gates platforms, and it is how this fork's
Windows-only code sits in the same files as everything else.

## `let` and `var`

Both exist. `var` declares a mutable variable; `let` declares an immutable
binding. Assigning to a `let` is `error: expression must be mutable in
assignment`.

The part that is not obvious, and that has caught people on the Mac port this
was borrowed from:

> **`let` binds a name. `var` copies a value.**

```mojo
from std.sys._winkb import winkb_constant


def main():
    # A binding. `WM_CLOSE` cannot be assigned to again.
    let WM_CLOSE = winkb_constant["WM_CLOSE"]()

    var count = 1
    let bound = count        # another name for `count`
    var copied = count       # a copy of what `count` held

    count = 2

    print("WM_CLOSE =", WM_CLOSE)
    print("count =", count, " let bound =", bound, " var copied =", copied)
```

```
WM_CLOSE = 16
count = 2  let bound = 2  var copied = 1
```

`bound` follows `count`; `copied` does not. If you reach for `let` because it
reads as "a constant", you have written an alias for something that is still
moving. Use `let` for a value you receive and hand on — a handle, an interface
pointer, a result — and `var` when you mean a snapshot.

`let` carries no ownership meaning of its own. It does not retain, release or
free anything; reference counting lives in `ComPtr` and nowhere else.

## `def`, `fn`, and `raises`

Upstream removed `fn` and made everything a `def`. This fork brought the
keyword back with a narrower meaning, because the Windows boundary needs a
contract the *callee* side can rely on:

> **`def` is an ordinary Mojo function. `fn` is a function the foreign side may
> call: C ABI, non-raising, no captured state.**

A window procedure, a COM vtable slot, an enumeration callback — Windows calls
each of these with no closure, no error channel and its own calling convention.
`fn` is the one-word way to say so.

```mojo
from std.memory import Pointer
from std.sys._com import com_addr
from std.sys._win32 import Win32Module


fn count_window(hwnd: Int, lparam: Int) -> Int32:
    # No captures: the state arrives as an address in LPARAM.
    var counter = Pointer[Int, MutAnyOrigin](unsafe_from_address=lparam)
    counter[] += 1
    return 1                       # keep enumerating


def main() raises:
    let user32 = Win32Module("user32.dll")
    let enum_windows = user32.function[
        def (
            def (Int, Int) thin abi("C") -> Int32,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> Int32
    ]("EnumWindows")

    var count: Int = 0
    _ = enum_windows(count_window, com_addr(count))
    print("top-level windows:", count)
```

```
top-level windows: 208
```

Change that `fn` to `def` and the program stops building at the point where the
callback is handed over:

```
error: invalid indirect call: value cannot be converted from
       'def count_window(hwnd: Int, lparam: Int) thin -> Int32'
       to 'def(Int, Int) abi("C") thin -> Int32'
```

That is the whole argument for the keyword: the mismatch is a compile error at
the call site rather than a crash inside `user32`.

Two consequences follow from the contract:

**`fn` may not raise.** `fn f() raises` is refused, by name:

```
error: 'fn' declares a foreign-callable (C ABI, non-raising) function in
       win-mojo and may not be marked 'raises'; use 'def' for an ordinary
       Mojo function
```

Catch inside the callback, or do not raise there. There is nowhere for the
error to go: the caller is `user32.dll`.

**`fn` is still a reserved word.** `var fn = 3` does not parse, and the message
you get is a leftover from upstream's removal —

```
error: 'fn' has been removed; use 'def' instead
```

— which is untrue in this fork and unhelpful in that spot. Name the variable
`proc`, `entry` or `callback`.

### `def` does not imply `raises`

A `def` that calls anything which may raise must say `raises` itself. This is
the most common first error in a program that opens a file or loads a DLL:

```
error: cannot call function that may raise in a context that cannot raise
note: try surrounding the call in a 'try' block
note: or mark surrounding function as 'raises'
```

`def main() raises:` is the usual answer, and it is why almost every example in
this guide spells it that way.

## Pointers and origins

`Pointer` is the only pointer type. It carries an **origin** — a parameter
saying which memory it refers to — and it cannot be null.

```mojo
from std.collections import Optional
from std.memory import Pointer


def deref(address: Int) -> Optional[Int]:
    if address == 0:
        return None
    return Pointer[Int, MutAnyOrigin](unsafe_from_address=address)[]


def main():
    var value = 7
    var p = Pointer(to=value)
    p[] += 1

    print("through the pointer:", value)
    print("from an address:", deref(Int(p)).value())
    print("from nothing:", deref(0).__bool__())
```

```
through the pointer: 8
from an address: 8
from nothing: False
```

`Pointer(unsafe_from_address=0)` is a compile error, not a runtime surprise:

```
note: constraint failed: Pointer is non-nullable. To construct a null
      pointer, use Optional[Pointer] to model nullability.
```

This matters at every Windows boundary, because half of Win32 returns a
nullable pointer and the other half takes one. Carry those as `Int` across the
boundary and build the `Pointer` once you know the value is non-zero, exactly
as `deref` does above. `OptionalPointer` exists for the cases where the
nullable pointer has to be stored.

### Origins, and where the cast goes

An origin is how the compiler knows a value is still in use. `Pointer(to=x)`
has origin `origin_of(x)`, which is what keeps `x` alive across a call that
writes through it.

There is no implicit conversion between origins. So a function whose signature
you wrote down — a COM method, a typed Win32 entry point — has to be given a
pointer whose origin says `MutAnyOrigin` at the call site:

```mojo
from std.ffi import c_int
from std.memory import Pointer
from std.sys._com import com_addr
from std.sys._win32 import Win32Module


def main() raises:
    var kernel32 = Win32Module("kernel32.dll")

    # 1. A declared signature. The parameter's origin is written down, so
    #    the call site has to say that this pointer matches it.
    comptime QPF = def (Pointer[Int64, MutAnyOrigin]) thin abi("C") -> c_int
    var frequency: Int64 = 0
    var qpf = kernel32.function[QPF]("QueryPerformanceFrequency")
    _ = qpf(Pointer(to=frequency).unsafe_origin_cast[MutAnyOrigin]())
    print("counter frequency:", frequency, "Hz")

    # 2. com_addr does the same thing in one word, and is what the COM and
    #    Win32 call sites in this tree use.
    comptime QPC = def (Pointer[Int64, MutAnyOrigin]) thin abi("C") -> c_int
    var ticks: Int64 = 0
    var qpc = kernel32.function[QPC]("QueryPerformanceCounter")
    _ = qpc(com_addr(ticks))
    print("uptime, roughly:", ticks // frequency, "seconds")
```

```
counter frequency: 10000000 Hz
uptime, roughly: 733822 seconds
```

Drop the cast and the compiler says precisely what is wrong:

```
error: invalid indirect call: value cannot be converted from
       'Pointer[Int64, origin_of(frequency)]' to 'Pointer[Int64, MutAnyOrigin]'
```

**Cast to `MutAnyOrigin`, never to an untracked one.** `MutAnyOrigin` means
"might access any memory value", which keeps the aliasing visible and keeps
`frequency` alive. An untracked origin *promises the pointer aliases nothing
the compiler is managing* — a promise that is false for a local, and one the
compiler is entitled to act on by handing the callee a temporary and never
reading it back. It works often enough to look correct, which is worse than
never working. `examples/win32/structptr` runs all three spellings side by side
against one API so the difference is visible in one program's output.

There is a second rule with the same cause, and it is the single most expensive
mistake in this tree:

> **Never write `Int(Pointer(to=x))` for a by-pointer argument.**

Converting an address to an integer throws away the origin, and with it every
trace that `x` is still being read. The store that initialised `x` can then be
dropped and its stack slot reused. The call still happens, at the right address,
with the right widths, and reads whatever now lives there. Griddle's first
optimised build drew rectangles three hundredths of a pixel wide because of it,
and the debug build was correct, so there was nothing for a debugger to show.
Use `com_addr(x)`, which returns a `Pointer`. The whole story, with the assembly,
is in [addresses-and-optimization.md](../../docs/addresses-and-optimization.md).

### `UnsafePointer` is `Pointer`

The two pointer types were unified. `UnsafePointer` survives as a deprecated
`comptime` alias so that old code keeps building:

```mojo
from std.memory import Pointer, UnsafePointer


def take(p: Pointer[Int, MutAnyOrigin]) -> Int:
    return p[]


def main():
    var value = 7
    var p = UnsafePointer(to=value).unsafe_origin_cast[MutAnyOrigin]()
    print(take(p))
```

That builds, prints `7`, and warns:

```
warning: 'UnsafePointer' is deprecated, use 'Pointer' instead
```

It is the same type, so there is nothing to convert and nothing to fix beyond
the name — except that the alias takes an origin parameter the old type did
not have, which is where porting old code actually stops.

## Strings

Mojo strings are UTF-8, and this compiler refuses the two questions that have
no single answer under UTF-8.

```mojo
def main():
    var s = String("naïve café")

    print("bytes:      ", s.byte_length())
    print("codepoints: ", len(s.codepoints()))
    print("graphemes:  ", len(s.graphemes()))

    print("s[byte=0:5]      =", String(s[byte=0:5]))
    print("s[codepoint=0:5] =", String(s[codepoint=0:5]))
```

```
bytes:       12
codepoints:  10
graphemes:   10
s[byte=0:5]      = naïv
s[codepoint=0:5] = naïve
```

`len(s)` and `s[0:5]` are both compile errors, and both diagnostics list the
spellings that would work. The rule they are enforcing is visible in the output:
the same range means two different things, and the difference is exactly the
`ï`.

Which one you want is usually decided for you. A byte offset from `find`, a
column from a compiler diagnostic, or an index into a buffer you are handing to
Windows is a byte offset — use `byte=`. A caret position a person moved with an
arrow key is not.

### A slice cannot be assigned back over its own string

This is rejected:

```mojo
line = String(line[byte=0:colon])
```

```
error: aliasing values passed immutably to 'args' argument and constructed
       as a result in 'String' initializer call
note: introduce a temporary to avoid mutating the call result while
      accessing it through an argument
```

The message names `args` and `String`, and the note tells you the fix without
telling you what you did. What you did was ask the compiler to build a new
string *out of* the storage it was about to overwrite. Name the result first:

```mojo
def main():
    var line = String("main.mojo:41:7: error: use of unknown declaration")
    var colon = line.find(": ")

    # A slice of `line` cannot be assigned back over `line`: the argument and
    # the result are the same storage. Name the slice first.
    var place = String(line[byte=0:colon])
    line = place^

    print(line)
```

```
main.mojo:41:7
```

`place^` transfers rather than copies, so nothing is duplicated. After a `^` the
name is dead: using `place` again is `use of uninitialized value`.

One more, from the same family: `.strip()` returns a span into the original
string, not a `String`. Wrap it — `String(x.strip())` — or you get a conversion
error about origins that does not mention stripping.

## Structs: the conformances that matter

There are no `__copyinit__` or `__moveinit__` methods in this dialect. Writing
them defines two ordinary methods that nothing ever calls. The contract is the
traits, and the constructors have keyword parameters:

| Trait | What it says | What you write |
|:---|:---|:---|
| `Movable` | this value can be relocated | `def __init__(out self, *, deinit move: Self)` |
| `Copyable` | this value can be copied, when asked | `def __init__(out self, *, copy: Self)`, used as `x.copy()` |
| `ImplicitlyCopyable` | …and the compiler may copy it without being asked | nothing extra; it is a marker |
| `Defaultable` | this value has a zero-argument constructor | `def __init__(out self)` |
| `RegisterPassable` | this value lives in registers | see the warning below |

`@fieldwise_init` gives you the all-fields constructor. The copy and move
constructors are synthesised when every field can be copied and moved, and you
may write either one yourself when the default is wrong.

```mojo
# Passed to Windows by pointer: it needs a zeroing default, and it must not
# claim to be register-passable.
@fieldwise_init
struct RECT(Defaultable, Copyable, Movable):
    var left: Int32
    var top: Int32
    var right: Int32
    var bottom: Int32

    def __init__(out self):
        self.left = 0
        self.top = 0
        self.right = 0
        self.bottom = 0


# Owns two heap containers. Neither String nor List is ImplicitlyCopyable, so
# the implicit copy constructor cannot be synthesised and has to be written.
struct OpenFile(ImplicitlyCopyable, Movable):
    var path: String
    var marks: List[Int]

    def __init__(out self, path: String):
        self.path = path
        self.marks = List[Int]()

    def __init__(out self, *, copy: Self):
        self.path = copy.path.copy()
        self.marks = copy.marks.copy()


def main():
    var r = RECT()
    print("default RECT:", r.left, r.top, r.right, r.bottom)

    var a = OpenFile(String("main.mojo"))
    a.marks.append(41)

    var b = a              # implicit: OpenFile said it was allowed
    b.marks.append(97)

    print(a.path, len(a.marks), "marks;", b.path, len(b.marks), "marks")
```

```
default RECT: 0 0 0 0
main.mojo 1 marks; main.mojo 2 marks
```

Delete `OpenFile`'s copy constructor and the struct will not compile, with the
reason named:

```
error: cannot synthesize implicit copy constructor because field 'marks' has
       non-implicitly-copyable type 'List[Int]'
```

That is the design working. `List` is copyable but not *implicitly* copyable,
because an accidental deep copy of a container is a performance bug that looks
like nothing. A struct that wants to be assigned around freely has to say what
copying it means.

`ImplicitlyCopyable` also decides whether a `comptime` constant of your type can
be used as a runtime value at all:

```
error: cannot materialize comptime value of type 'Iid' to runtime because it
       is not 'ImplicitlyCopyable'
```

So enum-like identifiers meant to be passed around want
`ImplicitlyCopyable, Movable`, not `Copyable, Movable`.

### `TrivialRegisterPassable` on a large struct is a silent catastrophe

This is the one to read twice, because there is no diagnostic anywhere and the
debug build is correct.

`TrivialRegisterPassable` says the value lives in registers and can be copied
with a `memcpy` and destroyed by doing nothing. For a handle or a colour that
is true and useful. For a 64-byte structure you are handing to Windows by
pointer it is false, and the compiler believes you.

```mojo
from std.ffi import c_int, OwnedDLHandle
from std.memory import Pointer
from std.sys.info import size_of


@fieldwise_init
struct StatusRegister(TrivialRegisterPassable):
    var dwLength: UInt32
    var dwMemoryLoad: UInt32
    var a: UInt64
    var b: UInt64
    var c: UInt64
    var d: UInt64
    var e: UInt64
    var f: UInt64
    var g: UInt64


@fieldwise_init
struct StatusMemory(Copyable, Movable):
    var dwLength: UInt32
    var dwMemoryLoad: UInt32
    var a: UInt64
    var b: UInt64
    var c: UInt64
    var d: UInt64
    var e: UInt64
    var f: UInt64
    var g: UInt64


def main() raises:
    var kernel32 = OwnedDLHandle("kernel32.dll")
    var GlobalMemoryStatusEx = kernel32.get_function[c_int](
        "GlobalMemoryStatusEx"
    )

    var bad = StatusRegister(0, 0, 0, 0, 0, 0, 0, 0, 0)
    bad.dwLength = UInt32(size_of[StatusRegister]())
    var ok_bad = GlobalMemoryStatusEx(Pointer(to=bad))
    print("TrivialRegisterPassable: hr =", ok_bad,
          " dwLength =", bad.dwLength, " load =", bad.dwMemoryLoad)

    var good = StatusMemory(0, 0, 0, 0, 0, 0, 0, 0, 0)
    good.dwLength = UInt32(size_of[StatusMemory]())
    var ok_good = GlobalMemoryStatusEx(Pointer(to=good))
    print("Copyable, Movable:       hr =", ok_good,
          " dwLength =", good.dwLength, " load =", good.dwMemoryLoad)
```

Built with `--no-optimization`, both are right:

```
TrivialRegisterPassable: hr = 1  dwLength = 64  load = 37
Copyable, Movable:       hr = 1  dwLength = 64  load = 37
```

Built without it, one of them is not:

```
TrivialRegisterPassable: hr = 1  dwLength = 1254182944  load = 32758
Copyable, Movable:       hr = 1  dwLength = 64  load = 37
```

Windows returned success both times. `mojo build --emit asm` says why. The
struct sits at `264(%rsp)`, is filled in, and is passed correctly:

```asm
movl    $64, 264(%rsp)          ; dwLength = 64
leaq    264(%rsp), %r14
movq    %r14, %rcx
callq   *%rax                   ; GlobalMemoryStatusEx(&struct)
```

and then, before the fields are read back, the same slot is handed to something
else:

```asm
movq    $6, 272(%rsp)                                  ; "load =", length 6
leaq    static_string_238d0dc88dc06c28(%rip), %rax
movq    %rax, 264(%rsp)                                ; "load =", pointer
movl    264(%rsp), %r9d                                ; "dwLength"
movl    268(%rsp), %eax                                ; "dwMemoryLoad"
```

`1254182944` and `32758` are the two halves of the address of the string
`"load ="`. Because the struct is register-passable, its memory is a temporary
materialised for the call rather than the variable itself, so nothing keeps the
slot alive once the call returns. The correct struct is zeroed into a slot the
compiler keeps.

The rule that follows:

> **A struct you pass to the operating system by pointer is
> `(Defaultable, Copyable, Movable)`.** Claim register-passability only for
> genuinely register-sized values.

The same reasoning, and the same class of failure, as `Int(Pointer(to=x))`
above. Both are the optimiser doing its job on information it was given wrongly.

## Lists

`List` is copyable but not implicitly copyable, and the subscript is a
reference.

```mojo
@fieldwise_init
struct Row(Copyable, Movable):
    var n: Int


def main():
    var rows: List[Row] = [Row(1), Row(2), Row(3)]

    # The subscript is a reference; assigning through it mutates the element.
    rows[0].n = 99

    # The loop variable is not. Index when you mean to write.
    for i in range(len(rows)):
        rows[i].n += 1

    var doubled = rows.copy()        # a List copy is always explicit
    doubled[0].n *= 2

    print(rows[0].n, rows[1].n, rows[2].n, "|", doubled[0].n)
```

```
100 3 4 | 200
```

Three things to take from that:

**Construction is a list literal.** `List[T](a, b, c)` does not exist. Write
`var xs: List[T] = [a, b, c]`, or `List[T](length=n, fill=v)` for a sized one.

**`for r in rows` gives you a read-only element.** `r.n = 42` is `error:
expression must be mutable in assignment`, and `r.n += 1` is `error: expression
must be mutable for in-place operator destination`. That is the trap that looks
like the old "the subscript gives you a copy" one, and it is not the same thing:
`rows[i]` is fine, `r` is not.

**A copy of a list is always asked for.** `var d = rows` is refused, with the
two ways out named:

```
error: value of type 'List[Row]' cannot be implicitly copied, it does not
       conform to 'ImplicitlyCopyable'
note: consider transferring the value with '^'
note: you can copy it explicitly with '.copy()'
```

## Module state: `named_global`

There are no module-level variables:

```
error: global variables are not supported; move this into a function body or
       use 'comptime' to declare a constant
```

That is a problem on Windows in particular, because a window procedure is
captureless: the operating system calls it with a message and a handle and
nothing else. Per-window state fits in `GWLP_USERDATA`. Per-*process* state — a
language server connection, a build's output, a debug adapter — has nowhere to
live. `named_global` is that place:

```mojo
from std.sys._globals import named_global

comptime g_lines = named_global["build.lines", List[String]]
comptime g_running = named_global["build.running", Int]

# Not a String. A zero-initialised String has a null byte pointer, and the
# flag bit that says "the bytes are inline" is one of the zeroes.
comptime g_partial = named_global["build.partial", List[String]]


def append_output(text: String):
    g_lines()[].append(text)


def main():
    print("a fresh List global is a valid empty list:", len(g_lines()[]))
    print("a fresh Int global is zero:              ", g_running()[])

    g_running()[] = 1
    append_output(String("mojo build -o build/griddle.exe ide/griddle.mojo"))
    append_output(String("[exit 0 after 1633 ms]"))

    print("lines:", len(g_lines()[]), "->", g_lines()[][1])

    # The reason g_partial is a List: this is what a zero String's bytes are.
    var zero = named_global["demo.zero_string", String]()
    print("zero String byte pointer:", Int(zero[].unsafe_ptr()))
    print("real String byte pointer:", Int(String("").unsafe_ptr()) != 0)
```

```
a fresh List global is a valid empty list: 0
a fresh Int global is zero:               0
lines: 2 -> [exit 0 after 1633 ms]
zero String byte pointer: 0
real String byte pointer: True
```

One storage location per name, deduplicated by the compiler, so two call sites
naming the same slot get the same memory without either knowing about the other.
Namespace the name — `"lsp.task"`, not `"task"` — because the name is the only
thing keeping two subsystems from sharing storage by accident.

**The storage is zero-filled, and that is not the same as constructed.** For an
`Int` it is; for a `List` it is, because a list of null pointer, length zero and
capacity zero is a valid empty list that allocates on first append. For a
`String` it is not. A `String` is three words, and the top bit of the third says
"the bytes are stored inline, here". Zero clears that bit, so a zero-initialised
`String` claims to be a heap string whose buffer is at address 0 — which is what
the last two lines print. It survives `byte_length()` and it survives being
assigned over, so it looks fine until something asks for its bytes, and the
thing that asks is usually Windows.

Store text as a one-element `List[String]`, or as a `List[UInt8]`, and put a
real `String` into it before you read it. Griddle's language-server inbox does
exactly this, for exactly this reason.

## The engineering notes, and where they have gone stale

The index and the reference point at [docs/](../../docs/), and they should:
`DIALECT-NOTES.md`, `mojo-traps.md` and the rest are working notes paid for with
real failures. They are also older than this build. Three entries did not
survive a recheck against the current compiler:

* `DIALECT-NOTES.md` says `fn` is removed. It is not — it came back with a
  narrower meaning, as above.
* It says `list[0].field = x` mutates a copy. It no longer does; the trap moved
  to the `for` loop variable.
* It says `sep.join(xs)` does not exist. It does. `ljust` still does not.

Where those notes and this chapter disagree, this chapter was checked against
the compiler that shipped in your copy.

## What is not covered

* **Calling Win32** — `win32[]`, the metadata queries, struct layout assertions
  against the SDK, and the UTF-16 boundary are [chapter 4](04-calling-win32.md).
  This chapter only borrows from them.
* **COM** — `ComPtr`, `com_method_of`, the `class` keyword and what interface
  ownership means here are [chapter 5](05-com.md).
* **Traits, generics and parameters in general.** This is a chapter about
  differences, not a language tutorial. Where the dialect matches what you have
  read elsewhere, nothing is said about it here.
* **The build and file traps** — the byte-order mark that stops the compiler
  with an error naming a character it cannot print, and the `with open(...)`
  whose handle lives until the function returns rather than until the block
  ends. Both are in [mojo-traps.md](../../docs/mojo-traps.md), both are about
  the toolchain rather than the language, and both will cost you an hour.
* **Python interop**, which is [chapter 2](02-griddle.md#python) for the
  environment and the `bifurcation` example for the code.
* **GPU code**, which has its own [guide](../gpu/).

The largest body of Mojo known to compile against this exact compiler is the
standard library in `mojo/stdlib/std`, and the second largest is `ide/`. When a
question is not answered here, grepping those two is faster than reasoning about
it, and it cannot be out of date.
