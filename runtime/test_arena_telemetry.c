/* The process totals are a fold of what each arena counted, joined once per
 * request by orbit_arena_reset.
 *
 * The property an operator relies on is the one pinned here: the aggregate the
 * telemetry endpoints publish equals the sum of every arena's own counters,
 * and the allocation fast path publishes nothing by itself. A single-threaded
 * check cannot tell a working fold from a broken one -- one arena is all it
 * would fold -- so the first block allocates from four threads and compares
 * the sum against the delta the aggregate moved.
 *
 * Delete the orbit_perf_fold_arena call from orbit_arena_reset and the first
 * block fails: the aggregates stay at zero while the arenas say 800. That is
 * the intended direction of the dependency, and this is the gate that says so.
 *
 * The second half pins the other end of the same change: orbit_ledger_exit
 * records the footprint of the request it closes, so /_ledger's memory columns
 * are the arena's own numbers rather than a prediction.
 *
 * Built by scripts/runtime_c_tests.py as `arena_telemetry`.
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#include "runtime.h"

#define WORKER_THREADS 4
#define WORKER_ALLOCS 200
#define ALLOC_SIZE 128

static int failures = 0;

static void check_u64(const char* what, uint64_t got, uint64_t want) {
    if (got != want) {
        printf("FAILED %s: got %llu, want %llu\n", what,
               (unsigned long long)got, (unsigned long long)want);
        failures++;
    }
}

typedef struct {
    OrbitArena** slot;
    int allocs;
} WorkerArgs;

#ifdef _WIN32
static DWORD WINAPI worker(LPVOID arg) {
#else
#include <pthread.h>
static void* worker(void* arg) {
#endif
    WorkerArgs* wa = (WorkerArgs*)arg;
    OrbitArena* arena = orbit_arena_create(64 * 1024);
    int i;
    if (!arena) {
        *wa->slot = NULL;
        return 0;
    }
    /* 200 * 128 = 25 KB, inside the arena's initial 64 KB commit, so every
     * allocation here takes the fast path whose counters this test is about. */
    for (i = 0; i < wa->allocs; i++) {
        if (!orbit_alloc(arena, ALLOC_SIZE)) break;
    }
    /* The join is at reset: the arena's numbers are published here and not
     * before, which is the whole point of moving them off the fast path. */
    orbit_arena_reset(arena);
    *wa->slot = arena;
    return 0;
}

