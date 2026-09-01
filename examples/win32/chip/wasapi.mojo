# ===----------------------------------------------------------------------=== #
# Sound out of Windows: the eight-step open, the mix format, and the loop with
# the deadline in it.
#
# This is where the port stops being a translation. CoreAudio hands you a
# render callback and calls it on a real-time thread it owns. WASAPI inverts
# that completely: nobody calls you. You are given a ring buffer and an event,
# and you ARE the thread -- wake, ask how much of the ring has drained, write
# exactly that much, sleep again. The deadline is the same deadline. The
# ownership of the thread is not.
#
# So the render callback does not survive as a callback, and pretending
# otherwise would be a worse port than admitting it. What survives is the
# function pointer: `run_stream` takes a `MonoFill` -- a thin C-ABI `def`,
# which in this dialect IS a C function pointer -- and calls it from inside
# the loop body, on the deadline, with nothing between it and the ring but a
# fan-out from mono to however many channels the mixer wants. The chip does
# not know what a WASAPI is; this file does not know what a chip is.
#
# Every slot, IID, constant and DLL name below is a query against
# windows_api.db. The single exception is the CLSID of the MMDeviceEnumerator
# coclass, and it is an exception for a recorded reason -- see below.
# ===----------------------------------------------------------------------=== #

from std.ffi import c_int
from std.memory import Pointer, OpaquePointer
from std.sys._com import ComPtr, _guid_bytes, com_addr
from std.sys._win32 import Win32Module
from std.sys._winkb import (
    winkb_constant,
    winkb_function_dll,
    winkb_interface_iid,
)
from std.sys.com import Com, co_create

from chip import P, PLAYER_BASE, get, put

# The metadata holds this name -- Windows.Win32.Media.Audio.MMDeviceEnumerator
# is in `types` -- but not its value: every guid-kind row in the database has
# a NULL value_text, coclass CLSIDs included. That is the recorded gap
# `std.sys.com.co_create` documents and `ide/screenshot.mojo` already lives
# with for WIC, so the same remedy applies: spell it once, next to the name it
# belongs to, and nowhere else in the program. It is the only hand-written
# Windows constant in this example.
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

# ── The stream's own slots ──────────────────────────────────────────────────
# The tail of the chip's block. The loop writes them and the window reads
# them; there is no lock, and there must not be one -- a torn read costs a
# wrong number on screen for one frame, where a held lock would cost a gap in
# the sound. Nothing here is read back by the loop, so nothing depends on the
# reader having seen it.

comptime ST_QUIT = PLAYER_BASE + 96  # the window asks the stream to stop
comptime ST_RUNNING = PLAYER_BASE + 97  # the stream says it is alive
comptime ST_WAKES = PLAYER_BASE + 98
comptime ST_UNDERRUNS = PLAYER_BASE + 99  # wakes that found the ring empty
comptime ST_GAP_US = PLAYER_BASE + 100  # last wake-to-wake gap
comptime ST_GAPMAX_US = PLAYER_BASE + 101
comptime ST_FILL_US = PLAYER_BASE + 102  # time inside the last fill
comptime ST_LOAD_PPM = PLAYER_BASE + 103  # fill as parts per thousand of gap
comptime ST_PEAK = PLAYER_BASE + 104  # endpoint peak meter x 10000
comptime ST_PEAKMAX = PLAYER_BASE + 105
comptime ST_FRAMES = PLAYER_BASE + 106
comptime ST_ERROR = PLAYER_BASE + 107
comptime ST_STALL_MS = PLAYER_BASE + 108  # a deliberate miss, for --stall

# What the chip is asked for: `frames` mono Float32 samples into `dest`.
comptime MonoFill = def (
    P, Pointer[Float32, MutUntrackedOrigin], Int
) thin abi("C") -> NoneType


def win32[Sig: TrivialRegisterPassable, name: StaticString]() raises -> Sig:
    """A Win32 entry point, typed, from whichever DLL the metadata names."""
    return Win32Module(String(winkb_function_dll[name]())).function[Sig](
        String(name)
    )


