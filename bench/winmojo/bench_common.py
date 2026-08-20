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
"""Python half of the Windows ARM64 Mojo-vs-Python comparison.

A line-for-line counterpart of bench_common.mojo: same algorithms, same
sizes, same checksums, written the way each would ordinarily be written in
its own language. No numpy — the point is to compare the languages'
own execution, not to benchmark a C library through Python.
"""

import time


def bench_fib(n):
    def fib(k):
        if k < 2:
            return k
        return fib(k - 1) + fib(k - 2)

    return fib(n)


def bench_sieve(limit):
    flags = [True] * (limit + 1)
    count = 0
    for i in range(2, limit + 1):
        if flags[i]:
            count += 1
            j = i * i
            while j <= limit:
                flags[j] = False
                j += i
    return count


def bench_matmul(n):
    a = [float(i % 100) * 0.5 for i in range(n * n)]
    b = [float(i % 7) * 1.5 for i in range(n * n)]
    c = [0.0] * (n * n)

    for i in range(n):
        for k in range(n):
            aik = a[i * n + k]
            for j in range(n):
                c[i * n + j] += aik * b[k * n + j]

    return sum(c)


def bench_mandelbrot(width, height, max_iter):
    total = 0
    for py in range(height):
        y0 = -1.25 + 2.5 * py / height
        for px in range(width):
            x0 = -2.0 + 3.0 * px / width
            x = 0.0
            y = 0.0
            it = 0
            while x * x + y * y <= 4.0 and it < max_iter:
                xt = x * x - y * y + x0
                y = 2.0 * x * y + y0
                x = xt
                it += 1
            total += it
    return total


def bench_string_ops(rounds):
    total = 0
    for _ in range(rounds):
        s = ""
        for i in range(64):
            s += str(i % 10)
        total += len(s)
        if s.startswith("0"):
            total += 1
    return total


def report(name, seconds, checksum):
    print(f"{name} , {seconds} , {checksum}")


def main():
    print("benchmark,seconds,checksum")

    t0 = time.monotonic_ns()
    r = bench_fib(30)
    t1 = time.monotonic_ns()
    report("fib(30)", (t1 - t0) / 1e9, r)

    t0 = time.monotonic_ns()
    r = bench_sieve(2_000_000)
    t1 = time.monotonic_ns()
    report("sieve(2e6)", (t1 - t0) / 1e9, r)

    t0 = time.monotonic_ns()
    r = bench_matmul(200)
    t1 = time.monotonic_ns()
    report("matmul(200)", (t1 - t0) / 1e9, r)

    t0 = time.monotonic_ns()
    r = bench_mandelbrot(300, 200, 500)
    t1 = time.monotonic_ns()
    report("mandelbrot(300x200)", (t1 - t0) / 1e9, r)

    t0 = time.monotonic_ns()
    r = bench_string_ops(20_000)
    t1 = time.monotonic_ns()
    report("string_ops(20k)", (t1 - t0) / 1e9, r)


if __name__ == "__main__":
    main()
