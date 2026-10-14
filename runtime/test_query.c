/* orbit_http_query_get/all: percent-decoding (+ to space) and repeated
 * keys. The path decoder keeps '+' literal (pinned by
 * test_params_decode.c); the query decoder must not, and keys decode
 * for matching as well as values for return. First repeated key wins
 * for the scalar; the list carries all of them in order.
 */
#include <stdio.h>
#include <string.h>

#include "runtime.h"

static OrbitRequest* req_with(OrbitArena* arena, char* query) {
    static OrbitRequest r;
    memset(&r, 0, sizeof(r));
    (void)arena;
    r.query = query;
    return &r;
}

int main(void) {
    int failures = 0;
    OrbitArena* arena = orbit_arena_create(65536);

    /* Percent-decoding, both cases, plus-to-space. */
    {
        OrbitRequest* r = req_with(arena, "q=a%20b%2Fc+d&x=%41");
        if (strcmp(orbit_http_query_get(arena, r, "q"), "a b/c d") != 0) {
            printf("FAILED decode: got %s\n", orbit_http_query_get(arena, r, "q"));
            failures++;
        }
        if (strcmp(orbit_http_query_get(arena, r, "x"), "A") != 0) {
            printf("FAILED upper hex\n");
            failures++;
        }
    }
    /* Keys decode for matching too. */
    {
        OrbitRequest* r = req_with(arena, "a%20b=1");
        if (strcmp(orbit_http_query_get(arena, r, "a b"), "1") != 0) {
            printf("FAILED key decode\n");
            failures++;
        }
    }
    /* First repeated key wins the scalar; the list has all in order. */
    {
        OrbitRequest* r = req_with(arena, "tag=a&tag=b&tag=c");
        if (strcmp(orbit_http_query_get(arena, r, "tag"), "a") != 0) {
            printf("FAILED first wins\n");
            failures++;
        }
        {
            OrbitList* l = orbit_http_query_get_all(arena, r, "tag");
            if (!l || l->len != 3) {
                printf("FAILED all length\n");
                failures++;
            } else {
                /* Read back through the public typed readers, the way
                 * generated code does, not by reaching into slots. */
                if (strcmp(orbit_list_read_string(l, 0, __func__, __FILE__, __LINE__), "a") != 0) {
                    printf("FAILED all[0]\n");
                    failures++;
                }
                if (strcmp(orbit_list_read_string(l, 2, __func__, __FILE__, __LINE__), "c") != 0) {
                    printf("FAILED all[2]\n");
                    failures++;
                }
            }
        }
    }
    /* Shapes: empty value, bare flag, missing key, missing list. */
    {
        OrbitRequest* r = req_with(arena, "e=&flag&k=v");
        if (strcmp(orbit_http_query_get(arena, r, "e"), "") != 0) {
            printf("FAILED empty value\n");
            failures++;
        }
        if (strcmp(orbit_http_query_get(arena, r, "flag"), "") != 0) {
            printf("FAILED bare flag\n");
            failures++;
        }
        if (strcmp(orbit_http_query_get(arena, r, "missing"), "") != 0) {
            printf("FAILED missing\n");
            failures++;
        }
        {
            OrbitList* l = orbit_http_query_get_all(arena, r, "missing");
            if (!l || l->len != 0) {
                printf("FAILED missing list\n");
                failures++;
            }
        }
    }
    orbit_arena_destroy(arena);
    if (failures == 0) {
        printf("test_query: all cases pass\n");
    }
    return failures == 0 ? 0 : 1;
}
