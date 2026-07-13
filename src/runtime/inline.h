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
    #define ORBIT_INLINE __forceinline
    #define ORBIT_NOINLINE __declspec(noinline)
#elif defined(__GNUC__) || defined(__clang__)
    #define ORBIT_INLINE static inline __attribute__((always_inline))
    #define ORBIT_NOINLINE __attribute__((noinline))
#else
    #define ORBIT_INLINE inline
    #define ORBIT_NOINLINE
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
