# winkb_queries — the metadata, printing its own provenance

Thirty-nine lines that answer the question *where does the compiler get
all this?* by running the queries and printing what came back: the size
and alignment of `RECT`, the offset of its `bottom` field, the size of
`OVERLAPPED`, the offset of its `hEvent`, which DLL `GetCursorPos` lives
in, and which vtable slot `IUnknown::Release` occupies.

## Run it

```
mojo run main.mojo
```

Every number printed was supplied by `windows_api.db` at compile time —
as the comment puts it, *nobody wrote 16 here; the metadata did*.

## What it teaches

- The query surface from [the metadata reference](../reference/02-metadata-queries.md),
  one line each: `winkb_struct_size`, `winkb_struct_align`,
  `winkb_field_offset`, `winkb_function_dll`, `winkb_vtable_index`.
- The assertion pattern that turns the metadata into a proof:

  ```mojo
  comptime assert winkb_struct_size["RECT"]() == 16
  ```

  The Mojo `RECT` declaration is checked against Windows itself; if the
  struct and the database ever disagree, the build fails instead of the
  call corrupting.
- What happens on a miss: change a name to something the SDK does not
  spell (`winkb_struct_size["RECTANGLE"]()`) and the error is at the line,
  naming the query and the name. That is the whole design — the database
  knows the Windows API; what it does not know cannot silently become zero.

The file fails to elaborate without `MODULAR_MOJO_MAX_WINKB_PATH`, which is
itself the lesson: these are compile-time reads of a database, not runtime
lookups.
