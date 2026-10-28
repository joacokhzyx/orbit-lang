/* Interface of runtime/collections.c (generated split; edit by hand from here). */
#ifndef ORBIT_RT_COLLECTIONS_H
#define ORBIT_RT_COLLECTIONS_H

#include "module_prelude.h"

#include "types.h"
#include "arena.h"

#include "arena.h"
#include "types.h"
#include "inline.h"
#include <string.h>
const char* orbit_list_kind_name(int kind);
void orbit_list_index_error(const char* where, unsigned long index,
                            unsigned long len, int kind, const char* file, int line);
void orbit_div_error(const char* file, int64_t line, int64_t kind);
void orbit_list_kind_error(int have, int want);

/** @brief Check that a read asking for @p kind can decode this list.
 *
 * An opaque list is accepted: the kind was never established, so the caller's
 * static type is the only account of what is in there, and refusing would
 * reject the lists the runtime itself builds (see orbit_list_create, which
 * takes no kind). A list that IS typed must agree. */
ORBIT_INLINE void orbit_list_expect_kind(const OrbitList* list, int kind) {
    if (list->elem_kind != ORBIT_ELEM_OPAQUE && list->elem_kind != kind) {
        orbit_list_kind_error(list->elem_kind, kind);
    }
}
OrbitResult orbit_list_create_typed(OrbitArena* arena, size_t elem_size, size_t initial_capacity, int elem_kind);
OrbitResult orbit_list_create(OrbitArena* arena, size_t elem_size, size_t initial_capacity);
OrbitResult orbit_list_grow(OrbitList* list);
OrbitResult orbit_list_push(OrbitList* list, const void* elem);
OrbitResult orbit_list_push_string(OrbitList* list, orbit_string value);
OrbitResult orbit_list_push_int(OrbitList* list, orbit_int value);
OrbitResult orbit_list_push_bool(OrbitList* list, orbit_bool value);
OrbitResult orbit_list_push_ref(OrbitList* list, void* value);
OrbitResult orbit_list_push_float(OrbitList* list, orbit_float value);

/** @brief The word stored in slot @p index, decoded for the list's own kind.
 *
 * This is the read an untyped call site makes: it knows nothing about the
 * element type, so it asks the list. A float list still answers with the
 * double's bits, so the value is not lost -- only the caller's type is. */
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

/** @brief Bounds-check a read, and refuse one whose element type is not the
 *  list's. The kind check runs before the read so a mismatch cannot silently
 *  reinterpret a slot. */
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

/* ── The reads the emitter calls ────────────────────────────────────────────
 *
 * These are what a `list_get` in generated C lowers to. Each one takes the
 * position of the read and stops the process if the index is past the end,
 * because the alternative -- a 0, which is what this used to answer -- is the
 * one value a caller cannot distinguish from a real element.
 *
 * They return the natural C type rather than a Result, so an emitted read is
 * one expression with no temporary and no `_lr.ok` test to get wrong. The
 * float one is the reason the Result-shaped accessor above is not enough: the
 * double travels in the result's word, and a pointer-to-double cast would
 * convert the bits to a number instead of reading them as a double.
 */
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

#undef ORBIT_LIST_READ_PROLOGUE
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
ORBIT_UNUSED OrbitResult orbit_map_delete(OrbitMap* map, const char* key);
ORBIT_UNUSED OrbitResult orbit_map_keys(const OrbitMap* map, OrbitArena* arena);

// ─── String Utilities ────────────────────────────────────────────────────────

ORBIT_INLINE orbit_int orbit_string_len(orbit_string s) {
    return s ? (orbit_int)strlen(s) : 0;
}
ORBIT_UNUSED orbit_int orbit_string_at(orbit_string s, orbit_int index);
ORBIT_UNUSED orbit_string orbit_string_slice(OrbitArena* arena, orbit_string s, orbit_int start, orbit_int end);
ORBIT_UNUSED orbit_string orbit_string_slice_known_len(orbit_string s, orbit_int start, orbit_int end, orbit_int totalLen);
orbit_string orbit_int_to_string(OrbitArena* arena, orbit_int value);
orbit_string orbit_float_to_string(OrbitArena* arena, orbit_float value);
orbit_string orbit_bool_to_string(OrbitArena* arena, orbit_bool value);
ORBIT_XLINK orbit_string orbit_string_from_char(OrbitArena* arena, orbit_int code);
ORBIT_UNUSED orbit_string orbit_string_concat(OrbitArena* arena, orbit_string a, orbit_string b);

// ─── Chunk Buffer (OrbitCBuf) ─────────────────────────────────────────────
// Arena-backed append-only byte buffer. Replaces repeated `out = out + frag`
// string concatenation (which copies the whole prefix per append and retains
// every intermediate in the arena) with amortised O(1) appends into one
// geometric buffer. The handle is an opaque pointer; Orbit sides carry it in
// a `string`-typed local (never inspected, only passed back) because the
// self-host `int` type is 32 bits and cannot hold a 64-bit address.
typedef struct OrbitCBuf {
    char* data;
    size_t len;
    size_t cap;
    OrbitArena* arena;
} OrbitCBuf;

// Small initial reserve on purpose: the arena commits pages as the cursor
// advances, so an oversized reserve per buffer (one per generated function)
// would charge hundreds of MB of commit for pages never touched. Growth
// doubles and abandons at most ~1x the final size, once per buffer.
#ifndef ORBIT_CBUF_INIT_CAP
#define ORBIT_CBUF_INIT_CAP (65536u)
#endif
ORBIT_XLINK OrbitCBuf* orbit_cbuf_create(OrbitArena* arena, size_t cap);
ORBIT_XLINK bool orbit_cbuf_append(OrbitCBuf* buf, orbit_string s);
ORBIT_XLINK orbit_string orbit_cbuf_build(OrbitCBuf* buf);
ORBIT_UNUSED OrbitList* orbit_string_split(OrbitArena* arena, orbit_string s, orbit_string delim);
ORBIT_UNUSED orbit_string orbit_string_replace(OrbitArena* arena, orbit_string s, orbit_string old_str, orbit_string new_str);
bool orbit_string_starts_with(orbit_string s, orbit_string prefix);
bool orbit_string_ends_with(orbit_string s, orbit_string suffix);
bool orbit_string_contains(orbit_string s, orbit_string substr);
orbit_int orbit_string_indexOf(orbit_string s, orbit_string substr);
orbit_string orbit_string_to_upper(OrbitArena* arena, orbit_string s);
orbit_string orbit_string_to_lower(OrbitArena* arena, orbit_string s);
orbit_string orbit_string_trim(OrbitArena* arena, orbit_string s);

#endif