static void test_fold_is_the_sum_of_arenas(void) {
    OrbitArena* arenas[WORKER_THREADS];
    WorkerArgs args[WORKER_THREADS];
    OrbitPerfStats before, after, d;
    int i;
    uint64_t expect_allocs = (uint64_t)WORKER_THREADS * WORKER_ALLOCS;
    uint64_t expect_bytes = expect_allocs * ALLOC_SIZE;

    memset(arenas, 0, sizeof(arenas));

#ifdef _WIN32
    HANDLE threads[WORKER_THREADS];
#else
    pthread_t threads[WORKER_THREADS];
#endif

    /* Nothing else in this process may be reset while the delta is open, or
     * the equality below would be measuring two things at once. */
    orbit_perf_stats.arena_alloc_count = 0;
    orbit_perf_stats.arena_requested_bytes = 0;
    orbit_perf_stats.arena_aligned_bytes = 0;
    orbit_perf_stats.total_alloc_bytes = 0;
    orbit_perf_stats.arena_peak_used_bytes = 0;
    before = orbit_perf_get_stats();

    for (i = 0; i < WORKER_THREADS; i++) {
        args[i].slot = &arenas[i];
        args[i].allocs = WORKER_ALLOCS;
#ifdef _WIN32
        threads[i] = CreateThread(NULL, 0, worker, &args[i], 0, NULL);
#else
        pthread_create(&threads[i], NULL, worker, &args[i]);
#endif
    }
    for (i = 0; i < WORKER_THREADS; i++) {
#ifdef _WIN32
        WaitForSingleObject(threads[i], INFINITE);
        CloseHandle(threads[i]);
#else
        pthread_join(threads[i], NULL);
#endif
    }
    for (i = 0; i < WORKER_THREADS; i++) {
        if (!arenas[i]) {
            printf("FAILED worker %d could not create an arena\n", i);
            failures++;
            return;
        }
    }

    after = orbit_perf_get_stats();
    check_u64("aggregate alloc_count", after.arena_alloc_count - before.arena_alloc_count,
              expect_allocs);
    check_u64("aggregate requested_bytes",
              after.arena_requested_bytes - before.arena_requested_bytes, expect_bytes);
    check_u64("aggregate aligned_bytes",
              after.arena_aligned_bytes - before.arena_aligned_bytes, expect_bytes);
    check_u64("aggregate total_alloc_bytes",
              after.total_alloc_bytes - before.total_alloc_bytes, expect_bytes);
    /* The peak is a max, not a sum: one arena's 25600 bytes, and no other
     * arena in this process has ever used more. */
    check_u64("aggregate peak_used_bytes",
              after.arena_peak_used_bytes - before.arena_peak_used_bytes,
              expect_bytes / WORKER_THREADS);

    /* And each arena still says so itself, which is what makes the above a
     * fold and not an independent count. */
    for (i = 0; i < WORKER_THREADS; i++) {
        check_u64("arena alloc_count", orbit_arena_alloc_count(arenas[i]), 0);
        check_u64("arena peak_used", (uint64_t)orbit_arena_peak_used(arenas[i]),
                  expect_bytes / WORKER_THREADS);
    }

    /* Destroying folds the interval after the last reset, which is empty
     * here: a second fold must not count the same allocations twice. */
    for (i = 0; i < WORKER_THREADS; i++) {
        orbit_arena_destroy(arenas[i]);
    }
    d = orbit_perf_get_stats();
    check_u64("destroy does not re-count allocs", d.arena_alloc_count, after.arena_alloc_count);
    check_u64("destroy does not re-count bytes", d.total_alloc_bytes, after.total_alloc_bytes);
}

static void test_fast_path_publishes_nothing(void) {
    OrbitArena* solo = orbit_arena_create(64 * 1024);
    uint64_t before, after_alloc, after_reset;

    if (!solo) {
        printf("FAILED solo arena not created\n");
        failures++;
        return;
    }
    before = orbit_perf_get_stats().arena_alloc_count;
    orbit_alloc(solo, ALLOC_SIZE);
    after_alloc = orbit_perf_get_stats().arena_alloc_count;
    check_u64("an allocation alone moves no aggregate", after_alloc, before);

    orbit_arena_reset(solo);
    after_reset = orbit_perf_get_stats().arena_alloc_count;
    check_u64("the reset publishes exactly one", after_reset, before + 1);

    orbit_arena_destroy(solo);
    check_u64("no second publish at destroy", orbit_perf_get_stats().arena_alloc_count,
              after_reset);
}

