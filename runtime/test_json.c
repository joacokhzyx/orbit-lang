/**
 * @file  test_json.c
 * @brief Object-to-JSON serialization, including lists as JSON arrays.
 *
 * Pins the canonical response form: an object literal with scalar, nested
 * object and list fields serializes to JSON in source order with escaping.
 * Lists hold strings, ints, floats, bools, or objects; an empty list is [].
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "crt_compat.h"
#include <stdint.h>

#include "runtime.h"

/* fflush after the banner, and after PASSED, because that is what makes a crash
 * attributable. On Windows stdout is fully buffered when it is a pipe, not a
 * console, so an access violation loses every buffered line and the CI log
 * shows a bare "[ORBIT RUNTIME CRASH]" with no indication of which test died. */
#define RUN_TEST(name) \
    do { \
        printf("Running test: %s... ", #name); \
        fflush(stdout); \
        name(); \
        printf("PASSED\n"); \
        fflush(stdout); \
    } while (0)

/* Scalars keep source order and escape on the way out. */
static void test_scalars_in_order(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    OrbitObject* o = orbit_object_create(arena);
    orbit_object_set_string(o, "name", "api");
    orbit_object_set_int(o, "count", 42);
    orbit_object_set_bool(o, "healthy", 1);
    const char* j = orbit_object_to_json(arena, o);
    assert(strcmp(j, "{\"name\":\"api\",\"count\":42,\"healthy\":true}") == 0);
    orbit_arena_destroy(arena);
}

/* A string list field is a JSON array of strings. */
static void test_string_list(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    OrbitObject* o = orbit_object_create(arena);
    OrbitResult lr = orbit_list_create(arena, sizeof(void*), 2);
    assert(lr.ok);
    OrbitList* l = (OrbitList*)lr.value;
    orbit_list_push_string(l, "a");
    orbit_list_push_string(l, "b");
    orbit_object_set_list(o, "tags", l);
    const char* j = orbit_object_to_json(arena, o);
    assert(strcmp(j, "{\"tags\":[\"a\",\"b\"]}") == 0);
    orbit_arena_destroy(arena);
}

/* An int list field serializes numbers, not pointers. */
static void test_int_list(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    OrbitObject* o = orbit_object_create(arena);
    OrbitResult lr = orbit_list_create(arena, sizeof(void*), 3);
    assert(lr.ok);
    OrbitList* l = (OrbitList*)lr.value;
    orbit_list_push_int(l, 10);
    orbit_list_push_int(l, 20);
    orbit_list_push_int(l, 30);
    orbit_object_set_list(o, "vals", l);
    const char* j = orbit_object_to_json(arena, o);
    assert(strcmp(j, "{\"vals\":[10,20,30]}") == 0);
    orbit_arena_destroy(arena);
}

/* A list of objects is the array-of-records shape every /files route serves. */
static void test_object_list(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    OrbitObject* o = orbit_object_create(arena);
    OrbitResult lr = orbit_list_create(arena, sizeof(void*), 2);
    assert(lr.ok);
    OrbitList* files = (OrbitList*)lr.value;
    OrbitObject* f1 = orbit_object_create(arena);
    orbit_object_set_string(f1, "name", "welcome.txt");
    orbit_object_set_int(f1, "size", 29);
    orbit_list_push_ref(files, f1);
    OrbitObject* f2 = orbit_object_create(arena);
    orbit_object_set_string(f2, "name", "notes.txt");
    orbit_object_set_int(f2, "size", 41);
    orbit_list_push_ref(files, f2);
    orbit_object_set_list(o, "files", files);
    const char* j = orbit_object_to_json(arena, o);
    assert(strcmp(j, "{\"files\":[{\"name\":\"welcome.txt\",\"size\":29},{\"name\":\"notes.txt\",\"size\":41}]}") == 0);
    orbit_arena_destroy(arena);
}

/* An empty list is [], not null and not a crash. */
static void test_empty_list(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    OrbitObject* o = orbit_object_create(arena);
    OrbitResult lr = orbit_list_create(arena, sizeof(void*), 0);
    assert(lr.ok);
    orbit_object_set_list(o, "tags", (OrbitList*)lr.value);
    const char* j = orbit_object_to_json(arena, o);
    assert(strcmp(j, "{\"tags\":[]}") == 0);
    orbit_arena_destroy(arena);
}

/* A list field reads back as a list through the typed getter. */
static void test_get_list(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    OrbitObject* o = orbit_object_create(arena);
    OrbitResult lr = orbit_list_create(arena, sizeof(void*), 1);
    assert(lr.ok);
    OrbitList* l = (OrbitList*)lr.value;
    orbit_list_push_string(l, "a");
    orbit_object_set_list(o, "tags", l);
    const OrbitList* back = orbit_object_get_list(o, "tags");
    assert(back != NULL);
    assert(back->len == 1);
    assert(orbit_object_get_list(o, "missing") == NULL);
    orbit_arena_destroy(arena);
}

int main(void) {
    printf("test_json\n");
    fflush(stdout); /* see RUN_TEST: a crash must name its test */
    RUN_TEST(test_scalars_in_order);
    RUN_TEST(test_string_list);
    RUN_TEST(test_int_list);
    RUN_TEST(test_object_list);
    RUN_TEST(test_empty_list);
    RUN_TEST(test_get_list);
    return 0;
}
