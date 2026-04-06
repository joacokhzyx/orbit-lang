#ifndef ORBIT_TYPES_H
#define ORBIT_TYPES_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

/* ──────────────────────────────────────────────────────────────────────
 * Orbit Type System — Phase 2: Type Resonance & Collections
 *
 * Design Invariants:
 *   1. Every type is arena-allocated. No malloc/free in user code.
 *   2. Result<T,E> replaces all exceptions. No segfaults, no longjmp.
 *   3. Collections (List, Map) grow within the arena. Zero-copy reads.
 *   4. All structs are aligned to cache-line boundaries where beneficial.
 *   5. C99 strict. No VLAs, no compound literals in headers.
 *   6. Internal linkage (static) for all implementation functions.
 *
 * Self-hosting note: these types map 1:1 to Orbit's type system.
 * ────────────────────────────────────────────────────────────────────── */

/* ── Primitive Type Aliases ─────────────────────────────────────────── */
typedef const char* orbit_string;
typedef int         orbit_int;
typedef double      orbit_float;
typedef double      orbit_decimal;
typedef bool        orbit_bool;

/* ── Forward Declarations ───────────────────────────────────────────── */
struct OrbitArena;

/* ── Result<T, E> — Algebraic error handling ────────────────────────── *
 *
 * OrbitResult replaces exceptions with explicit tagged unions.
 * Usage pattern:
 *   OrbitResult r = orbit_result_ok(ptr);
 *   if (!r.ok) { handle r.error_msg; }
 *   MyType* val = (MyType*)r.value;
 *
 * Zero-overhead: sizeof(OrbitResult) == 32 bytes (2 cache words on x64).
 * ────────────────────────────────────────────────────────────────────── */

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

static OrbitResult orbit_result_ok(void* value) {
    OrbitResult r;
    r.ok         = true;
    r.error_code = ORBIT_ERR_NONE;
    r.error_msg  = NULL;
    r.value      = value;
    return r;
}

static OrbitResult orbit_result_ok_int(orbit_int val) {
    OrbitResult r;
    r.ok         = true;
    r.error_code = ORBIT_ERR_NONE;
    r.error_msg  = NULL;
    /* Store int directly in pointer-sized slot (safe on 32/64-bit) */
    r.value      = NULL;
    memcpy(&r.value, &val, sizeof(orbit_int));
    return r;
}

static OrbitResult orbit_result_err(OrbitErrorCode code, const char* msg) {
    OrbitResult r;
    r.ok         = false;
    r.error_code = code;
    r.error_msg  = msg;
    r.value      = NULL;
    return r;
}

/* Convenience macro: unwrap-or-return for Result chaining */
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

/* ── Option<T> — Nullable wrapper ──────────────────────────────────── */

typedef struct {
    bool   has_value;
    void*  value;
} OrbitOption;

static OrbitOption orbit_some(void* value) {
    OrbitOption o;
    o.has_value = true;
    o.value     = value;
    return o;
}

static OrbitOption orbit_none(void) {
    OrbitOption o;
    o.has_value = false;
    o.value     = NULL;
    return o;
}

/* ── Slice<T> — Non-owning view over contiguous memory ─────────────── *
 *
 * Zero-copy: points into arena memory. No allocation.
 * Cache-friendly: linear traversal over data ptr.
 * ────────────────────────────────────────────────────────────────────── */

typedef struct {
    void*  data;
    size_t len;
    size_t elem_size;
} OrbitSlice;

static OrbitSlice orbit_slice_empty(size_t elem_size) {
    OrbitSlice s;
    s.data      = NULL;
    s.len       = 0;
    s.elem_size = elem_size;
    return s;
}

static OrbitResult orbit_slice_get(const OrbitSlice* s, size_t index) {
    if (!s || !s->data) {
        return orbit_result_err(ORBIT_ERR_NULL_PTR, "slice is null");
    }
    if (index >= s->len) {
        return orbit_result_err(ORBIT_ERR_OUT_OF_BOUNDS, "slice index out of bounds");
    }
    return orbit_result_ok((char*)s->data + index * s->elem_size);
}

/* ── List<T> — Arena-backed dynamic array ──────────────────────────── *
 *
 * Growth strategy: capacity doubles on overflow (within arena).
 * Since arenas use bump allocation, "realloc" means copy-forward.
 * The old memory is abandoned (reclaimed when arena resets).
 *
 * Memory layout: [header] [...items contiguous in arena...]
 * This gives O(1) indexed access and cache-prefetch-friendly iteration.
 * ────────────────────────────────────────────────────────────────────── */

typedef struct {
    void*           data;
    size_t          len;
    size_t          capacity;
    size_t          elem_size;
    struct OrbitArena* arena;   /* owning arena for growth */
} OrbitList;

/* ── Map<K,V> — Arena-backed open-addressing hash map ──────────────── *
 *
 * Uses Robin Hood hashing with linear probing.
 * All memory lives in the arena.
 * Key comparison: pointer equality first (from string pool), then memcmp.
 *
 * Load factor: resizes at 75%. Resize means allocate new bucket array
 * in arena and rehash (old buckets abandoned until arena reset).
 * ────────────────────────────────────────────────────────────────────── */

#define ORBIT_MAP_LOAD_FACTOR     75
#define ORBIT_MAP_INITIAL_BUCKETS 16

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

/* ── Tagged Union support ──────────────────────────────────────────── *
 *
 * OrbitUnion is the runtime representation of `union` types in Orbit.
 * The `tag` field is a type-safe discriminant (enum value).
 * The `data` field is a pointer into arena memory with the variant payload.
 *
 * Generated code will produce typed accessors for each variant.
 * ────────────────────────────────────────────────────────────────────── */

typedef struct {
    int     tag;
    void*   data;
    size_t  data_size;
} OrbitTaggedUnion;

static OrbitTaggedUnion orbit_tagged_union_create(int tag, void* data, size_t size) {
    OrbitTaggedUnion u;
    u.tag       = tag;
    u.data      = data;
    u.data_size = size;
    return u;
}

static OrbitResult orbit_tagged_union_get(const OrbitTaggedUnion* u, int expected_tag) {
    if (!u) {
        return orbit_result_err(ORBIT_ERR_NULL_PTR, "union is null");
    }
    if (u->tag != expected_tag) {
        return orbit_result_err(ORBIT_ERR_TYPE_MISMATCH, "union tag mismatch");
    }
    return orbit_result_ok(u->data);
}

/* ── Interface/Trait vtable ────────────────────────────────────────── *
 *
 * OrbitInterface is the runtime representation of trait objects.
 * Uses a vtable (function pointer table) for dynamic dispatch.
 * The `self` pointer is the concrete implementor.
 * ────────────────────────────────────────────────────────────────────── */

typedef struct {
    void*   self;        /* pointer to concrete object */
    void**  vtable;      /* array of function pointers */
    size_t  vtable_len;
} OrbitInterface;

#endif
