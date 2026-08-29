# GUID text to bytes, pinned to the byte layout QueryInterface memcmps.
#
# The first three groups are little-endian, the last eight bytes literal. A
# naive left-to-right parse produces bytes QI rejects, and the failure mode
# is E_NOINTERFACE -- a silently dead branch, not an error. The Modula-2 port
# recorded this as a "must-fix designed away" and pinned IID_IUnknown's
# layout in a regression; this is that regression, ported.

from std.sys._com import _guid_bytes
from std.sys._winkb import winkb_interface_iid


def main() raises:
    # IID_IUnknown = 00000000-0000-0000-C000-000000000046
    let text = winkb_interface_iid["IUnknown"]()
    print("IID(IUnknown) text:", text)
    var got = _guid_bytes(text)
    if len(got) != 16:
        raise Error("wrong byte count")

    # The pinned layout: eight zero bytes, then C0, six zeros, 46 -- the
    # last two groups are literal, so c000-000000000046 is C0 00 00 00 00 00
    # 00 46 verbatim. (The first draft of this spike pinned five zeros and
    # failed its own check, which is the check working.)
    var want = List[UInt8]()
    for _ in range(8):
        want.append(0)
    want.append(0xC0)
    for _ in range(6):
        want.append(0)
    want.append(0x46)
    if len(want) != 16:
        raise Error("the pin itself is malformed")

    for i in range(16):
        if got[i] != want[i]:
            raise Error("byte " + String(i) + " differs")
    print("IID_IUnknown bytes: pinned layout EXACT (…C0, 00 x5, 46)")

    # Mixed-endian is doing real work: a distinctive GUID's first group must
    # arrive reversed. 0000010b-... (IPersistFile) begins 0B 01 00 00.
    var pf = _guid_bytes(winkb_interface_iid["IPersistFile"]())
    print("IPersistFile leads:", pf[0], pf[1], pf[2], pf[3], "(expect 11 1 0 0)")
    if pf[0] != 0x0B or pf[1] != 0x01 or pf[2] != 0 or pf[3] != 0:
        raise Error("little-endian group 1 broken")
    print("S03 PASS")
