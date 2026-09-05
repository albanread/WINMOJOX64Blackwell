# winstr_smoke — the string boundary, smoked

The strings-and-errors facilities everything else in the Windows surface
stands on, exercised in forty lines: UTF-8 to UTF-16 and back, system error
text, and handle truthiness.

## Run it

```
mojo run main.mojo
```

Per case — empty string, "hello", a path, "café über", "🐉 dragon" — it
prints `utf16 units: N roundtrip: ok`, proving the `WideString` conversion
survives non-ASCII and non-BMP text. Then `error_message(2)` and
`error_message(5)` print the system's own words instead of bare numbers,
`last_error()` reports the thread's error state, and null/invalid handles
show their truthiness: *an empty handle must not try to close anything*.

## What it teaches

- **The W-boundary is explicit.** Windows' W-entry points take UTF-16;
  Mojo strings are UTF-8; `WideString(text)` is the conversion and
  `from_wide(wide.unsafe_ptr())` the way back. Nothing converts implicitly,
  so nothing corrupts silently.
- **Error text beats error numbers.** `error_message` and `last_error`
  (from `std.windows`) turn `GetLastError`-style codes into the message a
  person would actually read — the difference between `error 2` and "The
  system cannot find the file specified".
- **Handles are values with a null.** `Handle(adopt=0)` and
  `Handle(adopt=-1)` are false and safe to drop; the type's destructor
  closes only what is real.
