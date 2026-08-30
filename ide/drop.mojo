"""Drop a file on Griddle and it opens.

The dogfood moment, and the reason the compiler's C3 milestone was named
after a drop target months before this window existed. The IDE implements
`IDropTarget` with the `class` keyword this repository added to Mojo, hands
the object to OLE, and Windows holds a reference to it across the process
boundary. Everything under it -- the vtable in metadata slot order, the
atomic refcount, the IID-checking QueryInterface, the trampolines that turn
a raising Mojo method into an HRESULT -- is the language work being used
rather than demonstrated.

    class DropTarget(IDropTarget):
        var drops: Int
        ...
        def Drop(mut self, data, key, pt, effect) raises:
            ...

That is the whole declaration. There is no vtable arithmetic here, no
QueryInterface to write, and no place for a slot to be off by one.
"""

from std.ffi import c_int
from std.os import getenv
from std.memory import OpaquePointer, Pointer
from std.sys.info import size_of
from std.sys._com import ComPtr, com_addr, com_method_of
from std.sys._winkb import winkb_constant, winkb_struct_size

from ide.win32 import win32


comptime DROPEFFECT_NONE = UInt32(0)
comptime DROPEFFECT_COPY = UInt32(1)

# Where a dropped path is left for the rest of the IDE to read. The drop
# callbacks are reached through a C-ABI vtable and cannot hand a String back
# up the stack, so the path goes somewhere the status line and the agent can
# both find it. A file, because the editor is not built yet and this is the
# smallest thing that is honest about where the value lives.
comptime DROP_RECORD = StaticString("griddle-drop.txt")


@fieldwise_init
struct FORMATETC(Defaultable, ImplicitlyCopyable, Movable):
    """What a data object is being asked for."""

    var cfFormat: UInt16
    var ptd: Int
    var dwAspect: UInt32
    var lindex: Int32
    var tymed: UInt32

    def __init__(out self):
        """An empty request."""
        self.cfFormat = 0
        self.ptd = 0
        self.dwAspect = 0
        self.lindex = 0
        self.tymed = 0


@fieldwise_init
struct STGMEDIUM(Defaultable, ImplicitlyCopyable, Movable):
    """What a data object answered with.

    Windows says this is 32 bytes, which the compile-time check caught: the
    obvious reading -- a tag, a handle and a release pointer -- gives 24, and
    would have had Windows writing past the end of a struct that looked
    right. The union in the middle is wider than one pointer in the SDK's own
    description of itself, so the tail is declared as reserved space rather
    than guessed at. Only `tymed` and the handle are read here, and both sit
    where the C layout puts them.
    """

    var tymed: UInt32
    var _pad: UInt32
    var handle: Int
    var pUnkForRelease: Int
    var _reserved: Int

    def __init__(out self):
        """Nothing yet."""
        self.tymed = 0
        self._pad = 0
        self.handle = 0
        self.pUnkForRelease = 0
        self._reserved = 0


def paths_from(data_object: Int) raises -> String:
    """The file paths inside a drop, as newline-separated text.

    Windows delivers a drag as an `IDataObject`; the shell's file format is
    `CF_HDROP`, a global handle `DragQueryFileW` reads names out of. An empty
    answer is normal -- a drag of something that is not files -- and is not
    an error.

    Args:
        data_object: The dragged data, or zero when there is none.

    Returns:
        One path per line, or an empty string.

    Raises:
        If the medium cannot be released.
    """
    if data_object == 0:
        return String("")

    comptime assert (
        size_of[FORMATETC]() == winkb_struct_size["FORMATETC"]()
    ), "FORMATETC does not match Windows"
    comptime assert (
        size_of[STGMEDIUM]() == winkb_struct_size["STGMEDIUM"]()
    ), "STGMEDIUM does not match Windows"

    var fmt = FORMATETC()
    fmt.cfFormat = UInt16(winkb_constant["CF_HDROP"]())
    fmt.dwAspect = UInt32(winkb_constant["DVASPECT_CONTENT"]())
    fmt.lindex = -1
    fmt.tymed = UInt32(winkb_constant["TYMED_HGLOBAL"]())

    var medium = STGMEDIUM()
    var this = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=data_object
    )
    var hr = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Pointer[FORMATETC, MutAnyOrigin],
            Pointer[STGMEDIUM, MutAnyOrigin],
        ) thin abi("C") -> Int32,
        "IDataObject",
        "GetData",
    ](this)(this, com_addr(fmt), com_addr(medium))
    _ = fmt
    if hr != 0 or medium.handle == 0:
        return String("")

    # The buffer is an Int rather than a Pointer because asking for the
    # count passes null, and Mojo's Pointer is non-nullable by construction.
    var DragQueryFileW = win32[
        def (Int, UInt32, Int, UInt32) thin abi("C") -> UInt32,
        "DragQueryFileW",
    ]()
    # Asking for index 0xFFFFFFFF answers the count rather than a name.
    var count = Int(
        DragQueryFileW(
            medium.handle,
            UInt32(0xFFFFFFFF),
            0,
            UInt32(0),
        )
    )

    var out = String("")
    var buffer = List[UInt16]()
    for _ in range(1024):
        buffer.append(0)
    for i in range(count):
        var n = Int(
            DragQueryFileW(
                medium.handle,
                UInt32(i),
                Int(buffer.unsafe_ptr()),
                UInt32(1024),
            )
        )
        for k in range(n):
            out += chr(Int(buffer[k]))
        out += "\n"

    var ReleaseStgMedium = win32[
        def (
            Pointer[STGMEDIUM, MutAnyOrigin]
        ) thin abi("C") -> NoneType,
        "ReleaseStgMedium",
    ]()
    _ = ReleaseStgMedium(com_addr(medium))
    _ = medium
    return out


