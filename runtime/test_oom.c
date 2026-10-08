/**
 * @file  test_oom.c
 * @brief Runtime allocation-failure policy tests (FMT-1).
 *
 * orbit_alloc used to return NULL on exhaustion and left the decision to the
 * caller, but of 107 orbit_alloc call sites in the runtime only 5 checked the
 * result. The rest turned an allocation failure into a write through a null
 * pointer. Because orbit_string is a NUL-terminated const char*, the NULL was
 * also indistinguishable from a legitimately empty string, which is how
 * `orbit fmt` came to report success after zeroing a source file.
 *
 * The policy is now: exhaustion is loud by default (report, then abort), and a
 * program that wants to recover opts in with orbit_set_oom_handler or uses
 * orbit_alloc_try. These tests pin all four halves of that contract, including
 * the one that is easy to get wrong: a bad *argument* must stay a quiet NULL
 * rather than aborting, because argument validation is a recoverable path and
 * orbit_file_write's NULL checks depend on it (FMT-0).
 *
 * The abort is observed in a child process, since it is not supposed to
 * return. Conventions follow runtime/test_arena.c.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <assert.h>
#include <signal.h>
#include <unistd.h>
#include <sys/wait.h>

#include "runtime.h"

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

/** A request no arena can satisfy, used to reach the exhaustion paths. */
#define IMPOSSIBLE ((size_t)1 << 62)

static int handler_calls = 0;
static size_t handler_bytes = 0;

/** An OOM handler that returns, so the allocator hands NULL back instead. */
static void counting_handler(OrbitArena* arena, size_t bytes) {
    (void)arena;
    handler_calls++;
    handler_bytes = bytes;
}

static void test_a_handler_is_installed_by_default(void) {
    /* The aborting default is a real handler, not a null slot: the API
     * promises orbit_get_oom_handler() only yields NULL if no handler exists,
     * and callers rely on there always being something to call. */
    assert(orbit_get_oom_handler() != NULL);
}

static void test_default_handler_aborts_on_exhaustion(void) {
    /* A child process, because the contract under test is "does not return".
     * Asserting on the signal rather than on any output keeps this
     * independent of the diagnostic wording. */
    pid_t pid = fork();
    assert(pid >= 0);
    if (pid == 0) {
        OrbitArena* arena = orbit_arena_create(1024);
        if (!arena) _exit(2);
        void* p = orbit_alloc(arena, IMPOSSIBLE);
        /* Only reached if the default handler failed to abort. */
        (void)p;
        _exit(3);
    }
    int status = 0;
    assert(waitpid(pid, &status, 0) == pid);
    assert(WIFSIGNALED(status));
    assert(WTERMSIG(status) == SIGABRT);
}

static void test_try_returns_null_without_aborting(void) {
    OrbitArena* arena = orbit_arena_create(1024);
    assert(arena != NULL);
    assert(orbit_alloc_try(arena, IMPOSSIBLE) == NULL);
    /* Still running, which is the point: the caller gets to react. */
    assert(orbit_alloc_try(arena, 16) != NULL);
    orbit_arena_destroy(arena);
}

static void test_installed_handler_replaces_the_abort(void) {
    OrbitArena* arena = orbit_arena_create(1024);
    assert(arena != NULL);
    handler_calls = 0;
    handler_bytes = 0;
    orbit_set_oom_handler(counting_handler);
    void* p = orbit_alloc(arena, IMPOSSIBLE);
    assert(p == NULL);
    assert(handler_calls == 1);
    assert(handler_bytes == IMPOSSIBLE);
    /* Recovery still works: the arena was not left poisoned. */
    assert(orbit_alloc(arena, 16) != NULL);
    /* Passing NULL restores the aborting default. */
    orbit_set_oom_handler(NULL);
    assert(orbit_get_oom_handler() != counting_handler);
    orbit_arena_destroy(arena);
}

static void test_bad_arguments_stay_quiet(void) {
    OrbitArena* arena = orbit_arena_create(1024);
    assert(arena != NULL);
    handler_calls = 0;
    orbit_set_oom_handler(counting_handler);
    /* A null arena and a zero-byte request are argument errors, not
     * exhaustion. Routing them through the OOM handler would abort a process
     * that is midway through validating its input. */
    assert(orbit_alloc(NULL, 16) == NULL);
    assert(orbit_alloc(arena, 0) == NULL);
    assert(orbit_alloc_try(NULL, 16) == NULL);
    assert(orbit_alloc_try(arena, 0) == NULL);
    assert(handler_calls == 0);
    orbit_set_oom_handler(NULL);
    orbit_arena_destroy(arena);
}

int main(void) {
    printf("=== Orbit runtime allocation-failure policy tests ===\n");
    RUN_TEST(test_a_handler_is_installed_by_default);
    RUN_TEST(test_default_handler_aborts_on_exhaustion);
    RUN_TEST(test_try_returns_null_without_aborting);
    RUN_TEST(test_installed_handler_replaces_the_abort);
    RUN_TEST(test_bad_arguments_stay_quiet);
    printf("All 5 Orbit runtime allocation-failure policy tests PASSED successfully!\n");
    return 0;
}
