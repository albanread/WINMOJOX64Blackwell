# abcplayer — ABC tunes through a chip synth or General MIDI

A folk-tune player: parses ABC notation into an event schedule and plays it
through either the 6581-style chip synth (WASAPI shared mode) or Windows'
General MIDI synth (`midiStreamOut`), and can write Standard MIDI Files.
The window is GDI-drawn — tune list, transport, waveform/envelope/filter
sliders reading the chip's registers live, a scope. Click a tune and Play
(it loops), Add opens a file dialog, space toggles, `z`/`x` shift octave,
`c`/`v` master level, Tab sustains, and the letter keys are a piano
(Logic's Musical Typing layout). `--midi` chooses the synth, `--write=
out.mid` writes a file with no window, `--selftest` runs pitch/timing/
audibility checks headless, `--ms N` auto-closes.

## Run it

```
./examples/win32/build.sh abcplayer
export PATH="bazel-bin/KGEN:bazel-bin/AsyncRT:bazel-bin/Support:$PATH"
./build/abcplayer.exe examples/win32/abcplayer/tunes/galixigans.abc
```

## The walkthrough

**One schedule, two clocks.** The parse (music.mojo, parse.mojo,
repeats.mojo) produces events; `build_schedule` (schedule.mojo:107) gives
each step **both** a sample stamp (for the chip) and a MIDI tick stamp (for
the driver), so the conversion happens once, and the sort puts note-off
before note-on at the same instant. Downstream, `render_scheduled`
(chipplay.mojo:248) renders *between* sample-stamped events — a note
starting at sample 137 starts at 137; the selftest measured worst error
zero samples. The MIDI path packs `MIDIEVENT` buffers whose stride comes
from `winkb_field_offset["MIDIEVENT", "dwParms"]` because the metadata
counts a flexible-array element the SDK doesn't; smf.mojo writes format-1
files with variable-length quantities by hand.

**The audio discipline is the fill callback's.** `abc_fill`
(main.mojo:348) is an `@export` C-ABI function the stream calls: no
`raises`, therefore no allocation, no locks, no I/O on the audio deadline —
state arrives through the `user` pointer. The window thread drains
messages and paints ~90 rectangles into a bitmap at 30 fps; commands are
parsed in the loop, not the window procedure, because parsing can take a
millisecond and the procedure cannot.

**The COM ordering rule is load-bearing here.** The window thread runs in
an STA (it owns a window), the stream is created and the tune loaded
*before* the stream starts — loading with the clock running caused a real
underrun — and at shutdown `speaker.stop()` then `speaker = None` happen
*inside* the Apartment block, per the comment: *a Release after
CoUninitialize is a crash in ole32*.

## The trap, from the README's "worth writing down"

**`ComPtr` owns; addresses do not.** The first version kept the five COM
pointers as plain `Int`s with hand-written AddRefs — and the compiler
destroys a value at its last use, so each owning pointer's last use was the
AddRef's own argument: every object released to zero *before the call that
was meant to keep it alive*, and the first call through any of them was an
access violation inside MMDevAPI.dll naming nothing in this file. Keep
owning types as owning types; the refcounting is the type, not a chore.
