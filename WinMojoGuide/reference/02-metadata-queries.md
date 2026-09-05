# The metadata queries

The Windows API extension is a database and a set of compile-time queries
over it. A binding in this fork states a *name*; the compiler supplies
everything else — which DLL the function lives in, how big the struct is,
where the field sits, which vtable slot the method occupies — from
`windows_api.db` at elaboration time. A misspelled name is a compile error.
A struct that has drifted from the SDK fails the build. Nothing is
transcribed by hand that the database can answer.

The queries live in `std.sys._winkb` and fold to constants: every use
becomes a number in the compiled program.

## The database

`windows_api.db`, an SQLite database built from the Windows SDK by the
sibling WRASM repository, read by the compiler through its `winkb_query`
hook. It is found through `MODULAR_MOJO_MAX_WINKB_PATH`; a build that needs
it without the variable set fails to elaborate, naming the query.

Two provenance queries answer "what am I actually compiled against":

```mojo
winkb_db_hash()             # the database's content hash
winkb_db_schema_version()   # its schema version
```

## Structs

```mojo
winkb_struct_size["RECT"]()          # 16
winkb_struct_align["RECT"]()         # 4
winkb_field_offset["RECT", "bottom"]()   # 12
```

The standing use is the assertion that pins a hand-declared struct to the
SDK's layout — making drift a build failure instead of a corrupt call:

```mojo
comptime assert size_of[WNDCLASSEXW]() == winkb_struct_size["WNDCLASSEXW"]()
```

A size assert alone does not prove fields are in the right *place*; assert
`winkb_field_offset` for any field whose misplacement fails silently (an
HWND read from the wrong offset binds a swap chain to nothing and reports
nothing).

## Functions

```mojo
winkb_function_dll["GetCursorPos"]()     # "user32.dll"
```

One query: which DLL. The typed call itself goes through `win32[]` or
`Win32Module` (see [the language reference](01-language.md) for the FFI
floor and [chapter 4](../guide/04-calling-win32.md) for the tour); the
metadata's part is that the DLL name and the export name are looked up, not
transcribed.

## Constants

```mojo
winkb_constant["WM_PAINT"]()             # 0x000F, the signed reading
winkb_constant["HKEY_LOCAL_MACHINE"]()   # sign-extends correctly to a pointer
winkb_constant_text["ERROR_FILE_NOT_FOUND"]()   # "The system cannot find the file specified."
```

`winkb_constant` covers `#define` constants and enumeration or flag members
alike, and returns the *signed* reading — the one that stays correct in
both directions: `HKEY_LOCAL_MACHINE` must sign-extend to a pointer-sized
handle, while a flag mask keeps its bits through the caller's `UInt32()`.
Reach for it in preference to transcribing; swapped `STARTF_*` bits send a
child's output to the wrong place with no error anywhere.

`winkb_constant_text` is the message compiler's text for an error code —
the system's own words rather than a number.

## COM

The COM queries are how a method call finds its vtable slot and a
`query_interface` finds its IID — no GUID is ever written in user code:

```mojo
winkb_vtable_index["IUnknown", "Release"]()      # 2
winkb_interface_iid["IStream"]()                 # the textual GUID
winkb_com_method_count["IDropTarget"]()          # slots in the vtable
winkb_com_method_at_slot["IDropTarget", StaticString("3")]()  # the slot's name
winkb_com_has_method["IDropTarget", "DragEnter"]()  # 1 or 0
winkb_com_ret_type["IUnknown", "Release"]()      # the return's width/kind
winkb_com_param_count["IUnknown", "QueryInterface"]()
winkb_com_param_type["IUnknown", "QueryInterface", StaticString("0")]()
winkb_com_chain_iids["IStream"]()                # the whole inheritance chain, comma-joined
winkb_com_interface_base["IDropTarget"]()        # its immediate base
winkb_type_width["UInt32"]()                     # a Mojo type name's width in bits
```

The method queries chain-walk in SQL — nearest definition wins, the seed is
every interface with an IID — so a method inherited from a base answers at
the derived interface's name, and `com_chain_iids` returns every IID the
object can honestly answer `query_interface` with. `winkb_com_has_method`
answers instead of failing: it exists for tool paths that want a 0/1
(`class` bodies use it to leave a helper method unwired rather than to
refuse the class).

When a name is unknown, the error is at the use, naming the line:

> *note: the Win32 metadata has no 'constant_value' for STARTF_USESTDHANDLE*

— which is the feature. The database knows 86 MB of Windows; what it does
not know cannot silently become zero.

## What belongs in the database versus in source

The rule the examples follow: if the SDK states it, the database states it,
and source only asserts. Hand-written values in this tree are rare and each
carries a comment saying why — the two GUIDs whose database values are null
(`CLSID_MMDeviceEnumerator`, `CLSID_FileOpenDialog`) and the `IUnknown` IID
bytes pinned inside a must-not-raise C callback that s03 proves against the
metadata elsewhere.
