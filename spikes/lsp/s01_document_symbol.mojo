"""Does this Mojo language server answer `textDocument/documentSymbol`?

A spike, not a test and not part of the editor. The question is about the
server, so the program that asks it should be a program that does nothing
else: making Griddle ask, and reading the answer out of Griddle's behaviour,
is interrogating one program by modifying another.

Build and run:

    ./bazel-bin/KGEN/tools/mojo/mojo.exe build --no-optimization \
        -I mojo/stdlib -I . -o build/s01.exe spikes/lsp/s01_document_symbol.mojo
    ./build/s01.exe ide/rope.mojo
"""

from std.sys import argv
from std.time import perf_counter_ns

from ide.json import JSON
from ide.lsp import did_open, is_ready, poll, request, start, stop
from ide.win32 import absolute, env_or


def file_uri(path: String) -> String:
    """`file:///E:/x`, with the three slashes Windows needs."""
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
    print("spike: server", exe)
    print("spike: file  ", path)

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
        print("spike: the server never finished its handshake")
        stop()
        return

    did_open(uri, read_text(path))
    # Give it a moment to parse: a server asked about a file it has not read
    # yet may answer null and be right to.
    var settled = perf_counter_ns() + 5_000_000_000
    while perf_counter_ns() < settled:
        _ = poll()

    var doc = JSON.object()
    doc.set(String("uri"), JSON(uri))
    var params = JSON.object()
    params.set(String("textDocument"), doc^)
    var id = request(String("textDocument/documentSymbol"), params^)
    print("spike: sent documentSymbol as id", id)

    var until = perf_counter_ns() + 20_000_000_000
    while perf_counter_ns() < until:
        _ = poll()
    print("spike: 20s elapsed; the reply to id", id, "is above, or absent")
    stop()
