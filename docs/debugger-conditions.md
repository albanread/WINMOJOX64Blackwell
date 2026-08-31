# Conditional breakpoints are sent and ignored

Griddle sends `condition` with a breakpoint exactly as DAP specifies. The
debugger in this toolchain does not act on it. Written down because the
feature looks broken from the outside and the editor is not the part that is
broken.

## What was measured

`break 9 if <expression>` on `build/dbgme.mojo`, whose line 9 runs four times:

| condition | expected | what happened |
| --- | --- | --- |
| `i == 3` | stops once, on the last iteration | stops on the first, `i` is 0 |
| `1 == 2` | never stops | stops |
| `False` | never stops | stops |

The request going out was logged at the point it is written, so there is no
question of the editor dropping it:

    setBreakpoints {"source":{"path":"...\\dbgme.mojo"},
                    "breakpoints":[{"line":9,"condition":"1 == 2"}]}

That is the shape the protocol asks for, with the line already converted from
Griddle's zero-based counting to DAP's one-based.

## Why

LLDB fails safe: when a breakpoint's condition cannot be evaluated it stops
rather than skipping, on the principle that a breakpoint you were promised is
worth more than one silently discarded. The Mojo expression evaluator in this
build cannot evaluate the conditions, so every one of them fails and every
breakpoint stops.

This is not the same problem as the plugin failing to load. `MojoLLDB.dll`
does load — the transcript shows `plugin load` with no complaint and no
"limited inspection" warning, and locals come back with correct values.
Reading a variable and evaluating an expression are different capabilities and
this build has the first without the second.

`evaluate` on an expression that is just a name works, which is what Ctrl+I
uses; anything with an operator in it does not.

## What Griddle does about it

Keeps sending them, and says so. The field is correct and costs nothing, and
it will start working the day the evaluator does. What must not happen is an
editor implying a condition is in force when it is not, so setting one reports:

    breakpoint set at 9 when i == 3  (this toolchain's debugger ignores
    conditions and will stop every time -- see docs/debugger-conditions.md)

A conditional breakpoint that silently behaves like an unconditional one is
worse than no feature at all: somebody would sit through every iteration
wondering what they had got wrong.

## How to tell when this is fixed

Set one and watch:

```bash
./build/griddle.exe --open build/dbgme.mojo --no-lsp --cmd "break 9 if False;;debug launch;;debug wait 25000"
```

When that reports the debuggee running to the end instead of stopping, the
note in `ide/window.mojo`'s `toggle_breakpoint` and the comment in
`ide/dap.mojo`'s `set_breakpoints` should both come out, and this file with
them.
