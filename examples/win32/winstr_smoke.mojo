# Round-trips the wide-string helpers and decodes a few error codes.
# Small on purpose: everything else in the Windows surface stands on these.

from std.windows import (
    Handle,
    WideString,
    error_message,
    from_wide,
    last_error,
)


def main() raises:
    var cases: List[String] = [
        String(""),
        String("hello"),
        String("C:") + chr(92) + String("Windows") + chr(92) + String("System32"),
        String("café über"),
        String("🐉 dragon"),
    ]
    for text in cases:
        var wide = WideString(text)
        var back = from_wide(wide.unsafe_ptr())
        print(
            "utf16 units:",
            len(wide),
            "roundtrip:",
            "ok" if back == text else "MISMATCH",
            "|",
            back,
        )

    # ERROR_FILE_NOT_FOUND and ERROR_ACCESS_DENIED: the system's own words,
    # not a bare number for the reader to look up.
    print("error 2 ->", error_message(2))
    print("error 5 ->", error_message(5))
    print("last_error ->", last_error())

    # An empty handle must not try to close anything.
    var null_handle = Handle(adopt=0)
    var invalid = Handle(adopt=-1)
    print("null truthy:", Bool(null_handle), " invalid truthy:", Bool(invalid))
