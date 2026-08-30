# Addresses given to Windows must stay pointers

**Rule: spell every by-pointer argument `com_addr(x)`, and give the parameter
a `Pointer[T, MutAnyOrigin]` in the signature. Never `Int(Pointer(to=x))`.**

This is not a compiler bug and there is nothing here to fix in the toolchain.
Converting an address to an integer throws away the fact that the storage is
still live; folding and slot-merging on what remains is the optimizer doing
its job on the information it was given. The defect is in the spelling.

## What it looks like when you get it wrong

Griddle's first optimized build ran, opened its window, worked its menu,
answered every agent verb, registered its drop target, reported its 250,001
lines, and got a successful HRESULT out of `EndDraw`. It drew almost nothing.
The unoptimized build of identical source drew correctly.

The assembly said why. `_fill` at `-O2`:

```asm
vmovups %xmm0, 48(%rsp)      ; the colour struct
leaq    48(%rsp), %rdx       ; &colour  -> CreateSolidColorBrush
callq   *64(%rax)
...
leaq    48(%rsp), %rdx       ; &colour AGAIN -- handed to FillRectangle as the rect
callq   *136(%r9)            ; FillRectangle
```

The rectangle and the colour had been merged into one stack slot and the
rectangle's initialising store dropped. `FillRectangle` was reading the
colour's four floats as `left, top, right, bottom`: for the editor panel a
rectangle `(0.114, 0.125, 0.149, 1.0)`, three hundredths of a pixel wide,
drawn faithfully, in the right colour, eleven times a frame.

The call site was:

```mojo
com_method_of[def (..., Int, Int) thin abi("C") -> NoneType, ...](this)(
    this, Int(Pointer(to=r)), brush)
```

`Int(Pointer(to=r))` erases the origin, so `r`'s last recorded use is the
address-taking. Nothing then says `r` is read afterwards, and the optimizer
is entitled to drop its store and reuse its slot. The call still happens, at
the right slot, with the right widths, and reads whatever now lives there.

## The spelling that works

```mojo
com_method_of[
    def (..., Pointer[D2D_RECT_F, MutAnyOrigin], Int) thin abi("C") -> NoneType,
    ...,
](this)(this, com_addr(r), brush)
```

`com_addr` is in `std/sys/_com.mojo`, beside `com_method_of`, because it is a
fact about calling Windows rather than a fact about the IDE. It returns a
`Pointer`, which keeps the storage visibly in use across the call.

The one place the integer form is still right is an address that is *stored*
and outlives the expression — see `spikes/com/s15_class_destructor.mojo`,
which hands a counter's address to a COM object that bumps it from its
destructor. That is a different thing from a by-pointer call argument.

## Finding it again

Two things make this expensive to diagnose from the outside, and both are
worth knowing before the next one:

**Debug at `-O0`.** The unoptimized build is correct here, so a debugger has
nothing to show you. When behaviour differs between optimization levels, the
tool is `mojo build --emit asm` at both levels, diffed. That is the first
move, not the fourth.

**Do not reach for print.** A diagnostic placed after the call is itself a
use, and extends the lifetime it is trying to observe. Printing every
argument showed all of them correct while the drawing stayed wrong, because
printing `r` fixed `r` and did nothing for the eight other sites.

## The guard

`tools/check-ide.ps1` greps `ide/` for `Int(Pointer(to=` and fails if it
returns. A lint rather than a test on purpose: the consequence does not
appear in the build the checks run against, so no amount of exercising the
debug binary would catch a regression.

## What it cost, and what it bought

Fixed at `81252df`. Afterwards the optimized build is pixel-identical to the
debug one, and a scroll-and-paint frame on a 250,001-line, 14 MB document
costs 0.37 ms optimized against 0.51 ms unoptimized — 44x and 33x the 60 Hz
budget respectively.
