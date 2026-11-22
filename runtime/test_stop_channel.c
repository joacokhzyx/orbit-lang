/* The cross-process stop channel: open, poll, ask.
 *
 * The channel exists because Windows has no signal to send a detached child.
 * So the Windows half of this test is the real path: a process opens the name
 * that carries its own pid, and a caller that knows only the pid asks it. The
 * same-process ask still has to go through the named object, because that is
 * the only way to tell this apart from writing a variable.
 *
 * On POSIX the three calls are the documented no-ops -- SIGTERM is that
 * platform's graceful stop -- so the test asserts the no-op answer instead of
 * pretending a channel is there. A test that passes either way would prove
 * nothing about either platform.
 */
#include <stdio.h>

#include "runtime.h"

int main(void) {
    int failures = 0;
#ifdef _WIN32
    DWORD own = GetCurrentProcessId();
    if (orbit_stop_channel_ask((orbit_int)own) == 1) {
        printf("FAILED ask before any channel is open succeeded\n");
        failures++;
    }
    if (orbit_stop_channel_open(0) != 1) {
        printf("FAILED open of this process's channel\n");
        failures++;
    }
    if (orbit_stop_channel_open(0) != 1) {
        printf("FAILED second open is not idempotent\n");
        failures++;
    }
    if (orbit_stop_channel_poll() != 0) {
        printf("FAILED a fresh channel already reads as a stop request\n");
        failures++;
    }
    if (orbit_stop_channel_ask((orbit_int)own) != 1) {
        printf("FAILED ask of pid %lu\n", (unsigned long)own);
        failures++;
    }
    if (orbit_stop_channel_poll() != 1) {
        printf("FAILED the ask did not reach the channel that was opened\n");
        failures++;
    }
    /* A manual-reset event keeps the request once set: the server's loop must
     * see it on every poll until the process exits, not once. */
    if (orbit_stop_channel_poll() != 1) {
        printf("FAILED the request was consumed by the first poll\n");
        failures++;
    }
#else
    if (orbit_stop_channel_open(0) != 0) {
        printf("FAILED POSIX open must answer 0: SIGTERM is the stop there\n");
        failures++;
    }
    if (orbit_stop_channel_poll() != 0) {
        printf("FAILED POSIX poll must answer 0\n");
        failures++;
    }
    if (orbit_stop_channel_ask((orbit_int)getpid()) != 0) {
        printf("FAILED POSIX ask must answer 0\n");
        failures++;
    }
#endif
    /* pid <= 0 is "this process" for open and never a target for ask, or the
     * stopper that has no pid would ask every channel on the machine. */
    if (orbit_stop_channel_ask(0) != 0) {
        printf("FAILED ask(0) must refuse to name a process\n");
        failures++;
    }
    if (orbit_stop_channel_ask(-1) != 0) {
        printf("FAILED ask(-1) must refuse a negative pid\n");
        failures++;
    }
    if (failures == 0) printf("ok stop channel: open, poll, ask, repeat\n");
    return failures == 0 ? 0 : 1;
}
