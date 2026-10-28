/**
 * @file  orbit_api.h
 * @brief Declarations-only header for separate compilation against libruntime_net.a.
 *
 * A user translation unit (TU) produced by the Orbit compiler includes
 * "runtime.h" first (via the emitted preamble). Defining
 * -DORBIT_SEPARATE_COMPILATION on the C command line makes runtime.h expose
 * only this header instead of the unity implementation, so the TU compiles
 * standalone and links against .orbit/lib/libruntime_net.a (net variant, no
 * DB; see scripts/mklib_runtime.py):
 *
 *     gcc -DORBIT_SEPARATE_COMPILATION -I runtime user.c .orbit/lib/libruntime_net.a -o user -lws2_32   (Windows)
 *     gcc -DORBIT_SEPARATE_COMPILATION -I runtime user.c .orbit/lib/libruntime_net.a -o user            (POSIX)
 *
 * The default unity build (no flag) is unchanged: runtime.h still inlines
 * every runtime .c file into the one TU.
 *
 * Router decision: every emitted TU defines ORBIT_CUSTOM_ROUTER and provides
 * its own orbit_handle_request, while http.c keeps a fallback definition for
 * TUs without one. The library is built with -DORBIT_LIB_NO_ROUTER, which
 * excludes that fallback from http.c, so linking a user TU against the
 * library can never see two definitions. ORBIT_CUSTOM_ROUTER (user side) and
 * ORBIT_LIB_NO_ROUTER (library side) compose: both exclude the fallback, and
 * the user's definition is the only one linked.
 *
 * Linkage: the functions a user TU calls used to be file-static inside the
 * unity TU. They now have external linkage and are declared below. Beyond the
 * ten in the original split plan (orbit_string_concat/at/replace/
 * slice_known_len, orbit_ledger_enter/exit/is_loopback, orbit_monotonic_ns,
 * orbit_result_ok_float/get_float), the emitted TUs surveyed for this split
 * also call orbit_result_ok, orbit_result_err, orbit_result_ok_word,
 * orbit_string_slice, orbit_string_split, orbit_map_delete and
 * orbit_map_keys, so those are external too. Static helpers nobody outside
 * their own file calls (orbit_map_hash excepted, see below) stay static.
 *
 * The ORBIT_INLINE accessors the emitter lowers reads to (orbit_string_len,
 * orbit_list_len, orbit_list_read_*, orbit_list_get_value/checked/store,
 * orbit_list_store_at, orbit_list_adopt/expect_kind, orbit_map_get/has) are
 * static inline here, body-identical to runtime/collections.c, calling the
 * external functions declared in this header. orbit_map_get needs
 * orbit_map_hash, so a static copy of that FNV-1a helper rides along; both copies are internal
 * linkage and never meet at link time.
 *
 * Type definitions are repeated here rather than shared because the runtime
 * keeps them inside .c files (there is no types header to include); the
 * canonical definition and its documentation live in the .c file named in
 * each section. Layouts must stay in sync by inspection.
 *
 * Shared state: the performance counters (orbit_perf_stats,
 * orbit_perf_lat_hist in performance.h) are owned by the library TU
 * (ORBIT_PERF_IMPL) and bound via extern from a separate user TU, so both
 * modes count into the same object -- the same shape the Kynx lease pointer
 * (current_lease) already used. Every other runtime state (ledger, arenas,
 * Kynx, energy, clock) lives behind library functions in both modes.
 *
 * orbit_string_intern is intentionally absent: it is a static inline helper
 * with no caller in any emitted TU surveyed. DB/auth symbols are absent too:
 * the net variant library does not define them, so a DB program fails here
 * at compile time with a clear message instead of at link time.
 *
 * tcc judge builds are single-thread-only: tcc predefines __TINYC__ and
 * provides no __thread TLS and no __atomic_* builtins, so the shim below
 * degrades __thread to a plain global and the builtins to plain operations
 * (each runtime .c that needs it carries the same shim; the unity TU shares
 * one preprocessor state, so it is never #undef'd and every declaration
 * agrees). A tcc-built server must therefore never serve concurrent
 * requests: the multithreaded server stays a gcc build by design, because
 * plain operations race. Outside __TINYC__ everything is intact --
 * Interlocked* on Windows, __sync_* on POSIX, Winsock names -- and the
 * gcc/clang/MSVC path is byte-identical with or without the shim.
 */
#ifndef ORBIT_API_H
#define ORBIT_API_H

