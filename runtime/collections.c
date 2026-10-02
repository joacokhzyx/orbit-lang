/**
 * @file  collections.c
 * @brief Arena-backed generic List<T> and Map<K,V> implementations for Orbit.
 *
 * All memory is sourced from the request arena — no malloc/free in user code.
 * List<T> uses contiguous bump-allocated storage with copy-forward growth.
 * Map<K,V> uses open-addressing linear-probe hashing (FNV-1a) with a 75 % load
 * factor and tombstone-free deletion.  Both grow within the same arena, with
 * retired buckets reclaimed on arena reset.  String utilities append at the
 * end for convenient string manipulation from generated Orbit code.
 */
#ifndef ORBIT_COLLECTIONS_H
#define ORBIT_COLLECTIONS_H

#include "arena.c"
#include "types.c"
#include "inline.h"
#include <string.h>

/* ──────────────────────────────────────────────────────────────────────
 * Orbit Collections — Arena-backed List<T> and Map<K,V>
 *
 * Design Invariants:
 *   1. All memory comes from the arena. No malloc/free.
 *   2. All operations return OrbitResult. No exceptions.
 *   3. Read operations are zero-copy (return pointers into arena).
 *   4. Cache-friendly: contiguous storage, linear probing.
 *   5. C99 strict. Ready for self-hosting.
 * ────────────────────────────────────────────────────────────────────── */

/* ═══════════════════════════════════════════════════════════════════════
 * LIST<T> IMPLEMENTATION
 * ═══════════════════════════════════════════════════════════════════════ */

// ─── List<T> ────────────────────────────────────────────────────────────────

/** @brief The name of an element kind, for a diagnostic.
 *
 *  Deliberately a fixed table of literals rather than a %d over the enum: a
 *  list diagnostic is read by a person who has never seen the enum, and
 *  "list index 99 out of range (length 2, elements are int)" is a sentence
 *  while "out of range (length 2, elements are 2)" is not. */
const char* orbit_list_kind_name(int kind) {
    switch (kind) {
        case ORBIT_ELEM_STRING: return "string";
        case ORBIT_ELEM_INT:    return "int";
        case ORBIT_ELEM_FLOAT:  return "float";
        case ORBIT_ELEM_BOOL:   return "bool";
        case ORBIT_ELEM_REF:    return "reference";
        case ORBIT_ELEM_OPAQUE: return "untyped";
        default:                return "unknown";
    }
}

/* ── The two list diagnostics ────────────────────────────────────────────
 *
 * Both of these used to be silent, and silence is the defect. A read past the
 * end of a list answered the same 0 as a slot that really held 0, so a caller
 * could not tell a bug from a value; and a list with no element type could be
 * read as the wrong type entirely, which is not a value at all but a pointer
 * read as a character. Neither is recoverable at the use site, because the use
 * site has already been handed the number. So the list says so, here, where
 * the index and the length are both known, and stops.
 *
 * Both stop the process rather than returning a sentinel. There is no
 * `option` in the language to shape an answer as, and a sentinel is exactly
 * the thing that was wrong: an out-of-range 0 and a stored 0 are the same
 * value, so a caller that checks its result still cannot tell them apart.
 *
 * The bounds diagnostic names the enclosing function and the generated-C
 * location, because the emitted read passes __func__ and __LINE__ and the IR
 * carries no Orbit position to do better with (a match arm is the only
 * positioned node in the compiler today). The kind diagnostic has no position
 * at all: it can be raised from inside an always_inline runtime helper, where
 * __func__ would be the helper's own name and telling the user that is worse
 * than saying nothing.
 */
void orbit_list_index_error(const char* where, unsigned long index,
                            unsigned long len, int kind, const char* file, int line) {
    fprintf(stderr,
            "orbit: list index out of range\n"
            "  index    %lu\n"
            "  length   %lu\n"
            "  elements %s\n"
            "  in       %s (%s:%d)\n",
            index, len, orbit_list_kind_name(kind),
            where ? where : "<toplevel>", file, line);
    fflush(stderr);
    exit(2);
}

void orbit_list_kind_error(int have, int want) {
    fprintf(stderr,
            "orbit: list element type mismatch\n"
            "  list holds %s, this value is %s\n"
            "  a list has one element type, so a read and a write must agree on it\n",
            orbit_list_kind_name(have), orbit_list_kind_name(want));
    fflush(stderr);
    exit(2);
}

