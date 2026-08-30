"""Drive the Mojo language server directly, with no editor in the way.

Sprint 2.1. The server has never run on Windows before this sprint, so the
point of the exercise is to find out what it does here while there is nothing
else in the picture to blame. No IDE, no editor integration, no incremental
sync -- one process, stdio, and a transcript.

    python tools/lsp-probe.py                 # the whole handshake and both asks
    python tools/lsp-probe.py --verbose       # with every byte in both directions

What it does, in order: initialize, initialized, didOpen a file that has a
deliberate error in it, wait for the diagnostic the server pushes back, ask
for a completion inside a `Com[...]` chain, and shut down cleanly.

The file it opens uses this repository's COM surface on purpose. A completion
request in a plain Mojo file proves the server is alive; one in a file full of
`Com[StaticString("IDropTarget")]` proves it can parse what this repository
actually writes, which is the part nobody upstream has ever tried.
"""

import argparse
import json
import os
import subprocess
import sys
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = os.path.join(
    REPO, "bazel-bin", "KGEN", "tools", "mojo-lsp-server", "mojo-lsp-server.exe"
)
STDLIB = os.path.join(REPO, "mojo", "stdlib")

# A COM-using file with one deliberate mistake in it, on line 6 (zero-based
# 5): an undefined name, which the compiler certainly rejects.
#
# The first attempt used a misspelled interface -- Com[StaticString("IDropTargt")]
# -- on the assumption that a name no interface has would be an error. It is
# not. The compiler accepts that file, because Com's interface name is only
# checked when a method is called through it: the comptime assert lives in the
# method dispatch, not in the type. So a typo in an interface name survives
# until someone calls something on it. That is worth knowing independently of
# the language server, and it is why this sample now errors in a way both
# tools agree about.
SAMPLE = '''from std.sys.com import Com


def main() raises:
    var target = Com[StaticString("IDropTarget")](borrowed=0)
    var missing = definitely_not_a_function()
    _ = target
    _ = missing
'''

# The same file, mid-keystroke, for the completion asks. Two positions are
# tried and they answer differently -- see the note on member completion in
# docs/lsp-windows.md.
COMPLETION_SAMPLE = '''from std.sys.com import Com


def main() raises:
    var target_handle = Com[StaticString("IDropTarget")](borrowed=0)
    var other = tar
    target_handle.
'''


