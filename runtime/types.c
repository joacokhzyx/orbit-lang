/**
 * @file  types.c
 * @brief Orbit runtime type system: primitives, Result<T,E>, Option<T>, Slice<T>, List<T>, Map<K,V>, and tagged unions.
 *
 * Every user-facing type is arena-allocated and C99-compatible.  Result<T,E>
 * replaces exceptions with an explicit tagged union; Option<T> wraps nullable
 * values; Slice<T> provides a zero-copy non-owning view; and OrbitTaggedUnion
 * / OrbitInterface support Orbit's union and trait-object semantics at runtime.
 */
#ifndef ORBIT_TYPES_H
#define ORBIT_TYPES_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "inline.h"

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

struct OrbitArena;

typedef struct OrbitModel {
    void* data;
    orbit_string name;
    orbit_string message;
    orbit_int code;
    orbit_int line;
    orbit_int column;
    void* diagnostics;
} OrbitModel;

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

/** @brief Construct a successful Result carrying @p value. */
static OrbitResult orbit_result_ok(void* value) {
    OrbitResult r;
    r.ok         = true;
    r.error_code = ORBIT_ERR_NONE;
    r.error_msg  = NULL;
    r.value      = value;
    return r;
}

/** @brief Construct a successful Result carrying a 64-bit element word.
 *
 * The transport form for a value that is not a pointer: an int, a bool, or a
 * double's bit pattern. memcpy rather than a cast, so no int-to-pointer
 * conversion is invented. */
static ORBIT_UNUSED OrbitResult orbit_result_ok_word(uintptr_t word) {
    OrbitResult r;
    r.ok         = true;
    r.error_code = ORBIT_ERR_NONE;
    r.error_msg  = NULL;
    r.value      = NULL;
    memcpy(&r.value, &word, sizeof(uintptr_t));
    return r;
}


/** @brief Construct a failed Result with the given error @p code and human-readable @p msg. */
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



/* ── Element kinds — what a list holds, so a read can hand it back typed ──
 *
 * A list has exactly one element type. `elem_kind` records which, and every
 * read decodes the slot through it: without this a read handed back the raw
 * word, so a list of ints and a list of strings were the same value to the
 * caller and `.at()` on `[10,20,30]` could not tell an int from an address.
 *
 * ORBIT_ELEM_OPAQUE is the untyped list -- the kind was never established,
 * because the list was built by a caller that does not know it either. A read
 * on an opaque list hands back the stored word undecoded, which is the
 * behaviour every list had before this field existed.
 */
typedef enum {
    ORBIT_ELEM_OPAQUE = 0,   /* kind never established; reads are raw */
    ORBIT_ELEM_STRING = 1,   /* char*                                  */
    ORBIT_ELEM_INT    = 2,   /* orbit_int, sign-extended                */
    ORBIT_ELEM_FLOAT  = 3,   /* double, by bit pattern                  */
    ORBIT_ELEM_BOOL   = 4,   /* orbit_bool, 0 or 1                      */
    ORBIT_ELEM_REF    = 5    /* list / map / object / fn pointer        */
} OrbitElemKind;

/* The one slot layout, 8 bytes, for every element type.
 *
 * An Orbit value travels through a register as a uintptr_t, so an int, a bool
 * and a pointer all fit in a word and a read is a copy. A double does not fit
 * the same way: converting a double to uintptr_t truncates it to an integer,
 * which is how `[1.5, 2.5].get(0)` came to answer 1. Storing the bit pattern
 * instead makes the round trip exact. */
typedef union {
    uintptr_t  u;
    intptr_t   i;
    orbit_int  n;
    double     d;
    void*      p;
} OrbitElemBox;

/* ── List<T> — Arena-backed dynamic array ──────────────────────────── *
 *
 * Growth strategy: capacity doubles on overflow (within arena).
 * Since arenas use bump allocation, "realloc" means copy-forward.
 * The old memory is abandoned (reclaimed when arena resets).
 *
 * Memory layout: [header] [...items contiguous in arena...]
 * This gives O(1) indexed access and cache-prefetch-friendly iteration.
 *
 * elem_kind is the element type, set by the first typed push and by
 * list_create_typed. See OrbitElemKind above.
 * ────────────────────────────────────────────────────────────────────── */

typedef struct {
    void*           data;
    size_t          len;
    size_t          capacity;
    size_t          elem_size;
    int             elem_kind;          /* OrbitElemKind */
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