/** @brief Adopt @p kind as the list's element type, or report the conflict.
 *
 * The first typed push or typed set establishes the kind; a later one that
 * disagrees is a type error, not something to paper over. Leaving the list
 * alone here is what made F-0009's `indexOfStr` compare a list pointer with a
 * string and answer -1: the list was holding two kinds and nothing said so. */
ORBIT_INLINE void orbit_list_adopt_kind(OrbitList* list, int kind) {
    if (list->elem_kind == ORBIT_ELEM_OPAQUE) {
        list->elem_kind = kind;
        return;
    }
    if (list->elem_kind != kind) {
        orbit_list_kind_error(list->elem_kind, kind);
    }
}

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

OrbitResult orbit_list_create_typed(OrbitArena* arena, size_t elem_size, size_t initial_capacity, int elem_kind) {
    if (!arena) arena = orbit_arena_get_global();
    if (!arena || elem_size == 0) {
        fprintf(stderr, "[collections] list_create FAILED: arena=%p elem_size=%zu\n", (void*)arena, elem_size);
        return orbit_result_err(ORBIT_ERR_INVALID_ARG, "list: null arena or zero elem_size");
    }
    if (initial_capacity == 0) initial_capacity = 8;

    OrbitList* list = (OrbitList*)orbit_alloc(arena, sizeof(OrbitList));
    if (!list) {
        return orbit_result_err(ORBIT_ERR_OUT_OF_MEMORY, "list: header alloc failed");
    }

    void* data = orbit_alloc(arena, elem_size * initial_capacity);
    if (!data) {
        return orbit_result_err(ORBIT_ERR_OUT_OF_MEMORY, "list: data alloc failed");
    }

    list->data      = data;
    list->len       = 0;
    list->capacity  = initial_capacity;
    list->elem_size = elem_size;
    list->elem_kind = elem_kind;
    list->arena     = arena;

    return orbit_result_ok(list);
}

OrbitResult orbit_list_create(OrbitArena* arena, size_t elem_size, size_t initial_capacity) {
    return orbit_list_create_typed(arena, elem_size, initial_capacity, ORBIT_ELEM_OPAQUE);
}

/* Grow the backing array, copying existing data forward in the arena.
 * Old memory is abandoned (reclaimed on arena reset). */
OrbitResult orbit_list_grow(OrbitList* list) {
    if (!list || !list->arena) {
        return orbit_result_err(ORBIT_ERR_NULL_PTR, "list_grow: null list");
    }

    size_t new_cap = list->capacity * 2;
    void* new_data = orbit_alloc(list->arena, list->elem_size * new_cap);
    if (!new_data) {
        return orbit_result_err(ORBIT_ERR_OUT_OF_MEMORY, "list_grow: alloc failed");
    }

    /* Zero-copy forward: memcpy existing, old region abandoned */
    memcpy(new_data, list->data, list->len * list->elem_size);
    list->data     = new_data;
    list->capacity = new_cap;

    return orbit_result_ok(list);
}

