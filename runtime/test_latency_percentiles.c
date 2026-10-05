/**
 * @file  test_latency_percentiles.c
 * @brief The latency histogram returns ordered bucket boundaries, 0 before
 *        any request, and reports the overflow bucket from max_cycles.
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

    /* 400 us, 1.2 ms, 300 ms. Buckets are 100 us wide. */
    orbit_perf_record_latency(400ULL * 2500ULL);    /* bucket 4  */
    orbit_perf_record_latency(1200ULL * 2500ULL);   /* bucket 12 */
    orbit_perf_record_latency(300ULL * 1000ULL * 2500ULL); /* overflow */

    uint64_t count = 3;
    uint64_t p50 = orbit_perf_percentile_us(count, 500);
    uint64_t p95 = orbit_perf_percentile_us(count, 950);
    uint64_t p99 = orbit_perf_percentile_us(count, 990);

/* p50 with 3 samples targets ceil(3*0.5) = 2: the second bucket, whose upper
     * boundary is 1300 us (bucket 12 spans 1200-1300). */
    assert(p50 == 1300);

    /* p95 and p99 both target ceil(3*0.95) = 3: the overflow bucket, which is
     * answered from max_cycles rather than a bucket edge. Only requests through
     * orbit_perf_end_request set that, so recording straight into the histogram
     * leaves it 0 and the percentile is 0, not a fabricated 100 ms. */
    assert(p95 == 0);
    assert(p99 == 0);

    /* Once the real path has run, max_cycles answers the overflow bucket and
     * the percentiles order. */
    orbit_perf_stats.max_cycles = 300ULL * 1000ULL * 2500ULL;
    p95 = orbit_perf_percentile_us(count, 950);
    p99 = orbit_perf_percentile_us(count, 990);
    assert(p95 == 300000);
    assert(p99 == 300000);
    assert(p50 <= p95);
    assert(p95 <= p99);
    /* No percentile is finer than its bucket. */
    assert(p50 % 100 == 0);

    /* Recording through the real request path keeps the buckets populated. */
    orbit_perf_start_request();
    orbit_perf_end_request(orbit_rdtsc());
    assert(orbit_perf_stats.request_count == 1);
    assert(orbit_perf_lat_hist[0] == 1);

    printf("test_latency_percentiles: PASSED\n");
    return 0;
}