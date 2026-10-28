/* Interface of runtime/pulse.c (generated split; edit by hand from here). */
#ifndef ORBIT_RT_PULSE_H
#define ORBIT_RT_PULSE_H

#include "module_prelude.h"

#include "types.h"
#include "arena.h"

#include "performance.h"
#include "kynx.h"
#include "arena_pool.h"
#include <stdio.h>
#include <inttypes.h>

/* ──────────────────────────────────────────────────────────────────────
 * Orbit Pulse — Real-time telemetry engine.
 *
 * Serves a plain dashboard at /_pulse and a JSON API at /_pulse/data.
 * Zero external dependencies; all assets are embedded.
 * ────────────────────────────────────────────────────────────────────── */

// Forward declaration of the dashboard HTML
extern const char* ORBIT_PULSE_DASHBOARD_HTML;
orbit_string orbit_pulse_get_stats_json(OrbitArena* arena);
extern const char* ORBIT_PULSE_DASHBOARD_HTML;

#endif