#ifdef __TINYC__
#ifndef ORBIT_TINYC_SHIM
#define ORBIT_TINYC_SHIM
#define __thread
#ifndef __ATOMIC_RELAXED
#define __ATOMIC_RELAXED 0
#define __ATOMIC_ACQUIRE 2
#define __ATOMIC_RELEASE 3
#define __ATOMIC_SEQ_CST 5
#endif
#define __atomic_load_n(ptr, memorder) (*(ptr))
#define __atomic_store_n(ptr, val, memorder) ((*(ptr)) = (val))
#define __atomic_fetch_add(ptr, val, memorder) (*(ptr) += (val), *(ptr) - (val))
#define __atomic_fetch_sub(ptr, val, memorder) (*(ptr) -= (val), *(ptr) + (val))
/* fetch_or/and return the NEW value, not the old one the gcc builtin returns;
 * no call site in this tree reads the result. */
#define __atomic_fetch_or(ptr, val, memorder) (*(ptr) |= (val))
#define __atomic_fetch_and(ptr, val, memorder) (*(ptr) &= (val))
#endif
#endif

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <setjmp.h>
#include "socket_compat.h"
#include "crt_compat.h"
#include "inline.h"
#include "performance.h"

#ifdef ORBIT_WITH_DB
#error "libruntime_net.a is the net-only variant (no DB symbols): build this program in the default unity mode instead."
#endif

/* Same redirect as runtime.h: the emitted colour preamble calls getenv(). */
#define getenv orbit_env_get

/* ── Primitive type aliases (canonical: runtime/types.c) ─────────────── */
typedef const char* orbit_string;
typedef int64_t     orbit_int;
typedef double      orbit_float;
typedef double      orbit_decimal;
typedef bool        orbit_bool;

struct OrbitArena;

/* ── Arena (canonical: runtime/arena.c) ──────────────────────────────── */
typedef struct OrbitArenaOverflow {
    struct OrbitArenaOverflow* next;
    void*                      ptr;
    size_t                     size;
} OrbitArenaOverflow;

struct OrbitStringPoolLocal;

typedef struct OrbitArena {
    unsigned char* base;
    unsigned char* cursor;
    unsigned char* committed_end;
    unsigned char* reserved_end;

    size_t page_size;
    size_t requested_bytes;
    size_t aligned_bytes;
    size_t peak_used;
    size_t committed_bytes;
    size_t reserved_bytes;
    /* Kept in step with the private definition in runtime/arena.c: the
     * committed-bytes ceiling and whether the last refusal was that ceiling
     * rather than the OS running out. */
    size_t max_rule;
    bool ceiling_hit;

    uint64_t generation;
    uint64_t alloc_count;

    struct OrbitArena* parent;

    struct OrbitStringPoolLocal* local_string_pool;

    OrbitArenaOverflow* overflow_list;

    char*             buffer;
    size_t            capacity;
    size_t            used;
} OrbitArena;

typedef struct {
    size_t offset;
    uint64_t generation;
} OrbitArenaCheckpoint;

typedef void (*OrbitOomHandler)(OrbitArena* arena, size_t bytes);

/* ── Result<T,E> (canonical: runtime/types.c) ────────────────────────── */
typedef enum {
    ORBIT_ERR_NONE          = 0,
    ORBIT_ERR_NULL_PTR      = 1,
    ORBIT_ERR_OUT_OF_MEMORY = 2,
    ORBIT_ERR_OUT_OF_BOUNDS = 3,
    ORBIT_ERR_KEY_NOT_FOUND = 4,
    ORBIT_ERR_TYPE_MISMATCH = 5,
    ORBIT_ERR_OVERFLOW      = 6,
    ORBIT_ERR_INVALID_ARG   = 7,
    ORBIT_ERR_IO            = 8,
    ORBIT_ERR_PARSE         = 9,
    ORBIT_ERR_CUSTOM        = 255
} OrbitErrorCode;

typedef struct {
    bool            ok;
    OrbitErrorCode  error_code;
    const char*     error_msg;
    void*           value;
} OrbitResult;

#define ORBIT_TRY(result_expr)                 \
    do {                                       \
        OrbitResult _r = (result_expr);        \
        if (!_r.ok) return _r;                 \
    } while (0)

#define ORBIT_UNWRAP(result_expr, out_ptr)     \
    do {                                       \
        OrbitResult _r = (result_expr);        \
        if (!_r.ok) return _r;                 \
        (out_ptr) = _r.value;                  \
    } while (0)

/* ── List/Map element model (canonical: runtime/types.c) ─────────────── */
typedef enum {
    ORBIT_ELEM_OPAQUE = 0,
    ORBIT_ELEM_STRING = 1,
    ORBIT_ELEM_INT    = 2,
    ORBIT_ELEM_FLOAT  = 3,
    ORBIT_ELEM_BOOL   = 4,
    ORBIT_ELEM_REF    = 5
} OrbitElemKind;

typedef union {
    uintptr_t  u;
    intptr_t   i;
    orbit_int  n;
    double     d;
    void*      p;
} OrbitElemBox;

typedef struct {
    void*           data;
    size_t          len;
    size_t          capacity;
    size_t          elem_size;
    int             elem_kind;
    struct OrbitArena* arena;
} OrbitList;

