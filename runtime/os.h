/* Interface of runtime/os.c (generated split; edit by hand from here). */
#ifndef ORBIT_RT_OS_H
#define ORBIT_RT_OS_H

#include "module_prelude.h"

#include "types.h"
#include "arena.h"

#include "types.h"
#include "arena.h"
#include "crt_compat.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#include <direct.h>
#include <windows.h>
#include <io.h>
/* errno/EEXIST are used below: gcc and MSVC receive <errno.h> transitively
 * through the headers above, tcc does not, so it rides here explicitly. */
#include <errno.h>
#else
#include <sys/wait.h>
#include <sys/types.h>
#include <signal.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>
#endif
bool orbit_os_mkdir_p(const char* path);
ORBIT_UNUSED bool orbit_os_isatty_selfhost(orbit_int fd);
orbit_string orbit_os_cwd(OrbitArena* arena);
bool orbit_os_chdir(orbit_string path);
orbit_string orbit_os_env(OrbitArena* arena, orbit_string var_name);
orbit_string orbit_os_exec(OrbitArena* arena, orbit_string command);
void orbit_os_exit(orbit_int code);
orbit_int orbit_os_spawn(orbit_string command);
orbit_int orbit_os_run_timeout(orbit_string command, orbit_int timeout_ms, orbit_string capture_path);
orbit_int orbit_os_spawn_bg(orbit_string command, orbit_string logfile);
orbit_int orbit_os_kill(orbit_int pid, orbit_int mode);

#ifdef _WIN32
#include <winsock2.h>
#include <windows.h>
#else
#include <sys/ptrace.h>
#include <sys/types.h>
#if !defined(_WIN32)
#include <unistd.h>
#include <sys/stat.h>
#endif
#ifdef __APPLE__
#include <sys/sysctl.h>
#endif
#endif
extern char** _orbit_argv;
extern int _orbit_argc;
orbit_int orbit_os_argc(void);
orbit_string orbit_os_argv(OrbitArena* arena, orbit_int index);

#ifdef _WIN32
/* RtlGenRandom, the OS pool without a new link library: neither rand_s
 * nor the SystemFunction036 prototype exists in the headers this tree
 * builds with, and advapi32 (where it lives) is already linked into
 * every program, so the declaration rides here instead of in a header
 * that would promise it everywhere. */
BOOLEAN NTAPI SystemFunction036(PVOID RandomBuffer, ULONG RandomBufferLength);
#endif
OrbitResult orbit_random_bytes(OrbitArena* arena, orbit_int n);

#endif
