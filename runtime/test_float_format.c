/* orbit_float_to_string: a float prints as a float.
 *
 * This function had no C-level test at all, which is why a `strncat` in it
 * survived until the Windows CI job went red five runs in a row: the suite
 * tests the behaviour through generated programs and gcc has no opinion on
 * strncat, so nothing here was ever compiled by a toolchain that did.
 *
 * The cases are the ones that broke at least once:
 *
 *   2.0 printed as "2". The fixed-notation search starts at zero decimals and
 *   %.0f of 2.0 is "2", which round-trips, so every integral float found its
 *   answer at the first step and a float carried no information that it was a
 *   float.
 *
 *   2500.0 printed as "2.5e+03". The search minimises precision, not length,
 *   and %g switches to exponential when the exponent reaches the precision.
 *
 *   1.758241758241763 needs 16 significant figures, so a fixed %.15g would
 *   drop a digit and stop round-tripping.
 *
 *   1e6 printed as "100000". The %g loop left the length describing its own
 *   output, and the final memcpy copied that shorter number.
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#include "runtime.h"

typedef struct {
    orbit_float value;
    const char* want;
} float_case;

static const float_case CASES[] = {
    {2.0,                     "2.0"},
    {3.0,                     "3.0"},
    {-2.0,                    "-2.0"},
    {0.0,                     "0.0"},
    {100.0,                   "100.0"},
    {2500.0,                  "2500.0"},
    {1e6,                     "1000000.0"},
    {1.5,                     "1.5"},
    {2.25,                    "2.25"},
    {0.0015,                  "0.0015"},
    {1.758241758241763,       "1.758241758241763"},
    /* Outside the range where fixed notation is the readable answer. */
    {1e-9,                    "1e-09"},
    {1e20,                    "1e+20"},
};

int main(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    int failures = 0;
    size_t i;
    for (i = 0; i < sizeof(CASES) / sizeof(CASES[0]); i++) {
        const char* got = orbit_float_to_string(arena, CASES[i].value);
        if (strcmp(got, CASES[i].want) != 0) {
            printf("FAILED %s: got %s want %s\n",
                   "float_to_string", got, CASES[i].want);
            failures++;
        }
    }
    /* The append helper is what the ".0" now goes through, and it is the line
     * MSVC deprecated. Test its bounds too, because a silent truncation there
     * would print "2" again for one character of reason. */
    {
        char small[4];
        small[0] = '1';
        small[1] = '2';
        small[2] = '3';
        small[3] = '\0';
        orbit_str_append(small, sizeof(small), ".0");
        if (strcmp(small, "123") != 0) {
            printf("FAILED append must not overrun: got %s want 123\n", small);
            failures++;
        }
    }
    {
        char roomy[8];
        strcpy(roomy, "2500");
        orbit_str_append(roomy, sizeof(roomy), ".0");
        if (strcmp(roomy, "2500.0") != 0) {
            printf("FAILED append: got %s want 2500.0\n", roomy);
            failures++;
        }
    }
    if (failures == 0) {
        printf("test_float_format: all %d cases pass\n",
               (int)(sizeof(CASES) / sizeof(CASES[0])));
    }
    orbit_arena_destroy(arena);
    return failures == 0 ? 0 : 1;
}
