# The language

This is the Mojo this compiler accepts, spelled out. It is frozen at one
upstream commit and it is not the version most writing about Mojo describes;
[chapter 3 of the guide](../guide/03-the-dialect.md) lists the differences
and why each exists. This page states the language itself, positive form:
what you write, what it means, and what it compiles to.

The authority behind every statement here is `mojo/stdlib/std` — the largest
body of Mojo known to compile against this exact compiler. When this page
and the compiler disagree, the page is wrong and wants fixing.

## Modules and imports

The standard library is a package called `std`, and every import names it.

```mojo
from std.sys import argv
from std.math import sqrt
from std.collections import List
from std.sys._winkb import winkb_struct_size
```

An import names a module or a symbol. Underscore-prefixed modules
(`std.sys._winkb`, `std.sys._com`) are imports all the same; the underscore
marks them as machinery, not as private. Imports sit at module scope, or at
the top of a function — never inside a nested block.

A program is any file with a `main`; the compiler runs it with
`mojo run file.mojo` (JIT) and builds it with `mojo build` (an executable).

## `def`, and when it must say `raises`

`def` declares a function. A body that can fail says `raises`, and a caller
that can raise must itself be declared `raises` — the check is transitive
and enforced at every call site:

```mojo
def main() raises:
    ...
```

The diagnostic for forgetting either half is `cannot call function that may
raise in a context that cannot raise`, pointing at the call. Functions that
must not raise — window procedures, C callbacks — catch inside:

```mojo
@export("fluid_wndproc")
def fluid_wndproc(hwnd: Int, message: UInt32, wparam: Int, lparam: Int) abi("C") -> Int:
    try:
        ...
    except:
        return 0
```

## `fn` — the C-ABI declaration

`fn` is not the ordinary function spelling here; that is `def`. `fn`
declares a captureless callable with C calling convention, for handing *to*
the platform — a vtable slot, a callback, an entry Windows will call:

```mojo
fn sink_query_interface(this: Int, riid: Int, ppv: Int) -> Int32:
    ...
```

A `fn` cannot `raises` — `fn ... raises` refuses to compile, because
unwinding through a C frame is undefined. State travels through the
arguments, usually a `void *` the API hands back. The COM chapter shows
`fn` used exactly this way to build a vtable by hand
([spikes/com/s08_sink_vtable.mojo](../../spikes/com/s08_sink_vtable.mojo)).

The type of such a callable, when stored or declared in a signature, is:

```mojo
comptime SIG = def (Int, Int, Pointer[Int, MutAnyOrigin]) thin abi("C") -> Int32
```

`thin` is required (it makes the type `TrivialRegisterPassable`), and every
argument must be spelled: an under-declared signature compiles and then
corrupts the call silently.

## `let` and `var`

`let` binds a name once; assigning to it again is a compile error. `var`
binds a mutable name. Everything else about the two is the same.

```mojo
let ole32 = OwnedDLHandle("ole32.dll")   # this name never changes
var attempts = 0                          # this one does
attempts += 1
```

`let` is the right spelling for anything the function merely uses — handles,
looked-up entry points, parsed results. The standard library and every
example under [examples/](../../examples/win32/) use it that way.

## `comptime`

`comptime` marks what the compiler evaluates during compilation. Four forms:

```mojo
comptime N = 320                    # a named constant (this dialect's `alias`)
comptime W = winkb_struct_size["RECT"]()   # a constant from a metadata query

comptime if CompilationTarget.is_windows():    # a branch resolved at compile time
    ...                                        # the untaken side is never seen

comptime for i in range(SLOTS):     # an unrolled loop over known bounds
    wire_slot[i]()

comptime assert size_of[WNDCLASSEXW]() == winkb_struct_size["WNDCLASSEXW"]()
```

Struct parameters are compile-time too, and take `StaticString` for text:

```mojo
struct ComPtr[interface_name: StaticString](Boolable, Copyable, Movable): ...

var s = ComPtr[StaticString("IStream")](adopt=addr)
```

A `comptime` constant of struct type can be used as a runtime value only if
the struct is `ImplicitlyCopyable` — the diagnostic for getting this wrong
names exactly that.

## Structs

Declaration order is layout order, with natural alignment — a Mojo struct
at an FFI boundary lands its fields where C puts them. The lifecycle traits
state what a struct can do:

```mojo
@fieldwise_init
struct Scene(Copyable, Defaultable, Movable):
    var pixels: Int
    var width: Int
    var height: Int
```

| Trait | Grants |
|:---|:---|
| `Copyable` | copying; the compiler synthesises the copy constructor unless you write one |
| `Movable` | moving out of a dying value |
| `Deinitable` | destruction — write `__deinit__` when the struct owns something |
| `ImplicitlyCopyable` | copies the compiler may insert on its own (needed for comptime constants passed at runtime) |
| `RegisterPassable` | passed in registers; for genuinely small values only |
| `Boolable` | the value may be tested with `if x:` |
| `Writable` | `print(x)` works through your `write_to` |

Constructors write `out self` for the value being built; the copy and move
constructors are keyword-disambiguated, and a struct with a `__deinit__`
must write both itself:

```mojo
def __init__(out self):                    # default
def __init__(out self, *, copy: Self):     # copy
def __init__(out self, *, deinit move: Self):  # move — source's destructor will NOT run
def __deinit__(deinit self):               # destructor
```

