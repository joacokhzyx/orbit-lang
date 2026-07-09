#ifndef ORBIT_OS_C
#define ORBIT_OS_C

#include "types.c"
#include "arena.c"
#include <stdlib.h>
#include <stdio.h>

orbit_string orbit_os_env(OrbitArena* arena, orbit_string var_name) {
    if (!var_name || !arena) return "";
    
    char* val = getenv(var_name);
    if (!val) return "";
    
    size_t len = strlen(val);
    char* buf = (char*)orbit_alloc(arena, len + 1);
    if (!buf) return "";
    
    memcpy(buf, val, len);
    buf[len] = '\0';
    return buf;
}

orbit_string orbit_os_exec(OrbitArena* arena, orbit_string command) {
    if (!command || !arena) return "";

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

#ifdef _WIN32
    _pclose(fp);
#else
    pclose(fp);
#endif

    char* result = (char*)orbit_alloc(arena, size + 1);
    if (result) {
        memcpy(result, buf, size);
        result[size] = '\0';
    }
    free(buf);

    return result ? result : "";
}

void orbit_os_exit(orbit_int code) {
    exit((int)code);
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

#endif
