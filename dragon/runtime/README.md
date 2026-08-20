# `dragon/runtime/` — the device runtime

Where GAP 2 gets filled: an implementation of the `AsyncRT_DeviceContext_*` C
ABI backed by Adreno, so Mojo kernels have something to run on.

| File | What |
|---|---|
| `extract_abi.py` | Derives the ABI spec from Modular's own bindings |
| `ABI.md` | **Generated.** Do not hand-edit — rerun the extractor |

## Regenerating

```bash
python dragon/runtime/extract_abi.py
```

`--check` exits non-zero if `ABI.md` is stale. Run the extractor after every
rebase onto `winmojo`/`upstream` and read the diff: it is the early warning
that Modular changed the interface underneath us. A silent drift here would
show up much later as a wrong-arguments crash.

## Why generate rather than write

The ABI is unpublished, but it is fully *declared* — `max/mojo/max/gpu/host/*.mojo`
names every symbol it calls, and 94 of the 109 declarations carry the real C
prototype in a comment. Transcribing that by hand would be 109 chances to
introduce an error that only surfaces at runtime in a foreign process. The
generator is auditable and re-runnable; a transcription is neither.

The hand-authored parts are the *judgements*: the tier classification and the
bring-up subset. Both live at the top of `extract_abi.py`, and the bring-up
list is checked against reality on every run, so a symbol that gets renamed
upstream is reported rather than silently dropped.
