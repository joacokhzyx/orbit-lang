#ifndef ORBIT_RT_CONSOLE_C
#define ORBIT_RT_CONSOLE_C

#include "module_prelude.h"
#include "console.h"
#include <stdio.h>

#ifdef _WIN32
#include <windows.h>
void orbit_console_init(void) {
    HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
    if (hOut != INVALID_HANDLE_VALUE) {
        DWORD dwMode = 0;
        if (GetConsoleMode(hOut, &dwMode)) {
            SetConsoleMode(hOut, dwMode | 0x0001 | 0x0004);
        }
        SetConsoleOutputCP(65001);
    }
}
#else
void orbit_console_init(void) {}
#endif

void orbit_print_string(const char* s) {
    fputs(s ? s : "(null)", stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

#endif
