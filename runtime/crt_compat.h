/**
 * @file  crt_compat.h
 * @brief Portable spellings for the CRT entry points MSVC deprecates.
 *
 * MSVC marks the classic environment/IO/string entry points
 * _CRT_INSECURE_DEPRECATE, so on Windows a -Werror build fails on every use
 * even when the call is correct and bounds-checked. The compiler's own advice
 * is to define _CRT_SECURE_NO_WARNINGS, but that silences the diagnostic
 * without changing the code, so this runtime does not do it.
 *
 * Instead each use is mapped to the secure _s variant under _MSC_VER and to the
 * standard C function everywhere else, with identical observable behaviour,
 * including on failure. Only two entry points need a wrapper: getenv and fopen.
 * Everything else (strcpy/strncpy/sprintf) is expressed with memcpy or snprintf
 * at the call site, where the destination size is already known, which avoids
 * both the deprecation and strcpy_s's habit of aborting the process on an
 * overflow the previous code would have merely performed.
 *
 * Exposed publicly because the C that the Orbit compiler emits calls
 * orbit_env_get() from its generated prelude.
 */
#ifndef ORBIT_CRT_COMPAT_H
#define ORBIT_CRT_COMPAT_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _MSC_VER

/* getenv() hands back a borrowed pointer into the process environment, and
 * callers here rely on that: three of the four copy the value out immediately,
 * and system_env() returns the pointer itself. _dupenv_s() instead returns
 * malloc'd memory, so the value is copied into a per-thread slot. The result
 * stays borrowed (never free it) and stays valid until the next call on the
 * same thread, which is the getenv() contract.
 *
 * Thread-local rather than a plain static so that two workers reading different
 * variables concurrently cannot clobber each other's value. Sized to the
 * Windows limit for a single environment variable, so the copy can never
 * truncate: SetEnvironmentVariable rejects anything longer. */
#  define ORBIT_ENV_VALUE_MAX 32768
static __declspec(thread) char orbit_env_slot[ORBIT_ENV_VALUE_MAX];

/** @brief Read an environment variable, or NULL when it is unset. Borrowed. */
static inline const char* orbit_env_get(const char* name) {
    if (!name) return NULL;
    char* value = NULL;
    size_t need = 0;
    if (_dupenv_s(&value, &need, name) != 0) return NULL;
    if (!value) return NULL;
    size_t n = strlen(value);
    if (n >= ORBIT_ENV_VALUE_MAX) n = ORBIT_ENV_VALUE_MAX - 1;
    memcpy(orbit_env_slot, value, n);
    orbit_env_slot[n] = '\0';
    free(value);
    return orbit_env_slot;
}

/** @brief fopen() with the same contract: the FILE* on success, NULL on failure. */
static inline FILE* orbit_fopen(const char* path, const char* mode) {
    FILE* f = NULL;
    if (fopen_s(&f, path, mode) != 0) return NULL;
    return f;
}

#else

static inline const char* orbit_env_get(const char* name) {
    return name ? getenv(name) : NULL;
}

static inline FILE* orbit_fopen(const char* path, const char* mode) {
    return fopen(path, mode);
}

#endif

/* Setting and clearing an environment variable.
 *
 * Guarded on _WIN32 rather than _MSC_VER, unlike the two above, because the
 * absence is not an MSVC deprecation: MinGW-w64 simply does not declare
 * setenv()/unsetenv() unless the POSIX feature-test macros are turned on, and
 * the Windows CI job compiles with clang against MinGW. The build there failed
 * with -Wimplicit-function-declaration under -Werror, which is the same
 * "correct code, wrong platform" shape the rest of this header exists for.
 *
 * _putenv_s() is the spelling both toolchains agree on. It has no overwrite
 * flag -- the two-argument form always overwrites, which is what the callers
 * mean -- and clearing a variable is setting it to the empty string, not a
 * separate call. Both return 0 on success, like setenv(), so the wrappers keep
 * that contract instead of leaking errno_t. */
#ifdef _WIN32

/* _putenv_s is declared by <process.h> on both toolchains, not by <stdlib.h>
 * where setenv would have been, which is the same asymmetry that hid it. */
#include <process.h>

static inline int orbit_env_set(const char* name, const char* value) {
    if (!name || !value) return -1;
    return _putenv_s(name, value) == 0 ? 0 : -1;
}

static inline int orbit_env_unset(const char* name) {
    if (!name) return -1;
    return _putenv_s(name, "") == 0 ? 0 : -1;
}

#else

static inline int orbit_env_set(const char* name, const char* value) {
    if (!name || !value) return -1;
    return setenv(name, value, 1);
}

static inline int orbit_env_unset(const char* name) {
    if (!name) return -1;
    return unsetenv(name);
}

#endif

/* Append `suffix` to a fixed buffer, bounded, on every platform.
 *
 * strncat() is the obvious way to write this and it is the wrong one on
 * Windows: MSVC marks it __declspec(deprecated) in favour of strncat_s, and
 * this project compiles its runtime with -Werror, so a correct strncat is a
 * build failure there. It is also easy to get wrong by one -- strncat's count
 * is the number of bytes to append, not the space remaining, so the caller has
 * to remember to leave room for the terminator.
 *
 * The whole job is three bytes, so it is spelled out: measure, check, write.
 * One implementation for both platforms, and nothing for the compiler to
 * deprecate.
 */
static inline void orbit_str_append(char* buf, size_t cap, const char* suffix) {
    if (!buf || !suffix || cap == 0) return;
    size_t used = strlen(buf);
    size_t add = strlen(suffix);
    if (used + add + 1 > cap) return;
    memcpy(buf + used, suffix, add + 1);
}

#endif