`@fieldwise_init` synthesises the all-fields constructor. The old dunder
names (`__copyinit__`, `__moveinit__`, `__del__`) do not exist here.

## Values die at their last use

Destruction is not scoped to the block; a value dies when its name is last
read. Two spellings follow from this:

- `value^` — transfer ownership and kill the name; using it afterwards is
  `use of uninitialized value`.
- `value.copy()` — an explicit copy, leaving the original alive.

This composes with COM exactly and dangerously: a `ComPtr` Releases at its
last use, which can be three lines before the block ends. Where order
matters, name a keep-alive. The COM reference has the whole story.

## Origins and pointers

A pointer carries both a type and an *origin* — what memory it may alias.
The rules, in the order they are usually needed:

1. **Variadic calls take the true origin, no cast.**
   `external_call["func", Int32](id, Pointer(to=ts))` — the callee's writes
   through the pointer land in `ts`.
2. **Declared signatures take `AnyOrigin`, and the call casts to match.**
   There is no implicit origin conversion:
   `p.unsafe_origin_cast[MutAnyOrigin]()`. The cast preserves mutability;
   changing mutability is a separate, earlier call
   (`p.unsafe_mut_cast[True]()` or `.as_imm()`).
3. **`UntrackedOrigin` is for memory that is not Mojo's** — interface
   pointers, allocations Windows handed back. Casting a local's pointer to
   `Untracked` licenses the compiler to pass a temporary; it sometimes
   works anyway, which is worse.

The pointer itself is non-nullable: `unsafe_from_address=0` is a compile
error, so FFI code carries addresses as `Int` and constructs a pointer only
once the value is known non-zero. Arithmetic is `p.unsafe_offset(i)`;
`p[]` dereferences; `OpaquePointer[...]` is the `void *`.

```mojo
var x: Int = 0
var p = Pointer(to=x)          # true origin of the local
p[] = 7
var q = p.unsafe_offset(2)     # pointer arithmetic, spelled
```

Origin aliases live in `std.origin`: `MutAnyOrigin`, `ImmutAnyOrigin`, and
the `Unsafe` variants.

## The FFI floor

```mojo
# by name, variadic — resolved at link time
external_call["MessageBoxW", c_int](...)

# a DLL at run time, typed signature, through the process-lifetime cache
var MessageBoxW = win32[def (Int, Pointer[UInt16, MutAnyOrigin],
                            Pointer[UInt16, MutAnyOrigin], UInt32)
                        thin abi("C") -> c_int, "MessageBoxW"]()

# an address already in hand, as a callable
var entry = Pointer(to=addr_int).unsafe_bitcast[SIG]()[]
```

`win32[]` comes from `std.windows.gui` and resolves the DLL through the
metadata; [the metadata reference](02-metadata-queries.md) documents that
layer. Callbacks out of Mojo are top-level `def`s with `abi("C")` and
`@export("name")`, never `raises`.

## Strings

Strings are UTF-8 and refuse to pretend otherwise: `len(s)` is a compile
error. The three answers are spelled:

```mojo
s.byte_length()          # bytes
len(s.codepoints())      # code points
len(s.graphemes())       # what a person counts
```

Slices say which unit: `s[byte=0:3]` or `s[codepoint=0:3]` — a bare `s[0:3]`
is an error naming both spellings. `StaticString` is the compile-time string
for parameters. Windows W-entry points want UTF-16; the conversion is
explicit (`std.windows.core.WideString`, or `wide()` in the samples). The
`t"..."` interpolation exists and produces a t-string.

## Collections

`List[T]` is the workhorse: list literals (`var xs: List[Int] = [1, 2]`),
`append`, `resize(n, fill)`, and `unsafe_ptr()` for the stable heap address.
Two rules with teeth:

- `list[0].field = x` mutates a *copy* of the element. Build the value, then
  `append(value^)`.
- Tuples do not iterate — `for x in (a, b, c)` is a compile error. Use a
  `List`, or unroll with `comptime for`.

`Dict[K, V]`, `Span[T, origin]` (a borrowed view, much used at GDI
boundaries), and `Optional[T]` round out the everyday set. Mutable aliasing
is enforced: two mutable pointers into the same object in one call is
`aliasing values passed mutably`.

## Errors

```mojo
raise Error("the encoder produced no frame")

try:
    ...
except e:
    print("failed:", e)
```

`Error` carries a message. `try`/`except` needs no type list — there is one
error type. Any `def` that reaches a `raise` says `raises`, all the way up
to `main`.

## Reserved words

`fn`, `struct` and `interface` cannot be identifiers or parameter names.
Call the variable `proc`, `type_name`, `iface` — the diagnostic is
`expected parameter name`, which names nothing.

## Platform gating

```mojo
comptime if CompilationTarget.is_windows():
    ...
else:
    CompilationTarget.unsupported_target_error[operation="thing"]()
```

The runtime never sees the untaken branch.

## What is deliberately not here

`fn` as the ordinary function spelling, `alias`, `@parameter`,
`UnsafePointer`, `InlineArray`, `__copyinit__`/`__moveinit__`/`__del__`,
`Stringable`, tuple iteration, `len(string)`, `List[T](a, b, c)` variadic
construction. [Chapter 3](../guide/03-the-dialect.md) has the full table
with the diagnostic each produces; [the dialect notes](../../docs/DIALECT-NOTES.md)
have the working-notes versions with the stories attached.
