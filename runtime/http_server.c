#include "http_server.h"
#include "admission.h"
#include "arena.h"
#include "builtins.h"
#include "console.h"
#include "http.h"
#include "os.h"
#include "performance.h"
#include "thread_pool.c"
#include <signal.h>

typedef struct {
    OrbitWorkerCtx io;
    const OrbitHttpServerConfig* config;
} OrbitHttpWorker;

void orbit_admission_peer_ip_string(orbit_socket_t socket, char* out, size_t size) {
    struct sockaddr_storage address;
    socklen_t length = sizeof(address);
    out[0] = '\0';
    if (getpeername(socket, (struct sockaddr*)&address, &length) != 0) return;
    if (address.ss_family == AF_INET) {
        inet_ntop(AF_INET, &((struct sockaddr_in*)&address)->sin_addr, out, size);
    } else if (address.ss_family == AF_INET6) {
        inet_ntop(AF_INET6, &((struct sockaddr_in6*)&address)->sin6_addr, out, size);
    }
}

#ifdef _WIN32
static unsigned __stdcall orbit_worker_loop(void* arg) {
#else
static void* orbit_worker_loop(void* arg) {
#endif
    OrbitHttpWorker* worker = arg;
    OrbitWorkerCtx* ctx = &worker->io;

    /* Each thread owns its private arena — zero pool contention */
    OrbitArena* thread_arena = orbit_arena_create(131072);
    /* A refused request is answered, not fatal: the boundary handler is
     * installed for this worker's lifetime (orbit_request_oom_arm). */
    orbit_request_oom_install();

    orbit_socket_t clients[512];
    size_t buffered[512];
    char* buffers[512];
    /* Per-connection peer IP string, resolved once at adoption: a
     * connection's peer cannot change, so admission never re-resolves it. */
    char* peers[512];
    int num_clients = 0;

    /* Thread-local pre-allocated buffer pool to eliminate malloc/free overhead */
    char* buffer_pool = (char*)malloc(512 * 16384);
    char* free_buffers[512];
    for (int j = 0; j < 512; j++) {
        free_buffers[j] = buffer_pool + j * 16384;
    }
    int free_buffers_count = 512;
    /* A peer string is owned by exactly one live slot or by this
     * free stack, never both -- the same discipline free_buffers
     * keeps for buffers[]. Without it, swap-remove copies a
     * pointer and the next adoption overwrites the peer string of
     * a connection that is still live. */
    char* peer_pool = (char*)malloc(512 * 64);
    char* free_peers[512];
    for (int j = 0; j < 512; j++) {
        peers[j] = peer_pool + j * 64;
        peers[j][0] = '\0';
        free_peers[j] = peers[j];
    }
    int free_peers_count = 512;
    /* Drain: after a stop is requested, finish adopted and queued
     * connections, then exit. New idle connections are dropped. */
    while (!orbit_stop_requested() || num_clients > 0 || !orbit_accept_q_empty(&ctx->q)) {
        fd_set readfds;
        FD_ZERO(&readfds);
        orbit_socket_t max_fd = 0;
        FD_SET(ctx->wake_recv, &readfds);
        if (ctx->wake_recv > max_fd) max_fd = ctx->wake_recv;

        for (int i = 0; i < num_clients; i++) {
            FD_SET(clients[i], &readfds);
            if (clients[i] > max_fd) max_fd = clients[i];
        }

        /* Select timeout is bounded to 1s so an idle worker re-checks
         * its accept queue even if a wake datagram is ever dropped. */
        struct timeval tv = {1, 0};
        int activity = select((int)max_fd + 1, &readfds, NULL, NULL, &tv);
        if (orbit_stop_channel_poll()) { orbit_request_stop(); }

        if (activity < 0) {
#ifdef _WIN32
            int err = WSAGetLastError();
            if (err == WSAENOTSOCK) {
                for (int i = 0; i < num_clients; ) {
                    int optval;
                    int optlen = sizeof(optval);
                    if (getsockopt(clients[i], SOL_SOCKET, SO_TYPE, (char*)&optval, &optlen) == SOCKET_ERROR) {
                        orbit_socket_close(clients[i]);
                        free_buffers[free_buffers_count++] = buffers[i];
                        clients[i] = clients[num_clients - 1];
                        buffered[i] = buffered[num_clients - 1];
                        buffers[i] = buffers[num_clients - 1];
                        free_peers[free_peers_count++] = peers[i];
                        peers[i] = peers[num_clients - 1];
                        num_clients--;
                    } else {
                        i++;
                    }
                }
            }
#else
            if (errno == EBADF || errno == ENOTSOCK) {
                for (int i = 0; i < num_clients; ) {
                    if (fcntl(clients[i], F_GETFD) == -1) {
                        orbit_socket_close(clients[i]);
                        free_buffers[free_buffers_count++] = buffers[i];
                        clients[i] = clients[num_clients - 1];
                        buffered[i] = buffered[num_clients - 1];
                        buffers[i] = buffers[num_clients - 1];
                        free_peers[free_peers_count++] = peers[i];
                        peers[i] = peers[num_clients - 1];
                        num_clients--;
                    } else {
                        i++;
                    }
                }
            }
#endif
            continue;
        }

        if (FD_ISSET(ctx->wake_recv, &readfds)) {
            orbit_wake_drain(ctx->wake_recv);
        }

        /* Adopt sockets pushed by the acceptor thread (lock-free SPSC). */
        orbit_socket_t new_sock;
        while (orbit_accept_q_pop(&ctx->q, &new_sock)) {
            if (num_clients < 512 && free_buffers_count > 0) {
                clients[num_clients] = new_sock;
                buffered[num_clients] = 0;
                buffers[num_clients] = free_buffers[--free_buffers_count];
                peers[num_clients] = free_peers[--free_peers_count];
                if (worker->config->admission) {
                    orbit_admission_peer_ip_string(new_sock, peers[num_clients], 64);
                }
                num_clients++;
            } else {
                orbit_socket_close(new_sock);
            }
        }

        for (int i = 0; i < num_clients; ) {
            orbit_socket_t client_sock = clients[i];
            int drop = 0;
            /* While draining, drop idle connections: only
             * in-flight requests (buffered bytes) run to completion. */
            if (orbit_stop_requested() && buffered[i] == 0) drop = 1;

            if (FD_ISSET(client_sock, &readfds)) {
                int received = recv(client_sock, buffers[i] + buffered[i], 16384 - 1 - buffered[i], 0);
                if (received == 0) {
                    drop = 1;
                } else if (received < 0) {
#ifdef _WIN32
                    int err = WSAGetLastError();
                    if (err != WSAEWOULDBLOCK) drop = 1;
#else
                    if (errno != EAGAIN && errno != EWOULDBLOCK) drop = 1;
#endif
                } else {
                    buffered[i] += received;
                    buffers[i][buffered[i]] = 0;

                    int keep_alive = 1;
                    size_t parsed = 0;
                    while (parsed < buffered[i]) {
                        size_t consumed = 0;
                        /* The boundary is this frame's: a refusal inside the request below
                         * returns here instead of ending the process, and is answered 503
                         * (ENGINEERING.md section 7, admission-lease-abort). The jmp_buf
                         * outlives the request. The connection closes with it: how much
                         * was consumed died with the stack. */
                        jmp_buf orbit_oom_jb;
                        orbit_arena_reset(thread_arena);
                        orbit_request_oom_arm(&orbit_oom_jb);
                        if (setjmp(orbit_oom_jb)) {
                            orbit_admission_lease_abandon();
                            OrbitResponse* oom_res = orbit_response_create(thread_arena, 503, "text/plain", orbit_request_oom_message());
                            oom_res = orbit_response_or_500(thread_arena, oom_res);
                            orbit_send_response(client_sock, oom_res);
                            keep_alive = 0;
                            break;
                        }
                        int keep = worker->config->request(client_sock, buffers[i] + parsed, buffered[i] - parsed, thread_arena, &consumed, peers[i]);
                        orbit_request_oom_disarm();
                        if (!keep) keep_alive = 0;
                        if (consumed == 0) break;
                        parsed += consumed;
                    }

                    if (parsed > 0) {
                        memmove(buffers[i], buffers[i] + parsed, buffered[i] - parsed);
                        buffered[i] -= parsed;
                    }

                    if (buffered[i] == 16384 - 1) {
                        /* The receive buffer is full and no request completed in it:
                         * answer 431 or 413 instead of closing without a word. */
                        orbit_arena_reset(thread_arena);
                        OrbitResponse* full = orbit_response_or_500(thread_arena, orbit_http_buffer_full_response(thread_arena, buffers[i], buffered[i]));
                        orbit_send_response(client_sock, full);
                        drop = 1;
                    }
                    if (!keep_alive) {
                        drop = 1;
                    }
                }
            }

            if (drop) {
                orbit_socket_close(client_sock);
                free_buffers[free_buffers_count++] = buffers[i];
                clients[i] = clients[num_clients - 1];
                buffered[i] = buffered[num_clients - 1];
                buffers[i] = buffers[num_clients - 1];
                free_peers[free_peers_count++] = peers[i];
                peers[i] = peers[num_clients - 1];
                num_clients--;
            } else {
                i++;
            }
        }
        if (worker->config->flush_logs) {
            /* Flush the request log once per pass. */
            fflush(stdout);
        }
    }
    free(buffer_pool);
    free(peer_pool);
    orbit_arena_destroy(thread_arena);
#ifdef _WIN32
    return 0;
#else
    return NULL;
#endif
}

/* Graceful shutdown: Ctrl-C / SIGTERM stops accepting; workers
 * finish in-flight requests, then the process exits cleanly. */
#ifdef _WIN32
static BOOL WINAPI orbit_ctrl_handler(DWORD type) {
    if (type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT) {
        orbit_request_stop();
        return TRUE;
    }
    return FALSE;
}
#else
static void orbit_term_handler(int sig) {
    (void)sig;
    orbit_request_stop();
}
#endif

int orbit_http_serve(const OrbitHttpServerConfig* config) {
    int port = config->port;
    orbit_socket_t server_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (server_sock == ORBIT_INVALID_SOCKET) {
        fprintf(stderr, "Could not create network socket. Check that networking is available on this machine, then try again.\n");
        return 1;
    }

    int reuse = 1;
#ifdef _WIN32
    setsockopt(server_sock, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (char*)&reuse, sizeof(reuse));
#else
    setsockopt(server_sock, SOL_SOCKET, SO_REUSEADDR, (char*)&reuse, sizeof(reuse));
#endif
    int nodelay = 1;
    setsockopt(server_sock, IPPROTO_TCP, TCP_NODELAY, (char*)&nodelay, sizeof(nodelay));
#ifdef _WIN32
    u_long mode = 1;
    ioctlsocket(server_sock, FIONBIO, &mode);
#else
    int flags = fcntl(server_sock, F_GETFL, 0);
    fcntl(server_sock, F_SETFL, flags | O_NONBLOCK);
#endif

    struct sockaddr_in server_addr;
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = INADDR_ANY;
    server_addr.sin_port = htons(port);

    if (bind(server_sock, (struct sockaddr*)&server_addr, sizeof(server_addr)) == ORBIT_SOCKET_ERROR) {
        fprintf(stderr, "Port %d is not available. Another program may be using it.\n", port);
        fprintf(stderr, "Change the port in your .orb file and try again.\n");
        orbit_socket_close(server_sock);
        return 1;
    }
    {
#ifdef _WIN32
        int _orbit_addr_len = (int)sizeof(server_addr);
#else
        socklen_t _orbit_addr_len = (socklen_t)sizeof(server_addr);
#endif
        if (getsockname(server_sock, (struct sockaddr*)&server_addr, &_orbit_addr_len) == 0) {
            port = (int)ntohs(server_addr.sin_port);
        }
    }

    if (listen(server_sock, SOMAXCONN) == ORBIT_SOCKET_ERROR) {
        fprintf(stderr, "Could not listen on port %d. Try again, and check firewall settings if it persists.\n", port);
        orbit_socket_close(server_sock);
        return 1;
    }

    orbit_console_init();

    int num_workers = 0;
    if (num_workers <= 0) {
        const char* _orbit_env_w = getenv("ORBIT_WORKERS");
        if (_orbit_env_w != NULL) {
            int _orbit_env_n = atoi(_orbit_env_w);
            if (_orbit_env_n > 0) num_workers = _orbit_env_n;
        }
    }
    if (num_workers <= 0) num_workers = ORBIT_CPU_COUNT();
    if (num_workers <= 0) num_workers = 1;
    if (num_workers > 64) num_workers = 64;
    orbit_system_set_workers(num_workers);

    if (config->ready) {
        config->ready(port, num_workers, config->show_admission,
                      (orbit_rdtsc() - config->start_cycles) / 2500000.0);
    }
    /* Start record for `orbit stop`: this server's pid, so a later
     * stop in the same directory kills exactly this process. Written
     * only when .orbit/ exists (start-managed projects); a bare
     * `orbit build` run elsewhere skips it silently, and a stale
     * file from a killed server is told apart by probing the pid. */
    {
        FILE* _orbit_start_pid = fopen(".orbit/start.pid", "w");
        if (_orbit_start_pid) {
            fprintf(_orbit_start_pid, "%d\n", (int)system_pid());
            fclose(_orbit_start_pid);
        }
    }
#ifdef _WIN32
    SetConsoleCtrlHandler(orbit_ctrl_handler, TRUE);
#else
    signal(SIGINT, orbit_term_handler);
    signal(SIGTERM, orbit_term_handler);
#endif
    orbit_stop_channel_open(0);

    orbit_thread_t* workers = (orbit_thread_t*)malloc(sizeof(orbit_thread_t) * (size_t)num_workers);
    OrbitHttpWorker* workers_ctx = calloc((size_t)num_workers, sizeof(*workers_ctx));
    if (!workers || !workers_ctx) {
        free(workers);
        free(workers_ctx);
        orbit_socket_close(server_sock);
        return 1;
    }

    OrbitAcceptorCtx acceptor;
    acceptor.server_sock = server_sock;
    acceptor.num_workers = num_workers;
    acceptor.wake_send = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (acceptor.wake_send == ORBIT_INVALID_SOCKET) {
        fprintf(stderr, "Could not start server internals (wake socket). Try again.\n");
        free(workers);
        free(workers_ctx);
        orbit_socket_close(server_sock);
        return 1;
    }

    int ready_workers = 0;
    for (int i = 0; i < num_workers; i++) {
        OrbitWorkerCtx* ctx = &workers_ctx[i].io;
        workers_ctx[i].config = config;
        orbit_accept_q_init(&ctx->q);
        ctx->thread_id = i;
        ctx->port      = port;
        if (!orbit_wake_recv_create(&ctx->wake_recv, &acceptor.wake_addr[i])) {
            fprintf(stderr, "Could not start server internals (worker wake socket). Try again.\n");
            break;
        }
        acceptor.queues[i] = &ctx->q;
        ready_workers++;
    }
    if (ready_workers != num_workers) {
        for (int i = 0; i < ready_workers; i++) orbit_socket_close(workers_ctx[i].io.wake_recv);
        free(workers);
        free(workers_ctx);
        orbit_socket_close(acceptor.wake_send);
        orbit_socket_close(server_sock);
        return 1;
    }

    orbit_thread_t acceptor_thread;
    ORBIT_THREAD_CREATE(acceptor_thread, orbit_acceptor_loop, &acceptor);

    for (int i = 1; i < num_workers; i++) {
        ORBIT_THREAD_CREATE(workers[i], orbit_worker_loop, &workers_ctx[i]);
    }

    orbit_worker_loop(&workers_ctx[0]);

    /* A stop was requested: close the listener,
     * join every thread, then run the normal cleanup below. */
    orbit_socket_close(server_sock);
    ORBIT_THREAD_JOIN(acceptor_thread);
    for (int i = 1; i < num_workers; i++) {
        ORBIT_THREAD_JOIN(workers[i]);
    }
    orbit_socket_close(acceptor.wake_send);
    for (int i = 0; i < num_workers; i++) orbit_socket_close(workers_ctx[i].io.wake_recv);
    free(workers);
    free(workers_ctx);
    printf("Server stopped.\n");
    fflush(stdout);
    remove(".orbit/start.pid");

    return 0;
}
