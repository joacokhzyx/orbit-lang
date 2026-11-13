/**
 * @file  perf.c
 * @brief Owner of the performance counters for the separately compiled runtime.
 *
 * Every other module binds to orbit_perf_stats, orbit_perf_lat_hist and
 * orbit_perf_lat_sum_us through extern (performance.h); this is the single
 * definition.
 */
#define ORBIT_PERF_IMPL
#include "module_prelude.h"
#include "performance.h"
