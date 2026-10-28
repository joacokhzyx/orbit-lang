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

#ifndef _WIN32
#include <unistd.h>
#include <sys/wait.h>
#endif

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

/* Every typed getter round-trips its own kind. */
static void test_getters_match(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    OrbitObject* o = orbit_object_create(arena);
    orbit_object_set_int(o, "n", 42);
    orbit_object_set_float(o, "f", 1.5);
    orbit_object_set_bool(o, "b", 1);
    orbit_object_set_string(o, "s", "hi");
    assert(orbit_object_get_int(o, "n") == 42);
    assert(orbit_object_get_float(o, "f") == 1.5);
    assert(orbit_object_get_bool(o, "b") == 1);
    assert(strcmp(orbit_object_get_string(o, "s"), "hi") == 0);
    orbit_arena_destroy(arena);
}

/* A missing key keeps the quiet defaults: absence is not a mismatch. */
static void test_missing_key_quiet(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    OrbitObject* o = orbit_object_create(arena);
    assert(orbit_object_get_int(o, "nope") == 0);
    assert(orbit_object_get_float(o, "nope") == 0.0);
    assert(orbit_object_get_bool(o, "nope") == 0);
    assert(strcmp(orbit_object_get_string(o, "nope"), "") == 0);
    assert(orbit_object_get_object(o, "nope") == NULL);
    assert(orbit_object_get_list(o, "nope") == NULL);
    orbit_arena_destroy(arena);
}

/* A list whose slots are not one machine word cannot be stored or read:
   every typed accessor moves sizeof(uintptr_t) per slot. Creation refuses
   it with an argument error instead of corrupting silently downstream. */
static void test_create_rejects_non_word_elem_size(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    assert(!orbit_list_create(arena, 4, 2).ok);
    assert(!orbit_list_create(arena, 16, 2).ok);
    assert(orbit_list_create(arena, sizeof(uintptr_t), 2).ok);
    orbit_arena_destroy(arena);
}

#ifndef _WIN32
/* A present field read through the wrong getter aborts (exit 2) instead of
   reinterpreting the bits. Fork like test_oom: the contract under test is
   "does not return". */
static void test_mismatch_aborts(void) {
    pid_t pid = fork();
    assert(pid >= 0);
    if (pid == 0) {
        OrbitArena* arena = orbit_arena_create(65536);
        OrbitObject* o = orbit_object_create(arena);
        orbit_object_set_int(o, "n", 42);
        /* Must not return: an int word read as a pointer truncates. */
        (void)orbit_object_get_string(o, "n");
        _exit(3);
    }
    int status = 0;
    assert(waitpid(pid, &status, 0) == pid);
    assert(WIFEXITED(status));
    assert(WEXITSTATUS(status) == 2);
}

static void test_float_mismatch_aborts(void) {
    pid_t pid = fork();
    assert(pid >= 0);
    if (pid == 0) {
        OrbitArena* arena = orbit_arena_create(65536);
        OrbitObject* o = orbit_object_create(arena);
        orbit_object_set_string(o, "s", "hi");
        /* Must not return: chars decoded as double bits are garbage. */
        (void)orbit_object_get_float(o, "s");
        _exit(3);
    }
    int status = 0;
    assert(waitpid(pid, &status, 0) == pid);
    assert(WIFEXITED(status));
    assert(WEXITSTATUS(status) == 2);
}
#endif

/* Parse produces typed values: ints stay ints, nesting stays nested,
 * and a missing key keeps the quiet defaults instead of failing. */
static void test_parse_scalars(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    OrbitResult r = orbit_json_parse(arena, "{\"name\":\"api\",\"count\":42,\"ratio\":1.5,\"healthy\":true,\"nothing\":null}");
    OrbitObject* o;
    assert(r.ok);
    o = (OrbitObject*)r.value;
    assert(strcmp(orbit_object_get_string(o, "name"), "api") == 0);
    assert(orbit_object_get_int(o, "count") == 42);
    assert(orbit_object_get_float(o, "ratio") == 1.5);
    assert(orbit_object_get_bool(o, "healthy") == 1);
    assert(orbit_object_get_int(o, "nothing") == 0);
    assert(strcmp(orbit_object_get_string(o, "nothing"), "") == 0);
    assert(orbit_object_get_int(o, "missing") == 0);
    assert(strcmp(orbit_object_get_string(o, "missing"), "") == 0);
    orbit_arena_destroy(arena);
}

static void test_parse_nested(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    OrbitResult r = orbit_json_parse(arena, "{\"a\":{\"b\":{\"c\":7}}}");
    OrbitObject* b;
    assert(r.ok);
    b = orbit_object_get_object((OrbitObject*)r.value, "a");
    assert(b != NULL);
    b = orbit_object_get_object(b, "b");
    assert(b != NULL);
    assert(orbit_object_get_int(b, "c") == 7);
    assert(orbit_object_get_object((OrbitObject*)r.value, "missing") == NULL);
    orbit_arena_destroy(arena);
}

