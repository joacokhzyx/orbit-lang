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

// Create wrapper functions with original names (no arena parameter)
// These will be used when compiling the self-hosted compiler

// OS functions - wrappers that use global arena
orbit_int orbit_os_argc_selfhost(void) {
    return (orbit_os_argc)();
}

orbit_string orbit_os_argv_selfhost(orbit_int index) {
    return (orbit_os_argv)(orbit_arena_get_global(), index);
}

orbit_string orbit_os_exec_selfhost(orbit_string command) {
    return (orbit_os_exec)(orbit_arena_get_global(), command);
}

orbit_string orbit_os_env_selfhost(orbit_string var_name) {
    return (orbit_os_env)(orbit_arena_get_global(), var_name);
}

void orbit_os_exit_selfhost(orbit_int code) {
    (orbit_os_exit)(code);
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

// String/Int conversion helper
orbit_string orbit_int_to_string_selfhost(orbit_int value) {
    return (orbit_int_to_string)(orbit_arena_get_global(), value);
}

// Define macros to redirect the simple names to the selfhost versions
// when compiling selfhost code
#ifdef ORBIT_SELFHOST_BUILD
#define orbit_os_argc()           orbit_os_argc_selfhost()
#define orbit_os_argv(idx)        orbit_os_argv_selfhost(idx)
#define orbit_os_exec(cmd)        orbit_os_exec_selfhost(cmd)
#define orbit_os_env(var)         orbit_os_env_selfhost(var)
#define orbit_os_exit(code)       orbit_os_exit_selfhost(code)
#define orbit_file_read(path)     orbit_file_read_selfhost(path)
#define orbit_file_write(p, c)    orbit_file_write_selfhost(p, c)
#define orbit_int_to_string(val)  orbit_int_to_string_selfhost(val)
#endif

#endif
