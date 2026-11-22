#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "runtime.h"

/* `orbit_stdout_write` sends bytes, and `orbit_stdout_binary` is what stops
 * the platform translating them. Windows text mode turns each "\n" into
 * "\r\n", so a header written as "\r\n" arrives as "\r\r\n" and no JSON-RPC
 * client parses it. The test redirects stdout to a file opened in text mode --
 * the platform default the server would inherit -- writes one framed header,
 * and reads the bytes back. It compares exactly, so the translation is the
 * only thing under test. The verdict goes to a duplicate of the original
 * descriptor, because stdout itself now points at the file. */

int main(void) {
    int failures = 0;
    const char* path = "test_stdout_bytes.bin";
    const char* header = "Header: 1\r\n\r\n{}";
    size_t want = strlen(header);
    char buf[64];
    FILE* report;
    FILE* back;
    size_t got;

#ifdef _WIN32
    int saved = _dup(_fileno(stdout));
#else
    int saved = dup(fileno(stdout));
#endif
    if (saved < 0) {
        fprintf(stderr, "FAILED cannot duplicate stdout\n");
        return 1;
    }
#ifdef _WIN32
    report = _fdopen(saved, "w");
#else
    report = fdopen(saved, "w");
#endif
    if (report == NULL) {
        fprintf(stderr, "FAILED cannot reopen the duplicate\n");
        return 1;
    }
    if (freopen(path, "w", stdout) == NULL) {
        fprintf(stderr, "FAILED cannot redirect stdout\n");
        return 1;
    }
    if (!orbit_stdout_binary()) {
        fprintf(stderr, "FAILED orbit_stdout_binary answered false\n");
        failures++;
    }
    if (!orbit_stdout_write(header)) {
        fprintf(stderr, "FAILED orbit_stdout_write answered false\n");
        failures++;
    }
    fclose(stdout);

    back = fopen(path, "rb");
    if (back == NULL) {
        printf("FAILED cannot read back %s\n", path);
        return 1;
    }
    got = fread(buf, 1, sizeof buf, back);
    fclose(back);
    if (got != want || memcmp(buf, header, want) != 0) {
        fprintf(report, "FAILED bytes: want %zu, got %zu\n", want, got);
        failures++;
    }

    if (failures == 0) {
        fprintf(report, "test_stdout: all cases pass\n");
    }
    fflush(report);
    return failures == 0 ? 0 : 1;
}
