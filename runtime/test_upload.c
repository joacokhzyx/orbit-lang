/**
 * @file  test_upload.c
 * @brief Multipart upload save: boundary parse, field match, sanitized name.
 *
 * Pins the behaviour KNOWN_LIMITATIONS describes as absent: a real
 * multipart/form-data body now lands on disk, and the path handed back
 * names the saved file.
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

static const char* HDR_BOUNDARY = "----orbitest123";

static OrbitRequest* parse_multipart(OrbitArena* arena, const char* field_value) {
    char buf[1024];
    int n = snprintf(buf, sizeof(buf),
        "POST /upload HTTP/1.1\r\n"
        "Content-Type: multipart/form-data; boundary=%s\r\n"
        "Content-Length: %zu\r\n"
        "\r\n", HDR_BOUNDARY, strlen(field_value));
    strcat(buf, field_value);

    OrbitRequest* r = NULL;
    size_t c = orbit_http_parse_request_ex(arena, buf, strlen(buf), &r, NULL);
    assert(c > 0);
    return r;
}

static char* part_headers(char* out, size_t cap, const char* name, const char* filename) {
    if (filename) {
        snprintf(out, cap,
            "--%s\r\n"
            "Content-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\n"
            "\r\n", HDR_BOUNDARY, name, filename);
    } else {
        snprintf(out, cap,
            "--%s\r\n"
            "Content-Disposition: form-data; name=\"%s\"\r\n"
            "\r\n", HDR_BOUNDARY, name);
    }
    return out;
}

static char* part_end(char* out, size_t cap) {
    snprintf(out, cap, "\r\n--%s--\r\n", HDR_BOUNDARY);
    return out;
}

/* A multipart body with one file part lands on disk with its content. */
static void test_saves_file_part(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    char content[64] = "hello upload body\n";
    char hdr[512];
    char ending[256];
    char body[1024];
    strcpy(body, part_headers(hdr, sizeof(hdr), "file", "note.txt"));
    strcat(body, content);
    strcat(body, part_end(ending, sizeof(ending)));

    OrbitRequest* r = parse_multipart(arena, body);
    char path[512];
    snprintf(path, sizeof(path), "./note.txt");

    remove(path);
    const char* saved = orbit_file_upload_save(arena, r, "file", ".");
    assert(saved && *saved);

    FILE* f = orbit_fopen(saved, "rb");
    assert(f != NULL);
    char got[64];
    size_t n = fread(got, 1, sizeof(got) - 1, f);
    fclose(f);
    got[n] = '\0';
    assert(strcmp(got, content) == 0);

    orbit_arena_destroy(arena);
}

/* An absent field name means no file is saved. */
static void test_missing_field(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    char hdr[512];
    char ending[256];
    char body[1024];
    strcpy(body, part_headers(hdr, sizeof(hdr), "doc", "a.txt"));
    strcat(body, "data\n");
    strcat(body, part_end(ending, sizeof(ending)));
    OrbitRequest* r = parse_multipart(arena, body);
    const char* saved = orbit_file_upload_save(arena, r, "other", ".");
    assert(strcmp(saved, "") == 0);

    orbit_arena_destroy(arena);
}

int main(void) {
    printf("test_upload\n");
    RUN_TEST(test_saves_file_part);
    RUN_TEST(test_missing_field);
    return 0;
}