static void test_ledger_row_reports_the_request_arena(void) {
    OrbitArena* req = orbit_arena_create(64 * 1024);
    int slot, slot2;
    size_t big_used, small_used;
    uint64_t row_max, row_overflow;
    orbit_string json;

    if (!req) {
        printf("FAILED request arena not created\n");
        failures++;
        return;
    }

    slot = orbit_ledger_enter("GET", "/telemetry");
    if (slot < 0) {
        printf("FAILED ledger_enter returned %d\n", slot);
        failures++;
        orbit_arena_destroy(req);
        return;
    }
    orbit_alloc(req, 4096);
    big_used = orbit_arena_active_bytes(req);
    orbit_ledger_exit(slot, 2500, req);
    check_u64("row records the request footprint",
              orbit_ledger_table[slot].max_bytes, (uint64_t)big_used);
    /* A route that fits in one segment has never overflowed. */
    check_u64("normal route reports no overflow", orbit_ledger_table[slot].overflow_count, 0);

    /* A smaller request on the same route must not lower the row's maximum. */
    orbit_arena_reset(req);
    slot2 = orbit_ledger_enter("GET", "/telemetry");
    check_u64("same route, same slot", (uint64_t)slot2, (uint64_t)slot);
    orbit_alloc(req, 64);
    small_used = orbit_arena_active_bytes(req);
    orbit_ledger_exit(slot2, 2500, req);
    if (small_used >= big_used) {
        printf("FAILED second request was not smaller (%llu vs %llu)\n",
               (unsigned long long)small_used, (unsigned long long)big_used);
        failures++;
    }
    check_u64("smaller request does not lower max_bytes",
              orbit_ledger_table[slot].max_bytes, (uint64_t)big_used);

    /* A request that outgrows the 64 MB reservation chains a second segment.
     * That is the positive control the negative above needs: the counter can
     * be non-zero, so a zero on a normal route means something. */
    {
        OrbitArena* huge = orbit_arena_create(64 * 1024);
        int slot3;
        void* p;
        if (!huge) {
            printf("FAILED overflow arena not created\n");
            failures++;
            orbit_arena_destroy(req);
            return;
        }
        slot3 = orbit_ledger_enter("GET", "/overflow");
        if (slot3 < 0) {
            printf("FAILED ledger_enter(/overflow) returned %d\n", slot3);
            failures++;
            orbit_arena_destroy(huge);
            orbit_arena_destroy(req);
            return;
        }
        p = orbit_alloc(huge, 100 * 1024 * 1024);
        check_u64("100 MB allocation succeeds", p != NULL ? 1 : 0, 1);
        check_u64("arena reports the chain",
                  (uint64_t)orbit_arena_overflowed(huge), 1);
        orbit_ledger_exit(slot3, 2500, huge);
        check_u64("overflowing route reports one overflow",
                  orbit_ledger_table[slot3].overflow_count, 1);
        check_u64("overflowing route reports its footprint",
                  orbit_ledger_table[slot3].max_bytes,
                  (uint64_t)orbit_arena_active_bytes(huge));
        orbit_arena_destroy(huge);
    }

    /* The row is what /_ledger/data publishes, so read it the way the endpoint
     * does rather than only through the struct. */
    json = orbit_ledger_json(req);
    if (!json) {
        printf("FAILED ledger json came back NULL\n");
        failures++;
    } else {
        if (!strstr(json, "\"arena_overflow\":0")) {
            printf("FAILED json has no zero-overflow row: %s\n", json);
            failures++;
        }
        if (!strstr(json, "\"arena_overflow\":1")) {
            printf("FAILED json has no overflowing row: %s\n", json);
            failures++;
        }
    }

    row_max = orbit_ledger_table[slot].max_bytes;
    row_overflow = orbit_ledger_table[slot].overflow_count;
    check_u64("row max survives the json read", row_max, (uint64_t)big_used);
    check_u64("row overflow survives the json read", row_overflow, 0);

    orbit_arena_destroy(req);
}

int main(void) {
    printf("=== ORBIT ARENA TELEMETRY TESTS ===\n");
    fflush(stdout);

    memset(&orbit_perf_stats, 0, sizeof(OrbitPerfStats));

    printf("Running test: fold_is_the_sum_of_arenas... ");
    fflush(stdout);
    test_fold_is_the_sum_of_arenas();
    printf("done\n");
    fflush(stdout);

    printf("Running test: fast_path_publishes_nothing... ");
    fflush(stdout);
    test_fast_path_publishes_nothing();
    printf("done\n");
    fflush(stdout);

    printf("Running test: ledger_row_reports_the_request_arena... ");
    fflush(stdout);
    test_ledger_row_reports_the_request_arena();
    printf("done\n");
    fflush(stdout);

    if (failures) {
        printf("=== %d FAILURE(S) ===\n", failures);
        return 1;
    }
    printf("=== ALL ARENA TELEMETRY TESTS PASSED ===\n");
    return 0;
}
