# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #
"""Runs both halves of the comparison and prints a side-by-side table.

Usage:
    python run_bench.py --mojo <path to mojo.exe> [--import-path <std dir>]
                        [--compiler-rt <KGENCompilerRTShared.dll>]

The Mojo half is compiled to a native binary first (`mojo build`), so the
reported times are execution only, with no compilation in the measurement.
Checksums from both languages are compared; a mismatch means the two
implementations diverged and the timings are not comparable.
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def parse_output(text):
    """Parses 'name , seconds , checksum' lines into an ordered dict."""
    results = {}
    for line in text.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) != 3 or parts[0] in ("benchmark", ""):
            continue
        try:
            results[parts[0]] = (float(parts[1]), parts[2])
        except ValueError:
            continue
    return results


def run(cmd, env=None, cwd=None):
    proc = subprocess.run(
        cmd, capture_output=True, text=True, env=env, cwd=cwd
    )
    if proc.returncode != 0:
        print(f"command failed ({proc.returncode}): {' '.join(map(str, cmd))}")
        print(proc.stdout[-4000:])
        print(proc.stderr[-4000:], file=sys.stderr)
        sys.exit(1)
    return proc.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mojo", required=True)
    ap.add_argument("--import-path")
    ap.add_argument("--compiler-rt")
    ap.add_argument("--python", default=sys.executable)
    args = ap.parse_args()

    env = dict(os.environ)
    env["MODULAR_CRASH_REPORTING_ENABLED"] = "false"
    if args.import_path:
        env["MODULAR_MOJO_MAX_IMPORT_PATH"] = args.import_path
    if args.compiler_rt:
        env["MODULAR_MOJO_MAX_COMPILERRT_PATH"] = args.compiler_rt
        # The loader finds dependency DLLs through PATH on Windows.
        env["PATH"] = str(Path(args.compiler_rt).parent) + os.pathsep + env["PATH"]

    with tempfile.TemporaryDirectory() as td:
        exe = Path(td) / ("bench_mojo.exe" if os.name == "nt" else "bench_mojo")
        print("building the Mojo benchmark ...", flush=True)
        run(
            [args.mojo, "build", "-o", str(exe), str(HERE / "bench_common.mojo")],
            env=env,
        )

        print("running Mojo ...", flush=True)
        mojo_out = run([str(exe)], env=env)

        print("running Python ...", flush=True)
        py_out = run([args.python, str(HERE / "bench_common.py")], env=env)

    mojo = parse_output(mojo_out)
    py = parse_output(py_out)

    name_w = max([len(n) for n in mojo] + [len("benchmark")]) + 2
    print()
    print(
        f"{'benchmark':<{name_w}}{'mojo (s)':>12}{'python (s)':>12}"
        f"{'speedup':>10}  checksums"
    )
    print("-" * (name_w + 34 + 12))

    speedups = []
    for name in mojo:
        if name not in py:
            continue
        m_time, m_sum = mojo[name]
        p_time, p_sum = py[name]
        ratio = p_time / m_time if m_time > 0 else float("inf")
        speedups.append(ratio)
        agree = "match" if m_sum == p_sum else f"DIFFER {m_sum} vs {p_sum}"
        print(
            f"{name:<{name_w}}{m_time:>12.4f}{p_time:>12.4f}"
            f"{ratio:>9.1f}x  {agree}"
        )

    if speedups:
        geo = 1.0
        for s in speedups:
            geo *= s
        geo **= 1.0 / len(speedups)
        print("-" * (name_w + 34 + 12))
        print(f"{'geometric mean':<{name_w}}{'':>24}{geo:>9.1f}x")


if __name__ == "__main__":
    main()
