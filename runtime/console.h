/**
 * @file  console.h
 * @brief Console setup and string output for programs that print.
 */
#ifndef ORBIT_RT_CONSOLE_H
#define ORBIT_RT_CONSOLE_H

#include "module_prelude.h"

/* Windows: UTF-8 output code page and ANSI escape processing when stdout is a
 * console (best effort; GetConsoleMode fails on pipes). A no-op elsewhere.
 * Emitted only for programs that write to the console. */
void orbit_console_init(void);

/* print("%s", s) without the format engine: s, a newline, a flush. */
void orbit_print_string(const char* s);

#endif
