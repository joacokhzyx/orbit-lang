/**
 * @file  module_prelude.h
 * @brief Linkage switch shared by every runtime module header.
 *
 * The unity build (runtime.h) keeps the cross-module helpers file-static.
 * Compiling a module on its own (-DORBIT_RUNTIME_MODULE, see
 * scripts/mklib_runtime.py) gives them external linkage so the archive
 * member that defines them can be selected by the linker.
 */
#ifndef ORBIT_MODULE_PRELUDE_H
#define ORBIT_MODULE_PRELUDE_H

#include "inline.h"

#ifdef ORBIT_RUNTIME_MODULE
#define ORBIT_XLINK
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <stdint.h>
#include "socket_compat.h"
#include "crt_compat.h"
/* Same redirect as runtime.h: the runtime's own getenv calls go through
 * orbit_env_get in every build mode. */
#define getenv orbit_env_get
#else
#define ORBIT_XLINK static
#endif

#endif
