/* Interface of runtime/auth.c (generated split; edit by hand from here). */
#ifndef ORBIT_RT_AUTH_H
#define ORBIT_RT_AUTH_H

#include "module_prelude.h"

#include "types.h"
#include "arena.h"

#include <time.h>
#include <string.h>
#include <stdbool.h>
void orbit_auth_init(void);
orbit_string orbit_auth_bearer_token(OrbitArena* arena, const char* raw);
orbit_string orbit_auth_role(OrbitArena* arena, const char* token);
bool orbit_auth_has_role(OrbitArena* arena, const char* raw, const char* required);
orbit_string orbit_auth_current_role(OrbitArena* arena, const char* raw);

#endif
