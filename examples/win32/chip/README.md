# chip

A chip-tune synthesiser with a window. Three voices, a resonant filter, and a
player routine that rewrites the registers fifty times a second. It sounds like
a Commodore 64 because it does what a Commodore 64 did, not because it plays
samples of one.

```
  space    pause
  1 2 3    mute a voice
  < >      filter cutoff
  - +      resonance
  f        filter mode: low, band, high
  q / esc  quit, as does closing the window
```

```
  main.exe                       the built-in tune
  main.exe tunes\ode.abc         an ABC tune
  main.exe --selftest            check the arithmetic, play, prove it was
                                 audible, close
  main.exe --ms 8000             close after eight seconds
  main.exe --buffer-ms 0         ask the engine for its smallest ring
  main.exe --stall 120           miss one audio deadline on purpose
  main.exe --freeze 3000         block the WINDOW thread for three seconds
```

This is the port of the MojoCocoa `chip` example, which drives CoreAudio and
draws into an `NSView`.

## What it demonstrates

**The thread boundary, and Mojo on both sides of it.** There are two threads
here and they never wait for each other. One of them is Windows': the message
loop, pumping `WM_PAINT` and `WM_CHAR`, drawing thirty times a second, allowed
to allocate and allowed to fail. The other is the audio thread, whose whole
life is *wake, fill, release*, on a deadline the speaker enforces, where
allocating is a bad idea, taking a lock is a worse one, and raising reports
nothing to anybody — it just leaves the ring empty, which is a hole you can
hear.

Three things cross that boundary, and all three are Mojo functions handed
straight to something that expects a C function pointer:

- `chip_audio_thread` is an `LPTHREAD_START_ROUTINE`, passed to `CreateThread`;
- `chip_wndproc` is a `WNDPROC`, passed to `RegisterClassExW`;
- `chip_fill` is what the stream loop calls on the deadline.

A `def` declared `thin abi("C")` **is** a C function pointer in this dialect,
so none of those is wrapped, generated, thunked, or bridged. There is no C file
in this build.

**"May not raise" is a rule the compiler enforces, not a comment.** A `def`
without `raises` is the non-raising kind. `chip_fill`, `chip_render`,
`player_tick`, the oscillators, the envelope, the filter and the sine are all
declared that way, so the whole audio path is closed under non-raising and the
build fails if anything reaches into code that can throw. That is why
[chip.mojo](chip.mojo) has its own nine-term `_sin` — `std.math.sin` raises,
and on a real-time thread a raise is not a way of reporting anything.

**Nothing Windows-shaped is written by hand.** Every vtable slot, IID,
constant, structure size and DLL name is a query against `windows_api.db`. The
four declared structures assert their own size against the metadata with
`comptime assert`, so a layout that drifts from Windows fails the build rather
than the picture. There is exactly one exception, and it is recorded in
[wasapi.mojo](wasapi.mojo) where it lives: the CLSID of the
`MMDeviceEnumerator` coclass. The metadata holds the coclass *name* but every
guid-kind row in the database has a NULL value, so there are no CLSID *values*
in it at all — the same gap `std.sys.com.co_create` documents and
`ide/screenshot.mojo` already lives with for WIC.

## What to look for

The line under the title is the evidence:

```
WAKE 10.0MS   LOAD 0.4%   PEAK 45%   MISS 0
```

**WAKE** is the measured gap between the device's wakeups. It should sit on the
device period — 10 ms here — and stay there. **LOAD** is the fraction of that
gap spent inside the synthesiser: how close the whole thing is to the edge.
**PEAK** is the endpoint's own meter, read through `IAudioMeterInformation`
off the same `IMMDevice` — the machine's answer to "is sound leaving this
program", independent of anything the program believes about its buffers.
**MISS** counts wakes that found the ring already empty.

That last number matters more than it looks. **An underrun in shared mode is
completely silent.** `GetBuffer`, `ReleaseBuffer` and `Start` all keep
returning `S_OK` while the engine mixes whatever stale samples the ring still
holds. `GetCurrentPadding == 0` is the only reporter you get anywhere in the
API, which is why it is on screen. `--stall 120` misses one deadline by 120 ms
so you can watch MISS go to 1 and hear the hole.

