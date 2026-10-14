/* orbit_os_exec: captured stdout plus the nonzero-exit prefix.
 *
 * Built with -DORBIT_WITH_EXEC (the R3.6 opt-in): without the flag the
 * function answers "" by design, so this row carries the define the same
 * way the selfhost build does. Commands are the portable intersection:
 * `echo` and `exit` exist in both POSIX sh and Windows cmd. Exact output
 * is not pinned -- line endings differ -- only containment and the
 * error prefix contract.
 */
#include <stdio.h>
#include <string.h>

#include "runtime.h"

int main(void) {
    int failures = 0;
    {
        OrbitArena* arena = orbit_arena_create(65536);
        orbit_string out = orbit_os_exec(arena, "echo hi");
        if (!out || strstr(out, "hi") == NULL) {
            printf("FAILED echo: got %s\n", out ? out : "(null)");
            failures++;
        }
        if (out && strstr(out, "[ERROR") != NULL) {
            printf("FAILED echo carries error prefix: %s\n", out);
            failures++;
        }
        orbit_arena_destroy(arena);
    }
    {
        OrbitArena* arena = orbit_arena_create(65536);
        orbit_string out = orbit_os_exec(arena, "exit 1");
        if (!out || strstr(out, "[ERROR: process exited with code 1]") == NULL) {
            printf("FAILED exit prefix: got %s\n", out ? out : "(null)");
            failures++;
        }
        orbit_arena_destroy(arena);
    }
    if (failures == 0) {
        printf("test_exec: all cases pass\n");
    }
    return failures == 0 ? 0 : 1;
}
