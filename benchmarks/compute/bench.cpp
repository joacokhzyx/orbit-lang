#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

static uint64_t fib_recursive(uint64_t n) {
    if (n <= 1) return n;
    return fib_recursive(n - 1) + fib_recursive(n - 2);
}

static uint64_t fib_iterative(uint64_t n) {
    constexpr uint64_t MOD = 1'000'000'007ULL;
    if (n <= 1) return n;
    uint64_t a = 0, b = 1;
    for (uint64_t i = 2; i <= n; ++i) {
        uint64_t tmp = (a + b) % MOD;
        a = b;
        b = tmp;
    }
    return b;
}

static uint64_t sieve(uint64_t n) {
    std::vector<bool> composite(n + 1, false);
    uint64_t count = 0;
    for (uint64_t i = 2; i <= n; ++i) {
        if (!composite[i]) {
            ++count;
            for (uint64_t j = i * 2; j <= n; j += i) {
                composite[j] = true;
            }
        }
    }
    return count;
}

static uint64_t sum_loop(uint64_t n) {
    uint64_t s = 0;
    for (uint64_t i = 1; i <= n; ++i) s += i;
    return s;
}

int main(int argc, char* argv[]) {
    if (argc != 3) {
        std::cerr << "usage: bench <test_name> <N>\n";
        return 1;
    }
    std::string test = argv[1];
    uint64_t n = static_cast<uint64_t>(std::stoull(argv[2]));

    using Clock = std::chrono::high_resolution_clock;
    auto t0 = Clock::now();

    uint64_t result = 0;
    if (test == "fib_recursive") {
        result = fib_recursive(n);
    } else if (test == "fib_iterative") {
        result = fib_iterative(n);
    } else if (test == "sieve") {
        result = sieve(n);
    } else if (test == "sum") {
        result = sum_loop(n);
    } else {
        std::cerr << "unknown test: " << test << "\n";
        return 1;
    }

    auto t1 = Clock::now();
    auto elapsed_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();

    std::cout << "time_ns: " << elapsed_ns << "\n";
    std::cout << "result: " << result << "\n";
    return 0;
}
