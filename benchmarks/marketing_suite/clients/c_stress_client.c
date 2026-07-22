#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
#else
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#endif

int main(int argc, char** argv) {
    int port = 4001;
    if (argc > 1) port = atoi(argv[1]);
    int num_reqs = 5000;

#ifdef _WIN32
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#endif

    struct sockaddr_in server_addr;
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons((unsigned short)port);
    inet_pton(AF_INET, "127.0.0.1", &server_addr.sin_addr);

    const char* req = "GET /loop HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n";
    int req_len = (int)strlen(req);
    char buf[1024];

    int success = 0;
    int errors = 0;

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock >= 0) {
        if (connect(sock, (struct sockaddr*)&server_addr, sizeof(server_addr)) == 0) {
            for (int i = 0; i < num_reqs; i++) {
                if (send(sock, req, req_len, 0) > 0) {
                    int bytes = recv(sock, buf, sizeof(buf) - 1, 0);
                    if (bytes > 0) {
                        success++;
                    } else {
                        errors++;
                        break;
                    }
                } else {
                    errors++;
                    break;
                }
            }
        }
#ifdef _WIN32
        closesocket(sock);
#else
        close(sock);
#endif
    }

#ifdef _WIN32
    WSACleanup();
#endif

    printf("{\"client\":\"C\",\"total\":%d,\"success\":%d,\"errors\":%d}\n", success + errors, success, errors);
    return 0;
}