def record(text: String) raises:
    """Leave a drop where the status line and the agent can read it."""
    var dir = String(".")
    try:
        var tmp = getenv("TEMP")
        if tmp.byte_length() > 0:
            dir = tmp
    except:
        pass
    with open(dir + "\\" + String(DROP_RECORD), "w") as f:
        f.write(text)


def last() -> String:
    """Whatever was dropped most recently, or an empty string."""
    try:
        var dir = String(".")
        var tmp = getenv("TEMP")
        if tmp.byte_length() > 0:
            dir = tmp
        with open(dir + "\\" + String(DROP_RECORD), "r") as f:
            return f.read()
    except:
        return String("")


# ===----------------------------------------------------------------------===#
# The drop target itself
#
# Written in the language this repository built. Compare spikes/com/s10,
# where the same object is assembled by hand out of raw function pointers
# and vtable words: that is what the compiler now emits from these lines.
# ===----------------------------------------------------------------------===#


class DropTarget(IDropTarget):
    var drops: Int
    var enters: Int

    def DragEnter(
        mut self, data: Int, key: UInt32, pt: Int, effect: Int
    ) raises:
        self.enters += 1
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=effect)[] = (
            DROPEFFECT_COPY
        )

    def DragOver(mut self, key: UInt32, pt: Int, effect: Int) raises:
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=effect)[] = (
            DROPEFFECT_COPY
        )

    def DragLeave(mut self) raises:
        pass

    def Drop(mut self, data: Int, key: UInt32, pt: Int, effect: Int) raises:
        self.drops += 1
        var paths = paths_from(data)
        if paths.byte_length() > 0:
            record(paths)
        else:
            # A drag carrying no files still happened; say so rather than
            # leaving the previous drop's paths looking like this one's.
            record(String("(a drop carrying no file paths)\n"))
        Pointer[UInt32, MutAnyOrigin](unsafe_from_address=effect)[] = (
            DROPEFFECT_COPY
        )


def register(hwnd: Int) raises -> ComPtr[StaticString("IDropTarget")]:
    """Hand a drop target to OLE for this window.

    The returned pointer must be kept: OLE holds its own reference, but
    dropping ours would leave the object owned solely by the drag subsystem.

    Args:
        hwnd: The window that accepts drops.

    Returns:
        Our reference to the target.

    Raises:
        If OLE refuses the registration.
    """
    var target = DropTarget(0, 0).into_com()
    var RegisterDragDrop = win32[
        def (Int, Int) thin abi("C") -> Int32, "RegisterDragDrop"
    ]()
    var hr = RegisterDragDrop(hwnd, target.address())
    if hr != 0:
        raise Error("RegisterDragDrop failed, hr = " + String(hr))
    return target^


def revoke(hwnd: Int) raises:
    """Take the drop target back before the window goes away."""
    var RevokeDragDrop = win32[
        def (Int) thin abi("C") -> Int32, "RevokeDragDrop"
    ]()
    _ = RevokeDragDrop(hwnd)


def simulate(target: Int) raises -> String:
    """Drive a drop target through its own vtable, as OLE's proxy would.

    The same shape as `spikes/com/s10`: the object's methods are reached at
    the slots the metadata records, with a null data object standing in for
    a real drag. What this proves is that the object Windows holds is live
    and dispatches correctly, and that its callbacks run and record. What it
    cannot prove is the path extraction, because only Explorer supplies a
    real `IDataObject` -- that half is a manual drag, documented as one.

    Args:
        target: The drop target's interface pointer.

    Returns:
        What happened, as text.

    Raises:
        If a call fails.
    """
    if target == 0:
        return String("error: no drop target registered")

    var this = OpaquePointer[MutUntrackedOrigin](unsafe_from_address=target)

    # Ask the object how many references it has, without keeping one: OLE
    # holds one and we hold one, so two is the proof Windows took it.
    var up = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> UInt32,
        "IUnknown",
        "AddRef",
    ](this)(this)
    _ = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> UInt32,
        "IUnknown",
        "Release",
    ](this)(this)
    var refs = Int(up) - 1

    var effect = UInt32(0)
    var enter = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            UInt32,
            Int,
            Pointer[UInt32, MutAnyOrigin],
        ) thin abi("C") -> Int32,
        "IDropTarget",
        "DragEnter",
    ](this)(this, 0, UInt32(0), 0, com_addr(effect))

    var drop_effect = UInt32(0)
    var dropped = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            UInt32,
            Int,
            Pointer[UInt32, MutAnyOrigin],
        ) thin abi("C") -> Int32,
        "IDropTarget",
        "Drop",
    ](this)(this, 0, UInt32(0), 0, com_addr(drop_effect))

    return (
        String("refcount=") + String(refs)
        + " (2 = ours + OLE's)  DragEnter hr=" + String(enter)
        + " effect=" + String(effect)
        + "  Drop hr=" + String(dropped)
        + " effect=" + String(drop_effect)
        + "  recorded: " + String(last().strip())
    )
