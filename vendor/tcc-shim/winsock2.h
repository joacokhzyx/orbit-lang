/*
 * winsock2.h -- closed-set Winsock ABI shim for tcc 0.9.27 (Windows x64).
 *
 * Why this exists: tcc 0.9.27 ships no winsock headers at all (measured
 * 2026-10-14: `#include <winsock2.h>` fails with "include file not found"),
 * and its lib/ carries no ws2_32.def, so anything touching sockets neither
 * compiles nor links. This header provides the exact subset the Orbit
 * runtime uses on the Windows path, with ABI-real layouts and values.
 *
 * ABI-real means: every struct here is declared with the same field order
 * and natural alignment as the platform SDK, so the layout falls out of the
 * C rules rather than from copied padding. Fixed-width stdint types are
 * used instead of relying on tcc's own windows headers, so this file is
 * self-contained. Base Windows scalar types (SOCKET, DWORD, WORD, ...) are
 * redeclared here and guarded, so including the real headers afterwards
 * cannot collide.
 *
 * Closed set means: what is listed below links (each entry verified as a
 * real ws2_32.dll export via `tcc -impdef`, same date); what is NOT listed
 * fails. tcc turns an undeclared call into a warning plus an `undefined
 * symbol` hard error at link time, and ws2_32.def ships only the names
 * below, so a new Winsock use breaks the build loudly. That is the
 * contract: a use outside this set fails in the shim, never silently.
 *
 * Consumed with `-I vendor/tcc-shim` placed BEFORE tcc's own include dir,
 * so `#include <winsock2.h>` from runtime/socket_compat.h resolves here.
 */
#ifndef _ORBIT_TCC_WINSOCK2_H
#define _ORBIT_TCC_WINSOCK2_H

/* Keep the real headers out if they ever appear: same guard names. */
#ifndef _WINSOCKAPI_
#define _WINSOCKAPI_
#endif
#ifndef _WINSOCK2API_
#define _WINSOCK2API_
#endif

#include <stdint.h>
#include <stddef.h>

/* -- base scalar types (same widths as the SDK on x64) ------------------ */
#ifndef _ORBIT_TCC_BASETYPES_
#define _ORBIT_TCC_BASETYPES_
typedef unsigned char BYTE;
typedef unsigned short WORD;
typedef unsigned long DWORD;
typedef unsigned int u_int;
typedef unsigned short u_short;
typedef unsigned long u_long;
typedef uint64_t UINT_PTR;
typedef int64_t INT_PTR;
typedef UINT_PTR SOCKET;
typedef int socklen_t;
#endif

/* -- address families, socket types, protocols --------------------------- */
#define AF_UNSPEC 0
#define AF_INET 2
#define AF_INET6 23
#define PF_INET AF_INET
#define PF_INET6 AF_INET6
#define PF_UNSPEC AF_UNSPEC

#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOCK_RAW 3

#define IPPROTO_IP 0
#define IPPROTO_TCP 6
#define IPPROTO_UDP 17

#define INADDR_ANY 0u
#define INADDR_LOOPBACK 0x7f000001u
#define INADDR_BROADCAST 0xffffffffu

/* -- socket options ------------------------------------------------------ */
#define SOL_SOCKET 0xffff

#define SO_REUSEADDR 0x0004
#define SO_KEEPALIVE 0x0008
#define SO_SNDBUF 0x1001
#define SO_RCVBUF 0x1002
#define SO_SNDTIMEO 0x1005
#define SO_RCVTIMEO 0x1006
#define SO_ERROR 0x1007
#define SO_TYPE 0x1008

#define TCP_NODELAY 0x0001

#define SOMAXCONN 0x7fffffff

/* -- shutdown channels --------------------------------------------------- */
#define SD_RECEIVE 0
#define SD_SEND 1
#define SD_BOTH 2

/* -- invalid / error sentinels ------------------------------------------- */
#define INVALID_SOCKET (SOCKET)(~0)
#define SOCKET_ERROR (-1)

/* -- non-blocking ioctl -------------------------------------------------- */
#define FIONBIO 0x8004667eu

/* -- Winsock error codes used by the runtime ------------------------------
 *
 * Undef-first is load-bearing, not hygiene. tcc warns on ANY macro
 * redefinition, even an identical one, and that warning is fatal under
 * -Werror. The values below equal the SDK's (WSAEWOULDBLOCK is
 * WSABASEERR+35 = 10035, verified three ways on 2026-10-14: MinGW-w64's
 * own winerror.h, tcc's bundled winerror.h, and the number ws2_32.dll
 * actually returns for a non-blocking connect in progress, observed
 * through both a gcc and a tcc build of the same probe). Whichever
 * header comes second wins the macro, so the shim takes the value by
 * force in both orders: tcc's <windows.h> (pulled in by the -include
 * file) always runs first, the shim always runs second. */
#ifdef WSAEINTR
#undef WSAEINTR
#endif
#ifdef WSAEINVAL
#undef WSAEINVAL
#endif
#ifdef WSAEINPROGRESS
#undef WSAEINPROGRESS
#endif
#ifdef WSAEWOULDBLOCK
#undef WSAEWOULDBLOCK
#endif
#ifdef WSAECONNRESET
#undef WSAECONNRESET
#endif
#define WSAEINTR 10004
#define WSAEINVAL 10022
#define WSAEINPROGRESS 10036
#define WSAEWOULDBLOCK 10035
#define WSAECONNRESET 10054

/* -- byte order (real ws2_32.dll exports, not macros) --------------------- */
unsigned long __stdcall htonl(unsigned long hostlong);
unsigned short __stdcall htons(unsigned short hostshort);
unsigned long __stdcall ntohl(unsigned long netlong);
unsigned short __stdcall ntohs(unsigned short netshort);

