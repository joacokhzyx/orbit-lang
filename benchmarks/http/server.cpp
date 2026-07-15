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

#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <string>
#include <string_view>
#include <charconv>
#include <optional>

static const unsigned long long MOD = 1'000'000'007ULL;
static volatile int running = 1;

#ifndef _WIN32
static void handle_sig(int) { running = 0; }
#endif

static unsigned long long fib(long long n) {
    if (n < 0) return 0;
    if (n > 1'000'000) n = 1'000'000;
    if (n == 0) return 0;
    if (n == 1) return 1;
    unsigned long long a = 0, b = 1;
    for (long long i = 2; i <= n; ++i) {
        unsigned long long c = (a + b) % MOD;
        a = b;
        b = c;
    }
    return b;
}

static std::optional<std::string_view> get_query_param(std::string_view query, std::string_view key) {
    std::string prefix = std::string(key) + "=";
    size_t pos = 0;
    while (pos < query.size()) {
        size_t amp = query.find('&', pos);
        std::string_view part = (amp == std::string_view::npos)
            ? query.substr(pos)
            : query.substr(pos, amp - pos);
        if (part.substr(0, prefix.size()) == prefix) {
            return part.substr(prefix.size());
        }
        if (amp == std::string_view::npos) break;
        pos = amp + 1;
    }
    return std::nullopt;
}

static void send_all(SOCKET fd, const std::string &data) {
    size_t sent = 0;
    while (sent < data.size()) {
        int n = send(fd, data.c_str() + sent, (int)(data.size() - sent), 0);
        if (n <= 0) break;
        sent += n;
    }
}

static void send_response(SOCKET fd, int status, const char *status_text, const std::string &body) {
    std::string response =
        "HTTP/1.1 " + std::to_string(status) + " " + status_text + "\r\n"
        "Content-Type: text/plain\r\n"
        "Content-Length: " + std::to_string(body.size()) + "\r\n"
        "Connection: close\r\n"
        "\r\n" + body;
    send_all(fd, response);
}

static void handle_connection(SOCKET client) {
    char buf[4096];
    std::string raw;
    raw.reserve(512);

    while (raw.size() < 4096) {
        int n = recv(client, buf, sizeof(buf), 0);
        if (n <= 0) goto done;
        raw.append(buf, n);
        if (raw.find("\r\n") != std::string::npos) break;
    }

    {
        size_t crlf = raw.find("\r\n");
        std::string_view first_line(raw.c_str(), crlf == std::string::npos ? raw.size() : crlf);

        // Parse method
        size_t sp1 = first_line.find(' ');
        if (sp1 == std::string_view::npos) { send_response(client, 400, "Bad Request", "Not Found\n"); goto done; }
        std::string_view method = first_line.substr(0, sp1);

        // Parse URL
        size_t sp2 = first_line.find(' ', sp1 + 1);
        std::string_view url = (sp2 == std::string_view::npos)
            ? first_line.substr(sp1 + 1)
            : first_line.substr(sp1 + 1, sp2 - sp1 - 1);

        // Split path and query
        size_t qmark = url.find('?');
        std::string_view path  = (qmark == std::string_view::npos) ? url : url.substr(0, qmark);
        std::string_view query = (qmark == std::string_view::npos) ? "" : url.substr(qmark + 1);

        if (method != "GET") { send_response(client, 404, "Not Found", "Not Found\n"); goto done; }

        if (path == "/") {
            send_response(client, 200, "OK", "OK\n");
        } else if (path == "/fib") {
            auto nopt = get_query_param(query, "n");
            if (!nopt) { send_response(client, 404, "Not Found", "Not Found\n"); goto done; }
            long long n = 0;
            auto [ptr, ec] = std::from_chars(nopt->data(), nopt->data() + nopt->size(), n);
            if (ec != std::errc{}) { send_response(client, 404, "Not Found", "Not Found\n"); goto done; }
            unsigned long long result = fib(n);
            send_response(client, 200, "OK", std::to_string(result) + "\n");
        } else {
            send_response(client, 404, "Not Found", "Not Found\n");
        }
    }

done:
    closesocket(client);
}

int main(int argc, char *argv[]) {
    if (argc < 2) return 1;
    int port = std::atoi(argv[1]);
    if (port <= 0) return 1;

#ifdef _WIN32
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return 1;
#else
    struct sigaction sa{};
    sa.sa_handler = handle_sig;
    sigaction(SIGTERM, &sa, nullptr);
    sigaction(SIGINT,  &sa, nullptr);
#endif

    SOCKET server = socket(AF_INET, SOCK_STREAM, 0);
    if (server == INVALID_SOCKET) return 1;

    int opt = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, (const char *)&opt, sizeof(opt));

    sockaddr_in addr{};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port        = htons((unsigned short)port);

    if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) == SOCKET_ERROR) return 1;
    if (listen(server, SOMAXCONN) == SOCKET_ERROR) return 1;

    while (running) {
        sockaddr_in client_addr{};
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
