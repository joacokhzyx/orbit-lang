/**
 * @file  test_crypto.c
 * @brief Constant-time equality and the HMAC it guards.
 *
 * orbit_ct_equal compares secrets (JWT signatures, role tokens). The tests pin
 * its answer on every length relation, and pin HMAC-SHA256 to RFC 4231 test
 * case 2 so a signature that verifies is a real one. Timing itself is a
 * property of the loop (no early exit) and is reviewed in crypto.c, not
 * measured here.
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
        fflush(stdout); \
        name(); \
        printf("PASSED\n"); \
        fflush(stdout); \
    } while (0)

static void test_ct_equal_answers(void) {
    assert(orbit_ct_equal("", ""));
    assert(orbit_ct_equal("abc", "abc"));
    assert(!orbit_ct_equal("abc", "abd"));
    assert(!orbit_ct_equal("abc", "xbc"));
    assert(!orbit_ct_equal("abc", "ab"));
    assert(!orbit_ct_equal("ab", "abc"));
    assert(!orbit_ct_equal("", "a"));
    assert(!orbit_ct_equal("a", ""));
    /* A trailing NUL padding must not make a shorter string equal. */
    assert(!orbit_ct_equal("abc", "abc\x01"));
    /* High bytes compare as bytes, not as signed chars. */
    assert(orbit_ct_equal("\xff\x80", "\xff\x80"));
    assert(!orbit_ct_equal("\xff\x80", "\x7f\x80"));
    assert(!orbit_ct_equal(NULL, "a"));
    assert(!orbit_ct_equal("a", NULL));
    assert(!orbit_ct_equal(NULL, NULL));
}

static void test_ct_equal_signatures(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    orbit_string good = orbit_hmac_sha256_base64url(arena, "k", "header.payload");
    orbit_string again = orbit_hmac_sha256_base64url(arena, "k", "header.payload");
    orbit_string other_key = orbit_hmac_sha256_base64url(arena, "K", "header.payload");
    orbit_string other_msg = orbit_hmac_sha256_base64url(arena, "k", "header.payloae");
    assert(strlen(good) == 43);
    assert(orbit_ct_equal(good, again));
    assert(!orbit_ct_equal(good, other_key));
    assert(!orbit_ct_equal(good, other_msg));
    /* One flipped bit in each position of the signature is caught. */
    char tweaked[64];
    for (size_t i = 0; i < strlen(good); i++) {
        memcpy(tweaked, good, strlen(good) + 1);
        tweaked[i] = (char)(tweaked[i] ^ 1);
        assert(!orbit_ct_equal(good, tweaked));
    }
    orbit_arena_destroy(arena);
}

/* RFC 4231 test case 2: key "Jefe", data "what do ya want for nothing?". */
static void test_hmac_known_answer(void) {
    uint8_t mac[32];
    const char* data = "what do ya want for nothing?";
    orbit_hmac_sha256((const uint8_t*)"Jefe", 4, (const uint8_t*)data, strlen(data), mac);
    const uint8_t want[32] = {
        0x5b,0xdc,0xc1,0x46,0xbf,0x60,0x75,0x4e,0x6a,0x04,0x24,0x26,0x08,0x95,0x75,0xc7,
        0x5a,0x00,0x3f,0x08,0x9d,0x27,0x39,0x83,0x9d,0xec,0x58,0xb9,0x64,0xec,0x38,0x43 };
    assert(memcmp(mac, want, 32) == 0);
}

int main(void) {
    printf("test_crypto\n");
    fflush(stdout);
    RUN_TEST(test_ct_equal_answers);
    RUN_TEST(test_ct_equal_signatures);
    RUN_TEST(test_hmac_known_answer);
    printf("All crypto tests passed\n");
    return 0;
}
