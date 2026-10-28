/* Interface of runtime/selfhost.c (generated split; edit by hand from here). */
#ifndef ORBIT_RT_SELFHOST_H
#define ORBIT_RT_SELFHOST_H

#include "module_prelude.h"

#include "types.h"
#include "collections.h"
#include "file.h"
#include "os.h"

#include "types.h"
#include "arena.h"
#include "os.h"
#include "file.h"
#include "crt_compat.h"
#include "collections.h"
#include <stdlib.h>
orbit_int orbit_os_argc_selfhost(void);
orbit_string orbit_os_argv_selfhost(orbit_int index);
orbit_string orbit_float_to_string_selfhost(orbit_float value);
orbit_string orbit_os_exec_selfhost(orbit_string command);
orbit_int orbit_os_spawn_selfhost(orbit_string command);
orbit_int orbit_os_run_timeout_selfhost(orbit_string command, orbit_int timeout_ms, orbit_string capture_path);
orbit_int orbit_os_spawn_bg_selfhost(orbit_string command, orbit_string logfile);
orbit_int orbit_os_kill_selfhost(orbit_int pid, orbit_int mode);
orbit_string orbit_os_env_selfhost(orbit_string var_name);
orbit_string orbit_os_cwd_selfhost(void);
orbit_string orbit_os_temp_dir_selfhost(void);
void orbit_os_exit_selfhost(orbit_int code);
void orbit_os_write_stderr_selfhost(orbit_string content);
orbit_string orbit_file_read_selfhost(orbit_string path);
bool orbit_file_write_selfhost(orbit_string path, orbit_string content);
OrbitList* orbit_file_list_dir_selfhost(orbit_string path);

/* Used by orbit_string_hash_selfhost below. */
orbit_int orbit_string_char_at_selfhost(orbit_string s, orbit_int index);
bool orbit_os_mkdir_selfhost(orbit_string path);
orbit_int orbit_string_cmp_selfhost(orbit_string a, orbit_string b);
orbit_string orbit_string_hash_selfhost(orbit_string s);
orbit_string orbit_int_to_string_selfhost(orbit_int value);
orbit_int orbit_string_char_at_selfhost(orbit_string s, orbit_int index);
orbit_string orbit_string_from_char_selfhost(orbit_int code);
orbit_string orbit_cbuf_create_selfhost(void);
void orbit_cbuf_append_selfhost(orbit_string buf, orbit_string s);
orbit_string orbit_cbuf_build_selfhost(orbit_string buf);
orbit_string orbit_mem_report_selfhost(void);

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
