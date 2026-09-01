# The speaker: WASAPI shared mode, event-driven.
#
# The Mac hands CoreAudio a function pointer and CoreAudio calls it on a
# thread it owns. WASAPI inverts that. Nobody calls you: you are given a ring
# buffer and an event, and you are the thread -- wake, ask how much of the
# ring has drained, write exactly that much, sleep again. The deadline is the
# same deadline; the ownership of the thread is not. So the render callback
# does not disappear in the port, it becomes the body of a loop, and
# `render_scheduled` in chipplay.mojo is called from there without a line of
# it changing.
#
# Shared mode, not exclusive, for three measured reasons. This machine's mix
# format is refused outright in exclusive mode (AUDCLNT_E_UNSUPPORTED_FORMAT),
# so exclusive would mean negotiating a hardware format and writing a second
# output path for it. Exclusive mode evicts every other application on the
# endpoint, which is wrong for an example somebody runs while music is
# playing. And the latency it would buy is not needed: the engine already
# wakes us every 10 ms.
#
# Every IID, vtable slot, constant and DLL name here is a query against
# windows_api.db. There is exactly one exception and it is recorded below.

from std.ffi import c_int
from std.memory import Pointer, OpaquePointer
from std.sys._com import ComPtr, com_addr, _guid_bytes
from std.sys._winkb import winkb_constant, winkb_interface_iid
from std.sys.com import Com, co_create

from win32 import win32


# The metadata holds this name -- Windows.Win32.Media.Audio.MMDeviceEnumerator
# is in `types` -- but not its value: every guid-kind row in the database has
# a NULL value, coclass CLSIDs included. That is the recorded gap
# `std.sys.com.co_create` documents, and the same remedy applies: spell it
# once, next to the name it belongs to, and nowhere else in the program.
comptime CLSID_MMDeviceEnumerator = StaticString(
    "bcde0395-e52f-467c-8e3d-c4579291692e"
)

comptime eRender = Int32(winkb_constant["eRender"]())
comptime eConsole = Int32(winkb_constant["eConsole"]())
comptime CLSCTX_ALL = UInt32(winkb_constant["CLSCTX_ALL"]())
comptime SHAREMODE_SHARED = Int32(winkb_constant["AUDCLNT_SHAREMODE_SHARED"]())
comptime STREAMFLAGS_EVENTCALLBACK = UInt32(
    winkb_constant["AUDCLNT_STREAMFLAGS_EVENTCALLBACK"]()
)
comptime WAVE_FORMAT_PCM = winkb_constant["WAVE_FORMAT_PCM"]()
comptime WAVE_FORMAT_IEEE_FLOAT = winkb_constant["WAVE_FORMAT_IEEE_FLOAT"]()
comptime WAVE_FORMAT_EXTENSIBLE = winkb_constant["WAVE_FORMAT_EXTENSIBLE"]()
comptime WAIT_OBJECT_0 = UInt32(winkb_constant["WAIT_OBJECT_0"]())

# A REFERENCE_TIME is one ten-millionth of a second. Every duration WASAPI
# takes or returns is in these units, and the mistake that costs an afternoon
# is handing Initialize milliseconds: 200 becomes twenty microseconds, which
# is below the device period, and the call fails with a code that says nothing
# about units.
comptime REFTIMES_PER_MS = 10_000


