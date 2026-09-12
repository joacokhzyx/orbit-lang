/**
 * @file  os.c
 * @brief Cross-platform OS utilities for Orbit (process info, env, paths).
 *
 * Wraps OS-specific calls behind a uniform C API used by the Orbit runtime
 * on Windows (Win32), Linux, and macOS.  Includes directory creation,
 * environment variable access, and executable-path resolution.
 */
#ifndef ORBIT_OS_C
#define ORBIT_OS_C

#include "types.c"
#include "arena.c"
#include <stdlib.h>
#include <stdio.h>
#ifdef _WIN32
#include <direct.h>
#include <windows.h>
#else
#include <sys/wait.h>
#include <sys/types.h>
#include <signal.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#endif

orbit_string orbit_os_cwd(OrbitArena* arena) {
    OrbitArena* a = (arena && arena->base) ? arena : orbit_arena_get_global();
#ifdef _WIN32
    char buf[4096];
    if (!_getcwd(buf, sizeof(buf))) return "";
#else
    char buf[4096];
    if (!getcwd(buf, sizeof(buf))) return "";
#endif
    size_t len = strlen(buf);
    char* result = (char*)orbit_alloc(a, len + 1);
    if (!result) return "";
    memcpy(result, buf, len);
    result[len] = '\0';
    return result;
}

bool orbit_os_chdir(orbit_string path) {
#ifdef _WIN32
    return _chdir(path) == 0;
#else
    return chdir(path) == 0;
#endif
}

orbit_string orbit_os_env(OrbitArena* arena, orbit_string var_name) {
    if (!var_name) return "";
    OrbitArena* a = (arena && arena->base) ? arena : orbit_arena_get_global();
    
    char* val = getenv(var_name);
    if (!val) return "";
    
    size_t len = strlen(val);
    char* buf = (char*)orbit_alloc(a, len + 1);
    if (!buf) return "";
    
    memcpy(buf, val, len);
    buf[len] = '\0';
    return buf;
}

orbit_string orbit_os_exec(OrbitArena* arena, orbit_string command) {
    if (!command) return "";
#if !defined(ORBIT_WITH_EXEC)
    /* R3.6: command execution is opt-in (see builtins.c system_os_exec). */
    return "";
#else
    OrbitArena* a = (arena && arena->base) ? arena : orbit_arena_get_global();

#ifdef _WIN32
    FILE* fp = _popen(command, "r");
#else
    FILE* fp = popen(command, "r");
#endif

    if (!fp) return "";

    size_t capacity = 1024;
    size_t size = 0;
    char* buf = (char*)malloc(capacity);
    if (!buf) {
#ifdef _WIN32
        _pclose(fp);
#else
        pclose(fp);
#endif
        return "";
    }

    while (fgets(buf + size, (int)(capacity - size), fp)) {
        size += strlen(buf + size);
        if (size + 256 >= capacity) {
            capacity *= 2;
            char* new_buf = (char*)realloc(buf, capacity);
            if (!new_buf) break;
            buf = new_buf;
        }
    }

    int exit_code = 0;
#ifdef _WIN32
    int status = _pclose(fp);
    exit_code = status;
#else
    int status = pclose(fp);
    if (status == -1) {
        exit_code = -1;
    } else if (WIFEXITED(status)) {
        exit_code = WEXITSTATUS(status);
    } else {
        exit_code = status;
    }
#endif

    if (exit_code != 0) {
        char err_prefix[64];
        int err_len = snprintf(err_prefix, sizeof(err_prefix), "[ERROR: process exited with code %d]\n", exit_code);
        if (err_len < 0) err_len = 0;

        char* result = (char*)orbit_alloc(a, err_len + size + 1);
        if (result) {
            memcpy(result, err_prefix, err_len);
            if (size > 0) {
                memcpy(result + err_len, buf, size);
            }
            result[err_len + size] = '\0';
        }
        free(buf);
        return result ? result : "[ERROR: process execution failed]";
    }

    char* result = (char*)orbit_alloc(a, size + 1);
    if (result) {
        memcpy(result, buf, size);
        result[size] = '\0';
    }
    free(buf);

    return result ? result : "";
#endif /* ORBIT_WITH_EXEC */
}

