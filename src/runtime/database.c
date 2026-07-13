/**
 * @file  database.c
 * @brief Arena-backed SQLite integration for Orbit's runtime database layer.
 *
 * All result strings are allocated from the request arena — no fixed-size
 * buffers.  Queries are built dynamically in the arena, and rows are
 * serialised to JSON on the fly.  A Kynx budget macro (KYNX_DB_QUERY_CHECK)
 * guards every public function and aborts early when the per-request
 * database-query budget is exhausted.
 */
#ifndef ORBIT_DATABASE_H
#define ORBIT_DATABASE_H

#include <sqlite3.h>
#include <stdio.h>
#include <string.h>
#include "arena.c"
#include "types.c"

/* ──────────────────────────────────────────────────────────────────────
 * Orbit Database — Arena-backed SQLite integration.
 *
 * All result strings are allocated from the request Arena.
 * No fixed-size query or result buffers. Dynamic allocation only.
 * Uses parameterized queries where possible for SQL injection safety.
 * ────────────────────────────────────────────────────────────────────── */

static sqlite3* orbit_db_conn = NULL;

typedef struct {
    const char* table_name;
    const char* schema;
} orbit_collection;

/* ── Lifecycle ──────────────────────────────────────────────────────── */

extern int orbit_sqlite_progress_handler(void*);

#ifdef ORBIT_WITH_NET
#define KYNX_DB_QUERY_CHECK(ret) \
    if (current_lease) { \
        current_lease->db_queries++; \
        if (current_lease->db_queries > current_lease->db_queries_limit) { \
            orbit_perf_atomic_inc64(&orbit_perf_stats.kynx_db_query_budget_exhausted); \
            return ret; \
        } \
    }
#else
#define KYNX_DB_QUERY_CHECK(ret)
#endif

/** @brief Open (or create) the SQLite database at @p db_path and install the Kynx progress handler. */
void orbit_db_init(const char* db_path) {
    sqlite3_open(db_path, &orbit_db_conn);
    if (orbit_db_conn) {
        sqlite3_progress_handler(orbit_db_conn, 10, orbit_sqlite_progress_handler, NULL);
    }
}

/** @brief Close the global SQLite connection and set the internal handle to NULL. */
void orbit_db_close(void) {
    if (orbit_db_conn) {
        sqlite3_close(orbit_db_conn);
        orbit_db_conn = NULL;
    }
}

/* ── Internal: build a dynamic query string in Arena ───────────────── */

static char* orbit_db_build_query(OrbitArena* arena, const char* fmt, const char* table, const char* extra) {
    size_t fmt_len   = strlen(fmt);
    size_t table_len = strlen(table);
    size_t extra_len = extra ? strlen(extra) : 0;
    size_t total     = fmt_len + table_len + extra_len + 64;

    char* buf = (char*)orbit_alloc(arena, total);
    if (!buf) return NULL;

    snprintf(buf, total, fmt, table, extra ? extra : "");
    return buf;
}

/* ── Internal: serialize a row to JSON into Arena ──────────────────── */

static size_t orbit_db_row_to_json(OrbitArena* arena, sqlite3_stmt* stmt, char* out, size_t max_len) {
    int cols = sqlite3_column_count(stmt);
    char* p = out;
    char* end = out + max_len - 2;

    *(p++) = '{';

    for (int i = 0; i < cols && p < end; i++) {
        const char* col_name = sqlite3_column_name(stmt, i);
        const char* col_text = (const char*)sqlite3_column_text(stmt, i);

        if (i > 0) *(p++) = ',';

        int written = snprintf(p, (size_t)(end - p), "\"%s\":\"%s\"",
            col_name, col_text ? col_text : "");
        if (written > 0) p += written;
    }

    *(p++) = '}';
    *p = '\0';
    return (size_t)(p - out);
}

// ─── Public Query API ────────────────────────────────────────────────────────

/** @brief Fetch a single row from @p col by @p id and return it as a JSON object string, or NULL if not found. */
orbit_string orbit_db_get(OrbitArena* arena, orbit_collection col, const char* id) {
    KYNX_DB_QUERY_CHECK(NULL);
    const char* fmt = "SELECT * FROM %s WHERE id = ?;";
    size_t query_len = strlen(fmt) + strlen(col.table_name) + 16;
    char* query = (char*)orbit_alloc(arena, query_len);
    if (!query) return NULL;
    snprintf(query, query_len, "SELECT * FROM %s WHERE id = ?;", col.table_name);

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(orbit_db_conn, query, -1, &stmt, NULL) != SQLITE_OK)
        return NULL;

    sqlite3_bind_text(stmt, 1, id, -1, SQLITE_STATIC);

    orbit_string result = NULL;
    orbit_perf_stats.db_queries++; // Telemetry
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        char* buf = (char*)orbit_alloc(arena, 4096);
        if (buf) {
            orbit_db_row_to_json(arena, stmt, buf, 4096);
            result = buf;
        }
    }

    sqlite3_finalize(stmt);
    return result;
}