struct Audio(Movable):
    """An open render stream, owning every interface it opened.

    The five pointers are `ComPtr`s and not raw addresses, and that is not
    taste. An earlier version of this file kept addresses and AddRef'd them by
    hand on the way out; the compiler destroyed each owning pointer at its
    last use -- which was the AddRef's own argument -- so every object was
    released to zero before the function returned, and the first call through
    any of them was an access violation inside MMDevAPI. Letting the type own
    them means the release happens exactly when this value dies, and the whole
    question stops being a question.
    """

    var enumerator: ComPtr[StaticString("IMMDeviceEnumerator")]
    var device: ComPtr[StaticString("IMMDevice")]
    var client: ComPtr[StaticString("IAudioClient")]
    var meter: ComPtr[StaticString("IAudioMeterInformation")]
    var render: ComPtr[StaticString("IAudioRenderClient")]

    var format: Int         # the CoTaskMem WAVEFORMATEX block
    var event: Int          # the auto-reset event WASAPI signals
    var rate: Int           # samples per second: the engine's, not ours
    var channels: Int
    var frames: Int         # the ring, in frames
    var is_float: Bool
    var open: Bool

    def __init__(out self):
        """A closed stream. `--midi` and `--write` never open one."""
        self.enumerator = ComPtr[StaticString("IMMDeviceEnumerator")](adopt=0)
        self.device = ComPtr[StaticString("IMMDevice")](adopt=0)
        self.client = ComPtr[StaticString("IAudioClient")](adopt=0)
        self.meter = ComPtr[StaticString("IAudioMeterInformation")](adopt=0)
        self.render = ComPtr[StaticString("IAudioRenderClient")](adopt=0)
        self.format = 0
        self.event = 0
        self.rate = 48000
        self.channels = 2
        self.frames = 0
        self.is_float = True
        self.open = False

    def padding(self) raises -> Int:
        """Frames still queued in the ring.

        This is the only reporter of starvation there is. An underrun in
        shared mode is completely silent: GetBuffer, ReleaseBuffer and Start
        all keep returning S_OK while there is an audible hole in the sound.
        A padding of zero on a wake is what a missed deadline looks like from
        the inside, and it is why the loop counts them.
        """
        var p = UInt32(0)
        _ = Com[StaticString("IAudioClient")](of=self.client).GetCurrentPadding(
            com_addr(p)
        )
        return Int(p)

    def get_buffer(self, frames: Int) raises -> Int:
        var address: Int = 0
        _ = Com[StaticString("IAudioRenderClient")](of=self.render).GetBuffer(
            UInt32(frames), com_addr(address)
        )
        return address

    def release_buffer(self, frames: Int) raises:
        _ = Com[StaticString("IAudioRenderClient")](
            of=self.render
        ).ReleaseBuffer(UInt32(frames), UInt32(0))

    def start(self) raises:
        _ = Com[StaticString("IAudioClient")](of=self.client).Start()

    def stop(self) raises:
        _ = Com[StaticString("IAudioClient")](of=self.client).Stop()

    def reset(self) raises:
        """Throw away whatever is still queued in the ring.

        Stop does not empty the ring, it only stops draining it -- so after a
        stop the padding is still whatever was left, and asking GetBuffer for
        the whole ring is AUDCLNT_E_BUFFER_TOO_LARGE. Reset is the call that
        makes the ring empty again, and it is legal only on a stopped stream.
        """
        _ = Com[StaticString("IAudioClient")](of=self.client).Reset()

    def peak(self) raises -> Float64:
        """What the ENDPOINT metered, not what we believe we wrote.

        Independent evidence that sound left the program: the meter belongs to
        the device and knows nothing about this code.
        """
        var v = Float32(0.0)
        _ = Com[StaticString("IAudioMeterInformation")](
            of=self.meter
        ).GetPeakValue(com_addr(v))
        return Float64(v)

    def silence(self, address: Int, frames: Int):
        """Silence, in whichever sample format the engine is running."""
        if self.is_float:
            var f = OpaquePointer[MutUntrackedOrigin](
                unsafe_from_address=address
            ).unsafe_bitcast[Float32]()
            for i in range(frames * self.channels):
                f[unsafe_offset=i] = Float32(0.0)
        else:
            var s = OpaquePointer[MutUntrackedOrigin](
                unsafe_from_address=address
            ).unsafe_bitcast[Int16]()
            for i in range(frames * self.channels):
                s[unsafe_offset=i] = Int16(0)

    def fan_out(self, address: Int, mono_address: Int, frames: Int):
        """One mono buffer, written to every channel the engine expects.

        The chip has one output. This endpoint has two, interleaved, and a
        machine with a 5.1 endpoint would have six -- so this reads `channels`
        rather than assuming stereo.
        """
        var mono = Pointer[Float32, MutUntrackedOrigin](
            unsafe_from_address=mono_address
        )
        if self.is_float:
            var f = OpaquePointer[MutUntrackedOrigin](
                unsafe_from_address=address
            ).unsafe_bitcast[Float32]()
            for i in range(frames):
                var v = mono[unsafe_offset=i]
                for c in range(self.channels):
                    f[unsafe_offset = i * self.channels + c] = v
        else:
            var s = OpaquePointer[MutUntrackedOrigin](
                unsafe_from_address=address
            ).unsafe_bitcast[Int16]()
            for i in range(frames):
                var v = Int16(Float64(mono[unsafe_offset=i]) * 32767.0)
                for c in range(self.channels):
                    s[unsafe_offset = i * self.channels + c] = v

    def close(mut self) raises:
        """Free what COM does not own: the format block and the event.

        The five interfaces are released by this value's own destruction, in
        the apartment that made them. This must happen before CoUninitialize
        -- releasing a COM pointer after the apartment is gone is a crash
        inside ole32 with no useful stack -- which is what keeping the whole
        `Audio` inside the `with Apartment(...)` block guarantees.
        """
        if self.format != 0:
            _ = win32[def (Int) thin abi("C") -> NoneType, "CoTaskMemFree"]()(
                self.format
            )
            self.format = 0
        if self.event != 0:
            _ = win32[def (Int) thin abi("C") -> c_int, "CloseHandle"]()(
                self.event
            )
            self.event = 0
        self.open = False