The claim that the two threads are independent is made falsifiable rather than
asserted. `--freeze N` stops the *window* thread dead inside `WM_TIMER`:

```
froze the window thread for 2000 ms: paints 9 -> 9  audio wakes 44 -> 245  underruns 0
```

Nine paints before, nine after; two hundred and one audio wakes in between,
which is two seconds at 10 ms; no underruns. The music does not falter.

The voice rows show what the registers say, not what the tune meant. `WAVE`
reads out the four waveform-select bits as `TSPN`, `NOTE` is the frequency
register turned back into a note name (the chip has no idea what note it is
playing — it has a step size, and going backwards is a logarithm, so
[main.mojo](main.mojo) counts up from C-1 instead), and the bar is the
envelope's actual level. Mute a voice and the wave reads `----`: silence on
this chip is *no waveform selected*, which is what the register means, not a
volume of zero, which the chip does not have per voice.

## What is different from the Mac version, and why

**The render callback does not survive as a callback.** This is the big one.
CoreAudio hands you an `AURenderCallback` and calls it on a real-time thread it
owns. WASAPI inverts that completely: nobody calls you. You are given a ring
buffer and an event, and you *are* the thread — wake, ask how much of the ring
has drained, write exactly that much, sleep again. The deadline is the same
deadline; the ownership of the thread is not.

Pretending otherwise would have been a worse port than admitting it. What
survives is the function pointer: `run_stream` in [wasapi.mojo](wasapi.mojo)
takes a `MonoFill` and calls it from inside the loop body, so `chip_fill` is
still a C-ABI function invoked on the deadline with a chip and a buffer, and
[chip.mojo](chip.mojo) still does not know what an audio API is. The Mac
version's `inRefCon` becomes the thread parameter, which is the same idea with
a different name.

**The sample rate is a register, not a constant.** The Mac version asks
CoreAudio for 48 kHz mono float and gets it. Windows' shared mixer is already
running when the program starts, and its format is a statement rather than a
request: this machine reports 48 kHz, 2 channels, 32-bit IEEE float. So
`chip_new` takes the rate, stores it in `S_RATE`, and every place the Mac
version wrote `SAMPLE_RATE` reads it back. That the answer here happens to be
the 48 kHz the Mac assumed is luck, and assuming it is the bug that only shows
up on somebody else's card.

The chip is mono — a 6581 had one output pin — so `_spread` copies each sample
into every channel. Panning three voices across a stereo field would be
inventing something the machine never did.

**Shared mode, not exclusive.** Exclusive mode would give a lower latency floor
and a format of our own choosing, at the price of evicting everything else on
the endpoint and failing outright when something already holds it — wrong for
an example somebody runs while music is playing. It is also unavailable here:
both `IsFormatSupported` and `Initialize` answer
`AUDCLNT_E_UNSUPPORTED_FORMAT` (0x88890008) for the mix format in exclusive
mode on this machine, so taking that road would mean writing a second, 16-bit
output path as well. `read_mix_format` keeps the 16-bit PCM branch anyway, so
this is not a 48-kHz-float-only program.

**The text is in the framebuffer, and the font is eight bytes a character.**
The Mac version draws with `NSFont` and `drawAtPoint:`. There is no equivalent
here that survives what this window does: the whole screen is a BGRA buffer
that `StretchDIBits` scales to whatever size the window has been dragged to,
and GDI text drawn onto the device context *after* that stretch keeps its own
size and drifts out of the layout the moment anyone resizes. Two coordinate
systems. So [font.mojo](font.mojo) is a character ROM — 8x8, bit 7 leftmost,
codes 32 to 95, upper case only — which is what a machine like this one had at
`$D000` anyway, and which scales by whole pixels so a doubled character has
hard edges rather than a grey fringe.

That also retires the Mac version's second recorded bug. There, building a font
inside `drawRect:` thirty times a second eventually returned nil, and a nil
value in an attributes dictionary raises — surfacing as a trap deep inside
AppKit with a stack that mentions nothing about fonts. There is no font object
here to fail.

