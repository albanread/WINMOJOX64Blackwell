"""Sound out of Windows: one WASAPI render stream, opened, described, fed.

`std.windows.gui` is the part where a program has a window. This is the part
where it makes a noise.

It exists because two of the shipped examples had each written it out again --
`examples/win32/chip/wasapi.mojo` at 522 lines and
`examples/win32/abcplayer/wasapi.mojo` at 456 -- independently, from the same
documentation, to do the same job. Where two independent copies of a thing
disagree, one of them is wrong, and they disagreed in four places:

- `chip` drains the ring before `Stop` and `abcplayer` does not, so
  `abcplayer` truncates up to a whole ring of audio it had already written and
  been told was accepted. `chip` is right; that is `drain`.

- `abcplayer` has `Reset` and `chip` has none. Without it, restarting a
  stopped stream asks `GetBuffer` for a ring that is still occupied and gets
  `AUDCLNT_E_BUFFER_TOO_LARGE` -- hr -2004287482, reproduced deliberately in
  `spikes/win32/audio_smoke.mojo`. `abcplayer` is right; `reset` is here, and
  `start` additionally fills only the FREE space so the mistake is not
  available.

- NEITHER clamped before converting to 16-bit PCM, and this dialect's
  float-to-Int16 conversion wraps rather than saturates. Measured:
  `Int16(1.0001 * 32767.0)` is -32766. A sample one part in ten thousand over
  full scale becomes full-scale NEGATIVE -- not a clip, an inverted crack,
  louder than the signal that caused it. `fan_out` clamps.

- Both decoded the endpoint's own name with a hand-rolled `chr()` loop capped
  at 256 code units, which mangles anything outside the BMP, instead of the
  `WideCharToMultiByte` boundary `std.windows.core` already owns. `Endpoint.id`
  uses `from_wide`.

WHAT IS NOT NEGOTIABLE, because it was measured on this machine rather than
read somewhere:

- Shared mode, not exclusive. The mix format is refused outright in exclusive
  mode here -- `AUDCLNT_E_UNSUPPORTED_FORMAT` from both `IsFormatSupported`
  and `Initialize` -- so exclusive would mean negotiating a hardware format
  and writing a second output path for it. It also evicts every other
  application on the endpoint, which is wrong for an example somebody runs
  while music is playing.

- Event-driven, never polled. `CreateEventW` -> `SetEventHandle` ->
  `WaitForSingleObject`, measured at a 9.993 ms mean wake gap over 200 wakes
  with no zero-padding, against 13.998 ms and worse for `Sleep(1)` polling.

- The mix format is read, not assumed. It is 48 kHz, 2 channels, 32-bit IEEE
  float, `WAVE_FORMAT_EXTENSIBLE` here; 16-bit PCM is supported as well
  because the next machine is not this one.

THE REAL-TIME CONTRACT. WASAPI is not CoreAudio. Nobody calls you: you are
given a ring buffer and an event, and you ARE the thread -- wake, ask how much
of the ring has drained, write exactly that much, sleep again. So the render
callback does not survive as a callback. What survives is the function
pointer. `RenderFill` is a thin C-ABI `def`, which in this dialect IS a C
function pointer, and `write` calls it from inside the deadline. Everything it
is handed was allocated before `start`; there is no allocation, no lock, no
I/O and no entry-point lookup on the deadline -- `QueryPerformanceCounter` and
`WaitForSingleObject` are resolved once, at open, and held as fields. `RenderFill`
is declared without `raises` and the compiler holds it to that, which is the
whole point: the arithmetic that produces samples may not raise, while the
stream around it may, because a device that has been unplugged is worth
reporting rather than writing into.

WHAT THIS IS NOT. It is not a mixer, a resampler, a synthesiser or an audio
graph. It does not convert sample rates: in shared mode the engine's rate is a
statement, not a request, and a caller whose oscillator runs at 44100 on a
48000 endpoint will play sharp -- ask `format.rate` and deal with it. The only
conversion here is the one every caller needed anyway: one mono voice fanned
out to however many channels the mixer wants, in whichever of the two sample
formats it is running.

Everything below is a query against `windows_api.db`. There is exactly one
hand-written Windows value in this file, `CLSID_MMDeviceEnumerator`, and the
comment above it records why.

Every COM call here is written `_ = client.Something(...)`, and the discarded
value is the SUCCESSFUL `HResult`: `std.sys.com` raises inside the call on a
failed one. The `_ =` is not a swallowed error and must not be "fixed" into
one.

    from std.windows.audio import RenderStream

    @export("my_fill")
    def my_fill(
        user: OpaquePointer[MutUntrackedOrigin],
        dest: Pointer[Float32, MutUntrackedOrigin],
        frames: Int,
    ) abi("C") -> NoneType:
        for i in range(frames):
            dest[unsafe_offset=i] = Float32(0.0)
        return None

    def main() raises:
        with Apartment(multithreaded=True):
            var speaker = RenderStream(buffer_ms=60)
            print(speaker.describe())
            var fill = my_fill
            var going = keep_going
            speaker.run(fill, going, state)
            print("the endpoint metered", speaker.meter_peak)
            _ = speaker^   # before the apartment closes; see the lifetime note
"""

from std.ffi import c_int
from std.memory import Pointer, OpaquePointer
from std.memory.alloc import unsafe_alloc
from std.sys._com import ComPtr, com_addr, _guid_bytes
from std.sys._win32 import Win32Module
from std.sys._winkb import (
    winkb_constant,
    winkb_field_offset,
    winkb_function_dll,
    winkb_interface_iid,
    winkb_struct_size,
)
from std.sys.com import Com, co_create
from std.windows.core import WideString, from_wide, win32


# ===----------------------------------------------------------------------===#
# The one hand-written value in this file
# ===----------------------------------------------------------------------===#

comptime CLSID_MMDeviceEnumerator = StaticString(
    "bcde0395-e52f-467c-8e3d-c4579291692e"
)
"""The MMDeviceEnumerator coclass, written out because the metadata cannot say.

The database holds the NAME -- `Windows.Win32.Media.Audio.MMDeviceEnumerator`
is a row in `types` -- but not the value. Every guid-kind row in `constants` has
a NULL `value_text`: 5837 of them, and 0 with a value, coclass CLSIDs included.
That is the recorded gap `std.sys.com.co_create` documents, and the remedy it
prescribes is to write the CLSID once, next to the name it belongs to, and
nowhere else. This is that one place for audio -- it was written out twice
before, once per example, and is now written out once for the whole port.

If a later `windows_api.db` starts carrying CLSID values, this comptime and its
`co_create` call are the only two lines that have to change.
"""


