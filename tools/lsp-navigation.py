"""What the server will actually answer for navigation, before any UI asks it.

Sprint 2.5 is definition, hover and references. Every one of them is "straight
protocol work" in IDE-DESIGN.md, and the whole point of a probe is to find out
before a sprint is built on that sentence which parts of it are true here.

    python tools/lsp-navigation.py
    python tools/lsp-navigation.py --verbose

The order is deliberate: what the server advertises, then what it answers.
A server can advertise a capability and return null for every position in a
real file, and the second fact is the one an editor lives with.
"""

import argparse
import json
import os
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = os.path.join(
    REPO, "bazel-bin", "KGEN", "tools", "mojo-lsp-server", "mojo-lsp-server.exe"
)
STDLIB = os.path.join(REPO, "mojo", "stdlib")

# A file with the three things navigation has to find: a local definition, a
# call to it, and a name from another module. Line and character are 0-based
# on the wire, which is the off-by-one this file exists to not make.
SAMPLE = '''from std.sys.com import Com


def helper(count: Int) -> Int:
    """Doubles what it is given."""
    return count * 2


def main() raises:
    var first = helper(21)
    var second = helper(first)
    var target = Com[StaticString("IDropTarget")](borrowed=0)
    _ = second
    _ = target
'''

#                                         line  char  what sits there
POSITIONS = [
    ("call to a local function", 9, 17, "helper"),
    ("second call to it", 10, 18, "helper"),
    ("its own declaration", 3, 5, "helper"),
    ("a local variable", 10, 26, "first"),
    ("a name from another module", 11, 18, "Com"),
]


