# HResult at its true width, demonstrating the bug the width prevents.
#
# A virtual COM method returns HRESULT in EAX, zeroing RAX's upper half; a
# 64-bit sign test on that register is therefore always false for a failure
# code. The Modula-2 port hit this live. HResult holds Int32, so the sign
# test is right by construction -- and this spike shows the wide read lying
# next to the narrow one telling the truth.

from std.sys.com import HResult, S_OK, S_FALSE, E_FAIL, E_NOINTERFACE


def main() raises:
    # The narrow truth.
    let fail = E_FAIL
    print("E_FAIL as Int32:", fail.value, " failed:", fail.failed())
    if not fail.failed():
        raise Error("sign test broken")

    # The wide lie, reconstructed: what EAX->RAX zero-extension produces.
    let wide: UInt64 = 0x80004005
    let wide_signed = Int(wide)  # 2147500037 -- positive
    print("same bits read wide:", wide_signed, " '< 0' test:", wide_signed < 0)
    if wide_signed < 0:
        raise Error("expected the wide read to lie")

    # Success family: S_OK and S_FALSE both succeed; only one is S_OK.
    if not (S_OK.succeeded() and S_FALSE.succeeded()):
        raise Error("success family broken")
    print("S_OK succeeded, S_FALSE succeeded (and is not a failure)")

    # raise_for: the return value decides.
    var raised = False
    try:
        E_NOINTERFACE.raise_for["probe"]()
    except:
        raised = True
    if not raised:
        raise Error("E_NOINTERFACE did not raise")
    S_FALSE.raise_for["probe"]()  # must NOT raise
    print("raise_for: failure raised, S_FALSE passed through")
    print("S02 PASS")
