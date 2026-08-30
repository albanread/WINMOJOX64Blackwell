# The optimized build did not draw

**Status: fixed.** Found while adding an `-Optimized` switch to
`tools/build-ide.ps1` during sprint 1.2, though it had been there since
sprint 0.4. Kept because the shape of the bug is worth recognising again, and
because the guard against it is a grep rather than a test.

## The symptom

Build Griddle with optimization on and the program is, by every means
available to it, healthy: the window opens, the menu works, the agent answers
every verb, the drop target registers, the rope reports its 250,001 lines, and
`EndDraw` returns success. Almost nothing appears on screen.

Identical source, both ways, same machine, same session:

| build | screenshot | what was visible |
| --- | --- | --- |
| `--no-optimization` | 65 KB PNG | the whole interface |
| optimized (sprint 1.1) | 8.6 KB PNG | nothing at all |
| optimized (sprint 1.2) | 14.7 KB PNG | the four text labels |

An unoptimized build was correct, so there was nothing to debug in the usual
sense: no crash, no bad HRESULT, and printing every argument at every call
site showed correct values throughout — the colour with the right components
and an alpha of 1.0, the rectangles with the right coordinates, a live brush,
a live text format. Adding the diagnostic was itself part of the problem, as
it turned out, though not in the way that usually means.

## The cause

The answer was in the generated assembly, which is where this should have
started rather than where it ended up. `_fill` at `-O2`:

```asm
vmovups %xmm0, 48(%rsp)      ; the colour struct
leaq    48(%rsp), %rdx       ; &colour  -> CreateSolidColorBrush
callq   *64(%rax)
...
leaq    48(%rsp), %rdx       ; &colour AGAIN -- handed to FillRectangle as the rect
callq   *136(%r9)            ; FillRectangle
```

The rectangle and the colour had been merged into one stack slot, and the
store that filled the rectangle had been deleted. `FillRectangle` was reading
the colour's four floats as `left, top, right, bottom`: for the editor panel,
a rectangle `(0.114, 0.125, 0.149, 1.0)` — three hundredths of a pixel wide,
drawn faithfully, in the right colour, eleven times a frame.

The cause is one spelling:

```mojo
com_method_of[def (..., Int, Int) thin abi("C") -> NoneType, ...](this)(
    this, Int(Pointer(to=r)), brush)
```

`Int(Pointer(to=r))` erases the origin. `r`'s last *known* use is then the
address-taking, so nothing records that `r` is still being read, and the
optimizer is free to drop its initialising store and give its slot away. The
call still happens, at the right slot, with the right widths. It reads
whatever now occupies that memory.

Two things made it hard to see. It is invisible without optimization, because
the stores survive and the slots do not get merged. And any diagnostic added
after the call is a use, which extends the lifetime and can make the value
correct again — the values printed fine while the drawing stayed wrong,
because printing `r` fixed `r` and did nothing for the eight other sites.

## The fix

Keep the value a pointer all the way into the call. A pointer argument is an
escape the optimizer has to respect; an integer is just a number.

```mojo
com_method_of[
    def (..., Pointer[D2D_RECT_F, MutAnyOrigin], Int) thin abi("C") -> NoneType,
    ...,
](this)(this, com_addr(r), brush)
```

`com_addr` is in `std/sys/_com.mojo`, beside `com_method_of`, because this is
a fact about calling Windows and not a fact about the IDE. Its docstring is
the short version of this page. After the change the optimized build is
pixel-identical to the debug build, and a scroll-and-paint frame on the 14 MB
document costs 0.37 ms against 0.51 ms unoptimized.

## The guard

`tools/check-ide.ps1` greps `ide/` for `Int(Pointer(to=` and fails if it comes
back. That is a lint rather than a test on purpose: the defect does not show
in the build the checks run against, so no amount of exercising the debug
binary would ever catch a regression. The one place the old spelling is still
correct is `spikes/com/s15_class_destructor.mojo`, where an address is stored
in a COM object's field and outlives the expression entirely — a different
thing from a by-pointer call argument.

## Still open

Whether this is a Mojo bug or a documented consequence of erasing an origin.
It is at least a very sharp edge: the safe and the unsafe spellings differ by
one conversion, both compile, both are correct at `-O0`, and the compiler says
nothing. A warning when the address of a local is converted to an integer and
the local has no later use would have caught every instance of this in one
build.
