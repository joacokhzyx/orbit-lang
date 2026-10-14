/*
 * tcc_toolchain.h -- spelling fixes consumed via `-include tcc_toolchain.h`.
 *
 * Each mapping below is a measured tcc 0.9.27 gap (Windows x64,
 * 2026-10-14), not a guess: the probe that proved the gap is named.
 *
 *   1. GetTickCount64 -> GetTickCount.
 *      tcc's winbase.h declares no GetTickCount64 and its kernel32.def
 *      does not import it, so both the compile and the link fail
 *      (probes/winbase_probe.c: implicit declaration + undefined symbol).
 *      GetTickCount is a real import in the same .def, so the mapping
 *      compiles AND links. Cost, stated plainly: GetTickCount wraps every
 *      ~49 days while GetTickCount64 does not, so a tcc-built binary must
 *      never be the one whose uptime or energy numbers anyone quotes
 *      (docs/TOOLCHAIN.md makes that a rule, not advice).
 *
 *   2. YieldProcessor -> Sleep(0).
 *      tcc's winnt.h defines YieldProcessor as _mm_pause, which has no
 *      implementation behind it (undefined symbol at link). Sleep(0) is a
 *      real kernel32 import and yields the timeslice, which is a stronger
 *      concession than a pause hint: correct wherever the spinlock is
 *      correct, slower where it is hot. The `#undef` matters because the
 *      winnt.h spelling warns on redefinition, and a warning is a failure
 *      under -Werror.
 *
 *   3. strtoll -> _strtoi64, strtoull -> _strtoui64.
 *      tcc's stdlib.h DECLARES strtoll/strtoull but its msvcrt.def imports
 *      neither (undefined symbol at link, probes/strtoll_probe.c), while
 *      _strtoi64/_strtoui64 are declared AND imported. Same signature
 *      (const char *, char **, int), same semantics.
 *
 * Everything is guarded on __TINYC__ so that including this file under
 * gcc/clang is a no-op: without the guard the GetTickCount64 mapping
 * would silently downgrade a working 64-bit clock on toolchains that
 * have one, which is exactly the class of quiet wrongness this shim
 * exists to prevent.
 */
#ifndef _ORBIT_TCC_TOOLCHAIN_H
#define _ORBIT_TCC_TOOLCHAIN_H

#ifdef __TINYC__

/* Same exclusion runtime/socket_compat.h applies: without it tcc's own
 * windows.h pulls in its Winsock v1 header, whose WSAE* macros then
 * collide with the shim's winsock2.h (measured: five redefinition
 * warnings, fatal under -Werror). */
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN 1
#endif

#include <windows.h>
#include <stdlib.h>

/* 1. 64-bit tick count from the 32-bit one. Wraps ~49 days: never quote
 * a tcc-built binary's clock past a restart (see docs/TOOLCHAIN.md). */
#define GetTickCount64() ((ULONGLONG)GetTickCount())

/* 2. Spin hint without an implementation behind it -> yield the slice. */
#ifdef YieldProcessor
#undef YieldProcessor
#endif
#define YieldProcessor() Sleep(0)

/* 3. CRT names tcc declares but does not import -> the ones it does. */
#define strtoll _strtoi64
#define strtoull _strtoui64

#endif /* __TINYC__ */

#endif /* _ORBIT_TCC_TOOLCHAIN_H */
