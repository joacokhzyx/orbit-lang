#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>

#include "runtime.h"

#ifdef _WIN32
  #include <windows.h>
  static double get_time_seconds(void) {
      LARGE_INTEGER freq, count;
      QueryPerformanceFrequency(&freq);
      QueryPerformanceCounter(&count);
      return (double)count.QuadPart / (double)freq.QuadPart;
  }
#else
  #include <sys/time.h>
  static double get_time_seconds(void) {
      struct timeval tv;
      gettimeofday(&tv, NULL);
      return (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
  }
#endif

// A. Many small allocations
static void bench_small_allocs(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    double start = get_time_seconds();
    
    int iterations = 1000000;
    for (int i = 0; i < iterations; i++) {
        void* p = orbit_alloc(arena, 16);
        (void)p;
    }
    
    double end = get_time_seconds();
    double duration = end - start;
    printf("A. Small Allocations (16B):\n");
    printf("   - Total allocations: %d\n", iterations);
    printf("   - Duration: %.4f seconds\n", duration);
    printf("   - Rate: %.2f M allocs/sec\n", (iterations / duration) / 1000000.0);
    printf("   - Avg time per alloc: %.2f ns\n", (duration / iterations) * 1000000000.0);
    
    orbit_arena_destroy(arena);
}

// B. Mixture of sizes
static void bench_mixed_allocs(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    double start = get_time_seconds();
    
    int iterations = 500000;
    size_t sizes[] = {16, 64, 256, 4096};
    for (int i = 0; i < iterations; i++) {
        size_t size = sizes[i % 4];
        void* p = orbit_alloc(arena, size);
        (void)p;
    }
    
    double end = get_time_seconds();
    double duration = end - start;
    printf("B. Mixed Allocations (16B - 4KB):\n");
    printf("   - Total allocations: %d\n", iterations);
    printf("   - Duration: %.4f seconds\n", duration);
    printf("   - Rate: %.2f M allocs/sec\n", (iterations / duration) / 1000000.0);
    
    orbit_arena_destroy(arena);
}

// C. Typical request workload simulation
static void bench_request_sim(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    double start = get_time_seconds();
    
    int requests = 100000;
    for (int r = 0; r < requests; r++) {
        // Allocate request headers, body, views, etc.
        for (int i = 0; i < 20; i++) {
            void* p1 = orbit_alloc(arena, 32);
            void* p2 = orbit_alloc(arena, 128);
            (void)p1; (void)p2;
        }
        orbit_arena_reset(arena);
    }
    
    double end = get_time_seconds();
    double duration = end - start;
    printf("C. Request Workload Simulation (20 allocs/req + reset):\n");
    printf("   - Total requests processed: %d\n", requests);
    printf("   - Duration: %.4f seconds\n", duration);
    printf("   - Rate: %.2f requests/sec\n", requests / duration);
    printf("   - Avg request latency: %.2f us\n", (duration / requests) * 1000000.0);
    
    orbit_arena_destroy(arena);
}

// D. Occasional large allocations
static void bench_occasional_large(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    double start = get_time_seconds();
    
    int iterations = 10000;
    for (int i = 0; i < iterations; i++) {
        // 99 small allocs, 1 large alloc
        for (int j = 0; j < 99; j++) {
            void* p = orbit_alloc(arena, 32);
            (void)p;
        }
        void* large = orbit_alloc(arena, 1 * 1024 * 1024); // 1 MB large allocation
        (void)large;
        
        orbit_arena_reset(arena);
    }
    
    double end = get_time_seconds();
    double duration = end - start;
    printf("D. Occasional Large Allocations (1MB + 99 small allocs + reset):\n");
    printf("   - Total cycles: %d\n", iterations);
    printf("   - Duration: %.4f seconds\n", duration);
    printf("   - Rate: %.2f cycles/sec\n", iterations / duration);
    
    orbit_arena_destroy(arena);
}

// E. Thousands of resets
static void bench_thousands_of_resets(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    double start = get_time_seconds();
    
    int resets = 1000000;
    for (int i = 0; i < resets; i++) {
        orbit_arena_reset(arena);
    }
    
    double end = get_time_seconds();
    double duration = end - start;
    printf("E. Reset Overhead (O(1) logical resets):\n");
    printf("   - Total resets: %d\n", resets);
    printf("   - Duration: %.4f seconds\n", duration);
    printf("   - Rate: %.2f M resets/sec\n", (resets / duration) / 1000000.0);
    printf("   - Avg time per reset: %.2f ns\n", (duration / resets) * 1000000000.0);
    
    orbit_arena_destroy(arena);
}

// G. String interning
static void bench_string_interning(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    double start = get_time_seconds();
    
    int iterations = 500000;
    for (int i = 0; i < iterations; i++) {
        const char* s = orbit_string_intern(arena, "bench_string_intern_key");
        (void)s;
    }
    
    double end = get_time_seconds();
    double duration = end - start;
    printf("G. String Interning (hot path hit):\n");
    printf("   - Total interns: %d\n", iterations);
    printf("   - Duration: %.4f seconds\n", duration);
    printf("   - Rate: %.2f M interns/sec\n", (iterations / duration) / 1000000.0);
    
    orbit_arena_destroy(arena);
}

int main(void) {
    printf("=======================================================================\n");
    printf("                  ORBIT ARENA HIGH-SPEED BENCHMARK                     \n");
    printf("=======================================================================\n");
    
    bench_small_allocs();
    printf("\n");
    bench_mixed_allocs();
    printf("\n");
    bench_request_sim();
    printf("\n");
    bench_occasional_large();
    printf("\n");
    bench_thousands_of_resets();
    printf("\n");
    bench_string_interning();
    printf("\n");
    printf("=======================================================================\n");
    return 0;
}
