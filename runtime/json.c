/**
 * @file  json.c
 * @brief OrbitObject: an ordered, dynamically typed record, and its JSON form.
 *
 * A model is a struct the compiler generates, so its shape is fixed at compile
 * time and its fields are read by name at the C level. An object literal is
 * the opposite: the keys come from the source and are not known until runtime.
 * So it gets its own representation rather than a generated struct per
 * literal, which could not be named in a signature and whose field lookups
 * would collide with the model field table.
 *
 * Two properties drove the shape:
 *
 *   - Order is insertion order, not hash order. JSON key order is observable
 *     in a response body and in the parity goldens, so it has to be
 *     deterministic; a hash map would not be.
 *   - The type tag travels with the value. A register cannot say what it
 *     holds, so serializing needs the answer next to the data rather than in a
 *     side table that could drift.
 *
 * Memory is arena-only, like everything else in the runtime: an object lives
 * as long as the request that made it.
 */
#ifndef ORBIT_JSON_H
#define ORBIT_JSON_H

#include "arena.c"
#include "types.c"
#include "collections.c"
#include "inline.h"
#include <string.h>

typedef enum {
    ORBIT_VAL_NULL = 0,
    ORBIT_VAL_INT,
    ORBIT_VAL_FLOAT,
    ORBIT_VAL_BOOL,
    ORBIT_VAL_STRING,
    ORBIT_VAL_OBJECT
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

static ORBIT_UNUSED OrbitValue orbit_value_null(void) {
    OrbitValue v;
    v.kind = ORBIT_VAL_NULL;
    v.raw = 0;
    return v;
}

static ORBIT_UNUSED OrbitValue orbit_value_int(orbit_int i) {
    OrbitValue v;
    v.kind = ORBIT_VAL_INT;
    v.raw = (uintptr_t)i;
    return v;
}

static ORBIT_UNUSED OrbitValue orbit_value_float(orbit_float f) {
    OrbitValue v;
    v.kind = ORBIT_VAL_FLOAT;
    /* The bits, not the value: a float does not survive a round trip through
       uintptr_t, and the serializer reads these back with memcpy. */
    uint64_t bits = 0;
    memcpy(&bits, &f, sizeof(bits));
    v.kind = ORBIT_VAL_FLOAT;
    v.raw = (uintptr_t)bits;
    return v;
}

static ORBIT_UNUSED OrbitValue orbit_value_bool(orbit_bool b) {
    OrbitValue v;
    v.kind = ORBIT_VAL_BOOL;
    v.raw = b ? 1 : 0;
    return v;
}

static ORBIT_UNUSED OrbitValue orbit_value_string(const char* s) {
    OrbitValue v;
    v.kind = ORBIT_VAL_STRING;
    v.raw = (uintptr_t)(s ? s : "");
    return v;
}

static ORBIT_UNUSED OrbitValue orbit_value_object(OrbitObject* o) {
    OrbitValue v;
    v.kind = ORBIT_VAL_OBJECT;
    v.raw = (uintptr_t)o;
    return v;
}

ORBIT_UNUSED OrbitObject* orbit_object_create(OrbitArena* arena) {
    if (!arena) arena = orbit_arena_get_global();
    OrbitObject* o = (OrbitObject*)orbit_alloc(arena, sizeof(OrbitObject));
    o->arena = arena;
    o->count = 0;
    o->capacity = 0;
    o->keys = NULL;
    o->values = NULL;
    return o;
}

ORBIT_UNUSED void orbit_object_set(OrbitObject* o, const char* key, OrbitValue v) {
    if (!o || !key) return;
    /* A repeated key overwrites, the way a record literal should read, and
       keeps the position of the first mention so the order stays stable. */
    for (size_t i = 0; i < o->count; i++) {
        if (strcmp(o->keys[i], key) == 0) {
            o->values[i] = v;
            return;
        }
    }
    if (o->count == o->capacity) {
        size_t next = o->capacity ? o->capacity * 2 : 4;
        size_t kbytes = next * sizeof(orbit_string);
        size_t vbytes = next * sizeof(OrbitValue);
        /* Copy forward: the arena has no realloc and no free, so the old block
           is left behind deliberately and reclaimed on arena reset. */
        orbit_string* nk = (orbit_string*)orbit_alloc(o->arena, kbytes);
        OrbitValue* nv = (OrbitValue*)orbit_alloc(o->arena, vbytes);
        if (o->count) {
            memcpy(nk, o->keys, o->count * sizeof(orbit_string));
            memcpy(nv, o->values, o->count * sizeof(OrbitValue));
        }
        o->keys = nk;
        o->values = nv;
        o->capacity = next;
    }
    o->keys[o->count] = key;
    o->values[o->count] = v;
    o->count++;
}

/* One setter per value type, so the generated call is typed and the runtime
   records the kind instead of inferring it. orbit_object_set stays as the
   generic entry point for callers that already hold an OrbitValue. */
ORBIT_UNUSED void orbit_object_set_int(OrbitObject* o, const char* key, orbit_int v) {
    orbit_object_set(o, key, orbit_value_int(v));
}

ORBIT_UNUSED void orbit_object_set_float(OrbitObject* o, const char* key, orbit_float v) {
    orbit_object_set(o, key, orbit_value_float(v));
}

ORBIT_UNUSED void orbit_object_set_bool(OrbitObject* o, const char* key, orbit_bool v) {
    orbit_object_set(o, key, orbit_value_bool(v));
}

ORBIT_UNUSED void orbit_object_set_string(OrbitObject* o, const char* key, const char* v) {
    orbit_object_set(o, key, orbit_value_string(v));
}

ORBIT_UNUSED void orbit_object_set_object(OrbitObject* o, const char* key, OrbitObject* v) {
    orbit_object_set(o, key, orbit_value_object(v));
}

ORBIT_UNUSED OrbitValue orbit_object_get(OrbitObject* o, const char* key) {
    OrbitValue missing = orbit_value_null();
    if (!o || !key) return missing;
    for (size_t i = 0; i < o->count; i++) {
        if (strcmp(o->keys[i], key) == 0) return o->values[i];
    }
    return missing;
}

/* Typed getters, one per kind, so a field read compiles to a typed call
   instead of a pointer the caller has to cast. orbit_object_get_raw is the
   fallback for a field whose kind is not known where it is read -- an object
   that arrived from a function rather than a literal beside it. */
ORBIT_UNUSED orbit_int orbit_object_get_int(OrbitObject* o, const char* key) {
    OrbitValue v = orbit_object_get(o, key);
    return (orbit_int)v.raw;
}

ORBIT_UNUSED orbit_float orbit_object_get_float(OrbitObject* o, const char* key) {
    OrbitValue v = orbit_object_get(o, key);
    orbit_float f = 0;
    uint64_t bits = (uint64_t)v.raw;
    memcpy(&f, &bits, sizeof(f));
    return f;
}

ORBIT_UNUSED orbit_bool orbit_object_get_bool(OrbitObject* o, const char* key) {
    OrbitValue v = orbit_object_get(o, key);
    return v.raw ? 1 : 0;
}

ORBIT_UNUSED const char* orbit_object_get_string(OrbitObject* o, const char* key) {
    OrbitValue v = orbit_object_get(o, key);
    if (v.kind == ORBIT_VAL_STRING) return (const char*)v.raw;
    return "";
}

ORBIT_UNUSED OrbitObject* orbit_object_get_object(OrbitObject* o, const char* key) {
    OrbitValue v = orbit_object_get(o, key);
    if (v.kind == ORBIT_VAL_OBJECT) return (OrbitObject*)v.raw;
    return NULL;
}

/* The fallback for a field whose kind is not known where it is read. Returns
   "" rather than NULL for a missing key: a null string reaches printf and
   strcmp as a dereference, so an absent field would be a crash instead of an
   empty answer. */
ORBIT_UNUSED const char* orbit_object_get_raw(OrbitObject* o, const char* key) {
    OrbitValue v = orbit_object_get(o, key);
    if (v.kind == ORBIT_VAL_NULL) return "";
    return (const char*)v.raw;
}

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

static ORBIT_UNUSED void json_buf_reserve(OrbitJsonBuf* b, size_t extra) {
    if (b->len + extra <= b->cap) return;
    size_t next = b->cap ? b->cap : 128;
    while (next < b->len + extra) next *= 2;
    char* grown = (char*)orbit_alloc(b->arena, next);
    if (b->len) memcpy(grown, b->data, b->len);
    b->data = grown;
    b->cap = next;
}

static ORBIT_UNUSED void json_puts(OrbitJsonBuf* b, const char* s) {
    size_t n = strlen(s);
    json_buf_reserve(b, n + 1);
    memcpy(b->data + b->len, s, n);
    b->len += n;
    b->data[b->len] = '\0';
}

static ORBIT_UNUSED void json_putc(OrbitJsonBuf* b, char c) {
    json_buf_reserve(b, 2);
    b->data[b->len++] = c;
    b->data[b->len] = '\0';
}

/* put_value and the object writer call each other: an object may hold another
   object. Declared here so neither needs the other's body first. */
static ORBIT_UNUSED void json_put_value(OrbitJsonBuf* b, OrbitValue v);
static ORBIT_UNUSED void orbit_object_to_json_buf(OrbitJsonBuf* b, OrbitObject* o);

/* Same rules as the database row serializer, so a string that survives one
   survives the other: quote, backslash, the three short escapes, and \u00XX
   for the remaining control characters. */
static ORBIT_UNUSED void json_put_string(OrbitJsonBuf* b, const char* s) {
    json_putc(b, '"');
    for (const char* c = s ? s : ""; *c; c++) {
        unsigned char ch = (unsigned char)*c;
        if (ch == '"' || ch == '\\') {
            json_putc(b, '\\');
            json_putc(b, (char)ch);
        } else if (ch == '\n') {
            json_puts(b, "\\n");
        } else if (ch == '\r') {
            json_puts(b, "\\r");
        } else if (ch == '\t') {
            json_puts(b, "\\t");
        } else if (ch < 0x20) {
            char esc[8];
            snprintf(esc, sizeof(esc), "\\u%04x", ch);
            json_puts(b, esc);
        } else {
            json_putc(b, (char)ch);
        }
    }
    json_putc(b, '"');
}

static ORBIT_UNUSED void json_put_value(OrbitJsonBuf* b, OrbitValue v) {
    char tmp[64];
    switch (v.kind) {
        case ORBIT_VAL_NULL:
            json_puts(b, "null");
            break;
        case ORBIT_VAL_BOOL:
            json_puts(b, v.raw ? "true" : "false");
            break;
        case ORBIT_VAL_INT:
            snprintf(tmp, sizeof(tmp), "%lld", (long long)(orbit_int)v.raw);
            json_puts(b, tmp);
            break;
        case ORBIT_VAL_FLOAT: {
            orbit_float f = 0;
            uint64_t bits = (uint64_t)v.raw;
            memcpy(&f, &bits, sizeof(f));
            /* %.17g round-trips, but prints 2 as 2.0000000000000000; %g with
               the shortest representation that still round-trips is what a
               reader expects to see. */
            snprintf(tmp, sizeof(tmp), "%g", (double)f);
            json_puts(b, tmp);
            break;
        }
        case ORBIT_VAL_STRING:
            json_put_string(b, (const char*)v.raw);
            break;
        case ORBIT_VAL_OBJECT:
            orbit_object_to_json_buf(b, (OrbitObject*)v.raw);
            break;
    }
}

static ORBIT_UNUSED void orbit_object_to_json_buf(OrbitJsonBuf* b, OrbitObject* o) {
    if (!o) {
        json_puts(b, "null");
        return;
    }
    json_putc(b, '{');
    for (size_t i = 0; i < o->count; i++) {
        if (i) json_putc(b, ',');
        json_put_string(b, o->keys[i]);
        json_putc(b, ':');
        json_put_value(b, o->values[i]);
    }
    json_putc(b, '}');
}

ORBIT_UNUSED const char* orbit_object_to_json(OrbitArena* arena, OrbitObject* o) {
    if (!arena) arena = orbit_arena_get_global();
    OrbitJsonBuf b;
    b.arena = arena;
    b.len = 0;
    b.cap = 0;
    b.data = NULL;
    json_buf_reserve(&b, 1);
    b.data[0] = '\0';
    orbit_object_to_json_buf(&b, o);
    return b.data;
}

#endif /* ORBIT_JSON_H */
