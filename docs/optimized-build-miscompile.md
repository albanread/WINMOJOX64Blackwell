# The optimized build does not draw

**Status: open. Predates sprint 1.2. The IDE ships unoptimized, so nothing is
currently blocked by it — but the whole point of the grid is speed, and the
speed claims cannot be made on a build that renders a blank window.**

## What happens

Build `ide/griddle.mojo` with optimization on and the program is, by every
means available to it, healthy: the window opens, the menu works, the agent
answers every verb, the drop target registers, the rope reports its 250,001
lines, and `EndDraw` does not complain. Almost nothing appears on screen.

Identical source, both ways, same machine, same session:

| build | screenshot | what is visible |
| --- | --- | --- |
| `--no-optimization` | 65 KB PNG | the whole chrome, the text grid, the labels |
| optimized | 14.7 KB PNG | the four labels, nothing else |

At sprint 1.1 the optimized build drew *nothing* — a blank white window,
8.6 KB. So this is not a regression from the grid work; the grid work made it
less bad, which is its own puzzle and probably a clue.

## What is ruled out

**The values are correct where they are passed.** Printing the arguments at
every call site in the optimized build shows the colour struct with the right
components and an alpha of 1.0, the rectangles with the right coordinates, a
non-zero brush, and a non-zero text format. Nothing arrives garbled.

**It is not only a lifetime hole, though there is one.** `Int(Pointer(to=x))`
erases the origin, so `x`'s last known use is the address-taking and Mojo is
free to end its lifetime before the call it was taken for. That is real:
adding `_ = size` after `rt.Resize(Int(Pointer(to=size)))` is the difference
between `Resize` returning `D2DERR_EXCEEDS_MAX_BITMAP_SIZE` and returning
success. Every such site in `ide/` now carries a keep-alive.

But keep-alives do not fix the drawing. `_fill` has one on its colour and one
on its rectangle, both values print correctly after the call, and the
rectangle is still not filled. Whatever else is wrong is not this.

## What has not been looked at yet

- `Com[...](borrowed=...)` is a non-owning view. If its destructor releases
  anyway, ASAP destruction under optimization would drop the render target's
  refcount mid-frame, where in a debug build the same destructor runs at end
  of scope. `_fill` and `_label` each construct one. This is the first thing
  to check.
- Whether `com_method_of`'s slot lookup resolves differently once inlined.
- Whether the failing calls have anything in common beyond returning void:
  `Clear` and `FillRectangle` fail, `DrawText` works, and all three take an
  address argument through the same raw layer.
- The generated IR for one `_fill`, both ways, diffed. This is the answer, and
  it should probably have been the first step rather than the fourth.

## How to reproduce

```bash
tools/build-ide.ps1 -Out build/griddle-opt.exe -Optimized
build/griddle-opt.exe --cmd "paint;;screenshot build/opt.png"
tools/build-ide.ps1 -Out build/griddle-dbg.exe
build/griddle-dbg.exe --cmd "paint;;screenshot build/dbg.png"
```

The two PNGs differ by about 50 KB, which is the entire user interface.
