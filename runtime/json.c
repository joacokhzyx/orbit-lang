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

static ORBIT_UNUSED OrbitValue orbit_value_list(const OrbitList* l) {
    OrbitValue v;
    v.kind = ORBIT_VAL_LIST;
    v.raw = (uintptr_t)l;
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

ORBIT_UNUSED void orbit_object_set_list(OrbitObject* o, const char* key, const OrbitList* v) {
    orbit_object_set(o, key, orbit_value_list(v));
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
   that arrived from a function rather than a literal beside it.
   A present field read through the wrong getter aborts with a diagnostic
   instead of reinterpreting the bits: an int read as a pointer truncates
   to 32 bits, a pointer read as a float decodes garbage as a double, and
   any nonzero word read as a bool is true. A missing key keeps the old
   quiet defaults (0, 0.0, "", NULL): absence is not a mismatch. */
static const char* orbit_value_kind_name(OrbitValueKind k) {
    switch (k) {
        case ORBIT_VAL_NULL: return "null";
        case ORBIT_VAL_INT: return "int";
        case ORBIT_VAL_FLOAT: return "float";
        case ORBIT_VAL_BOOL: return "bool";
        case ORBIT_VAL_STRING: return "string";
        case ORBIT_VAL_OBJECT: return "object";
        case ORBIT_VAL_LIST: return "list";
        default: return "unknown";
    }
}

static ORBIT_UNUSED void orbit_object_kind_error(OrbitValueKind have, OrbitValueKind want, const char* key) {
    fprintf(stderr,
            "orbit: object field type mismatch\n"
            "  field    %s\n"
            "  holds    %s, read as %s\n"
            "  a field has one type, so the getter must match the setter\n",
            key ? key : "<null>",
            orbit_value_kind_name(have), orbit_value_kind_name(want));
    fflush(stderr);
    exit(2);
}

ORBIT_UNUSED orbit_int orbit_object_get_int(OrbitObject* o, const char* key) {
    OrbitValue v = orbit_object_get(o, key);
    if (v.kind == ORBIT_VAL_NULL) return 0;
    if (v.kind != ORBIT_VAL_INT) orbit_object_kind_error(v.kind, ORBIT_VAL_INT, key);
    return (orbit_int)v.raw;
}

ORBIT_UNUSED orbit_float orbit_object_get_float(OrbitObject* o, const char* key) {
    OrbitValue v = orbit_object_get(o, key);
    orbit_float f = 0;
    if (v.kind == ORBIT_VAL_NULL) return f;
    if (v.kind != ORBIT_VAL_FLOAT) orbit_object_kind_error(v.kind, ORBIT_VAL_FLOAT, key);
    uint64_t bits = (uint64_t)v.raw;
    memcpy(&f, &bits, sizeof(f));
    return f;
}

ORBIT_UNUSED orbit_bool orbit_object_get_bool(OrbitObject* o, const char* key) {
    OrbitValue v = orbit_object_get(o, key);
    if (v.kind == ORBIT_VAL_NULL) return 0;
    if (v.kind != ORBIT_VAL_BOOL) orbit_object_kind_error(v.kind, ORBIT_VAL_BOOL, key);
    return v.raw ? 1 : 0;
}

ORBIT_UNUSED const char* orbit_object_get_string(OrbitObject* o, const char* key) {
    OrbitValue v = orbit_object_get(o, key);
    if (v.kind == ORBIT_VAL_STRING) return (const char*)v.raw;
    if (v.kind == ORBIT_VAL_NULL) return "";
    orbit_object_kind_error(v.kind, ORBIT_VAL_STRING, key);
    return "";
}

ORBIT_UNUSED OrbitObject* orbit_object_get_object(OrbitObject* o, const char* key) {
    OrbitValue v = orbit_object_get(o, key);
    if (v.kind == ORBIT_VAL_OBJECT) return (OrbitObject*)v.raw;
    if (v.kind == ORBIT_VAL_NULL) return NULL;
    orbit_object_kind_error(v.kind, ORBIT_VAL_OBJECT, key);
    return NULL;
}

ORBIT_UNUSED const OrbitList* orbit_object_get_list(OrbitObject* o, const char* key) {
    OrbitValue v = orbit_object_get(o, key);
    if (v.kind == ORBIT_VAL_LIST) return (const OrbitList*)v.raw;
    if (v.kind == ORBIT_VAL_NULL) return NULL;
    orbit_object_kind_error(v.kind, ORBIT_VAL_LIST, key);
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

static void json_fail(JsonParse* j, const char* msg) {
    if (!j->err) j->err = msg;
}

static void json_ws(const char** p) {
    while (**p == ' ' || **p == '\t' || **p == '\n' || **p == '\r') (*p)++;
}

static int json_hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* One \uXXXX unit, or -1 past the end or on malformed digits. Surrogate
 * halves are combined by the caller; a lone half is refused there. */
static int json_unicode_unit(const char* s) {
    int h0 = json_hexval(s[0]);
    int h1 = json_hexval(s[1]);
    int h2 = json_hexval(s[2]);
    int h3 = json_hexval(s[3]);
    if (h0 < 0 || h1 < 0 || h2 < 0 || h3 < 0) return -1;
    return (h0 << 12) | (h1 << 8) | (h2 << 4) | h3;
}

static int json_utf8_len(int cp) {
    if (cp < 0x80) return 1;
    if (cp < 0x800) return 2;
    if (cp < 0x10000) return 3;
    return 4;
}

static void json_utf8_emit(char* out, int cp) {
    if (cp < 0x80) {
        out[0] = (char)cp;
    } else if (cp < 0x800) {
        out[0] = (char)(0xC0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
        out[0] = (char)(0xE0 | (cp >> 12));
        out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (char)(0x80 | (cp & 0x3F));
    } else {
        out[0] = (char)(0xF0 | (cp >> 18));
        out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[3] = (char)(0x80 | (cp & 0x3F));
    }
}

/* A JSON string at *p (the opening quote). Two passes: the first finds the
 * closing quote while validating escapes and measuring the decoded length,
 * the second decodes into an exact arena buffer. Unescaped control bytes
 * and lone surrogates are refused; a decoded NUL is refused too, because
 * an orbit_string cannot hold one. */
static const char* json_parse_string(JsonParse* j, const char** p) {
    const char* s = *p + 1;
    size_t decoded = 0;
    const char* q = s;
    while (*q && *q != '"') {
        if ((unsigned char)*q < 0x20) {
            json_fail(j, "json: unescaped control character in string");
            return NULL;
        }
        if (*q != '\\') {
            decoded++;
            q++;
            continue;
        }
        q++;
        if (*q == '"' || *q == '\\' || *q == '/') {
            decoded++;
            q++;
        } else if (*q == 'b' || *q == 'f' || *q == 'n' || *q == 'r' || *q == 't') {
            decoded++;
            q++;
        } else if (*q == 'u') {
            int cp;
            if (!q[1] || !q[2] || !q[3] || !q[4]) {
                json_fail(j, "json: truncated unicode escape");
                return NULL;
            }
            cp = json_unicode_unit(q + 1);
            if (cp < 0) {
                json_fail(j, "json: bad unicode escape");
                return NULL;
            }
            if (cp >= 0xD800 && cp <= 0xDBFF) {
                int lo;
                if (q[5] != '\\' || q[6] != 'u') {
                    json_fail(j, "json: lone surrogate");
                    return NULL;
                }
                if (!q[7] || !q[8] || !q[9] || !q[10]) {
                    json_fail(j, "json: truncated unicode escape");
                    return NULL;
                }
                lo = json_unicode_unit(q + 7);
                if (lo < 0 || lo < 0xDC00 || lo > 0xDFFF) {
                    json_fail(j, "json: lone surrogate");
                    return NULL;
                }
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                decoded += 4;
                /* 11 from the 'u': u + 4 hex + backslash + u + 4 hex. The
                 * opening backslash is already behind q. */
                q += 11;
            } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                json_fail(j, "json: lone surrogate");
                return NULL;
            } else {
                decoded += (size_t)json_utf8_len(cp);
                q += 6;
            }
        } else {
            json_fail(j, "json: bad escape");
            return NULL;
        }
    }
    if (*q != '"') {
        json_fail(j, "json: unterminated string");
        return NULL;
    }
    {
        char* out = (char*)orbit_alloc(j->arena, decoded + 1);
        char* w;
        const char* r;
        if (!out) {
            json_fail(j, "json: out of memory");
            return NULL;
        }
        w = out;
        r = s;
        while (r < q) {
            if (*r != '\\') {
                *w++ = *r++;
                continue;
            }
            r++;
            if (*r == 'u') {
                int cp = json_unicode_unit(r + 1);
                if (cp >= 0xD800 && cp <= 0xDBFF) {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (json_unicode_unit(r + 7) - 0xDC00);
                    json_utf8_emit(w, cp);
                    w += 4;
                    /* 11 from the 'u', as in the measuring pass. */
                    r += 11;
                } else {
                    json_utf8_emit(w, cp);
                    w += json_utf8_len(cp);
                    r += 6;
                }
                continue;
            }
            if (*r == 'b') *w++ = '\b';
            else if (*r == 'f') *w++ = '\f';
            else if (*r == 'n') *w++ = '\n';
            else if (*r == 'r') *w++ = '\r';
            else if (*r == 't') *w++ = '\t';
            else *w++ = *r;
            r++;
        }
        *w = '\0';
        *p = q + 1;
        return out;
    }
}

/* 0 not-a-number, 1 int (oi), 2 float (of). Leading zeros, a bare dot or
 * exponent, and a missing integer part are all refused; an integer past
 * int64 and a float past finite are refused too, with the range stated. */
static int json_parse_number(JsonParse* j, const char** p, orbit_int* oi, orbit_float* of) {
    const char* start = *p;
    const char* s = start;
    int isFloat = 0;
    if (*s == '-') s++;
    if (*s == '0') {
        s++;
        if (*s >= '0' && *s <= '9') {
            json_fail(j, "json: leading zeros are not numbers");
            return 0;
        }
    } else if (*s >= '1' && *s <= '9') {
        while (*s >= '0' && *s <= '9') s++;
    } else {
        json_fail(j, "json: bad number");
        return 0;
    }
    if (*s == '.') {
        isFloat = 1;
        s++;
        if (*s < '0' || *s > '9') {
            json_fail(j, "json: bad number");
            return 0;
        }
        while (*s >= '0' && *s <= '9') s++;
    }
    if (*s == 'e' || *s == 'E') {
        isFloat = 1;
        s++;
        if (*s == '+' || *s == '-') s++;
        if (*s < '0' || *s > '9') {
            json_fail(j, "json: bad number");
            return 0;
        }
        while (*s >= '0' && *s <= '9') s++;
    }
    {
        size_t span = (size_t)(s - start);
        char* copy = (char*)orbit_alloc(j->arena, span + 1);
        if (!copy) {
            json_fail(j, "json: out of memory");
            return 0;
        }
        memcpy(copy, start, span);
        copy[span] = '\0';
        if (!isFloat) {
            errno = 0;
            long long v = strtoll(copy, NULL, 10);
            if (errno == ERANGE) {
                json_fail(j, "json: integer out of int64 range");
                return 0;
            }
            *oi = (orbit_int)v;
        } else {
            double d = strtod(copy, NULL);
            if (!isfinite(d)) {
                json_fail(j, "json: float out of range");
                return 0;
            }
            *of = (orbit_float)d;
        }
        *p = s;
        return isFloat ? 2 : 1;
    }
}

static int json_lit(const char** p, const char* word) {
    size_t n = strlen(word);
    if (strncmp(*p, word, n) != 0) return 0;
    *p += n;
    return 1;
}

static int json_parse_value(JsonParse* j, const char** p, int depth, JsonVal* out);

static int json_parse_object(JsonParse* j, const char** p, int depth, OrbitObject** out) {
    OrbitObject* o = orbit_object_create(j->arena);
    if (!o) {
        json_fail(j, "json: out of memory");
        return 0;
    }
    (*p)++;
    json_ws(p);
    if (**p == '}') {
        (*p)++;
        *out = o;
        return 1;
    }
    for (;;) {
        const char* key;
        JsonVal v;
        if (**p != '"') {
            json_fail(j, "json: object keys must be strings");
            return 0;
        }
        key = json_parse_string(j, p);
        if (!key) return 0;
        json_ws(p);
        if (**p != ':') {
            json_fail(j, "json: expected ':' after key");
            return 0;
        }
        (*p)++;
        json_ws(p);
        if (!json_parse_value(j, p, depth, &v)) return 0;
        if (v.kind == J_INT) orbit_object_set_int(o, key, v.i);
        else if (v.kind == J_FLOAT) orbit_object_set_float(o, key, v.f);
        else if (v.kind == J_BOOL) orbit_object_set_bool(o, key, v.b);
        else if (v.kind == J_STR) orbit_object_set_string(o, key, v.s);
        else if (v.kind == J_OBJ) orbit_object_set_object(o, key, v.o);
        else if (v.kind == J_ARR) orbit_object_set_list(o, key, v.l);
        json_ws(p);
        if (**p == ',') {
            (*p)++;
            json_ws(p);
            continue;
        }
        if (**p == '}') {
            (*p)++;
            *out = o;
            return 1;
        }
        json_fail(j, "json: expected ',' or '}' in object");
        return 0;
    }
}

static int json_parse_array(JsonParse* j, const char** p, int depth, OrbitList** out) {
    OrbitResult cr = orbit_list_create(j->arena, sizeof(uintptr_t), 4);
    OrbitList* list;
    int firstKind = 0;
    if (!cr.ok) {
        json_fail(j, "json: out of memory");
        return 0;
    }
    list = (OrbitList*)cr.value;
    (*p)++;
    json_ws(p);
    if (**p == ']') {
        (*p)++;
        *out = list;
        return 1;
    }
    for (;;) {
        JsonVal v;
        if (!json_parse_value(j, p, depth, &v)) return 0;
        if (v.kind == J_NULL) {
            json_fail(j, "json: null array elements have no list slot");
            return 0;
        }
        if (v.kind == J_ARR) {
            json_fail(j, "json: nested arrays have no indexed reader");
            return 0;
        }
        if (firstKind == 0) {
            firstKind = (int)v.kind;
        } else if ((int)v.kind != firstKind) {
            json_fail(j, "json: heterogeneous arrays have no one element type");
            return 0;
        }
        if (v.kind == J_INT) {
            if (!orbit_list_push_int(list, v.i).ok) {
                json_fail(j, "json: out of memory");
                return 0;
            }
        } else if (v.kind == J_FLOAT) {
            if (!orbit_list_push_float(list, v.f).ok) {
                json_fail(j, "json: out of memory");
                return 0;
            }
        } else if (v.kind == J_BOOL) {
            if (!orbit_list_push_bool(list, v.b ? 1 : 0).ok) {
                json_fail(j, "json: out of memory");
                return 0;
            }
        } else if (v.kind == J_STR) {
            if (!orbit_list_push_string(list, v.s).ok) {
                json_fail(j, "json: out of memory");
                return 0;
            }
        } else {
            if (!orbit_list_push_ref(list, v.o).ok) {
                json_fail(j, "json: out of memory");
                return 0;
            }
        }
        json_ws(p);
        if (**p == ',') {
            (*p)++;
            json_ws(p);
            continue;
        }
        if (**p == ']') {
            (*p)++;
            *out = list;
            return 1;
        }
        json_fail(j, "json: expected ',' or ']' in array");
        return 0;
    }
}

static int json_parse_value(JsonParse* j, const char** p, int depth, JsonVal* out) {
    char c;
    if (depth > ORBIT_JSON_MAX_DEPTH) {
        json_fail(j, "json: nesting past 64 levels");
        return 0;
    }
    json_ws(p);
    c = **p;
    if (c == '{') {
        out->kind = J_OBJ;
        return json_parse_object(j, p, depth + 1, &out->o);
    }
    if (c == '[') {
        out->kind = J_ARR;
        return json_parse_array(j, p, depth + 1, &out->l);
    }
    if (c == '"') {
        const char* s = json_parse_string(j, p);
        if (!s) return 0;
        out->kind = J_STR;
        out->s = s;
        return 1;
    }
    if (c == 't') {
        if (!json_lit(p, "true")) {
            json_fail(j, "json: bad literal");
            return 0;
        }
        out->kind = J_BOOL;
        out->b = 1;
        return 1;
    }
    if (c == 'f') {
        if (!json_lit(p, "false")) {
            json_fail(j, "json: bad literal");
            return 0;
        }
        out->kind = J_BOOL;
        out->b = 0;
        return 1;
    }
    if (c == 'n') {
        if (!json_lit(p, "null")) {
            json_fail(j, "json: bad literal");
            return 0;
        }
        out->kind = J_NULL;
        return 1;
    }
    if (c == '-' || (c >= '0' && c <= '9')) {
        orbit_int oi = 0;
        orbit_float of = 0;
        int nkind = json_parse_number(j, p, &oi, &of);
        if (nkind == 0) return 0;
        if (nkind == 1) {
            out->kind = J_INT;
            out->i = oi;
        } else {
            out->kind = J_FLOAT;
            out->f = of;
        }
        return 1;
    }
    if (c == '\0') {
        json_fail(j, "json: unexpected end of input");
        return 0;
    }
    json_fail(j, "json: unexpected character");
    return 0;
}

/** @brief Parse a JSON object document, or err.
 *
 * The top level must be an object: configs, bodies and payloads are, and
 * a bare list or scalar has no field to traverse to. Strict throughout:
 * trailing garbage, unterminated strings, bad escapes, lone surrogates,
 * leading zeros, overflow past int64 or finite double, mixed or
 * null-bearing or nested arrays, and nesting past 64 levels are all err
 * with the reason, never a partial object. */
ORBIT_UNUSED OrbitResult orbit_json_parse(OrbitArena* arena, const char* text) {
    JsonParse j;
    const char* p;
    JsonVal v;
    OrbitArena* a = (arena && arena->base) ? arena : orbit_arena_get_global();
    if (!text) return orbit_result_err(ORBIT_ERR_PARSE, "json: null input");
    j.arena = a;
    j.err = NULL;
    p = text;
    if (!json_parse_value(&j, &p, 0, &v)) {
        return orbit_result_err(ORBIT_ERR_PARSE, j.err ? j.err : "json: bad input");
    }
    if (v.kind != J_OBJ) {
        return orbit_result_err(ORBIT_ERR_PARSE, "json: top level must be an object");
    }
    json_ws(&p);
    if (*p != '\0') {
        return orbit_result_err(ORBIT_ERR_PARSE, "json: trailing data after document");
    }
    return orbit_result_ok(v.o);
}

/* Indexed array traversal. Missing keys answer the quiet defaults, the
 * way scalar getters do; a present field of the wrong shape aborts with
 * the same diagnostic those use. Out-of-range indexes stop through the
 * list readers, the way every list read does. */
ORBIT_UNUSED orbit_int orbit_json_array_len(OrbitObject* o, const char* key) {
    OrbitValue v = orbit_object_get(o, key);
    if (v.kind == ORBIT_VAL_NULL) return 0;
    if (v.kind != ORBIT_VAL_LIST) orbit_object_kind_error(v.kind, ORBIT_VAL_LIST, key);
    return (orbit_int)((const OrbitList*)v.raw)->len;
}

ORBIT_UNUSED orbit_int orbit_json_array_get_int(OrbitObject* o, const char* key, orbit_int idx) {
    OrbitValue v = orbit_object_get(o, key);
    if (v.kind == ORBIT_VAL_NULL) return 0;
    if (v.kind != ORBIT_VAL_LIST) orbit_object_kind_error(v.kind, ORBIT_VAL_LIST, key);
    return orbit_list_read_int((const OrbitList*)v.raw, (size_t)idx, __func__, __FILE__, __LINE__);
}

ORBIT_UNUSED orbit_float orbit_json_array_get_float(OrbitObject* o, const char* key, orbit_int idx) {
    OrbitValue v = orbit_object_get(o, key);
    if (v.kind == ORBIT_VAL_NULL) return 0;
    if (v.kind != ORBIT_VAL_LIST) orbit_object_kind_error(v.kind, ORBIT_VAL_LIST, key);
    return orbit_list_read_float((const OrbitList*)v.raw, (size_t)idx, __func__, __FILE__, __LINE__);
}

ORBIT_UNUSED orbit_bool orbit_json_array_get_bool(OrbitObject* o, const char* key, orbit_int idx) {
    OrbitValue v = orbit_object_get(o, key);
    if (v.kind == ORBIT_VAL_NULL) return 0;
    if (v.kind != ORBIT_VAL_LIST) orbit_object_kind_error(v.kind, ORBIT_VAL_LIST, key);
    return orbit_list_read_bool((const OrbitList*)v.raw, (size_t)idx, __func__, __FILE__, __LINE__);
}

ORBIT_UNUSED const char* orbit_json_array_get_string(OrbitObject* o, const char* key, orbit_int idx) {
    OrbitValue v = orbit_object_get(o, key);
    if (v.kind == ORBIT_VAL_NULL) return "";
    if (v.kind != ORBIT_VAL_LIST) orbit_object_kind_error(v.kind, ORBIT_VAL_LIST, key);
    return orbit_list_read_string((const OrbitList*)v.raw, (size_t)idx, __func__, __FILE__, __LINE__);
}

ORBIT_UNUSED OrbitObject* orbit_json_array_get_object(OrbitObject* o, const char* key, orbit_int idx) {
    OrbitValue v = orbit_object_get(o, key);
    if (v.kind == ORBIT_VAL_NULL) return NULL;
    if (v.kind != ORBIT_VAL_LIST) orbit_object_kind_error(v.kind, ORBIT_VAL_LIST, key);
    return (OrbitObject*)orbit_list_read_ref((const OrbitList*)v.raw, (size_t)idx, __func__, __FILE__, __LINE__);
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
static ORBIT_UNUSED void json_put_list(OrbitJsonBuf* b, const OrbitList* l);

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
        case ORBIT_VAL_LIST:
            json_put_list(b, (const OrbitList*)v.raw);
            break;
        default:
            json_puts(b, "null");
            break;
    }
}

/* A list inside an object is a JSON array. Elements are read by the list's own
   element kind, the same mapping the typed accessors use: strings as pointers,
   ints sign-extended, floats by bit pattern, bools as 0/1, refs as embedded
   objects. An empty or untyped list has no elements to disagree on, so it is
   simply []. A ref element is an object pointer: lists of objects are the JSON
   array-of-records shape, and nested lists stay unsupported rather than
   mis-serialized (sema rejects them with a diagnostic). */
static ORBIT_UNUSED void json_put_list(OrbitJsonBuf* b, const OrbitList* l) {
    if (!l || !l->data) {
        json_puts(b, "[]");
        return;
    }
    char tmp[64];
    json_putc(b, '[');
    for (size_t i = 0; i < l->len; i++) {
        if (i) json_putc(b, ',');
        uintptr_t word = 0;
        memcpy(&word, (const char*)l->data + i * l->elem_size, sizeof(uintptr_t));
        switch (l->elem_kind) {
            case ORBIT_ELEM_STRING:
                json_put_string(b, (const char*)word);
                break;
            case ORBIT_ELEM_INT:
                snprintf(tmp, sizeof(tmp), "%lld", (long long)(orbit_int)(intptr_t)word);
                json_puts(b, tmp);
                break;
            case ORBIT_ELEM_FLOAT: {
                orbit_float f = 0;
                uint64_t bits = (uint64_t)word;
                memcpy(&f, &bits, sizeof(f));
                snprintf(tmp, sizeof(tmp), "%g", (double)f);
                json_puts(b, tmp);
                break;
            }
            case ORBIT_ELEM_BOOL:
                json_puts(b, word ? "true" : "false");
                break;
            case ORBIT_ELEM_REF:
                orbit_object_to_json_buf(b, (OrbitObject*)word);
                break;
            default:
                json_puts(b, "null");
                break;
        }
    }
    json_putc(b, ']');
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
