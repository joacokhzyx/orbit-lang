#ifndef ORBIT_RT_OS_C
#define ORBIT_RT_OS_C

#include "module_prelude.h"
#include "os.h"
#include "types.h"
#include "arena.h"
#include "collections.h"
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
#include <fcntl.h>
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

/**
 * Create a directory and every missing parent, like `mkdir -p`.
 *
 * Exists because orbit_file_write cannot create the directory it is writing
 * into: it opens the path and reports failure, so a cache whose layout has a
 * subdirectory was unusable until this did. Returns false when the path could
 * not be created, and true when it already existed -- "the directory is there"
 * is the only thing a caller asking for this actually wanted.
 */
bool orbit_os_mkdir_p(const char* path) {
    if (!path || !*path) return false;
    char buf[1024];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof(buf)) return false;
    memcpy(buf, path, len + 1);

    /* Strip a trailing separator unless the path IS the root. */
    while (len > 1 && (buf[len - 1] == '/' || buf[len - 1] == '\\')) {
        buf[--len] = '\0';
    }

    for (size_t i = 1; i < len; i++) {
        if (buf[i] == '/' || buf[i] == '\\') {
            char saved = buf[i];
            buf[i] = '\0';
#ifdef _WIN32
            _mkdir(buf);
#else
            mkdir(buf, 0777);
#endif
            buf[i] = saved;
        }
    }
#ifdef _WIN32
    if (_mkdir(buf) != 0 && errno != EEXIST) return false;
#else
    if (mkdir(buf, 0777) != 0 && errno != EEXIST) return false;
#endif
    return true;
}

// Whether fd is a live terminal. The compiler's auto color needs the real
// answer per stream, not TERM alone: piped output stays plain even when TERM
// names a color terminal, and a redirected stdout with a live stderr still
// paints its cards. Windows speaks _isatty, everything else isatty.
ORBIT_UNUSED bool orbit_os_isatty_selfhost(orbit_int fd) {
    if (fd < 0) return false;
#ifdef _WIN32
    return _isatty((int)fd) != 0;
#else
    return isatty((int)fd) != 0;
#endif
}

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
    
    const char* val = orbit_env_get(var_name);
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

