/* orbit_result_ok_float / orbit_result_get_float: a double round-trips by
 * bits, not by value.
 *
 * Boxing a double through uintptr_t truncates it (1.5 becomes 1), the same
 * truncation the list element table documents in runtime/collections.c, so
 * these two copy the IEEE-754 pattern with memcpy. The cases are the ones
 * a numeric cast gets wrong: a fraction, a negative fraction, both zeros
 * (which differ in exactly one bit), and a large magnitude. Bit-compared
 * with memcmp, because == cannot tell 0.0 from -0.0 and the box promises
 * the pattern, not the number.
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#include "runtime.h"

typedef struct {
    orbit_float value;
} float_case;

static const float_case CASES[] = {
    {1.5},
    {-2.25},
    {0.0},
    {-0.0},
    {1e300},
    {123456.789},
};

int main(void) {
    int failures = 0;
    size_t i;
    for (i = 0; i < sizeof(CASES) / sizeof(CASES[0]); i++) {
        OrbitResult r = orbit_result_ok_float(CASES[i].value);
        if (!r.ok) {
            printf("FAILED ok flag: case %d not ok\n", (int)i);
            failures++;
        }
        if (r.error_code != ORBIT_ERR_NONE) {
            printf("FAILED error code: case %d code %d\n", (int)i, (int)r.error_code);
            failures++;
        }
        {
            orbit_float got = orbit_result_get_float(r);
            if (memcmp(&got, &CASES[i].value, sizeof(orbit_float)) != 0) {
                printf("FAILED round trip: case %d bits differ\n", (int)i);
                failures++;
            }
        }
    }
    if (failures == 0) {
        printf("test_result_float: all %d cases pass\n",
               (int)(sizeof(CASES) / sizeof(CASES[0])));
    }
    return failures == 0 ? 0 : 1;
}
