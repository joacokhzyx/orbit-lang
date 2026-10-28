#ifndef ORBIT_RT_CONSOLE_C
#define ORBIT_RT_CONSOLE_C

#include "module_prelude.h"
#include "console.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#endif

#ifdef _WIN32
static void orbit_console_enable_escapes(DWORD which) {
    HANDLE h = GetStdHandle(which);
    DWORD mode = 0;
    if (h != INVALID_HANDLE_VALUE && h != NULL && GetConsoleMode(h, &mode)) {
        SetConsoleMode(h, mode | 0x0001 | 0x0004);
    }
}

void orbit_console_init(void) {
    HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
    if (hOut != INVALID_HANDLE_VALUE) {
        orbit_console_enable_escapes(STD_OUTPUT_HANDLE);
        SetConsoleOutputCP(65001);
    }
    orbit_console_enable_escapes(STD_ERROR_HANDLE);
}
#else
void orbit_console_init(void) {}
#endif

void orbit_print_string(const char* s) {
    fputs(s ? s : "(null)", stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

/* The terminal UI below is the compiler's. A program built for users has no
 * use for it, and the archive member would grow every program that prints, so
 * it exists only in the build that carries the compiler (ORBIT_WITH_EXEC). */
#ifdef ORBIT_WITH_EXEC

/* Capabilities of stdout (index 1) and stderr (index 2), probed once. */
static int orbit_ui_caps_value[3];
static int orbit_ui_caps_ready;

static const char orbit_ui_restore_seq[] = "\x1b[?25h\x1b[0m";

#ifdef _WIN32
static void orbit_ui_probe(void) {
    int any_console = 0;
    if (orbit_ui_caps_ready) return;
    orbit_ui_caps_ready = 1;
    for (int fd = 1; fd <= 2; fd++) {
        HANDLE h = GetStdHandle(fd == 1 ? STD_OUTPUT_HANDLE : STD_ERROR_HANDLE);
        DWORD mode = 0;
        int caps = 0;
        if (h != INVALID_HANDLE_VALUE && h != NULL && GetConsoleMode(h, &mode)) {
            caps |= 1;
            any_console = 1;
            if ((mode & 0x0004) || SetConsoleMode(h, mode | 0x0001 | 0x0004)) caps |= 2;
        }
        orbit_ui_caps_value[fd] = caps;
    }
    if (any_console && (GetConsoleOutputCP() == 65001 || (SetConsoleOutputCP(65001) && GetConsoleOutputCP() == 65001))) {
        for (int fd = 1; fd <= 2; fd++) {
            if (orbit_ui_caps_value[fd] & 1) orbit_ui_caps_value[fd] |= 4;
        }
    }
}

#else
static int orbit_ui_env_has_utf8(const char* name) {
    const char* v = getenv(name);
    if (!v) return 0;
    for (const char* p = v; *p; p++) {
        if ((p[0] | 32) == 'u' && (p[1] | 32) == 't' && (p[2] | 32) == 'f') {
            if (p[3] == '8' || (p[3] == '-' && p[4] == '8')) return 1;
        }
    }
    return 0;
}

static void orbit_ui_probe(void) {
    if (orbit_ui_caps_ready) return;
    orbit_ui_caps_ready = 1;
    const char* locale = getenv("LC_ALL");
    if (!locale || !*locale) locale = getenv("LC_CTYPE") && *getenv("LC_CTYPE") ? "LC_CTYPE" : "LANG";
    else locale = "LC_ALL";
    int utf8 = orbit_ui_env_has_utf8(locale);
    for (int fd = 1; fd <= 2; fd++) {
        if (isatty(fd)) orbit_ui_caps_value[fd] = 1 | 2 | (utf8 ? 4 : 0);
    }
}

#endif


/* Bit 1: the stream is a console. Bit 2: ANSI escapes are enabled on that very
 * handle (set here, not assumed). Bit 4: the console takes UTF-8 output. */
orbit_int orbit_ui_caps(orbit_int fd) {
    orbit_ui_probe();
    if (fd < 1 || fd > 2) return 0;
    return orbit_ui_caps_value[fd];
}

orbit_int orbit_ui_width(orbit_int fd) {
    if (fd < 1 || fd > 2) return 0;
#ifdef _WIN32
    HANDLE h = GetStdHandle(fd == 1 ? STD_OUTPUT_HANDLE : STD_ERROR_HANDLE);
    CONSOLE_SCREEN_BUFFER_INFO info;
    if (h != INVALID_HANDLE_VALUE && h != NULL && GetConsoleScreenBufferInfo(h, &info)) {
        return (orbit_int)(info.srWindow.Right - info.srWindow.Left + 1);
    }
    return 0;
#else
    struct winsize ws;
    if (ioctl((int)fd, TIOCGWINSZ, &ws) == 0) return (orbit_int)ws.ws_col;
    return 0;
#endif
}

/* The .text size of a PE image, or -1 for anything else. The build screen
 * quotes it so a size change shows next to the time. */
orbit_int orbit_ui_text_size(orbit_string path) {
    if (!path) return -1;
    FILE* f = fopen(path, "rb");
    if (!f) return -1;
    orbit_int result = -1;
    unsigned char dos[64];
    if (fread(dos, 1, 64, f) == 64 && dos[0] == 'M' && dos[1] == 'Z') {
        unsigned long pe = (unsigned long)dos[60] | ((unsigned long)dos[61] << 8) | ((unsigned long)dos[62] << 16) | ((unsigned long)dos[63] << 24);
        unsigned char hdr[24];
        if (fseek(f, (long)pe, SEEK_SET) == 0 && fread(hdr, 1, 24, f) == 24 && memcmp(hdr, "PE\0\0", 4) == 0) {
            int nsec = hdr[6] | (hdr[7] << 8);
            long optsz = hdr[20] | (hdr[21] << 8);
            if (fseek(f, (long)pe + 24 + optsz, SEEK_SET) == 0) {
                for (int i = 0; i < nsec; i++) {
                    unsigned char sec[40];
                    if (fread(sec, 1, 40, f) != 40) break;
                    if (memcmp(sec, ".text", 6) == 0) {
                        result = (orbit_int)((unsigned long)sec[8] | ((unsigned long)sec[9] << 8) | ((unsigned long)sec[10] << 16) | ((unsigned long)sec[11] << 24));
                        break;
                    }
                }
            }
        }
    }
    fclose(f);
    return result;
}

/* Animation. One thread repaints a block of lines on stderr about 12 times a
 * second. The block is a template the compiler composes: byte 0x01 becomes the
 * orbital frame (two cells) and byte 0x02 the milliseconds the active stage has
 * run (six cells, right-aligned). The cursor is hidden while the thread runs
 * and every exit path writes orbit_ui_restore_seq: stop, exit, Ctrl-C, signals
 * and the unhandled-exception filter. */

#define ORBIT_UI_FRAME_MS 83

static char* orbit_ui_template;
static int orbit_ui_painted;
static int orbit_ui_running;
static int orbit_ui_ascii;
static volatile int orbit_ui_cursor_hidden;
static volatile int orbit_ui_halt;
static unsigned orbit_ui_frame_no;
static unsigned long long orbit_ui_stage_started;
static int orbit_ui_hooks_installed;

#ifdef _WIN32
static CRITICAL_SECTION orbit_ui_lock;
static int orbit_ui_lock_ready;
static HANDLE orbit_ui_event;
static HANDLE orbit_ui_thread;
static LPTOP_LEVEL_EXCEPTION_FILTER orbit_ui_prev_filter;
static unsigned long long orbit_ui_now_ms(void) { return (unsigned long long)GetTickCount64(); }
static void orbit_ui_lock_take(void) { EnterCriticalSection(&orbit_ui_lock); }
static void orbit_ui_lock_drop(void) { LeaveCriticalSection(&orbit_ui_lock); }
static void orbit_ui_write(const char* data, size_t len) {
    HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
    DWORD written = 0;
    if (len > 0) WriteFile(h, data, (DWORD)len, &written, NULL);
}
#else
static pthread_mutex_t orbit_ui_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t orbit_ui_cond = PTHREAD_COND_INITIALIZER;
static pthread_t orbit_ui_thread;
static unsigned long long orbit_ui_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (unsigned long long)ts.tv_sec * 1000ULL + (unsigned long long)ts.tv_nsec / 1000000ULL;
}
static void orbit_ui_lock_take(void) { pthread_mutex_lock(&orbit_ui_lock); }
static void orbit_ui_lock_drop(void) { pthread_mutex_unlock(&orbit_ui_lock); }
static void orbit_ui_write(const char* data, size_t len) {
    while (len > 0) {
        ssize_t n = write(2, data, len);
        if (n <= 0) break;
        data += n;
        len -= (size_t)n;
    }
}
#endif

/* Writes the terminal back to normal from any context: no allocation, no lock. */
static void orbit_ui_restore_terminal(void) {
    if (!orbit_ui_cursor_hidden) return;
    orbit_ui_cursor_hidden = 0;
    orbit_ui_write(orbit_ui_restore_seq, sizeof(orbit_ui_restore_seq) - 1);
}

static const char* orbit_ui_frames_unicode[4] = {"\xC2\xB7\xE2\x97\x9C", "\xC2\xB7\xE2\x97\x9D", "\xC2\xB7\xE2\x97\x9E", "\xC2\xB7\xE2\x97\x9F"};
static const char* orbit_ui_frames_ascii[4] = {" |", " /", " -", " \\"};

/* Expands the template into a malloc'd buffer; *lines receives its newline count. */
static char* orbit_ui_expand(const char* tpl, unsigned frame, unsigned long long active_ms, int* lines, size_t* out_len) {
    size_t cap = strlen(tpl) * 2 + 256;
    char* buf = (char*)malloc(cap);
    size_t n = 0;
    int nl = 0;
    if (!buf) return NULL;
    for (const char* p = tpl; *p; p++) {
        const char* piece = NULL;
        char num[32];
        if (*p == 1) {
            piece = orbit_ui_ascii ? orbit_ui_frames_ascii[frame & 3] : orbit_ui_frames_unicode[frame & 3];
        } else if (*p == 2) {
            snprintf(num, sizeof(num), "%6llu", active_ms);
            piece = num;
        }
        size_t add = piece ? strlen(piece) : 4;
        if (n + add + 8 > cap) {
            cap = cap * 2 + add;
            char* grown = (char*)realloc(buf, cap);
            if (!grown) { free(buf); return NULL; }
            buf = grown;
        }
        if (piece) {
            memcpy(buf + n, piece, add);
            n += add;
        } else if (*p == '\n') {
            memcpy(buf + n, "\x1b[K\n", 4);
            n += 4;
            nl++;
        } else {
            buf[n++] = *p;
        }
    }
    buf[n] = '\0';
    *lines = nl;
    *out_len = n;
    return buf;
}

/* Replaces the painted block with the template as it reads now. */
static void orbit_ui_paint(unsigned frame) {
    if (!orbit_ui_template) return;
    int lines = 0;
    size_t len = 0;
    unsigned long long active = orbit_ui_now_ms() - orbit_ui_stage_started;
    char* body = orbit_ui_expand(orbit_ui_template, frame, active, &lines, &len);
    if (!body) return;
    char up[24];
    int upn = 0;
    if (orbit_ui_painted > 0) upn = snprintf(up, sizeof(up), "\x1b[%dF", orbit_ui_painted);
    char* all = (char*)malloc((size_t)upn + len + 1);
    if (all) {
        memcpy(all, up, (size_t)upn);
        memcpy(all + upn, body, len);
        orbit_ui_write(all, (size_t)upn + len);
        free(all);
    }
    orbit_ui_painted = lines;
    free(body);
}

#ifdef _WIN32
static DWORD WINAPI orbit_ui_thread_main(LPVOID arg) {
    (void)arg;
    while (!orbit_ui_halt) {
        orbit_ui_lock_take();
        if (!orbit_ui_halt) orbit_ui_paint(orbit_ui_frame_no++);
        orbit_ui_lock_drop();
        WaitForSingleObject(orbit_ui_event, ORBIT_UI_FRAME_MS);
    }
    return 0;
}

static BOOL WINAPI orbit_ui_ctrl_handler(DWORD type) {
    (void)type;
    orbit_ui_halt = 1;
    orbit_ui_restore_terminal();
    return FALSE;
}

static LONG WINAPI orbit_ui_exception_filter(EXCEPTION_POINTERS* ep) {
    orbit_ui_halt = 1;
    orbit_ui_restore_terminal();
    if (orbit_ui_prev_filter) return orbit_ui_prev_filter(ep);
    return EXCEPTION_CONTINUE_SEARCH;
}
#else
static void* orbit_ui_thread_main(void* arg) {
    (void)arg;
    orbit_ui_lock_take();
    while (!orbit_ui_halt) {
        orbit_ui_paint(orbit_ui_frame_no++);
        struct timespec until;
        clock_gettime(CLOCK_REALTIME, &until);
        until.tv_nsec += ORBIT_UI_FRAME_MS * 1000000L;
        until.tv_sec += until.tv_nsec / 1000000000L;
        until.tv_nsec %= 1000000000L;
        pthread_cond_timedwait(&orbit_ui_cond, &orbit_ui_lock, &until);
    }
    orbit_ui_lock_drop();
    return NULL;
}

static void orbit_ui_signal_handler(int sig) {
    orbit_ui_halt = 1;
    orbit_ui_restore_terminal();
    signal(sig, SIG_DFL);
    raise(sig);
}
#endif

static void orbit_ui_join(void) {
    if (!orbit_ui_running) return;
    orbit_ui_halt = 1;
#ifdef _WIN32
    SetEvent(orbit_ui_event);
    WaitForSingleObject(orbit_ui_thread, 2000);
    CloseHandle(orbit_ui_thread);
    CloseHandle(orbit_ui_event);
#else
    pthread_mutex_lock(&orbit_ui_lock);
    pthread_cond_signal(&orbit_ui_cond);
    pthread_mutex_unlock(&orbit_ui_lock);
    pthread_join(orbit_ui_thread, NULL);
#endif
    orbit_ui_running = 0;
}

static void orbit_ui_at_exit(void) {
    orbit_ui_join();
    orbit_ui_restore_terminal();
}

static char* orbit_ui_copy(const char* s) {
    size_t n = s ? strlen(s) : 0;
    char* c = (char*)malloc(n + 1);
    if (!c) return NULL;
    if (n) memcpy(c, s, n);
    c[n] = '\0';
    return c;
}

/* Starts the repaint thread with `block` as the first frame. `flags` bit 0
 * selects the ASCII frames. Returns 1 when the thread runs and 0 when it could
 * not start; the caller then prints final frames only. */
orbit_int orbit_ui_anim_start(orbit_string block, orbit_int flags) {
    if (orbit_ui_running) return 0;
#ifdef _WIN32
    if (!orbit_ui_lock_ready) {
        InitializeCriticalSection(&orbit_ui_lock);
        orbit_ui_lock_ready = 1;
    }
#endif
    free(orbit_ui_template);
    orbit_ui_template = orbit_ui_copy(block);
    if (!orbit_ui_template) return 0;
    orbit_ui_ascii = (flags & 1) != 0;
    orbit_ui_painted = 0;
    orbit_ui_frame_no = 0;
    orbit_ui_halt = 0;
    orbit_ui_stage_started = orbit_ui_now_ms();
    if (!orbit_ui_hooks_installed) {
        orbit_ui_hooks_installed = 1;
        atexit(orbit_ui_at_exit);
#ifdef _WIN32
        SetConsoleCtrlHandler(orbit_ui_ctrl_handler, TRUE);
        orbit_ui_prev_filter = SetUnhandledExceptionFilter(orbit_ui_exception_filter);
#else
        signal(SIGINT, orbit_ui_signal_handler);
        signal(SIGTERM, orbit_ui_signal_handler);
        signal(SIGSEGV, orbit_ui_signal_handler);
        signal(SIGABRT, orbit_ui_signal_handler);
#endif
    }
    orbit_ui_write("\x1b[?25l", 6);
    orbit_ui_cursor_hidden = 1;
#ifdef _WIN32
    orbit_ui_event = CreateEvent(NULL, FALSE, FALSE, NULL);
    orbit_ui_thread = CreateThread(NULL, 0, orbit_ui_thread_main, NULL, 0, NULL);
    if (!orbit_ui_thread) {
        CloseHandle(orbit_ui_event);
        orbit_ui_restore_terminal();
        return 0;
    }
#else
    if (pthread_create(&orbit_ui_thread, NULL, orbit_ui_thread_main, NULL) != 0) {
        orbit_ui_restore_terminal();
        return 0;
    }
#endif
    orbit_ui_running = 1;
    return 1;
}

/* A stage began: `block` is the whole template for it. The repaint thread picks
 * it up on its next tick and the active-stage clock restarts. */
orbit_int orbit_ui_anim_stage(orbit_string block) {
    if (!orbit_ui_running) return 0;
    char* next = orbit_ui_copy(block);
    if (!next) return 0;
    orbit_ui_lock_take();
    char* old = orbit_ui_template;
    orbit_ui_template = next;
    orbit_ui_stage_started = orbit_ui_now_ms();
    orbit_ui_lock_drop();
    free(old);
    return 1;
}

/* Stops the thread, draws `final_block` over the painted block and shows the cursor. */
orbit_int orbit_ui_anim_stop(orbit_string final_block) {
    if (!orbit_ui_running) return 0;
    orbit_ui_join();
    free(orbit_ui_template);
    orbit_ui_template = orbit_ui_copy(final_block);
    orbit_ui_paint(0);
    free(orbit_ui_template);
    orbit_ui_template = NULL;
    orbit_ui_painted = 0;
    orbit_ui_restore_terminal();
    return 1;
}

#endif
#endif
