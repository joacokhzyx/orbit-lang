/* Interface of runtime/ledger.c (generated split; edit by hand from here). */
#ifndef ORBIT_RT_LEDGER_H
#define ORBIT_RT_LEDGER_H

#include "module_prelude.h"

#include "types.h"
#include "arena.h"
#include "energy.h"
#include "kynx.h"
/**
 * @file  ledger.c
 * @brief Automatic per-route cost ledger for Orbit servers.
 *
 * No annotations, no config: the generated router records every handler
 * invocation (cycles) and every DB call (cycles, via a thread-local slot)
 * into a fixed table keyed by METHOD + route template. Served at /_ledger
 * (HTML, auto-refresh) and /_ledger/data (JSON). Loopback only.
 *
 * Honesty notes: cycles use the same 2.5 GHz RDTSC basis as the request
 * log, so milliseconds are approximate on other clocks. Per-route joules
 * come from the energy sampler (runtime/energy.c): on Linux with a readable
 * powercap sensor they are that route's cycle-share of the attributable
 * package energy (an ESTIMATE, see docs/ENERGY.md); without a sensor every
 * joule field reads 0 and the source column reads "cpu-proxy", meaning the
 * cycle counters are a labeled proxy, never energy. What is not measured
 * is not shown. Define ORBIT_NO_LEDGER to compile the enter/exit hooks to
 * no-ops for overhead comparison; the JSON/HTML endpoints then report
 * empty route lists.
 */
#ifdef __TINYC__
#ifndef ORBIT_TINYC_SHIM
#define ORBIT_TINYC_SHIM
/* tcc judge build is single-thread-only: tcc provides no __thread TLS and no
 * __atomic_* builtins, so __thread degrades to a plain global and the builtins
 * degrade to plain operations. Never #undef'd: the unity TU shares one
 * preprocessor state, so every declaration and definition must agree (all
 * plain). Invisible to gcc/clang/MSVC. The multithreaded server stays a gcc
 * build by design: plain operations race (see runtime/orbit_api.h). */
#define __thread
#ifndef __ATOMIC_RELAXED
#define __ATOMIC_RELAXED 0
#define __ATOMIC_ACQUIRE 2
#define __ATOMIC_RELEASE 3
#define __ATOMIC_SEQ_CST 5
#endif
#define __atomic_load_n(ptr, memorder) (*(ptr))
#define __atomic_store_n(ptr, val, memorder) ((*(ptr)) = (val))
#define __atomic_fetch_add(ptr, val, memorder) (*(ptr) += (val), *(ptr) - (val))
#define __atomic_fetch_sub(ptr, val, memorder) (*(ptr) -= (val), *(ptr) + (val))
/* fetch_or/and return the NEW value, not the old one the gcc builtin returns;
 * no call site in this tree reads the result. */
#define __atomic_fetch_or(ptr, val, memorder) (*(ptr) |= (val))
#define __atomic_fetch_and(ptr, val, memorder) (*(ptr) &= (val))
#endif
#endif

#include "performance.h"
#include <stdio.h>
#include <string.h>

#define ORBIT_LEDGER_MAX 64

/* Per-route latency histogram: one bucket per power of two of cycles, so
 * bucket i holds durations in (2^i, 2^(i+1)] and its upper boundary is
 * 2^(i+1) cycles. Log spacing keeps the whole table at 64 routes * 64
 * buckets * 8 B = 32 KB of static state, where 100 us-wide buckets would
 * need 512 KB. The cost is resolution: a reported p99 is a power-of-two
 * boundary, not a measurement. */
#define ORBIT_LEDGER_LAT_BUCKETS 64

typedef struct {
    char method[16];
    char path[256];
    uint64_t count;
    uint64_t total_cycles;
    uint64_t db_cycles;
    uint64_t max_bytes;      /* largest arena footprint seen on this route */
    uint64_t overflow_count; /* requests on this route that chained a segment */
    uint64_t lat[ORBIT_LEDGER_LAT_BUCKETS];
    int used;
} OrbitLedgerEntry;
extern OrbitLedgerEntry orbit_ledger_table[ORBIT_LEDGER_MAX];
extern ORBIT_THREAD_LOCAL int orbit_ledger_tls_slot;
int orbit_ledger_enter(const char* method, const char* path);
void orbit_ledger_exit(int idx, uint64_t cycles, const OrbitArena* arena);

/* DB timing choke points. Called from orbit_db_* entry functions. */
static inline uint64_t orbit_ledger_db_begin(void) {
    return orbit_rdtsc();
}

static inline void orbit_ledger_db_end(uint64_t t0) {
    int idx = orbit_ledger_tls_slot;
    if (idx >= 0 && idx < ORBIT_LEDGER_MAX) {
        orbit_perf_atomic_add64(&orbit_ledger_table[idx].db_cycles, orbit_rdtsc() - t0);
    }
}

#ifdef ORBIT_ENERGY_C
#define ORBIT_LEDGER_SOURCE() orbit_energy_source()
#define ORBIT_LEDGER_ATTR_J() orbit_energy_attributable_joules()
#define ORBIT_LEDGER_ROUTE_J(rc, tc) orbit_energy_route_joules((rc), (tc))
#else
/* Standalone TU without the sampler: labeled proxy, no joules. */
#define ORBIT_LEDGER_SOURCE() ("cpu-proxy")
#define ORBIT_LEDGER_ATTR_J() (0.0)
#define ORBIT_LEDGER_ROUTE_J(rc, tc) ((void)(rc), (void)(tc), 0.0)
#endif

#define ORBIT_LEDGER_NOTE_METERED \
    "cycles on 2.5 GHz RDTSC basis; ms approximate. " \
    "Joules are the route cycle-share of attributable RAPL package energy (ESTIMATE, see docs/ENERGY.md)."
#define ORBIT_LEDGER_NOTE_PROXY \
    "cycles on 2.5 GHz RDTSC basis; ms approximate. " \
    "No power sensor: joules read 0 and avg_cycles is a labeled CPU proxy, not energy."

/* Defined below; the dump hook runs at exit and needs it from up here. */
orbit_string orbit_ledger_json(OrbitArena* arena);
void orbit_ledger_enable_file_dump(void);
orbit_string orbit_ledger_json(OrbitArena* arena);
orbit_string orbit_ledger_html(OrbitArena* arena);

#endif
