import sys
import time


def fib_recursive(n: int) -> int:
    if n <= 1:
        return n
    return fib_recursive(n - 1) + fib_recursive(n - 2)


def fib_iterative(n: int) -> int:
    MOD = 1_000_000_007
    if n <= 1:
        return n
    a, b = 0, 1
    for _ in range(2, n + 1):
        a, b = b, (a + b) % MOD
    return b


def sieve(n: int) -> int:
    composite = bytearray(n + 1)
    count = 0
    i = 2
    while i <= n:
        if not composite[i]:
            count += 1
            j = i * 2
            while j <= n:
                composite[j] = 1
                j += i
        i += 1
    return count


def sum_loop(n: int) -> int:
    s = 0
    for i in range(1, n + 1):
        s += i
    return s


def main() -> None:
    if len(sys.argv) != 3:
        print("usage: bench.py <test_name> <N>", file=sys.stderr)
        sys.exit(1)

    test = sys.argv[1]
    n = int(sys.argv[2])

    t0 = time.perf_counter_ns()

    if test == "fib_recursive":
        result = fib_recursive(n)
    elif test == "fib_iterative":
        result = fib_iterative(n)
    elif test == "sieve":
        result = sieve(n)
    elif test == "sum":
        result = sum_loop(n)
    else:
        print(f"unknown test: {test}", file=sys.stderr)
        sys.exit(1)

    elapsed = time.perf_counter_ns() - t0

    print(f"time_ns: {elapsed}")
    print(f"result: {result}")


if __name__ == "__main__":
    main()
