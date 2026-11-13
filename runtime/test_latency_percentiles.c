/**
 * @file  test_latency_percentiles.c
 * @brief A percentile is estimated inside its bucket, anchored on the mean the
 *        bucket recorded: 100 us steps to 100 ms, then buckets of doubling
 *        width, and only the last of those falls back to the longest request.
 */

#include <stdio.h>
#include <assert.h>
#include "crt_compat.h"
#include <stdint.h>
#include <string.h>

#include "runtime.h"
#include "performance.h"

int main(void) {
    /* Nothing recorded: every percentile is 0, not garbage. */
    assert(orbit_perf_percentile_us(orbit_perf_stats.request_count, 500) == 0);

    /* 400 us, 1.2 ms, 300 ms. The linear buckets are 100 us wide. */
    orbit_perf_record_latency(400ULL * 2500ULL);    /* bucket 4  */
    orbit_perf_record_latency(1200ULL * 2500ULL);   /* bucket 12 */
    orbit_perf_record_latency(300ULL * 1000ULL * 2500ULL); /* 200-400 ms */

    uint64_t count = 3;
    uint64_t p50 = orbit_perf_percentile_us(count, 500);
    uint64_t p95 = orbit_perf_percentile_us(count, 950);
    uint64_t p99 = orbit_perf_percentile_us(count, 990);

    /* p50 with 3 samples targets ceil(3*0.5) = 2: the second sample, 1.2 ms, and
     * the bucket that holds it holds nothing else. The answer is the sample, not
     * the 1300 us the upper edge of bucket 12 used to say. */
    assert(p50 == 1200);

    /* p95 and p99 target ceil(3*0.95) = 3: the 200-400 ms bucket, whose one
     * sample is 300 ms. A 300 ms p99 reporting 400 ms -- the top of the bucket
     * that holds it -- was the limitation this removes. max_cycles stays 0 here
     * because recording goes straight into the histogram, so the value cannot
     * have come from the longest request. */
    assert(p95 == 300000);
    assert(p99 == 300000);

    /* 160 s is ten doublings above 100 ms, so it lands in the eleventh log
     * slot, and the 300 ms sample did not share a bucket with it -- the
     * collapse the doubling half removed. */
    orbit_perf_record_latency(160000ULL * 1000ULL * 2500ULL);
    assert(orbit_perf_lat_hist[ORBIT_PERF_LAT_BUCKETS + 10] == 1);
    assert(orbit_perf_lat_hist[ORBIT_PERF_LAT_BUCKETS + 1] == 1);

    /* The longest request does not move a percentile that lands in a bucket
     * with edges of its own. */
    orbit_perf_stats.max_cycles = 160000ULL * 1000ULL * 2500ULL;

    /* Four samples now: 400 us, 1.2 ms, 300 ms, 160 s. p95 targets
     * ceil(4*0.95) = 4, the eleventh log slot, which holds only the 160 s
     * sample: it answers 160 s, inside the 102.4-204.8 s bucket whose edge used
     * to be the answer. */
    uint64_t p95_4 = orbit_perf_percentile_us(4, 950);
    assert(p95_4 == 160000000ULL);

    /* p50 of the same four still targets the second sample, and p99 wants the
     * same fourth one as p95. */
    uint64_t p50_4 = orbit_perf_percentile_us(4, 500);
    assert(p50_4 == 1200);
    assert(orbit_perf_percentile_us(4, 990) == p95_4);

    /* Ordering holds across the change of scale. */
    assert(p50 <= p50_4);
    assert(p50_4 <= p95_4);

    /* One bucket, one hundred samples spread 2 ms apart from 200 ms to 398 ms.
     * The mean is the middle of the spread, so the rank decides where inside the
     * bucket the answer sits -- no edge is claimed, and no answer leaves the
     * bucket. */
    memset(orbit_perf_lat_hist, 0, sizeof(orbit_perf_lat_hist));
    memset(orbit_perf_lat_sum_us, 0, sizeof(orbit_perf_lat_sum_us));
    for (uint64_t k = 0; k < 100; k++) {
        orbit_perf_record_latency((200000ULL + k * 2000ULL) * 2500ULL);
    }
    uint64_t p50_100 = orbit_perf_percentile_us(100, 500);
    uint64_t p99_100 = orbit_perf_percentile_us(100, 990);
    uint64_t p5_100 = orbit_perf_percentile_us(100, 50);
    assert(orbit_perf_lat_hist[ORBIT_PERF_LAT_BUCKETS + 1] == 100);
    /* The 50th of these is 298 ms. One rank step (2 ms) of slop is the price of
     * dividing the bucket width by the count instead of the product. */
    assert(p50_100 >= 296000 && p50_100 <= 299000);
    /* The 99th is 396 ms, and the 5th is 208 ms: both ranks want to leave the
     * bucket, and the clamp is what keeps a percentile inside it. */
    assert(p99_100 == 400000);
    assert(p5_100 == 200000);
    assert(p5_100 <= p50_100);
    assert(p50_100 <= p99_100);

    /* Only the clamp -- the last slot, for a width that starts at 100 ms
     * doubled nineteen times, about 14.6 h -- is answered from the longest
     * request, because it has no upper edge of its own. */
    memset(orbit_perf_lat_hist, 0, sizeof(orbit_perf_lat_hist));
    memset(orbit_perf_lat_sum_us, 0, sizeof(orbit_perf_lat_sum_us));
    orbit_perf_record_latency(100000000000ULL * 2500ULL); /* 100000 s: the clamp */
    assert(orbit_perf_lat_hist[ORBIT_PERF_LAT_SLOTS - 1] == 1);
    /* max_cycles is what the clamp answers from, so name it instead of relying
     * on the value a previous case left there. */
    orbit_perf_stats.max_cycles = 100000000ULL * 2500ULL;
    assert(orbit_perf_percentile_us(1, 990) == 100000000ULL);

    /* Recording through the real request path populates both halves of the
     * histogram. A single request is the one case where the bucket's mean is the
     * sample itself, so the percentile is its own length, whatever bucket the
     * machine put it in. */
    memset(orbit_perf_lat_hist, 0, sizeof(orbit_perf_lat_hist));
    memset(orbit_perf_lat_sum_us, 0, sizeof(orbit_perf_lat_sum_us));
    orbit_perf_stats.request_count = 0;
    orbit_perf_start_request();
    orbit_perf_end_request(orbit_rdtsc());
    assert(orbit_perf_stats.request_count == 1);
    int filled = -1;
    uint64_t filled_us = 0;
    for (int i = 0; i < ORBIT_PERF_LAT_SLOTS; i++) {
        if (orbit_perf_lat_hist[i] != 0) {
            assert(filled == -1);
            filled = i;
            filled_us = orbit_perf_lat_sum_us[i];
        }
    }
    assert(filled >= 0);
    assert(orbit_perf_percentile_us(1, 500) == filled_us);

    printf("test_latency_percentiles: PASSED\n");
    return 0;
}
