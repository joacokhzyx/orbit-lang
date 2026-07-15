#ifdef _WIN32
#  define _CRT_SECURE_NO_WARNINGS
#  include <winsock2.h>
#  include <ws2tcpip.h>
#  pragma comment(lib, "ws2_32.lib")
typedef int socklen_t;
#else
#  include <sys/socket.h>
#  include <netinet/in.h>
#  include <arpa/inet.h>
#  include <unistd.h>
#  include <signal.h>
#  define SOCKET int
#  define INVALID_SOCKET (-1)
#  define SOCKET_ERROR   (-1)
#  define closesocket    close
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MOD 1000000007ULL
#define BUF_SIZE 4096

static volatile int running = 1;

#ifndef _WIN32
static void handle_sig(int sig) { (void)sig; running = 0; }
#endif

static unsigned long long fib(long long n) {
    if (n < 0) return 0;
    if (n > 1000000) n = 1000000;
    if (n == 0) return 0;
    if (n == 1) return 1;
    unsigned long long a = 0, b = 1, c;
    for (long long i = 2; i <= n; i++) {
        c = (a + b) % MOD;
        a = b;
        b = c;
    }
    return b;
}

/* Parse first line of HTTP request. Returns method, path, query pointers into buf. */
static int parse_request(char *buf, char **method, char **path, char **query) {
    char *sp1 = strchr(buf, ' ');
    if (!sp1) return -1;
    *sp1 = '\0';
    *method = buf;

    char *url = sp1 + 1;
    char *sp2 = strchr(url, ' ');
    if (!sp2) return -1;
    *sp2 = '\0';

    char *q = strchr(url, '?');
    if (q) {
        *q = '\0';
        *query = q + 1;
    } else {
        *query = NULL;
    }
    *path = url;
    return 0;
}

static const char *get_query_param(const char *query, const char *key) {
    if (!query) return NULL;
    size_t klen = strlen(key);
    const char *p = query;
    while (*p) {
        if (strncmp(p, key, klen) == 0 && p[klen] == '=') {
            return p + klen + 1;
        }
        p = strchr(p, '&');
        if (!p) break;
        p++;
    }
    return NULL;
}

static void send_response(SOCKET fd, int status, const char *status_text,
                          const char *body, size_t body_len) {
    char header[256];
    int hlen = snprintf(header, sizeof(header),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: text/plain\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "\r\n",
        status, status_text, body_len);
    send(fd, header, hlen, 0);
    if (body_len > 0) send(fd, body, (int)body_len, 0);
}

static void handle_connection(SOCKET client) {
    char buf[BUF_SIZE];
    int total = 0;
    /* Read until we have the first line or buffer full */
    while (total < BUF_SIZE - 1) {
        int n = recv(client, buf + total, BUF_SIZE - 1 - total, 0);
        if (n <= 0) goto done;
        total += n;
        buf[total] = '\0';
        if (strstr(buf, "\r\n")) break;
    }

    /* Null-terminate at first CRLF for parse_request */
    char *crlf = strstr(buf, "\r\n");
    if (crlf) *crlf = '\0';

    char *method = NULL, *path = NULL, *query = NULL;
    if (parse_request(buf, &method, &path, &query) < 0) {
        send_response(client, 400, "Bad Request", "Not Found\n", 10);
        goto done;
    }

    if (strcmp(method, "GET") != 0) {
        send_response(client, 404, "Not Found", "Not Found\n", 10);
        goto done;
    }

    if (strcmp(path, "/") == 0) {
        send_response(client, 200, "OK", "OK\n", 3);
    } else if (strcmp(path, "/fib") == 0) {
        const char *nstr = get_query_param(query, "n");
        if (!nstr) {
            send_response(client, 404, "Not Found", "Not Found\n", 10);
            goto done;
        }
        char *end;
        long long n = strtoll(nstr, &end, 10);
        if (end == nstr) {
            send_response(client, 404, "Not Found", "Not Found\n", 10);
            goto done;
        }
        unsigned long long result = fib(n);
        char body[32];
        int blen = snprintf(body, sizeof(body), "%llu\n", result);
        send_response(client, 200, "OK", body, (size_t)blen);
    } else {
        send_response(client, 404, "Not Found", "Not Found\n", 10);
    }

done:
    closesocket(client);
}

int main(int argc, char *argv[]) {
    if (argc < 2) return 1;
    int port = atoi(argv[1]);
    if (port <= 0) return 1;

#ifdef _WIN32
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return 1;
#else
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handle_sig;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);
#endif

    SOCKET server = socket(AF_INET, SOCK_STREAM, 0);
    if (server == INVALID_SOCKET) return 1;

    int opt = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, (const char *)&opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port        = htons((unsigned short)port);

    if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) == SOCKET_ERROR) return 1;
    if (listen(server, SOMAXCONN) == SOCKET_ERROR) return 1;

    while (running) {
        struct sockaddr_in client_addr;
        socklen_t clen = sizeof(client_addr);
        SOCKET client = accept(server, (struct sockaddr *)&client_addr, &clen);
        if (client == INVALID_SOCKET) break;
        handle_connection(client);
    }

    closesocket(server);
#ifdef _WIN32
    WSACleanup();
#endif
    return 0;
}
