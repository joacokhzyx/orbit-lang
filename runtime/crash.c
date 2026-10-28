#ifndef ORBIT_RT_CRASH_C
#define ORBIT_RT_CRASH_C

#include "module_prelude.h"
#include "crash.h"

#ifdef _WIN32
#include <windows.h>
#include <stdio.h>
#include <stdint.h>

/* Hex without printf: this module sits in every program, and the format
 * engine would cost more .text than everything else here. */
static void orbit_crash_put_hex(char* out, uintptr_t v, int digits) {
    for (int i = digits - 1; i >= 0; i--) {
        out[i] = "0123456789ABCDEF"[v & 15];
        v >>= 4;
    }
}

static LONG WINAPI orbit_crash_handler(EXCEPTION_POINTERS* ep) {
    char line[96] = "\n[ORBIT RUNTIME CRASH] ExceptionCode 0x00000000 at address 0x0000000000000000\n";
    orbit_crash_put_hex(line + 39, (uintptr_t)(unsigned int)ep->ExceptionRecord->ExceptionCode, 8);
    orbit_crash_put_hex(line + 61, (uintptr_t)ep->ExceptionRecord->ExceptionAddress, 16);
    fputs(line, stderr);
    fflush(stderr);
    return EXCEPTION_CONTINUE_SEARCH;
}

void orbit_crash_handler_install(void) {
    SetUnhandledExceptionFilter(orbit_crash_handler);
}
#else
void orbit_crash_handler_install(void) {}
#endif

#endif
