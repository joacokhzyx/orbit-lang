/**
 * @file  inline.h
 * @brief Compiler-portability macros for inlining, branch prediction, and prefetch hints.
 *
 * Provides ORBIT_INLINE / ORBIT_NOINLINE, branch-likelihood hints (ORBIT_LIKELY /
 * ORBIT_UNLIKELY), cache-prefetch helpers, and the ORBIT_RESTRICT alias — all
 * normalised across MSVC, GCC, and Clang.
 */
#ifndef ORBIT_INLINE_H
#define ORBIT_INLINE_H

#include <stdint.h>

#ifdef _MSC_VER
    /* `static` is not optional here, and must lead: ORBIT_INLINE is used on
     * definitions in .c files and in headers, and every branch has to agree on
     * the linkage. Without it the MSVC/clang-cl path gave these functions
     * external linkage while the file-static helpers they call (orbit_result_ok,
     * orbit_result_err, orbit_perf_stats) stayed internal, which clang reports
     * as "using static function/variable 'X' in an inline function with external
     * linkage is a C2y extension" (-Wstatic-in-inline). That is a hard -Werror
     * failure on Windows, where _MSC_VER is defined for clang itself, and it
     * never shows up on gcc/Linux. Keep these three branches byte-identical in
     * their linkage. */
    #define ORBIT_INLINE static __forceinline
    #define ORBIT_NOINLINE __declspec(noinline)
    #define ORBIT_UNUSED
#elif defined(__GNUC__) || defined(__clang__)
    #define ORBIT_INLINE static inline __attribute__((always_inline))
    #define ORBIT_NOINLINE __attribute__((noinline))
    #define ORBIT_UNUSED __attribute__((unused))
#else
    #define ORBIT_INLINE static inline
    #define ORBIT_NOINLINE
    #define ORBIT_UNUSED
#endif

#define ORBIT_HOT __attribute__((hot))
#define ORBIT_COLD __attribute__((cold))
#define ORBIT_PURE __attribute__((pure))
#define ORBIT_CONST __attribute__((const))

#define ORBIT_LIKELY(x) __builtin_expect(!!(x), 1)
#define ORBIT_UNLIKELY(x) __builtin_expect(!!(x), 0)

#define ORBIT_PREFETCH_READ(addr) __builtin_prefetch(addr, 0, 3)
#define ORBIT_PREFETCH_WRITE(addr) __builtin_prefetch(addr, 1, 3)

#define ORBIT_RESTRICT __restrict

#ifdef _MSC_VER
    #define ORBIT_NORETURN __declspec(noreturn)
#else
    #define ORBIT_NORETURN __attribute__((noreturn))
#endif

/* Integer division is checked. A divisor of 0 and INT64_MIN / -1 have no
 * answer an int can hold, and C leaves both undefined (SIGFPE on x86-64). The
 * program stops instead: kind 0 is a zero divisor, kind 1 is the overflowing
 * quotient (and remainder, which C also traps). The diagnostic names the Orbit
 * source file and line the emitter passes in; exit status is 2, as for an
 * out-of-range list index. Defined in collections.c. */
ORBIT_NORETURN void orbit_div_error(const char* file, int64_t line, int64_t kind);

/* One unsigned compare catches both divisors that can fail: b + 1 is 0 for -1
 * and 1 for 0, and larger for every other value. */
ORBIT_INLINE int64_t orbit_int_div(int64_t a, int64_t b, const char* file, int64_t line) {
    if (ORBIT_UNLIKELY((uint64_t)b + 1u <= 1u)) {
        if (b == 0) orbit_div_error(file, line, 0);
        if (a == INT64_MIN) orbit_div_error(file, line, 1);
    }
    return a / b;
}

ORBIT_INLINE int64_t orbit_int_mod(int64_t a, int64_t b, const char* file, int64_t line) {
    if (ORBIT_UNLIKELY((uint64_t)b + 1u <= 1u)) {
        if (b == 0) orbit_div_error(file, line, 0);
        if (a == INT64_MIN) orbit_div_error(file, line, 1);
    }
    return a % b;
}

#endif
