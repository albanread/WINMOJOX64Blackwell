# comptr — ComPtr's ownership, asserted against a live object

Seventy-four lines that refuse to take the ownership table on faith: it
creates a real COM object (`CreateStreamOnHGlobal`), reads its refcount
through a balanced `AddRef`/`Release` pair, and prints the count after
every transition the type claims to make.

## Run it

```
mojo run main.mojo
```

## What the output proves

```
after adopt: 1        <- adopt= takes the callee's reference without adding
after copy:  2        <- copying AddRefs
after move:  2        <- value^ transfers without any traffic
after QI:    3        <- query_interface arrives pre-counted and is adopted
QI non-null: True
unrelated QI raises: True     <- an interface the object lacks raises E_NOINTERFACE
after drops: 1        <- every binding released exactly what it took
```

`probe_count` (main.mojo:16) is the instrument worth stealing: to read a
refcount without perturbing it, `com_method_of` the `AddRef`/`Release`
slots, call both, and report the value `AddRef` returned.

## What it teaches

[The COM reference's](../reference/05-com.md) ownership table, row by row,
against ole32's actual objects — including the two behaviours people get
wrong: that `adopt=` must *not* AddRef (the callee already counted), and
that a move (`^`) is genuinely free because `deinit move` consumes the
source without running its destructor. The IID in every call is inferred
from the type parameter; no GUID appears anywhere in the file.
