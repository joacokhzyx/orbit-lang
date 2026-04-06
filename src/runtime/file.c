#ifndef ORBIT_FILE_H
#define ORBIT_FILE_H

#include <stdio.h>
#include <stdlib.h>
#include "arena.c"
#include "types.c"

orbit_string orbit_file_read(OrbitArena* arena, const char* filename) {
    FILE* f = fopen(filename, "rb");
    if (!f) return NULL;
    
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    
    char* content = orbit_alloc(arena, size + 1);
    if (!content) {
        fclose(f);
        return NULL;
    }
    
    fread(content, 1, size, f);
    content[size] = 0;
    fclose(f);
    return content;
}

bool orbit_file_write(const char* filename, const char* content) {
    FILE* f = fopen(filename, "wb");
    if (!f) return false;
    
    fprintf(f, "%s", content);
    fclose(f);
    return true;
}

#endif
