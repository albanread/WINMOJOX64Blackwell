"""Run a graph on the Hexagon NPU, with the control discipline enforced, and
log everything to a wedge case file.

The DSP session layer wedges. Once wedged, every HTP run fails identically at
session open regardless of what you ask it to do, so any measurement taken
after the first failure is worthless. The only way to tell a real limit from a
wedge is to re-run a known-good small model immediately afterwards.

This tool refuses to let you skip that, and records every run - pass or fail -
to `wedge-log.jsonl` so the trigger can eventually be identified from evidence
rather than recollection.

    python htp_run.py --model mm.dll --dim 512 --label "4 MiB baseline"
    python htp_run.py --report
    python htp_run.py --note "rebooted"        # mark a recovery boundary

Every record carries the machine state that might matter: uptime, driver
versions, what else was holding the NPU. If a pattern exists, it will be in
there.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import struct
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
LOG = HERE / "wedge-log.jsonl"
SDK = pathlib.Path(os.environ.get("QNN_SDK_ROOT", r"C:\Qualcomm\AIStack\qairt\2.42.0.251225"))
LIB = SDK / "lib" / "aarch64-windows-msvc"
NETRUN = SDK / "bin" / "aarch64-windows-msvc" / "qnn-net-run.exe"
SKELS = SDK / "lib" / "hexagon-v81" / "unsigned"

WEDGE_SIG = "DspTransport.openSession"


def env() -> dict:
    e = dict(os.environ)
    e["PATH"] = f"{LIB};{SDK / 'bin' / 'aarch64-windows-msvc'};" + e.get("PATH", "")
    e["ADSP_LIBRARY_PATH"] = str(SKELS)
    return e


def ps(cmd: str) -> str:
    try:
        r = subprocess.run(
            ["powershell", "-NoProfile", "-Command", cmd],
            capture_output=True, text=True, timeout=60,
        )
        return r.stdout.strip()
    except Exception:
        return ""


def machine_state() -> dict:
    """Everything cheap that might correlate with a wedge."""
    boot = ps("(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')")
    drivers = ps(
        "pnputil /enum-drivers | Select-String -Context 0,3 'qcnspmcdm' | "
        "Select-String 'Version' | ForEach-Object { $_.ToString().Trim() }"
    )
    holders = ps(
        "(Get-Process | Where-Object { $_.ProcessName -match "
        "'geniex|llama|qnn|net-run|onnxruntime|genie' } | "
        "ForEach-Object { $_.ProcessName }) -join ','"
    )
    npu = ps(
        "(Get-PnpDevice | Where-Object { $_.FriendlyName -match 'Hexagon' } | "
        "Select-Object -First 1 -ExpandProperty Status)"
    )
    return {
        "boot_time": boot,
        "npu_device_status": npu,
        "nsp_driver_versions": [x for x in drivers.splitlines() if x][:4],
        "other_npu_processes": [x for x in holders.split(",") if x],
    }


def stage_control(work: pathlib.Path, dim: int = 512) -> pathlib.Path:
    """A tiny known-good input for the control model."""
    d = work / "control_in"
    d.mkdir(parents=True, exist_ok=True)
    raw = d / "x.raw"
    if not raw.exists():
        raw.write_bytes(b"".join(struct.pack("<f", (i % 13 - 6) / 32.0) for i in range(dim)))
    lst = work / "control_list.txt"
    lst.write_text("input_0:=control_in/x.raw\n", encoding="utf-8")
    return lst


def run_netrun(model: pathlib.Path, input_list: pathlib.Path, outdir: pathlib.Path,
               backend: str = "QnnHtp.dll") -> dict:
    t0 = time.time()
    try:
        r = subprocess.run(
            [str(NETRUN), "--backend", str(LIB / backend), "--model", str(model),
             "--input_list", str(input_list), "--output_dir", str(outdir)],
            capture_output=True, text=True, env=env(), cwd=str(input_list.parent),
            timeout=900,
        )
        out = (r.stdout or "") + (r.stderr or "")
    except subprocess.TimeoutExpired:
        return {"ok": False, "ms": 900_000, "error": "TIMEOUT", "wedge_signature": False}
    ms = (time.time() - t0) * 1000

    ok = "Finished Executing Graphs" in out
    err = ""
    m = re.search(r"\[\s*ERROR\s*\].*", out)
    if m:
        err = re.sub(r"\s+", " ", m.group(0))[:300]
    return {
        "ok": ok,
        "ms": round(ms, 1),
        "error": err,
        "wedge_signature": WEDGE_SIG in out,
    }


def append(rec: dict) -> None:
    rec["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    with LOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")


def cmd_run(a) -> int:
    work = pathlib.Path(a.work or (HERE / "_htpwork"))
    work.mkdir(parents=True, exist_ok=True)
    model = pathlib.Path(a.model).resolve()
    control = pathlib.Path(a.control).resolve() if a.control else None

    clist = stage_control(work) if control else None

    # 1. Control BEFORE. If the DSP is already wedged, nothing measured after
    #    this point means anything, so stop rather than generate noise.
    pre = None
    if control:
        pre = run_netrun(control, clist, work / "out_pre")
        if not pre["ok"]:
            rec = {"kind": "blocked", "label": a.label, "reason": "DSP already wedged",
                   "control_before": pre, "machine": machine_state()}
            append(rec)
            print("DSP IS ALREADY WEDGED - nothing measured now would mean anything.")
            print(f"  {pre['error']}")
            print("  Reboot, then re-run. Logged as 'blocked'.")
            return 2
        print(f"control before: ok ({pre['ms']:.0f} ms)")

    # 2. The actual run.
    main = run_netrun(model, pathlib.Path(a.input_list).resolve(), work / "out_main")
    print(f"run: {'ok' if main['ok'] else 'FAIL'} ({main['ms']:.0f} ms)")
    if main["error"]:
        print(f"  {main['error']}")

    # 3. Control AFTER - the whole point of the exercise.
    post, verdict = None, "ok"
    if not main["ok"] and control:
        print("  running control to distinguish a real limit from a wedge...")
        post = run_netrun(control, clist, work / "out_post")
        if post["ok"]:
            verdict = "real_failure"
            print("  -> REAL FAILURE: control still passes, this workload genuinely failed")
        else:
            verdict = "wedged"
            print("  -> WEDGED: control now fails too; this result proves nothing")
            print("  -> Reboot before measuring anything else.")
    elif not main["ok"]:
        verdict = "unknown_no_control"

    append({
        "kind": "run",
        "label": a.label,
        "verdict": verdict,
        "model": str(model),
        "model_bytes": model.stat().st_size if model.exists() else None,
        "dim": a.dim,
        "layers": a.layers,
        "weight_bytes": (a.dim * a.dim * 4 * a.layers) if (a.dim and a.layers) else None,
        "backend": "QnnHtp.dll",
        "result": main,
        "control_before": pre,
        "control_after": post,
        "machine": machine_state(),
    })
    return 0 if main["ok"] else 1


def cmd_note(a) -> int:
    append({"kind": "note", "text": a.note, "machine": machine_state()})
    print(f"logged note: {a.note}")
    return 0


def cmd_report(a) -> int:
    if not LOG.exists():
        print("no wedge log yet")
        return 0
    recs = [json.loads(l) for l in LOG.read_text(encoding="utf-8").splitlines() if l.strip()]
    runs = [r for r in recs if r.get("kind") == "run"]
    wedges = [r for r in runs if r.get("verdict") == "wedged"]
    real = [r for r in runs if r.get("verdict") == "real_failure"]
    oks = [r for r in runs if r.get("verdict") == "ok"]

    print(f"{len(recs)} records: {len(oks)} ok, {len(real)} real failures, "
          f"{len(wedges)} wedges, {len(recs) - len(runs)} notes/blocked\n")

    if oks:
        big = max(oks, key=lambda r: r.get("weight_bytes") or 0)
        wb = big.get("weight_bytes")
        if wb:
            print(f"largest weight set that RAN on HTP: {wb / 1024**2:.1f} MiB "
                  f"({big.get('label') or big['ts']})")
    if real:
        small = min(real, key=lambda r: r.get("weight_bytes") or 1 << 60)
        wb = small.get("weight_bytes")
        if wb:
            print(f"smallest weight set that GENUINELY FAILED: {wb / 1024**2:.1f} MiB")
    else:
        print("no genuine (control-verified) failures recorded yet - "
              "so no ceiling has actually been measured")

    if wedges:
        print(f"\nwedge events ({len(wedges)}):")
        for w in wedges:
            wb = w.get("weight_bytes")
            size = f"{wb / 1024**2:.1f} MiB" if wb else "?"
            print(f"  {w['ts']}  {size:>10}  {w.get('label') or ''}")
            print(f"      uptime-boot {w['machine'].get('boot_time','?')}")
            others = w["machine"].get("other_npu_processes") or []
            if others:
                print(f"      other NPU users at the time: {', '.join(others)}")
        print("\nlook for what the wedge events share and the ok runs do not.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model")
    ap.add_argument("--input-list", dest="input_list")
    ap.add_argument("--control", help="path to a known-good small model DLL")
    ap.add_argument("--work")
    ap.add_argument("--dim", type=int)
    ap.add_argument("--layers", type=int)
    ap.add_argument("--label", default="")
    ap.add_argument("--note")
    ap.add_argument("--report", action="store_true")
    a = ap.parse_args()

    if a.report:
        return cmd_report(a)
    if a.note:
        return cmd_note(a)
    if not (a.model and a.input_list):
        ap.error("--model and --input-list are required (or use --report / --note)")
    return cmd_run(a)


if __name__ == "__main__":
    sys.exit(main())