# ===----------------------------------------------------------------------===#
# Everything else, from the metadata
# ===----------------------------------------------------------------------===#

comptime DATAFLOW_RENDER = Int32(winkb_constant["eRender"]())
"""`EDataFlow` for an endpoint that plays: speakers rather than a microphone."""

comptime ROLE_CONSOLE = Int32(winkb_constant["eConsole"]())
"""`ERole` for the device the user thinks of as "the speakers"."""

comptime ROLE_MULTIMEDIA = Int32(winkb_constant["eMultimedia"]())
"""`ERole` for the device chosen for music and film, where that differs."""

comptime ROLE_COMMUNICATIONS = Int32(winkb_constant["eCommunications"]())
"""`ERole` for the device chosen for voice calls, usually a headset."""

comptime _CLSCTX_ALL = UInt32(winkb_constant["CLSCTX_ALL"]())
comptime _SHAREMODE_SHARED = Int32(winkb_constant["AUDCLNT_SHAREMODE_SHARED"]())
comptime _STREAMFLAGS_EVENTCALLBACK = UInt32(
    winkb_constant["AUDCLNT_STREAMFLAGS_EVENTCALLBACK"]()
)
comptime _BUFFERFLAGS_SILENT = UInt32(
    winkb_constant["AUDCLNT_BUFFERFLAGS_SILENT"]()
)
comptime _WAVE_FORMAT_PCM = winkb_constant["WAVE_FORMAT_PCM"]()
comptime _WAVE_FORMAT_IEEE_FLOAT = winkb_constant["WAVE_FORMAT_IEEE_FLOAT"]()
comptime _WAVE_FORMAT_EXTENSIBLE = winkb_constant["WAVE_FORMAT_EXTENSIBLE"]()
comptime _WAIT_OBJECT_0 = UInt32(winkb_constant["WAIT_OBJECT_0"]())

comptime REFTIMES_PER_MS = 10_000
"""Hundred-nanosecond units in a millisecond: a `REFERENCE_TIME`.

Every duration WASAPI takes or returns is in these. The mistake that costs an
afternoon is handing `Initialize` milliseconds -- 200 becomes twenty
microseconds, which is below the device period, and the call fails with a code
that says nothing about units.
"""


# ===----------------------------------------------------------------------===#
# The format the engine is already running at
# ===----------------------------------------------------------------------===#


@fieldwise_init
struct AudioFormat(Copyable, Movable):
    """What the shared mixer is running at, read from the engine.

    In shared mode this is not a request, it is a statement: the engine has
    been running at this rate and this width since before the program started,
    and everything a synthesiser produces has to arrive in it. Nothing here is
    negotiable and nothing here is a default.
    """

    var rate: Int
    """Frames per second -- 48000 on the machine this was written on."""

    var channels: Int
    """Interleaved channels per frame."""

    var bits: Int
    """Bits per sample: 32 for float, 16 for PCM."""

    var tag: Int
    """`wFormatTag`, usually `WAVE_FORMAT_EXTENSIBLE`."""

    var subformat_tag: Int
    """`Data1` of the `SubFormat` GUID, which IS the real `WAVE_FORMAT_` tag."""

    var block_align: Int
    """Bytes per frame, as the engine reported it, not as we computed it."""

    var is_float: Bool
    """True for 32-bit IEEE float; False for 16-bit PCM. There is no third."""

    def bytes_per_frame(self) -> Int:
        """Bytes one frame of every channel occupies in the ring.

        Returns:
            The engine's `nBlockAlign`.
        """
        return self.block_align

    def describe(self) -> String:
        """One line naming the format.

        Returns:
            Rate, channels and sample format.
        """
        return (
            String(self.rate)
            + " Hz, "
            + String(self.channels)
            + " ch, "
            + (String("float32") if self.is_float else String("int16"))
        )


@always_inline
fn _u16(p: Pointer[UInt8, MutUntrackedOrigin], at: Int) -> Int:
    """One little-endian u16, a byte at a time and with no alignment claim."""
    return Int(
        UInt32(p[unsafe_offset=at]) | (UInt32(p[unsafe_offset = at + 1]) << 8)
    )


@always_inline
fn _u32(p: Pointer[UInt8, MutUntrackedOrigin], at: Int) -> Int:
    """One little-endian u32, a byte at a time and with no alignment claim."""
    return Int(
        UInt32(p[unsafe_offset=at])
        | (UInt32(p[unsafe_offset = at + 1]) << 8)
        | (UInt32(p[unsafe_offset = at + 2]) << 16)
        | (UInt32(p[unsafe_offset = at + 3]) << 24)
    )