static void test_parse_escapes(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    OrbitResult r = orbit_json_parse(arena, "{\"q\":\"a\\\"b\\nc\\ud834\\udd1e\",\"s\":\"x\\/y\\tb\"}");
    OrbitObject* o;
    assert(r.ok);
    o = (OrbitObject*)r.value;
    assert(strcmp(orbit_object_get_string(o, "q"), "a\"b\nc\xF0\x9D\x84\x9E") == 0);
    assert(strcmp(orbit_object_get_string(o, "s"), "x/y\tb") == 0);
    orbit_arena_destroy(arena);
}

static void test_parse_arrays(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    OrbitResult r = orbit_json_parse(arena, "{\"ids\":[1,2,3],\"tags\":[\"a\",\"b\"],\"fs\":[1.5,2.5],\"bs\":[true,false],\"os\":[{\"id\":1},{\"id\":2}],\"e\":[]}");
    OrbitObject* o;
    assert(r.ok);
    o = (OrbitObject*)r.value;
    assert(orbit_json_array_len(o, "ids") == 3);
    assert(orbit_json_array_get_int(o, "ids", 0) == 1);
    assert(orbit_json_array_get_int(o, "ids", 2) == 3);
    assert(orbit_json_array_len(o, "tags") == 2);
    assert(strcmp(orbit_json_array_get_string(o, "tags", 1), "b") == 0);
    assert(orbit_json_array_get_float(o, "fs", 0) == 1.5);
    assert(orbit_json_array_get_float(o, "fs", 1) == 2.5);
    assert(orbit_json_array_get_bool(o, "bs", 0) == 1);
    assert(orbit_json_array_get_bool(o, "bs", 1) == 0);
    assert(orbit_json_array_len(o, "os") == 2);
    assert(orbit_object_get_int(orbit_json_array_get_object(o, "os", 1), "id") == 2);
    assert(orbit_json_array_len(o, "e") == 0);
    assert(orbit_json_array_len(o, "missing") == 0);
    assert(orbit_json_array_get_int(o, "missing", 0) == 0);
    assert(strcmp(orbit_json_array_get_string(o, "missing", 0), "") == 0);
    orbit_arena_destroy(arena);
}

/* Malformed input is err, never partial and never abort. Each case is one
 * rule: truncation, trailing comma, single quotes, bare keys, non-object
 * tops, trailing data, leading zeros, dangling fraction/exponent, mixed
 * or null-bearing or nested arrays, overflow past int64 or finite
 * double, lone surrogates. */
static void test_parse_rejects(void) {
    static const char* bad[] = {
        "{",
        "{\"a\":",
        "[1,]",
        "{'a':1}",
        "{a:1}",
        "",
        "null",
        "42",
        "[1]",
        "{\"a\":1} trailing",
        "{\"a\":01}",
        "{\"a\":1.}",
        "{\"a\":1e}",
        "{\"a\":[1,\"x\"]}",
        "{\"a\":[null]}",
        "{\"a\":[[1]]}",
        "{\"a\":9223372036854775808}",
        "{\"a\":1e999}",
        "{\"a\":\"\\ud800\"}",
        "{\"a\":\"\\ud800\\u\"}",
        "{\"a\":\"\\ud800\\u12\"}",
        "{\"a\":\"\\udc00\"}",
        "{\"a\":\"bad\\escape\"}",
        "{\"a\":\"unterminated}",
        "{\"a\":tru}",
    };
    size_t i;
    OrbitArena* arena = orbit_arena_create(65536);
    for (i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
        OrbitResult r = orbit_json_parse(arena, bad[i]);
        if (r.ok) {
            printf("FAILED parse accepted: %s\n", bad[i]);
            assert(!r.ok);
        }
    }
    {
        /* Nesting past 64 levels is refused, not recursed. */
        char deep[300];
        size_t k = 0;
        size_t d;
        OrbitResult r;
        for (d = 0; d < 70; d++) deep[k++] = '{';
        deep[k++] = '1';
        for (d = 0; d < 70; d++) deep[k++] = '}';
        deep[k] = '\0';
        r = orbit_json_parse(arena, deep);
        assert(!r.ok);
    }
    {
        /* A repeated key overwrites: last value wins. */
        OrbitResult r = orbit_json_parse(arena, "{\"a\":1,\"a\":2}");
        assert(r.ok);
        assert(orbit_object_get_int((OrbitObject*)r.value, "a") == 2);
    }
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
    RUN_TEST(test_parse_scalars);
    RUN_TEST(test_parse_nested);
    RUN_TEST(test_parse_escapes);
    RUN_TEST(test_parse_arrays);
    RUN_TEST(test_parse_rejects);
    RUN_TEST(test_getters_match);
    RUN_TEST(test_missing_key_quiet);
#ifndef _WIN32
    RUN_TEST(test_mismatch_aborts);
    RUN_TEST(test_float_mismatch_aborts);
#endif
    RUN_TEST(test_create_rejects_non_word_elem_size);
    return 0;
}
