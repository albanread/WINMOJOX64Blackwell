"""Everything `std.windows.audio` offers, in one program that makes a noise.

An endpoint, a mix format, a ring, an event, a fill on the deadline and the
device's own meter -- the whole of what the module is for. It is here rather
than in the examples because it is a check rather than a demonstration: if this
plays, the module works on this machine, and if it does not, nothing built on
the module will either.

    ./bazel-bin/KGEN/tools/mojo/mojo.exe build --no-optimization \
        -I mojo/stdlib -I . -o build/audio_smoke.exe spikes/win32/audio_smoke.mojo
    ./build/audio_smoke.exe

It plays a 440 Hz sine at amplitude 0.25 twice: once through the hand-driven
API (`start` / `wait` / `write` / `stop`), which is the shape a program with a
window needs, and once through `run`, which is the shape a program with an
audio thread needs. Both are metered.

The metering is the point, and it is the same lesson as `gui_smoke`'s reading
the pixels back. A stream that was filled but never played looks exactly like
one that worked: every WASAPI call returns S_OK through an underrun, through a
muted session and through a buffer of silence. `IAudioMeterInformation` belongs
to the DEVICE and knows nothing about this program, so it is the only witness
that is not also the defendant. A silent run cannot pass here: if the meter
never moves, this exits non-zero and says so.

`AUDIO_MS=N` plays each phase for N milliseconds (default 600).
`AUDIO_BUFFER_MS=N` asks for a ring of at least N ms (default 60).
`AUDIO_AMPLITUDE=N` asks for an amplitude of N/1000 (default 250).
`AUDIO_SILENT=1` deliberately feeds silence, to prove the check can fail.

Last measured on the T1000 box, asking for 60 ms: 48000 Hz, 2 channels,
float32, ring 2880 frames (60 ms), device period 10000 us, minimum 3000 us.
58 wakes driven by hand and 55 through `run`, 0 underruns either way, mean
wake gap 9886 us against a 10000 us period, fill 13 us -- 1 part per thousand
of the time available for it. Endpoint peak 0.25 against the 0.25 asked for,
in both phases.

The three checks that can fail: `AUDIO_SILENT=1` meters 0.0 and is refused;
the oversize `GetBuffer` is refused with hr -2004287482
(AUDCLNT_E_BUFFER_TOO_LARGE); and the 16-bit fan-out clamps +1.5 to 32767
rather than wrapping it, which is what `Int16(1.5 * 32767.0)` does on its own
(-16386).
"""

from std.math import pi, sin
from std.memory import Pointer, OpaquePointer
from std.memory.alloc import unsafe_alloc
from std.os import getenv
from std.sys.com import Apartment
from std.windows.audio import (
    RenderStats,
    RenderStream,
    default_render_meter,
    fan_out,
)


# ── The state a function pointer can reach ──────────────────────────────────
# A `RenderFill` is captureless, so everything the tone generator needs lives
# in one block of Ints reached through the user pointer -- the audio side's
# equivalent of GWLP_USERDATA. Ints and not Floats because the block is one
# type and integers are what a phase counter wants anyway.

comptime S_RATE = 0  # frames per second, from the engine
comptime S_PHASE = 1  # frames produced so far
comptime S_TARGET = 2  # frames to produce before `keep_going` says no
comptime S_AMP = 3  # amplitude x 1000
comptime S_HZ = 4  # tone frequency
comptime S_PEAK = 5  # loudest sample this program produced, x 10000
comptime S_SLOTS = 6


@always_inline
fn slot(user: OpaquePointer[MutUntrackedOrigin], i: Int) -> Int:
    return user.unsafe_bitcast[Int]()[unsafe_offset=i]


@always_inline
fn put(user: OpaquePointer[MutUntrackedOrigin], i: Int, v: Int):
    user.unsafe_bitcast[Int]()[unsafe_offset=i] = v


@export("audio_smoke_fill")
def audio_smoke_fill(
    user: OpaquePointer[MutUntrackedOrigin],
    dest: Pointer[Float32, MutUntrackedOrigin],
    frames: Int,
) abi("C") -> NoneType:
    """A sine, produced on the deadline.

    This is the whole of what a caller supplies. It allocates nothing, locks
    nothing, calls nothing that can block, and cannot raise -- the signature
    says so and the compiler agrees.

    It also records the loudest sample it produced, which is a DIFFERENT claim
    from the endpoint's meter: that one hears the whole machine, so a run that
    made no sound at all can still meter whatever else is playing. Both numbers
    together are the honest evidence.
    """
    var rate = slot(user, S_RATE)
    var amp = Float64(slot(user, S_AMP)) / 1000.0
    var hz = Float64(slot(user, S_HZ))
    var phase = slot(user, S_PHASE)
    var peak = slot(user, S_PEAK)
    var step = 2.0 * pi * hz / Float64(rate)
    for i in range(frames):
        var v = amp * Float64(sin(step * Float64(phase + i)))
        dest[unsafe_offset=i] = Float32(v)
        var mag = Int((v if v >= 0.0 else -v) * 10000.0)
        if mag > peak:
            peak = mag
    put(user, S_PHASE, phase + frames)
    put(user, S_PEAK, peak)
    return None


