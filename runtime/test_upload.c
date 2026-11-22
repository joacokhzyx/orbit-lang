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

/* fflush after the banner, and after PASSED, because that is what makes a crash
 * attributable. On Windows stdout is fully buffered when it is a pipe, not a
 * console, so an access violation loses every buffered line and the CI log
 * shows a bare "[ORBIT RUNTIME CRASH]" with no indication of which test died --
 * which is how a crash in the migrations test was read as a crash in whichever
 * test happened to be compiled last. The line is there to name the failure. */
#define RUN_TEST(name) \
    do { \
        printf("Running test: %s... ", #name); \
        fflush(stdout); \
        name(); \
        printf("PASSED\n"); \
        fflush(stdout); \
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

/* A traversal filename cannot escape the destination directory: the path
   is stripped to its base and only safe characters survive, so the saved
   file lands inside dest_dir. */
static void test_traversal_filename_stays_inside(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    char hdr[512];
    char ending[256];
    char body[1024];
    strcpy(body, part_headers(hdr, sizeof(hdr), "file", "../../etc/passwd"));
    strcat(body, "x");
    strcat(body, part_end(ending, sizeof(ending)));
    OrbitRequest* r = parse_multipart(arena, body);
    const char* saved = orbit_file_upload_save(arena, r, "file", ".");
    assert(saved && *saved);
    /* dest_dir is ".": the saved path must be ./<base> with no separators. */
    assert(saved[0] == '.' && saved[1] == '/');
    assert(strchr(saved + 2, '/') == NULL);
    assert(strchr(saved + 2, '\\') == NULL);
    remove(saved);

    orbit_arena_destroy(arena);
}

/* An empty part saves an empty file rather than failing or writing junk. */
static void test_empty_part_saves_empty_file(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    char hdr[512];
    char ending[256];
    char body[1024];
    strcpy(body, part_headers(hdr, sizeof(hdr), "file", "empty.txt"));
    strcat(body, part_end(ending, sizeof(ending)));
    OrbitRequest* r = parse_multipart(arena, body);
    const char* saved = orbit_file_upload_save(arena, r, "file", ".");
    assert(saved && *saved);
    FILE* f = orbit_fopen(saved, "rb");
    assert(f != NULL);
    assert(fgetc(f) == EOF);
    fclose(f);
    remove(saved);

    orbit_arena_destroy(arena);
}

/* A zero byte inside the part is content, not the end of it. The save path
 * walks the parsed body by length and writes a byte range, so the file keeps
 * the byte; a copy through strlen would write one byte and return a path that
 * names a truncated file. */
static void test_nul_byte_in_body_survives(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    const unsigned char content[5] = { 'a', 0, 'b', 'c', 'd' };
    char hdr[512];
    char ending[256];

    char body[1024];
    const char* pre = part_headers(hdr, sizeof(hdr), "file", "bin.dat");
    size_t n = strlen(pre);
    memcpy(body, pre, n);
    memcpy(body + n, content, sizeof(content));
    n += sizeof(content);
    const char* tail = part_end(ending, sizeof(ending));
    size_t tlen = strlen(tail);
    memcpy(body + n, tail, tlen);
    n += tlen;

    char head[512];
    int hlen = snprintf(head, sizeof(head),
        "POST /upload HTTP/1.1\r\n"
        "Content-Type: multipart/form-data; boundary=%s\r\n"
        "Content-Length: %zu\r\n"
        "\r\n", HDR_BOUNDARY, n);
    char raw[2048];
    memcpy(raw, head, (size_t)hlen);
    memcpy(raw + hlen, body, n);

    OrbitRequest* r = NULL;
    size_t c = orbit_http_parse_request_ex(arena, raw, (size_t)hlen + n, &r, NULL);
    assert(c > 0 && r != NULL);

    remove("./bin.dat");
    const char* saved = orbit_file_upload_save(arena, r, "file", ".");
    assert(saved && *saved);
    FILE* f = orbit_fopen(saved, "rb");
    assert(f != NULL);
    unsigned char got[16];
    size_t gn = fread(got, 1, sizeof(got), f);
    fclose(f);
    assert(gn == sizeof(content));
    assert(memcmp(got, content, sizeof(content)) == 0);
    remove(saved);
    orbit_arena_destroy(arena);
}

/* A zero byte in a part header is not representable in an orbit_string, so
 * the save refuses the part instead of sanitizing the value into a name the
 * sender did not choose. `a\0b.txt` used to land as `a_b.txt`: the byte
 * became '_' in the sanitized name and the path named a file the sender
 * never wrote. No file is created, and the answer is "". */
static void test_nul_in_filename_is_refused(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    static const unsigned char fname[7] = { 'a', 0, 'b', '.', 't', 'x', 't' };
    static const char pre[] =
        "Content-Disposition: form-data; name=\"file\"; filename=\"";
    static const char mid[] = "\"\r\n\r\npayload\n";
    size_t blen = strlen(HDR_BOUNDARY);

    char body[1024];
    size_t n = 0;
    memcpy(body + n, "--", 2);
    n += 2;
    memcpy(body + n, HDR_BOUNDARY, blen);
    n += blen;
    memcpy(body + n, "\r\n", 2);
    n += 2;
    memcpy(body + n, pre, sizeof(pre) - 1);
    n += sizeof(pre) - 1;
    memcpy(body + n, fname, sizeof(fname));
    n += sizeof(fname);
    memcpy(body + n, mid, sizeof(mid) - 1);
    n += sizeof(mid) - 1;
    memcpy(body + n, "\r\n--", 4);
    n += 4;
    memcpy(body + n, HDR_BOUNDARY, blen);
    n += blen;
    memcpy(body + n, "--\r\n", 4);
    n += 4;
    assert(n < sizeof(body));

    char raw[2048];
    int hlen = snprintf(raw, sizeof(raw),
        "POST /upload HTTP/1.1\r\n"
        "Content-Type: multipart/form-data; boundary=%s\r\n"
        "Content-Length: %zu\r\n"
        "\r\n", HDR_BOUNDARY, n);
    assert(hlen > 0 && (size_t)hlen + n <= sizeof(raw));
    memcpy(raw + hlen, body, n);

    OrbitRequest* r = NULL;
    size_t c = orbit_http_parse_request_ex(arena, raw, (size_t)hlen + n, &r, NULL);
    assert(c > 0 && r != NULL);

    /* Both names the old sanitizer could produce are absent beforehand, so
       either one appearing is the defect. */
    remove("./a_b.txt");
    remove("./a.txt");

    const char* saved = orbit_file_upload_save(arena, r, "file", ".");
    assert(strcmp(saved, "") == 0);
    FILE* f = orbit_fopen("./a_b.txt", "rb");
    assert(f == NULL);
    f = orbit_fopen("./a.txt", "rb");
    assert(f == NULL);

    orbit_arena_destroy(arena);
}

int main(void) {
    printf("test_upload\n");
    fflush(stdout); /* see RUN_TEST: a crash must name its test */
    RUN_TEST(test_saves_file_part);
    RUN_TEST(test_missing_field);
    RUN_TEST(test_traversal_filename_stays_inside);
    RUN_TEST(test_empty_part_saves_empty_file);
    RUN_TEST(test_nul_byte_in_body_survives);
    RUN_TEST(test_nul_in_filename_is_refused);
    return 0;
}
