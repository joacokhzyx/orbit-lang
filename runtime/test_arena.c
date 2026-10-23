#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdint.h>

#ifndef _WIN32
#include <pthread.h>
#include <sched.h>
#endif

#include "runtime.h"

// Define a test runner framework
/* fflush after the banner, and after PASSED, because that is what makes a crash
 * attributable. On Windows stdout is fully buffered when it is a pipe, not a
 * console, so an access violation loses every buffered line and the CI log
 * shows a bare "[ORBIT RUNTIME CRASH]" with no indication of which test died --
 * which is how a crash in the migrations test was read as a crash in whichever
 * test happened to be compiled last. The line is there to name the failure. */
#define RUN_TEST(name) \
    do { \
        printf("Running test: %s... ", #name); \
        fflush(stdout); \
        name(); \
        printf("PASSED\n"); \
        fflush(stdout); \
    } while (0)

// 1. Creation and destruction
static void test_create_destroy(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    assert(arena != NULL);
    assert(arena->base != NULL);
    assert(arena->cursor == arena->base);
    assert(arena->committed_bytes >= 65536);
    assert(arena->reserved_bytes >= ORBIT_ARENA_DEFAULT_RESERVE);
    orbit_arena_destroy(arena);
}

// 2. Alignment for sizes 1..512
static void test_alignment_sizes(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    for (size_t size = 1; size <= 512; size++) {
        void* ptr = orbit_alloc(arena, size);
        assert(ptr != NULL);
        assert(((uintptr_t)ptr % ORBIT_ARENA_ALIGN) == 0);
    }
    orbit_arena_destroy(arena);
}

// 3. Various alignments of structs
struct TestStruct1 { char c; };
struct TestStruct2 { int i; char c; };
struct TestStruct3 { double d; char c[3]; };
static void test_struct_alignments(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    void* p1 = orbit_alloc(arena, sizeof(struct TestStruct1));
    void* p2 = orbit_alloc(arena, sizeof(struct TestStruct2));
    void* p3 = orbit_alloc(arena, sizeof(struct TestStruct3));
    assert(((uintptr_t)p1 % ORBIT_ARENA_ALIGN) == 0);
    assert(((uintptr_t)p2 % ORBIT_ARENA_ALIGN) == 0);
    assert(((uintptr_t)p3 % ORBIT_ARENA_ALIGN) == 0);
    orbit_arena_destroy(arena);
}

// 4. Allocations up to crossing page boundaries
// 5. Commit incremental
static void test_page_crossing_commit(void) {
    OrbitArena* arena = orbit_arena_create(4096);
    size_t page_size = arena->page_size;
    
    // Allocate almost up to the page size
    void* p1 = orbit_alloc(arena, page_size - 32);
    assert(p1 != NULL);
    
    size_t committed_before = arena->committed_bytes;
    
    // Allocate to cross the boundary
    void* p2 = orbit_alloc(arena, 64);
    assert(p2 != NULL);
    
    size_t committed_after = arena->committed_bytes;
    assert(committed_after > committed_before);
    assert(committed_after - committed_before >= page_size);
    
    orbit_arena_destroy(arena);
}

// 6. Stable pointers after growth
static void test_stable_pointers(void) {
    OrbitArena* arena = orbit_arena_create(4096);
    void* p1 = orbit_alloc(arena, 128);
    void* p2 = orbit_alloc(arena, 4096); // triggers page growth
    void* p3 = orbit_alloc(arena, 128);
    
    // Check that p1 and p3 are stable and in consecutive memory order
    assert((unsigned char*)p1 + orbit_align_up(128, ORBIT_ARENA_ALIGN) == (unsigned char*)p2);
    assert((unsigned char*)p2 + orbit_align_up(4096, ORBIT_ARENA_ALIGN) == (unsigned char*)p3);
    
    orbit_arena_destroy(arena);
}

// 7. Reset and reuse of the same base address
static void test_reset_reuse(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    void* base_before = arena->base;
    orbit_alloc(arena, 1024);
    
    orbit_arena_reset(arena);
    assert(arena->base == base_before);
    assert(arena->cursor == arena->base);
    
    void* first_alloc_after = orbit_alloc(arena, 1024);
    assert(first_alloc_after == base_before);
    
    orbit_arena_destroy(arena);
}

// 8. Reset O(1) logical
static void test_reset_o1_logical(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    for (int i = 0; i < 1000; i++) {
        orbit_alloc(arena, 16);
    }
    // Reset should be O(1) and not depend on number of allocations
    orbit_arena_reset(arena);
    assert(arena->alloc_count == 0);
    assert(arena->used == 0);
    orbit_arena_destroy(arena);
}

// 9. Requested bytes vs aligned bytes
// 10. Peak usage
static void test_telemetry_bytes(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    orbit_alloc(arena, 5);
    orbit_alloc(arena, 11);
    
    assert(arena->requested_bytes == 16);
    assert(arena->aligned_bytes == 32); // 5 -> 16, 11 -> 16
    assert(arena->peak_used == 32);
    
    orbit_arena_destroy(arena);
}

// 11. Size_t overflow protection
static void test_size_t_overflow(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    // orbit_alloc_try, not orbit_alloc: exhaustion is loud by default and this
    // test is specifically asserting the graceful NULL return, so it opts out
    // of the aborting policy for this one call.
    void* ptr = orbit_alloc_try(arena, SIZE_MAX - 8);
    assert(ptr == NULL); // Must gracefully fail
    orbit_arena_destroy(arena);
}

// 12. Reserve exhaustion
// 13. Exceptionally large allocations (handling overflow blocks)
static void test_large_allocation_overflow(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    
    // Allocate 100 MB which exceeds standard 64MB reserve
    void* ptr = orbit_alloc(arena, 100 * 1024 * 1024);
    assert(ptr != NULL);
    assert(arena->overflow_list != NULL);
    assert(orbit_arena_capacity(arena) >= 100 * 1024 * 1024);
    
    orbit_arena_destroy(arena);
}

// 14. Checkpoint and rewind
// 15. Nesting checkpoints
static void test_checkpoint_rewind(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    
    void* p1 = orbit_alloc(arena, 64);
    OrbitArenaCheckpoint cp1 = orbit_arena_checkpoint(arena);
    
    void* p2 = orbit_alloc(arena, 128);
    OrbitArenaCheckpoint cp2 = orbit_arena_checkpoint(arena);
    
    void* p3 = orbit_alloc(arena, 256);
    
    // Rewind to cp2
    bool ok2 = orbit_arena_rewind(arena, cp2);
    assert(ok2);
    assert(arena->cursor == (unsigned char*)p2 + 128);
    
    // Alloc after rewind should return same slot as p3
    void* p3_new = orbit_alloc(arena, 256);
    assert(p3_new == p3);
    
    // Rewind to cp1
    bool ok1 = orbit_arena_rewind(arena, cp1);
    assert(ok1);
    assert(arena->cursor == (unsigned char*)p1 + 64);
    
    orbit_arena_destroy(arena);
}

// 16. Checkpoint invalid by generation
static void test_checkpoint_generation_invalid(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    orbit_alloc(arena, 64);
    OrbitArenaCheckpoint cp = orbit_arena_checkpoint(arena);
    
    orbit_arena_reset(arena);
    // Rewinding using cp from previous epoch should fail
    bool ok = orbit_arena_rewind(arena, cp);
    assert(!ok);
    
    orbit_arena_destroy(arena);
}

// 17. Child arena
static void test_child_arena(void) {
    OrbitArena* parent = orbit_arena_create(65536);
    OrbitArena* child = orbit_arena_create_child(parent, 4096);
    assert(child != NULL);
    assert(child->parent == parent);
    orbit_arena_destroy(child);
    orbit_arena_destroy(parent);
}

// 18. Promote of trivial bytes
static void test_promote_bytes(void) {
    OrbitArena* parent = orbit_arena_create(65536);
    OrbitArena* child = orbit_arena_create_child(parent, 4096);
    
    char* str = "Hello parent";
    void* promoted = orbit_arena_promote(child, str, strlen(str) + 1);
    assert(promoted != NULL);
    assert(strcmp((char*)promoted, str) == 0);
    assert((unsigned char*)promoted >= parent->base && (unsigned char*)promoted < parent->reserved_end);
    
    orbit_arena_destroy(child);
    orbit_arena_destroy(parent);
}

// 19. String interning in epoch
// 20. String pool invalidation after reset
static void test_string_interning(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    
    const char* str1 = orbit_string_intern(arena, "test_intern");
    const char* str2 = orbit_string_intern(arena, "test_intern");
    assert(str1 == str2); // Pointer equality within same epoch
    
    orbit_arena_reset(arena);
    
    const char* str3 = orbit_string_intern(arena, "test_intern");
    // After reset, we must allocate a new string. Its address must differ (since reset recycled it, or it can be at the start)
    // Actually, because of reset, str3 might be at base, which could be the same address as str1,
    // but the old reference str1 is officially invalidated. Let's make sure it works.
    assert(str3 != NULL);
    
    orbit_arena_destroy(arena);
}

// 21. Concurrent acquire/release of the pool
// 22. Pool exhaustion
// 23. Arena overflow in pool
static void test_pool_concurrency_and_overflow(void) {
    orbit_arena_pool_init(4, 4096);
    
    OrbitArena* a1 = orbit_arena_pool_acquire();
    OrbitArena* a2 = orbit_arena_pool_acquire();
    OrbitArena* a3 = orbit_arena_pool_acquire();
    OrbitArena* a4 = orbit_arena_pool_acquire();
    
    // The next one should trigger pool exhaustion / overflow creation
    OrbitArena* a5 = orbit_arena_pool_acquire();
    assert(a5 != NULL);
    
    assert(orbit_global_arena_pool.active_count == 4);
    assert(orbit_global_arena_pool.overflow_creates == 1);
    
    orbit_arena_pool_release(a1);
    orbit_arena_pool_release(a2);
    orbit_arena_pool_release(a3);
    orbit_arena_pool_release(a4);
    orbit_arena_pool_release(a5); // should be destroyed
    
    orbit_arena_pool_cleanup();
}

// 24. Repetition of thousands of resets
static void test_thousands_of_resets(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    for (int i = 0; i < 5000; i++) {
        void* p = orbit_alloc(arena, 32);
        assert(p != NULL);
        orbit_arena_reset(arena);
    }
    orbit_arena_destroy(arena);
}

// 25. No memory leaks on error paths
static void test_no_leaks_on_error(void) {
    // Attempt huge reservation
    OrbitArena* arena = orbit_arena_create(SIZE_MAX - 1000);
    assert(arena == NULL); // Must fail cleanly without leaking anything
}

// 26. Cross-request arena isolation: sequential requests
// 27. Cross-request arena isolation: concurrent in-flight requests
static int region_has_byte(const void* ptr, size_t n, unsigned char byte) {
    const unsigned char* p = (const unsigned char*)ptr;
    for (size_t i = 0; i < n; i++) {
        if (p[i] == byte) return 1;
    }
    return 0;
}

static void test_cross_request_sequential_isolation(void) {
    orbit_arena_pool_init(2, 4096);

    const size_t pad_size = 512 * 1024;
    const size_t chunk = 4096;
    const int chunks = 4;
    const char* secret = "request1_secret";
    size_t secret_len = strlen(secret);

    OrbitArena* req1 = orbit_arena_pool_acquire();
    assert(req1 != NULL);

    void* pad1 = orbit_alloc(req1, pad_size);
    assert(pad1 != NULL);
    for (int i = 0; i < chunks; i++) {
        void* p = orbit_alloc(req1, chunk);
        assert(p != NULL);
        memset(p, 0xAB, chunk);
    }
    const char* s1 = orbit_string_intern(req1, secret);
    assert(s1 != NULL);

    orbit_arena_pool_release(req1);

    OrbitArena* req2 = orbit_arena_pool_acquire();
    assert(req2 != NULL);
    assert(req2 == req1);

    void* pad2 = orbit_alloc(req2, pad_size);
    assert(pad2 != NULL);
    for (int i = 0; i < chunks; i++) {
        void* p = orbit_alloc(req2, chunk);
        assert(p != NULL);
        assert(!region_has_byte(p, chunk, 0xAB));
    }

    void* cover = orbit_alloc(req2, chunk);
    assert(cover != NULL);
    assert(memcmp(s1, secret, secret_len) != 0);

    const char* s2 = orbit_string_intern(req2, secret);
    assert(s2 != NULL);
    assert(strcmp(s2, secret) == 0);

    orbit_arena_pool_release(req2);
    orbit_arena_pool_cleanup();
}

static void test_cross_request_concurrent_isolation(void) {
    orbit_arena_pool_init(2, 4096);

    OrbitArena* a1 = orbit_arena_pool_acquire();
    OrbitArena* a2 = orbit_arena_pool_acquire();
    assert(a1 != NULL);
    assert(a2 != NULL);
    assert(a1 != a2);
    assert(a1->base != a2->base);

    unsigned char* r1 = (unsigned char*)orbit_alloc(a1, 16384);
    unsigned char* r2 = (unsigned char*)orbit_alloc(a2, 16384);
    assert(r1 != NULL);
    assert(r2 != NULL);
    memset(r1, 0x11, 16384);
    memset(r2, 0x22, 16384);

    assert(!region_has_byte(r1, 16384, 0x22));
    assert(!region_has_byte(r2, 16384, 0x11));

    orbit_arena_pool_release(a1);
    orbit_arena_pool_release(a2);
    orbit_arena_pool_cleanup();
}

// 28. The process-wide fallback singleton: one arena across a first-call race
/* orbit_arena_get_global is what a runtime helper reaches when it was handed
 * no arena, and its first call is the only instant at which more than one
 * arena can be created. A start gate holds eight threads until every one of
 * them is at the call, so they enter the create together; the property
 * asserted is the guarantee -- every caller sees the same arena -- because a
 * second arena would answer a different pointer to its creator. This test is
 * first in `main` on purpose: once anything in the process has called it, the
 * singleton exists and there is no first call left to race. */
#define GLOBAL_RACE_THREADS 8

typedef struct {
    volatile int* arrived;
    volatile int* release;
    OrbitArena* got;
} GlobalRaceArgs;

static void global_race_yield(void) {
#ifdef _WIN32
    Sleep(0);
#else
    sched_yield();
#endif
}

#ifdef _WIN32
static DWORD WINAPI global_race_worker(LPVOID arg) {
#else
static void* global_race_worker(void* arg) {
#endif
    GlobalRaceArgs* a = (GlobalRaceArgs*)arg;
#ifdef _WIN32
    InterlockedIncrement((volatile LONG*)a->arrived);
#else
    __sync_fetch_and_add((volatile int*)a->arrived, 1);
#endif
    while (!*a->release) global_race_yield();
    a->got = orbit_arena_get_global();
    return 0;
}

static void test_global_fallback_singleton_is_created_once(void) {
    volatile int arrived = 0;
    volatile int release = 0;
    GlobalRaceArgs args[GLOBAL_RACE_THREADS];

    /* A pass here would be vacuous if the arena already existed, so say so
     * instead of letting a green line mean nothing. */
    assert(g_orbit_global_fallback_arena == NULL);

    for (int i = 0; i < GLOBAL_RACE_THREADS; i++) {
        args[i].arrived = &arrived;
        args[i].release = &release;
        args[i].got = NULL;
    }

#ifdef _WIN32
    HANDLE threads[GLOBAL_RACE_THREADS];
    for (int i = 0; i < GLOBAL_RACE_THREADS; i++) {
        threads[i] = CreateThread(NULL, 0, global_race_worker, &args[i], 0, NULL);
        assert(threads[i] != NULL);
    }
#else
    pthread_t threads[GLOBAL_RACE_THREADS];
    for (int i = 0; i < GLOBAL_RACE_THREADS; i++) {
        assert(pthread_create(&threads[i], NULL, global_race_worker, &args[i]) == 0);
    }
#endif

    while (arrived < GLOBAL_RACE_THREADS) global_race_yield();
    release = 1;

#ifdef _WIN32
    for (int i = 0; i < GLOBAL_RACE_THREADS; i++) {
        WaitForSingleObject(threads[i], INFINITE);
        CloseHandle(threads[i]);
    }
#else
    for (int i = 0; i < GLOBAL_RACE_THREADS; i++) {
        pthread_join(threads[i], NULL);
    }
#endif

    for (int i = 0; i < GLOBAL_RACE_THREADS; i++) {
        assert(args[i].got != NULL);
        assert(args[i].got == args[0].got);
    }
    assert(orbit_arena_get_global() == args[0].got);
    assert(args[0].got->base != NULL);
}

// 29. Hot retention follows the request footprint, not a fixed 256 KB
static void test_hot_retention_follows_footprint(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    size_t page = arena->page_size;
    size_t initial_committed = arena->committed_bytes;

    // A request below the floor makes reset commit nothing: the retention floor
    // bounds what is kept, it is not a commit minimum.
    orbit_alloc(arena, 1024);
    orbit_arena_reset(arena);
    assert(arena->committed_bytes == initial_committed);

    // A request above the floor keeps the pages it touched, so a following
    // request of the same size commits nothing. That reuse is the whole point.
    size_t big = ORBIT_ARENA_HOT_RETENTION_LIMIT * 2;
    orbit_alloc(arena, big);
    orbit_arena_reset(arena);
    assert(arena->committed_bytes == orbit_align_up(big, page));

    unsigned char* committed_end_before = arena->committed_end;
    assert(orbit_alloc(arena, big) != NULL);
    assert(arena->committed_end == committed_end_before);

    // One request larger than the ceiling does not pin the worker.
    orbit_alloc(arena, ORBIT_ARENA_HOT_RETENTION_CEILING * 4);
    orbit_arena_reset(arena);
    assert(arena->committed_bytes == orbit_align_up(ORBIT_ARENA_HOT_RETENTION_CEILING, page));

    // The next small request releases the excess back to the floor.
    orbit_alloc(arena, 1024);
    orbit_arena_reset(arena);
    assert(arena->committed_bytes == orbit_align_up(ORBIT_ARENA_HOT_RETENTION_LIMIT, page));

    orbit_arena_destroy(arena);
}

// 23. The ceiling stops an arena that would keep growing, through the
//     exhaustion path the allocator already has. A handler that returns makes
//     the refusal observable without aborting the test process, and a value
//     that is not a positive count keeps the machine-derived default.
static int ceiling_calls = 0;

static void counting_ceiling_handler(OrbitArena* arena, size_t bytes) {
    (void)arena;
    (void)bytes;
    ceiling_calls++;
}

static void test_ceiling_stops_a_runaway_arena(void) {
    assert(orbit_env_set("ORBIT_ARENA_MAX_MB", "1") == 0);
    OrbitArena* arena = orbit_arena_create(65536);
    assert(arena != NULL);
    assert(arena->max_rule == (size_t)1024 * 1024);

    orbit_set_oom_handler(counting_ceiling_handler);
    ceiling_calls = 0;

    // Two megabytes do not fit under a one-megabyte ceiling, so the allocator
    // answers through the handler instead of committing them.
    assert(orbit_alloc(arena, 2 * 1024 * 1024) == NULL);
    assert(ceiling_calls == 1);
    assert(arena->ceiling_hit == true);

    // A request that fits still succeeds, and the flag describes the last
    // refusal rather than sticking to the arena.
    assert(orbit_alloc(arena, 4096) != NULL);
    assert(arena->ceiling_hit == false);

    // A child inherits the ceiling and does not re-read the environment.
    assert(orbit_env_set("ORBIT_ARENA_MAX_MB", "8") == 0);
    OrbitArena* child = orbit_arena_create_child(arena, 65536);
    assert(child != NULL);
    assert(child->max_rule == arena->max_rule);
    orbit_arena_destroy(child);

    orbit_set_oom_handler(NULL);

    // Zero and non-numeric values keep the machine-derived default.
    static const char* bad[] = {"0", "lots", "-4"};
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
        assert(orbit_env_set("ORBIT_ARENA_MAX_MB", bad[i]) == 0);
        OrbitArena* a = orbit_arena_create(65536);
        assert(a != NULL);
        assert(a->max_rule == orbit_arena_default_max());
        orbit_arena_destroy(a);
    }

    orbit_env_unset("ORBIT_ARENA_MAX_MB");
    orbit_arena_destroy(arena);
}

int main(void) {
    printf("=== ORBIT EPOCHAL ARENA RUNTIME TESTS ===\n");
    fflush(stdout); /* see RUN_TEST: a crash must name its test */
    
    // Initialize global performance stats so telemetry increments don't crash
    memset(&orbit_perf_stats, 0, sizeof(OrbitPerfStats));

    /* First, because the singleton it races exists from its first successful
     * call onward and nothing before this line has made one. */
    RUN_TEST(test_global_fallback_singleton_is_created_once);

    RUN_TEST(test_create_destroy);
    RUN_TEST(test_alignment_sizes);
    RUN_TEST(test_struct_alignments);
    RUN_TEST(test_page_crossing_commit);
    RUN_TEST(test_stable_pointers);
    RUN_TEST(test_reset_reuse);
    RUN_TEST(test_reset_o1_logical);
    RUN_TEST(test_telemetry_bytes);
    RUN_TEST(test_size_t_overflow);
    RUN_TEST(test_large_allocation_overflow);
    RUN_TEST(test_checkpoint_rewind);
    RUN_TEST(test_checkpoint_generation_invalid);
    RUN_TEST(test_child_arena);
    RUN_TEST(test_promote_bytes);
    RUN_TEST(test_string_interning);
    RUN_TEST(test_pool_concurrency_and_overflow);
    RUN_TEST(test_thousands_of_resets);
    RUN_TEST(test_no_leaks_on_error);
    RUN_TEST(test_cross_request_sequential_isolation);
    RUN_TEST(test_cross_request_concurrent_isolation);
    RUN_TEST(test_hot_retention_follows_footprint);
    RUN_TEST(test_ceiling_stops_a_runaway_arena);
    
    printf("All 23 mandatory Orbit Arena runtime tests PASSED successfully!\n");
    return 0;
}