typedef struct {
    const char* key;
    void*       value;
    uint32_t    hash;
    bool        occupied;
} OrbitMapEntry;

typedef struct {
    OrbitMapEntry*     buckets;
    size_t             bucket_count;
    size_t             count;
    size_t             value_size;
    struct OrbitArena*  arena;
} OrbitMap;

/* ── JSON values and objects (canonical: runtime/json.c) ─────────────── */
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

/* ── HTTP request/response (canonical: runtime/http.c) ───────────────── */
#ifndef ORBIT_HTTP_API_H
#define ORBIT_HTTP_API_H
#define ORBIT_MAX_PATH_PARAMS 32
typedef struct {
    char* method;
    char* path;
    char* query;
    char* body;
    char* headers;
    size_t body_len;
    size_t headers_len;
    char* param_names[ORBIT_MAX_PATH_PARAMS];
    char* param_values[ORBIT_MAX_PATH_PARAMS];
    int param_count;
} OrbitRequest;
#endif

typedef struct {
    int    status;
    char*  body;
    size_t body_len;
    char*  content_type;
    char*  extra_headers;
    size_t extra_headers_len;
} OrbitResponse;

/* ── Convenience (mirrors runtime.h) ─────────────────────────────────── */
#define print(...) do { printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while(0)

static inline int bit_op(int i) {
    return ((i * 17) ^ (i >> 2)) & 0xFFFF;
}

/* Process start-up pieces the generated main calls (runtime/crash.c,
 * runtime/console.c). No constructor: a program links only what it names. */
void orbit_crash_handler_install(void);
void orbit_console_init(void);
void orbit_print_string(const char* s);

/* ── Static inline accessors (canonical: runtime/collections.c) ────────
 * Byte-identical copies; they call the external functions declared below,
 * so their bodies live after the declaration block at the end of this
 * section. orbit_map_get needs orbit_map_hash, so a static copy of that
 * FNV-1a helper rides along; both copies are internal linkage and never
 * meet at link time. */

/* ── External functions: Result (canonical: runtime/types.c) ─────────── */
OrbitResult orbit_result_ok(void* value);
OrbitResult orbit_result_ok_word(uintptr_t word);
OrbitResult orbit_result_ok_float(orbit_float value);
orbit_float orbit_result_get_float(OrbitResult r);
OrbitResult orbit_result_err(OrbitErrorCode code, const char* msg);

/* ── External functions: arena (canonical: runtime/arena.c) ──────────── */
OrbitArena* orbit_arena_create(size_t initial_capacity);
OrbitArena* orbit_arena_create_child(OrbitArena* parent, size_t initial_capacity);
void orbit_arena_destroy(OrbitArena* arena);
void orbit_set_oom_handler(OrbitOomHandler handler);
OrbitOomHandler orbit_get_oom_handler(void);
/* Request-boundary OOM recovery: a refusal inside one request is answered
 * instead of ending the process. The mechanism is arena.c; the generated
 * router arms and disarms it around one request -- arming hands over the
 * jmp_buf of the frame that will take the longjmp -- and answers with a 503
 * that carries the refusal's numbers. ENGINEERING.md section 7,
 * kynx-lease-abort. */
void orbit_request_oom_install(void);
void orbit_request_oom_arm(jmp_buf* target);
void orbit_request_oom_disarm(void);
const char* orbit_request_oom_message(void);
void* orbit_alloc_try(OrbitArena* arena, size_t bytes);
void* orbit_alloc(OrbitArena* arena, size_t bytes);
char* orbit_arena_strdup(OrbitArena* arena, const char* src);
void orbit_arena_reset(OrbitArena* arena);
OrbitArenaCheckpoint orbit_arena_checkpoint(const OrbitArena* arena);
bool orbit_arena_rewind(OrbitArena* arena, OrbitArenaCheckpoint checkpoint);
void* orbit_arena_promote(OrbitArena* child, const void* ptr, size_t bytes);
size_t orbit_arena_used(const OrbitArena* arena);
size_t orbit_arena_capacity(const OrbitArena* arena);
uint64_t orbit_arena_alloc_count(const OrbitArena* arena);
size_t orbit_arena_peak_used(const OrbitArena* arena);
size_t orbit_arena_active_bytes(const OrbitArena* arena);
int orbit_arena_overflowed(const OrbitArena* arena);
OrbitArena* orbit_arena_get_global(void);

/* ── External functions: arena pool (canonical: runtime/arena_pool.c) ── */
void orbit_arena_pool_init(int pool_size, size_t arena_capacity);
OrbitArena* orbit_arena_pool_acquire(void);
void orbit_arena_pool_release(OrbitArena* arena);
void orbit_arena_pool_cleanup(void);

/* ── External functions: string pool (canonical: runtime/string_pool.c)  */
void orbit_string_pool_init(int capacity);
void orbit_string_pool_cleanup(void);

