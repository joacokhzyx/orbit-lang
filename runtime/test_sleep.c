/* orbit_sleep_ms: it blocks for at least what it was asked, and a request
 * that is zero or negative returns at once.
 *
 * Only the lower bound is asserted, because that is the property the stop
 * paths depend on: the OS wakes late, never early. An upper bound would be a
 * race against every other process on the machine, and a test that goes red on
 * a busy runner teaches nobody anything.
 *
 * The negative case is the one that used to be wrong in this repository's own
 * history: a wait that returned immediately was indistinguishable from a wait
 * that had happened, which is how a 3-second escalation finished in 200 ms.
 */
#include <stdio.h>

#include "runtime.h"

static long slept_ms(orbit_int ms) {
    long start = (long)orbit_clock_ms();
    orbit_sleep_ms(ms);
    return (long)orbit_clock_ms() - start;
}

int main(void) {
    int failures = 0;
    long asked = 120;
    long took = slept_ms(asked);
    if (took < asked) {
        printf("FAILED %ld ms slept only %ld\n", asked, took);
        failures++;
    }
    took = slept_ms(0);
    if (took >= asked) {
        printf("FAILED 0 ms took %ld\n", took);
        failures++;
    }
    took = slept_ms(-50);
    if (took >= asked) {
        printf("FAILED a negative request took %ld\n", took);
        failures++;
    }
    if (failures == 0) printf("ok sleep: at least the asked time, zero and negative return\n");
    return failures == 0 ? 0 : 1;
}
