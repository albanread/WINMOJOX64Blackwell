# Reference

Look things up here. The guide explains; this states.

| | What it is |
|:---|:---|
| The language | *Not yet written.* The frozen dialect, spelled out: what `comptime` means here, `let` and `var`, `def` and `fn`, origins, and every construct whose spelling differs from what is written elsewhere. |
| The metadata queries | *Not yet written.* `winkb_constant`, `winkb_struct_size`, `winkb_field_offset`, `winkb_function_dll`, `winkb_vtable_index`, `winkb_interface_iid`, and the provenance queries. Each with what it returns and what happens when the name is unknown. |
| [Griddle](03-griddle.md) | Every keyboard shortcut, the whole menu bar, the complete command surface, the environment variables it reads and the files it writes. Generated from the running program. |
| Diagnostics | *Not yet written.* The compiler's Windows-specific messages, what each one really means, and what to do about it. |
| Deviations | *Not yet written.* Every place this fork behaves differently from upstream Mojo, with the reason. |

## Meanwhile

The engineering notes in [docs/](../../docs/) are not user documentation, but
they are true, and several of them answer questions this reference will
eventually answer more kindly:

| Note | What it settles |
|:---|:---|
| [mojo-traps.md](../../docs/mojo-traps.md) | The dialect's sharp edges, each with the fix — including the byte-order mark that stops the compiler and the `with open` that does not close a file. |
| [DIALECT-NOTES.md](../../docs/DIALECT-NOTES.md) | Where the frozen dialect differs from what is written elsewhere. |
| [occlusion.md](../../docs/occlusion.md) | Why a Direct2D window can report complete success and present nothing, and the one command that tells you. |
| [debugger-conditions.md](../../docs/debugger-conditions.md) | Why conditional breakpoints are sent correctly and ignored. |
| [addresses-and-optimization.md](../../docs/addresses-and-optimization.md) | Why `Int(Pointer(to=x))` is correct in a debug build and silently wrong optimised. |
| [event-loop.md](../../docs/event-loop.md) | What a Windows program owes its message queue. |
| [lsp-windows.md](../../docs/lsp-windows.md) | The language server on Windows, and its framing. |
