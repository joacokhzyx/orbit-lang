/**
 * @file  socket_compat.h
 * @brief Cross-platform socket type aliases and helper macros.
 *
 * Abstracts the differences between Winsock2 (Windows) and POSIX sockets
 * (Linux / macOS / BSD) behind a uniform orbit_socket_t typedef and a small
 * set of inline helpers, so the rest of the runtime never includes
 * platform-specific socket headers directly.
 */
#ifndef ORBIT_SOCKET_COMPAT_H
#define ORBIT_SOCKET_COMPAT_H

#ifdef _WIN32
  #ifndef FD_SETSIZE
    #define FD_SETSIZE 4096
  #endif
  /* Windows — Winsock2 */
  #ifndef WIN32_LEAN_AND_MEAN
    #define WIN32_LEAN_AND_MEAN
  #endif
  #include <winsock2.h>
  #include <ws2tcpip.h>

  typedef SOCKET orbit_socket_t;
  #define ORBIT_INVALID_SOCKET  INVALID_SOCKET
  #define ORBIT_SOCKET_ERROR    SOCKET_ERROR
  #define orbit_socket_close(s) closesocket(s)
  #define orbit_socket_errno()  WSAGetLastError()

  /** @brief Set the receive timeout on @p s to @p ms milliseconds (Windows: integer milliseconds). */
  static inline void orbit_set_recv_timeout(orbit_socket_t s, int ms) {
      setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (char*)&ms, sizeof(ms));
  }
#else
  /* POSIX — Linux, macOS, BSD */
  #include <sys/types.h>
  #include <sys/socket.h>
  #include <netinet/in.h>
  #include <netinet/tcp.h>
  #include <arpa/inet.h>
  #include <unistd.h>
  #include <errno.h>
  #include <fcntl.h>

  typedef int orbit_socket_t;
  #define ORBIT_INVALID_SOCKET  (-1)
  #define ORBIT_SOCKET_ERROR    (-1)
  #define orbit_socket_close(s) close(s)
  #define orbit_socket_errno()  errno

  /** @brief Set the receive timeout on @p s to @p ms milliseconds (POSIX: struct timeval). */
  static inline void orbit_set_recv_timeout(orbit_socket_t s, int ms) {
      struct timeval tv;
      tv.tv_sec  = ms / 1000;
      tv.tv_usec = (ms % 1000) * 1000;
      setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  }
#endif

/* SO_REUSEPORT — Linux only. */
#ifdef __linux__
/** @brief Enable SO_REUSEPORT on @p s so multiple threads can accept on the same port. */
static inline void orbit_enable_reuseport(orbit_socket_t s) {
    int val = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &val, sizeof(val));
}
#else
/** @brief No-op stub for platforms that do not support SO_REUSEPORT. */
static inline void orbit_enable_reuseport(orbit_socket_t s) { (void)s; }
#endif

#endif // ORBIT_SOCKET_COMPAT_H