void orbit_os_exit(orbit_int code) {
    exit((int)code);
}

// Spawn a command with inherited stdio (for `orbit run`).
// Unlike orbit_os_exec (popen capture, waits for EOF), this lets
// long-running programs such as servers own the terminal.
// Returns the child exit code, or 1 when it cannot be determined.
orbit_int orbit_os_spawn(orbit_string command) {
    if (!command) return 1;
#ifdef _WIN32
    return system(command);
#else
    int status = system(command);
    if (status == -1) return 1;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return 1;
#endif
}

// ---- Single-host cluster orchestration (orbit cluster v1) ----------------
// Detached background spawn + signal/probe. Used by the compiler binary
// itself for `orbit cluster` (trusted infrastructure, like orbit_os_spawn).

// Launch `command` detached: stdin is /dev/null (NUL), stdout/stderr are
// appended to `logfile` (discarded when empty). Returns the child pid (>0),
// or -1 when the child could not be started.
// POSIX: fork + setsid, then `sh -c "exec <command>"` so the returned pid is
// the server itself (no intermediate shell left to orphan). A graceful stop
// sent to this pid therefore reaches the server's own SIGTERM handler.
// Windows: CreateProcess with DETACHED_PROCESS, std handles on the log file.
orbit_int orbit_os_spawn_bg(orbit_string command, orbit_string logfile) {
    if (!command || !*command) return -1;
#ifdef _WIN32
    const char* lf = (logfile && *logfile) ? logfile : "NUL";
    SECURITY_ATTRIBUTES sa;
    ZeroMemory(&sa, sizeof(sa));
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;
    HANDLE hLog = CreateFileA(lf, FILE_APPEND_DATA,
                              FILE_SHARE_READ | FILE_SHARE_WRITE,
                              &sa, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hLog == INVALID_HANDLE_VALUE) return -1;
    HANDLE hIn = CreateFileA("NUL", GENERIC_READ,
                             FILE_SHARE_READ | FILE_SHARE_WRITE,
                             &sa, OPEN_EXISTING, 0, NULL);
    STARTUPINFOA si;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = hLog;
    si.hStdError = hLog;
    si.hStdInput = (hIn == INVALID_HANDLE_VALUE) ? NULL : hIn;
    /* CreateProcessA may modify the command line: pass a mutable copy. */
    size_t n = strlen(command);
    char* cmdline = (char*)malloc(n + 1);
    if (!cmdline) {
        CloseHandle(hLog);
        if (hIn != INVALID_HANDLE_VALUE) CloseHandle(hIn);
        return -1;
    }
    memcpy(cmdline, command, n + 1);
    PROCESS_INFORMATION pi;
    ZeroMemory(&pi, sizeof(pi));
    BOOL ok = CreateProcessA(NULL, cmdline, NULL, NULL, TRUE,
                             DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP,
                             NULL, NULL, &si, &pi);
    free(cmdline);
    CloseHandle(hLog);
    if (hIn != INVALID_HANDLE_VALUE) CloseHandle(hIn);
    if (!ok) return -1;
    CloseHandle(pi.hThread);
    orbit_int cpid = (orbit_int)pi.dwProcessId;
    CloseHandle(pi.hProcess);
    return cpid;
#else
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        if (setsid() < 0) _exit(127);
        const char* lf = (logfile && *logfile) ? logfile : "/dev/null";
        int fd = open(lf, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            dup2(fd, STDOUT_FILENO);
            dup2(fd, STDERR_FILENO);
            if (fd > STDERR_FILENO) close(fd);
        }
        int dn = open("/dev/null", O_RDONLY);
        if (dn >= 0) {
            dup2(dn, STDIN_FILENO);
            if (dn > STDERR_FILENO) close(dn);
        }
        /* `exec` replaces the shell, so getpid() == server pid. */
        size_t clen = strlen(command);
        char* exec_cmd = (char*)malloc(clen + 6);
        if (!exec_cmd) _exit(127);
        memcpy(exec_cmd, "exec ", 5);
        memcpy(exec_cmd + 5, command, clen + 1);
        execl("/bin/sh", "sh", "-c", exec_cmd, (char*)NULL);
        _exit(127);
    }
    return (orbit_int)pid;
