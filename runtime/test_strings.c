/* The string utilities of runtime/orb/strings.orb keep the results collections.c
 * gave for a NULL argument, and the results for ordinary strings. */
#include "runtime.h"

static int failures = 0;

#define CHECK(cond)                                                          \
    do {                                                                     \
        if (!(cond)) {                                                       \
            fprintf(stderr, "test_strings: %s:%d: %s\n", __FILE__, __LINE__, \
                    #cond);                                                  \
            failures++;                                                      \
        }                                                                    \
    } while (0)

int main(void) {
    OrbitArena* a = orbit_arena_create(1 << 20);
    CHECK(a != NULL);

    CHECK(orbit_string_starts_with(NULL, "a") == false);
    CHECK(orbit_string_starts_with("a", NULL) == false);
    CHECK(orbit_string_ends_with(NULL, "a") == false);
    CHECK(orbit_string_ends_with("a", NULL) == false);
    CHECK(orbit_string_contains(NULL, "a") == false);
    CHECK(orbit_string_contains("a", NULL) == false);
    CHECK(orbit_string_indexOf(NULL, "a") == -1);
    CHECK(orbit_string_indexOf("a", NULL) == -1);
    CHECK(strcmp(orbit_string_to_upper(a, NULL), "") == 0);
    CHECK(strcmp(orbit_string_to_upper(NULL, "abc"), "") == 0);
    CHECK(strcmp(orbit_string_to_lower(a, NULL), "") == 0);
    CHECK(strcmp(orbit_string_to_lower(NULL, "ABC"), "") == 0);
    CHECK(strcmp(orbit_string_trim(a, NULL), "") == 0);
    CHECK(strcmp(orbit_string_trim(NULL, " a "), "") == 0);

    CHECK(orbit_string_starts_with("orbit", "orb") == true);
    CHECK(orbit_string_starts_with("orbit", "orbits") == false);
    CHECK(orbit_string_starts_with("orbit", "") == true);
    CHECK(orbit_string_starts_with("", "a") == false);
    CHECK(orbit_string_ends_with("orbit", "bit") == true);
    CHECK(orbit_string_ends_with("orbit", "xorbit") == false);
    CHECK(orbit_string_ends_with("orbit", "") == true);
    CHECK(orbit_string_contains("orbit", "rb") == true);
    CHECK(orbit_string_contains("orbit", "") == true);
    CHECK(orbit_string_contains("orbit", "bix") == false);
    CHECK(orbit_string_indexOf("orbit", "bit") == 2);
    CHECK(orbit_string_indexOf("orbit", "") == 0);
    CHECK(orbit_string_indexOf("aab", "ab") == 1);
    CHECK(orbit_string_indexOf("orbit", "x") == -1);
    CHECK(orbit_string_indexOf("", "x") == -1);

    CHECK(strcmp(orbit_string_to_upper(a, "aZ_9 z"), "AZ_9 Z") == 0);
    CHECK(strcmp(orbit_string_to_lower(a, "Az_9 Z"), "az_9 z") == 0);
    CHECK(strcmp(orbit_string_to_upper(a, ""), "") == 0);
    CHECK(strcmp(orbit_string_trim(a, " \t\r\n ab c \n"), "ab c") == 0);
    CHECK(strcmp(orbit_string_trim(a, "ab"), "ab") == 0);
    CHECK(strcmp(orbit_string_trim(a, " \t\r\n"), "") == 0);
    CHECK(strcmp(orbit_string_trim(a, ""), "") == 0);

    if (failures == 0) {
        printf("strings ok\n");
        return 0;
    }
    return 1;
}
