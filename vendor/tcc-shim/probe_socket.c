#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdio.h>
#include <string.h>

/* Loopback exercise for the tcc shim: WSAStartup, socket/bind/listen,
 * getsockname (ephemeral port), getaddrinfo/freeaddrinfo, connect,
 * accept, send/recv, select, ioctlsocket, getsockopt(SO_ERROR),
 * getpeername + IN6/loopback check, closure. Returns 0 on full pass. */
int main(void) {
    WSADATA wsa;
    SOCKET ls = INVALID_SOCKET, cli = INVALID_SOCKET, srv = INVALID_SOCKET;
    struct sockaddr_in addr, got, peer;
    struct addrinfo hints, *res = 0;
    int len, port, n, fails = 0;
    char buf[64];
    fd_set rfds;
    struct timeval tv;
    u_long mode;
    int soerr;
    int optlen;

    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) { printf("FAIL WSAStartup\n"); return 1; }

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo("127.0.0.1", "0", &hints, &res) != 0 || !res) { printf("FAIL getaddrinfo\n"); return 1; }
    freeaddrinfo(res);

    ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (ls == INVALID_SOCKET) { printf("FAIL socket\n"); return 1; }
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(0);
    if (bind(ls, (struct sockaddr *)&addr, sizeof(addr)) != 0) { printf("FAIL bind\n"); return 1; }
    if (listen(ls, 8) != 0) { printf("FAIL listen\n"); return 1; }
    len = sizeof(got);
    if (getsockname(ls, (struct sockaddr *)&got, &len) != 0) { printf("FAIL getsockname\n"); return 1; }
    port = ntohs(got.sin_port);
    if (port <= 0) { printf("FAIL ephemeral port %d\n", port); return 1; }

    /* non-blocking connect + select writability + SO_ERROR, as http.c does */
    cli = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    mode = 1;
    if (ioctlsocket(cli, FIONBIO, &mode) != 0) { printf("FAIL ioctlsocket\n"); return 1; }
    memset(&peer, 0, sizeof(peer));
    peer.sin_family = AF_INET;
    peer.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    peer.sin_port = htons((unsigned short)port);
    connect(cli, (struct sockaddr *)&peer, sizeof(peer));
    if (WSAGetLastError() != WSAEWOULDBLOCK && WSAGetLastError() != 0) { printf("FAIL conn errno %d\n", WSAGetLastError()); return 1; }
    FD_ZERO(&rfds);
    FD_SET(cli, &rfds);
    tv.tv_sec = 5; tv.tv_usec = 0;
    if (select((int)cli + 1, NULL, &rfds, NULL, &tv) <= 0) { printf("FAIL select\n"); return 1; }
    if (!FD_ISSET(cli, &rfds)) { printf("FAIL FD_ISSET\n"); return 1; }
    optlen = sizeof(soerr);
    if (getsockopt(cli, SOL_SOCKET, SO_ERROR, (char *)&soerr, &optlen) != 0 || soerr != 0) { printf("FAIL SO_ERROR %d\n", soerr); return 1; }
    mode = 0;
    ioctlsocket(cli, FIONBIO, &mode);

    len = sizeof(got);
    srv = accept(ls, (struct sockaddr *)&got, &len);
    if (srv == INVALID_SOCKET) { printf("FAIL accept\n"); return 1; }
    len = sizeof(peer);
    if (getpeername(srv, (struct sockaddr *)&peer, &len) != 0) { printf("FAIL getpeername\n"); return 1; }
    if (peer.sin_addr.s_addr != htonl(INADDR_LOOPBACK)) { printf("FAIL loopback\n"); return 1; }

    if (send(cli, "ping", 4, 0) != 4) { printf("FAIL send\n"); return 1; }
    n = recv(srv, buf, sizeof(buf), 0);
    if (n != 4 || memcmp(buf, "ping", 4) != 0) { printf("FAIL recv\n"); return 1; }

    /* toolchain mappings from -include tcc_toolchain.h */
    {
        ULONGLONG t = GetTickCount64();
        long long v = strtoll("-12345", 0, 10);
        unsigned long long u = strtoull("99", 0, 10);
        YieldProcessor();
        if (t == 0 || v != -12345 || u != 99) { printf("FAIL toolchain map\n"); return 1; }
    }

    closesocket(srv);
    closesocket(cli);
    closesocket(ls);
    WSACleanup();
    if (fails == 0) printf("TCC-SHIM-SOCKET-PASS port=%d\n", port);
    return fails;
}