def read_wave_format(address: Int) raises -> AudioFormat:
    """Read a `WAVEFORMATEX`/`WAVEFORMATEXTENSIBLE` block the engine handed back.

    The first seven fields come from `winkb_field_offset`, because for those
    the metadata and the SDK agree. `SubFormat` does not, and this is the one
    place in the Windows surface where the metadata's offsets must be refused:

    `winkb_struct_size["WAVEFORMATEX"]` is 20 where the SDK's `sizeof` is 18,
    because `mmreg.h` wraps the whole family in `pshpack1` and the metadata
    records the unpacked reading. Those two bytes move every field of
    `WAVEFORMATEXTENSIBLE` after the header: the metadata says `SubFormat` is at
    32, and the packed truth is 24. Both numbers are asserted below, so if a
    later database is fixed the build fails here and somebody reads this
    paragraph instead of debugging silence.

    Telling float from PCM needs no hand-written GUID. `KSDATAFORMAT_SUBTYPE_PCM`
    and `_IEEE_FLOAT` are built by `DEFINE_WAVEFORMATEX_GUID(tag)`, so the
    GUID's `Data1` IS the `WAVE_FORMAT_` tag -- read that one u32 and compare it
    against the constants the metadata already has.

    Args:
        address: The block, as `GetMixFormat` returned it.

    Returns:
        The format, with float-versus-PCM already decided.

    Raises:
        If the block is null, malformed, or in a format this module cannot
        write -- anything that is neither 32-bit float nor 16-bit PCM.
    """
    comptime assert (
        winkb_struct_size["WAVEFORMATEX"]() == 20
    ), "WAVEFORMATEX is no longer the unpacked 20 bytes this reader compensates for"
    comptime assert (
        winkb_field_offset["WAVEFORMATEXTENSIBLE", "SubFormat"]() == 32
    ), "WAVEFORMATEXTENSIBLE.SubFormat offset changed; re-derive the packed one"
    comptime assert (
        winkb_field_offset["WAVEFORMATEX", "cbSize"]() == 16
    ), "WAVEFORMATEX header layout changed; the packed prefix is no longer 18 bytes"

    if address == 0:
        raise Error("GetMixFormat returned S_OK and a null format")

    var p = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=address
    ).unsafe_bitcast[UInt8]()

    var tag = _u16(p, winkb_field_offset["WAVEFORMATEX", "wFormatTag"]())
    var channels = _u16(p, winkb_field_offset["WAVEFORMATEX", "nChannels"]())
    var rate = _u32(p, winkb_field_offset["WAVEFORMATEX", "nSamplesPerSec"]())
    var block_align = _u16(
        p, winkb_field_offset["WAVEFORMATEX", "nBlockAlign"]()
    )
    var bits = _u16(p, winkb_field_offset["WAVEFORMATEX", "wBitsPerSample"]())
    var cb_size = _u16(p, winkb_field_offset["WAVEFORMATEX", "cbSize"]())

    # 24, counted from the packed layout: Format 0..17, Samples 18,
    # dwChannelMask 20, SubFormat 24.
    var subformat_tag = 0
    if tag == _WAVE_FORMAT_EXTENSIBLE and cb_size >= 22:
        subformat_tag = _u32(p, 24)

    var is_float = tag == _WAVE_FORMAT_IEEE_FLOAT or (
        tag == _WAVE_FORMAT_EXTENSIBLE
        and subformat_tag == _WAVE_FORMAT_IEEE_FLOAT
    )
    var is_pcm16 = (
        tag == _WAVE_FORMAT_PCM
        or (tag == _WAVE_FORMAT_EXTENSIBLE and subformat_tag == _WAVE_FORMAT_PCM)
    ) and bits == 16
    if not is_float and not is_pcm16:
        raise Error(
            "unhandled mix format: tag "
            + String(tag)
            + ", subformat tag "
            + String(subformat_tag)
            + ", "
            + String(bits)
            + " bits -- this module writes 32-bit float and 16-bit PCM only"
        )
    if channels < 1 or rate < 1:
        raise Error(
            "nonsense mix format: "
            + String(channels)
            + " channels at "
            + String(rate)
            + " Hz"
        )

    # A cross-check the offsets cannot fake. If the header were being read at
    # the wrong offsets, three unrelated fields would have to be wrong in
    # exactly the way that keeps this identity true.
    if block_align != channels * (bits // 8):
        raise Error(
            "WAVEFORMATEX is inconsistent: nBlockAlign "
            + String(block_align)
            + " but "
            + String(channels)
            + " channels of "
            + String(bits)
            + " bits needs "
            + String(channels * (bits // 8))
            + " -- the header was probably read at the wrong offsets"
        )

    return AudioFormat(
        rate, channels, bits, tag, subformat_tag, block_align, is_float
    )


# ===----------------------------------------------------------------------===#
# The endpoint
# ===----------------------------------------------------------------------===#


struct Endpoint(Movable):
    """A default audio endpoint, and the enumerator that named it.

    Both are held as `ComPtr`s and not as raw addresses, and that is not
    taste. An earlier hand-written version of this kept addresses and AddRef'd
    them by hand on the way out; the compiler destroyed each owning pointer at
    its last use -- which was the AddRef's own argument -- so every object was
    released to zero before the function returned, and the first call through
    any of them was an access violation inside MMDevAPI. Letting the type own
    them means the release happens exactly when this value dies.

    COM must already be initialised on the calling thread.
    """

    var enumerator: ComPtr[StaticString("IMMDeviceEnumerator")]
    """The device enumerator this endpoint came from."""

    var device: ComPtr[StaticString("IMMDevice")]
    """The endpoint itself."""

    def __init__(
        out self, *, capture: Bool = False, role: Int32 = ROLE_CONSOLE
    ) raises:
        """Open the default endpoint for a data flow and a role.

        Args:
            capture: True for a microphone; the default is the speakers.
            role: `ROLE_CONSOLE`, `ROLE_MULTIMEDIA` or `ROLE_COMMUNICATIONS`.

        Raises:
            If COM is not initialised on this thread, the audio service is not
            running, or there is no endpoint for that flow and role.
        """
        self.enumerator = co_create[
            CLSID_MMDeviceEnumerator, "IMMDeviceEnumerator"
        ]()
        var device_address: Int = 0
        _ = Com[StaticString("IMMDeviceEnumerator")](
            of=self.enumerator
        ).GetDefaultAudioEndpoint(
            Int32(1) if capture else DATAFLOW_RENDER,
            role,
            com_addr(device_address),
        )
        if device_address == 0:
            raise Error(
                "GetDefaultAudioEndpoint returned S_OK and a null device"
            )
        self.device = ComPtr[StaticString("IMMDevice")](adopt=device_address)

    def activate[iface: StaticString](self) raises -> ComPtr[iface]:
        """COM's other activation verb, applied to this endpoint.

        Not "make me an instance of this class" but "give me this interface,
        implemented for this device". The IID comes from the metadata; the
        activation-parameters pointer is null.

        Parameters:
            iface: The interface to ask for, e.g. "IAudioClient".

        Returns:
            An owning pointer to the requested interface.

        Raises:
            If the endpoint does not implement it, or the audio service is
            unavailable.
        """
        var iid = _guid_bytes(winkb_interface_iid[iface]())
        var out_address: Int = 0
        _ = Com[StaticString("IMMDevice")](of=self.device).Activate(
            iid.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            _CLSCTX_ALL,
            Int(0),
            com_addr(out_address),
        )
        _ = iid
        if out_address == 0:
            raise Error("IMMDevice::Activate returned S_OK and a null pointer")
        return ComPtr[iface](adopt=out_address)

    def id(self) raises -> String:
        """The endpoint's identifier string, so a run names what it played into.

        Decoded with `from_wide`, not with a `chr()` loop: an endpoint id is
        ASCII in practice but a device name is not, and this library already
        owns the UTF-16 boundary.

        Returns:
            The endpoint id, or the empty string if the device would not say.

        Raises:
            If `GetId` fails or the text cannot be decoded.
        """
        var id_address: Int = 0
        _ = Com[StaticString("IMMDevice")](of=self.device).GetId(
            com_addr(id_address)
        )
        if id_address == 0:
            return String("")
        var text = from_wide(
            Pointer[UInt16, MutAnyOrigin](unsafe_from_address=id_address)
        )
        _ = win32[def (Int) thin abi("C") -> NoneType, "CoTaskMemFree"]()(
            id_address
        )
        return text^

    def meter(self) raises -> Meter:
        """This endpoint's own peak meter.

        Returns:
            A meter reading the whole endpoint, not just this program.

        Raises:
            If the endpoint does not offer `IAudioMeterInformation`.
        """
        return Meter(self.activate["IAudioMeterInformation"]())


struct Meter(Movable):
    """The endpoint's peak meter: what the DEVICE heard, not what we wrote.

    This is the only instrument in the module that is independent of the
    module. Every WASAPI call can return S_OK through an underrun, through a
    muted session and through a program that filled its buffers with zeros --
    the meter cannot. It is also the whole endpoint, so it hears other
    programs too: a non-zero reading proves sound is happening, and only a
    reading that tracks what the caller asked for proves it is ours.
    """

    var meter: ComPtr[StaticString("IAudioMeterInformation")]
    """The interface; ownership is this value's."""

    def __init__(
        out self, var meter: ComPtr[StaticString("IAudioMeterInformation")]
    ):
        """Take ownership of a meter interface.

        Args:
            meter: The interface, usually from `Endpoint.meter`.
        """
        self.meter = meter^

    def peak(self) raises -> Float64:
        """The loudest sample the endpoint has seen since the last call.

        Returns:
            A peak between 0.0 and 1.0.

        Raises:
            If the device has gone away.
        """
        var v = Float32(0.0)
        _ = Com[StaticString("IAudioMeterInformation")](
            of=self.meter
        ).GetPeakValue(com_addr(v))
        return Float64(v)

    def channel_count(self) raises -> Int:
        """How many channels this meter reports separately.

        Returns:
            The metering channel count.

        Raises:
            If the device has gone away.
        """
        var n = UInt32(0)
        _ = Com[StaticString("IAudioMeterInformation")](
            of=self.meter
        ).GetMeteringChannelCount(com_addr(n))
        return Int(n)


def default_render_meter(role: Int32 = ROLE_CONSOLE) raises -> Meter:
    """The default speakers' peak meter, with no render stream attached.

    For a program whose sound leaves by some other road -- the system MIDI
    synthesiser, another process -- and which still wants the machine's own
    answer to "did anything come out".

    Args:
        role: Which default endpoint to meter.

    Returns:
        A meter on the default render endpoint.

    Raises:
        If COM is not initialised, or there is no render endpoint.
    """
    return Endpoint(role=role).meter()


# ===----------------------------------------------------------------------===#
# The callback that is not a callback
# ===----------------------------------------------------------------------===#

comptime RenderFill = def (
    OpaquePointer[MutUntrackedOrigin],
    Pointer[Float32, MutUntrackedOrigin],
    Int,
) thin abi("C") -> NoneType
"""Produce `frames` mono samples into `dest`, nominally in -1.0 ..= 1.0.

Called from inside the deadline. Thin C-ABI and captureless, which in this
dialect is exactly a C function pointer, and declared WITHOUT `raises` so the
compiler refuses a body that could unwind out of the audio loop. Whatever it
touches must have been allocated before `start`: no allocation, no locking, no
I/O, no COM.

Mono, because that is what both callers had and because fanning one voice into
N channels is the honest conversion. A caller that really produces interleaved
audio should use `begin` and `commit` and write the ring itself.

The first argument is whatever pointer was handed to `write` or `run` -- the
audio side's equivalent of `GWLP_USERDATA`, since a function pointer has
nowhere else to keep anything.
"""

comptime RenderRunning = def (
    OpaquePointer[MutUntrackedOrigin]
) thin abi("C") -> Bool
"""Asked once per wake by `run`: True to keep going, False to stop and drain.

Same rules as `RenderFill`. It runs on the audio thread, so it must answer
from memory -- a flag another thread sets -- rather than by doing anything.
"""


@always_inline
fn fan_out(
    mono: Pointer[Float32, MutUntrackedOrigin],
    destination: Int,
    frames: Int,
    channels: Int,
    is_float: Bool,
):
    """One mono voice into every channel of the engine's interleaved buffer.

    What `write` does between the fill and the release, exposed because a
    caller using `begin` and `commit` directly still wants it. A chip with one
    output pin, an endpoint with two channels, and a machine somewhere with
    six: copying the same sample into each is the honest answer, where panning
    a mono part across a stereo field would be inventing something.

    The 16-bit path CLAMPS. Both hand-written copies of this multiplied by
    32767 and converted, and the conversion WRAPS: measured on this machine,
    `Int16(1.0001 * 32767.0)` is -32766, so a sample one part in ten thousand
    over full scale came out inverted at full scale. That is not a clip, it is
    a crack, and it is louder than whatever caused it.

    The float path deliberately does NOT clamp: the engine accepts samples
    outside the range and clips them itself, and silently reshaping a caller's
    waveform is worse than letting the mixer do its job.

    Non-raising, and called from inside the deadline.

    Args:
        mono: `frames` mono samples, nominally in -1.0 ..= 1.0.
        destination: The engine's buffer, from `begin`.
        channels: How many channels to write per frame.
        frames: How many frames to write.
        is_float: The engine's sample format, from `AudioFormat.is_float`.
    """
    if is_float:
        var out = OpaquePointer[MutUntrackedOrigin](
            unsafe_from_address=destination
        ).unsafe_bitcast[Float32]()
        for i in range(frames):
            var v = mono[unsafe_offset=i]
            for c in range(channels):
                out[unsafe_offset = i * channels + c] = v
    else:
        var out = OpaquePointer[MutUntrackedOrigin](
            unsafe_from_address=destination
        ).unsafe_bitcast[Int16]()
        for i in range(frames):
            var f = Float64(mono[unsafe_offset=i])
            if f > 1.0:
                f = 1.0
            elif f < -1.0:
                f = -1.0
            var v = Int16(f * 32767.0)
            for c in range(channels):
                out[unsafe_offset = i * channels + c] = v


# ===----------------------------------------------------------------------===#
# What a run is worth reporting
# ===----------------------------------------------------------------------===#


@fieldwise_init
struct RenderStats(Copyable, Movable, Defaultable):
    """What the stream saw, for a caller that wants to show or check it.

    Written on the audio thread and read wherever; there is no lock and there
    must not be one. A torn read costs a wrong number on a screen for one
    frame, where a held lock would cost a gap in the sound.
    """

    var wakes: Int
    """Events delivered since `start`."""

    var underruns: Int
    """Wakes that found the ring completely empty.

    The only reporter of starvation there is. `GetBuffer`, `ReleaseBuffer` and
    `Start` all keep returning S_OK while there is an audible hole in the
    sound; a padding of zero on a wake is what a missed deadline looks like
    from the inside.
    """

    var frames: Int
    """Frames handed to the engine, including the pre-roll."""

    var gap_us: Int
    """Microseconds between the last two wakes."""

    var gap_max_us: Int
    """The longest gap seen, which is the number that says whether it glitched.
    """

    var gap_total_us: Int
    """Every gap added up, so the mean is a division and not a guess."""

    var fill_us: Int
    """Microseconds spent inside the last `RenderFill` and fan-out."""

    var load_permille: Int
    """The last fill as parts per thousand of the time available for it."""

    def __init__(out self):
        """A run that has not happened yet."""
        self.wakes = 0
        self.underruns = 0
        self.frames = 0
        self.gap_us = 0
        self.gap_max_us = 0
        self.gap_total_us = 0
        self.fill_us = 0
        self.load_permille = 0

    def mean_gap_us(self) -> Int:
        """The average wake-to-wake gap, which should be the device period.

        This is the number that decides whether a stream is event-driven or
        merely hopeful: it lands on the device period when Windows is waking
        us, and on whatever the sleep granularity happens to be when it is not.

        Returns:
            Microseconds, or 0 before the second wake.
        """
        if self.wakes < 2:
            return 0
        return self.gap_total_us // (self.wakes - 1)


# ===----------------------------------------------------------------------===#
# The stream
# ===----------------------------------------------------------------------===#


struct RenderStream(Movable):
    """An open, event-driven, shared-mode render stream on the default speakers.

    Construction is the whole eight-step open: enumerator, endpoint, client,
    meter, mix format, `Initialize`, event, render client. After it, the
    stream is stopped, the ring is empty, and `format` and `frames` say what
    the engine decided.

    There are two ways to drive it, and both examples this replaces needed a
    different one.

    A program that owns a thread for audio calls `run`, which is the whole
    loop: pre-roll, `Start`, wake-fill-release until the predicate says stop,
    drain, `Stop`.

    A program that has a window and no audio thread drives the loop itself,
    blocking on `event` and the message queue together with
    `MsgWaitForMultipleObjects` -- one call that is never late for either --
    and calls `start`, `write` and `stop` by hand.

    LIFETIME. This value owns five COM interfaces, a kernel event, a CoTaskMem
    block and a scratch buffer, and its destructor frees all four kinds. It
    must therefore go out of scope INSIDE the `with Apartment(...)` block that
    created it: releasing a COM pointer after `CoUninitialize` is a crash
    inside ole32 with no useful stack. `_ = stream^` at the end of the block
    makes that explicit where scoping does not already.
    """

    var endpoint: Endpoint
    """The device, kept so the stream can still name what it is playing into."""

    var client: ComPtr[StaticString("IAudioClient")]
    """The initialised audio client."""

    var render: ComPtr[StaticString("IAudioRenderClient")]
    """The ring buffer's writer."""

    var meter: Meter
    """The endpoint's peak meter, opened alongside so evidence is always to hand.
    """

    var format: AudioFormat
    """What the engine is running at. Read, never assumed, never negotiated."""

    var frames: Int
    """The ring, in frames. A floor was requested; the engine chose this."""

    var event: Int
    """The auto-reset event WASAPI signals once per device period.

    Public because a program with a window blocks on this and on its message
    queue in the same `MsgWaitForMultipleObjects` call.
    """

    var default_period_us: Int
    """The engine's default device period, in microseconds."""

    var minimum_period_us: Int
    """The engine's minimum device period, in microseconds."""

    var running: Bool
    """Whether `Start` has been called and `Stop` has not."""

    var stats: RenderStats
    """What this run has seen so far."""

    var meter_peak: Float64
    """The highest endpoint peak seen by `poll_meter`, including from `run`."""

    var wait_status: UInt32
    """The last `WaitForSingleObject` result, if it was not `WAIT_OBJECT_0`.

    Zero means every wait so far succeeded. `run` stores the failing status
    here and leaves rather than hanging on a stream that has gone away.
    """

    var mmcss_granted: Bool
    """Whether the last `run` got an MMCSS "Pro Audio" slice."""

    var _format_block: Int
    var _mono: Pointer[Float32, MutUntrackedOrigin]
    var _mono_frames: Int
    var _wait: def (Int, UInt32) thin abi("C") -> UInt32
    var _sleep: def (UInt32) thin abi("C") -> NoneType
    var _qpc: def (Pointer[Int64, MutAnyOrigin]) thin abi("C") -> c_int
    var _ticks_per_us: Float64
    var _last_tick: Int64

    def __init__(
        out self, *, buffer_ms: Int = 60, role: Int32 = ROLE_CONSOLE
    ) raises:
        """Open the default speakers and initialise a stream on them.

        `buffer_ms` is a FLOOR, not an exact request: the engine rounds up to a
        whole number of periods and imposes its own minimum. Measured here,
        asking for 1 ms gets 1056 frames -- 22 ms -- while asking for 60 gets
        exactly 2880. Read `frames` afterwards rather than assuming either.

        Shared mode, always. `hnsPeriodicity` MUST be zero in shared mode, and
        `AUDCLNT_STREAMFLAGS_EVENTCALLBACK` and `SetEventHandle` are one
        decision rather than two: the flag without the handle is
        `AUDCLNT_E_EVENTHANDLE_NOT_SET` at `Start`, and the handle without the
        flag is `AUDCLNT_E_EVENTHANDLE_NOT_EXPECTED` at `SetEventHandle`.

        Args:
            buffer_ms: The smallest ring the caller can live with.
            role: Which default endpoint: console, multimedia or communications.

        Raises:
            If COM is not initialised on this thread, there is no render
            endpoint, the audio service is not running, or the engine's mix
            format is one this module cannot write.
        """
        if buffer_ms <= 0:
            raise Error("buffer_ms must be positive")

        self.endpoint = Endpoint(role=role)
        self.client = self.endpoint.activate["IAudioClient"]()
        self.meter = self.endpoint.meter()

        var ac = Com[StaticString("IAudioClient")](of=self.client)

        # Step 4: ask the engine what it is already running at. The block is
        # CoTaskMem and stays alive until this value dies, because `Initialize`
        # is not the only thing that reads it -- a caller may want to look.
        var format_address: Int = 0
        _ = ac.GetMixFormat(com_addr(format_address))
        self._format_block = format_address
        self.format = read_wave_format(format_address)

        var default_period = Int64(0)
        var minimum_period = Int64(0)
        _ = ac.GetDevicePeriod(
            com_addr(default_period), com_addr(minimum_period)
        )
        self.default_period_us = Int(default_period) // 10
        self.minimum_period_us = Int(minimum_period) // 10

        _ = ac.Initialize(
            _SHAREMODE_SHARED,
            _STREAMFLAGS_EVENTCALLBACK,
            Int64(buffer_ms * REFTIMES_PER_MS),
            Int64(0),
            format_address,
            Int(0),
        )

        var buffer_frames = UInt32(0)
        _ = ac.GetBufferSize(com_addr(buffer_frames))
        self.frames = Int(buffer_frames)
        if self.frames <= 0:
            raise Error("GetBufferSize reported a ring of no frames")

        # Auto-reset, initially unsignalled. Windows sets it once per device
        # period once the stream is running; before `Start` it is never set,
        # which is why the first buffer has to be filled by hand.
        var create_event = win32[
            def (Int, Int32, Int32, Int) thin abi("C") -> Int, "CreateEventW"
        ]()
        self.event = create_event(0, Int32(0), Int32(0), 0)
        if self.event == 0:
            raise Error("CreateEventW failed")
        _ = ac.SetEventHandle(self.event)

        # Step 8: `GetService`, not `QueryInterface`. The render client is a
        # service of an INITIALISED client, so this must come after Initialize.
        var iid = _guid_bytes(winkb_interface_iid["IAudioRenderClient"]())
        var render_address: Int = 0
        _ = ac.GetService(
            iid.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            com_addr(render_address),
        )
        _ = iid
        if render_address == 0:
            raise Error("GetService returned S_OK and a null render client")
        self.render = ComPtr[StaticString("IAudioRenderClient")](
            adopt=render_address
        )

        # One scratch buffer, exactly ring-sized, so a fill can never be asked
        # for more mono samples than there is room for. Both callers allocated
        # their own and both had to remember to size it from `frames`.
        self._mono = unsafe_alloc[Float32](self.frames, alignment=64)
        self._mono_frames = self.frames

        # Everything the deadline calls, resolved here and never again. A
        # GetProcAddress per wake would probably be fine; "probably fine" is
        # not what a real-time loop is for.
        self._wait = win32[
            def (Int, UInt32) thin abi("C") -> UInt32, "WaitForSingleObject"
        ]()
        self._sleep = win32[def (UInt32) thin abi("C") -> NoneType, "Sleep"]()
        self._qpc = win32[
            def (Pointer[Int64, MutAnyOrigin]) thin abi("C") -> c_int,
            "QueryPerformanceCounter",
        ]()
        var qpf = win32[
            def (Pointer[Int64, MutAnyOrigin]) thin abi("C") -> c_int,
            "QueryPerformanceFrequency",
        ]()
        var freq = Int64(1)
        _ = qpf(com_addr(freq))
        self._ticks_per_us = Float64(Int(freq)) / 1_000_000.0
        self._last_tick = Int64(0)

        self.running = False
        self.stats = RenderStats()
        self.meter_peak = 0.0
        self.wait_status = UInt32(0)
        self.mmcss_granted = False

    def __deinit__(deinit self):
        """Free the event, the format block and the scratch buffer.

        The five COM interfaces are released by their own fields dying, in
        whichever apartment is current -- which is why this value must not
        outlive the `with Apartment(...)` block that made it.

        Resolved by address rather than through `win32[]` because a destructor
        cannot raise, and kernel32 exporting `CreateEventW` but not
        `CloseHandle` is not a real machine.
        """
        if self._mono_frames > 0:
            self._mono.unsafe_free()
        if self.event != 0:
            var close_at = Win32Module(
                String(winkb_function_dll["CloseHandle"]())
            ).address_of("CloseHandle")
            if close_at != 0:
                _ = Pointer(to=close_at).unsafe_bitcast[
                    def (Int) thin abi("C") -> Int32
                ]()[](self.event)
        if self._format_block != 0:
            var free_at = Win32Module(
                String(winkb_function_dll["CoTaskMemFree"]())
            ).address_of("CoTaskMemFree")
            if free_at != 0:
                Pointer(to=free_at).unsafe_bitcast[
                    def (Int) thin abi("C") -> NoneType
                ]()[](self._format_block)

    # ── What the engine will say about itself ───────────────────────────────

    def describe(self) raises -> String:
        """One line naming the stream, for a run that should say what it did.

        Returns:
            Mode, format, ring size in frames and milliseconds, device period,
            and the endpoint id.

        Raises:
            If the endpoint will not give up its id.
        """
        return (
            String("WASAPI shared, event-driven, ")
            + self.format.describe()
            + ", ring "
            + String(self.frames)
            + " frames ("
            + String(self.frames * 1000 // self.format.rate)
            + " ms), period "
            + String(self.default_period_us)
            + " us  "
            + self.endpoint.id()
        )

    def padding(self) raises -> Int:
        """Frames still queued in the ring and not yet played.

        Returns:
            The engine's current padding.

        Raises:
            If the device has gone away.
        """
        var p = UInt32(0)
        _ = Com[StaticString("IAudioClient")](of=self.client).GetCurrentPadding(
            com_addr(p)
        )
        return Int(p)

    def available(self) raises -> Int:
        """How much of the ring has drained, which is exactly how much to write.

        Returns:
            Free frames; never more than `frames`.

        Raises:
            If the device has gone away.
        """
        return self.frames - self.padding()

    def latency_us(self) raises -> Int:
        """How far ahead of the speaker the stream is writing, right now.

        Returns:
            The queued audio, in microseconds.

        Raises:
            If the device has gone away.
        """
        return self.padding() * 1_000_000 // self.format.rate

    def poll_meter(mut self) raises -> Float64:
        """Ask the endpoint what it heard, and remember the loudest answer.

        Returns:
            The peak since the previous call, 0.0 to 1.0.

        Raises:
            If the device has gone away.
        """
        var p = self.meter.peak()
        if p > self.meter_peak:
            self.meter_peak = p
        return p

    # ── The low-level pair, for a caller writing the ring itself ────────────

    def begin(self, frames: Int) raises -> Int:
        """Claim `frames` frames of the ring and get the engine's own memory.

        Ask for exactly what `available` said and not one frame more:
        `GetBuffer` for a ring that is still occupied is
        `AUDCLNT_E_BUFFER_TOO_LARGE`, which is what a restart after a `Stop`
        without a `reset` looks like.

        Args:
            frames: How many frames to claim.

        Returns:
            The address of an interleaved buffer of `frames * channels`
            samples in the engine's own format, or 0.

        Raises:
            If more was asked for than is free, or the device has gone away.
        """
        var address: Int = 0
        _ = Com[StaticString("IAudioRenderClient")](of=self.render).GetBuffer(
            UInt32(frames), com_addr(address)
        )
        return address

    def commit(mut self, frames: Int) raises:
        """Hand a claimed buffer back to the engine.

        Args:
            frames: How many frames were written; must match the `begin`.

        Raises:
            If the device has gone away.
        """
        _ = Com[StaticString("IAudioRenderClient")](
            of=self.render
        ).ReleaseBuffer(UInt32(frames), UInt32(0))
        self.stats.frames += frames

    def commit_silence(mut self, frames: Int) raises:
        """Hand a claimed buffer back, telling the engine to ignore what is in it.

        `AUDCLNT_BUFFERFLAGS_SILENT` is the documented way to be quiet, and it
        is cheaper and more honest than writing zeros: the engine skips the
        memory entirely. Both examples zeroed by hand through their
        synthesiser.

        Args:
            frames: How many frames were claimed.

        Raises:
            If the device has gone away.
        """
        _ = Com[StaticString("IAudioRenderClient")](
            of=self.render
        ).ReleaseBuffer(UInt32(frames), _BUFFERFLAGS_SILENT)
        self.stats.frames += frames

    # ── One wake ────────────────────────────────────────────────────────────

    def write(
        mut self, fill: RenderFill, user: OpaquePointer[MutUntrackedOrigin]
    ) raises -> Int:
        """Write exactly what has drained, and not one frame more.

        The whole contract of a WASAPI render loop, in one call: how much is
        free, claim it, ask the caller for that many mono samples, fan them out
        into the engine's format, release. Nothing in here allocates and
        nothing in here locks.

        Args:
            fill: The sample source; called once, on the deadline.
            user: Passed through to `fill` untouched.

        Returns:
            Frames written; 0 if the ring was still full.

        Raises:
            If the device has gone away.
        """
        var pad = self.padding()
        if self.running and pad == 0:
            # The ring ran dry between wakes. Nothing else reports this --
            # GetBuffer, ReleaseBuffer and Start all still say S_OK -- so this
            # count is the only evidence an underrun leaves.
            self.stats.underruns += 1
        var n = self.frames - pad
        if n <= 0:
            return 0

        var address = self.begin(n)
        if address == 0:
            return 0

        var t0 = Int64(0)
        _ = self._qpc(com_addr(t0))
        fill(user, self._mono, n)
        fan_out(
            self._mono, address, n, self.format.channels, self.format.is_float
        )
        var t1 = Int64(0)
        _ = self._qpc(com_addr(t1))

        self.commit(n)
        self.stats.fill_us = Int(Float64(Int(t1) - Int(t0)) / self._ticks_per_us)
        if self.stats.gap_us > 0:
            # The number that says whether this is close to the edge: the fill,
            # as a fraction of the time the device gave us to do it in.
            self.stats.load_permille = (
                self.stats.fill_us * 1000 // self.stats.gap_us
            )
        return n

    def write_silence(mut self) raises -> Int:
        """Fill whatever has drained with silence, for a paused stream.

        Returns:
            Frames written; 0 if the ring was still full.

        Raises:
            If the device has gone away.
        """
        var n = self.available()
        if n <= 0:
            return 0
        var address = self.begin(n)
        if address == 0:
            return 0
        self.commit_silence(n)
        return n

    def wait(mut self, timeout_ms: Int) raises -> Bool:
        """Block until the engine wants more, and record the wake gap.

        Args:
            timeout_ms: How long to wait before giving up on the stream.

        Returns:
            True if the event arrived; False if it did not, with the reason in
            `wait_status`.

        Raises:
            Never, in practice; declared for symmetry with the rest.
        """
        var status = self._wait(self.event, UInt32(timeout_ms))
        if status != _WAIT_OBJECT_0:
            self.wait_status = status
            return False
        var now = Int64(0)
        _ = self._qpc(com_addr(now))
        if self._last_tick != Int64(0):
            var gap = Int(
                Float64(Int(now) - Int(self._last_tick)) / self._ticks_per_us
            )
            self.stats.gap_us = gap
            self.stats.gap_total_us += gap
            if gap > self.stats.gap_max_us:
                self.stats.gap_max_us = gap
        self._last_tick = now
        self.stats.wakes += 1
        return True

    def wake_timeout_ms(self) -> Int:
        """A generous ceiling on how long a healthy wake can take.

        Twice the ring plus a fifth of a second. If the event has not arrived
        by then the stream is gone, and hanging forever is the wrong answer.

        Returns:
            A timeout in milliseconds.
        """
        return 2 * (self.frames * 1000 // self.format.rate) + 200

    # ── Transport ───────────────────────────────────────────────────────────

    def start(
        mut self, fill: RenderFill, user: OpaquePointer[MutUntrackedOrigin]
    ) raises:
        """Fill the ring, then start the engine draining it.

        The pre-roll is not optional. The event is never signalled before
        `Start`, so the first buffer is the caller's to fill by hand, and
        starting on an unfilled ring is a guaranteed underrun on the first
        period -- which in shared mode is not an error: the engine mixes
        whatever stale contents the ring has, and that is an audible tick.

        This fills only what is FREE rather than the whole ring, so it is safe
        after a `stop` that left audio queued. To throw that audio away first,
        call `reset`.

        Args:
            fill: The sample source.
            user: Passed through to `fill`.

        Raises:
            If the device has gone away, or the event handle was never set.
        """
        if self.running:
            return
        _ = self.write(fill, user)
        _ = Com[StaticString("IAudioClient")](of=self.client).Start()
        self.running = True
        self._last_tick = Int64(0)

    def stop(mut self) raises:
        """Stop the engine draining the ring.

        This does NOT empty the ring and does not wait for it: whatever is
        still queued stays queued and is simply not played. Call `drain` first
        to let the tail reach the speaker, or `reset` afterwards to discard it.

        Raises:
            If the device has gone away.
        """
        if not self.running:
            return
        _ = Com[StaticString("IAudioClient")](of=self.client).Stop()
        self.running = False

    def reset(mut self) raises:
        """Throw away whatever is still queued in the ring.

        Legal only on a stopped stream. Without it, restarting asks `begin` for
        a ring that is still mostly occupied; `start` now handles that by
        filling only the free space, but a caller who wants the queued audio
        gone -- a seek, a stop button, a new tune -- wants this.

        Raises:
            If the stream is still running, or the device has gone away.
        """
        if self.running:
            raise Error(
                "IAudioClient::Reset is legal only on a stopped stream; call"
                " stop() first"
            )
        _ = Com[StaticString("IAudioClient")](of=self.client).Reset()

    def drain(mut self, timeout_ms: Int = 200) raises:
        """Wait for the queued audio to reach the speaker.

        Without this, `stop` truncates the last buffer -- up to a whole ring of
        sound that was written, acknowledged, and never heard. One of the two
        modules this replaces did it and the other did not.

        Args:
            timeout_ms: How long to wait before giving up on the tail.

        Raises:
            If the device has gone away.
        """
        var waited = 0
        while waited < timeout_ms:
            if self.padding() == 0:
                return
            self._sleep(UInt32(2))
            waited += 2

    # ── The whole loop, for a program with a thread to spare ────────────────

    def run(
        mut self,
        fill: RenderFill,
        running: RenderRunning,
        user: OpaquePointer[MutUntrackedOrigin],
        *,
        pro_audio: Bool = True,
        meter: Bool = True,
    ) raises:
        """Pre-roll, start, wake-fill-release until asked to stop, drain, stop.

        This is the whole of the deadline. It allocates nothing, locks nothing,
        resolves no entry points and does no I/O; the only things it calls that
        compute anything are `fill` and `running`, which are non-raising C
        function pointers.

        It is `raises` all the same, and that is not a contradiction. Every COM
        call in here can report a stream that has gone away -- the device
        unplugged, the session disconnected -- and the right answer to that is
        to leave, not to keep writing into a ring nobody owns.

        Call it on a thread that has initialised COM for itself, and prefer the
        MTA: this thread owns no window and pumps no messages, and an STA whose
        messages are never pumped is where cross-apartment calls go to hang.

        Args:
            fill: The sample source, called once per wake.
            running: Asked once per wake; False stops the loop.
            user: Passed through to both, untouched.
            pro_audio: Register with MMCSS for the duration. Costs nothing when
                it is declined, and `mmcss_granted` records which happened.
            meter: Read the endpoint's own peak meter once per wake, so a run
                always carries independent evidence that sound came out. It is
                one in-process COM call against a 10 ms period.

        Raises:
            If the device goes away, or the stream was never initialised.
        """
        var task = 0
        if pro_audio:
            task = pro_audio_begin()
        self.mmcss_granted = task != 0

        self.start(fill, user)
        var timeout = self.wake_timeout_ms()
        while running(user):
            if not self.wait(timeout):
                break
            if meter:
                _ = self.poll_meter()
            _ = self.write(fill, user)

        self.drain()
        self.stop()

        if task != 0:
            pro_audio_end(task)


# ===----------------------------------------------------------------------===#
# Telling the scheduler this is audio
# ===----------------------------------------------------------------------===#


def pro_audio_begin(task: StringSlice = "Pro Audio") raises -> Int:
    """Ask the Multimedia Class Scheduler for a real-time slice on this thread.

    Without it an audio thread is an ordinary thread competing with everything
    else on the machine; with it the scheduler gives it the guaranteed slice a
    10 ms deadline needs. Failure is not fatal -- the loop still runs, just
    less reliably -- so a zero answer is a result rather than an error.

    Call it on the audio thread itself; the registration is per-thread.

    Args:
        task: The MMCSS task name, as registered under
            `SYSTEM\\CurrentControlSet\\Control\\SafeBoot\\Multimedia\\SystemProfile\\Tasks`.

    Returns:
        A handle to pass to `pro_audio_end`, or 0 if MMCSS declined.

    Raises:
        If AVRT cannot be loaded, or the task name is not valid UTF-8.
    """
    var av_set = win32[
        def (
            Pointer[UInt16, MutAnyOrigin], Pointer[UInt32, MutAnyOrigin]
        ) thin abi("C") -> Int,
        "AvSetMmThreadCharacteristicsW",
    ]()
    var name = WideString(task)
    var index = UInt32(0)
    var handle = av_set(name.unsafe_ptr(), com_addr(index))
    _ = name
    return handle


def pro_audio_end(handle: Int) raises:
    """Give the real-time slice back.

    Args:
        handle: Whatever `pro_audio_begin` returned; 0 is a no-op.

    Raises:
        If AVRT cannot be loaded.
    """
    if handle == 0:
        return
    var av_revert = win32[
        def (Int) thin abi("C") -> Int32, "AvRevertMmThreadCharacteristics"
    ]()
    _ = av_revert(handle)
