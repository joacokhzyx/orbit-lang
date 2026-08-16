// Minimal single-threaded select() HTTP server for benchmarking (Windows).
#include <winsock2.h>
#include <ws2tcpip.h>
#include <stdio.h>
#include <string.h>

#define MAX_CLIENTS 512
#define BUF_SIZE 16384
#define PORT 4104

static const char* RESP =
    "HTTP/1.1 200 OK\r\n"
    "Content-Type: application/json\r\n"
    "Content-Length: 2\r\n"
    "Connection: keep-alive\r\n"
    "\r\n"
    "OK";

int main(void) {
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return 1;

    SOCKET server = socket(AF_INET, SOCK_STREAM, 0);
    if (server == INVALID_SOCKET) return 1;
    int opt = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, (char*)&opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(PORT);
    if (bind(server, (struct sockaddr*)&addr, sizeof(addr)) != 0) return 1;
    if (listen(server, 512) != 0) return 1;

    u_long nb = 1;
    ioctlsocket(server, FIONBIO, &nb);

    SOCKET clients[MAX_CLIENTS];
    memset(clients, 0, sizeof(clients));

    while (1) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(server, &rfds);
        int maxfd = (int)server;
        for (int i = 0; i < MAX_CLIENTS; i++) {
            if (clients[i] != 0) {
                FD_SET(clients[i], &rfds);
                if ((int)clients[i] > maxfd) maxfd = (int)clients[i];
            }
        }
        if (select(maxfd + 1, &rfds, NULL, NULL, NULL) == SOCKET_ERROR) continue;

        if (FD_ISSET(server, &rfds)) {
            SOCKET c = accept(server, NULL, NULL);
            if (c != INVALID_SOCKET) {
                u_long cb = 1;
                ioctlsocket(c, FIONBIO, &cb);
                int nodelay = 1;
                setsockopt(c, IPPROTO_TCP, TCP_NODELAY, (char*)&nodelay, sizeof(nodelay));
                int slot = -1;
                for (int i = 0; i < MAX_CLIENTS; i++) {
                    if (clients[i] == 0) { slot = i; break; }
                }
                if (slot >= 0) clients[slot] = c;
                else closesocket(c);
            }
        }

        for (int i = 0; i < MAX_CLIENTS; i++) {
            if (clients[i] == 0) continue;
            if (FD_ISSET(clients[i], &rfds)) {
                char buf[BUF_SIZE];
                int n = recv(clients[i], buf, BUF_SIZE - 1, 0);
                if (n <= 0) {
                    closesocket(clients[i]);
                    clients[i] = 0;
                } else {
                    send(clients[i], RESP, (int)strlen(RESP), 0);
                }
            }
        }
    }
    return 0;
}