# ===----------------------------------------------------------------------=== #
# The Windows package.
#
# Upstream Mojo has no Windows support, so it has no Windows library either:
# `os` and `pathlib` are written against POSIX and the parts that cannot be
# emulated are simply absent. This package is the other half -- the things a
# Windows program actually needs, spelled as Mojo rather than as FFI
# boilerplate at every call site.
#
# It is built in layers. `core` has wide strings, error decoding and owning
# handles, because every W entry point needs all three; everything else stands
# on it. Nothing here wraps an API just to have wrapped it: each function is
# one a real program reaches for.
#
# Struct layouts are not hand-copied from headers. They come from the Windows
# knowledge base at compile time via `winkb_struct_size` and
# `winkb_field_offset`, so a wrong offset is a compile error rather than a
# corrupted call -- which matters more here than anywhere, since half of the
# published offsets on the internet are the 32-bit ones.
# ===----------------------------------------------------------------------=== #
"""Windows system APIs: registry, shell folders, filesystem, console, system
information.

This package exists only on the Windows port. It provides the parts of the
Win32 API a program is most likely to need, on top of a small foundation of
wide strings, decoded errors, and owning handles.

Example:

```mojo
from std.windows import RegKey, HKEY_CURRENT_USER, known_folder, KnownFolder

def main() raises:
    print(known_folder(KnownFolder.DOCUMENTS))
    var key = RegKey.open(HKEY_CURRENT_USER, "Environment")
    print(key.get_string("Path"))
```
"""

from .clipboard import get_clipboard_text, set_clipboard_text
from .console import (
    console_size,
    enable_virtual_terminal,
    set_console_title,
    use_utf8_console,
)
from .core import (
    Handle,
    WideString,
    error_message,
    from_wide,
    last_error,
    raise_if_failed,
    raise_last_error,
)
from .fs import (
    FILE_ATTRIBUTE_DIRECTORY,
    FILE_ATTRIBUTE_HIDDEN,
    FILE_ATTRIBUTE_READONLY,
    DirEntry,
    copy_file,
    create_directory,
    current_directory,
    delete_file,
    disk_free_space,
    file_attributes,
    full_path,
    is_directory,
    list_directory,
    module_path,
    move_file,
    path_exists,
    read_file,
    remove_directory,
    set_current_directory,
    temp_path,
    write_file,
)
from .process import (
    build_command_line,
    current_process_id,
    environment,
    get_environment,
    is_elevated,
    quote_argument,
    run,
    run_captured,
    set_environment,
)
from .registry import (
    HKEY_CLASSES_ROOT,
    HKEY_CURRENT_CONFIG,
    HKEY_CURRENT_USER,
    HKEY_LOCAL_MACHINE,
    HKEY_USERS,
    KEY_ALL_ACCESS,
    KEY_READ,
    KEY_WOW64_32KEY,
    KEY_WOW64_64KEY,
    KEY_WRITE,
    REG_BINARY,
    REG_DWORD,
    REG_EXPAND_SZ,
    REG_MULTI_SZ,
    REG_QWORD,
    REG_SZ,
    RegKey,
)
from .shell import (
    KnownFolder,
    expand_environment,
    known_folder,
    message_box,
)
from .time import (
    DateTime,
    file_times,
    filetime_to_unix_ns,
    system_time_ns,
    to_local_time,
    unix_ns_to_filetime,
)
from .sysinfo import (
    MemoryStatus,
    WindowsVersion,
    computer_name,
    memory_status,
    performance_counter,
    performance_frequency,
    processor_count,
    uptime_ms,
    user_name,
    windows_version,
)
