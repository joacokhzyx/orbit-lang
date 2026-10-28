/* orbit_random_bytes: length, range, empty, negative.
 *
 * Only deterministic properties are pinned: the requested length, every
 * byte inside 0..255, the empty list for zero, err for a negative count.
 * Whether two draws differ is verified by hand -- randomness cannot be
 * asserted deterministically, and a suite that always passes is worth
 * more than a probabilistic one that usually does.
 */
#include <stdio.h>

#include "runtime.h"

int main(void) {
    int failures = 0;
    {
        OrbitArena* arena = orbit_arena_create(65536);
        OrbitResult r = orbit_random_bytes(arena, 16);
        if (!r.ok) {
            printf("FAILED 16 bytes not ok\n");
            failures++;
        } else {
            OrbitList* list = (OrbitList*)r.value;
            size_t i;
            if (list->len != 16) {
                printf("FAILED length: got %d want 16\n", (int)list->len);
                failures++;
            }
            for (i = 0; i < list->len; i++) {
                uintptr_t word = 0;
                memcpy(&word, (const char*)list->data + i * list->elem_size,
                       sizeof(uintptr_t));
                if (word > 255) {
                    printf("FAILED range: slot %d holds %lu\n",
                           (int)i, (unsigned long)word);
                    failures++;
                    break;
                }
            }
        }
        orbit_arena_destroy(arena);
    }
    {
        OrbitArena* arena = orbit_arena_create(65536);
        OrbitResult r = orbit_random_bytes(arena, 0);
        if (!r.ok || ((OrbitList*)r.value)->len != 0) {
            printf("FAILED empty list\n");
            failures++;
        }
        orbit_arena_destroy(arena);
    }
    {
        OrbitArena* arena = orbit_arena_create(65536);
        OrbitResult r = orbit_random_bytes(arena, -1);
        if (r.ok) {
            printf("FAILED negative count accepted\n");
            failures++;
        }
        orbit_arena_destroy(arena);
    }
    /* A count whose slot bytes wrap size_t is an error, not a short list that
     * claims the full capacity: 8 * (2^61 + 1) wraps to 8. */
    {
        OrbitArena* arena = orbit_arena_create(65536);
        OrbitResult r = orbit_random_bytes(arena, ((orbit_int)1 << 61) + 1);
        if (r.ok) {
            printf("FAILED wrapped count accepted\n");
            failures++;
        }
        r = orbit_list_create(arena, sizeof(uintptr_t), SIZE_MAX / sizeof(uintptr_t) + 2);
        if (r.ok) {
            printf("FAILED wrapped list capacity accepted\n");
            failures++;
        }
        r = orbit_list_create(arena, sizeof(uintptr_t), 4);
        if (!r.ok) {
            printf("FAILED ordinary list refused\n");
            failures++;
        }
        orbit_arena_destroy(arena);
    }
    if (failures == 0) {
        printf("test_random: all cases pass\n");
    }
    return failures == 0 ? 0 : 1;
}
