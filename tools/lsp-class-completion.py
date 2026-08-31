"""Completion inside a COM class body, checked against the metadata.

Sprint 2.4's acceptance, driven directly at the language server. The claim is
specific: put the caret in a `class DropTarget(IDropTarget):` body that has not
implemented `DragOver`, ask for a completion, and be offered `DragOver` with
the parameter types `windows_api.db` records -- not a name to look the rest of
up, and not types somebody remembered.

    python tools/lsp-class-completion.py
    python tools/lsp-class-completion.py --verbose

Kept apart from lsp-probe.py, which is sprint 2.1's "does the server work at
all". This one is about the one feature this fork's server has that no other
Mojo server does.
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

# A class with a hole in it. `DragOver` is missing; the other three are there,
# so the check also proves the offer is filtered by what the body already has.
# `def Drag` on line 7 is the half-typed line the caret sits in.
SAMPLE = '''# A class missing DragOver.
class DropTarget(IDropTarget):
    var drops: Int

    def DragEnter(mut self, d: Int, k: UInt32, p: Int, e: Int) raises:
        pass

    def Drag

    def DragLeave(mut self) raises:
        pass

    def Drop(mut self, d: Int, k: UInt32, p: Int, e: Int) raises:
        self.drops += 1
'''
CARET_LINE = 7          # `    def Drag`
CARET_CHAR = 12         # just past "Drag"

# What the metadata says IDropTarget::DragOver takes. The names are readable
# versions of Windows' own; the types are the database's and are the half that
# has to be right.
WANT_SIGNATURE = "(mut self, key_state: UInt32, pt: Int, effect: Int) raises"


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
            print(f"--> {method}")
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
        """Wait for a parse to finish, which is when diagnostics arrive.

        A completion sent mid-parse is refused with -32801 -- see
        docs/lsp-windows.md, which is where that cost three attempts to learn.
        """
        deadline = time.time() + timeout
        while time.time() < deadline:
            msg = self.read(max(0.5, deadline - time.time()))
            if msg is None:
                return
            if msg.get("method") == "textDocument/publishDiagnostics":
                return


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--server", default=SERVER)
    args = ap.parse_args()

    if not os.path.exists(args.server):
        print("the language server is not built; skipping")
        print("  ./bazelw.cmd build //KGEN/tools/mojo-lsp-server")
        return 0
    if not os.environ.get("MODULAR_MOJO_MAX_WINKB_PATH"):
        print("MODULAR_MOJO_MAX_WINKB_PATH is not set; skipping")
        print("  the server reads the interface's methods out of windows_api.db")
        return 0

    results = []

    def record(name, ok, detail):
        results.append(ok)
        print(f"  {name:<26} {'PASS' if ok else 'FAIL'}  {detail}")

    print("== class completion ==")
    path = os.path.join(REPO, "build", "class-completion.mojo")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(SAMPLE)
    uri = "file:///" + path.replace("\\", "/").lstrip("/")

    srv = Server(args.server, args.verbose)
    try:
        rid = srv.send("initialize", {
            "processId": os.getpid(),
            "rootUri": "file:///" + REPO.replace("\\", "/").lstrip("/"),
            "capabilities": {},
        })
        if srv.wait(rid) is None:
            record("server", False, "did not answer initialize")
            return 1
        srv.send("initialized", {}, want_reply=False)
        srv.send("textDocument/didOpen", {
            "textDocument": {"uri": uri, "languageId": "mojo",
                             "version": 1, "text": SAMPLE},
        }, want_reply=False)
        srv.settle()

        rid = srv.send("textDocument/completion", {
            "textDocument": {"uri": uri},
            "position": {"line": CARET_LINE, "character": CARET_CHAR},
        })
        reply = srv.wait(rid)
        if reply is None or "result" not in reply:
            record("completion", False, f"no result: {reply}")
            return 1
        result = reply["result"]
        items = result.get("items", result if isinstance(result, list) else [])
        by_label = {i.get("label", ""): i for i in items}

        for label in sorted(by_label):
            if args.verbose:
                print(f"       {label:<16} {by_label[label].get('detail','')}")

        # 1. The missing slot is offered.
        record("offers the missing slot", "DragOver" in by_label,
               f"{len(items)} items: " + ", ".join(sorted(by_label)[:6]))

        # 2. With the metadata's parameter types.
        detail = by_label.get("DragOver", {}).get("detail", "")
        record("with the metadata's types", WANT_SIGNATURE in detail,
               detail if detail else "no detail on the item")

        # 3. And its true slot number, which is the fact a hand-written
        # binding gets wrong.
        record("and its vtable slot", "slot 4" in detail,
               "IDropTarget.DragOver is slot 4")

        # 4. Accepting it leaves something that compiles, not a name.
        insert = by_label.get("DragOver", {}).get("insertText", "")
        record("inserts a whole method",
               insert.startswith("DragOver(mut self") and insert.endswith(":"),
               insert if insert else "no insertText")

        # 5. What the body already implements is NOT offered. This is the
        # check that failed first time round: the scan looked only above the
        # caret and cheerfully offered the three methods written below it.
        already = [n for n in ("DragEnter", "DragLeave", "Drop") if n in by_label]
        record("hides what is already there",
               not already,
               "none re-offered" if not already
               else "re-offered: " + ", ".join(already))

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