class Server:
    """A language server on the other end of a pipe."""

    def __init__(self, path, verbose=False):
        self.verbose = verbose
        self.proc = subprocess.Popen(
            [path, "-I", STDLIB],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=REPO,
        )
        self.next_id = 1
        self.stderr_lines = []
        # stderr on its own thread: the server logs there, and a full pipe
        # buffer would deadlock the conversation on stdout.
        t = threading.Thread(target=self._drain_stderr, daemon=True)
        t.start()

    def _drain_stderr(self):
        for line in self.proc.stderr:
            self.stderr_lines.append(line.decode("utf-8", "replace").rstrip())

    def send(self, method, params, want_reply=True):
        """Send one message; returns its id, or None for a notification."""
        msg = {"jsonrpc": "2.0", "method": method, "params": params}
        rid = None
        if want_reply:
            rid = self.next_id
            self.next_id += 1
            msg["id"] = rid
        body = json.dumps(msg).encode("utf-8")
        header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
        if self.verbose:
            print(f"--> {method} {json.dumps(params)[:160]}")
        self.proc.stdin.write(header + body)
        self.proc.stdin.flush()
        return rid

    def read(self, timeout=30.0):
        """Read one message, or None if the server went quiet or away."""
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
        msg = json.loads(body.decode("utf-8"))
        if self.verbose:
            print(f"<-- {json.dumps(msg)[:400]}")
        return msg

    def await_reply(self, rid, timeout=30.0):
        """Read until the reply to `rid` arrives, keeping what came first."""
        others = []
        deadline = time.time() + timeout
        while time.time() < deadline:
            msg = self.read(timeout=max(0.5, deadline - time.time()))
            if msg is None:
                break
            if msg.get("id") == rid and ("result" in msg or "error" in msg):
                return msg, others
            others.append(msg)
        return None, others

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def uri_of(path):
    """A file URI Windows will accept: forward slashes and a leading slash."""
    return "file:///" + path.replace("\\", "/").lstrip("/")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--server", default=SERVER)
    args = ap.parse_args()

    if not os.path.exists(args.server):
        print("not built:", args.server)
        print("  ./bazelw.cmd build //KGEN/tools/mojo-lsp-server")
        return 2

    sample_path = os.path.join(REPO, "build", "lsp-sample.mojo")
    os.makedirs(os.path.dirname(sample_path), exist_ok=True)
    with open(sample_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(SAMPLE)
    uri = uri_of(sample_path)

    results = []
    gaps = []

    def record(name, ok, detail):
        results.append((name, ok, detail))
        print(f"  {name:<22} {'PASS' if ok else 'FAIL'}  {detail}")

    print("== lsp probe ==")
    print("  server:", args.server)
    srv = Server(args.server, args.verbose)

    try:
        # ---- the handshake ------------------------------------------------
        started = time.time()
        rid = srv.send("initialize", {
            "processId": os.getpid(),
            "rootUri": uri_of(REPO),
            "capabilities": {
                "textDocument": {
                    "publishDiagnostics": {"relatedInformation": True},
                    "completion": {
                        "completionItem": {"snippetSupport": False}
                    },
                }
            },
        })
        reply, _ = srv.await_reply(rid)
        if reply is None or "result" not in reply:
            record("initialize", False, "no reply; the server did not start")
            return 1
        caps = reply["result"].get("capabilities", {})
        took = (time.time() - started) * 1000
        record("initialize", True,
               f"{len(caps)} capabilities in {took:.0f} ms")

        offered = sorted(k for k in caps if caps[k])
        record("capabilities", "completionProvider" in caps,
               "offers: " + ", ".join(offered[:6]))

        srv.send("initialized", {}, want_reply=False)

        # ---- open a file, and wait for what the server thinks of it -------
        srv.send("textDocument/didOpen", {
            "textDocument": {
                "uri": uri,
                "languageId": "mojo",
                "version": 1,
                "text": SAMPLE,
            }
        }, want_reply=False)

        diagnostics = None
        deadline = time.time() + 60
        while time.time() < deadline:
            msg = srv.read(timeout=max(0.5, deadline - time.time()))
            if msg is None:
                break
            if msg.get("method") == "textDocument/publishDiagnostics":
                diagnostics = msg["params"].get("diagnostics", [])
                break
        if diagnostics is None:
            record("diagnostic", False, "the server published nothing")
        elif not diagnostics:
            record("diagnostic", False,
                   "published an empty list; the bad interface was accepted")
        else:
            first = diagnostics[0]
            line = first.get("range", {}).get("start", {}).get("line", -1)
            text = first.get("message", "").split("\n")[0][:80]
            # The mistake is on line 5, zero-based.
            record("diagnostic", line == 5,
                   f"line {line + 1}: {text}")

        # ---- completion, after a dot on a Com[...] value ------------------
        # The document is changed to its mid-keystroke form first, because a
        # completion is asked for while someone is typing and `target.` with
        # nothing after it is what the buffer actually contains at that
        # moment. Sending it as a didChange rather than opening a second file
        # is also the shape sprint 2.2 will use for every keystroke.
        srv.send("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 2},
            "contentChanges": [{"text": COMPLETION_SAMPLE}],
        }, want_reply=False)

        version = [2]

        def complete(line, char, trigger=None):
            # A fresh version, and then WAIT for the reparse before asking.
            #
            # A completion sent while the server is still parsing comes back
            # -32801 ContentModified, "outdated request" -- which reads
            # exactly like a server that cannot complete, and is not. The
            # server publishes diagnostics when a parse finishes, so that is
            # the signal to wait for. An editor has to do the same thing or
            # retry, which is worth knowing before sprint 2.2 wires
            # didChange to every keystroke.
            version[0] += 1
            srv.send("textDocument/didChange", {
                "textDocument": {"uri": uri, "version": version[0]},
                "contentChanges": [{"text": COMPLETION_SAMPLE}],
            }, want_reply=False)
            settle = time.time() + 30
            while time.time() < settle:
                msg = srv.read(timeout=max(0.5, settle - time.time()))
                if msg is None:
                    break
                if msg.get("method") == "textDocument/publishDiagnostics":
                    if msg["params"].get("version") == version[0]:
                        break
            params = {
                "textDocument": {"uri": uri},
                "position": {"line": line, "character": char},
            }
            if trigger:
                params["context"] = {
                    "triggerKind": 2, "triggerCharacter": trigger
                }
            rid = srv.send("textDocument/completion", params)
            reply, _ = srv.await_reply(rid, timeout=60)
            if reply is None:
                return None
            if "error" in reply:
                return reply["error"]
            result = reply["result"]
            return result.get(
                "items", result if isinstance(result, list) else []
            )

        # An identifier prefix: `tar` on line 6, where `target_handle` is in
        # scope. This is the completion the acceptance asks for, in a file
        # that uses this repository's COM surface.
        items = complete(5, 19)
        if items is None:
            record("completion", False, "no reply")
        elif isinstance(items, dict):
            record("completion", False, str(items)[:80])
        else:
            labels = [i.get("label", "?") for i in items[:6]]
            record("completion", len(items) > 0,
                   f"{len(items)} items: " + ", ".join(labels))

        # After a dot, which is the trigger character the server advertises.
        # It answers nothing -- not because the document is mid-edit, since a
        # fully valid file with the cursor inside `p.x` answers nothing
        # either, and neither does `self.` in a file that compiles. Reported
        # as a gap rather than a failure: it is what this server does, not a
        # regression, and sprint 2.4 already plans to extend the server in
        # this fork for exactly this.
        members = complete(6, 18, trigger=".")
        if members is None:
            record("member-completion", False, "no reply")
        elif isinstance(members, dict):
            record("member-completion", False, str(members)[:80])
        elif len(members) > 0:
            record("member-completion", True,
                   f"{len(members)} items: "
                   + ", ".join(i.get("label", "?") for i in members[:6]))
        else:
            gaps.append("member completion after `.` returns nothing")
            print("  member-completion       GAP   "
                  "no items after `.`, in valid or mid-edit documents")

        # ---- shut down like an editor would -------------------------------
        rid = srv.send("shutdown", {})
        reply, _ = srv.await_reply(rid, timeout=15)
        record("shutdown", reply is not None and "result" in reply,
               "answered" if reply else "did not answer")
        srv.send("exit", {}, want_reply=False)

    finally:
        srv.close()

    if srv.stderr_lines:
        print("\n  server said on stderr:")
        for line in srv.stderr_lines[:12]:
            print("   ", line)

    bad = sum(1 for _, ok, _ in results if not ok)
    print(f"\n{len(results)} checks: {len(results) - bad} passed, {bad} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
