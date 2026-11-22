#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "runtime.h"

/* The runtime had no read of stdin, which is what a language server needs
 * first. These tests drive the three calls through a file the test writes and
 * hands to `stdin`, so the same assertions run on both hosts without a pipe
 * helper: a CRLF stream reads like an LF one, a byte count takes exactly what
 * it is asked for, and `at_end` is what separates an empty line from EOF. */

static int tests_passed = 0;
#define RUN_TEST(name) do { \
    printf("Running test: %s... ", #name); fflush(stdout); \
    name(); printf("PASSED\n"); fflush(stdout); tests_passed++; \
} while (0)

static OrbitArena* fresh(void) {
    OrbitArena* arena = orbit_arena_create(1 << 16);
    assert(arena != NULL);
    return arena;
}

static void feed(const char* text, const char* mode) {
    const char* path = "test_stdin_input.txt";
    FILE* f = fopen(path, "wb");
    assert(f != NULL);
    assert(fwrite(text, 1, strlen(text), f) == strlen(text));
    fclose(f);
    assert(freopen(path, mode, stdin) != NULL);
}

static void test_crlf_and_lf_read_the_same(void) {
    OrbitArena* arena = fresh();
    feed("Content-Length: 3\r\n\r\n{}", "rb");
    assert(strcmp(orbit_stdin_read_line(arena), "Content-Length: 3") == 0);
    assert(strcmp(orbit_stdin_read_line(arena), "") == 0);
    assert(strcmp(orbit_stdin_read_bytes(arena, 2), "{}") == 0);
}

static void test_bytes_are_verbatim(void) {
    OrbitArena* arena = fresh();
    feed("{\"a\":1}\n{\"b\":2}", "rb");
    assert(strcmp(orbit_stdin_read_bytes(arena, 7), "{\"a\":1}") == 0);
    assert(strcmp(orbit_stdin_read_line(arena), "") == 0);
    assert(strcmp(orbit_stdin_read_bytes(arena, 7), "{\"b\":2}") == 0);
}

static void test_at_end_separates_empty_line_from_eof(void) {
    OrbitArena* arena = fresh();
    feed("line\n", "rb");
    assert(orbit_stdin_at_end() == false);
    assert(strcmp(orbit_stdin_read_line(arena), "line") == 0);
    assert(strcmp(orbit_stdin_read_line(arena), "") == 0);
    assert(orbit_stdin_at_end() == true);
}

static void test_short_read_returns_what_arrived(void) {
    OrbitArena* arena = fresh();
    feed("abc", "rb");
    assert(strcmp(orbit_stdin_read_bytes(arena, 10), "abc") == 0);
    assert(orbit_stdin_at_end() == true);
}

int main(void) {
    printf("stdin property tests\n"); fflush(stdout);
    RUN_TEST(test_crlf_and_lf_read_the_same);
    RUN_TEST(test_bytes_are_verbatim);
    RUN_TEST(test_at_end_separates_empty_line_from_eof);
    RUN_TEST(test_short_read_returns_what_arrived);
    printf("stdin: %d/4 PASSED\n", tests_passed); fflush(stdout);
    remove("test_stdin_input.txt");
    return tests_passed == 4 ? 0 : 1;
}
