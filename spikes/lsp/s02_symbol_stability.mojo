"""Does the same `documentSymbol` request give the same answer every time?

Griddle got 61, 61 and 4 symbols from three identical runs against the same
unchanged file, which is either the server answering differently or this
client losing part of the reply. The editor is not the place to find out, so
this asks the same question five times in one process and prints what came
back each time.

    ./bazel-bin/KGEN/tools/mojo/mojo.exe build --no-optimization \
        -I mojo/stdlib -I . -o build/s02.exe spikes/lsp/s02_symbol_stability.mojo
    ./build/s02.exe ide/rope.mojo
"""

from std.sys import argv
from std.time import perf_counter_ns

from ide.json import JSON
from ide.lsp import did_change, did_open, is_ready, poll, start, stop
from ide.symbols import (
    clear_symbols,
    request_symbols,
    symbol_count,
    symbols_request_id,
    symbols_serial,
)
from ide.win32 import absolute, env_or


def file_uri(path: String) -> String:
    var out = String("file:///")
    for byte in path.as_bytes():
        var c = Int(byte)
        out += "/" if c == ord("\\") else chr(c)
    return out^


def read_text(path: String) raises -> String:
    var handle = open(path, "r")
    var text = handle.read()
    handle.close()
    return text^


def main() raises:
    var args = argv()
    var rel = String(args[1]) if len(args) > 1 else String("ide/rope.mojo")
    var path = absolute(rel)
    var exe = env_or(
        "GRIDDLE_LSP",
        String("./bazel-bin/KGEN/tools/mojo-lsp-server/mojo-lsp-server.exe"),
    )
    var stdlib = absolute(String("mojo/stdlib"))
    var uri = file_uri(path)
    var slash = uri.rfind("/")
    var root = String(uri[byte=:slash]) if slash > 0 else uri
    if not start(exe, root, stdlib):
        print("spike: could not start the server")
        return

    var deadline = perf_counter_ns() + 30_000_000_000
    while perf_counter_ns() < deadline and not is_ready():
        _ = poll()
    if not is_ready():
        print("spike: no handshake")
        stop()
        return
    did_open(uri, read_text(path))
    # No settle. Griddle restores a session, so several documents are opened
    # at once and the server is still parsing when the first question is
    # asked -- which is the remaining difference between this and the editor.
    var settled = perf_counter_ns() + Int(env_or("SETTLE_MS", String("0"))) * 1_000_000
    while perf_counter_ns() < settled:
        _ = poll()

    # The editor's extra move: it syncs the document before it asks, so the
    # server is re-parsing when the question arrives. That is the difference
    # between this spike and Griddle, and therefore the thing to try.
    var text = read_text(path)
    for round in range(5):
        clear_symbols()
        did_change(uri, round + 2, text)
        var mark = symbols_serial()
        var id = request_symbols(uri)
        var until = perf_counter_ns() + 15_000_000_000
        while perf_counter_ns() < until and symbols_serial() == mark:
            _ = poll()
        print(
            "spike: round", round, " id", id,
            " symbols", symbol_count(),
            " outstanding", symbols_request_id(),
        )
    stop()
