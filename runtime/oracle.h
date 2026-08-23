/**
 * @file  oracle.h
 * @brief Orbit Arena Oracle — predictive pre-reservation allocator.
 */
#ifndef ORBIT_ORACLE_H
#define ORBIT_ORACLE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#define ORACLE_MAX_ROUTES         4096
#define ORACLE_DEFAULT_PREDICT    (64 * 1024)
#define ORACLE_SAFETY_MARGIN      5
#define ORACLE_COLD_START_SAMPLES 50
#define ORACLE_EMA_ALPHA          10

typedef struct {
    uint64_t route_hash;
    size_t   predicted;
    size_t   max_seen;
    size_t   min_seen;
    uint64_t total_bytes;
    uint64_t sample_count;
    uint64_t overflow_count;
    bool     is_trained;
} OracleRoutePrediction;

typedef struct {
    unsigned char* block_start;
    unsigned char* cursor;
    unsigned char* block_end;
    size_t         predicted;
    uint64_t       route_hash;
    int            active;
    int            slow_path;
} OracleSession;

#ifdef _MSC_VER
extern __declspec(thread) OracleSession tls_oracle_session;
#else
extern __thread OracleSession tls_oracle_session;
#endif

void oracle_init(void);
uint64_t oracle_route_hash(const char* method, const char* path);
OracleRoutePrediction* oracle_get_prediction(uint64_t route_hash);
int oracle_begin_session(void* arena_ptr, uint64_t route_hash);
void oracle_end_session(void* arena_ptr);

#endif /* ORBIT_ORACLE_H */