/* ── External functions: collections (canonical: runtime/collections.c)  */
const char* orbit_list_kind_name(int kind);
void orbit_list_index_error(const char* where, unsigned long index,
                            unsigned long len, int kind, const char* file, int line);
void orbit_list_kind_error(int have, int want);
OrbitResult orbit_list_create_typed(OrbitArena* arena, size_t elem_size, size_t initial_capacity, int elem_kind);
OrbitResult orbit_list_create(OrbitArena* arena, size_t elem_size, size_t initial_capacity);
OrbitResult orbit_list_grow(OrbitList* list);
OrbitResult orbit_list_push(OrbitList* list, const void* elem);
OrbitResult orbit_list_push_string(OrbitList* list, orbit_string value);
OrbitResult orbit_list_push_int(OrbitList* list, orbit_int value);
OrbitResult orbit_list_push_bool(OrbitList* list, orbit_bool value);
OrbitResult orbit_list_push_ref(OrbitList* list, void* value);
OrbitResult orbit_list_push_float(OrbitList* list, orbit_float value);
OrbitResult orbit_list_pop(OrbitList* list);
OrbitResult orbit_list_set(OrbitList* list, size_t index, const void* elem);
OrbitResult orbit_list_set_int(OrbitList* list, size_t index, orbit_int value);
OrbitResult orbit_list_set_string(OrbitList* list, size_t index, orbit_string value);
OrbitResult orbit_list_set_bool(OrbitList* list, size_t index, orbit_bool value);
OrbitResult orbit_list_set_float(OrbitList* list, size_t index, orbit_float value);
OrbitResult orbit_list_set_ref(OrbitList* list, size_t index, void* value);
void orbit_list_clear(OrbitList* list);
OrbitResult orbit_map_create(OrbitArena* arena, size_t value_size);
OrbitResult orbit_map_resize(OrbitMap* map);
OrbitResult orbit_map_set(OrbitMap* map, const char* key, const void* value);
OrbitResult orbit_map_delete(OrbitMap* map, const char* key);
OrbitResult orbit_map_keys(const OrbitMap* map, OrbitArena* arena);
orbit_int orbit_string_at(orbit_string s, orbit_int index);
orbit_string orbit_string_slice(OrbitArena* arena, orbit_string s, orbit_int start, orbit_int end);
orbit_string orbit_string_slice_known_len(orbit_string s, orbit_int start, orbit_int end, orbit_int totalLen);
orbit_string orbit_int_to_string(OrbitArena* arena, orbit_int value);
orbit_string orbit_float_to_string(OrbitArena* arena, orbit_float value);
orbit_string orbit_bool_to_string(OrbitArena* arena, orbit_bool value);
orbit_string orbit_string_concat(OrbitArena* arena, orbit_string a, orbit_string b);
OrbitList* orbit_string_split(OrbitArena* arena, orbit_string s, orbit_string delim);
orbit_string orbit_string_replace(OrbitArena* arena, orbit_string s, orbit_string old_str, orbit_string new_str);
bool orbit_string_starts_with(orbit_string s, orbit_string prefix);
bool orbit_string_ends_with(orbit_string s, orbit_string suffix);
bool orbit_string_contains(orbit_string s, orbit_string substr);
orbit_int orbit_string_indexOf(orbit_string s, orbit_string substr);
orbit_string orbit_string_to_upper(OrbitArena* arena, orbit_string s);
orbit_string orbit_string_to_lower(OrbitArena* arena, orbit_string s);
orbit_string orbit_string_trim(OrbitArena* arena, orbit_string s);

static uint32_t orbit_api_map_hash(const char* key) {
    uint32_t hash = 2166136261u;
    while (*key) {
        hash ^= (uint8_t)*key++;
        hash *= 16777619u;
    }
    return hash;
}

ORBIT_INLINE orbit_int orbit_string_len(orbit_string s) {
    return s ? (orbit_int)strlen(s) : 0;
}

ORBIT_INLINE void orbit_list_adopt_kind(OrbitList* list, int kind) {
    if (list->elem_kind == ORBIT_ELEM_OPAQUE) {
        list->elem_kind = kind;
        return;
    }
    if (list->elem_kind != kind) {
        orbit_list_kind_error(list->elem_kind, kind);
    }
}
ORBIT_INLINE void orbit_list_expect_kind(const OrbitList* list, int kind) {
    if (list->elem_kind != ORBIT_ELEM_OPAQUE && list->elem_kind != kind) {
        orbit_list_kind_error(list->elem_kind, kind);
    }
}

ORBIT_INLINE OrbitResult orbit_list_get(const OrbitList* list, size_t index) {
    if (!list || !list->data) {
        return orbit_result_err(ORBIT_ERR_NULL_PTR, "list_get: null list");
    }
    if (index >= list->len) {
        return orbit_result_err(ORBIT_ERR_OUT_OF_BOUNDS, "list_get: index out of bounds");
    }
    return orbit_result_ok((char*)list->data + index * list->elem_size);
}

