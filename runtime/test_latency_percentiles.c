/**
 * @file  test_latency_percentiles.c
 * @brief The latency histogram answers a bucket edge at every magnitude:
 *        100 us steps to 100 ms, then buckets of doubling width, and only the
 *        last of those falls back to the longest request.
 */

#include <stdio.h>
#include <assert.h>
#include "crt_compat.h"
#include <stdint.h>

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

    /* p50 with 3 samples targets ceil(3*0.5) = 2: the second bucket, whose upper
     * boundary is 1300 us (bucket 12 spans 1200-1300). */
    assert(p50 == 1300);

    /* p95 and p99 target ceil(3*0.95) = 3: the 200-400 ms bucket. The answer is
     * that bucket's upper edge -- 400 ms -- and it does not come from
     * max_cycles: recording straight into the histogram leaves max_cycles at 0,
     * so a fabricated value would show up as 0 here. Under the single overflow
     * bucket this case answered max_cycles, which is a different quantity than a
     * percentile boundary. */
    assert(p95 == 400000);
    assert(p99 == 400000);

    /* 160 s is ten doublings above 100 ms, so it lands in the eleventh log
     * slot. Naming the slot is what pins the mapping; the percentile itself
     * would need a larger sample count to reach it. */
    orbit_perf_record_latency(160000ULL * 1000ULL * 2500ULL);
    assert(orbit_perf_lat_hist[ORBIT_PERF_LAT_BUCKETS + 10] == 1);
    /* The 200-400 ms bucket holds only the 300 ms sample: 160 s did not share
     * it, which is the collapse the doubling removed. */
    assert(orbit_perf_lat_hist[ORBIT_PERF_LAT_BUCKETS + 1] == 1);

    /* The longest request does not move a percentile that lands in a bucket
     * with an edge of its own. */
    orbit_perf_stats.max_cycles = 160000ULL * 1000ULL * 2500ULL;

    /* Four samples now: 400 us, 1.2 ms, 300 ms, 160 s. p95 targets
     * ceil(4*0.95) = 4, the eleventh log slot, whose edge is 100 ms doubled
     * eleven times -- 204.8 s. It is the bucket's boundary, not max_cycles,
     * which is set to a different number on purpose. */
    uint64_t p95_4 = orbit_perf_percentile_us(4, 950);
    assert(p95_4 == 100000ULL << 11);

    /* p50 of the same four still targets the second sample, and p99 answers the
     * same edge as p95: both want the fourth sample. */
    uint64_t p50_4 = orbit_perf_percentile_us(4, 500);
    assert(p50_4 == 1300);
    assert(orbit_perf_percentile_us(4, 990) == p95_4);

    /* Ordering holds across the change of scale, and no percentile is finer
     * than its bucket. */
    assert(p50 <= p50_4);
    assert(p50_4 <= p95_4);
    assert(p50 % 100 == 0);
    assert(p95_4 % 100000 == 0);

    /* Only the clamp -- the last slot, for a width that starts at 100 ms
     * doubled nineteen times, about 14.6 h -- is answered from the longest
     * request, because it has no upper edge of its own. */
    orbit_perf_record_latency(200000000ULL * 2500ULL);    /* 200 s: same edge as 160 s */
    assert(orbit_perf_lat_hist[ORBIT_PERF_LAT_SLOTS - 1] == 0);
    orbit_perf_record_latency(100000000000ULL * 2500ULL); /* 100000 s: the clamp */
    assert(orbit_perf_lat_hist[ORBIT_PERF_LAT_SLOTS - 1] == 1);
    /* Six samples: p99 targets ceil(6*0.99) = 6, the clamp, so this one really
     * is answered from max_cycles -- the 160 s set above. */
    assert(orbit_perf_percentile_us(6, 990) == 160000000ULL);

    /* Recording through the real request path keeps the buckets populated. */
    orbit_perf_start_request();
    orbit_perf_end_request(orbit_rdtsc());
    assert(orbit_perf_stats.request_count == 1);
    assert(orbit_perf_lat_hist[0] == 1);

    printf("test_latency_percentiles: PASSED\n");
    return 0;
}
