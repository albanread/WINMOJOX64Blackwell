# The metadata surface a COM binding stands on, pinned by value.
#
# Every number here is the database answering at compile time; a drifted
# database changes the printout and the assertions catch the load-bearing
# ones. The chain-walk is the point to prove: Read is DEFINED on
# ISequentialStream and must be reachable by asking IStream.

from std.sys._winkb import (
    winkb_db_schema_version,
    winkb_db_hash,
    winkb_vtable_index,
    winkb_interface_iid,
    winkb_com_ret_type,
    winkb_com_param_count,
    winkb_com_param_type,
    winkb_com_method_count,
    winkb_com_interface_base,
    winkb_type_width,
)


def expect[label: StaticString](got: Int, want: Int) raises:
    print(" ", label, "=", got, "(expect", want, ")")
    if got != want:
        raise Error("metadata drift on " + String(label))


def main() raises:
    print("schema", winkb_db_schema_version(), "hash", winkb_db_hash())

    # The inheritance chain, walked in the query.
    expect["IStream.QueryInterface slot"](
        winkb_vtable_index["IStream", "QueryInterface"](), 0
    )
    expect["IStream.Read slot (from ISequentialStream)"](
        winkb_vtable_index["IStream", "Read"](), 3
    )
    expect["IStream.Seek slot (own)"](
        winkb_vtable_index["IStream", "Seek"](), 5
    )
    expect["IStream total slots"](winkb_com_method_count["IStream"](), 14)

    # Signatures.
    expect["Read arity"](winkb_com_param_count["IStream", "Read"](), 3)
    print("  Read returns", winkb_com_ret_type["IStream", "Read"]())
    print("  Read params:", winkb_com_param_type["IStream", "Read", "0"](),
          winkb_com_param_type["IStream", "Read", "1"](),
          winkb_com_param_type["IStream", "Read", "2"]())

    # Chain shape and widths.
    print("  IStream base:", winkb_com_interface_base["IStream"]())
    expect["STREAM_SEEK width"](winkb_type_width["STREAM_SEEK"](), 4)
    expect["POINTL width"](winkb_type_width["POINTL"](), 8)

    # The IID the QI path will use.
    print("  IID(IUnknown) =", winkb_interface_iid["IUnknown"]())
    print("S01 PASS")
