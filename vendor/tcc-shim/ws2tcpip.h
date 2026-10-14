/*
 * ws2tcpip.h -- closed-set address-resolution shim for tcc 0.9.27.
 *
 * Companionship file to winsock2.h in this directory: the two together
 * cover what the Orbit runtime resolves at link time on Windows.
 * The addrinfo layout below is the SDK's (three ints, then size_t and two
 * pointers: 48 bytes on x64 by natural alignment).
 *
 * IN6_IS_ADDR_LOOPBACK lives here rather than in a ws2ipdef.h because
 * there is no ws2ipdef.h in the shim: one fewer file, same macro. The
 * byte-wise spelling is endianness-independent and equivalent to the
 * SDK's word comparison for ::1.
 *
 * Closed set: getaddrinfo/freeaddrinfo only. Anything else (GetAddrInfoW,
 * WSAIoctl, gethostname, ...) is a link error until it is added to this
 * file AND to ws2_32.def AND re-verified with `tcc -impdef`.
 */
#ifndef _ORBIT_TCC_WS2TCPIP_H
#define _ORBIT_TCC_WS2TCPIP_H

#include <stddef.h>

#ifndef _ORBIT_TCC_BASETYPES_
#define _ORBIT_TCC_BASETYPES_
typedef unsigned char BYTE;
typedef unsigned short WORD;
typedef unsigned long DWORD;
typedef unsigned int u_int;
typedef unsigned short u_short;
typedef unsigned long u_long;
typedef unsigned long long UINT_PTR;
typedef long long INT_PTR;
typedef UINT_PTR SOCKET;
typedef int socklen_t;
#endif

#define AI_PASSIVE 0x1

typedef struct addrinfo {
    int ai_flags;
    int ai_family;
    int ai_socktype;
    int ai_protocol;
    size_t ai_addrlen;
    char *ai_canonname;
    struct sockaddr *ai_addr;
    struct addrinfo *ai_next;
} addrinfo;

int __stdcall getaddrinfo(const char *nodename, const char *servname,
                          const struct addrinfo *hints,
                          struct addrinfo **res);
void __stdcall freeaddrinfo(struct addrinfo *res);

#define IN6_IS_ADDR_LOOPBACK(a) \
    (((const BYTE *)(a))[0] == 0 && ((const BYTE *)(a))[1] == 0 && \
     ((const BYTE *)(a))[2] == 0 && ((const BYTE *)(a))[3] == 0 && \
     ((const BYTE *)(a))[4] == 0 && ((const BYTE *)(a))[5] == 0 && \
     ((const BYTE *)(a))[6] == 0 && ((const BYTE *)(a))[7] == 0 && \
     ((const BYTE *)(a))[8] == 0 && ((const BYTE *)(a))[9] == 0 && \
     ((const BYTE *)(a))[10] == 0 && ((const BYTE *)(a))[11] == 0 && \
     ((const BYTE *)(a))[12] == 0 && ((const BYTE *)(a))[13] == 0 && \
     ((const BYTE *)(a))[14] == 0 && ((const BYTE *)(a))[15] == 1)

#endif /* _ORBIT_TCC_WS2TCPIP_H */
