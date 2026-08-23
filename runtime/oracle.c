/**
 * @file  oracle.c
 * @brief Orbit Arena Oracle implementation.
 */
#include "oracle.h"
#include <stdlib.h>
#include <string.h>

#ifdef _MSC_VER
__declspec(thread) OracleSession tls_oracle_session = {0};
#else
__thread OracleSession tls_oracle_session = {0};
#endif

static OracleRoutePrediction oracle_prediction_table[ORACLE_MAX_ROUTES];
static int oracle_prediction_count = 0;

#ifdef _WIN32
  #define oracle_atomic_inc64(ptr) InterlockedIncrement64((volatile LONG64*)(ptr))
  #define oracle_atomic_add64(ptr, val) InterlockedExchangeAdd64((volatile LONG64*)(ptr), (LONG64)(val))
#else
  #define oracle_atomic_inc64(ptr) __sync_fetch_and_add((volatile uint64_t*)(ptr), 1)
  #define oracle_atomic_add64(ptr, val) __sync_fetch_and_add((volatile uint64_t*)(ptr), (uint64_t)(val))
#endif

void oracle_init(void) {
    memset(oracle_prediction_table, 0, sizeof(oracle_prediction_table));
    oracle_prediction_count = 0;
    memset(&tls_oracle_session, 0, sizeof(tls_oracle_session));
}

uint64_t oracle_route_hash(const char* method, const char* path) {
    uint64_t h = 14695981039346656037ULL;
    if (method) { while (*method) { h ^= (unsigned char)*method++; h *= 1099511628211ULL; } }
    h ^= ':'; h *= 1099511628211ULL;
    if (path) { while (*path) { h ^= (unsigned char)*path++; h *= 1099511628211ULL; } }
    return h;
}

OracleRoutePrediction* oracle_get_prediction(uint64_t route_hash) {
    for (int i = 0; i < oracle_prediction_count; i++) {
        if (oracle_prediction_table[i].route_hash == route_hash) {
            return &oracle_prediction_table[i];
        }
    }
    if (oracle_prediction_count >= ORACLE_MAX_ROUTES) return NULL;
    int idx = oracle_prediction_count++;
    oracle_prediction_table[idx].route_hash = route_hash;
    oracle_prediction_table[idx].predicted  = ORACLE_DEFAULT_PREDICT;
    oracle_prediction_table[idx].max_seen   = 0;
    oracle_prediction_table[idx].min_seen   = 0;
    oracle_prediction_table[idx].total_bytes = 0;
    oracle_prediction_table[idx].sample_count = 0;
    oracle_prediction_table[idx].overflow_count = 0;
    oracle_prediction_table[idx].is_trained = false;
    return &oracle_prediction_table[idx];
}

static void oracle_record_stat(uint64_t route_hash, size_t actual_bytes) {
    OracleRoutePrediction* rp = oracle_get_prediction(route_hash);
    if (!rp) return;
    oracle_atomic_add64(&rp->total_bytes, actual_bytes);
    oracle_atomic_inc64(&rp->sample_count);
    if (actual_bytes > rp->max_seen) rp->max_seen = actual_bytes;
    if (rp->min_seen == 0 || actual_bytes < rp->min_seen) rp->min_seen = actual_bytes;
    if (rp->sample_count >= ORACLE_COLD_START_SAMPLES) rp->is_trained = true;

    size_t ema = (rp->predicted * (100 - ORACLE_EMA_ALPHA) + actual_bytes * ORACLE_EMA_ALPHA) / 100;
    size_t safety = rp->max_seen + (rp->max_seen / ORACLE_SAFETY_MARGIN);
    if (ema < safety) ema = safety;
    rp->predicted = ema;
}

int oracle_begin_session(void* arena_ptr, uint64_t route_hash) {
    OrbitArena* arena = (OrbitArena*)arena_ptr;
    if (!arena) return 0;

    OracleRoutePrediction* rp = oracle_get_prediction(route_hash);
    size_t predicted = rp ? rp->predicted : ORACLE_DEFAULT_PREDICT;
    if (predicted < 4096) predicted = 4096;

    /* Reserve block from arena */
    unsigned char* block = (unsigned char*)orbit_alloc(arena, predicted);
    if (!block) return 0;

    tls_oracle_session.block_start = block;
    tls_oracle_session.cursor      = block;
    tls_oracle_session.block_end   = block + predicted;
    tls_oracle_session.predicted   = predicted;
    tls_oracle_session.route_hash  = route_hash;
    tls_oracle_session.active      = 1;
    tls_oracle_session.slow_path   = 0;
    return 1;
}

void oracle_end_session(void* arena_ptr) {
    (void)arena_ptr;
    if (!tls_oracle_session.active) return;
    size_t actual_bytes = (size_t)(tls_oracle_session.cursor - tls_oracle_session.block_start);
    oracle_record_stat(tls_oracle_session.route_hash, actual_bytes);
    if (tls_oracle_session.slow_path) {
        OracleRoutePrediction* rp = oracle_get_prediction(tls_oracle_session.route_hash);
        if (rp) oracle_atomic_inc64(&rp->overflow_count);
    }
    tls_oracle_session.active = 0;
    tls_oracle_session.cursor = NULL;
    tls_oracle_session.block_start = NULL;
    tls_oracle_session.block_end = NULL;
}
