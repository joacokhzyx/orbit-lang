/**
 * @file  thread_pool.c
 * @brief Fixed-size thread pool for concurrent HTTP request handling.
 *
 * Workers pull tasks from a lock-free ring queue.  Each worker owns an
 * OrbitArena from the arena pool; the arena is reset between requests.
 * Pool size defaults to `ORBIT_WORKER_THREADS` (env) or hardware_concurrency.
 */
#ifndef ORBIT_THREAD_POOL_H
#define ORBIT_THREAD_POOL_H

#include "socket_compat.h"

// ── Platform detection ────────────────────────────────────────────────
#ifdef _WIN32
  #include <windows.h>
  #include <process.h>
  typedef HANDLE orbit_thread_t;
  typedef unsigned (__stdcall *orbit_thread_fn)(void*);
  #define ORBIT_THREAD_CREATE(t, fn, arg) \
      ((t) = (HANDLE)_beginthreadex(NULL, 0, fn, arg, 0, NULL))
  #define ORBIT_THREAD_JOIN(t) \
      WaitForSingleObject((t), INFINITE); CloseHandle(t)
  
  static inline int orbit_cpu_count(void) {
      SYSTEM_INFO si;
      GetSystemInfo(&si);
      return (int)si.dwNumberOfProcessors;
  }
  #define ORBIT_CPU_COUNT() orbit_cpu_count()
#else
  // Linux / macOS
  #include <pthread.h>
  typedef pthread_t orbit_thread_t;
  typedef void* (*orbit_thread_fn)(void*);
  #define ORBIT_THREAD_CREATE(t, fn, arg) \
      pthread_create(&(t), NULL, (void*(*)(void*))(fn), arg)
  #define ORBIT_THREAD_JOIN(t) \
      pthread_join(t, NULL)
  
  #ifdef __APPLE__
    #include <sys/sysctl.h>
    static inline int orbit_cpu_count(void) {
        int n = 1;
        size_t s = sizeof(n);
        sysctlbyname("hw.logicalcpu", &n, &s, NULL, 0);
        return n;
    }
    #define ORBIT_CPU_COUNT() orbit_cpu_count()
  #else
    #include <unistd.h>
    #define ORBIT_CPU_COUNT() ((int)sysconf(_SC_NPROCESSORS_ONLN))
  #endif
#endif

// ── Contexto por thread ───────────────────────────────────────────────
typedef struct {
    orbit_socket_t server_sock;  // Socket compartido
    int thread_id;
    int port;
} OrbitWorkerCtx;

#endif // ORBIT_THREAD_POOL_H
