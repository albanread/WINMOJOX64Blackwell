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
"""Mojo half of the Windows ARM64 Mojo-vs-Python comparison.

Deliberately plain Mojo: no SIMD intrinsics, no parallelism, no unrolling
hints. Each kernel is written the way the equivalent Python is written, so
the comparison measures what a straightforward port of ordinary code gains,
not what a hand-tuned kernel can reach. Every kernel returns a checksum that
is printed, which also keeps the optimizer from deleting the work.

Timings use monotonic() from the standard library, which on Windows is the
QueryPerformanceCounter path added by this port.
"""

from std.time import monotonic
from std.math import sqrt


def bench_fib(n: Int) -> Int:
    """Recursive fibonacci: call overhead and integer arithmetic."""

    def fib(k: Int) -> Int:
        if k < 2:
            return k
        return fib(k - 1) + fib(k - 2)

    return fib(n)


def bench_sieve(limit: Int) -> Int:
    """Sieve of Eratosthenes: list indexing and tight loops."""
    var flags = List[Bool]()
    for _ in range(limit + 1):
        flags.append(True)

    var count = 0
    for i in range(2, limit + 1):
        if flags[i]:
            count += 1
            var j = i * i
            while j <= limit:
                flags[j] = False
                j += i
    return count


def bench_matmul(n: Int) -> Float64:
    """Naive triple-loop matrix multiply: float math and 2D indexing."""
    var a = List[Float64]()
    var b = List[Float64]()
    var c = List[Float64]()
    for i in range(n * n):
        a.append(Float64(i % 100) * 0.5)
        b.append(Float64(i % 7) * 1.5)
        c.append(0.0)

    for i in range(n):
        for k in range(n):
            var aik = a[i * n + k]
            for j in range(n):
                c[i * n + j] += aik * b[k * n + j]

    var total = 0.0
    for i in range(n * n):
        total += c[i]
    return total


def bench_mandelbrot(width: Int, height: Int, max_iter: Int) -> Int:
    """Mandelbrot escape counts: float-heavy inner loop with a branch."""
    var total = 0
    for py in range(height):
        var y0 = -1.25 + 2.5 * Float64(py) / Float64(height)
        for px in range(width):
            var x0 = -2.0 + 3.0 * Float64(px) / Float64(width)
            var x = 0.0
            var y = 0.0
            var it = 0
            while x * x + y * y <= 4.0 and it < max_iter:
                var xt = x * x - y * y + x0
                y = 2.0 * x * y + y0
                x = xt
                it += 1
            total += it
    return total


def bench_string_ops(rounds: Int) -> Int:
    """String building and comparison."""
    var total = 0
    for r in range(rounds):
        var s = String("")
        for i in range(64):
            s += String(i % 10)
        total += len(s)
        if s.startswith("0"):
            total += 1
    return total


def report(name: String, seconds: Float64, checksum: String):
    print(name, ",", seconds, ",", checksum)


def main():
    # name,seconds,checksum — parsed by run_bench.py
    print("benchmark,seconds,checksum")

    var t0 = monotonic()
    var fib_result = bench_fib(30)
    var t1 = monotonic()
    report("fib(30)", Float64(t1 - t0) / 1.0e9, String(fib_result))

    t0 = monotonic()
    var sieve_result = bench_sieve(2_000_000)
    t1 = monotonic()
    report("sieve(2e6)", Float64(t1 - t0) / 1.0e9, String(sieve_result))

    t0 = monotonic()
    var matmul_result = bench_matmul(200)
    t1 = monotonic()
    report("matmul(200)", Float64(t1 - t0) / 1.0e9, String(matmul_result))

    t0 = monotonic()
    var mandel_result = bench_mandelbrot(300, 200, 500)
    t1 = monotonic()
    report("mandelbrot(300x200)", Float64(t1 - t0) / 1.0e9, String(mandel_result))

    t0 = monotonic()
    var string_result = bench_string_ops(20_000)
    t1 = monotonic()
    report("string_ops(20k)", Float64(t1 - t0) / 1.0e9, String(string_result))
