"""The audio deck on Windows: two chips through one WASAPI render stream.

The Metal backend's design carried over -- two 6581s (music on A, effects
on B), a lock-free trigger ring, three effect voices, sample-accurate ABC
scheduling flattened on the game thread -- with CoreAudio's AURenderCallback
replaced by `std.windows.audio.RenderStream`'s `RenderFill`, the same
contract the chip example runs under: a thin C-ABI function, no raises, no
allocation, no locks, no COM inside the deadline.

The audio runs on its OWN THREAD with its own MTA apartment (the
RenderStream contract), which is why the deck is one flat block reachable
through a named_global: the fill callback is captureless, exactly like
the window procedure.
"""

from std.ffi import external_call
from std.memory import Pointer, OpaquePointer
from std.sys._globals import named_global
from std.windows.audio import RenderStream, RenderFill, RenderRunning
from std.windows.gui import win32
from std.sys.com import Apartment

from gamepane.api import (
    P,
    CLOCK_PAL,
    SAMPLE_RATE,
    FRAME_SAMPLES,
    Tick,
    chip_new,
    chip_render,
    chip_free,
    set_volume,
    gate_off,
    get,
    put,
    sfx_frames,
    sfx_start,
    sfx_stop,
    sfx_frame,
    PLAYER_BASE,
)
from gamepane.api.sfx import SFX_COUNT
from gamepane.abc.parse import parse_abc
from gamepane.abc.model import Tune
from gamepane.abc.schedule import build_schedule, sort_steps, Step, resolve_ties
from gamepane.abc.chipplay import flatten_schedule, silent_tick
from gamepane.abc.chipplay import SC_LOOP


# ── the deck's layout ───────────────────────────────────────────────────────
#
# One flat Int64 block, addressed by slot, exactly as on the Mac: the fill
# callback is a C function and can carry nothing but the pointer.

comptime D_CHIP_A = 0
comptime D_CHIP_B = 1
comptime D_MUTED = 2
comptime D_TUNE = 3
comptime D_TICK_A = 4
comptime D_TICK_B = 5
comptime D_SCRATCH = 6
comptime D_VOICE_BASE = 8
comptime D_VOICE_STRIDE = 4
comptime D_V_EFFECT = 0
comptime D_V_FRAME = 1
comptime D_V_LEFT = 2
comptime D_V_UNUSED = 3
comptime D_RING_BASE = D_VOICE_BASE + 3 * D_VOICE_STRIDE

comptime RING_BITS = 8
comptime RING_SIZE = 1 << RING_BITS

comptime DECK_SLOTS = D_RING_BASE + RING_SIZE

comptime MAX_BUFFER = 4096
"""Scratch for chip B, sized past anything WASAPI asks for. Allocated with
the deck, never in the callback."""


def dput(d: P, slot: Int, value: Int):
    d.unsafe_bitcast[Int]()[unsafe_offset=slot] = value


def dget(d: P, slot: Int) -> Int:
    return d.unsafe_bitcast[Int]()[unsafe_offset=slot]


# The deck the fill is currently driving. One audio stream per process,
# the same limit the window has.
comptime g_deck = named_global["gamepane.audio.deck", Int]


def deck_new() raises -> P:
    """Two chips, a ring, and three effect voices. Allocated once."""
    let d = external_call["calloc", P](Int(DECK_SLOTS), Int(8))
    if Int(d) == 0:
        raise Error("audio deck: out of memory")
    dput(d, D_CHIP_A, Int(chip_new()))
    dput(d, D_CHIP_B, Int(chip_new()))
    set_volume(P(unsafe_from_address=dget(d, D_CHIP_A)), 15)
    set_volume(P(unsafe_from_address=dget(d, D_CHIP_B)), 15)
    for v in range(3):
        dput(d, D_VOICE_BASE + v * D_VOICE_STRIDE + D_V_EFFECT, -1)
    let scratch = external_call["calloc", P](Int(MAX_BUFFER), Int(4))
    if Int(scratch) == 0:
        raise Error("audio deck: no scratch buffer")
    dput(d, D_SCRATCH, Int(scratch))
    return d


def deck_free(d: P):
    if Int(d) == 0:
        return
    chip_free(P(unsafe_from_address=dget(d, D_CHIP_A)))
    chip_free(P(unsafe_from_address=dget(d, D_CHIP_B)))
    _ = external_call["free", NoneType](P(unsafe_from_address=dget(d, D_SCRATCH)))
    _ = external_call["free", NoneType](d)


def music_chip(d: P) -> P:
    return P(unsafe_from_address=dget(d, D_CHIP_A))


