#!/usr/bin/env python3
"""Drive lldb-dap through one debug session, no editor involved.

The Windows sibling of MojoCocoa's lsp-probe: prove the wire before any UI
consumes it. Speaks DAP (Content-Length framing, like LSP) to lldb-dap over
pipes, loads MojoLLDB via initCommands, sets a breakpoint in the fixture,
and asks the question the whole debugger stack exists to answer:

    do variables come back with names and values?

Usage:
    python tools/dap-probe.py <lldb-dap.exe> <MojoLLDB.dll> <program.exe> \
        <source.mojo> <line>

Exit 0 with "DAP PROBE PASS" only if the stop produced a non-empty variable
list. Everything observed is printed, so a failure is a transcript rather
than a shrug.
"""

import json
import subprocess
import sys
import threading
import queue


def read_messages(pipe, q):
    """Reader thread: parse Content-Length framed messages into a queue."""
    try:
        while True:
            headers = b""
            while not headers.endswith(b"\r\n\r\n"):
                ch = pipe.read(1)
                if not ch:
                    return
                headers += ch
            length = 0
            for line in headers.split(b"\r\n"):
                if line.lower().startswith(b"content-length:"):
                    length = int(line.split(b":")[1])
            body = b""
            while len(body) < length:
                chunk = pipe.read(length - len(body))
                if not chunk:
                    return
                body += chunk
            q.put(json.loads(body))
    except Exception as e:  # reader dies with the process; report why
        q.put({"_reader_error": str(e)})


def main():
    if len(sys.argv) != 6:
        print(__doc__)
        return 2
    dap, plugin, program, source, line = sys.argv[1:6]
    line = int(line)

    proc = subprocess.Popen(
        [dap],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    q = queue.Queue()
    threading.Thread(
        target=read_messages, args=(proc.stdout, q), daemon=True
    ).start()

    seq = [0]

    def send(command, arguments=None):
        seq[0] += 1
        msg = {"seq": seq[0], "type": "request", "command": command}
        if arguments is not None:
            msg["arguments"] = arguments
        body = json.dumps(msg).encode()
        proc.stdin.write(
            b"Content-Length: %d\r\n\r\n%s" % (len(body), body)
        )
        proc.stdin.flush()
        return seq[0]

    def wait_for(pred, what, timeout=60):
        import time

        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                m = q.get(timeout=deadline - time.time())
            except queue.Empty:
                break
            if "_reader_error" in m:
                print("reader ended:", m["_reader_error"])
                break
            kind = m.get("type")
            name = m.get("command") or m.get("event")
            print(f"  <- {kind} {name}"
                  + (f" ok={m.get('success')}" if kind == "response" else ""))
            if kind == "response" and not m.get("success", True):
                print("     !", m.get("message"),
                      json.dumps(m.get("body", {}))[:200])
            if pred(m):
                return m
        print(f"TIMEOUT waiting for {what}")
        proc.kill()
        sys.exit(1)

    print("-> initialize")
    send("initialize", {"adapterID": "mojo", "linesStartAt1": True})
    wait_for(lambda m: m.get("command") == "initialize"
             and m.get("type") == "response", "initialize response")

    print("-> launch (plugin via initCommands)")
    send("launch", {
        "program": program,
        "initCommands": [f"plugin load {plugin}"],
        "stopOnEntry": False,
    })
    wait_for(lambda m: m.get("event") == "initialized", "initialized event")

    print(f"-> setBreakpoints {source}:{line}")
    send("setBreakpoints", {
        "source": {"path": source},
        "breakpoints": [{"line": line}],
    })
    bp = wait_for(lambda m: m.get("command") == "setBreakpoints",
                  "breakpoint response")
    verified = bp["body"]["breakpoints"][0].get("verified")
    print(f"   breakpoint verified: {verified}")

    send("configurationDone")
    stop = wait_for(lambda m: m.get("event") == "stopped", "stopped event")
    print(f"   stopped: {stop['body'].get('reason')}")

    tid = stop["body"]["threadId"]
    send("stackTrace", {"threadId": tid})
    st = wait_for(lambda m: m.get("command") == "stackTrace", "stack")
    top = st["body"]["stackFrames"][0]
    print(f"   top frame: {top.get('name')} "
          f"({top.get('source', {}).get('name')}:{top.get('line')})")

    send("scopes", {"frameId": top["id"]})
    sc = wait_for(lambda m: m.get("command") == "scopes", "scopes")
    ref = sc["body"]["scopes"][0]["variablesReference"]
    print(f"   first scope: {sc['body']['scopes'][0]['name']}")

    send("variables", {"variablesReference": ref})
    vs = wait_for(lambda m: m.get("command") == "variables", "variables")
    variables = vs["body"]["variables"]
    for v in variables:
        print(f"   {v['name']} = {v.get('value')!r}  ({v.get('type')})")

    send("disconnect", {"terminateDebuggee": True})
    proc.wait(timeout=15)

    if verified and variables:
        print(f"DAP PROBE PASS -- breakpoint verified, "
              f"{len(variables)} variable(s) with values")
        return 0
    print("DAP PROBE FAIL -- "
          + ("no variables" if verified else "breakpoint never verified"))
    return 1


if __name__ == "__main__":
    sys.exit(main())
