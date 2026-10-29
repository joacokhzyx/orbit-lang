#ifndef ORBIT_RT_COLLECTIONS_C
#define ORBIT_RT_COLLECTIONS_C

#include "module_prelude.h"
#include "collections.h"
#include "types.h"
#include "arena.h"
#include "arena.h"
#include "types.h"
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

void orbit_div_error(const char* file, int64_t line, int64_t kind) {
    const char* what = kind == 0 ? "division by zero" : "integer overflow in division";
    if (file && file[0] && line > 0) {
        fprintf(stderr, "orbit: %s at %s:%lld\n", what, file, (long long)line);
    } else if (file && file[0]) {
        fprintf(stderr, "orbit: %s at %s\n", what, file);
    } else {
        fprintf(stderr, "orbit: %s\n", what);
    }
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

/* The list functions (create, grow, push, pop, set and their typed forms, clear)
 * are runtime/orb/lists.orb, compiled to runtime/gen/lists.c. orbit_list_get and
 * orbit_list_len stay here: emitted code reads them in place. */

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


ORBIT_UNUSED OrbitResult orbit_map_delete(OrbitMap* map, const char* key) {
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
ORBIT_UNUSED OrbitResult orbit_map_keys(const OrbitMap* map, OrbitArena* arena) {
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

ORBIT_UNUSED orbit_int orbit_string_at(orbit_string s, orbit_int index) {
    if (!s) return 0;
    orbit_int len = (orbit_int)strlen(s);
    if (index < 0 || index >= len) return 0;
    return (unsigned char)s[index];
}

ORBIT_UNUSED orbit_string orbit_string_slice(OrbitArena* arena, orbit_string s, orbit_int start, orbit_int end) {
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

ORBIT_UNUSED orbit_string orbit_string_slice_known_len(orbit_string s, orbit_int start, orbit_int end, orbit_int totalLen) {
    // Same contract as orbit_string_slice, but the caller already knows the
    // length, so there is no strlen: the lexer slices every token out of a
    // source whose length it holds, and paying strlen(source) per token made
    // lexing quadratic in file size. Allocates from the global arena, like
    // the other selfhost helpers, so callers pass exactly the slice bounds
    // and no arena. Bounds are still clamped defensively; every current
    // caller passes 0 <= start <= end <= totalLen.
    if (!s) return "";
    OrbitArena* ar = orbit_arena_get_global();
    if (start < 0) start = 0;
    if (end > totalLen) end = totalLen;
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
    int n = snprintf(tmp, sizeof(tmp), "%lld", (long long)value);
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

ORBIT_XLINK orbit_string orbit_string_from_char(OrbitArena* arena, orbit_int code) {
    OrbitArena* ar = (arena && arena->base) ? arena : orbit_arena_get_global();
    char* buf;
    if (code < 1 || code > 255) return "";
    buf = (char*)orbit_alloc(ar, 2);
    if (!buf) return "";
    buf[0] = (char)code;
    buf[1] = '\0';
    return buf;
}

ORBIT_UNUSED orbit_string orbit_string_concat(OrbitArena* arena, orbit_string a, orbit_string b) {
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
#ifndef ORBIT_CBUF_INIT_CAP
#endif

ORBIT_XLINK OrbitCBuf* orbit_cbuf_create(OrbitArena* arena, size_t cap) {
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

ORBIT_XLINK bool orbit_cbuf_append(OrbitCBuf* buf, orbit_string s) {
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

ORBIT_XLINK orbit_string orbit_cbuf_build(OrbitCBuf* buf) {
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

ORBIT_UNUSED OrbitList* orbit_string_split(OrbitArena* arena, orbit_string s, orbit_string delim) {
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

ORBIT_UNUSED orbit_string orbit_string_replace(OrbitArena* arena, orbit_string s, orbit_string old_str, orbit_string new_str) {
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

// starts_with, ends_with, contains, indexOf, to_upper, to_lower and trim are
// Orbit: runtime/orb/strings.orb, generated into runtime/gen/strings.c.

#endif
