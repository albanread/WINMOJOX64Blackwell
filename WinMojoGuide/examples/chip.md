# chip — a C64 synth in a window, and the WASAPI contract learned properly

A Commodore 64-style chip-tune synthesiser in an 800×500 window: C64-blue
screen, oscilloscope, three voice rows (WAVE / NOTE / ENVELOPE), a filter
readout, and a telemetry line `WAKE … LOAD … PEAK … MISS`. It plays a
built-in tune or an ABC file. `1`/`2`/`3` mute a voice, `<`/`>` sweep the
cutoff, `-`/`+` resonance, `f` cycles the filter mode, space pauses,
`q`/Esc quits. `--selftest`, `--ms N`, `--buffer-ms 0`, `--stall N` and
`--freeze N` exist to break it on purpose.

## Run it

```
./examples/win32/build.sh chip
./bazel-bin/examples/win32/chip.exe            # or: chip.exe tunes\ode.abc
```

## The walkthrough

**The synth is the SID's register file in a flat Mojo block** (chip.mojo):
three voices with 24-bit phase accumulators, a 23-bit noise LFSR, an ADSR
with the 6581's period-stretching decay table (`advance_envelope`,
chip.mojo:408 — ÷2 below 93, then ÷4/÷8/÷16/÷30, the detail that makes it
*sound* like a C64), and a state-variable filter. `chip_render`
(chip.mojo:458) mixes into mono and, every `rate ÷ 50` samples, invokes the
player — *exactly where a raster interrupt would have been*.

**The player teaches what C64 music is**: `player_tick` (tune.mojo:222)
runs at 50 Hz and does nothing but edit registers — arpeggio chords, PWM
sweep on held notes, noise-pitch-sweep drums. Fifty edits a second, not
samples. `abc.mojo` parses ABC notation (key signatures, accidentals,
broken rhythm, `[CEG]` chords, `V:` voices) into the flat score blocks the
player reads; `font.mojo` is an 8×8 character ROM blitted into the
framebuffer.

**The audio architecture is the lesson underneath the music.** The window
thread never touches audio: a second thread (`CreateThread`, its own MTA
apartment, MMCSS "Pro Audio" priority) owns a
`std.windows.audio.RenderStream`, wakes on the engine's event, and fills —
the WASAPI event-driven contract in its honest form: *nobody calls you; you
wake on an event, read the padding, fill exactly the drained frames,
release.* `wasapi.mojo` keeps the raw eight-step open documented as the
library's ancestor, including `read_mix_format` counting a packed layout
because the metadata's struct size disagrees with the SDK's — asserted,
commented, and handled.

## The trap, from the README

**An underrun in shared mode is completely silent.** `GetBuffer`,
`ReleaseBuffer` and `Start` keep returning `S_OK` while the engine mixes
whatever stale samples the ring still holds; `GetCurrentPadding == 0` is
the only reporter anywhere in the API — which is why it is on screen, in
the telemetry line.
