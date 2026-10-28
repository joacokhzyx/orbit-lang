/* Interface of runtime/file.c (generated split; edit by hand from here). */
#ifndef ORBIT_RT_FILE_H
#define ORBIT_RT_FILE_H

#include "module_prelude.h"

#include "types.h"
#include "arena.h"

#include <stdio.h>
#include <stdlib.h>
#include "arena.h"
#include "types.h"
#include "crt_compat.h"
#include "collections.h"

#ifdef _WIN32
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
#  include <sys/stat.h>
#else
#  include <dirent.h>
#  include <sys/stat.h>
#  include <unistd.h>
#endif
OrbitResult orbit_file_read(OrbitArena* arena, const char* filename);
bool orbit_file_write(const char* filename, const char* content);
OrbitList* orbit_file_list_dir(OrbitArena* arena, const char* path);
bool orbit_file_exists(const char* filename);
bool orbit_file_delete(const char* filename);
bool orbit_path_is_dir(const char* path);
bool orbit_file_remove_dir(const char* path);

#endif
