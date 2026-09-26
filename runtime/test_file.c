/**
 * @file  test_file.c
 * @brief Runtime file-IO tests, with a focus on honest failure reporting.
 *
 * The contract these tests pin down is the one that lets a tool destroy a
 * user's source: `fopen(..., "wb")` truncates the target the moment it
 * succeeds, so a write that fails afterwards has already done the damage. A
 * `true` return therefore has to mean "the bytes are on disk", not "fopen
 * worked".
 *
 * A previous implementation returned true unconditionally and passed the
 * string straight to `fprintf`. It reported success for a short write, and
 * passing NULL content was undefined behaviour (it crashed), so `orbit fmt`
 * could replace a source file with a 0-byte file and print "Formatted".
 *
 * Conventions follow runtime/test_arena.c.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "crt_compat.h"
#include <stdint.h>

#include "runtime.h"

#define RUN_TEST(name) \
    do { \
        printf("Running test: %s... ", #name); \
        name(); \
        printf("PASSED\n"); \
    } while (0)

static const char* TEST_PATH = "test_file_tmp.bin";

/** Read the whole file into buf. Returns the byte count, or -1 on error. */
static long slurp(const char* path, char* buf, size_t cap) {
    FILE* f = orbit_fopen(path, "rb");
    if (!f) return -1;
    size_t n = fread(buf, 1, cap - 1, f);
    fclose(f);
    buf[n] = '\0';
    return (long)n;
}

// 1. The ordinary path: write, read back, overwrite.
static void test_write_read_roundtrip(void) {
    assert(orbit_file_write(TEST_PATH, "hello") == true);

    char buf[64];
    long n = slurp(TEST_PATH, buf, sizeof(buf));
    assert(n == 5);
    assert(strcmp(buf, "hello") == 0);

    // Rewriting replaces the contents rather than appending.
    assert(orbit_file_write(TEST_PATH, "hi") == true);
    n = slurp(TEST_PATH, buf, sizeof(buf));
    assert(n == 2);
    assert(strcmp(buf, "hi") == 0);

    remove(TEST_PATH);
}

// 2. Content longer than a short buffer is written in full.
static void test_large_content(void) {
    static char big[100000];
    for (size_t i = 0; i < sizeof(big) - 1; i++) big[i] = (char)('a' + (i % 26));
    big[sizeof(big) - 1] = '\0';

    assert(orbit_file_write(TEST_PATH, big) == true);

    FILE* f = orbit_fopen(TEST_PATH, "rb");
    assert(f != NULL);
    char got[100001];
    size_t n = fread(got, 1, sizeof(got) - 1, f);
    fclose(f);
    got[n] = '\0';
    assert(n == sizeof(big) - 1);
    assert(strcmp(got, big) == 0);

    remove(TEST_PATH);
}

// 3. Refused writes must leave the existing file untouched. This is the case
//    that used to destroy files: fopen already truncated before the failure.
static void test_refused_write_preserves_file(void) {
    assert(orbit_file_write(TEST_PATH, "original") == true);

    // NULL content is a programming error, not an instruction to truncate.
    assert(orbit_file_write(TEST_PATH, NULL) == false);

    // A NULL path is refused without touching anything.
    assert(orbit_file_write(NULL, "x") == false);

    // A path in a directory that does not exist cannot be opened.
    assert(orbit_file_write("no_such_dir_xyz/out.bin", "x") == false);

    char buf[64];
    long n = slurp(TEST_PATH, buf, sizeof(buf));
    assert(n == 8);
    assert(strcmp(buf, "original") == 0);

    remove(TEST_PATH);
}

// 4. Writing an empty file is a legitimate request, not a failure, and not
//    something the write primitive should second-guess. Deciding that an empty
//    result is unacceptable belongs to the caller: that is why `orbit fmt`
//    refuses to write an empty result over a non-blank source.
static void test_empty_write_is_legitimate(void) {
    assert(orbit_file_write(TEST_PATH, "x") == true);
    assert(orbit_file_write(TEST_PATH, "") == true);

    FILE* f = orbit_fopen(TEST_PATH, "rb");
    assert(f != NULL);
    int c = fgetc(f);
    fclose(f);
    assert(c == EOF);   // the file exists and is empty

    remove(TEST_PATH);
}

// 5. The read side reports a missing file as an error rather than as content.
static void test_read_missing_file(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    assert(arena != NULL);

    OrbitResult r = orbit_file_read(arena, "definitely_not_here_xyz.bin");
    assert(r.ok == false);
    assert(r.error_msg != NULL);

    orbit_arena_destroy(arena);
}

// 6. Read back what we wrote, through the same API a compiler would use.
static void test_read_write_interop(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    assert(arena != NULL);

    const char* text = "fn main() -> int {\n    return 0\n}\n";
    assert(orbit_file_write(TEST_PATH, text) == true);

    OrbitResult r = orbit_file_read(arena, TEST_PATH);
    assert(r.ok == true);
    assert(r.value != NULL);
    assert(strcmp((const char*)r.value, text) == 0);

    /* The pair is text-only by construction: both sides are NUL-terminated C
     * strings, so a payload containing a NUL is truncated at that byte on the
     * way out and arrives short. Pinned here so the behaviour is a documented
     * property rather than a surprise; a caller that needs binary has no API
     * today and must say so rather than discover it at runtime. */
    assert(orbit_file_write(TEST_PATH, "a\0b") == true);
    r = orbit_file_read(arena, TEST_PATH);
    assert(r.ok == true);
    assert(strcmp((const char*)r.value, "a") == 0);

    remove(TEST_PATH);
    orbit_arena_destroy(arena);
}

int main(void) {
    printf("=== Orbit runtime file-IO tests ===\n");
    RUN_TEST(test_write_read_roundtrip);
    RUN_TEST(test_large_content);
    RUN_TEST(test_refused_write_preserves_file);
    RUN_TEST(test_empty_write_is_legitimate);
    RUN_TEST(test_read_missing_file);
    RUN_TEST(test_read_write_interop);
    printf("All 6 Orbit runtime file-IO tests PASSED successfully!\n");
    return 0;
}