/* -- timeval: `long` is 32-bit on Windows x64, matching the SDK ----------- */
struct timeval {
    long tv_sec;
    long tv_usec;
};

/* -- socket address structures (natural layout == SDK layout) ------------ */
struct sockaddr {
    unsigned short sa_family;
    char sa_data[14];
};

struct in_addr {
    union {
        struct { unsigned char s_b1, s_b2, s_b3, s_b4; } S_un_b;
        struct { unsigned short s_w1, s_w2; } S_un_w;
        unsigned long S_addr;
    } S_un;
};

/* SDK spelling: runtime code writes sin_addr.s_addr, which is this macro. */
#define s_addr S_un.S_addr

struct sockaddr_in {
    short sin_family;
    unsigned short sin_port;
    struct in_addr sin_addr;
    char sin_zero[8];
};

struct in6_addr {
    union {
        unsigned char Byte[16];
        unsigned short Word[8];
    } u;
};

struct sockaddr_in6 {
    short sin6_family;
    unsigned short sin6_port;
    unsigned long sin6_flowinfo;
    struct in6_addr sin6_addr;
    unsigned long sin6_scope_id;
};

/* 128 bytes, 8-byte aligned, like the SDK (family + pad + align + pad). */
struct sockaddr_storage {
    short ss_family;
    char __ss_pad1[6];
    int64_t __ss_align;
    char __ss_pad2[112];
};

/* -- WSADATA: field order gives the SDK's 408-byte x64 layout ------------ */
typedef struct WSAData {
    WORD wVersion;
    WORD wHighVersion;
    char szDescription[257];
    char szSystemStatus[129];
    unsigned short iMaxSockets;
    unsigned short iMaxUdpDg;
    char *lpVendorInfo;
} WSADATA, *LPWSADATA;

#ifdef MAKEWORD
#undef MAKEWORD
#endif
#define MAKEWORD(a, b) \
    ((WORD)(((BYTE)(((DWORD)(a)) & 0xff)) | ((WORD)((BYTE)(((DWORD)(b)) & 0xff)) << 8)))

/* -- fd_set: SDK layout (count + array), honouring a pre-defined size ---- */
#ifndef FD_SETSIZE
#define FD_SETSIZE 64
#endif

typedef struct fd_set {
    u_int fd_count;
    SOCKET fd_array[FD_SETSIZE];
} fd_set;

int __stdcall __WSAFDIsSet(SOCKET fd, fd_set *set);

#define FD_CLR(fd, set) do { \
    u_int __i; \
    for (__i = 0; __i < ((fd_set *)(set))->fd_count; __i++) { \
        if (((fd_set *)(set))->fd_array[__i] == (fd)) { \
            while (__i < ((fd_set *)(set))->fd_count - 1) { \
                ((fd_set *)(set))->fd_array[__i] = ((fd_set *)(set))->fd_array[__i + 1]; \
                __i++; \
            } \
            ((fd_set *)(set))->fd_count--; \
            break; \
        } \
    } \
} while (0)

#define FD_SET(fd, set) do { \
    u_int __i; \
    for (__i = 0; __i < ((fd_set *)(set))->fd_count; __i++) { \
        if (((fd_set *)(set))->fd_array[__i] == (fd)) break; \
    } \
    if (__i == ((fd_set *)(set))->fd_count && ((fd_set *)(set))->fd_count < FD_SETSIZE) { \
        ((fd_set *)(set))->fd_array[__i] = (fd); \
        ((fd_set *)(set))->fd_count++; \
    } \
} while (0)

#define FD_ZERO(set) (((fd_set *)(set))->fd_count = 0)
#define FD_ISSET(fd, set) __WSAFDIsSet((fd), (set))

/* -- startup / cleanup / last error -------------------------------------- */
int __stdcall WSAStartup(WORD wVersionRequested, LPWSADATA lpWSAData);
int __stdcall WSACleanup(void);
int __stdcall WSAGetLastError(void);
void __stdcall WSASetLastError(int iError);

/* -- sockets -------------------------------------------------------------- */
SOCKET __stdcall socket(int af, int type, int protocol);
int __stdcall closesocket(SOCKET s);
int __stdcall bind(SOCKET s, const struct sockaddr *addr, int namelen);
int __stdcall listen(SOCKET s, int backlog);
SOCKET __stdcall accept(SOCKET s, struct sockaddr *addr, int *addrlen);
int __stdcall connect(SOCKET s, const struct sockaddr *addr, int namelen);
int __stdcall send(SOCKET s, const char *buf, int len, int flags);
int __stdcall recv(SOCKET s, char *buf, int len, int flags);
int __stdcall sendto(SOCKET s, const char *buf, int len, int flags,
                     const struct sockaddr *to, int tolen);
int __stdcall recvfrom(SOCKET s, char *buf, int len, int flags,
                       struct sockaddr *from, int *fromlen);
int __stdcall setsockopt(SOCKET s, int level, int optname,
                         const char *optval, int optlen);
int __stdcall getsockopt(SOCKET s, int level, int optname,
                         char *optval, int *optlen);
int __stdcall getsockname(SOCKET s, struct sockaddr *addr, int *addrlen);
int __stdcall getpeername(SOCKET s, struct sockaddr *addr, int *addrlen);
int __stdcall ioctlsocket(SOCKET s, long cmd, u_long *argp);
int __stdcall shutdown(SOCKET s, int how);
int __stdcall select(int nfds, fd_set *readfds, fd_set *writefds,
                     fd_set *exceptfds, const struct timeval *timeout);

#endif /* _ORBIT_TCC_WINSOCK2_H */