def open_meter() raises -> Audio:
    """The endpoint's peak meter, and nothing else.

    `--midi` opens no render stream of its own -- the system synthesiser has
    its own path to the speakers -- but the question "did sound come out" is
    the same question, and this is the same instrument that answers it for
    the chip. The meter belongs to the device and knows nothing about which
    program fed it.
    """
    var a = Audio()
    var enumerator = co_create[
        CLSID_MMDeviceEnumerator, "IMMDeviceEnumerator"
    ]()
    var device_address: Int = 0
    _ = Com[StaticString("IMMDeviceEnumerator")](
        of=enumerator
    ).GetDefaultAudioEndpoint(eRender, eConsole, com_addr(device_address))
    a.enumerator = enumerator^
    a.device = ComPtr[StaticString("IMMDevice")](adopt=device_address)

    var iid_meter = _guid_bytes(winkb_interface_iid["IAudioMeterInformation"]())
    var meter_address: Int = 0
    _ = Com[StaticString("IMMDevice")](of=a.device).Activate(
        iid_meter.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        CLSCTX_ALL,
        Int(0),
        com_addr(meter_address),
    )
    a.meter = ComPtr[StaticString("IAudioMeterInformation")](
        adopt=meter_address
    )
    return a^


def open_output(buffer_ms: Int) raises -> Audio:
    """The seven steps from "there is a machine" to "there is a ring buffer".

    COM must already be initialised on the calling thread.
    """
    var a = Audio()

    # ── 1. The enumerator, and 2. the default render endpoint ────────────
    # eRender/eConsole: the speakers the user thinks of as "the speakers".
    var enumerator = co_create[
        CLSID_MMDeviceEnumerator, "IMMDeviceEnumerator"
    ]()
    var device_address: Int = 0
    _ = Com[StaticString("IMMDeviceEnumerator")](
        of=enumerator
    ).GetDefaultAudioEndpoint(eRender, eConsole, com_addr(device_address))
    a.enumerator = enumerator^
    a.device = ComPtr[StaticString("IMMDevice")](adopt=device_address)

    # ── 3. IAudioClient off the endpoint ─────────────────────────────────
    # Activate is COM's other activation verb: not a CLSID, but "give me this
    # interface, implemented for this device". The IID comes from the
    # metadata; the activation-parameters pointer is null.
    var iid_client = _guid_bytes(winkb_interface_iid["IAudioClient"]())
    var client_address: Int = 0
    _ = Com[StaticString("IMMDevice")](of=a.device).Activate(
        iid_client.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        CLSCTX_ALL,
        Int(0),
        com_addr(client_address),
    )
    a.client = ComPtr[StaticString("IAudioClient")](adopt=client_address)

    # The endpoint's own peak meter, off the same IMMDevice. It answers "did
    # sound actually leave this program", which is a different question from
    # "did every call return S_OK" -- and in shared mode every call returns
    # S_OK even while the ring starves.
    var iid_meter = _guid_bytes(winkb_interface_iid["IAudioMeterInformation"]())
    var meter_address: Int = 0
    _ = Com[StaticString("IMMDevice")](of=a.device).Activate(
        iid_meter.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        CLSCTX_ALL,
        Int(0),
        com_addr(meter_address),
    )
    a.meter = ComPtr[StaticString("IAudioMeterInformation")](
        adopt=meter_address
    )

    # ── 4. The mix format ────────────────────────────────────────────────
    # In shared mode this is not a request, it is a statement: the engine is
    # already running at this rate and this width, and everything the
    # synthesiser produces has to arrive in it. That is why the chip's
    # SAMPLE_RATE is checked against this number at start-up rather than
    # assumed -- they happen to agree at 48000 here, and on a machine where
    # they did not the whole tune would play at the wrong pitch.
    var format_address: Int = 0
    _ = Com[StaticString("IAudioClient")](of=a.client).GetMixFormat(
        com_addr(format_address)
    )
    if format_address == 0:
        raise Error("GetMixFormat returned S_OK and a null format")
    a.format = format_address

    var fmt = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=format_address
    )
    var f16 = fmt.unsafe_bitcast[UInt16]()
    var f32 = fmt.unsafe_bitcast[UInt32]()
    var f8 = fmt.unsafe_bitcast[UInt8]()
    var tag = Int(f16[unsafe_offset=0])
    var channels = Int(f16[unsafe_offset=1])
    var rate = Int(f32[unsafe_offset=1])
    var bits = Int(f16[unsafe_offset=7])
    var cb_size = Int(f16[unsafe_offset=8])

    # KSDATAFORMAT_SUBTYPE_IEEE_FLOAT and _PCM are the WAVE_FORMAT_* tag
    # promoted into a GUID: Data1 IS the tag. So float-versus-integer can be
    # decided without a hand-written GUID anywhere -- read the u32 at the
    # SubFormat offset and compare it against the constants the metadata
    # already gives us.
    #
    # The offset is 24, found by looking rather than by asking. The metadata
    # records WAVEFORMATEX as 20 bytes where the SDK's sizeof is 18, because
    # mmreg.h wraps the whole family in pshpack1 and the metadata records the
    # unpacked reading; that two-byte difference moves every field of
    # WAVEFORMATEXTENSIBLE. The seven fields read above are at the same
    # offsets either way, which is why they are read and this one is not.
    var subformat_tag = 0
    if tag == WAVE_FORMAT_EXTENSIBLE and cb_size >= 22:
        subformat_tag = Int(
            UInt32(f8[unsafe_offset=24])
            | (UInt32(f8[unsafe_offset=25]) << 8)
            | (UInt32(f8[unsafe_offset=26]) << 16)
            | (UInt32(f8[unsafe_offset=27]) << 24)
        )

    var is_float = tag == WAVE_FORMAT_IEEE_FLOAT or (
        tag == WAVE_FORMAT_EXTENSIBLE
        and subformat_tag == WAVE_FORMAT_IEEE_FLOAT
    )
    var is_pcm16 = (
        tag == WAVE_FORMAT_PCM
        or (tag == WAVE_FORMAT_EXTENSIBLE and subformat_tag == WAVE_FORMAT_PCM)
    ) and bits == 16
    if not is_float and not is_pcm16:
        raise Error(
            "unhandled mix format: tag "
            + String(tag)
            + ", "
            + String(bits)
            + " bits"
        )

    # ── 5. Initialize ────────────────────────────────────────────────────
    # hnsPeriodicity MUST be zero in shared mode. hnsBufferDuration is a
    # floor, not an exact request: the engine rounds up to a whole number of
    # periods, and its own minimum here is 22 ms however little you ask for.
    #
    # AUDCLNT_STREAMFLAGS_EVENTCALLBACK is a promise, not a hint: set it and
    # SetEventHandle must follow before Start, or Start returns
    # AUDCLNT_E_EVENTHANDLE_NOT_SET. Leave it clear and SetEventHandle is the
    # call that fails instead. The two halves are one decision.
    _ = Com[StaticString("IAudioClient")](of=a.client).Initialize(
        SHAREMODE_SHARED,
        STREAMFLAGS_EVENTCALLBACK,
        Int64(buffer_ms * REFTIMES_PER_MS),
        Int64(0),
        format_address,
        Int(0),
    )

    var buffer_frames = UInt32(0)
    _ = Com[StaticString("IAudioClient")](of=a.client).GetBufferSize(
        com_addr(buffer_frames)
    )

    # ── 6. The event ─────────────────────────────────────────────────────
    # Auto-reset, initially unsignalled. Windows sets it once per device
    # period once the stream is running; before Start it is never set, which
    # is why the first buffer has to be filled by hand.
    var create_event = win32[
        def (Int, Int32, Int32, Int) thin abi("C") -> Int, "CreateEventW"
    ]()
    var event = create_event(0, Int32(0), Int32(0), 0)
    if event == 0:
        raise Error("CreateEventW failed")
    _ = Com[StaticString("IAudioClient")](of=a.client).SetEventHandle(event)

    # ── 7. IAudioRenderClient ────────────────────────────────────────────
    # GetService, not QueryInterface: the render client is a service of an
    # *initialised* client, so this must come after Initialize.
    var iid_render = _guid_bytes(winkb_interface_iid["IAudioRenderClient"]())
    var render_address: Int = 0
    _ = Com[StaticString("IAudioClient")](of=a.client).GetService(
        iid_render.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        com_addr(render_address),
    )
    a.render = ComPtr[StaticString("IAudioRenderClient")](
        adopt=render_address
    )

    a.event = event
    a.rate = rate
    a.channels = channels
    a.frames = Int(buffer_frames)
    a.is_float = is_float
    a.open = True
    return a^


def describe(a: Audio) raises -> String:
    """One line naming the endpoint this stream landed on."""
    var id_address: Int = 0
    _ = Com[StaticString("IMMDevice")](of=a.device).GetId(com_addr(id_address))
    var id_text = String("")
    if id_address != 0:
        var w = OpaquePointer[MutUntrackedOrigin](
            unsafe_from_address=id_address
        ).unsafe_bitcast[UInt16]()
        var k = 0
        while w[unsafe_offset=k] != UInt16(0) and k < 256:
            id_text += chr(Int(w[unsafe_offset=k]))
            k += 1
        _ = win32[def (Int) thin abi("C") -> NoneType, "CoTaskMemFree"]()(
            id_address
        )
    return (
        String("WASAPI shared, ")
        + String(a.rate)
        + " Hz, "
        + String(a.channels)
        + " ch, "
        + (String("float32") if a.is_float else String("int16"))
        + ", ring "
        + String(a.frames)
        + " frames ("
        + String(a.frames * 1000 // a.rate)
        + " ms)  "
        + id_text
    )