@export("audio_smoke_running")
def audio_smoke_running(
    user: OpaquePointer[MutUntrackedOrigin],
) abi("C") -> Bool:
    """Asked once per wake by `run`. It answers from memory and nothing else."""
    return slot(user, S_PHASE) < slot(user, S_TARGET)


def report(name: String, asked: Float64, produced: Float64, metered: Float64) -> Int:
    """Print one phase's evidence and say whether it counts as a failure."""
    print(
        "  ",
        name,
        " asked",
        asked,
        " produced",
        produced,
        " endpoint metered",
        metered,
    )
    if metered <= 0.0:
        print("   FAIL:", name, "-- the endpoint's meter never moved")
        return 1
    if produced <= 0.0:
        print("   FAIL:", name, "-- nothing was produced to play")
        return 1
    print("   AUDIBLE:", name)
    return 0


def pcm16_clamp_check() -> Int:
    """The 16-bit path, checked without a 16-bit endpoint.

    The mix format here is float32, so `write`'s PCM branch never runs on this
    machine -- which is exactly how both hand-written copies kept an unclamped
    conversion for as long as they did. Calling `fan_out` directly exercises
    it: a sample of +1.5 must come out as +32767 and not as the large negative
    number an unclamped truncation produces.
    """
    var mono = unsafe_alloc[Float32](3, alignment=64)
    mono[unsafe_offset=0] = Float32(1.5)
    mono[unsafe_offset=1] = Float32(-1.5)
    mono[unsafe_offset=2] = Float32(0.5)
    var out = unsafe_alloc[Int16](6, alignment=64)
    for i in range(6):
        out[unsafe_offset=i] = Int16(0)
    fan_out(mono, Int(out), 3, 2, False)
    var hi = Int(out[unsafe_offset=0])
    var lo = Int(out[unsafe_offset=2])
    var mid = Int(out[unsafe_offset=4])
    var interleaved = Int(out[unsafe_offset=1])
    print(
        "  16-bit fan-out: +1.5 ->",
        hi,
        " -1.5 ->",
        lo,
        " +0.5 ->",
        mid,
        " second channel ->",
        interleaved,
    )
    var bad = 0
    if hi != 32767:
        print("   FAIL: +1.5 clamped to", hi, "and not 32767")
        bad += 1
    if lo != -32767:
        print("   FAIL: -1.5 clamped to", lo, "and not -32767")
        bad += 1
    if mid != 16383:
        print("   FAIL: +0.5 became", mid, "and not 16383")
        bad += 1
    if interleaved != hi:
        print("   FAIL: the second channel got", interleaved, "and not", hi)
        bad += 1
    if bad == 0:
        print("   CLAMPED: an overshooting sample clips instead of wrapping")
    mono.unsafe_free()
    out.unsafe_free()
    return bad


