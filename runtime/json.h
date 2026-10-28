/* Interface of runtime/json.c (generated split; edit by hand from here). */
#ifndef ORBIT_RT_JSON_H
#define ORBIT_RT_JSON_H

#include "module_prelude.h"

#include "types.h"
#include "arena.h"

#include "arena.h"
#include "types.h"
#include "collections.h"
#include "inline.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <errno.h>

typedef enum {
    ORBIT_VAL_NULL = 0,
    ORBIT_VAL_INT,
    ORBIT_VAL_FLOAT,
    ORBIT_VAL_BOOL,
    ORBIT_VAL_STRING,
    ORBIT_VAL_OBJECT,
    ORBIT_VAL_LIST
} OrbitValueKind;

typedef struct {
    OrbitValueKind kind;
    uintptr_t raw;
} OrbitValue;

typedef struct {
    OrbitArena* arena;
    orbit_string* keys;
    OrbitValue* values;
    size_t count;
    size_t capacity;
} OrbitObject;
ORBIT_UNUSED OrbitObject* orbit_object_create(OrbitArena* arena);
ORBIT_UNUSED void orbit_object_set(OrbitObject* o, const char* key, OrbitValue v);
ORBIT_UNUSED void orbit_object_set_int(OrbitObject* o, const char* key, orbit_int v);
ORBIT_UNUSED void orbit_object_set_float(OrbitObject* o, const char* key, orbit_float v);
ORBIT_UNUSED void orbit_object_set_bool(OrbitObject* o, const char* key, orbit_bool v);
ORBIT_UNUSED void orbit_object_set_string(OrbitObject* o, const char* key, const char* v);
ORBIT_UNUSED void orbit_object_set_object(OrbitObject* o, const char* key, OrbitObject* v);
ORBIT_UNUSED void orbit_object_set_list(OrbitObject* o, const char* key, const OrbitList* v);
ORBIT_UNUSED OrbitValue orbit_object_get(OrbitObject* o, const char* key);
ORBIT_UNUSED orbit_int orbit_object_get_int(OrbitObject* o, const char* key);
ORBIT_UNUSED orbit_float orbit_object_get_float(OrbitObject* o, const char* key);
ORBIT_UNUSED orbit_bool orbit_object_get_bool(OrbitObject* o, const char* key);
ORBIT_UNUSED const char* orbit_object_get_string(OrbitObject* o, const char* key);
ORBIT_UNUSED OrbitObject* orbit_object_get_object(OrbitObject* o, const char* key);
ORBIT_UNUSED const OrbitList* orbit_object_get_list(OrbitObject* o, const char* key);
ORBIT_UNUSED const char* orbit_object_get_raw(OrbitObject* o, const char* key);

/* ── JSON parse ───────────────────────────────────────────────────────────
 *
 * Strict recursive descent over the grammar (objects, arrays, strings with
 * escapes, numbers, true/false/null; no comments, no trailing commas, no
 * NaN/Infinity, no leading zeros), producing typed OrbitObjects: ints stay
 * ints and nesting stays nested, which is what the substring reader in
 * runtime/builtins.c cannot do. Malformed input is err, never a partial
 * object and never abort: the loud exits elsewhere in this file are for a
 * program that mistyped its own field, not for text that arrived broken.
 *
 * Three representation limits, all refused loudly and stated in
 * std/json/json.orb rather than discovered:
 *   - arrays must be homogeneous (the list slots carry no per-slot tag,
 *     so a mixed array has nowhere to record its second kind);
 *   - null array elements have nowhere to go for the same reason (null
 *     object fields are fine: object slots are tagged);
 *   - nested arrays have no indexed getter on the other side.
 * Duplicate keys overwrite keeping first position (orbit_object_set);
 * past 64 nesting levels the document is refused, not recursed. */

#define ORBIT_JSON_MAX_DEPTH 64

typedef enum {
    J_NULL,
    J_INT,
    J_FLOAT,
    J_BOOL,
    J_STR,
    J_OBJ,
    J_ARR
} JsonKind;

typedef struct {
    JsonKind kind;
    orbit_int i;
    orbit_float f;
    orbit_bool b;
    const char* s;
    OrbitObject* o;
    OrbitList* l;
} JsonVal;

typedef struct {
    OrbitArena* arena;
    const char* err;
} JsonParse;
ORBIT_UNUSED OrbitResult orbit_json_parse(OrbitArena* arena, const char* text);
ORBIT_UNUSED orbit_int orbit_json_array_len(OrbitObject* o, const char* key);
ORBIT_UNUSED orbit_int orbit_json_array_get_int(OrbitObject* o, const char* key, orbit_int idx);
ORBIT_UNUSED orbit_float orbit_json_array_get_float(OrbitObject* o, const char* key, orbit_int idx);
ORBIT_UNUSED orbit_bool orbit_json_array_get_bool(OrbitObject* o, const char* key, orbit_int idx);
ORBIT_UNUSED const char* orbit_json_array_get_string(OrbitObject* o, const char* key, orbit_int idx);
ORBIT_UNUSED OrbitObject* orbit_json_array_get_object(OrbitObject* o, const char* key, orbit_int idx);

/* ── JSON ─────────────────────────────────────────────────────────────────
 *
 * A growable buffer, because the length is not knowable up front: it depends
 * on the values, and the values are only known while writing them. The arena
 * is the only allocator, so growth copies forward and abandons the old block.
 */

typedef struct {
    char* data;
    size_t len;
    size_t cap;
    OrbitArena* arena;
} OrbitJsonBuf;
ORBIT_UNUSED const char* orbit_object_to_json(OrbitArena* arena, OrbitObject* o);

#endif