class Server:
    def __init__(self, path, verbose=False):
        self.verbose = verbose
        self.proc = subprocess.Popen(
            [path, "-I", STDLIB],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, cwd=REPO,
        )
        self.next_id = 1

    def send(self, method, params, want_reply=True):
        msg = {"jsonrpc": "2.0", "method": method, "params": params}
        rid = None
        if want_reply:
            rid = self.next_id
            self.next_id += 1
            msg["id"] = rid
        body = json.dumps(msg).encode("utf-8")
        self.proc.stdin.write(
            f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body)
        self.proc.stdin.flush()
        if self.verbose:
            print(f"--> {method} {json.dumps(params.get('position', ''))}")
        return rid

    def read(self, timeout=40.0):
        deadline = time.time() + timeout
        header = b""
        while b"\r\n\r\n" not in header:
            if time.time() > deadline:
                return None
            ch = self.proc.stdout.read(1)
            if not ch:
                return None
            header += ch
        length = 0
        for line in header.decode("ascii").split("\r\n"):
            if line.lower().startswith("content-length:"):
                length = int(line.split(":", 1)[1].strip())
        body = b""
        while len(body) < length:
            chunk = self.proc.stdout.read(length - len(body))
            if not chunk:
                return None
            body += chunk
        return json.loads(body.decode("utf-8"))

    def wait(self, rid, timeout=60.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            msg = self.read(max(0.5, deadline - time.time()))
            if msg is None:
                return None
            if msg.get("id") == rid and ("result" in msg or "error" in msg):
                return msg
        return None

    def settle(self, timeout=40.0):
        """A request sent mid-parse is refused with -32801; wait for the
        diagnostics that say the parse finished. See docs/lsp-windows.md."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            msg = self.read(max(0.5, deadline - time.time()))
            if msg is None:
                return
            if msg.get("method") == "textDocument/publishDiagnostics":
                return


def where(result):
    """A definition reply, as one readable line. The protocol allows a
    Location, a list of them, or a LocationLink, and a probe that only
    understood one shape would report a working server as broken."""
    if result is None:
        return None
    if isinstance(result, dict):
        result = [result]
    if not result:
        return None
    first = result[0]
    uri = first.get("uri") or first.get("targetUri", "")
    rng = first.get("range") or first.get("targetSelectionRange") or {}
    start = rng.get("start", {})
    return "{}:{}:{}".format(
        os.path.basename(uri), start.get("line", "?"), start.get("character", "?"))


def hover_text(result):
    """Hover's contents can be a string, a {language, value} pair, a
    MarkupContent, or a list of any of those."""
    if not result:
        return None
    contents = result.get("contents")
    if contents is None:
        return None
    if isinstance(contents, str):
        return contents.strip()
    if isinstance(contents, dict):
        return str(contents.get("value", "")).strip()
    if isinstance(contents, list):
        parts = []
        for c in contents:
            parts.append(c if isinstance(c, str) else str(c.get("value", "")))
        return " | ".join(p.strip() for p in parts if p.strip())
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--server", default=SERVER)
    args = ap.parse_args()

    if not os.path.exists(args.server):
        print("the language server is not built; skipping")
        print("  ./bazelw.cmd build //KGEN/tools/mojo-lsp-server")
        return 0

    results = []

    def record(name, ok, detail):
        results.append(ok)
        print(f"  {name:<30} {'PASS' if ok else 'FAIL'}  {detail}")

    print("== navigation ==")
    path = os.path.join(REPO, "build", "navigation-sample.mojo")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(SAMPLE)
    uri = "file:///" + path.replace("\\", "/").lstrip("/")

    srv = Server(args.server, args.verbose)
    try:
        rid = srv.send("initialize", {
            "processId": os.getpid(),
            "rootUri": "file:///" + REPO.replace("\\", "/").lstrip("/"),
            "capabilities": {"textDocument": {
                "definition": {"linkSupport": True},
                "hover": {"contentFormat": ["markdown", "plaintext"]},
                "references": {},
                "documentSymbol": {"hierarchicalDocumentSymbolSupport": True},
            }},
        })
        reply = srv.wait(rid)
        if reply is None:
            record("server", False, "did not answer initialize")
            return 1
        caps = reply["result"].get("capabilities", {})

        # 1. What it says it can do. Advertised is not the same as answers,
        # which is what the rest of this file is about.
        for cap, label in (
            ("definitionProvider", "advertises definition"),
            ("hoverProvider", "advertises hover"),
            ("referencesProvider", "advertises references"),
            ("documentSymbolProvider", "advertises document symbols"),
            ("renameProvider", "advertises rename"),
        ):
            record(label, cap in caps, f"{cap} = {caps.get(cap, 'absent')}")

        srv.send("initialized", {}, want_reply=False)
        srv.send("textDocument/didOpen", {
            "textDocument": {"uri": uri, "languageId": "mojo",
                             "version": 1, "text": SAMPLE},
        }, want_reply=False)
        srv.settle()

        # 2. What it answers, position by position. Reported rather than
        # asserted: this run is the thing that decides what sprint 2.5 can
        # promise, so a null here is a finding and not a failure.
        print("\n  -- definition --")
        answered = 0
        for label, line, char, token in POSITIONS:
            rid = srv.send("textDocument/definition", {
                "textDocument": {"uri": uri},
                "position": {"line": line, "character": char},
            })
            reply = srv.wait(rid)
            got = where(reply.get("result")) if reply else None
            if got:
                answered += 1
            print(f"     {label:<28} {token:<8} -> {got or 'null'}")
        record("definition answers", answered > 0,
               f"{answered} of {len(POSITIONS)} positions resolved")

        print("\n  -- hover --")
        hovered = 0
        for label, line, char, token in POSITIONS:
            rid = srv.send("textDocument/hover", {
                "textDocument": {"uri": uri},
                "position": {"line": line, "character": char},
            })
            reply = srv.wait(rid)
            text = hover_text(reply.get("result")) if reply else None
            if text:
                hovered += 1
            shown = (text or "null").replace("\n", " ")[:70]
            print(f"     {label:<28} {token:<8} -> {shown}")
        record("hover answers", hovered > 0,
               f"{hovered} of {len(POSITIONS)} positions described")

        print("\n  -- references --")
        rid = srv.send("textDocument/references", {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": 5},
            "context": {"includeDeclaration": True},
        })
        reply = srv.wait(rid)
        refs = reply.get("result") if reply else None
        count = len(refs) if isinstance(refs, list) else 0
        for r in (refs or [])[:6]:
            rng = r.get("range", {}).get("start", {})
            print(f"     {os.path.basename(r.get('uri',''))}:"
                  f"{rng.get('line')}:{rng.get('character')}")
        # `helper` is declared once and called twice.
        record("references to a local function", count >= 2,
               f"{count} found for `helper` (declared once, called twice)")

        srv.send("shutdown", {})
    finally:
        try:
            srv.proc.stdin.close()
        except Exception:
            pass
        srv.proc.kill()

    bad = sum(1 for ok in results if not ok)
    print(f"\n{len(results)} checks: {len(results) - bad} passed, {bad} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