def main() raises:
    var ms = 600
    var door = getenv("AUDIO_MS")
    if door != "":
        ms = Int(door)
    var amplitude = 250
    var amp_door = getenv("AUDIO_AMPLITUDE")
    if amp_door != "":
        amplitude = Int(amp_door)
    var silent = getenv("AUDIO_SILENT") == "1"
    if silent:
        # The negative control. Everything else is identical, every call still
        # returns S_OK, and this run must NOT pass.
        amplitude = 0

    var buffer_ms = 60
    var buf_door = getenv("AUDIO_BUFFER_MS")
    if buf_door != "":
        buffer_ms = Int(buf_door)

    var failures = 0
    failures += pcm16_clamp_check()

    # The MTA, deliberately. This thread owns no window and pumps no messages,
    # and an STA whose messages are never pumped is where cross-apartment calls
    # go to hang. WASAPI's objects are in-process and thread-agile.
    with Apartment(multithreaded=True):
        var speaker = RenderStream(buffer_ms=buffer_ms)
        print(speaker.describe())
        print(
            "device period",
            speaker.default_period_us,
            "us  minimum",
            speaker.minimum_period_us,
            "us",
        )

        var state = unsafe_alloc[Int](S_SLOTS, alignment=64)
        var user = OpaquePointer[MutUntrackedOrigin](
            unsafe_from_address=Int(state)
        )
        for i in range(S_SLOTS):
            state[unsafe_offset=i] = 0
        put(user, S_RATE, speaker.format.rate)
        put(user, S_AMP, amplitude)
        put(user, S_HZ, 440)
        put(user, S_TARGET, speaker.format.rate * ms // 1000)

        var fill = audio_smoke_fill
        var going = audio_smoke_running

        # ── Phase 1: the hand-driven loop ───────────────────────────────────
        # `start` / `wait` / `write` / `stop`, which is what a program with a
        # window does around its own message pump.
        speaker.start(fill, user)

        # A failure, on purpose. The ring is full immediately after the
        # pre-roll, so asking `begin` for one frame more than exists must be
        # refused with AUDCLNT_E_BUFFER_TOO_LARGE -- which is the crash the
        # abcplayer copy hit when it restarted a stopped stream without a
        # Reset. It also proves a failed HRESULT reaches Mojo as an exception:
        # every COM call in the module is written `_ = ac.Something(...)`, and
        # the discarded value is the SUCCESSFUL result, not the error.
        var refused = False
        try:
            _ = speaker.begin(speaker.frames + 1)
        except e:
            refused = True
            print("  oversize GetBuffer refused, as it must be:", e)
        if not refused:
            print("   FAIL: GetBuffer accepted more frames than the ring holds")
            failures += 1

        var silent_frames = 0
        var reported_latency = -1
        while slot(user, S_PHASE) < slot(user, S_TARGET):
            if not speaker.wait(speaker.wake_timeout_ms()):
                print("   FAIL: the audio event never arrived, status", speaker.wait_status)
                failures += 1
                break
            _ = speaker.poll_meter()
            if reported_latency < 0:
                reported_latency = speaker.latency_us()
            if speaker.stats.wakes >= 10 and speaker.stats.wakes < 14:
                # Exercise the AUDCLNT_BUFFERFLAGS_SILENT path for a few wakes.
                # The engine skips the memory entirely rather than reading
                # zeros somebody wrote, and the stream must not starve for it.
                silent_frames += speaker.write_silence()
            else:
                _ = speaker.write(fill, user)
        speaker.drain()
        speaker.stop()
        print(
            "  latency at the first wake",
            reported_latency,
            "us   meter channels",
            speaker.meter.channel_count(),
            "  silent frames via BUFFERFLAGS_SILENT",
            silent_frames,
        )
        if silent_frames <= 0:
            print("   FAIL: the silent-buffer path was never exercised")
            failures += 1

        var phase1_peak = Float64(slot(user, S_PEAK)) / 10000.0
        var phase1_metered = speaker.meter_peak
        print(
            "  driven by hand: wakes",
            speaker.stats.wakes,
            " underruns",
            speaker.stats.underruns,
            " frames",
            speaker.stats.frames,
            " gap",
            speaker.stats.gap_us,
            "us (max",
            speaker.stats.gap_max_us,
            "us)  fill",
            speaker.stats.fill_us,
            "us =",
            speaker.stats.load_permille,
            "permille",
        )
        failures += report(
            String("hand-driven"),
            Float64(amplitude) / 1000.0,
            phase1_peak,
            phase1_metered,
        )

        # ── Phase 2: the whole loop, from the module ────────────────────────
        # Discard the tail of phase 1 and start again, this time letting `run`
        # own the loop -- which is what a program with an audio thread does.
        speaker.reset()
        speaker.meter_peak = 0.0
        speaker.stats = RenderStats()
        put(user, S_PEAK, 0)
        put(user, S_PHASE, 0)
        speaker.run(fill, going, user)

        var phase2_peak = Float64(slot(user, S_PEAK)) / 10000.0
        print(
            "  run(): wakes",
            speaker.stats.wakes,
            " underruns",
            speaker.stats.underruns,
            " frames",
            speaker.stats.frames,
            " gap",
            speaker.stats.gap_us,
            "us (max",
            speaker.stats.gap_max_us,
            "us)  MMCSS",
            "Pro Audio" if speaker.mmcss_granted else "declined",
        )
        print(
            "  mean wake gap",
            speaker.stats.mean_gap_us(),
            "us over",
            speaker.stats.wakes,
            "wakes, against a device period of",
            speaker.default_period_us,
            "us",
        )
        failures += report(
            String("run()"),
            Float64(amplitude) / 1000.0,
            phase2_peak,
            speaker.meter_peak,
        )

        # The meter-only door, for a program whose sound leaves by another road
        # (the system MIDI synthesiser) and still wants the machine's answer.
        var lone = default_render_meter()
        print("  meter-only endpoint opens:", lone.channel_count(), "channels")

        state.unsafe_free()
        _ = lone^
        # `speaker` owns five COM pointers and must die inside this block: a
        # Release after CoUninitialize is a crash in ole32 with no stack.
        _ = speaker^

    if silent:
        # Inverted: with no signal the meter must NOT have found ours. If this
        # run "passed", the check is worthless and that is the real failure.
        if failures == 0:
            print("FAIL: a silent run passed; the meter check proves nothing")
            raise Error("audio_smoke: the silence control passed")
        print("silence control behaved: the check refused a run that made no sound")
        return

    if failures != 0:
        raise Error("audio_smoke: " + String(failures) + " failure(s)")
    print("audio_smoke: the device heard it.")
