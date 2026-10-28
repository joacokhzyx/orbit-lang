/* Symbols the arena members share. Internal: not part of arena.h.
 * ORBIT_XLINK is static in the unity build and external in the archive. */
#ifndef ORBIT_RT_ARENA_INTERNAL_H
#define ORBIT_RT_ARENA_INTERNAL_H

#include "module_prelude.h"
#include "arena.h"

ORBIT_XLINK size_t orbit_oom_put(char* buf, size_t cap, size_t n, const char* s);
ORBIT_XLINK size_t orbit_oom_put_u(char* buf, size_t cap, size_t n, unsigned long long v);
ORBIT_XLINK size_t orbit_oom_put_holds(char* buf, size_t cap, size_t n, OrbitArena* arena);
ORBIT_XLINK void orbit_oom_abort_default(OrbitArena* arena, size_t bytes);
#ifdef ORBIT_RUNTIME_MODULE
extern OrbitOomHandler orbit_oom_handler;
#endif

#endif
