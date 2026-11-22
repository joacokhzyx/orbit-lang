/* orbit_os_spawn_bg must not hand the caller's stdout to the child.
 *
 * A pipeline sees end of file only when every writer closes. The nodes
 * `orbit cluster up` starts outlive the command, so a child that inherits the
 * caller's stdout keeps `orbit cluster up | tail` and $(...) waiting until the
 * nodes die. The child's own output goes to the log file; it has no reason to
 * hold the caller's.
 *
 * Windows only: the POSIX branch redirects stdout and stderr to the log and
 * closes the rest before exec, so the bug cannot exist there.
 */
#include <stdio.h>
#include <string.h>

#include "runtime.h"

#ifdef _WIN32

#include <windows.h>

static DWORD WINAPI drain_pipe(void* arg) {
    HANDLE h = (HANDLE)arg;
    char buf[64];
    DWORD n = 0;
    while (ReadFile(h, buf, (DWORD)sizeof buf, &n, NULL) && n > 0) {
    }
    return 0;
}

int main(void) {
    int failures = 0;
    HANDLE rd = NULL;
    HANDLE wr = NULL;
    SECURITY_ATTRIBUTES sa;
    HANDLE saved;
    HANDLE reader;
    orbit_int pid;
    DWORD waited;

    ZeroMemory(&sa, sizeof sa);
    sa.nLength = (DWORD)sizeof sa;
    sa.bInheritHandle = TRUE;
    if (!CreatePipe(&rd, &wr, &sa, 0)) {
        printf("FAILED create pipe\n");
        return 1;
    }
    SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
    saved = GetStdHandle(STD_OUTPUT_HANDLE);
    SetStdHandle(STD_OUTPUT_HANDLE, wr);

    /* Several seconds of life, and it never writes: the parent's closed
     * handle is the only writer unless the child inherited it. */
    pid = orbit_os_spawn_bg("cmd /c ping -n 5 127.0.0.1 >nul", "NUL");
    SetStdHandle(STD_OUTPUT_HANDLE, saved);
    CloseHandle(wr);
    if (pid <= 0) {
        printf("FAILED spawn\n");
        CloseHandle(rd);
        return 1;
    }

    reader = CreateThread(NULL, 0, drain_pipe, rd, 0, NULL);
    waited = WaitForSingleObject(reader, 1500);
    if (waited != WAIT_OBJECT_0) {
        printf("FAILED the spawned child holds the caller's stdout\n");
        failures++;
        TerminateThread(reader, 0);
    }
    CloseHandle(reader);
    CloseHandle(rd);
    orbit_os_kill(pid, 0);
    if (failures == 0) printf("PASS\n");
    return failures == 0 ? 0 : 1;
}

#else

int main(void) {
    /* The POSIX branch redirects both streams to the log before exec. */
    printf("PASS\n");
    return 0;
}

#endif
