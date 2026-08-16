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

// ── Acceptor → Worker dispatch (lock-free SPSC rings) ─────────────────
// The listen socket is owned by exactly one acceptor thread.  Each worker
// owns a private single-producer/single-consumer ring of freshly accepted
// sockets plus a loopback UDP wake socket.  The acceptor pushes a socket
// and fires the matching worker's wake socket; the worker adopts queued
// sockets on every select round.  No locks and no shared accept races.

#define ORBIT_ACCEPT_Q_CAP 256

typedef struct {
    orbit_socket_t slots[ORBIT_ACCEPT_Q_CAP];
    unsigned int head;   /* consumer index (worker, exclusively) */
    unsigned int tail;   /* producer index (acceptor, exclusively) */
} OrbitAcceptQueue;

static inline void orbit_accept_q_init(OrbitAcceptQueue* q) {
    q->head = 0;
    q->tail = 0;
}

/* Single producer: the acceptor. Returns 0 when the ring is full. */
static inline int orbit_accept_q_push(OrbitAcceptQueue* q, orbit_socket_t s) {
    unsigned int t = q->tail;
    unsigned int next = (t + 1) % ORBIT_ACCEPT_Q_CAP;
    if (next == __atomic_load_n(&q->head, __ATOMIC_ACQUIRE)) return 0;
    q->slots[t] = s;
    __atomic_store_n(&q->tail, next, __ATOMIC_RELEASE);
    return 1;
}

/* Single consumer: the owning worker. Returns 0 when empty. */
static inline int orbit_accept_q_pop(OrbitAcceptQueue* q, orbit_socket_t* out) {
    unsigned int h = q->head;
    if (h == __atomic_load_n(&q->tail, __ATOMIC_ACQUIRE)) return 0;
    *out = q->slots[h];
    __atomic_store_n(&q->head, (h + 1) % ORBIT_ACCEPT_Q_CAP, __ATOMIC_RELEASE);
    return 1;
}

/* Loopback UDP wake socket pair (works identically on Windows and POSIX). */
static inline int orbit_wake_recv_create(orbit_socket_t* recv_out, struct sockaddr_in* addr_out) {
    orbit_socket_t r = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (r == ORBIT_INVALID_SOCKET) return 0;
#ifdef _WIN32
    u_long mode = 1;
    ioctlsocket(r, FIONBIO, &mode);
#else
    int flags = fcntl(r, F_GETFL, 0);
    fcntl(r, F_SETFL, flags | O_NONBLOCK);
#endif
    struct sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = 0;
    if (bind(r, (struct sockaddr*)&a, sizeof(a)) == ORBIT_SOCKET_ERROR) {
        orbit_socket_close(r);
        return 0;
    }
    int len = (int)sizeof(*addr_out);
    if (getsockname(r, (struct sockaddr*)addr_out, &len) == ORBIT_SOCKET_ERROR) {
        orbit_socket_close(r);
        return 0;
    }
    *recv_out = r;
    return 1;
}

static inline void orbit_wake_send(orbit_socket_t send_sock, const struct sockaddr_in* to) {
    const char c = 'W';
    (void)sendto(send_sock, &c, 1, 0, (const struct sockaddr*)to, sizeof(*to));
}

static inline void orbit_wake_drain(orbit_socket_t recv_sock) {
    char buf[64];
    for (;;) {
        int n = recvfrom(recv_sock, buf, (int)sizeof(buf), 0, NULL, NULL);
        if (n <= 0) break;
    }
}

// ── Contexto por thread ───────────────────────────────────────────────
typedef struct {
    OrbitAcceptQueue q;         // SPSC ring: acceptor → this worker
    orbit_socket_t wake_recv;   // UDP wake socket selected by the worker
    int thread_id;
    int port;
} OrbitWorkerCtx;

typedef struct {
    orbit_socket_t server_sock;
    orbit_socket_t wake_send;          // unconnected UDP socket for sendto
    OrbitAcceptQueue* queues[64];      // one queue per worker
    struct sockaddr_in wake_addr[64];  // per-worker wake addresses
    int num_workers;
} OrbitAcceptorCtx;

#ifdef _WIN32
static unsigned __stdcall orbit_acceptor_loop(void* arg) {
#else
static void* orbit_acceptor_loop(void* arg) {
#endif
    OrbitAcceptorCtx* ac = (OrbitAcceptorCtx*)arg;
    unsigned int rr = 0;
    while (1) {
        fd_set readfds;
        FD_ZERO(&readfds);
        FD_SET(ac->server_sock, &readfds);
        if (select((int)ac->server_sock + 1, &readfds, NULL, NULL, NULL) > 0 &&
            FD_ISSET(ac->server_sock, &readfds)) {
            for (;;) {
                orbit_socket_t s = accept(ac->server_sock, NULL, NULL);
                if (s == ORBIT_INVALID_SOCKET) break;
                int nodelay = 1;
                setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (char*)&nodelay, sizeof(nodelay));
                int sndbuf = 65536;
                int rcvbuf = 65536;
                setsockopt(s, SOL_SOCKET, SO_SNDBUF, (char*)&sndbuf, sizeof(sndbuf));
                setsockopt(s, SOL_SOCKET, SO_RCVBUF, (char*)&rcvbuf, sizeof(rcvbuf));
                /* Adaptive dispatch: pick the first worker (round-robin from
                 * the last used one) whose ring has room. */
                int pushed = 0;
                for (int k = 0; k < ac->num_workers; k++) {
                    int w = (int)((rr + (unsigned int)k) % (unsigned int)ac->num_workers);
                    if (orbit_accept_q_push(ac->queues[w], s)) {
                        orbit_wake_send(ac->wake_send, &ac->wake_addr[w]);
                        rr = (unsigned int)w;
                        pushed = 1;
                        break;
                    }
                }
                if (!pushed) orbit_socket_close(s);
                rr = (rr + 1) % (unsigned int)ac->num_workers;
            }
        }
    }
#ifdef _WIN32
    return 0;
#else
    return NULL;
#endif
}

#endif // ORBIT_THREAD_POOL_H