OrbitResult orbit_list_push(OrbitList* list, const void* elem) {
    if (!list || !elem) {
        return orbit_result_err(ORBIT_ERR_NULL_PTR, "list_push: null argument");
    }

    if (list->len >= list->capacity) {
        OrbitResult grow_result = orbit_list_grow(list);
        if (!grow_result.ok) return grow_result;
    }

    memcpy((char*)list->data + list->len * list->elem_size, elem, list->elem_size);
    list->len++;

    return orbit_result_ok(list);
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

/* ── Typed element access ──────────────────────────────────────────────────
 *
 * The slot word and the value are not the same thing. A slot is always eight
 * bytes; what is IN it depends on the list's kind, and these six functions are
 * the only place that mapping is written down:
 *
 *   string  the pointer itself
 *   int     the 32-bit value, sign extended into the word
 *   bool    0 or 1
 *   ref     the pointer itself
 *   float   the double's IEEE-754 bit pattern, NOT its numeric value
 *
 * The float case is the whole reason a kind is needed. A double does not
 * survive a conversion to uintptr_t -- 1.5 becomes 1 -- so a float element
 * cannot be stored the way an int is. memcpy of the bits is the only exact
 * round trip, and reading it back as a double is what makes
 * `[1.5, 2.5].get(0)` answer 1.5 instead of 1.
 *
 * Every one of these returns the value in the result's word slot rather than a
 * pointer to it, so the caller can hand it straight to a register, which is
 * where an Orbit value lives.
 */

/** @brief Store the word @p word into the next slot, growing if it has to. */
ORBIT_INLINE OrbitResult orbit_list_store(OrbitList* list, uintptr_t word) {
    if (list->len >= list->capacity) {
        OrbitResult grew = orbit_list_grow(list);
        if (!grew.ok) return grew;
    }
    memcpy((char*)list->data + list->len * list->elem_size, &word, sizeof(uintptr_t));
    list->len++;
    return orbit_result_ok(list);
}

OrbitResult orbit_list_push_string(OrbitList* list, orbit_string value) {
    if (!list) return orbit_result_err(ORBIT_ERR_NULL_PTR, "list_push: null list");
    orbit_list_adopt_kind(list, ORBIT_ELEM_STRING);
    return orbit_list_store(list, (uintptr_t)value);
}

OrbitResult orbit_list_push_int(OrbitList* list, orbit_int value) {
    if (!list) return orbit_result_err(ORBIT_ERR_NULL_PTR, "list_push: null list");
    orbit_list_adopt_kind(list, ORBIT_ELEM_INT);
    return orbit_list_store(list, (uintptr_t)(intptr_t)value);
}

OrbitResult orbit_list_push_bool(OrbitList* list, orbit_bool value) {
    if (!list) return orbit_result_err(ORBIT_ERR_NULL_PTR, "list_push: null list");
    orbit_list_adopt_kind(list, ORBIT_ELEM_BOOL);
    return orbit_list_store(list, (uintptr_t)(value ? 1 : 0));
}

OrbitResult orbit_list_push_ref(OrbitList* list, void* value) {
    if (!list) return orbit_result_err(ORBIT_ERR_NULL_PTR, "list_push: null list");
    orbit_list_adopt_kind(list, ORBIT_ELEM_REF);
    return orbit_list_store(list, (uintptr_t)value);
}

OrbitResult orbit_list_push_float(OrbitList* list, orbit_float value) {
    if (!list) return orbit_result_err(ORBIT_ERR_NULL_PTR, "list_push: null list");
    orbit_list_adopt_kind(list, ORBIT_ELEM_FLOAT);
    OrbitElemBox box;
    box.d = value;
    return orbit_list_store(list, box.u);
}

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

ORBIT_INLINE size_t orbit_list_len(const OrbitList* list) {
    return list ? list->len : 0;
}

OrbitResult orbit_list_pop(OrbitList* list) {
    if (!list || list->len == 0) {
        return orbit_result_err(ORBIT_ERR_OUT_OF_BOUNDS, "list_pop: empty list");
    }
    list->len--;
    return orbit_result_ok((char*)list->data + list->len * list->elem_size);
}

OrbitResult orbit_list_set(OrbitList* list, size_t index, const void* elem) {
    if (!list || !elem) {
        return orbit_result_err(ORBIT_ERR_NULL_PTR, "list_set: null argument");
    }
    if (index >= list->len) {
        return orbit_result_err(ORBIT_ERR_OUT_OF_BOUNDS, "list_set: index out of bounds");
    }
    memcpy((char*)list->data + index * list->elem_size, elem, list->elem_size);
    return orbit_result_ok(list);
}

/* The typed writes. `set` cannot move the length, so a write into a slot no
 * push has typed leaves the list's kind alone -- a list that has never been
 * pushed to has no element type yet, and inferring one from an assignment would
 * make `xs[0] = 1; xs[0] = "s"` depend on statement order. */

/** @brief Bounds- and kind-check a typed write, then put @p word in the slot. */
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

OrbitResult orbit_list_set_int(OrbitList* list, size_t index, orbit_int value) {
    return orbit_list_store_at(list, index, ORBIT_ELEM_INT, (uintptr_t)(intptr_t)value);
}

OrbitResult orbit_list_set_string(OrbitList* list, size_t index, orbit_string value) {
    return orbit_list_store_at(list, index, ORBIT_ELEM_STRING, (uintptr_t)value);
}

OrbitResult orbit_list_set_bool(OrbitList* list, size_t index, orbit_bool value) {
    return orbit_list_store_at(list, index, ORBIT_ELEM_BOOL, (uintptr_t)(value ? 1 : 0));
}

OrbitResult orbit_list_set_float(OrbitList* list, size_t index, orbit_float value) {
    OrbitElemBox box;
    box.d = value;
    return orbit_list_store_at(list, index, ORBIT_ELEM_FLOAT, box.u);
}

OrbitResult orbit_list_set_ref(OrbitList* list, size_t index, void* value) {
    return orbit_list_store_at(list, index, ORBIT_ELEM_REF, (uintptr_t)value);
}


/* Clear without deallocation — O(1) reset */
void orbit_list_clear(OrbitList* list) {
    if (list) list->len = 0;
}

// ─── Map<K,V> ───────────────────────────────────────────────────────────────

/* FNV-1a hash for string keys — fast, cache-friendly, good distribution */
static uint32_t orbit_map_hash(const char* key) {
    uint32_t hash = 2166136261u;
    while (*key) {
        hash ^= (uint8_t)*key++;
        hash *= 16777619u;
    }
    return hash;
}

OrbitResult orbit_map_create(OrbitArena* arena, size_t value_size) {
    if (!arena) arena = orbit_arena_get_global();
    if (!arena || value_size == 0) {
        return orbit_result_err(ORBIT_ERR_INVALID_ARG, "map: null arena or zero value_size");
    }

    OrbitMap* map = (OrbitMap*)orbit_alloc(arena, sizeof(OrbitMap));
    if (!map) {
        return orbit_result_err(ORBIT_ERR_OUT_OF_MEMORY, "map: header alloc failed");
    }

    size_t bucket_count = ORBIT_MAP_INITIAL_BUCKETS;
    OrbitMapEntry* buckets = (OrbitMapEntry*)orbit_alloc(arena, sizeof(OrbitMapEntry) * bucket_count);
    if (!buckets) {
        return orbit_result_err(ORBIT_ERR_OUT_OF_MEMORY, "map: bucket alloc failed");
    }

    memset(buckets, 0, sizeof(OrbitMapEntry) * bucket_count);

    map->buckets      = buckets;
    map->bucket_count = bucket_count;
    map->count        = 0;
    map->value_size   = value_size;
    map->arena        = arena;

    return orbit_result_ok(map);
}

OrbitResult orbit_map_resize(OrbitMap* map) {
    if (!map || !map->arena) {
        return orbit_result_err(ORBIT_ERR_NULL_PTR, "map_resize: null map");
    }

    size_t new_bucket_count = map->bucket_count * 2;
    OrbitMapEntry* new_buckets = (OrbitMapEntry*)orbit_alloc(
        map->arena, sizeof(OrbitMapEntry) * new_bucket_count
    );
    if (!new_buckets) {
        return orbit_result_err(ORBIT_ERR_OUT_OF_MEMORY, "map_resize: alloc failed");
    }
    memset(new_buckets, 0, sizeof(OrbitMapEntry) * new_bucket_count);

    /* Rehash all existing entries */
    for (size_t i = 0; i < map->bucket_count; i++) {
        if (map->buckets[i].occupied) {
            OrbitMapEntry* entry = &map->buckets[i];
            size_t idx = entry->hash & (new_bucket_count - 1);

            while (new_buckets[idx].occupied) {
                idx = (idx + 1) & (new_bucket_count - 1);
            }

            new_buckets[idx] = *entry;
        }
    }

    /* Old buckets abandoned in arena — reclaimed on reset */
    map->buckets      = new_buckets;
    map->bucket_count = new_bucket_count;

    return orbit_result_ok(map);
}

OrbitResult orbit_map_set(OrbitMap* map, const char* key, const void* value) {
    if (!map || !key || !value) {
        return orbit_result_err(ORBIT_ERR_NULL_PTR, "map_set: null argument");
    }

    /* Resize at 75% load */
    if (map->count * 100 >= map->bucket_count * ORBIT_MAP_LOAD_FACTOR) {
        OrbitResult resize_res = orbit_map_resize(map);
        if (!resize_res.ok) return resize_res;
    }

    uint32_t hash = orbit_map_hash(key);
    size_t idx = hash & (map->bucket_count - 1);

    while (map->buckets[idx].occupied) {
        /* Fast path: pointer equality from string pool */
        if (map->buckets[idx].key == key ||
            (map->buckets[idx].hash == hash && strcmp(map->buckets[idx].key, key) == 0)) {
            /* Update existing value */
            void* val_ptr = orbit_alloc(map->arena, map->value_size);
            if (!val_ptr) {
                return orbit_result_err(ORBIT_ERR_OUT_OF_MEMORY, "map_set: value alloc failed");
            }
            memcpy(val_ptr, value, map->value_size);
            map->buckets[idx].value = val_ptr;
            return orbit_result_ok(val_ptr);
        }
        idx = (idx + 1) & (map->bucket_count - 1);
    }

    /* Allocate value in arena */
    void* val_ptr = orbit_alloc(map->arena, map->value_size);
    if (!val_ptr) {
        return orbit_result_err(ORBIT_ERR_OUT_OF_MEMORY, "map_set: value alloc failed");
    }
    memcpy(val_ptr, value, map->value_size);

    map->buckets[idx].key      = key;
    map->buckets[idx].value    = val_ptr;
    map->buckets[idx].hash     = hash;
    map->buckets[idx].occupied = true;
    map->count++;

    return orbit_result_ok(val_ptr);
}

ORBIT_INLINE OrbitResult orbit_map_get(const OrbitMap* map, const char* key) {
    if (!map || !key) {
        return orbit_result_err(ORBIT_ERR_NULL_PTR, "map_get: null argument");
    }

    uint32_t hash = orbit_map_hash(key);
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


static ORBIT_UNUSED OrbitResult orbit_map_delete(OrbitMap* map, const char* key) {
    if (!map || !key) {
        return orbit_result_err(ORBIT_ERR_NULL_PTR, "map_delete: null argument");
    }

    uint32_t hash = orbit_map_hash(key);
    size_t idx = hash & (map->bucket_count - 1);

    while (map->buckets[idx].occupied) {
        if (map->buckets[idx].key == key ||
            (map->buckets[idx].hash == hash && strcmp(map->buckets[idx].key, key) == 0)) {
            /* Tombstone-free deletion: shift subsequent entries backward */
            map->buckets[idx].occupied = false;
            map->count--;

            /* Rehash following cluster */
            size_t next = (idx + 1) & (map->bucket_count - 1);
            while (map->buckets[next].occupied) {
                OrbitMapEntry entry = map->buckets[next];
                map->buckets[next].occupied = false;
                map->count--;

                /* Re-insert */
                size_t target = entry.hash & (map->bucket_count - 1);
                while (map->buckets[target].occupied) {
                    target = (target + 1) & (map->bucket_count - 1);
                }
                map->buckets[target] = entry;
                map->count++;

                next = (next + 1) & (map->bucket_count - 1);
            }

            return orbit_result_ok(NULL);
        }
        idx = (idx + 1) & (map->bucket_count - 1);
    }

    return orbit_result_err(ORBIT_ERR_KEY_NOT_FOUND, "map_delete: key not found");
}

/* Get all keys as a List<orbit_string> — useful for iteration */
static ORBIT_UNUSED OrbitResult orbit_map_keys(const OrbitMap* map, OrbitArena* arena) {
    if (!map || !arena) {
        return orbit_result_err(ORBIT_ERR_NULL_PTR, "map_keys: null argument");
    }

    OrbitResult list_res = orbit_list_create(arena, sizeof(orbit_string), map->count > 0 ? map->count : 4);
    if (!list_res.ok) return list_res;
    OrbitList* keys = (OrbitList*)list_res.value;

    for (size_t i = 0; i < map->bucket_count; i++) {
        if (map->buckets[i].occupied) {
            orbit_list_push(keys, &map->buckets[i].key);
        }
    }

    return orbit_result_ok(keys);
}

// ─── String Utilities ────────────────────────────────────────────────────────

ORBIT_INLINE orbit_int orbit_string_len(orbit_string s) {
    return s ? (orbit_int)strlen(s) : 0;
}

static ORBIT_UNUSED orbit_int orbit_string_at(orbit_string s, orbit_int index) {
    if (!s) return 0;
    orbit_int len = (orbit_int)strlen(s);
    if (index < 0 || index >= len) return 0;
    return (unsigned char)s[index];
}

static ORBIT_UNUSED orbit_string orbit_string_slice(OrbitArena* arena, orbit_string s, orbit_int start, orbit_int end) {
    if (!s) return "";
    OrbitArena* ar = (arena && arena->base) ? arena : orbit_arena_get_global();
    orbit_int len = (orbit_int)strlen(s);
    if (start < 0) start = 0;
    if (end > len) end = len;
    if (start >= end) return "";

    orbit_int slice_len = end - start;
    char* buf = (char*)orbit_alloc(ar, slice_len + 1);
    if (!buf) return "";
    memcpy(buf, s + start, slice_len);
    buf[slice_len] = '\0';
    return buf;
}

orbit_string orbit_int_to_string(OrbitArena* arena, orbit_int value) {
    if (!arena) return "";

    char tmp[32];
    int n = snprintf(tmp, sizeof(tmp), "%d", value);
    if (n <= 0) return "";

    char* buf = (char*)orbit_alloc(arena, (size_t)n + 1);
    if (!buf) return "";

    memcpy(buf, tmp, (size_t)n + 1);
    return buf;
}

orbit_string orbit_float_to_string(OrbitArena* arena, orbit_float value) {
    if (!arena) return "";

    // Big enough for the fixed rendering below as well as for %g, so the copy
    // that moves one into the other cannot truncate. gcc cannot prove that a
    // value which round-trips as a decimal below 1e17 needs fewer than 26
    // characters, and it is right not to have to.
    char tmp[512];
    int n = snprintf(tmp, sizeof(tmp), "%.15g", value);
    if (n <= 0) return "";

    // Shortest round-trip formatting: find the smallest precision whose output
    // parses back to the exact same double. A fixed %.15g would drop a digit
    // (1.758241758241763 needs 16 significant figures).
    for (int prec = 1; prec <= 16; prec++) {
        n = snprintf(tmp, sizeof(tmp), "%.*g", prec, value);
        if (n <= 0) return "";
        char* end = NULL;
        double rt = strtod(tmp, &end);
        if (end != NULL && *end == '\0' && rt == value) {
            break;
        }
    }

    // Prefer the fixed form for magnitudes a person would write that way.
    // The loop above minimises *precision*, not length, and %g switches to
    // exponential when the exponent reaches the precision: 2500.0 round-trips
    // at precision 2, so it printed as "2.5e+03" -- the same number, in a
    // shape nobody writes. So for a value inside the range where fixed
    // notation is readable, look for a fixed rendering that round-trips and
    // use it instead, trimming the trailing zeros the decimals add.
    // The range where fixed notation is the shorter, more readable answer.
    // Below 1e-6 and above 1e17 the digits stop being scannable and the
    // exponent form is genuinely better, which is roughly where other languages
    // switch too. 1e6 as "1e+06" is nobody's idea of how to write a million.
    double magnitude = value < 0 ? -value : value;
    int wantFixed = (value == value) &&
                    (value == 0.0 || (magnitude >= 1e-6 && magnitude < 1e17));
    if (wantFixed) {
        char fixed[512];
        for (int dec = 0; dec <= 17; dec++) {
            if (snprintf(fixed, sizeof(fixed), "%.*f", dec, value) <= 0) break;
            char* end = NULL;
            if (strtod(fixed, &end) == value && end != NULL && *end == '\0') {
                // A float prints as a float.
                //
                // The loop starts at zero decimals, and %.0f of 2.0 is "2",
                // which round-trips -- so every integral float found its
                // answer at the first step and printed as an integer.
                // `print(2.0)` and `print(2)` produced the same bytes, and a
                // float carried no information that it was a float.
                //
                // The differential fuzzer caught it, five cases at once and all
                // one bug, by comparing against a reference that keeps the
                // point. The earlier trailing-zero trim was not the cause and
                // never ran; this is.
                //
                // So: if the fixed form has no point, add ".0". It costs one
                // digit and buys back the type. 2500.0 is "2500.0" rather than
                // "2500", which is also what the reference prints, and still
                // nowhere near "1e+06".
                if (strchr(fixed, '.') == NULL) {
                    orbit_str_append(fixed, sizeof(fixed), ".0");
                }
                snprintf(tmp, sizeof(tmp), "%s", fixed);
                break;
            }
        }
    }

    // Length the string that is actually in tmp, not the one the last snprintf
    // that filled it happened to write. The %g loop left `n` describing its own
    // output, so a million came out as 100000: seven characters sitting in tmp,
    // `n` saying five, and the final memcpy faithfully copying five. Nothing had
    // rewritten tmp after that loop before now, which is why it survived.
    n = (int)strlen(tmp);
    if (n <= 0) return "";

    char* buf = (char*)orbit_alloc(arena, (size_t)n + 1);
    if (!buf) return "";

    memcpy(buf, tmp, (size_t)n + 1);
    return buf;
}

orbit_string orbit_bool_to_string(OrbitArena* arena, orbit_bool value) {
    (void)arena;
    return value ? "true" : "false";
}

static orbit_string orbit_string_from_char(OrbitArena* arena, orbit_int code) {
    OrbitArena* ar = (arena && arena->base) ? arena : orbit_arena_get_global();
    char* buf;
    if (code < 1 || code > 255) return "";
    buf = (char*)orbit_alloc(ar, 2);
    if (!buf) return "";
    buf[0] = (char)code;
    buf[1] = '\0';
    return buf;
}

static ORBIT_UNUSED orbit_string orbit_string_concat(OrbitArena* arena, orbit_string a, orbit_string b) {
    OrbitArena* ar = (arena && arena->base) ? arena : orbit_arena_get_global();
    if (!a) a = "";
    if (!b) b = "";

    orbit_int a_len = (orbit_int)strlen(a);
    orbit_int b_len = (orbit_int)strlen(b);
    orbit_int total_len = a_len + b_len;

    char* buf = (char*)orbit_alloc(ar, (size_t)total_len + 1);
    if (!buf) return "";

    if (a_len > 0) memcpy(buf, a, (size_t)a_len);
    if (b_len > 0) memcpy(buf + a_len, b, (size_t)b_len);
    buf[total_len] = '\0';

    return buf;
}

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

static OrbitCBuf* orbit_cbuf_create(OrbitArena* arena, size_t cap) {
    OrbitArena* ar = (arena && arena->base) ? arena : orbit_arena_get_global();
    if (cap == 0) cap = ORBIT_CBUF_INIT_CAP;
    OrbitCBuf* buf = (OrbitCBuf*)orbit_alloc(ar, sizeof(OrbitCBuf));
    if (!buf) return NULL;
    buf->data = (char*)orbit_alloc(ar, cap);
    if (!buf->data) return NULL;
    buf->len = 0;
    buf->cap = cap;
    buf->arena = ar;
    return buf;
}

static bool orbit_cbuf_append(OrbitCBuf* buf, orbit_string s) {
    size_t slen;
    size_t need;
    size_t ncap;
    char* ndata;
    if (!buf || !buf->data) return false;
    if (!s) return true;
    slen = strlen(s);
    if (slen == 0) return true;
    need = buf->len + slen;
    if (need >= buf->cap) {
        ncap = buf->cap ? buf->cap : 1024;
        while (ncap <= need) ncap *= 2;
        ndata = (char*)orbit_alloc(buf->arena, ncap);
        if (!ndata) return false;
        memcpy(ndata, buf->data, buf->len);
        buf->data = ndata;
        buf->cap = ncap;
    }
    memcpy(buf->data + buf->len, s, slen);
    buf->len = need;
    return true;
}

static orbit_string orbit_cbuf_build(OrbitCBuf* buf) {
    char* ndata;
    if (!buf || !buf->data) return "";
    if (buf->len + 1 > buf->cap) {
        ndata = (char*)orbit_alloc(buf->arena, buf->len + 1);
        if (!ndata) return "";
        memcpy(ndata, buf->data, buf->len);
        buf->data = ndata;
        buf->cap = buf->len + 1;
    }
    buf->data[buf->len] = '\0';
    return buf->data;
}

static ORBIT_UNUSED OrbitList* orbit_string_split(OrbitArena* arena, orbit_string s, orbit_string delim) {
    OrbitList* list = (OrbitList*)orbit_list_create(arena, sizeof(orbit_string), 4).value;
    if (!s || !delim || !arena) return list;

    size_t delim_len = strlen(delim);
    if (delim_len == 0) {
        orbit_list_push(list, &s);
        return list;
    }

    const char* p = s;
    const char* d = strstr(p, delim);
    while (d) {
        size_t len = d - p;
        char* buf = (char*)orbit_alloc(arena, len + 1);
        if (buf) {
            memcpy(buf, p, len);
            buf[len] = '\0';
            orbit_string s_part = buf;
            orbit_list_push(list, &s_part);
        }
        p = d + delim_len;
        d = strstr(p, delim);
    }
    
    size_t rem_len = strlen(p);
    char* rem_buf = (char*)orbit_alloc(arena, rem_len + 1);
    if (rem_buf) {
        memcpy(rem_buf, p, rem_len);
        rem_buf[rem_len] = '\0';
        orbit_string rem_part = rem_buf;
        orbit_list_push(list, &rem_part);
    }
    
    return list;
}

static ORBIT_UNUSED orbit_string orbit_string_replace(OrbitArena* arena, orbit_string s, orbit_string old_str, orbit_string new_str) {
    if (!s || !old_str || !new_str || !arena) return s;

    size_t old_len = strlen(old_str);
    if (old_len == 0) return s;

    size_t new_len = strlen(new_str);
    size_t s_len = strlen(s);

    // Count occurrences
    int count = 0;
    const char* p = s;
    while ((p = strstr(p, old_str)) != NULL) {
        count++;
        p += old_len;
    }

    if (count == 0) return s;

    size_t total_len = s_len + count * (new_len - old_len);
    char* buf = (char*)orbit_alloc(arena, total_len + 1);
    if (!buf) return "";

    const char* r = s;
    char* w = buf;
    while ((p = strstr(r, old_str)) != NULL) {
        size_t chunk_len = p - r;
        memcpy(w, r, chunk_len);
        w += chunk_len;
        memcpy(w, new_str, new_len);
        w += new_len;
        r = p + old_len;
    }
    size_t rem_len = strlen(r);
    memcpy(w, r, rem_len);
    w += rem_len;
    *w = '\0';

    return buf;
}

// ─── Extended String Utilities ─────────────────────────────────────────

bool orbit_string_starts_with(orbit_string s, orbit_string prefix) {
    if (!s || !prefix) return false;
    size_t sl = strlen(s);
    size_t pl = strlen(prefix);
    if (pl > sl) return false;
    return memcmp(s, prefix, pl) == 0;
}

bool orbit_string_ends_with(orbit_string s, orbit_string suffix) {
    if (!s || !suffix) return false;
    size_t sl = strlen(s);
    size_t sul = strlen(suffix);
    if (sul > sl) return false;
    return memcmp(s + sl - sul, suffix, sul) == 0;
}

bool orbit_string_contains(orbit_string s, orbit_string substr) {
    if (!s || !substr) return false;
    return strstr(s, substr) != NULL;
}

orbit_int orbit_string_indexOf(orbit_string s, orbit_string substr) {
    if (!s || !substr) return -1;
    const char* p = strstr(s, substr);
    return p ? (orbit_int)(p - s) : -1;
}

orbit_string orbit_string_to_upper(OrbitArena* arena, orbit_string s) {
    if (!s || !arena) return "";
    size_t len = strlen(s);
    char* buf = (char*)orbit_alloc(arena, len + 1);
    if (!buf) return "";
    for (size_t i = 0; i < len; i++) {
        char c = s[i];
        buf[i] = (c >= 'a' && c <= 'z') ? (c - 32) : c;
    }
    buf[len] = '\0';
    return buf;
}

orbit_string orbit_string_to_lower(OrbitArena* arena, orbit_string s) {
    if (!s || !arena) return "";
    size_t len = strlen(s);
    char* buf = (char*)orbit_alloc(arena, len + 1);
    if (!buf) return "";
    for (size_t i = 0; i < len; i++) {
        char c = s[i];
        buf[i] = (c >= 'A' && c <= 'Z') ? (c + 32) : c;
    }
    buf[len] = '\0';
    return buf;
}

orbit_string orbit_string_trim(OrbitArena* arena, orbit_string s) {
    if (!s || !arena) return "";
    const char* start = s;
    const char* end = s + strlen(s) - 1;
    while (*start == ' ' || *start == '\t' || *start == '\n' || *start == '\r') start++;
    if (start > end) return "";
    while (end > start && (*end == ' ' || *end == '\t' || *end == '\n' || *end == '\r')) end--;
    size_t len = (size_t)(end - start + 1);
    char* buf = (char*)orbit_alloc(arena, len + 1);
    if (!buf) return "";
    memcpy(buf, start, len);
    buf[len] = '\0';
    return buf;
}

#endif