ORBIT_INLINE OrbitResult orbit_list_store(OrbitList* list, uintptr_t word) {
    if (list->len >= list->capacity) {
        OrbitResult grew = orbit_list_grow(list);
        if (!grew.ok) return grew;
    }
    memcpy((char*)list->data + list->len * list->elem_size, &word, sizeof(uintptr_t));
    list->len++;
    return orbit_result_ok(list);
}
ORBIT_INLINE OrbitResult orbit_list_get_value(const OrbitList* list, size_t index) {
    if (!list || !list->data) {
        return orbit_result_err(ORBIT_ERR_NULL_PTR, "list_get: null list");
    }
    if (index >= list->len) {
        return orbit_result_err(ORBIT_ERR_OUT_OF_BOUNDS, "list_get: index out of range");
    }
    uintptr_t word = 0;
    memcpy(&word, (const char*)list->data + index * list->elem_size, sizeof(uintptr_t));
    return orbit_result_ok_word(word);
}
ORBIT_INLINE OrbitResult orbit_list_checked(const OrbitList* list, size_t index, int kind) {
    if (!list || !list->data) {
        return orbit_result_err(ORBIT_ERR_NULL_PTR, "list_get: null list");
    }
    if (index >= list->len) {
        return orbit_result_err(ORBIT_ERR_OUT_OF_BOUNDS, "list_get: index out of range");
    }
    if (kind != ORBIT_ELEM_OPAQUE) {
        orbit_list_expect_kind(list, kind);
    }
    return orbit_list_get_value(list, index);
}
#define ORBIT_LIST_READ_PROLOGUE(list, index)                                        \
    OrbitResult _lr = orbit_list_checked((list), (index), kind);                    \
    if (!_lr.ok) {                                                                  \
        orbit_list_index_error(where, (unsigned long)(index),                        \
                               (list) ? (list)->len : 0,                            \
                               (list) ? (list)->elem_kind : 0, file, line);          \
    }                                                                               \
    uintptr_t _word = 0;                                                             \
    memcpy(&_word, &_lr.value, sizeof(uintptr_t))
ORBIT_INLINE uintptr_t orbit_list_read_word(const OrbitList* list, size_t index,
                                            const char* where, const char* file, int line) {
    const int kind = ORBIT_ELEM_OPAQUE;
    ORBIT_LIST_READ_PROLOGUE(list, index);
    return _word;
}
ORBIT_INLINE orbit_int orbit_list_read_int(const OrbitList* list, size_t index,
                                           const char* where, const char* file, int line) {
    const int kind = ORBIT_ELEM_INT;
    ORBIT_LIST_READ_PROLOGUE(list, index);
    return (orbit_int)(intptr_t)_word;
}
ORBIT_INLINE orbit_bool orbit_list_read_bool(const OrbitList* list, size_t index,
                                             const char* where, const char* file, int line) {
    const int kind = ORBIT_ELEM_BOOL;
    ORBIT_LIST_READ_PROLOGUE(list, index);
    return _word ? true : false;
}
ORBIT_INLINE orbit_string orbit_list_read_string(const OrbitList* list, size_t index,
                                                 const char* where, const char* file, int line) {
    const int kind = ORBIT_ELEM_STRING;
    ORBIT_LIST_READ_PROLOGUE(list, index);
    return (orbit_string)_word;
}
ORBIT_INLINE void* orbit_list_read_ref(const OrbitList* list, size_t index,
                                       const char* where, const char* file, int line) {
    const int kind = ORBIT_ELEM_REF;
    ORBIT_LIST_READ_PROLOGUE(list, index);
    return (void*)_word;
}
ORBIT_INLINE orbit_float orbit_list_read_float(const OrbitList* list, size_t index,
                                               const char* where, const char* file, int line) {
    const int kind = ORBIT_ELEM_FLOAT;
    ORBIT_LIST_READ_PROLOGUE(list, index);
    OrbitElemBox box;
    box.u = _word;
    return box.d;
}
ORBIT_INLINE size_t orbit_list_len(const OrbitList* list) {
    return list ? list->len : 0;
}
ORBIT_INLINE OrbitResult orbit_list_store_at(OrbitList* list, size_t index, int kind, uintptr_t word) {
    if (!list) return orbit_result_err(ORBIT_ERR_NULL_PTR, "list_set: null list");
    if (index >= list->len) {
        return orbit_result_err(ORBIT_ERR_OUT_OF_BOUNDS, "list_set: index out of range");
    }
    if (list->elem_kind == ORBIT_ELEM_OPAQUE) {
        list->elem_kind = kind;
    } else if (list->elem_kind != kind) {
        orbit_list_kind_error(list->elem_kind, kind);
    }
    memcpy((char*)list->data + index * list->elem_size, &word, sizeof(uintptr_t));
    return orbit_result_ok(list);
}

