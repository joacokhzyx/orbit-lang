#ifndef ORBIT_SOCKET_COMPAT_H
#define ORBIT_SOCKET_COMPAT_H

#ifdef _WIN32
  #ifndef FD_SETSIZE
    #define FD_SETSIZE 4096
  #endif
  // Windows (Winsock2)
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

  // SO_RCVTIMEO en Windows toma int (ms), no struct timeval
  static inline void orbit_set_recv_timeout(orbit_socket_t s, int ms) {
      setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (char*)&ms, sizeof(ms));
  }
#else
  // POSIX (Linux, macOS, BSD)
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

  // SO_RCVTIMEO en POSIX toma struct timeval
  static inline void orbit_set_recv_timeout(orbit_socket_t s, int ms) {
      struct timeval tv;
      tv.tv_sec  = ms / 1000;
      tv.tv_usec = (ms % 1000) * 1000;
      setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  }
#endif

// SO_REUSEPORT (Solo en Linux)
#ifdef __linux__
static inline void orbit_enable_reuseport(orbit_socket_t s) {
    int val = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &val, sizeof(val));
}
#else
static inline void orbit_enable_reuseport(orbit_socket_t s) { (void)s; }
#endif

#endif // ORBIT_SOCKET_COMPAT_H