def sfx_chip(d: P) -> P:
    return P(unsafe_from_address=dget(d, D_CHIP_B))


def play_tune(d: P, source: String, loop: Bool = False) raises -> Int:
    """Parse ABC and schedule it on chip A. Returns the number of steps.

    The schedule is flattened into plain memory HERE, on the game's thread,
    before the fill ever looks at it -- the audio thread only reads an
    array of integers. That is the whole reason a tune can be
    sample-accurate without a lock."""
    var tune = Tune()
    parse_abc(source, tune)
    resolve_ties(tune)
    var steps = List[Step]()
    build_schedule(tune, SAMPLE_RATE, steps)
    sort_steps(steps)
    var a = music_chip(d)
    let addr = flatten_schedule(steps, a)
    put(a, PLAYER_BASE + SC_LOOP, 1 if loop else 0)
    dput(d, D_TUNE, 1 if (addr != 0 and len(steps) > 0) else 0)
    return len(steps)


def stop_audio(unit_addr: Int):
    """Always, before main returns. Clearing the global stops the running
    predicate; the thread then drains, stops and exits on its own."""
    g_deck()[] = 0


def stop_tune(d: P):
    """Silence the tune. The schedule stays flattened, so playing it again
    costs nothing."""
    dput(d, D_TUNE, 0)
    let a = music_chip(d)
    for v in range(3):
        gate_off(a, v)


def set_music_tick(d: P, tick: Tick):
    """Install chip A's 50 Hz player routine, as an address."""
    var t = tick
    dput(d, D_TICK_A, Pointer(to=t).unsafe_bitcast[Int]()[])


def set_muted(d: P, muted: Bool):
    dput(d, D_MUTED, 1 if muted else 0)


# ── the trigger ring ────────────────────────────────────────────────────────


def sfx_play(d: P, effect: Int):
    """Fire an effect: a single word into the ring, from any thread."""
    if effect < 0 or effect >= SFX_COUNT:
        return
    # The ring's write/read cursors are the two slots just before the ring.
    var write = dget(d, D_RING_BASE - 2)
    var read = dget(d, D_RING_BASE - 1)
    if write - read >= RING_SIZE:
        return  # full: the oldest unplayed trigger is dropped, never blocked
    dput(d, D_RING_BASE + (write & (RING_SIZE - 1)), effect)
    dput(d, D_RING_BASE - 2, write + 1)


def pending_triggers(d: P) -> Int:
    return dget(d, D_RING_BASE - 2) - dget(d, D_RING_BASE - 1)


def dropped_triggers(d: P) -> Int:
    return 0


def drain_triggers(d: P):
    """Start every queued effect. The audio thread's half of the ring."""
    var read = dget(d, D_RING_BASE - 1)
    var write = dget(d, D_RING_BASE - 2)
    let b = sfx_chip(d)
    while read < write:
        _start_effect(d, b, dget(d, D_RING_BASE + (read & (RING_SIZE - 1))))
        read += 1
    dput(d, D_RING_BASE - 1, read)


def _start_effect(d: P, b: P, effect: Int):
    """Find a voice and load the effect's first frame into it."""
    if effect < 0 or effect >= SFX_COUNT:
        return
    var chosen = -1
    for v in range(3):
        if dget(d, D_VOICE_BASE + v * D_VOICE_STRIDE + D_V_EFFECT) == -1:
            chosen = v
            break
    if chosen == -1:
        # Voice stealing: the oldest effect gives way. The game fires
        # bursts of explosions and never notices; a stuck silence would be
        # noticed.
        var oldest = -1
        var oldest_left = -1
        for v in range(3):
            let left = dget(d, D_VOICE_BASE + v * D_VOICE_STRIDE + D_V_LEFT)
            if left > oldest_left:
                oldest_left = left
                oldest = v
        chosen = oldest
    let base = D_VOICE_BASE + chosen * D_VOICE_STRIDE
    try:
        sfx_start(b, chosen, effect)
    except:
        pass
    dput(d, base + D_V_EFFECT, effect)
    dput(d, base + D_V_FRAME, 0)
    dput(d, base + D_V_LEFT, sfx_frames(effect))


