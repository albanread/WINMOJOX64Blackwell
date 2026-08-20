# Language drift: why the Mojo documentation does not match this compiler

Almost every Mojo tutorial, blog post, conference talk and manual chapter written
before this version fails to compile against it. Not in the corners — in the
first five lines of the first example.

This page exists because that cost real time during the port, and because it is
the concrete argument behind [the freeze](../README.md): pinning to one commit is
not stubbornness when the language redefines its own surface syntax this fast.

## What the compiler itself says

These are not inferred. They are the diagnostic strings compiled into
`mojo.exe`, which is the only authority that matters:

| Written in the docs | This compiler | Status |
| --- | --- | --- |
| `fn` | `'fn' has been removed; use 'def' instead` | **removed** |
| `alias` | `'alias' is deprecated; use 'comptime'` | deprecated |
| `@parameter if` | `use 'comptime if'` | deprecated |
| `@parameter for` | `use 'comptime for'` | deprecated |
| `@parameter` | `'@parameter' is deprecated; use '@__parameter'` | deprecated |
| `__del__` | `'__del__' is deprecated; use '__deinit__'` | deprecated |
| `read` | `'read' is deprecated; use 'imm'` | deprecated |
| `__comptime_assert` | `use 'comptime assert'` | deprecated |
| `@register_passable` | `the 'register_passable' function effect is no longer supported` | **removed** |
| `escaping` | `the 'escaping' function effect is no longer supported` | **removed** |
| `where` in a parameter list | `'where' clauses inside parameter lists are no longer supported` | **removed** |

Reproduce the list at any time with:

```bash
grep -rhoE "\"[^\"]{0,90}(has been removed|no longer supported|is deprecated)[^\"]{0,60}\"" --include="*.cpp" KGEN/ | sort -u
```

## The turnover is complete, not aspirational

Counting the standard library's own source — 38 modules of Mojo written by the
people who changed the language:

| Spelling | Occurrences in `mojo/stdlib/std` |
| --- | --- |
| `comptime` | 3,361 |
| `alias` | 51 |
| `@parameter` | 1 |

`comptime` has not been introduced alongside `alias`; it has replaced it. The
remaining 51 are residue. This is what makes old documentation actively
misleading rather than merely dated: the examples are not deprecated-but-working,
they name constructs the compiler rejects outright.

## The two that hurt most

**`fn` is gone.** The `def`/`fn` split — Python-style dynamism beside
systems-style strictness — was the first thing every introduction to Mojo
explained, and one of the clearest reasons the language was interesting. It is
now a hard error.

**`alias` is going.** `alias` appears in essentially every Mojo program ever
published, because compile-time constants are unavoidable. Every one of those
programs now emits a deprecation, and will presumably stop compiling.

Between them, a reader following the official manual writes two lines and hits
two dead constructs.

## What this means for the port

The positive counterpart to this list -- how to write what this compiler
*accepts*, keyed by the error you are looking at -- is
[DIALECT-NOTES.md](DIALECT-NOTES.md).

- **Treat any Mojo example older than this commit as pseudocode.** Read it for
  intent, not syntax.
- **The standard library in this tree is the reference.** It is the largest body
  of Mojo known to compile against this exact compiler. When the docs and
  `mojo/stdlib/std` disagree, the stdlib is right.
- **The compiler's diagnostics are the migration guide.** They name the
  replacement in the error text, which is more than the documentation does.

## Why this justifies the freeze

A port that tracked upstream would be re-learning the language on a schedule set
by someone else, while also porting it. The costs of pinning — no upstream
fixes, no new features — are stated plainly in the README. This is the other
side of that ledger: a fixed language is one that can actually be learned,
documented, and finished.

Whatever else is true of Mojo at version 1.1, code written against it will still
compile against it next month. That is not a claim the upstream language can
currently make.