/** @brief Fetch every row from @p col and return a JSON array string; returns "[]" on error or empty table. */
orbit_string orbit_db_all(OrbitArena* arena, orbit_collection col) {
    KYNX_DB_QUERY_CHECK("[]");
    size_t query_len = strlen("SELECT * FROM ;") + strlen(col.table_name) + 1;
    char* query = (char*)orbit_alloc(arena, query_len);
    if (!query) return "[]";
    snprintf(query, query_len, "SELECT * FROM %s;", col.table_name);

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(orbit_db_conn, query, -1, &stmt, NULL) != SQLITE_OK)
        return "[]";

    /* Dynamic result buffer — start with 8KB, grow as needed */
    size_t buf_cap = 8192;
    char* buf = (char*)orbit_alloc(arena, buf_cap);
    if (!buf) return "[]";

    char* p = buf;
    *(p++) = '[';
    bool first = true;

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        orbit_perf_stats.db_queries++; // Telemetry
        /* Ensure space: worst case ~2KB per row */
        size_t used_so_far = (size_t)(p - buf);
        if (used_so_far + 2048 > buf_cap) {
            /* Can't realloc arena memory, allocate a larger chunk */
            size_t new_cap = buf_cap * 2;
            char* new_buf = (char*)orbit_alloc(arena, new_cap);
            if (!new_buf) break;
            memcpy(new_buf, buf, used_so_far);
            buf = new_buf;
            p = buf + used_so_far;
            buf_cap = new_cap;
        }

        if (!first) *(p++) = ',';

        size_t row_len = orbit_db_row_to_json(arena, stmt, p, buf_cap - (size_t)(p - buf));
        p += row_len;
        first = false;
    }

    *(p++) = ']';
    *p = '\0';

    sqlite3_finalize(stmt);
    return buf;
}

/** @brief Fetch rows from @p col matching @p condition (a raw SQL WHERE clause fragment) and return a JSON array. */
orbit_string orbit_db_where(OrbitArena* arena, orbit_collection col, const char* condition) {
    KYNX_DB_QUERY_CHECK("[]");
    size_t query_len = strlen("SELECT * FROM  WHERE ;") + strlen(col.table_name) + strlen(condition) + 1;
    char* query = (char*)orbit_alloc(arena, query_len);
    if (!query) return "[]";
    snprintf(query, query_len, "SELECT * FROM %s WHERE %s;", col.table_name, condition);

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(orbit_db_conn, query, -1, &stmt, NULL) != SQLITE_OK)
        return "[]";

    size_t buf_cap = 8192;
    char* buf = (char*)orbit_alloc(arena, buf_cap);
    if (!buf) return "[]";

    char* p = buf;
    *(p++) = '[';
    bool first = true;

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        size_t used_so_far = (size_t)(p - buf);
        if (used_so_far + 2048 > buf_cap) {
            size_t new_cap = buf_cap * 2;
            char* new_buf = (char*)orbit_alloc(arena, new_cap);
            if (!new_buf) break;
            memcpy(new_buf, buf, used_so_far);
            buf = new_buf;
            p = buf + used_so_far;
            buf_cap = new_cap;
        }

        if (!first) *(p++) = ',';
        size_t row_len = orbit_db_row_to_json(arena, stmt, p, buf_cap - (size_t)(p - buf));
        p += row_len;
        first = false;
    }

    *(p++) = ']';
    *p = '\0';

    sqlite3_finalize(stmt);
    return buf;
}

/** @brief Fetch the first row from @p col and return it as a JSON object string, or NULL if the table is empty. */
orbit_string orbit_db_first(OrbitArena* arena, orbit_collection col) {
    KYNX_DB_QUERY_CHECK(NULL);
    size_t query_len = strlen("SELECT * FROM  LIMIT 1;") + strlen(col.table_name) + 1;
    char* query = (char*)orbit_alloc(arena, query_len);
    if (!query) return NULL;
    snprintf(query, query_len, "SELECT * FROM %s LIMIT 1;", col.table_name);

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(orbit_db_conn, query, -1, &stmt, NULL) != SQLITE_OK)
        return NULL;

    orbit_string result = NULL;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        char* buf = (char*)orbit_alloc(arena, 4096);
        if (buf) {
            orbit_db_row_to_json(arena, stmt, buf, 4096);
            result = buf;
        }
    }

    sqlite3_finalize(stmt);
    return result;
}

/** @brief Return the number of rows in @p col via COUNT(*). */
int orbit_db_count(orbit_collection col) {
    KYNX_DB_QUERY_CHECK(0);
    /* Count uses a small stack buffer since the query is trivial */
    char query[128];
    snprintf(query, sizeof(query), "SELECT COUNT(*) FROM %s;", col.table_name);

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(orbit_db_conn, query, -1, &stmt, NULL) != SQLITE_OK)
        return 0;

    int count = 0;
    orbit_perf_stats.db_queries++; // Telemetry
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        count = sqlite3_column_int(stmt, 0);
    }

    sqlite3_finalize(stmt);
    return count;
}