@fieldwise_init
struct MixFormat(Copyable, Movable):
    """What the shared mixer is already running at.

    In shared mode this is not a request, it is a statement: the engine has
    been running at this rate and this width since before the program started,
    and everything the synthesiser produces has to arrive in it.
    """

    var rate: Int
    var channels: Int
    var bits: Int
    var tag: Int
    var subformat_tag: Int
    var is_float: Bool
    var is_pcm16: Bool


def mix_format_address(client_address: Int) raises -> Int:
    """Step 4: ask the engine what it is already running at.

    The block comes back in CoTaskMem and is the caller's to free once
    Initialize has read it.
    """
    var address: Int = 0
    _ = Com[StaticString("IAudioClient")](borrowed=client_address).GetMixFormat(
        com_addr(address)
    )
    return address


def read_mix_format(address: Int) raises -> MixFormat:
    """Read a WAVEFORMATEX(TENSIBLE) block by looking rather than trusting.

    `winkb_struct_size["WAVEFORMATEX"]` is 20 and the SDK's `sizeof` is 18:
    mmreg.h wraps the whole family in `pshpack1` and the metadata records the
    unpacked reading. Two bytes moves every field of WAVEFORMATEXTENSIBLE, so
    `winkb_field_offset` is wrong for this one family and the sub-format is
    located by counting from the packed layout instead: Format 0..17,
    Samples 18, dwChannelMask 20, SubFormat 24.

    The first seven WAVEFORMATEX fields are at the same offsets either way,
    which is why those are read normally.
    """
    if address == 0:
        raise Error("GetMixFormat returned S_OK and a null format")
    var fmt = OpaquePointer[MutUntrackedOrigin](unsafe_from_address=address)
    var f16 = fmt.unsafe_bitcast[UInt16]()
    var f32 = fmt.unsafe_bitcast[UInt32]()
    var f8 = fmt.unsafe_bitcast[UInt8]()

    var tag = Int(f16[unsafe_offset=0])
    var channels = Int(f16[unsafe_offset=1])
    var rate = Int(f32[unsafe_offset=1])
    var bits = Int(f16[unsafe_offset=7])
    var cb_size = Int(f16[unsafe_offset=8])

    # KSDATAFORMAT_SUBTYPE_IEEE_FLOAT and _PCM are built by
    # DEFINE_WAVEFORMATEX_GUID(tag), so the GUID's Data1 IS the WAVE_FORMAT_*
    # tag. Reading that one u32 tells float from PCM with no hand-written GUID
    # anywhere -- compare it against the constants the metadata already has.
    var subformat_tag = 0
    if tag == WAVE_FORMAT_EXTENSIBLE and cb_size >= 22:
        subformat_tag = Int(
            UInt32(f8[unsafe_offset=24])
            | (UInt32(f8[unsafe_offset=25]) << 8)
            | (UInt32(f8[unsafe_offset=26]) << 16)
            | (UInt32(f8[unsafe_offset=27]) << 24)
        )

    var is_float = tag == WAVE_FORMAT_IEEE_FLOAT or (
        tag == WAVE_FORMAT_EXTENSIBLE and subformat_tag == WAVE_FORMAT_IEEE_FLOAT
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
    return MixFormat(
        rate, channels, bits, tag, subformat_tag, is_float, is_pcm16
    )


def open_enumerator() raises -> ComPtr[StaticString("IMMDeviceEnumerator")]:
    """Step 1: the device enumerator, by CLSID."""
    return co_create[CLSID_MMDeviceEnumerator, "IMMDeviceEnumerator"]()


def default_render_device(
    enumerator_address: Int,
) raises -> ComPtr[StaticString("IMMDevice")]:
    """Step 2: eRender/eConsole -- the speakers the user thinks of as the
    speakers."""
    var device_address: Int = 0
    _ = Com[StaticString("IMMDeviceEnumerator")](
        borrowed=enumerator_address
    ).GetDefaultAudioEndpoint(eRender, eConsole, com_addr(device_address))
    return ComPtr[StaticString("IMMDevice")](adopt=device_address)


def activate[iface: StaticString](device_address: Int) raises -> ComPtr[iface]:
    """Step 3: COM's other activation verb.

    Not "make me an instance of this class" but "give me this interface,
    implemented for this device". The IID comes from the metadata; the
    activation-parameters pointer is null.
    """
    var iid = _guid_bytes(winkb_interface_iid[iface]())
    var out_address: Int = 0
    _ = Com[StaticString("IMMDevice")](borrowed=device_address).Activate(
        iid.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        CLSCTX_ALL,
        Int(0),
        com_addr(out_address),
    )
    _ = iid
    return ComPtr[iface](adopt=out_address)


def endpoint_id(device_address: Int) raises -> String:
    """Which endpoint, so a run's output names the thing it played into."""
    var id_address: Int = 0
    _ = Com[StaticString("IMMDevice")](borrowed=device_address).GetId(
        com_addr(id_address)
    )
    var text = String("")
    if id_address != 0:
        var w = OpaquePointer[MutUntrackedOrigin](
            unsafe_from_address=id_address
        ).unsafe_bitcast[UInt16]()
        var k = 0
        while w[unsafe_offset=k] != UInt16(0) and k < 256:
            text += chr(Int(w[unsafe_offset=k]))
            k += 1
        co_task_free(id_address)
    return text^


def co_task_free(address: Int) raises:
    """The blocks GetMixFormat and GetId hand back are ours to free."""
    if address != 0:
        _ = win32[def (Int) thin abi("C") -> NoneType, "CoTaskMemFree"]()(
            address
        )


@fieldwise_init
struct Stream(Copyable, Movable):
    """An initialised client: the ring's size and the event it signals on."""

    var buffer_frames: Int
    var event: Int
    var default_period_us: Int
    var minimum_period_us: Int


def initialize_stream(
    client_address: Int, format_address: Int, buffer_ms: Int
) raises -> Stream:
    """Steps 5, 6 and 7: the device period, Initialize, and the event.

    Shared mode. Exclusive mode would give a lower latency floor and a format
    of our own choosing, at the price of evicting everything else on the
    endpoint -- wrong for an example somebody runs while music is playing.
    It is also not available with this format on this machine: both
    IsFormatSupported and Initialize answer AUDCLNT_E_UNSUPPORTED_FORMAT for
    the mix format in exclusive mode, so taking that road would mean writing a
    second, 16-bit output path as well.

    hnsPeriodicity MUST be zero in shared mode. hnsBufferDuration is a floor,
    not an exact request: the engine rounds up to a whole number of periods,
    and its own minimum here is 22 ms however small a number it is given.

    AUDCLNT_STREAMFLAGS_EVENTCALLBACK and SetEventHandle are one decision, not
    two. The flag without the handle is AUDCLNT_E_EVENTHANDLE_NOT_SET at
    Start; the handle without the flag is AUDCLNT_E_EVENTHANDLE_NOT_EXPECTED
    at SetEventHandle.
    """
    var ac = Com[StaticString("IAudioClient")](borrowed=client_address)

    var default_period = Int64(0)
    var minimum_period = Int64(0)
    _ = ac.GetDevicePeriod(com_addr(default_period), com_addr(minimum_period))

    _ = ac.Initialize(
        SHAREMODE_SHARED,
        STREAMFLAGS_EVENTCALLBACK,
        Int64(buffer_ms * REFTIMES_PER_MS),
        Int64(0),
        format_address,
        Int(0),
    )

    var buffer_frames = UInt32(0)
    _ = ac.GetBufferSize(com_addr(buffer_frames))

    # Auto-reset, initially unsignalled. Windows sets it once per device
    # period once the stream is running; before Start it is never set, which
    # is why the first buffer has to be filled by hand.
    var create_event = win32[
        def (Int, Int32, Int32, Int) thin abi("C") -> Int, "CreateEventW"
    ]()
    var event = create_event(0, Int32(0), Int32(0), 0)
    if event == 0:
        raise Error("CreateEventW failed")
    _ = ac.SetEventHandle(event)

    return Stream(
        Int(buffer_frames),
        event,
        Int(default_period) // 10,
        Int(minimum_period) // 10,
    )


def render_client(
    client_address: Int,
) raises -> ComPtr[StaticString("IAudioRenderClient")]:
    """Step 8. GetService, not QueryInterface: the render client is a service
    of an *initialised* client, so this must come after Initialize."""
    var iid = _guid_bytes(winkb_interface_iid["IAudioRenderClient"]())
    var out_address: Int = 0
    _ = Com[StaticString("IAudioClient")](borrowed=client_address).GetService(
        iid.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        com_addr(out_address),
    )
    _ = iid
    return ComPtr[StaticString("IAudioRenderClient")](adopt=out_address)


@always_inline
def _spread(
    mono: Pointer[Float32, MutUntrackedOrigin],
    destination: Int,
    frames: Int,
    channels: Int,
    is_float: Bool,
):
    """One mono voice into every channel of an interleaved buffer.

    The chip is a mono part -- a 6581 had one output pin -- and the mixer
    wants two channels here and might want eight somewhere else. Copying the
    same sample into each is the honest answer; panning three voices across a
    stereo field would be inventing something the machine never did.
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
            var v = Int16(Float64(mono[unsafe_offset=i]) * 32767.0)
            for c in range(channels):
                out[unsafe_offset = i * channels + c] = v


def run_stream(
    st: P,
    client_address: Int,
    render_address: Int,
    meter_address: Int,
    stream: Stream,
    fmt: MixFormat,
    mono_address: Int,
    fill: MonoFill,
) raises:
    """Pre-roll, Start, wake-fill-release until asked to stop, Stop.

    This is the whole of the deadline. Everything it touches was allocated
    before Start; there is no allocation, no lock and no I/O in the loop, and
    the only thing it calls that computes anything is `fill`, which is a
    non-raising C function pointer.

    It is `raises` all the same, and that is not a contradiction. Every COM
    call in here can report a stream that has gone away -- the device
    unplugged, the session disconnected -- and the right answer to that is to
    leave, not to keep writing into a ring nobody owns. What may not raise is
    the arithmetic that produces samples, and it does not: `fill` and
    everything under it are declared without `raises` and the compiler holds
    them to it.
    """
    var ac = Com[StaticString("IAudioClient")](borrowed=client_address)
    var rc = Com[StaticString("IAudioRenderClient")](borrowed=render_address)

    var wait = win32[
        def (Int, UInt32) thin abi("C") -> UInt32, "WaitForSingleObject"
    ]()
    var sleep_ms = win32[def (UInt32) thin abi("C") -> NoneType, "Sleep"]()
    var qpc = win32[
        def (Pointer[Int64, MutAnyOrigin]) thin abi("C") -> c_int,
        "QueryPerformanceCounter",
    ]()
    var qpf = win32[
        def (Pointer[Int64, MutAnyOrigin]) thin abi("C") -> c_int,
        "QueryPerformanceFrequency",
    ]()
    var freq = Int64(1)
    _ = qpf(com_addr(freq))
    var ticks_per_us = Float64(Int(freq)) / 1_000_000.0

    var mono = Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=mono_address
    )
    var frames = stream.buffer_frames

    # Prime the whole ring before Start. Starting on silence is a guaranteed
    # underrun on the first period, and an underrun in shared mode is not an
    # error -- the engine simply mixes whatever stale contents the ring has,
    # which is an audible tick.
    var first_address: Int = 0
    _ = rc.GetBuffer(UInt32(frames), com_addr(first_address))
    fill(st, mono, frames)
    _spread(mono, first_address, frames, fmt.channels, fmt.is_float)
    _ = rc.ReleaseBuffer(UInt32(frames), UInt32(0))
    put(st, ST_FRAMES, frames)

    _ = ac.Start()
    put(st, ST_RUNNING, 1)

    var last = Int64(0)
    _ = qpc(com_addr(last))

    while get(st, ST_QUIT) == 0:
        # Twice the ring is a generous ceiling: if the event has not arrived
        # by then the stream is gone and hanging forever is the wrong answer.
        var timeout = UInt32(
            2 * (frames * 1000 // fmt.rate) + 200
        )
        var status = wait(stream.event, timeout)
        if status != WAIT_OBJECT_0:
            put(st, ST_ERROR, Int(status) + 1)
            break

        var now = Int64(0)
        _ = qpc(com_addr(now))
        var gap_us = Int(Float64(Int(now) - Int(last)) / ticks_per_us)
        last = now
        put(st, ST_WAKES, get(st, ST_WAKES) + 1)
        put(st, ST_GAP_US, gap_us)
        if gap_us > get(st, ST_GAPMAX_US):
            put(st, ST_GAPMAX_US, gap_us)

        # Ask the endpoint, not ourselves, whether sound is happening. This is
        # the machine's own answer, independent of anything this program
        # believes about its buffers.
        if meter_address != 0:
            var peak = Float32(0.0)
            _ = Com[StaticString("IAudioMeterInformation")](
                borrowed=meter_address
            ).GetPeakValue(com_addr(peak))
            var scaled = Int(Float64(peak) * 10000.0)
            put(st, ST_PEAK, scaled)
            if scaled > get(st, ST_PEAKMAX):
                put(st, ST_PEAKMAX, scaled)

        # A deliberate miss, once, to see what starvation looks like from the
        # inside. The answer is: silent. Every call still returns S_OK.
        var stall = get(st, ST_STALL_MS)
        if stall > 0:
            put(st, ST_STALL_MS, 0)
            sleep_ms(UInt32(stall))

        # How much has drained since the last wake. This is the whole
        # contract: write exactly the free space, never more.
        var padding = UInt32(0)
        _ = ac.GetCurrentPadding(com_addr(padding))
        var available = frames - Int(padding)
        if available <= 0:
            continue
        if Int(padding) == 0:
            # The ring ran dry between wakes. Nothing else reports this --
            # GetBuffer, ReleaseBuffer and Start all still say S_OK -- so a
            # zero here is the only evidence an underrun leaves.
            put(st, ST_UNDERRUNS, get(st, ST_UNDERRUNS) + 1)

        var data_address: Int = 0
        _ = rc.GetBuffer(UInt32(available), com_addr(data_address))

        var t0 = Int64(0)
        _ = qpc(com_addr(t0))
        fill(st, mono, available)
        _spread(mono, data_address, available, fmt.channels, fmt.is_float)
        var t1 = Int64(0)
        _ = qpc(com_addr(t1))

        _ = rc.ReleaseBuffer(UInt32(available), UInt32(0))
        put(st, ST_FRAMES, get(st, ST_FRAMES) + available)

        var fill_us = Int(Float64(Int(t1) - Int(t0)) / ticks_per_us)
        put(st, ST_FILL_US, fill_us)
        # The number that says whether this is close to the edge: the fill,
        # as a fraction of the time the device gave us to do it in.
        if gap_us > 0:
            put(st, ST_LOAD_PPM, fill_us * 1000 // gap_us)

    # Let the tail of the ring reach the speaker before Stop truncates it.
    var drained = 0
    while drained < 64:
        var padding = UInt32(0)
        _ = ac.GetCurrentPadding(com_addr(padding))
        if Int(padding) == 0:
            break
        sleep_ms(UInt32(2))
        drained += 1

    _ = ac.Stop()
    put(st, ST_RUNNING, 0)
