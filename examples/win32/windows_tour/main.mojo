# ===----------------------------------------------------------------------=== #
# Everything in std.windows, run against the real machine.
#
#     ./examples/win32/build.sh windows_tour
#     ./bazel-bin/examples/win32/windows_tour.exe
#
# This is the acceptance test for the package, not a demo: each section prints
# what the machine actually said, so a wrong struct offset or a mis-decoded
# string is visible rather than merely absent. The registry section writes to
# HKCU\Software\MojoWindowsTour and deletes it again; nothing else is
# destructive.
# ===----------------------------------------------------------------------=== #

from std.windows import (
    DateTime,
    HKEY_CURRENT_USER,
    HKEY_LOCAL_MACHINE,
    KEY_READ,
    KEY_WRITE,
    KnownFolder,
    RegKey,
    computer_name,
    console_size,
    current_directory,
    current_process_id,
    delete_file,
    disk_free_space,
    enable_virtual_terminal,
    environment,
    expand_environment,
    file_times,
    get_clipboard_text,
    get_environment,
    is_elevated,
    known_folder,
    list_directory,
    memory_status,
    module_path,
    performance_counter,
    performance_frequency,
    processor_count,
    quote_argument,
    read_file,
    run_captured,
    set_clipboard_text,
    system_time_ns,
    temp_path,
    to_local_time,
    uptime_ms,
    use_utf8_console,
    user_name,
    windows_version,
    write_file,
)


def count_char(text: StringSlice, needle: StringSlice) -> Int:
    var n = 0
    for byte in text.as_bytes():
        if byte == needle.as_bytes()[0]:
            n += 1
    return n


def pad(text: StringSlice, width: Int) -> String:
    var out = String(text)
    while out.byte_length() < width:
        out += " "
    return out^


def commas(items: List[String]) -> String:
    var out = String("")
    for i in range(len(items)):
        if i:
            out += ", "
        out += items[i]
    return out^


def show_folder(label: StringSlice, folder: KnownFolder):
    # Every folder id is exercised: a transcribed GUID that is wrong resolves
    # to nothing, and printing the path is the only proof it was right.
    try:
        print(pad(label, 14), known_folder(folder))
    except e:
        print(pad(label, 14), "unavailable:", e)


def rule(title: StringSlice):
    print()
    print("--", title, "-" * (68 - title.byte_length()))


