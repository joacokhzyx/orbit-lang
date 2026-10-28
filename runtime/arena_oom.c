#ifndef ORBIT_RT_ARENA_OOM_C
#define ORBIT_RT_ARENA_OOM_C

/* Out-of-memory configuration: the handler slot and the request-boundary
 * recovery. A program that never installs a handler links none of this. */
#include "module_prelude.h"
#include "arena.h"
#include "arena_vm.h"
#include "arena_internal.h"
#include <setjmp.h>
#include <stdlib.h>
#include <string.h>
#include "crt_compat.h"

/** @brief Install @p handler for allocation failure, or pass NULL to restore the aborting default. */
void orbit_set_oom_handler(OrbitOomHandler handler) {
    orbit_oom_handler = handler ? handler : orbit_oom_abort_default;
}

/** @brief The handler that orbit_alloc would call on exhaustion. NULL means the aborting default. */
OrbitOomHandler orbit_get_oom_handler(void) {
    return orbit_oom_handler;
}

/* ──────────────────────────────────────────────────────────────────────
 * Request-boundary OOM recovery.
 *
 * A Kynx lease caps one request's arena (runtime/kynx.c, 16 MB by default),
 * and a request that asked for more than the cap used to be answered by the
 * aborting default above: a refusal at the request boundary ended the
 * process. The refusal belongs to one request, so the answer does too, and
 * the generated router is the only frame that holds both the request and its
 * arena. compiler/emit/route_runtime.orb installs this handler once per
 * worker and arms it for exactly the span of one request; a refusal inside
 * that span returns to the arm point instead of exiting.
 *
 * What the longjmp skips is only the frames between the allocator and the
 * boundary, and nothing there holds a lock across an allocation: every lock
 * in the runtime is a CAS on a flag or a spinlock held around counters only
 * (runtime/arena_pool.c, runtime/kynx.c, runtime/ledger.c), and the
 * per-route ledger row is a set of atomic counters, so a skipped exit costs
 * that request its row rather than corrupting one. A refusal inside a sqlite
 * query leaks the prepared statement and no more: sqlite3 locks per call,
 * never across one.
 *
 * The handler assumes nothing about room left in the arena. The recovery
 * builds the 5xx it is about to send, and if the reservation itself is gone
 * that allocation refuses too -- with the armed flag already cleared, so the
 * aborting default runs and the process ends as it always did. An exhausted
 * arena has no room to answer with; that is the reservation's job.
 */
static ORBIT_THREAD_LOCAL jmp_buf* orbit_request_oom_target;
static ORBIT_THREAD_LOCAL int orbit_request_oom_armed;
static ORBIT_THREAD_LOCAL char orbit_request_oom_text[256];

static void orbit_request_oom_handler(OrbitArena* arena, size_t bytes) {
    if (orbit_request_oom_armed && orbit_request_oom_target) {
        orbit_request_oom_armed = 0;
        /* The facts the aborting default prints, minus the exit. The lease
         * clause is a measurement, not a claim about the cause: which arena
         * refused and what the lease held are both facts. */
        char* t = orbit_request_oom_text;
        const size_t cap = sizeof orbit_request_oom_text;
        size_t n = orbit_oom_put(t, cap, 0, "503 request refused: ");
        n = orbit_oom_put_u(t, cap, n, bytes);
        n = orbit_oom_put(t, cap, n, " bytes refused; ");
        n = orbit_oom_put_holds(t, cap, n, arena);
        if (current_lease) {
            n = orbit_oom_put(t, cap, n, "; lease holds ");
            n = orbit_oom_put_u(t, cap, n, current_lease->arena_bytes);
            n = orbit_oom_put(t, cap, n, " of ");
            n = orbit_oom_put_u(t, cap, n, current_lease->arena_limit);
            orbit_oom_put(t, cap, n, " bytes");
        }
        longjmp(*orbit_request_oom_target, 1);
    }
    orbit_oom_abort_default(arena, bytes);
}

/** @brief Install the request-boundary handler. The generated worker loop calls this once per worker. */
void orbit_request_oom_install(void) {
    orbit_set_oom_handler(orbit_request_oom_handler);
}

/** @brief Arm the boundary for one request, landing in the caller's frame.
 *
 * @p target is the caller's own jmp_buf and must outlive the request: the
 * setjmp is deliberately not taken here. longjmp can only return to a frame
 * that is still on the stack, and a helper that setjmp'd and returned would
 * hand the handler a dead frame -- measured while this was written, the
 * caller's setjmp then returned garbage instead of 1. So the frame that stays
 * alive across the request owns the buffer and calls setjmp on it; this file
 * only remembers where to land.
 */
void orbit_request_oom_arm(jmp_buf* target) {
    orbit_request_oom_target = target;
    orbit_request_oom_armed = 1;
}

/** @brief Disarm the boundary. Armed only while one request's frame is on the stack. */
void orbit_request_oom_disarm(void) {
    orbit_request_oom_armed = 0;
    orbit_request_oom_target = NULL;
}

/** @brief The refusal text the boundary answer sends, built where the facts still were. */
const char* orbit_request_oom_message(void) {
    return orbit_request_oom_text;
}

#endif
