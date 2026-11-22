/**
 * @file  test_ledger_percentiles.c
 * @brief Per-route percentiles, estimated inside their bucket: ordering, the
 *        clamps, and the JSON keys, so /_ledger/data reports distribution
 *        without inventing it.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "crt_compat.h"
#include <stdint.h>

#include "runtime.h"
#include "performance.h"

/* ledger.c is a static-header TU (ORBIT_LEDGER_C guard); pull it in. */
#define ORBIT_LEDGER_C
#include "ledger.c"

static uint64_t US(uint64_t us) { return us * 2500ULL; }

int main(void) {
    /* 1 us, 2 us, 4 us, and a 10 ms outlier, all on one route. */
    int slot = orbit_ledger_enter("GET", "/notes/:id");
    assert(slot >= 0);
    /* No arena here: the test drives the percentile buckets, and the memory
     * columns are covered by test_arena_telemetry.c. */
    orbit_ledger_exit(slot, US(1), NULL);
    orbit_ledger_exit(slot, US(2), NULL);
    orbit_ledger_exit(slot, US(4), NULL);
    orbit_ledger_exit(slot, US(10000), NULL);
    

    const OrbitLedgerEntry* e = &orbit_ledger_table[slot];
    assert(e->count == 4);
    assert(e->total_cycles == US(1 + 2 + 4 + 10000));

    /* 1 us is 2500 cycles, so the samples land at buckets 11, 12, 13 and 24
     * (2500, 5000, 10000, 25000000 cycles) rather than at 0, 1 and 2. */
    assert(e->lat[11] == 1);
    assert(e->lat[12] == 1);
    assert(e->lat[13] == 1);
    assert(e->lat[24] == 1);

    uint64_t p50 = orbit_ledger_percentile_us(e, 500);
    uint64_t p95 = orbit_ledger_percentile_us(e, 950);
    uint64_t p99 = orbit_ledger_percentile_us(e, 990);

    /* p50 targets ceil(4*0.5)=2 -> the 2 us sample, alone in bucket 12. A bucket
     * holding one request answers that request, not the 8192-cycle edge (3 us)
     * above it. */
    assert(p50 == 2);
    /* p95 and p99 target 4 -> the outlier's bucket, whose one sample is
     * 25,000,000 cycles: 10000 us measured, where 2^25 = 13421 us was the edge
     * the boundary rule reported. */
    assert(p95 == 10000);
    assert(p99 == 10000);
    assert(p50 <= p95);
    assert(p95 <= p99);

    /* One bucket, one hundred requests spread 80 cycles apart from 8192 to
     * 16112 -- all inside bucket 13, whose edges are 8192 and 16384. The mean is
     * the middle of the spread and the rank decides where inside it the answer
     * sits, so the table no longer reports the same edge for every one of them. */
    int bulk = orbit_ledger_enter("GET", "/notes/bulk");
    assert(bulk >= 0);
    for (uint64_t k = 0; k < 100; k++) {
        orbit_ledger_exit(bulk, 8192ULL + k * 80ULL, NULL);
    }
    const OrbitLedgerEntry* b = &orbit_ledger_table[bulk];
    assert(b->count == 100);
    assert(b->lat[13] == 100);
    uint64_t bulk_p5 = orbit_ledger_percentile_us(b, 50);
    uint64_t bulk_p50 = orbit_ledger_percentile_us(b, 500);
    uint64_t bulk_p99 = orbit_ledger_percentile_us(b, 990);
    /* The 50th of these is 12112 cycles = 4 us; one rank step (81 cycles) of
     * slop is the price of dividing the width by the count, not the product. */
    assert(bulk_p50 == 4);
    /* The 5th wants to leave the bucket below and the 99th above: the clamp is
     * what keeps a percentile between the edges that bound it. */
    assert(bulk_p5 == 3);
    assert(bulk_p99 == 6);
    assert(bulk_p5 <= bulk_p50);
    assert(bulk_p50 <= bulk_p99);

    /* An unentered route has no distribution to report. */
    const OrbitLedgerEntry empty = {0};
    assert(orbit_ledger_percentile_us(&empty, 500) == 0);

    /* The JSON endpoint carries the percentiles and says they are boundaries. */
    OrbitArena* arena = orbit_arena_create(65536);
    const char* json = orbit_ledger_json(arena);
    assert(strstr(json, "\"p50_us\":2") != NULL);
    assert(strstr(json, "\"p95_us\":10000") != NULL);
    assert(strstr(json, "\"p99_us\":10000") != NULL);
    assert(strstr(json, "log2-bucket estimates") != NULL);

    const char* html = orbit_ledger_html(arena);
    assert(strstr(html, "p50 µs") != NULL);
    assert(strstr(html, "log2-bucket estimates") != NULL);

    /* ORBIT_LEDGER_OUT: the same JSON, readable by a tool that is not an HTTP
     * client. That is the whole point of the dump -- a static analyser can read
     * a file, and cannot usefully start a server and drive traffic through it.
     *
     * Registered through orbit_ledger_enable_file_dump() and then written by an
     * explicit call to the same hook atexit would invoke, because the test still
     * has assertions left to run and cannot wait for exit(). Writing the file by
     * hand here would pass even with the hook deleted. */
    {
        /* Relative, like the other runtime tests ("note.txt", "a.txt"). The
         * path is opened with fopen at the end of this block, and "/tmp" does
         * not exist on the Windows runner, so the hook wrote a file nothing
         * could open and the assertion below failed on a machine where every
         * line above it had passed. */
        const char* path = "orbit_test_ledger_dump.json";
        remove(path);
        orbit_env_set("ORBIT_LEDGER_OUT", path);
        orbit_ledger_enable_file_dump();
        assert(orbit_ledger_out_path[0] != '\0');
        assert(strcmp(orbit_ledger_out_path, path) == 0);

        orbit_ledger_dump_at_exit();

        FILE* f = fopen(path, "rb");
        assert(f != NULL);            /* the hook wrote it */
        char buf[4096];
        size_t got = fread(buf, 1, sizeof(buf) - 1, f);
        buf[got] = '\0';
        fclose(f);
        assert(strstr(buf, "\"routes\"") != NULL);
        assert(strstr(buf, "/notes/:id") != NULL);
        assert(strstr(buf, "\"p99_us\"") != NULL);
        /* Atomic: the temporary is gone, only the final name remains. */
        char tmp[512];
        snprintf(tmp, sizeof(tmp), "%s.tmp", path);
        assert(fopen(tmp, "rb") == NULL);
        remove(path);

        /* Opt-in: an unset variable must leave the hook inert. */
        orbit_env_unset("ORBIT_LEDGER_OUT");
        orbit_ledger_out_path[0] = '\0';
        orbit_ledger_dump_at_exit();
        f = fopen(path, "rb");
        assert(f == NULL);
        if (f) fclose(f);
    }

    orbit_arena_destroy(arena);
    printf("test_ledger_percentiles: PASSED\n");
    return 0;
}