# QueryInterface answers for an interface's BASES, not only for itself.
#
# COM interfaces inherit: IStream derives from ISequentialStream, which
# derives from IUnknown. A client handed an IStream may legitimately ask it
# for ISequentialStream -- that is the whole point of the base -- and an
# object that answers E_NOINTERFACE there is broken in a way that only shows
# up against a client written by someone else.
#
# The layout makes this nearly free: a base's vtable is a PREFIX of the
# derived one, so the same cell pointer already satisfies the base, and only
# the accepted-IID table needs the extra entries. They come from one metadata
# query for the whole chain, so the inheritance depth need not be known.
#
# ISequentialStream's Read/Write occupy the same slots in IStream's vtable,
# so a call made through the base pointer reaches the same implementation.

from std.memory import Pointer, OpaquePointer
from std.sys._com import ComPtr, com_method_of, _guid_bytes
from std.sys.com import ComClassBuilder
from std.sys._winkb import winkb_interface_iid

comptime QI_SIG = def (
    OpaquePointer[MutUntrackedOrigin], Int, Int
) thin abi("C") -> Int32
comptime UNK_SIG = def (
    OpaquePointer[MutUntrackedOrigin]
) thin abi("C") -> UInt32


@fieldwise_init
struct MemStream(Movable, Deinitable):
    var reads: Int

    def Read(mut self, pv: Int, cb: UInt32, got: Int) raises:
        self.reads += 1
        if got != 0:
            Pointer[UInt32, MutAnyOrigin](unsafe_from_address=got)[] = UInt32(0)


def build() raises -> ComPtr[StaticString("IStream")]:
    var b = ComClassBuilder["IStream"]()
    b.method["Read", MemStream.Read]()
    # Everything else this object does not do, declined visibly rather than
    # left as a hole: the point here is QueryInterface, not a real stream.
    b.notimpl["Write"]()
    b.notimpl["Seek"]()
    b.notimpl["SetSize"]()
    b.notimpl["CopyTo"]()
    b.notimpl["Commit"]()
    b.notimpl["Revert"]()
    b.notimpl["LockRegion"]()
    b.notimpl["UnlockRegion"]()
    b.notimpl["Stat"]()
    b.notimpl["Clone"]()
    return b^.finish_state(MemStream(0))


def query[iface: StaticString](p: Int) raises -> Int:
    var iid = _guid_bytes(String(winkb_interface_iid[iface]()))
    var out = Int(0)
    var hr = com_method_of[QI_SIG, "IUnknown", "QueryInterface"](
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=p)
    )(
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=p),
        Int(iid.unsafe_ptr()),
        Int(Pointer(to=out)),
    )
    _ = iid
    if hr != 0:
        raise Error(
            "QueryInterface refused " + String(iface) + " (hr " + String(hr)
            + "): an object must answer for the interfaces it inherits"
        )
    return out


def main() raises:
    var obj = build()
    var primary = obj.address()
    print("built an IStream-shaped object")

    # The base, two levels down the chain from nothing: IStream -> ISeqStream.
    var seq = query["ISequentialStream"](primary)
    print("QI(ISequentialStream) succeeded, same pointer:", seq == primary)

    # A base's vtable is a prefix, so the base pointer is the same pointer --
    # and Read, declared by ISequentialStream, is reachable through it.
    var got = UInt32(0)
    var hr = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int, UInt32,
            Pointer[UInt32, MutAnyOrigin],
        ) thin abi("C") -> Int32,
        "ISequentialStream",
        "Read",
    ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=seq))(
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=seq),
        0,
        UInt32(0),
        Pointer(to=got).unsafe_origin_cast[MutAnyOrigin](),
    )
    print("Read through the base interface: hr", hr)
    if hr != 0:
        raise Error("the base pointer did not dispatch to the implementation")

    var unk = query["IUnknown"](primary)
    print("IUnknown still resolves:", unk != 0)

    _ = com_method_of[UNK_SIG, "IUnknown", "Release"](
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=seq)
    )(OpaquePointer[MutUntrackedOrigin](unsafe_from_address=seq))
    _ = com_method_of[UNK_SIG, "IUnknown", "Release"](
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=unk)
    )(OpaquePointer[MutUntrackedOrigin](unsafe_from_address=unk))
    _ = obj

    print("S18 PASS -- QueryInterface answers for inherited interfaces")