def main() raises:
    # Before anything prints: without these two the console mangles non-ASCII
    # and prints escape codes literally.
    use_utf8_console()
    try:
        enable_virtual_terminal()
    except:
        print("(no console; VT not enabled)")

    rule("system")
    print("windows      ", windows_version())
    print("computer     ", computer_name())
    print("user         ", user_name())
    print("processors   ", processor_count())
    print("uptime       ", uptime_ms() // 3600000, "hours")

    var mem = memory_status()
    print("memory load  ", mem.load_percent, "%")
    print(
        "physical     ",
        mem.available_physical // (1 << 30),
        "GiB free of",
        mem.total_physical // (1 << 30),
        "GiB",
    )
    print("virtual      ", mem.total_virtual // (1 << 40), "TiB address space")

    rule("timing")
    # Timed against real work, not an arithmetic loop: the optimiser folds a
    # loop with no observable effect and the reading comes back as zero.
    var hz = performance_frequency()
    var t0 = performance_counter()
    var system32 = list_directory(known_folder(KnownFolder.SYSTEM))
    var t1 = performance_counter()
    print("counter freq ", hz, "Hz")
    print(
        "listing System32 (", len(system32), "entries ) took",
        (t1 - t0) * 1000 // hz,
        "ms",
    )

    rule("known folders")
    show_folder("profile", KnownFolder.PROFILE)
    show_folder("desktop", KnownFolder.DESKTOP)
    show_folder("documents", KnownFolder.DOCUMENTS)
    show_folder("downloads", KnownFolder.DOWNLOADS)
    show_folder("localappdata", KnownFolder.LOCAL_APP_DATA)
    show_folder("programfiles", KnownFolder.PROGRAM_FILES)
    show_folder("windows", KnownFolder.WINDOWS)
    show_folder("system", KnownFolder.SYSTEM)
    show_folder("fonts", KnownFolder.FONTS)

    rule("paths")
    print("exe          ", module_path())
    print("cwd          ", current_directory())
    print("temp         ", temp_path())
    print("expanded     ", expand_environment("%SystemRoot%"))

    var free_and_total = disk_free_space("C:\\")
    print(
        "C: free      ",
        free_and_total[0] // (1 << 30),
        "GiB of",
        free_and_total[1] // (1 << 30),
        "GiB",
    )

    rule("directory listing")
    var entries = list_directory(known_folder(KnownFolder.WINDOWS))
    var dirs = 0
    var files = 0
    var biggest = 0
    var biggest_name = String("")
    for entry in entries:
        if entry.is_directory():
            dirs += 1
        else:
            files += 1
            if entry.size > biggest:
                biggest = entry.size
                biggest_name = entry.name.copy()
    print("C:\\Windows   ", dirs, "directories,", files, "files")
    print("largest      ", biggest_name, biggest // 1024, "KiB")

    rule("registry: reading")
    var cv = RegKey.open(
        HKEY_LOCAL_MACHINE,
        "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion",
    )
    # ProductName still says "Windows 10" on Windows 11 -- which is exactly
    # why windows_version()'s build number above is the one to believe.
    print("product      ", cv.get_string("ProductName"))
    print("edition      ", cv.get_string("EditionID"))
    print("build lab    ", cv.get_string("BuildLabEx"))
    print("install date ", cv.get_int("InstallDate"), "(unix seconds)")

    var env = RegKey.open(HKEY_CURRENT_USER, "Environment")
    var names = env.values()
    print("env values   ", len(names), "->", commas(names))

    var processor = RegKey.open(
        HKEY_LOCAL_MACHINE, "HARDWARE\\DESCRIPTION\\System\\CentralProcessor"
    )
    var cores = processor.subkeys()
    print("cpu subkeys  ", len(cores), "->", commas(cores))
    var core0 = RegKey.open(
        HKEY_LOCAL_MACHINE,
        "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0",
    )
    print("cpu name     ", core0.get_string("ProcessorNameString"))

    rule("registry: writing")
    var scratch = RegKey.create(HKEY_CURRENT_USER, "Software\\MojoWindowsTour")
    scratch.set_string("greeting", "café über 🐉")
    scratch.set_int("answer", 42)
    scratch.set_string("expandable", "%SystemRoot%\\System32", 2)  # REG_EXPAND_SZ
    print("greeting     ", scratch.get_string("greeting"))
    print("answer       ", scratch.get_int("answer"))
    print("expandable   ", scratch.get_string("expandable"), "(auto-expanded)")
    print("values       ", commas(scratch.values()))

    scratch.delete_value("greeting")
    scratch.delete_value("answer")
    scratch.delete_value("expandable")
    var root = RegKey.open(HKEY_CURRENT_USER, "Software", KEY_WRITE | KEY_READ)
    root.delete_subkey("MojoWindowsTour")
    print("cleaned up   ", "MojoWindowsTour removed")

    rule("console")
    try:
        var size = console_size()
        print("size         ", size[0], "x", size[1], "cells")
    except:
        print("size          (redirected; no console)")
    print("colour       ", "\x1b[32mgreen\x1b[0m \x1b[33myellow\x1b[0m \x1b[31mred\x1b[0m")
    print("unicode      ", "café über 🐉 — em dash, ½ fraction, → arrow")

    rule("time")
    print("now (local)  ", to_local_time(system_time_ns()))
    var times = file_times(module_path())
    print("exe created  ", to_local_time(times[0]))
    print("exe modified ", to_local_time(times[2]))
    var newest = list_directory(current_directory())
    var latest = 0
    var latest_name = String("")
    for entry in newest:
        if entry.modified > latest:
            latest = entry.modified
            latest_name = entry.name.copy()
    print("newest here  ", latest_name, "at", to_local_time(latest))

    rule("process")
    print("pid          ", current_process_id())
    print("elevated     ", is_elevated())
    print("PATH entries ", count_char(get_environment("PATH"), ";") + 1)
    print("environment  ", len(environment()), "variables")
    # The quoting is the part that is easy to get wrong: a Windows path ending
    # in a backslash escapes the closing quote unless the run is doubled.
    print("quoted       ", quote_argument("C:\\Program Files\\"))

    var probe = run_captured(
        [String("cmd.exe"), String("/c"), String("echo from a child process")]
    )
    print("child exit   ", probe[0])
    print("child said   ", probe[1].strip())

    rule("files")
    # Binary-exact round trip: every byte value, including the 0x0A that a
    # text-mode writer would corrupt into 0x0D 0x0A.
    var payload = List[UInt8](length=256, fill=0)
    for i in range(256):
        payload[i] = UInt8(i)
    var scratch_file = temp_path() + "mojo_tour_bytes.bin"
    write_file(scratch_file, Span(payload))
    var returned = read_file(scratch_file)
    var intact = len(returned) == 256
    if intact:
        for i in range(256):
            if returned[i] != UInt8(i):
                intact = False
    print("round trip   ", "256 bytes", "intact" if intact else "CORRUPTED")
    delete_file(scratch_file)
    print("cleaned up   ", scratch_file)

    rule("clipboard")
    var before = get_clipboard_text()
    set_clipboard_text("mojo on windows arm64 — café über 🐉")
    print("wrote/read   ", get_clipboard_text())
    set_clipboard_text(before)  # put back whatever was there
    print("restored     ", before.byte_length(), "bytes")
    print()