**The `let` bug is gone rather than fixed.** The Mac README describes
`let drum_first = i` naming `i`'s storage rather than copying it, so a recorded
index followed the loop, a voice was pointed past the end of the score block,
and `midi_hz` was handed a note of several billion — which is not a wrong pitch
but a hang, on the audio thread, where a hang is silence rather than a crash.
`let` no longer exists in this dialect. The comment survives in
[tune.mojo](tune.mojo) because the clamp `midi_hz` grew in response is still
the right clamp: on a real-time thread, a value that is merely wrong and a
value that hangs are different severities.

**Simplified, and worth saying so.** The Mac version can run two chips at once
in principle and so can this one, but only one is wired up. The window is not
resizable in any interesting way — it stretches, and the 8x8 font stretches
with it, so a large window is a large C64 rather than more information. And
there is no `finally` in the language, so the audio thread is started *last*,
after the window is up and nothing between there and the message loop can
raise; starting it earlier would leave a window in which a raise on the main
thread releases interface pointers the audio thread is still calling through.

## What is in the chip

[chip.mojo](chip.mojo) is a 6581-flavoured synthesiser, not an emulator —
rechip already exists, is cycle-exact, and is thousands of lines of measured
analogue behaviour. This is the arithmetic that gives the 6581 its voice, small
enough to read in one sitting.

The 6581 is integer hardware, so the model is integer arithmetic. The only
floating point is the filter and the final sample.

| Part | What makes it sound right |
| --- | --- |
| Oscillators | 24-bit phase accumulators, stepped in 24.8 fixed point so the pitch is exact |
| Waveforms | triangle, sawtooth, pulse, and the real 23-bit noise LFSR with its actual output taps — which is why the noise rasps instead of hissing |
| Combined | selecting two waveforms ANDs them, as on the chip |
| Envelope | decays by the chip's period-stretching table (÷2 below level 93, then ÷4, ÷8, ÷16, ÷30) rather than an exponential curve |
| Ring mod | one XOR of the previous voice's top bit into this one's triangle |
| Hard sync | the previous voice's wrap resets this accumulator |
| Filter | a two-pole state-variable filter, multimode, with resonance |

The envelope table is the single detail that matters most. Replace it with a
smooth exponential and the thing stops sounding like a C64 and starts sounding
like a synthesiser.

## What is in the player

[tune.mojo](tune.mojo) is the part people forget. The chip has three voices and
no memory; everything that makes a C64 tune sound like one happens in the
routine that ran off the raster interrupt:

- a **chord** is one voice switching between three notes on consecutive frames
  — fast enough to hear as a chord, slow enough to shimmer. The arpeggio is the
  most recognisable sound the machine made.
- a **held note** is kept alive by sweeping the pulse width every frame,
  because a static pulse wave goes lifeless in about half a second
- a **drum** is noise plus a downward pitch sweep, because the chip has no
  percussion

The routine is a thin C-ABI `def` and it is called from inside the fill, on the
beat, exactly where the interrupt would have been.

## ABC tunes

[abc.mojo](abc.mojo) reads ABC notation — headers, accidentals held to the end
of the bar, key signatures including modes, broken rhythm, and `V:` for up to
three voices. An ABC chord `[CEG]` becomes an arpeggio, which is the correct
translation rather than a convenient one.

Repeats are ignored rather than expanded, so a tune plays through once per
loop. Slurs, ties, grace notes and decorations are skipped: they change nothing
a chip can hear.

Everything in that file allocates and every function in it may raise, which is
precisely why none of it is reachable from the audio thread. A tune is parsed
before the stream is started, and only the flat block it produces crosses the
boundary.

## Traps this example stood on

- **A `REFERENCE_TIME` is 100 ns.** Every duration WASAPI takes is in these
  units, and handing `Initialize` milliseconds turns a 200 ms request into 20
  µs — below the device period, failing with a code that says nothing about
  units.
- **`AUDCLNT_STREAMFLAGS_EVENTCALLBACK` and `SetEventHandle` are one
  decision.** The flag without the handle is `AUDCLNT_E_EVENTHANDLE_NOT_SET` at
  `Start`; the handle without the flag is `AUDCLNT_E_EVENTHANDLE_NOT_EXPECTED`
  at `SetEventHandle`.