ORBIT_INLINE OrbitResult orbit_map_get(const OrbitMap* map, const char* key) {
    if (!map || !key) {
        return orbit_result_err(ORBIT_ERR_NULL_PTR, "map_get: null argument");
    }

    uint32_t hash = orbit_api_map_hash(key);
    size_t idx = hash & (map->bucket_count - 1);

    while (map->buckets[idx].occupied) {
        if (map->buckets[idx].key == key ||
            (map->buckets[idx].hash == hash && strcmp(map->buckets[idx].key, key) == 0)) {
            return orbit_result_ok(map->buckets[idx].value);
        }
        idx = (idx + 1) & (map->bucket_count - 1);
    }

    return orbit_result_err(ORBIT_ERR_KEY_NOT_FOUND, "map_get: key not found");
}

ORBIT_INLINE bool orbit_map_has(const OrbitMap* map, const char* key) {
    OrbitResult r = orbit_map_get(map, key);
    return r.ok;
}


/* ── External functions: objects and JSON (canonical: runtime/json.c) ── */
OrbitObject* orbit_object_create(OrbitArena* arena);
void orbit_object_set(OrbitObject* o, const char* key, OrbitValue v);
void orbit_object_set_int(OrbitObject* o, const char* key, orbit_int v);
void orbit_object_set_float(OrbitObject* o, const char* key, orbit_float v);
void orbit_object_set_bool(OrbitObject* o, const char* key, orbit_bool v);
void orbit_object_set_string(OrbitObject* o, const char* key, const char* v);
void orbit_object_set_object(OrbitObject* o, const char* key, OrbitObject* v);
void orbit_object_set_list(OrbitObject* o, const char* key, const OrbitList* v);
OrbitValue orbit_object_get(OrbitObject* o, const char* key);
orbit_int orbit_object_get_int(OrbitObject* o, const char* key);
orbit_float orbit_object_get_float(OrbitObject* o, const char* key);
orbit_bool orbit_object_get_bool(OrbitObject* o, const char* key);
const char* orbit_object_get_string(OrbitObject* o, const char* key);
OrbitObject* orbit_object_get_object(OrbitObject* o, const char* key);
const OrbitList* orbit_object_get_list(OrbitObject* o, const char* key);
const char* orbit_object_get_raw(OrbitObject* o, const char* key);
OrbitResult orbit_json_parse(OrbitArena* arena, const char* text);
orbit_int orbit_json_array_len(OrbitObject* o, const char* key);
orbit_int orbit_json_array_get_int(OrbitObject* o, const char* key, orbit_int idx);
orbit_float orbit_json_array_get_float(OrbitObject* o, const char* key, orbit_int idx);
orbit_bool orbit_json_array_get_bool(OrbitObject* o, const char* key, orbit_int idx);
const char* orbit_json_array_get_string(OrbitObject* o, const char* key, orbit_int idx);
OrbitObject* orbit_json_array_get_object(OrbitObject* o, const char* key, orbit_int idx);
const char* orbit_object_to_json(OrbitArena* arena, OrbitObject* o);

/* ── External functions: files (canonical: runtime/file.c) ───────────── */
OrbitResult orbit_file_read(OrbitArena* arena, const char* filename);
bool orbit_file_write(const char* filename, const char* content);
OrbitList* orbit_file_list_dir(OrbitArena* arena, const char* path);
bool orbit_file_exists(const char* filename);
bool orbit_file_delete(const char* filename);
bool orbit_path_is_dir(const char* path);
bool orbit_file_remove_dir(const char* path);

/* ── External functions: OS (canonical: runtime/os.c) ────────────────── */
bool orbit_os_mkdir_p(const char* path);
orbit_string orbit_os_cwd(OrbitArena* arena);
bool orbit_os_chdir(orbit_string path);
orbit_string orbit_os_env(OrbitArena* arena, orbit_string var_name);
orbit_string orbit_os_exec(OrbitArena* arena, orbit_string command);
void orbit_os_exit(orbit_int code);
orbit_int orbit_os_spawn(orbit_string command);
orbit_int orbit_os_run_timeout(orbit_string command, orbit_int timeout_ms, orbit_string capture_path);
orbit_int orbit_os_spawn_bg(orbit_string command, orbit_string logfile);
orbit_int orbit_os_kill(orbit_int pid, orbit_int mode);
orbit_int orbit_os_argc(void);
orbit_string orbit_os_argv(OrbitArena* arena, orbit_int index);
OrbitResult orbit_random_bytes(OrbitArena* arena, orbit_int n);
extern char** _orbit_argv;
extern int _orbit_argc;