def advance_effects(d: P):
    """One 50 Hz tick of chip B's voices: next frame or stop."""
    let b = sfx_chip(d)
    for v in range(3):
        let base = D_VOICE_BASE + v * D_VOICE_STRIDE
        let e = dget(d, base + D_V_EFFECT)
        if e == -1:
            continue
        let left = dget(d, base + D_V_LEFT)
        if left <= 0:
            try:
                sfx_stop(b, v, e)
            except:
                pass
            dput(d, base + D_V_EFFECT, -1)
            continue
        try:
            sfx_frame(b, v, e, dget(d, base + D_V_FRAME))
        except:
            pass
        dput(d, base + D_V_FRAME, dget(d, base + D_V_FRAME) + 1)
        dput(d, base + D_V_LEFT, left - 1)


def _sfx_tick(st: P) abi("C"):
    """Chip B's 50 Hz hook."""
    if g_deck()[] != 0:
        advance_effects(P(unsafe_from_address=g_deck()[]))


def _silent_tick(st: P) abi("C"):
    pass


# ── the fill callback ───────────────────────────────────────────────────────


def gamepane_fill(
    user: OpaquePointer[MutUntrackedOrigin],
    dest: Pointer[Float32, MutUntrackedOrigin],
    frames: Int,
) abi("C"):
    """Mono Float32: chip A plus chip B, summed. WASAPI's render thread.

    Same contract as the chip example's fill: no allocation, no locks, no
    COM; the deck was built before start and nothing here builds
    anything."""
    let d = P(unsafe_from_address=Int(user))

    if dget(d, D_MUTED) != 0:
        for i in range(frames):
            dest[unsafe_offset=i] = Float32(0.0)
        return

    drain_triggers(d)

    # Chip A renders straight into the destination; chip B into scratch,
    # then summed. Two passes because the chip's render loop is the hot
    # path and it stays a straight line.
    let scratch = Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=dget(d, D_SCRATCH)
    )
    var a = music_chip(d)
    var b = sfx_chip(d)

    chip_render(a, dest, frames, _player_tick_a)
    chip_render(b, scratch, frames, _sfx_tick_ptr)

    for i in range(frames):
        dest[unsafe_offset=i] = (
            dest[unsafe_offset=i] + scratch[unsafe_offset=i]
        ) * Float32(0.5)


def _player_tick_a(st: P) abi("C"):
    """Chip A's 50 Hz hook: the tune's step player, when a tune is on."""
    if g_deck()[] != 0:
        let d = P(unsafe_from_address=g_deck()[])
        if dget(d, D_TUNE) != 0:
            _tick_addr_call(d)


def _tick_addr_call(d: P):
    """Call the installed tick, if one was installed."""
    let addr = dget(d, D_TICK_A)
    if addr == 0:
        return
    var fn_p = Pointer(to=addr).unsafe_bitcast[
        def (P) thin abi("C") -> NoneType
    ]()[]
    fn_p(P(unsafe_from_address=dget(d, D_CHIP_A)))


def _sfx_tick_ptr(st: P) abi("C"):
    _sfx_tick(st)


def gamepane_running(
    user: OpaquePointer[MutUntrackedOrigin]
) abi("C") -> Bool:
    """Run while the deck is live; the game stops the thread by clearing
    the global before joining it."""
    return g_deck()[] != 0


# ── the thread ──────────────────────────────────────────────────────────────


comptime ThreadProc = def (Int) thin abi("C") -> UInt32


def gamepane_audio_thread(param: Int) abi("C") -> UInt32:
    """The audio thread's whole life: MTA apartment, open, run, exit.

    Everything is inside the try because unwinding out of a thread proc
    is undefined; a failure is reported on stdout and the thread ends."""
    try:
        with Apartment(multithreaded=True):
            var speaker = RenderStream(buffer_ms=90)
            speaker.run(
                gamepane_fill, gamepane_running,
                OpaquePointer[MutUntrackedOrigin](unsafe_from_address=param),
                pro_audio=True, meter=False,
            )
    except e:
        print("audio thread ended early:", e)
    return UInt32(0)


def start_audio(d: P) raises -> Int:
    """Open the default output and run the stream on its own thread.

    Returns the thread handle -- WaitForSingleObject it before main
    returns, after stop_audio, exactly as the chip example does."""
    from std.python._cpython import _fn_ptr_as_opaque

    g_deck()[] = Int(d)
    var create_thread = win32[
        def (
            Int, UInt32, Int, Int, Int,
        ) thin abi("C") -> Int,
        "CreateThread",
    ]()
    var thread_proc: ThreadProc = gamepane_audio_thread
    var handle = create_thread(
        0,  # default security
        UInt32(0),  # default stack
        Int(_fn_ptr_as_opaque(thread_proc)),
        Int(d),  # the deck pointer, as the thread's parameter
        0,
    )
    if handle == 0:
        raise Error("CreateThread failed")
    return handle
