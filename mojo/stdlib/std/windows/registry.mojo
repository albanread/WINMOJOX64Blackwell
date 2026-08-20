# ===----------------------------------------------------------------------=== #
# The registry.
#
# Every Reg* function returns LSTATUS -- a plain Win32 error code, not an
# HRESULT and not a BOOL, so `GetLastError` is not involved and the code comes
# straight back from the call. That is the one convention to remember here; the
# wrappers turn a non-zero status into a raise and are otherwise thin.
#
# The predefined roots are the classic 64-bit trap. HKEY_LOCAL_MACHINE is
# `(HKEY)(ULONG_PTR)((LONG)0x80000002)` -- a *signed* 32-bit value widened to a
# pointer, so on 64-bit it is 0xFFFFFFFF80000002 and not 0x0000000080000002.
# Writing the unsigned constant gives an invalid handle. winkb stores them
# signed, which is what the values below are.
# ===----------------------------------------------------------------------=== #

from std.ffi import c_int
from std.memory import Pointer
from std.sys._win32 import Win32Module
from std.sys._winkb import winkb_constant
from std.windows.core import WideString, error_message, from_wide
from std.windows.shell import expand_environment


# The predefined roots, from the metadata, which stores them signed --
# see the note above about why that matters on 64-bit.
comptime HKEY_CLASSES_ROOT = winkb_constant["HKEY_CLASSES_ROOT"]()
"""The `HKEY_CLASSES_ROOT` predefined key."""
comptime HKEY_CURRENT_USER = winkb_constant["HKEY_CURRENT_USER"]()
"""The `HKEY_CURRENT_USER` predefined key."""
comptime HKEY_LOCAL_MACHINE = winkb_constant["HKEY_LOCAL_MACHINE"]()
"""The `HKEY_LOCAL_MACHINE` predefined key."""
comptime HKEY_USERS = winkb_constant["HKEY_USERS"]()
"""The `HKEY_USERS` predefined key."""
comptime HKEY_CURRENT_CONFIG = winkb_constant["HKEY_CURRENT_CONFIG"]()
"""The `HKEY_CURRENT_CONFIG` predefined key."""

# Access masks. KEY_READ and KEY_WRITE are the header's composites with
# SYNCHRONIZE masked off, which is what `RegOpenKeyExW` expects.
comptime KEY_READ = UInt32(winkb_constant["KEY_READ"]())
"""Read access: query values, enumerate subkeys, and be notified."""
comptime KEY_WRITE = UInt32(winkb_constant["KEY_WRITE"]())
"""Write access: set values and create subkeys."""
comptime KEY_ALL_ACCESS = UInt32(winkb_constant["KEY_ALL_ACCESS"]())
"""Full access to a key."""
comptime KEY_WOW64_64KEY = UInt32(winkb_constant["KEY_WOW64_64KEY"]())
"""Forces the 64-bit view of the registry, whatever the process bitness."""
comptime KEY_WOW64_32KEY = UInt32(winkb_constant["KEY_WOW64_32KEY"]())
"""Forces the 32-bit (WOW6432Node) view of the registry."""

# Value types.
comptime REG_SZ = UInt32(winkb_constant["REG_SZ"]())
"""A NUL-terminated UTF-16 string."""
comptime REG_EXPAND_SZ = UInt32(winkb_constant["REG_EXPAND_SZ"]())
"""A string with unexpanded environment references, e.g. `%PATH%`."""
comptime REG_BINARY = UInt32(winkb_constant["REG_BINARY"]())
"""Raw bytes."""
comptime REG_DWORD = UInt32(winkb_constant["REG_DWORD"]())
"""A 32-bit integer."""
comptime REG_MULTI_SZ = UInt32(winkb_constant["REG_MULTI_SZ"]())
"""A sequence of strings, NUL-separated and NUL-NUL-terminated."""
comptime REG_QWORD = UInt32(winkb_constant["REG_QWORD"]())
"""A 64-bit integer."""

comptime _ERROR_NO_MORE_ITEMS = winkb_constant["ERROR_NO_MORE_ITEMS"]()


def _advapi32() raises -> Win32Module:
    """The module the Reg* entry points live in.

    Returns:
        A cached handle to advapi32.dll.

    Raises:
        If the module cannot be loaded.
    """
    var module = Win32Module("advapi32.dll")
    if not module:
        raise Error("cannot load advapi32.dll")
    return module


def _check(status: Int32, what: StringSlice) raises:
    """Raises if a registry call returned a non-zero LSTATUS.

    Args:
        status: The status the call returned.
        what: The operation, named for the reader.

    Raises:
        If `status` is non-zero.
    """
    if status != 0:
        raise Error(
            String(what)
            + " failed: "
            + error_message(UInt32(Int(status)))
            + " ("
            + String(status)
            + ")"
        )