- **`GetService` must come after `Initialize`.** The render client is a service
  of an *initialised* client, not an interface of the object.
- **Pre-roll before `Start`.** The event is never signalled before the stream
  runs, so the first ring has to be filled by hand; starting on an unfilled
  ring is a guaranteed first-period underrun, which is audible and silent to
  the API.
- **`winkb_struct_size["WAVEFORMATEX"]` is 20 and the SDK's `sizeof` is 18.**
  `mmreg.h` wraps the whole family in `pshpack1` and the metadata records the
  unpacked reading, so `winkb_field_offset` puts `WAVEFORMATEXTENSIBLE`'s
  `SubFormat` at 32 when the real block has it at 24. The first seven
  `WAVEFORMATEX` fields agree either way and are read normally; the sub-format
  is found by counting the packed layout instead. `KSDATAFORMAT_SUBTYPE_*` are
  built by `DEFINE_WAVEFORMATEX_GUID(tag)`, so the GUID's `Data1` **is** the
  `WAVE_FORMAT_*` tag — which is how float is told from PCM with no
  hand-written GUID anywhere.
- **Shutdown has exactly one safe order.** The audio thread is still inside the
  loop calling through the same interface pointers the enclosing scope is about
  to release, so `WM_DESTROY` raises the quit flag, `main` waits on the thread
  handle, and only then does anything get released — render client, client,
  device, enumerator, all before `CoUninitialize`. Releasing first is a
  use-after-free with a stack that mentions nothing but `ole32`.
- **`WM_TIMER` is a request, not a clock.** An unoptimised paint here takes
  about 45 ms against a 33 ms timer, so counting ticks would make `--ms` mean
  something different on every machine. The auto-close reads `GetTickCount64`.
- **Both threads need their own `CoInitializeEx`.** The MTA on both: this
  program registers no OLE drop target, the WASAPI objects are agile, and an
  STA whose messages are never pumped is where cross-apartment calls go to
  hang.
- **`AvSetMmThreadCharacteristicsW("Pro Audio")`** is what tells the scheduler
  this thread has a deadline. It is not checked, because a failure means the
  loop runs at ordinary priority rather than not at all — but the run prints
  which it got.

## Unattended

`--selftest` runs the checks whose answers are exact, then opens the window,
plays for six seconds (or `--ms N`), closes itself, and **fails unless the
endpoint's own peak meter moved**. A run that produced silence cannot pass:

```
chip checks:
  pitch   midi 69 -> 440 Hz -> register -> 'A 4 ': ok
  noise   23-bit LFSR never reaches zero over 4 s: ok
  filter  cutoff 1700 res 5 stays finite and in range for 2 s: ok
  abc     tunes/scale.abc: 'Chromatic Check', 18 events across 18/0/0: ok
  abc     tunes/ode.abc: 'Ode to Joy', 94 events across 62/32/0: ok
```

The filter check is the interesting one. Cutoff 1700 with resonance 5 is the
pair that diverged on the Mac before `recompute_filter` learned that `f` and
`q` are not independent — a Chamberlin state-variable filter is stable only
while `f + q < 2`. The state runs to infinity and then to NaN, which is
*sticky*: every sample after it is NaN too, so the synth goes silent for good
and only a restart brings it back. The output clamp cannot help, because by
then the damage is in the state rather than the sample. So the check is for
samples that are neither out of range nor unequal to themselves.

## Build it

From the repository root:

```
export MODULAR_MOJO_MAX_WINKB_PATH="F:/bzs/external/+http_archive+winkb/windows_api.db"
./bazel-bin/KGEN/tools/mojo/mojo.exe build --no-optimization \
    -I mojo/stdlib -I . -I max/mojo \
    -Xlinker "$(cygpath -w bazel-bin/nvptx/runtime/nvptxrt.lib)" \
    -o build/chip.exe examples/win32/chip/main.mojo
```

The five modules beside `main.mojo` resolve as siblings, so no extra `-I` is
needed for them. Run it with `build/chip.exe`, or from the IDE with
Build > Run Without Debugging.
