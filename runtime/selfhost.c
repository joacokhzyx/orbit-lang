/**
 * @file  selfhost.c
 * @brief Wrappers for Orbit self-hosted compiler built-in functions
 *
 * The self-hosted compiler (compiler orb files) declares extern functions without
 * explicit arena parameters. These wrappers automatically use the global arena.
 */
#ifndef ORBIT_SELFHOST_C
#define ORBIT_SELFHOST_C

#include "types.c"
#include "arena.c"
#include "os.c"
#include "file.c"
#include "collections.c"
#include <stdlib.h>

// Create wrapper functions with original names (no arena parameter)
// These will be used when compiling the self-hosted compiler

// OS functions - wrappers that use global arena
orbit_int orbit_os_argc_selfhost(void) {
    return (orbit_os_argc)();
}

orbit_string orbit_os_argv_selfhost(orbit_int index) {
    return (orbit_os_argv)(orbit_arena_get_global(), index);
}

orbit_string orbit_float_to_string_selfhost(orbit_float value) {
    return (orbit_float_to_string)(orbit_arena_get_global(), value);
}

orbit_string orbit_os_exec_selfhost(orbit_string command) {
    return (orbit_os_exec)(orbit_arena_get_global(), command);
}

orbit_int orbit_os_spawn_selfhost(orbit_string command) {
    return (orbit_os_spawn)(command);
}

orbit_int orbit_os_spawn_bg_selfhost(orbit_string command, orbit_string logfile) {
    return (orbit_os_spawn_bg)(command, logfile);
}

orbit_int orbit_os_kill_selfhost(orbit_int pid, orbit_int mode) {
    return (orbit_os_kill)(pid, mode);
}

orbit_string orbit_os_env_selfhost(orbit_string var_name) {
    return (orbit_os_env)(orbit_arena_get_global(), var_name);
}

orbit_string orbit_os_cwd_selfhost(void) {
    return (orbit_os_cwd)(orbit_arena_get_global());
}

// Per-user scratch directory for compiler intermediates, or "" when the
// platform offers none. The compiler prefers $TEMP / $TMPDIR / $TMP and only
// falls back to this, so a build never drops a multi-megabyte C file into the
// user's working directory.
orbit_string orbit_os_temp_dir_selfhost(void) {
    static const char* vars[] = {"TEMP", "TMPDIR", "TMP", NULL};
    OrbitArena* a = orbit_arena_get_global();
    for (int i = 0; vars[i] != NULL; i++) {
        const char* v = getenv(vars[i]);
        if (v == NULL || v[0] == '\0') continue;
        size_t len = strlen(v);
        char* buf = (char*)orbit_alloc(a, len + 1);
        if (!buf) return "";
        memcpy(buf, v, len + 1);
        return buf;
    }
#if defined(_WIN32)
    /* No temp variable at all on Windows: report absence rather than guess a
     * path, so the caller keeps its documented working-directory behaviour. */
    return "";
#else
    return "/tmp";
#endif
}

void orbit_os_exit_selfhost(orbit_int code) {
    (orbit_os_exit)(code);
}

// Raw stderr writer: emits bytes verbatim (LF line endings, no CRLF translation)
// so self-host diagnostics are byte-identical to whatever the compiler wrote.
void orbit_os_write_stderr_selfhost(orbit_string content) {
    if (!content) return;
    size_t len = strlen(content);
    if (len == 0) return;
#ifdef _WIN32
    HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
    DWORD written = 0;
    WriteFile(h, content, (DWORD)len, &written, NULL);
#else
    fwrite(content, 1, len, stderr);
    fflush(stderr);
#endif
}

// File I/O functions
orbit_string orbit_file_read_selfhost(orbit_string path) {
    OrbitResult res = (orbit_file_read)(orbit_arena_get_global(), path);
    if (!res.ok) {
        return "";
    }
    return (orbit_string)res.value;
}

bool orbit_file_write_selfhost(orbit_string path, orbit_string content) {
    return (orbit_file_write)(path, content);
}

OrbitList* orbit_file_list_dir_selfhost(orbit_string path) {
    return (orbit_file_list_dir)(orbit_arena_get_global(), path);
}

// String/Int conversion helper
orbit_string orbit_int_to_string_selfhost(orbit_int value) {
    return (orbit_int_to_string)(orbit_arena_get_global(), value);
}

// O(1) character access: single indexed load, NO strlen, NO bounds check.
// Caller guarantees 0 <= index < len(s). Returns 0 when s is NULL.
orbit_int orbit_string_char_at_selfhost(orbit_string s, orbit_int index) {
    return s ? (unsigned char)s[index] : 0;
}

orbit_string orbit_string_from_char_selfhost(orbit_int code) {
    return orbit_string_from_char(orbit_arena_get_global(), code);
}

// Chunk buffer for the self-hosted code generator. Handles ride in
// `string`-typed Orbit locals (opaque pointers, never inspected as text)
// because the self-host `int` type is 32 bits.
orbit_string orbit_cbuf_create_selfhost(void) {
    OrbitCBuf* buf = orbit_cbuf_create(orbit_arena_get_global(), ORBIT_CBUF_INIT_CAP);
    if (!buf) return "";
    return (orbit_string)(void*)buf;
}

void orbit_cbuf_append_selfhost(orbit_string buf, orbit_string s) {
    if (!buf) return;
    orbit_cbuf_append((OrbitCBuf*)(void*)buf, s);
}

orbit_string orbit_cbuf_build_selfhost(orbit_string buf) {
    if (!buf) return "";
    return orbit_cbuf_build((OrbitCBuf*)(void*)buf);
}

// One-line memory snapshot of the global arena for the Phase-1 memory
// report (enabled by ORBIT_MEM_REPORT=1). Allocation-free on the opt-out
// path: a single getenv. Format: "used=12MB peak=34MB allocs=5678".
orbit_string orbit_mem_report_selfhost(void) {
    OrbitArena* a = orbit_arena_get_global();
    uint64_t allocs;
    char* out;
    if (!a) return "";
    allocs = orbit_arena_alloc_count(a);
    if (allocs > 2147483647ull) allocs = 2147483647ull;
    out = (char*)orbit_alloc(a, 96);
    if (!out) return "";
    snprintf(out, 96, "used=%uMB peak=%uMB allocs=%u",
             (unsigned)(orbit_arena_used(a) >> 20),
             (unsigned)(orbit_arena_peak_used(a) >> 20),
             (unsigned)allocs);
    return out;
}

// Define macros to redirect the simple names to the selfhost versions
// when compiling selfhost code
#ifdef ORBIT_SELFHOST_BUILD
#define orbit_os_argc()           orbit_os_argc_selfhost()
#define orbit_os_argv(idx)        orbit_os_argv_selfhost(idx)
#define orbit_os_exec(cmd)        orbit_os_exec_selfhost(cmd)
#define orbit_os_spawn(cmd)       orbit_os_spawn_selfhost(cmd)
#define orbit_os_spawn_bg(c, l)   orbit_os_spawn_bg_selfhost(c, l)
#define orbit_os_kill(pid, mode)  orbit_os_kill_selfhost(pid, mode)
#define orbit_os_env(var)         orbit_os_env_selfhost(var)
#define orbit_os_exit(code)       orbit_os_exit_selfhost(code)
#define orbit_file_read(path)     orbit_file_read_selfhost(path)
#define orbit_file_write(p, c)    orbit_file_write_selfhost(p, c)
#define orbit_int_to_string(val)  orbit_int_to_string_selfhost(val)
#endif

#endif