struct RegKey(Boolable, Movable):
    """An open registry key, closed when it goes out of scope.

    Move-only, like `Handle`: two owners would mean two `RegCloseKey` calls on
    one key.

    Example:

    ```mojo
    from std.windows import RegKey, HKEY_LOCAL_MACHINE

    def main() raises:
        var key = RegKey.open(
            HKEY_LOCAL_MACHINE,
            "SOFTWARE\\\\Microsoft\\\\Windows NT\\\\CurrentVersion",
        )
        print(key.get_string("ProductName"))
    ```
    """

    var _key: Int

    def __init__(out self, *, adopt: Int):
        """Takes ownership of a raw HKEY.

        Args:
            adopt: The key, as returned by a Reg* call.
        """
        self._key = adopt

    def __init__(out self, *, deinit move: Self):
        """Moves ownership; nothing is closed.

        Args:
            move: The value being moved from.
        """
        self._key = move._key

    def __deinit__(deinit self):
        """Closes the key, unless it is a predefined root.

        Closing a predefined root is legal but pointless, and closing one that
        was never opened would be a bug worth not having.
        """
        if self._key != 0 and self._key > 0:
            try:
                _ = _advapi32().function[
                    def (Int) thin abi("C") -> Int32
                ]("RegCloseKey")(self._key)
            except:
                pass

    def __bool__(self) -> Bool:
        """Whether this holds an open key.

        Returns:
            True if the key is usable.
        """
        return self._key != 0

    @staticmethod
    def open(
        root: Int, path: StringSlice, access: UInt32 = KEY_READ
    ) raises -> Self:
        """Opens an existing key.

        Args:
            root: A predefined root, or the raw value of another open key.
            path: The subkey path, backslash-separated.
            access: The access mask, e.g. `KEY_READ`.

        Returns:
            The open key.

        Raises:
            If the key does not exist or access is denied.
        """
        var name = WideString(path)
        var result = Int(0)
        _check(
            _advapi32().function[
                def (
                    Int,
                    Pointer[UInt16, MutAnyOrigin],
                    UInt32,
                    UInt32,
                    Pointer[Int, MutAnyOrigin],
                ) thin abi("C") -> Int32
            ]("RegOpenKeyExW")(
                root,
                name.unsafe_ptr(),
                UInt32(0),
                access,
                Pointer(to=result).unsafe_origin_cast[MutAnyOrigin](),
            ),
            "RegOpenKeyExW(" + String(path) + ")",
        )
        return Self(adopt=result)

    @staticmethod
    def create(
        root: Int, path: StringSlice, access: UInt32 = KEY_ALL_ACCESS
    ) raises -> Self:
        """Opens a key, creating it and any missing parents.

        Args:
            root: A predefined root, or the raw value of another open key.
            path: The subkey path, backslash-separated.
            access: The access mask, e.g. `KEY_WRITE`.

        Returns:
            The open key.

        Raises:
            If the key cannot be created.
        """
        var name = WideString(path)
        var result = Int(0)
        _check(
            _advapi32().function[
                def (
                    Int,
                    Pointer[UInt16, MutAnyOrigin],
                    UInt32,
                    Int,
                    UInt32,
                    UInt32,
                    Int,
                    Pointer[Int, MutAnyOrigin],
                    Int,
                ) thin abi("C") -> Int32
            ]("RegCreateKeyExW")(
                root,
                name.unsafe_ptr(),
                UInt32(0),
                Int(0),  # lpClass
                UInt32(winkb_constant["REG_OPTION_NON_VOLATILE"]()),
                access,
                Int(0),  # default security
                Pointer(to=result).unsafe_origin_cast[MutAnyOrigin](),
                Int(0),  # disposition; not reported
            ),
            "RegCreateKeyExW(" + String(path) + ")",
        )
        return Self(adopt=result)

    def value(self) -> Int:
        """The raw HKEY, for passing to Win32 or as another call's root.

        Ownership stays here.

        Returns:
            The key value.
        """
        return self._key

    def _query(
        mut self, name: StringSlice, mut kind: UInt32
    ) raises -> List[UInt8]:
        """Reads a value's raw bytes, reporting its type through `kind`.

        Args:
            name: The value's name; empty means the key's default value.
            kind: Receives the value's `REG_*` type.

        Returns:
            The value's bytes, with two bytes of NUL padding appended.

        Raises:
            If the value does not exist.
        """
        var value_name = WideString(name)
        var query = _advapi32().function[
            def (
                Int,
                Pointer[UInt16, MutAnyOrigin],
                Int,
                Pointer[UInt32, MutAnyOrigin],
                Int,
                Pointer[UInt32, MutAnyOrigin],
            ) thin abi("C") -> Int32
        ]("RegQueryValueExW")

        # Ask for the size first: registry values have no useful upper bound,
        # and guessing one is how truncation bugs start.
        var size = UInt32(0)
        _check(
            query(
                self._key,
                value_name.unsafe_ptr(),
                Int(0),
                Pointer(to=kind).unsafe_origin_cast[MutAnyOrigin](),
                Int(0),
                Pointer(to=size).unsafe_origin_cast[MutAnyOrigin](),
            ),
            "RegQueryValueExW(" + String(name) + ")",
        )

        var data = List[UInt8](length=Int(size) + 2, fill=0)
        var capacity = size
        _check(
            _advapi32().function[
                def (
                    Int,
                    Pointer[UInt16, MutAnyOrigin],
                    Int,
                    Pointer[UInt32, MutAnyOrigin],
                    Pointer[UInt8, MutAnyOrigin],
                    Pointer[UInt32, MutAnyOrigin],
                ) thin abi("C") -> Int32
            ]("RegQueryValueExW")(
                self._key,
                value_name.unsafe_ptr(),
                Int(0),
                Pointer(to=kind).unsafe_origin_cast[MutAnyOrigin](),
                data.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
                Pointer(to=capacity).unsafe_origin_cast[MutAnyOrigin](),
            ),
            "RegQueryValueExW(" + String(name) + ")",
        )
        return data^

    def value_type(mut self, name: StringSlice) raises -> UInt32:
        """The type of a value, e.g. `REG_SZ`.

        Args:
            name: The value's name.

        Returns:
            One of the `REG_*` constants.

        Raises:
            If the value does not exist.
        """
        var kind = UInt32(0)
        _ = self._query(name, kind)
        return kind

    def get_string(mut self, name: StringSlice) raises -> String:
        """Reads a string value.

        `REG_EXPAND_SZ` values are returned already expanded, since a caller
        that wanted `%SystemRoot%` back verbatim would have asked for bytes.

        Args:
            name: The value's name; empty means the key's default value.

        Returns:
            The value as text.

        Raises:
            If the value is missing or is not a string type.
        """
        var kind = UInt32(0)
        var bytes = self._query(name, kind)
        if kind != REG_SZ and kind != REG_EXPAND_SZ and kind != REG_MULTI_SZ:
            raise Error(
                String(name) + " is not a string value (type " + String(kind) + ")"
            )
        var text = from_wide(
            bytes.unsafe_ptr().unsafe_bitcast[UInt16]().unsafe_origin_cast[
                MutAnyOrigin
            ]()
        )
        if kind == REG_EXPAND_SZ:
            return expand_environment(text)
        return text^

    def get_int(mut self, name: StringSlice) raises -> Int:
        """Reads a `REG_DWORD` or `REG_QWORD` value.

        Args:
            name: The value's name.

        Returns:
            The value as an integer.

        Raises:
            If the value is missing or is not an integer type.
        """
        var kind = UInt32(0)
        var bytes = self._query(name, kind)
        if kind == REG_DWORD:
            return Int(
                bytes.unsafe_ptr().unsafe_bitcast[UInt32]().unsafe_origin_cast[
                    MutAnyOrigin
                ]()[]
            )
        if kind == REG_QWORD:
            return Int(
                bytes.unsafe_ptr().unsafe_bitcast[UInt64]().unsafe_origin_cast[
                    MutAnyOrigin
                ]()[]
            )
        raise Error(
            String(name) + " is not an integer value (type " + String(kind) + ")"
        )

    def get_bytes(mut self, name: StringSlice) raises -> List[UInt8]:
        """Reads a value's raw bytes, whatever its type.

        Args:
            name: The value's name.

        Returns:
            The bytes, without the padding this call adds internally.

        Raises:
            If the value does not exist.
        """
        var kind = UInt32(0)
        var bytes = self._query(name, kind)
        # _query over-allocates by two so a truncated string still terminates.
        if len(bytes) >= 2:
            _ = bytes.pop()
            _ = bytes.pop()
        return bytes^

    def set_string(
        mut self, name: StringSlice, value: StringSlice, kind: UInt32 = REG_SZ
    ) raises:
        """Writes a string value.

        Args:
            name: The value's name; empty means the key's default value.
            value: The text to store.
            kind: `REG_SZ` or `REG_EXPAND_SZ`.

        Raises:
            If the key was not opened for writing.
        """
        var value_name = WideString(name)
        var text = WideString(value)
        # cbData counts BYTES and must include the terminator, or readers get
        # an unterminated string back.
        var size = UInt32((len(text) + 1) * 2)
        _check(
            _advapi32().function[
                def (
                    Int,
                    Pointer[UInt16, MutAnyOrigin],
                    UInt32,
                    UInt32,
                    Pointer[UInt16, MutAnyOrigin],
                    UInt32,
                ) thin abi("C") -> Int32
            ]("RegSetValueExW")(
                self._key,
                value_name.unsafe_ptr(),
                UInt32(0),
                kind,
                text.unsafe_ptr(),
                size,
            ),
            "RegSetValueExW(" + String(name) + ")",
        )

    def set_int(mut self, name: StringSlice, value: Int) raises:
        """Writes a `REG_QWORD` value.

        Args:
            name: The value's name.
            value: The integer to store.

        Raises:
            If the key was not opened for writing.
        """
        var value_name = WideString(name)
        var payload = UInt64(value)
        _check(
            _advapi32().function[
                def (
                    Int,
                    Pointer[UInt16, MutAnyOrigin],
                    UInt32,
                    UInt32,
                    Pointer[UInt64, MutAnyOrigin],
                    UInt32,
                ) thin abi("C") -> Int32
            ]("RegSetValueExW")(
                self._key,
                value_name.unsafe_ptr(),
                UInt32(0),
                REG_QWORD,
                Pointer(to=payload).unsafe_origin_cast[MutAnyOrigin](),
                UInt32(8),
            ),
            "RegSetValueExW(" + String(name) + ")",
        )

    def delete_value(mut self, name: StringSlice) raises:
        """Deletes a value.

        Args:
            name: The value's name.

        Raises:
            If the value does not exist or the key is read-only.
        """
        var value_name = WideString(name)
        _check(
            _advapi32().function[
                def (
                    Int, Pointer[UInt16, MutAnyOrigin]
                ) thin abi("C") -> Int32
            ]("RegDeleteValueW")(self._key, value_name.unsafe_ptr()),
            "RegDeleteValueW(" + String(name) + ")",
        )

    def delete_subkey(mut self, path: StringSlice) raises:
        """Deletes a subkey, which must itself have no subkeys.

        Args:
            path: The subkey's path relative to this key.

        Raises:
            If the subkey is missing, has children, or the key is read-only.
        """
        var name = WideString(path)
        _check(
            _advapi32().function[
                def (
                    Int, Pointer[UInt16, MutAnyOrigin], UInt32, UInt32
                ) thin abi("C") -> Int32
            ]("RegDeleteKeyExW")(
                self._key, name.unsafe_ptr(), UInt32(0), UInt32(0)
            ),
            "RegDeleteKeyExW(" + String(path) + ")",
        )

    def subkeys(mut self) raises -> List[String]:
        """The names of this key's immediate subkeys.

        Returns:
            The subkey names, in the order the registry reports them.

        Raises:
            If enumeration fails for a reason other than running out.
        """
        var enumerate = _advapi32().function[
            def (
                Int,
                UInt32,
                Pointer[UInt16, MutAnyOrigin],
                Pointer[UInt32, MutAnyOrigin],
                Int,
                Int,
                Int,
                Int,
            ) thin abi("C") -> Int32
        ]("RegEnumKeyExW")

        var names = List[String]()
        var index = UInt32(0)
        # 257 is the documented maximum key-name length plus its terminator.
        var buffer = List[UInt16](length=257, fill=0)
        while True:
            var length = UInt32(257)
            var status = enumerate(
                self._key,
                index,
                buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
                Pointer(to=length).unsafe_origin_cast[MutAnyOrigin](),
                Int(0),
                Int(0),
                Int(0),
                Int(0),
            )
            if Int(status) == _ERROR_NO_MORE_ITEMS:
                break
            _check(status, "RegEnumKeyExW")
            names.append(
                from_wide(
                    buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
                    Int(length),
                )
            )
            index += 1
        return names^

    def values(mut self) raises -> List[String]:
        """The names of this key's values.

        The default value, if set, appears as an empty name.

        Returns:
            The value names, in the order the registry reports them.

        Raises:
            If enumeration fails for a reason other than running out.
        """
        var enumerate = _advapi32().function[
            def (
                Int,
                UInt32,
                Pointer[UInt16, MutAnyOrigin],
                Pointer[UInt32, MutAnyOrigin],
                Int,
                Int,
                Int,
                Int,
            ) thin abi("C") -> Int32
        ]("RegEnumValueW")

        var names = List[String]()
        var index = UInt32(0)
        # 16384 is the documented maximum value-name length.
        var buffer = List[UInt16](length=16385, fill=0)
        while True:
            var length = UInt32(16385)
            var status = enumerate(
                self._key,
                index,
                buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
                Pointer(to=length).unsafe_origin_cast[MutAnyOrigin](),
                Int(0),
                Int(0),
                Int(0),
                Int(0),
            )
            if Int(status) == _ERROR_NO_MORE_ITEMS:
                break
            _check(status, "RegEnumValueW")
            names.append(
                from_wide(
                    buffer.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
                    Int(length),
                )
            )
            index += 1
        return names^
