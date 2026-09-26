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

#endif