/* ── External functions: builtins (canonical: runtime/builtins.c) ────── */
void orbit_print(const char* str);
orbit_int orbit_string_to_int(orbit_string s);
orbit_float orbit_string_to_float(orbit_string s);
orbit_int orbit_clock_ns(void);
orbit_int orbit_clock_ms(void);
orbit_int orbit_wall_seconds(void);
void orbit_sleep_ms(orbit_int ms);
orbit_string orbit_http_query_get(OrbitArena* arena, OrbitRequest* req, orbit_string key);
OrbitList* orbit_http_query_get_all(OrbitArena* arena, OrbitRequest* req, orbit_string key);
orbit_string orbit_http_param_get(OrbitArena* arena, OrbitRequest* req, orbit_string param_name);
orbit_string orbit_http_body_get(OrbitArena* arena, OrbitRequest* req);
orbit_string orbit_json_field(OrbitArena* arena, orbit_string json, orbit_string key);
orbit_string orbit_cache_get(OrbitArena* arena, orbit_string key);
bool orbit_cache_set(orbit_string key, orbit_string val, int64_t ttl);
orbit_string orbit_file_upload_save(OrbitArena* arena, OrbitRequest* req, orbit_string field_name, orbit_string dest_dir);
uint64_t orbit_monotonic_ns(void);
void orbit_system_set_workers(int n);
orbit_int system_uptime(void);
orbit_int system_pid(void);
orbit_int system_active_workers(void);
orbit_int system_http_requests_total(void);
orbit_int system_latency_avg_us(void);
orbit_int system_latency_p50_us(void);
orbit_int system_latency_p95_us(void);
orbit_int system_latency_p99_us(void);
orbit_int system_os_exec(orbit_string cmd);
orbit_string system_env(orbit_string name);

/* ── External functions: crypto (canonical: runtime/crypto.c) ────────── */
orbit_string orbit_base64url_encode(OrbitArena* arena, const uint8_t* data, size_t input_len);
orbit_string orbit_base64url_encode_str(OrbitArena* arena, const char* str);
void orbit_sha256(const uint8_t* data, size_t len, uint8_t hash[32]);
orbit_string orbit_sha256_hex(OrbitArena* arena, const char* str);
void orbit_hmac_sha256(const uint8_t* key, size_t key_len, const uint8_t* data, size_t data_len, uint8_t out[32]);
orbit_string orbit_hmac_sha256_base64url(OrbitArena* arena, const char* key, const char* data);
bool orbit_ct_equal(const char* a, const char* b);

/* ── External functions: selfhost helpers (canonical: runtime/selfhost.c) */
orbit_int orbit_os_argc_selfhost(void);
orbit_string orbit_os_argv_selfhost(orbit_int index);
orbit_string orbit_float_to_string_selfhost(orbit_float value);
orbit_string orbit_os_exec_selfhost(orbit_string command);
orbit_int orbit_os_spawn_selfhost(orbit_string command);
orbit_int orbit_os_run_timeout_selfhost(orbit_string command, orbit_int timeout_ms, orbit_string capture_path);
orbit_int orbit_os_spawn_bg_selfhost(orbit_string command, orbit_string logfile);
orbit_int orbit_os_kill_selfhost(orbit_int pid, orbit_int mode);
orbit_string orbit_os_env_selfhost(orbit_string var_name);
bool orbit_os_isatty_selfhost(orbit_int fd);
orbit_string orbit_os_cwd_selfhost(void);
orbit_string orbit_os_temp_dir_selfhost(void);
void orbit_os_exit_selfhost(orbit_int code);
void orbit_os_write_stderr_selfhost(orbit_string content);
orbit_string orbit_file_read_selfhost(orbit_string path);
bool orbit_file_write_selfhost(orbit_string path, orbit_string content);
OrbitList* orbit_file_list_dir_selfhost(orbit_string path);
orbit_int orbit_string_char_at_selfhost(orbit_string s, orbit_int index);
bool orbit_os_mkdir_selfhost(orbit_string path);
orbit_int orbit_string_cmp_selfhost(orbit_string a, orbit_string b);
orbit_string orbit_string_hash_selfhost(orbit_string s);
orbit_string orbit_int_to_string_selfhost(orbit_int value);
orbit_string orbit_string_from_char_selfhost(orbit_int code);
orbit_string orbit_cbuf_create_selfhost(void);
void orbit_cbuf_append_selfhost(orbit_string buf, orbit_string s);
orbit_string orbit_cbuf_build_selfhost(orbit_string buf);
orbit_string orbit_mem_report_selfhost(void);

/* ── External functions: energy (canonical: runtime/energy.c) ────────── */
void orbit_energy_start(void);
void orbit_energy_stop(void);
int orbit_energy_has_sensor(void);
const char* orbit_energy_source(void);
double orbit_energy_total_joules(void);
double orbit_energy_uptime_s(void);
double orbit_energy_attributable_joules(void);
double orbit_energy_route_joules(uint64_t route_cycles, uint64_t total_cycles);

