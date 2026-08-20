# ===----------------------------------------------------------------------=== #
# Win32 metadata, queried while compiling.
#
# The Win32 API is described precisely -- struct sizes, field offsets, vtable
# order, interface IIDs -- in a metadata database, and the compiler can read it
# during elaboration. So a binding states a name and the compiler supplies the
# rest, instead of a generator restating 15,000 struct layouts that then have to
# be kept in step with Windows by hand.
#
# Every function here resolves to a constant before any code is generated. A
# name the metadata does not know is a compile error, not a wrong answer.
# ===----------------------------------------------------------------------=== #

from std.collections.string.string_span import _get_kgen_string


def winkb_struct_size[name: StaticString]() -> Int:
    """The size in bytes of a Win32 struct, from the metadata.

    Parameters:
        name: The unqualified Win32 struct name, e.g. "POINT".

    Returns:
        The size in bytes.
    """
    return Int(
        mlir_value=__mlir_attr[
            `#kgen.param.expr<winkb_query, `,
            _get_kgen_string["struct_size"](),
            `, `,
            _get_kgen_string[name](),
            `> : index`,
        ]
    )


def winkb_struct_align[name: StaticString]() -> Int:
    """The alignment in bytes of a Win32 struct, from the metadata.

    Parameters:
        name: The unqualified Win32 struct name.

    Returns:
        The alignment in bytes.
    """
    return Int(
        mlir_value=__mlir_attr[
            `#kgen.param.expr<winkb_query, `,
            _get_kgen_string["struct_align"](),
            `, `,
            _get_kgen_string[name](),
            `> : index`,
        ]
    )


def winkb_field_offset[type_name: StaticString, field: StaticString]() -> Int:
    """The byte offset of a field within a Win32 struct.

    This is what makes a declaration checkable rather than merely plausible:
    a Mojo struct can assert that its own layout agrees with what Windows
    expects, and fail to build if it does not.

    Parameters:
        type_name: The unqualified Win32 struct name.
        field: The field name within it.

    Returns:
        The offset in bytes from the start of the struct.
    """
    return Int(
        mlir_value=__mlir_attr[
            `#kgen.param.expr<winkb_query, `,
            _get_kgen_string["field_offset"](),
            `, `,
            _get_kgen_string[type_name](),
            `, `,
            _get_kgen_string[field](),
            `> : index`,
        ]
    )


def winkb_vtable_index[type_name: StaticString, method: StaticString]() -> Int:
    """The vtable slot of a COM method.

    A COM call is an indexed load from the interface's vtable, so this is the
    only fact a caller needs that cannot be written down from the signature.
    Taking it from the metadata means the 46,000-odd methods across Windows
    need no generated constants at all.

    Parameters:
        type_name: The COM interface name, e.g. "IFileDialog".
        method: The method name on it.

    Returns:
        The zero-based vtable slot.
    """
    return Int(
        mlir_value=__mlir_attr[
            `#kgen.param.expr<winkb_query, `,
            _get_kgen_string["vtable_index"](),
            `, `,
            _get_kgen_string[type_name](),
            `, `,
            _get_kgen_string[method](),
            `> : index`,
        ]
    )


def winkb_function_dll[name: StaticString]() -> StaticString:
    """Which DLL exports a Win32 function.

    Parameters:
        name: The exported function name, e.g. "GetCursorPos".

    Returns:
        The DLL name, e.g. "USER32.dll".
    """
    var res = __mlir_attr[
        `#kgen.param.expr<winkb_query, `,
        _get_kgen_string["function_dll"](),
        `, `,
        _get_kgen_string[name](),
        `> : !kgen.string`,
    ]
    return StaticString(res)


def winkb_interface_iid[type_name: StaticString]() -> StaticString:
    """The IID of a COM interface, from the metadata.

    Parameters:
        type_name: The interface name, e.g. "IStream".

    Returns:
        The textual GUID, e.g. "0000000c-0000-0000-c000-000000000046".
    """
    var res = __mlir_attr[
        `#kgen.param.expr<winkb_query, `,
        _get_kgen_string["interface_iid"](),
        `, `,
        _get_kgen_string[type_name](),
        `> : !kgen.string`,
    ]
    return StaticString(res)


def winkb_constant[name: StaticString]() -> Int:
    """The value of a named Win32 constant or flag, from the metadata.

    Covers both plain constants and enumeration/flag members, so
    `winkb_constant["STARTF_USESTDHANDLES"]()` and
    `winkb_constant["ERROR_BROKEN_PIPE"]()` both answer. The value is the
    signed reading, which is the one that stays correct in both directions:
    `HKEY_LOCAL_MACHINE` must sign-extend to a pointer, and a flag mask keeps
    its bits through the caller's `UInt32()`.

    Hand-transcribing these is the quiet failure mode of Windows FFI --
    `STARTF_USESTDHANDLES` is 0x100 and `STARTF_USESHOWWINDOW` is 1, and
    swapping them redirects a child's output to the console instead of the
    pipe with no error anywhere. A name the metadata does not know is a
    compile error naming the source line.

    Parameters:
        name: The constant's name, e.g. "FILE_ATTRIBUTE_DIRECTORY".

    Returns:
        The constant's value.

    Example:

    ```mojo
    from std.sys._winkb import winkb_constant

    comptime CF_UNICODETEXT = UInt32(winkb_constant["CF_UNICODETEXT"]())
    ```
    """
    return Int(
        mlir_value=__mlir_attr[
            `#kgen.param.expr<winkb_query, `,
            _get_kgen_string["constant_value"](),
            `, `,
            _get_kgen_string[name](),
            `> : index`,
        ]
    )


def winkb_constant_text[name: StaticString]() -> StaticString:
    """The value of a named Win32 string constant, from the metadata.

    Parameters:
        name: The constant's name, e.g. "SERVICES_ACTIVE_DATABASEW".

    Returns:
        The constant's text.
    """
    var res = __mlir_attr[
        `#kgen.param.expr<winkb_query, `,
        _get_kgen_string["constant_text"](),
        `, `,
        _get_kgen_string[name](),
        `> : !kgen.string`,
    ]
    return StaticString(res)


def winkb_db_hash() -> StaticString:
    """The SHA-256 of the metadata database this compilation is reading.

    The reproducibility pin: a binary's build record can state exactly which
    metadata revision its layouts and vtable slots came from.

    Returns:
        The hash as lowercase hex.
    """
    var res = __mlir_attr[
        `#kgen.param.expr<winkb_query, `,
        _get_kgen_string["db_hash"](),
        `> : !kgen.string`,
    ]
    return StaticString(res)


def winkb_db_schema_version() -> StaticString:
    """The metadata database's own schema version.

    Returns:
        The schema version string.
    """
    var res = __mlir_attr[
        `#kgen.param.expr<winkb_query, `,
        _get_kgen_string["db_schema_version"](),
        `> : !kgen.string`,
    ]
    return StaticString(res)
