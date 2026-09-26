/**
 * @file  file.c
 * @brief File I/O helpers for reading and writing files in Orbit programs.
 *
 * Thin wrappers around POSIX/Win32 file APIs.  All returned buffers are
 * arena-allocated so no explicit free is required.
 */
#ifndef ORBIT_FILE_H
#define ORBIT_FILE_H

#include <stdio.h>
#include <stdlib.h>
#include "arena.c"
#include "types.c"
#include "crt_compat.h"
#include "collections.c"

#ifdef _WIN32
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
#  include <sys/stat.h>
#else
#  include <dirent.h>
#  include <sys/stat.h>
#endif

OrbitResult orbit_file_read(OrbitArena* arena, const char* filename) {
    FILE* f = orbit_fopen(filename, "rb");
    if (!f) return orbit_result_err(ORBIT_ERR_IO, "Failed to open file");

    /* A directory opens successfully in read mode on POSIX, and ftell on such a
     * handle reports LONG_MAX. `size + 1` then overflows to a negative long,
     * which becomes SIZE_MAX/2+1 as a size_t, and the allocation below asks for
     * 2^63 bytes. This was harmless by accident: the allocation used to fail,
     * the NULL came back as ORBIT_ERR_OUT_OF_MEMORY, and callers that probe a
     * path with orbit_file_read before deciding whether it is a directory
     * (`orbit fmt <dir>` does exactly that) read that as "not a file" and
     * carried on. Once allocation failure became loud (FMT-1) the same path
     * aborted the process, so the directory is rejected up front instead. */
    {
        int is_dir = 0;
#ifdef _WIN32
        struct _stat st;
        if (_fstat(_fileno(f), &st) == 0 && (st.st_mode & _S_IFDIR)) is_dir = 1;
#else
        struct stat st;
        if (fstat(fileno(f), &st) == 0 && S_ISDIR(st.st_mode)) is_dir = 1;
#endif
        if (is_dir) {
            fclose(f);
            return orbit_result_err(ORBIT_ERR_IO, "Path is a directory, not a file");
        }
    }

    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size < 0) {
        fclose(f);
        return orbit_result_err(ORBIT_ERR_IO, "Failed to determine file size");
    }

    char* content = orbit_alloc(arena, (size_t)size + 1);
    if (!content) {
        fclose(f);
        return orbit_result_err(ORBIT_ERR_OUT_OF_MEMORY, "Failed to allocate memory");
    }
    
    fread(content, 1, size, f);
    content[size] = 0;
    fclose(f);
    return orbit_result_ok(content);
}

/* Write `content` to `filename`, replacing it.
 *
 * `fopen(..., "wb")` truncates the target the moment it succeeds, so every
 * failure after that point has already destroyed whatever was there. The write
 * is therefore verified, not assumed: a short write (out of space, out of
 * handles, a NULL buffer) returns false, and the caller can report it. The
 * previous version returned true unconditionally, which let `orbit fmt` replace
 * a source file with a 0-byte file and still report success.
 *
 * Writing an empty string is a legitimate request and is honoured; deciding
 * that an empty result is not acceptable belongs to the caller.
 */
bool orbit_file_write(const char* filename, const char* content) {
    if (!filename) return false;
    if (!content) return false;

    size_t len = strlen(content);

    FILE* f = orbit_fopen(filename, "wb");
    if (!f) return false;

    if (len > 0) {
        size_t written = fwrite(content, 1, len, f);
        if (written != len) {
            fclose(f);
            return false;
        }
    }

    /* A failed flush means the bytes may never have reached the file, so it
     * counts as a failed write even though fwrite said otherwise. */
    if (fflush(f) != 0) {
        fclose(f);
        return false;
    }
    if (fclose(f) != 0) return false;
    return true;
}

OrbitList* orbit_file_list_dir(OrbitArena* arena, const char* path) {
    OrbitList* list = (OrbitList*)orbit_list_create(arena, sizeof(orbit_string), 16).value;
    if (!list) return list;

#ifdef _WIN32
    /* Build "path\*" pattern using arena allocation to avoid large stack frames. */
    size_t plen = 0;
    while (path[plen]) plen++;
    /* plen + 3: backslash + '*' + NUL */
    char* pattern = (char*)orbit_alloc(arena, plen + 3);
    if (!pattern) return list;
    for (size_t i = 0; i < plen; i++) pattern[i] = path[i];
    pattern[plen]     = '\\';
    pattern[plen + 1] = '*';
    pattern[plen + 2] = '\0';

    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pattern, &fd);
    if (h == INVALID_HANDLE_VALUE) return list;
    do {
        if (fd.cFileName[0] == '.') continue;
        size_t len = 0;
        while (fd.cFileName[len]) len++;
        char* str = (char*)orbit_alloc(arena, len + 1);
        if (str) {
            for (size_t i = 0; i < len; i++) str[i] = fd.cFileName[i];
            str[len] = '\0';
            orbit_string s = str;
            orbit_list_push(list, &s);
        }
    } while (FindNextFileA(h, &fd));
    FindClose(h);
#else
    DIR* d = opendir(path);
    if (!d) return list;
    
    struct dirent* dir;
    while ((dir = readdir(d)) != NULL) {
        if (dir->d_name[0] == '.') continue;
        
        size_t len = 0;
        while (dir->d_name[len]) len++;
        
        char* str = (char*)orbit_alloc(arena, len + 1);
        if (str) {
            for (size_t i = 0; i < len; i++) str[i] = dir->d_name[i];
            str[len] = '\0';
            orbit_string s = str;
            orbit_list_push(list, &s);
        }
    }
    
    closedir(d);
#endif
    return list;
}

bool orbit_file_exists(const char* filename) {
    FILE* f = orbit_fopen(filename, "rb");
    if (!f) return false;
    fclose(f);
    return true;
}

bool orbit_file_delete(const char* filename) {
    return remove(filename) == 0;
}

#endif