// Run `command` through the shell and wait at most timeout_ms (<= 0 waits
// forever). stdout and stderr go to capture_path when it is non-empty and are
// inherited otherwise. Returns the exit code; -2 when the deadline passed (the
// whole process tree is killed); -1 when the command could not be started.
// The caller that must not hang on a stale tool (the native backend probing
// r6.exe) is the reason this exists next to orbit_os_spawn, which waits for ever.
orbit_int orbit_os_run_timeout(orbit_string command, orbit_int timeout_ms, orbit_string capture_path) {
    if (!command || !*command) return -1;
    int capture = capture_path && *capture_path;
#ifdef _WIN32
    SECURITY_ATTRIBUTES sa;
    ZeroMemory(&sa, sizeof(sa));
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;
    HANDLE hOut = INVALID_HANDLE_VALUE;
    HANDLE hIn = INVALID_HANDLE_VALUE;
    if (capture) {
        hOut = CreateFileA(capture_path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           &sa, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (hOut == INVALID_HANDLE_VALUE) return -1;
        hIn = CreateFileA("NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                          &sa, OPEN_EXISTING, 0, NULL);
    }
    STARTUPINFOA si;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    if (capture) {
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = hIn;
        si.hStdOutput = hOut;
        si.hStdError = hOut;
    }
    static const char prefix[] = "cmd.exe /d /s /c \"";
    size_t clen = strlen(command);
    char* line = (char*)malloc(sizeof(prefix) + clen + 2);
    if (!line) {
        if (hOut != INVALID_HANDLE_VALUE) CloseHandle(hOut);
        if (hIn != INVALID_HANDLE_VALUE) CloseHandle(hIn);
        return -1;
    }
    memcpy(line, prefix, sizeof(prefix) - 1);
    memcpy(line + sizeof(prefix) - 1, command, clen);
    line[sizeof(prefix) - 1 + clen] = '"';
    line[sizeof(prefix) + clen] = '\0';
    HANDLE job = CreateJobObjectA(NULL, NULL);
    if (job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION lim;
        ZeroMemory(&lim, sizeof(lim));
        lim.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(job, JobObjectExtendedLimitInformation, &lim, sizeof(lim));
    }
    PROCESS_INFORMATION pi;
    ZeroMemory(&pi, sizeof(pi));
    BOOL ok = CreateProcessA(NULL, line, NULL, NULL, TRUE, CREATE_SUSPENDED, NULL, NULL, &si, &pi);
    free(line);
    if (hOut != INVALID_HANDLE_VALUE) CloseHandle(hOut);
    if (hIn != INVALID_HANDLE_VALUE) CloseHandle(hIn);
    if (!ok) {
        if (job) CloseHandle(job);
        return -1;
    }
    if (job) AssignProcessToJobObject(job, pi.hProcess);
    ResumeThread(pi.hThread);
    DWORD wait = WaitForSingleObject(pi.hProcess, timeout_ms > 0 ? (DWORD)timeout_ms : INFINITE);
    orbit_int rc;
    if (wait == WAIT_TIMEOUT) {
        if (job) TerminateJobObject(job, 1); else TerminateProcess(pi.hProcess, 1);
        WaitForSingleObject(pi.hProcess, 2000);
        rc = -2;
    } else {
        DWORD code = 0;
        rc = GetExitCodeProcess(pi.hProcess, &code) ? (orbit_int)code : -1;
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    if (job) CloseHandle(job);
    return rc;
#else
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        setpgid(0, 0);
        if (capture) {
            int fd = open(capture_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd >= 0) {
                dup2(fd, STDOUT_FILENO);
                dup2(fd, STDERR_FILENO);
                if (fd > STDERR_FILENO) close(fd);
            }
        }
        execl("/bin/sh", "sh", "-c", command, (char*)NULL);
        _exit(127);
    }
    long waited_ms = 0;
    for (;;) {
        int status = 0;
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) {
            if (WIFEXITED(status)) return WEXITSTATUS(status);
            return 1;
        }
        if (r < 0) return -1;
        if (timeout_ms > 0 && waited_ms >= timeout_ms) {
            kill(-pid, SIGKILL);
            waitpid(pid, &status, 0);
            return -2;
        }
        usleep(10000);
        waited_ms += 10;
    }
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
    /* The child gets hLog for both streams below. Its own copy of the caller's
     * stdout is the one thing it must not get: a pipeline sees end of file only
     * when every writer closes, and these children outlive the command that
     * started them. Clearing the flag on the parent's handles is enough --
     * CreateProcess copies only inheritable ones. */
    {
        HANDLE ownOut = GetStdHandle(STD_OUTPUT_HANDLE);
        HANDLE ownErr = GetStdHandle(STD_ERROR_HANDLE);
        if (ownOut != NULL && ownOut != INVALID_HANDLE_VALUE) {
            SetHandleInformation(ownOut, HANDLE_FLAG_INHERIT, 0);
        }
        if (ownErr != NULL && ownErr != INVALID_HANDLE_VALUE) {
            SetHandleInformation(ownErr, HANDLE_FLAG_INHERIT, 0);
        }
    }
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

/* One stop channel per process, named by its pid.
 *
 * A stop asked from another process has no signal to send on Windows: the
 * children are created DETACHED_PROCESS (see the spawn above), so there is no
 * console for GenerateConsoleCtrlEvent to deliver into, and TerminateProcess
 * loses the requests in flight. The name is the pid because that is the only
 * thing the stopper knows. pid <= 0 means "this process", which is how the
 * generated server opens its own channel without a getpid of its own.
 *
 * POSIX has SIGTERM, which the generated server's handler already turns into
 * orbit_request_stop(). The three calls there do nothing and answer 0, so one
 * emitted code path works on both hosts and the signal path stays the single
 * answer to the question on POSIX. */
#ifdef _WIN32
static HANDLE orbit_stop_channel_handle = NULL;

orbit_int orbit_stop_channel_open(orbit_int pid) {
    char name[48];
    DWORD own;
    if (orbit_stop_channel_handle != NULL) return 1;
    own = (pid > 0) ? (DWORD)pid : GetCurrentProcessId();
    snprintf(name, sizeof(name), "Local\\orbit-stop-%lu", (unsigned long)own);
    orbit_stop_channel_handle = CreateEventA(NULL, TRUE, FALSE, name);
    return orbit_stop_channel_handle != NULL ? 1 : 0;
}

orbit_int orbit_stop_channel_poll(void) {
    if (orbit_stop_channel_handle == NULL) return 0;
    return WaitForSingleObject(orbit_stop_channel_handle, 0) == WAIT_OBJECT_0 ? 1 : 0;
}

orbit_int orbit_stop_channel_ask(orbit_int pid) {
    char name[48];
    HANDLE h;
    BOOL ok;
    if (pid <= 0) return 0;
    snprintf(name, sizeof(name), "Local\\orbit-stop-%lu", (unsigned long)pid);
    h = OpenEventA(EVENT_MODIFY_STATE, FALSE, name);
    if (h == NULL) return 0;
    ok = SetEvent(h);
    CloseHandle(h);
    return ok ? 1 : 0;
}
#else
orbit_int orbit_stop_channel_open(orbit_int pid) { (void)pid; return 0; }
orbit_int orbit_stop_channel_poll(void) { return 0; }
orbit_int orbit_stop_channel_ask(orbit_int pid) { (void)pid; return 0; }
#endif

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
    /* A graceful stop, asked through the channel the child opened. When no
     * channel exists -- the child is older than the channel, or it never got
     * to the server start -- fall back to the terminate this function always
     * did, and keep the same return value so callers do not change shape. */
    if (mode == 1 && orbit_stop_channel_ask(pid) == 1) return 1;
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
#include <sys/stat.h>
#endif
#ifdef __APPLE__
#include <sys/sysctl.h>
#endif
#endif


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
#ifdef _WIN32
#endif

/** @brief n bytes of OS entropy as a list of byte values, or err.
 *
 * No PRNG and no seed state: Windows draws from the OS pool through
 * RtlGenRandom (no extra link library), POSIX reads /dev/urandom, so every
 * target already in CI works with nothing new to link. A failed source is
 * err, never a half-filled list; a negative count is refused up front and
 * zero answers the empty list. Bytes travel as ints 0..255 because an
 * orbit_string cannot hold a NUL. */
OrbitResult orbit_random_bytes(OrbitArena* arena, orbit_int n) {
    if (n < 0) {
        return orbit_result_err(ORBIT_ERR_INVALID_ARG, "random: negative count");
    }
    {
        OrbitArena* a = (arena && arena->base) ? arena : orbit_arena_get_global();
        OrbitResult cr = orbit_list_create(a, sizeof(uintptr_t), (size_t)n);
        OrbitList* list;
        uint8_t* buf;
        if (!cr.ok) return cr;
        list = (OrbitList*)cr.value;
        if (n == 0) return orbit_result_ok(list);
        buf = (uint8_t*)orbit_alloc(a, (size_t)n);
        if (!buf) {
            return orbit_result_err(ORBIT_ERR_OUT_OF_MEMORY, "random: alloc failed");
        }
#ifdef _WIN32
        /* One call fills the whole buffer; a FALSE return is the only
         * failure the API has. */
        if (!SystemFunction036(buf, (ULONG)n)) {
            return orbit_result_err(ORBIT_ERR_IO, "random: entropy source failed");
        }
#else
        {
            int fd = open("/dev/urandom", O_RDONLY);
            if (fd < 0) {
                return orbit_result_err(ORBIT_ERR_IO, "random: entropy source unavailable");
            }
            {
                size_t got = 0;
                while (got < (size_t)n) {
                    ssize_t r = read(fd, buf + got, (size_t)n - got);
                    if (r < 0) {
                        if (errno == EINTR) continue;
                        close(fd);
                        return orbit_result_err(ORBIT_ERR_IO, "random: entropy read failed");
                    }
                    if (r == 0) {
                        close(fd);
                        return orbit_result_err(ORBIT_ERR_IO, "random: short entropy read");
                    }
                    got += (size_t)r;
                }
            }
            close(fd);
        }
#endif
        {
            orbit_int j = 0;
            while (j < n) {
                OrbitResult pr = orbit_list_push_int(list, (orbit_int)buf[j]);
                if (!pr.ok) return pr;
                j++;
            }
        }
        return orbit_result_ok(list);
    }
}

/* ── Standard input ───────────────────────────────────────────────────────
 * A language that hosts a language server has to read the protocol stream,
 * and the runtime had no read of stdin at all. `read_line` stops at LF and
 * drops a CR before it, so a stream written by a Windows client and one
 * written by a POSIX client read the same. `read_bytes` takes exactly what
 * the caller asks for, because a JSON-RPC body has no line structure and may
 * contain any byte but NUL: an orbit_string is NUL-terminated, so a body with
 * a NUL truncates and the caller sees a short read as an empty one.
 * `at_end` is what tells an empty line from the end of the stream. */
orbit_string orbit_stdin_read_line(OrbitArena* arena) {
    orbit_int cap = 128;
    orbit_int len = 0;
    char* buf;
    int c;
    if (!arena) return "";
    buf = (char*)orbit_alloc_try(arena, (size_t)cap);
    if (!buf) return "";
    while ((c = fgetc(stdin)) != EOF && c != '\n') {
        if (len + 1 >= cap) {
            char* grown = (char*)orbit_alloc_try(arena, (size_t)cap * 2);
            if (!grown) return "";
            memcpy(grown, buf, (size_t)len);
            buf = grown;
            cap *= 2;
        }
        if (c != '\r') {
            buf[len] = (char)c;
            len++;
        }
    }
    if (c == EOF && len == 0) return "";
    buf[len] = 0;
    return buf;
}

orbit_string orbit_stdin_read_bytes(OrbitArena* arena, orbit_int n) {
    char* buf;
    size_t got;
    if (!arena || n <= 0) return "";
    buf = (char*)orbit_alloc_try(arena, (size_t)n + 1);
    if (!buf) return "";
    got = 0;
    /* A pipe may deliver less than asked in one call; a protocol reader has to
       keep asking until the body it was promised has arrived, or the stream
       ends. */
    while (got < (size_t)n) {
        size_t r = fread(buf + got, 1, (size_t)n - got, stdin);
        if (r == 0) break;
        got += r;
    }
    buf[got] = 0;
    return buf;
}

bool orbit_stdin_at_end(void) {
    return feof(stdin) != 0;
}

/* A protocol writer needs its bytes, not the platform's idea of a newline:
   Windows text mode turns the "\n" of a "\r\n" header terminator into
   "\r\n", so the stream carries "\r\r\n" and no client parses it. */
bool orbit_stdout_binary(void) {
#ifdef _WIN32
    return _setmode(_fileno(stdout), _O_BINARY) != -1;
#else
    return true;
#endif
}

/* `print` appends a newline, which a framed protocol cannot have: the bytes
   between messages are part of the framing. */
bool orbit_stdout_write(orbit_string text) {
    if (!text) return false;
    if (fwrite(text, 1, strlen(text), stdout) != strlen(text)) return false;
    return fflush(stdout) == 0;
}

#endif