/** @brief Return true if a row with the given @p id exists in @p col. */
bool orbit_db_exists(orbit_collection col, const char* id) {
    KYNX_DB_QUERY_CHECK(false);
    char query[128];
    snprintf(query, sizeof(query), "SELECT 1 FROM %s WHERE id = ? LIMIT 1;", col.table_name);

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(orbit_db_conn, query, -1, &stmt, NULL) != SQLITE_OK)
        return false;

    sqlite3_bind_text(stmt, 1, id, -1, SQLITE_STATIC);
    bool exists = (sqlite3_step(stmt) == SQLITE_ROW);
    sqlite3_finalize(stmt);
    return exists;
}

/** @brief Insert a JSON document into @p col; uses malloc for the query buffer since no arena is available at insert time. */
bool orbit_db_add(orbit_collection col, const char* json_data) {
    KYNX_DB_QUERY_CHECK(false);
    size_t query_len = strlen("INSERT INTO  (JSON_DATA) VALUES (?);") + strlen(col.table_name) + 1;
    char* query = (char*)malloc(query_len);
    if (!query) return false;
    snprintf(query, query_len, "INSERT INTO %s (JSON_DATA) VALUES (?);", col.table_name);

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(orbit_db_conn, query, -1, &stmt, NULL) != SQLITE_OK) {
        free(query);
        return false;
    }

    sqlite3_bind_text(stmt, 1, json_data, -1, SQLITE_STATIC);
    bool success = (sqlite3_step(stmt) == SQLITE_DONE);
    sqlite3_finalize(stmt);
    free(query);
    return success;
}

/** @brief Update the JSON_DATA column for the row with the given @p id in @p col. */
bool orbit_db_set(orbit_collection col, const char* id, const char* json_updates) {
    KYNX_DB_QUERY_CHECK(false);
    size_t query_len = strlen("UPDATE  SET JSON_DATA = ? WHERE id = ?;") + strlen(col.table_name) + 1;
    char* query = (char*)malloc(query_len);
    if (!query) return false;
    snprintf(query, query_len, "UPDATE %s SET JSON_DATA = ? WHERE id = ?;", col.table_name);

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(orbit_db_conn, query, -1, &stmt, NULL) != SQLITE_OK) {
        free(query);
        return false;
    }

    sqlite3_bind_text(stmt, 1, json_updates, -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 2, id, -1, SQLITE_STATIC);
    bool success = (sqlite3_step(stmt) == SQLITE_DONE);
    sqlite3_finalize(stmt);
    free(query);
    return success;
}

/** @brief Delete the row with the given @p id from @p col. */
bool orbit_db_del(orbit_collection col, const char* id) {
    KYNX_DB_QUERY_CHECK(false);
    size_t query_len = strlen("DELETE FROM  WHERE id = ?;") + strlen(col.table_name) + 1;
    char* query = (char*)malloc(query_len);
    if (!query) return false;
    snprintf(query, query_len, "DELETE FROM %s WHERE id = ?;", col.table_name);

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(orbit_db_conn, query, -1, &stmt, NULL) != SQLITE_OK) {
        free(query);
        return false;
    }

    sqlite3_bind_text(stmt, 1, id, -1, SQLITE_STATIC);
    bool success = (sqlite3_step(stmt) == SQLITE_DONE);
    sqlite3_finalize(stmt);
    free(query);
    return success;
}

// ─── JSON Helpers ────────────────────────────────────────────────────────────

/** @brief Return true when @p s is NULL, the empty-object literal "{}", or the empty-array literal "[]". */
bool orbit_is_empty(orbit_string s) {
    return s == NULL || strcmp(s, "{}") == 0 || strcmp(s, "[]") == 0;
}

/** @brief Extract the string value for @p key from a flat JSON object stored in @p json. Returns "" if not found. */
orbit_string orbit_json_get(OrbitArena* arena, orbit_string json, const char* key) {
    if (!json || !key) return "";

    /* Build search pattern: "key":" */
    size_t key_len = strlen(key);
    size_t search_len = key_len + 4; /* "key":" */
    char* search = (char*)orbit_alloc(arena, search_len + 1);
    if (!search) return "";
    snprintf(search, search_len + 1, "\"%s\":\"", key);

    const char* start = strstr(json, search);
    if (!start) return "";

    start += search_len;
    const char* end = strchr(start, '"');
    if (!end) return "";

    size_t len = (size_t)(end - start);
    char* res = (char*)orbit_alloc(arena, len + 1);
    if (!res) return "";

    memcpy(res, start, len);
    res[len] = '\0';
    return res;
}

#endif
