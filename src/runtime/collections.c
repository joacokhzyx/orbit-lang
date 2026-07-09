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

static OrbitResult orbit_list_create(OrbitArena* arena, size_t elem_size, size_t initial_capacity) {
    if (!arena || elem_size == 0) {
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
    list->arena     = arena;

    return orbit_result_ok(list);
}

/* Grow the backing array, copying existing data forward in the arena.
 * Old memory is abandoned (reclaimed on arena reset). */
static OrbitResult orbit_list_grow(OrbitList* list) {
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

static OrbitResult orbit_list_push(OrbitList* list, const void* elem) {
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

ORBIT_INLINE size_t orbit_list_len(const OrbitList* list) {
    return list ? list->len : 0;
}

static OrbitResult orbit_list_pop(OrbitList* list) {
    if (!list || list->len == 0) {
        return orbit_result_err(ORBIT_ERR_OUT_OF_BOUNDS, "list_pop: empty list");
    }
    list->len--;
    return orbit_result_ok((char*)list->data + list->len * list->elem_size);
}

static OrbitResult orbit_list_set(OrbitList* list, size_t index, const void* elem) {
    if (!list || !elem) {
        return orbit_result_err(ORBIT_ERR_NULL_PTR, "list_set: null argument");
    }
    if (index >= list->len) {
        return orbit_result_err(ORBIT_ERR_OUT_OF_BOUNDS, "list_set: index out of bounds");
    }
    memcpy((char*)list->data + index * list->elem_size, elem, list->elem_size);
    return orbit_result_ok(list);
}

/* Return a zero-copy slice view of the list */
static OrbitSlice orbit_list_as_slice(const OrbitList* list) {
    OrbitSlice s;
    if (!list) {
        s.data      = NULL;
        s.len       = 0;
        s.elem_size = 0;
    } else {
        s.data      = list->data;
        s.len       = list->len;
        s.elem_size = list->elem_size;
    }
    return s;
}

/* Clear without deallocation — O(1) reset */
static void orbit_list_clear(OrbitList* list) {
    if (list) list->len = 0;
}

/* ═══════════════════════════════════════════════════════════════════════
 * MAP<K,V> IMPLEMENTATION — Open-addressing Robin Hood
 * ═══════════════════════════════════════════════════════════════════════ */

/* FNV-1a hash for string keys — fast, cache-friendly, good distribution */
static uint32_t orbit_map_hash(const char* key) {
    uint32_t hash = 2166136261u;
    while (*key) {
        hash ^= (uint8_t)*key++;
        hash *= 16777619u;
    }
    return hash;
}

static OrbitResult orbit_map_create(OrbitArena* arena, size_t value_size) {
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

static OrbitResult orbit_map_resize(OrbitMap* map) {
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

static OrbitResult orbit_map_set(OrbitMap* map, const char* key, const void* value) {
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

ORBIT_INLINE size_t orbit_map_count(const OrbitMap* map) {
    return map ? map->count : 0;
}

static OrbitResult orbit_map_delete(OrbitMap* map, const char* key) {
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
static OrbitResult orbit_map_keys(const OrbitMap* map, OrbitArena* arena) {
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

/* ═══════════════════════════════════════════════════════════════════════
 * STRING UTILITIES
 * ═══════════════════════════════════════════════════════════════════════ */

ORBIT_INLINE orbit_int orbit_string_len(orbit_string s) {
    return s ? (orbit_int)strlen(s) : 0;
}

static orbit_int orbit_string_at(orbit_string s, orbit_int index) {
    if (!s) return 0;
    orbit_int len = (orbit_int)strlen(s);
    if (index < 0 || index >= len) return 0;
    return (unsigned char)s[index];
}

static orbit_string orbit_string_slice(OrbitArena* arena, orbit_string s, orbit_int start, orbit_int end) {
    if (!s || !arena) return "";
    orbit_int len = (orbit_int)strlen(s);
    if (start < 0) start = 0;
    if (end > len) end = len;
    if (start >= end) return "";

    orbit_int slice_len = end - start;
    char* buf = (char*)orbit_alloc(arena, slice_len + 1);
    if (!buf) return "";
    memcpy(buf, s + start, slice_len);
    buf[slice_len] = '\0';
    return buf;
}

static orbit_string orbit_int_to_string(OrbitArena* arena, orbit_int value) {
    if (!arena) return "";

    char tmp[32];
    int n = snprintf(tmp, sizeof(tmp), "%d", value);
    if (n <= 0) return "";

    char* buf = (char*)orbit_alloc(arena, (size_t)n + 1);
    if (!buf) return "";

    memcpy(buf, tmp, (size_t)n + 1);
    return buf;
}

static orbit_string orbit_float_to_string(OrbitArena* arena, orbit_float value) {
    if (!arena) return "";

    char tmp[64];
    int n = snprintf(tmp, sizeof(tmp), "%.15g", value);
    if (n <= 0) return "";

    char* buf = (char*)orbit_alloc(arena, (size_t)n + 1);
    if (!buf) return "";

    memcpy(buf, tmp, (size_t)n + 1);
    return buf;
}

static orbit_string orbit_bool_to_string(OrbitArena* arena, orbit_bool value) {
    (void)arena;
    return value ? "true" : "false";
}

static orbit_string orbit_string_concat(OrbitArena* arena, orbit_string a, orbit_string b) {
    if (!arena) return "";

    if (!a) a = "";
    if (!b) b = "";

    orbit_int a_len = (orbit_int)strlen(a);
    orbit_int b_len = (orbit_int)strlen(b);
    orbit_int total_len = a_len + b_len;

    char* buf = (char*)orbit_alloc(arena, (size_t)total_len + 1);
    if (!buf) return "";

    if (a_len > 0) memcpy(buf, a, (size_t)a_len);
    if (b_len > 0) memcpy(buf + a_len, b, (size_t)b_len);
    buf[total_len] = '\0';

    return buf;
}

static OrbitList* orbit_string_split(OrbitArena* arena, orbit_string s, orbit_string delim) {
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

static orbit_string orbit_string_replace(OrbitArena* arena, orbit_string s, orbit_string old_str, orbit_string new_str) {
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


#endif