#endif
}

// Signal or probe a process by pid.
// mode 0 = forceful stop  (POSIX SIGKILL / Windows TerminateProcess).
// mode 1 = graceful stop  (POSIX SIGTERM, honored by the generated server's
//          drain handler; Windows TerminateProcess, which is NOT graceful).
// mode 2 = probe only: report whether pid is alive, send nothing
//          (POSIX kill(pid,0), plus a waitpid reap check so an already-exited
//           child of this process reads as dead instead of lingering as a
//           zombie; Windows OpenProcess + WaitForSingleObject(0)).
// Returns 1 on success (probe: alive), 0 on failure (probe: dead/absent).
orbit_int orbit_os_kill(orbit_int pid, orbit_int mode) {
    if (pid <= 0) return 0;
#ifdef _WIN32
    if (mode == 2) {
        HANDLE h = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)pid);
        if (h == NULL) return 0;
        DWORD w = WaitForSingleObject(h, 0);
        CloseHandle(h);
        return (w == WAIT_TIMEOUT) ? 1 : 0;
    }
    HANDLE h = OpenProcess(PROCESS_TERMINATE, FALSE, (DWORD)pid);
    if (h == NULL) return 0;
    BOOL ok = TerminateProcess(h, 0);
    CloseHandle(h);
    return ok ? 1 : 0;
#else
    if (mode == 2) {
        int status = 0;
        pid_t w = waitpid((pid_t)pid, &status, WNOHANG);
        if (w == (pid_t)pid) return 0; /* own child, exited: reaped, dead */
        if (w == 0) return 1;          /* own child, still running */
        if (kill((pid_t)pid, 0) == 0) return 1;
        return (errno == EPERM) ? 1 : 0; /* exists, but not permitted */
    }
    int sig = (mode == 0) ? SIGKILL : SIGTERM;
    return (kill((pid_t)pid, sig) == 0) ? 1 : 0;
#endif
}

#ifdef _WIN32
#include <winsock2.h>
#include <windows.h>
#else
#include <sys/ptrace.h>
#include <sys/types.h>
#if !defined(_WIN32)
#include <unistd.h>
#endif
#ifdef __APPLE__
#include <sys/sysctl.h>
#endif
#endif

void orbit_anti_debug(void) {
#ifdef _WIN32
    if (IsDebuggerPresent()) {
        exit(1);
    }
    BOOL isDebuggerPresent = FALSE;
    if (CheckRemoteDebuggerPresent(GetCurrentProcess(), &isDebuggerPresent) && isDebuggerPresent) {
        exit(1);
    }
#elif defined(__APPLE__)
    int mib[4];
    struct kinfo_proc info;
    size_t size;
    info.kp_proc.p_flag = 0;
    mib[0] = CTL_KERN;
    mib[1] = KERN_PROC;
    mib[2] = KERN_PROC_PID;
    mib[3] = getpid();
    size = sizeof(info);
    sysctl(mib, sizeof(mib) / sizeof(*mib), &info, &size, NULL, 0);
    if ((info.kp_proc.p_flag & P_TRACED) != 0) {
        exit(1);
    }
    ptrace(31, 0, 0, 0); // PT_DENY_ATTACH = 31 on macOS
#else
    // ptrace on Linux returns -1 if a debugger is already attached
    if (ptrace(PTRACE_TRACEME, 0, 1, 0) < 0) {
        exit(1);
    }
#endif
}

char** _orbit_argv = NULL;
int _orbit_argc = 0;

orbit_int orbit_os_argc(void) {
    return _orbit_argc;
}

orbit_string orbit_os_argv(OrbitArena* arena, orbit_int index) {
    if (index < 0 || index >= _orbit_argc) return "";
    OrbitArena* a = (arena && arena->base) ? arena : orbit_arena_get_global();
    size_t len = strlen(_orbit_argv[index]);
    char* buf = (char*)orbit_alloc(a, len + 1);
    if (!buf) return "";
    memcpy(buf, _orbit_argv[index], len);
    buf[len] = '\0';
    return buf;
}

#endif
