# structptr — one struct, one API, three idioms

The minimal struct-by-pointer test, and the origin rules made observable.
It calls `GlobalMemoryStatusEx` three ways with the same Mojo struct and
prints what landed each time — one of the three is *expected* to fail, with
a sentinel proving it.

## Run it

```
mojo run main.mojo
```

(needs `MODULAR_MOJO_MAX_WINKB_PATH` — the struct assertion elaborates a
metadata query). Prints `ok` / memory load / total physical bytes per
idiom.

## The three idioms

1. **True origin, no cast** (main.mojo:49) — the API is declared variadic,
   so `GlobalMemoryStatusEx(Pointer(to=m1))` hands the pointer with its
   real origin: the checker can see the callee's writes land in `m1`, and
   they do.
2. **`unsafe_origin_cast[MutUntrackedOrigin]()`** (main.mojo:62) — the cast
   promises the pointer does *not* alias the local. That promise is false
   here, and the struct is pre-filled with a sentinel (`12345`) so the
   printout shows whether the write actually landed: with this compiler
   today it does land, but the promise licenses the compiler to pass a
   temporary, and *it sometimes works anyway, which is worse than never
   working*.
3. **A hand-built `MutAnyOrigin` signature** (main.mojo:79) — the API is
   declared with `AnyOrigin` and the call casts to match, the idiom every
   declared signature in the tree uses.

## What it teaches

The layout half first: the Mojo `MEMORYSTATUSEX` is pinned to the SDK with
`comptime assert size_of[...]() == winkb_struct_size[...]()` before
anything is called (main.mojo:40). Then the origin rules from
[the language reference](../reference/01-language.md) in ten lines each:
true origins for variadic calls, `AnyOrigin` plus a cast for declared
signatures, and why `Untracked` is a promise about aliasing rather than a
spelling inconvenience.
