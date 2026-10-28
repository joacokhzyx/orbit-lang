/**
 * @file  crash.h
 * @brief Windows crash diagnostic: names the exception code and address.
 */
#ifndef ORBIT_RT_CRASH_H
#define ORBIT_RT_CRASH_H

#include "module_prelude.h"

/* Installs an unhandled-exception filter that prints one line to stderr and
 * then lets the OS default (WER, exit code 0xC0000005 and the like) proceed.
 * Idempotent; a no-op off Windows. The generated main calls it first. */
void orbit_crash_handler_install(void);

#endif