/* ── External functions: ledger (canonical: runtime/ledger.c) ────────── */
int orbit_ledger_enter(const char* method, const char* path);
void orbit_ledger_exit(int idx, uint64_t cycles, const OrbitArena* arena);
int orbit_ledger_is_loopback(orbit_socket_t s);
orbit_string orbit_ledger_json(OrbitArena* arena);
orbit_string orbit_ledger_html(OrbitArena* arena);
void orbit_ledger_enable_file_dump(void);

/* ── External functions: HTTP (canonical: runtime/http.c) ────────────── */
size_t orbit_http_parse_request(OrbitArena* arena, const char* raw, size_t raw_len, OrbitRequest** out_req);
size_t orbit_http_parse_request_ex(OrbitArena* arena, const char* raw, size_t raw_len, OrbitRequest** out_req, int* out_parse_error);
void orbit_http_limits_reload(void);
OrbitResponse* orbit_http_parse_error_response(OrbitArena* arena, int code);
OrbitResponse* orbit_http_buffer_full_response(OrbitArena* arena, const char* buf, size_t len);
bool orbit_route_match(OrbitArena* arena, OrbitRequest* req, const char* method, const char* pattern);
OrbitResponse* orbit_response_create(OrbitArena* arena, int status, const char* content_type, const char* body);
void orbit_response_add_header(OrbitArena* arena, OrbitResponse* resp, const char* name, const char* value);
orbit_string orbit_response_header_line(OrbitArena* arena, const char* name, const char* value);
void orbit_response_add_headers(OrbitArena* arena, OrbitResponse* resp, const char* block);
OrbitResponse* orbit_response_json(OrbitArena* arena, int status, const char* json);
OrbitResponse* orbit_response_html(OrbitArena* arena, int status, const char* html);
OrbitResponse* orbit_response_error(OrbitArena* arena, int status, const char* message);
OrbitResponse* orbit_response_or_500(OrbitArena* arena, OrbitResponse* resp);
const char* orbit_reason_phrase(int status);
void orbit_send_response(orbit_socket_t client, OrbitResponse* resp);
orbit_string orbit_http_header_get(OrbitArena* arena, OrbitRequest* req, orbit_string name);
OrbitResult orbit_http_client_fetch(OrbitArena* arena, orbit_string url);
void orbit_http_init(void);
void orbit_http_cleanup(void);
#ifndef ORBIT_CUSTOM_ROUTER
int orbit_handle_request(orbit_socket_t client_sock, const char* raw_request, size_t raw_len, OrbitArena* arena, size_t* out_consumed);
#endif

/* ── External functions: Kynx (canonical: runtime/kynx.c) ────────────── */
typedef struct {
    int   pool_size;
    int   rate_limit;
    int   window_ms;
    int   burst;
    int   ban_threshold;
    int   score_increment;
    int   score_decay;
    int   ban_duration_s;
    bool  enabled;
} OrbitKynxConfig;

uint64_t orbit_kynx_now_ns(void);
void orbit_kynx_add_trusted_proxy(const char* cidr);
bool orbit_kynx_is_trusted_proxy(const char* ip_str);
bool orbit_kynx_has_trusted_proxies(void);
void orbit_kynx_effective_ip(const char* peer, const char* xff, char* out, size_t out_len);
void orbit_kynx_register_route_limit(const char* method, const char* path, int rate, int window_ms, int burst);
bool orbit_kynx_check(const char* ip_str);
bool orbit_kynx_check_route(const char* ip_str, const char* method, const char* path);
void orbit_kynx_init(OrbitKynxConfig config);
void orbit_kynx_cleanup(void);
void orbit_kynx_reset(void);
OrbitKynxLease* orbit_kynx_lease_create_for_route(const char* path, const char* method, OrbitArena* arena);
void orbit_kynx_lease_destroy(OrbitKynxLease* lease);
void orbit_kynx_lease_abandon(void);
bool orbit_kynx_lease_check_limits(size_t additional_response_bytes);
uint64_t orbit_kynx_get_total_checks(void);
uint64_t orbit_kynx_get_total_blocked(void);
bool orbit_kynx_is_siege_mode(void);
int orbit_kynx_get_suspicion(const char* ip_str);
int orbit_kynx_last_retry_ms(void);
double orbit_kynx_lease_joules(const OrbitKynxLease* lease);
uint64_t orbit_kynx_lease_cycles(const OrbitKynxLease* lease);

/* ── External data: Pulse dashboard (canonical: runtime/pulse.c) ─────── */
orbit_string orbit_pulse_get_stats_json(OrbitArena* arena);
extern const char* ORBIT_PULSE_DASHBOARD_HTML;

#endif /* ORBIT_API_H */
