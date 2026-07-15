#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static uint64_t get_time_ns(void) {
    LARGE_INTEGER freq, counter;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&counter);
    /* Convert to nanoseconds: counter * 1e9 / freq */
    return (uint64_t)((__int128)counter.QuadPart * 1000000000ULL / freq.QuadPart);
}
#else
#include <time.h>

static uint64_t get_time_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}
#endif

static uint64_t fib_recursive(uint64_t n) {
    if (n <= 1) return n;
    return fib_recursive(n - 1) + fib_recursive(n - 2);
}

static uint64_t fib_iterative(uint64_t n) {
    const uint64_t MOD = 1000000007ULL;
    if (n <= 1) return n;
    uint64_t a = 0, b = 1;
    for (uint64_t i = 2; i <= n; i++) {
        uint64_t tmp = (a + b) % MOD;
        a = b;
        b = tmp;
    }
    return b;
}

static uint64_t sieve(uint64_t n) {
    char *composite = (char *)calloc(n + 1, sizeof(char));
    if (!composite) { fprintf(stderr, "OOM\n"); exit(1); }
    uint64_t count = 0;
    for (uint64_t i = 2; i <= n; i++) {
        if (!composite[i]) {
            count++;
            for (uint64_t j = i * 2; j <= n; j += i) {
                composite[j] = 1;
            }
        }
    }
    free(composite);
    return count;
}

static uint64_t sum_loop(uint64_t n) {
    uint64_t s = 0;
    for (uint64_t i = 1; i <= n; i++) s += i;
    return s;
}

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "usage: bench <test_name> <N>\n");
        return 1;
    }
    const char *test = argv[1];
    uint64_t n = (uint64_t)strtoull(argv[2], NULL, 10);

    uint64_t t0 = get_time_ns();
    uint64_t result = 0;

    if (strcmp(test, "fib_recursive") == 0) {
        result = fib_recursive(n);
    } else if (strcmp(test, "fib_iterative") == 0) {
        result = fib_iterative(n);
    } else if (strcmp(test, "sieve") == 0) {
        result = sieve(n);
    } else if (strcmp(test, "sum") == 0) {
        result = sum_loop(n);
    } else {
        fprintf(stderr, "unknown test: %s\n", test);
        return 1;
    }

    uint64_t t1 = get_time_ns();

    printf("time_ns: %llu\n", (unsigned long long)(t1 - t0));
    printf("result: %llu\n", (unsigned long long)result);
    return 0;
}
