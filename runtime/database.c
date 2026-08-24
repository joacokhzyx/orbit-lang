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

/* The Kynx lease guard lives in kynx.c, which is only compiled with
 * ORBIT_WITH_NET. Without it, provide a no-op progress handler so DB-only
 * programs link without pulling in the network stack. */
#ifdef ORBIT_WITH_NET
extern int orbit_sqlite_progress_handler(void*);
#else
static int orbit_sqlite_progress_handler(void* param) { (void)param; return 0; }
#endif

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

/* Internal: table/identifier names are interpolated into SQL. Anything
 * outside [A-Za-z0-9_] cannot be a legit Orbit model table and would be
 * an injection attempt — reject before formatting. */
static bool orbit_db_valid_identifier(const char* name) {
    if (!name || !*name) return false;
    for (const char* c = name; *c; c++) {
        char ch = *c;
        if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
              (ch >= '0' && ch <= '9') || ch == '_')) {
            return false;
        }
    }
    return true;
}

void orbit_db_init(const char* db_path) {
    sqlite3_open(db_path, &orbit_db_conn);
    if (orbit_db_conn) {
        sqlite3_progress_handler(orbit_db_conn, 10, orbit_sqlite_progress_handler, NULL);
        const char* init_sql =
            "CREATE TABLE IF NOT EXISTS notes ("
            "  id TEXT PRIMARY KEY, title TEXT, body TEXT, author_id TEXT, created_at TEXT, is_private INTEGER"
            ");"
            "CREATE TABLE IF NOT EXISTS products ("
            "  id TEXT PRIMARY KEY, name TEXT, description TEXT, price REAL, category TEXT, in_stock INTEGER, rating REAL"
            ");"
            "CREATE TABLE IF NOT EXISTS users ("
            "  id TEXT PRIMARY KEY, username TEXT, email TEXT, role_name TEXT"
            ");"
            "CREATE TABLE IF NOT EXISTS sessions ("
            "  token TEXT PRIMARY KEY, user_id TEXT, expires_at INTEGER"
            ");";
        sqlite3_exec(orbit_db_conn, init_sql, NULL, NULL, NULL);

        int count = 0;
        sqlite3_stmt* stmt = NULL;
        if (sqlite3_prepare_v2(orbit_db_conn, "SELECT COUNT(*) FROM products;", -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) count = sqlite3_column_int(stmt, 0);
            sqlite3_finalize(stmt);
        }
        if (count == 0) {
            const char* seed_sql =
                "INSERT INTO products VALUES ('prod_101', 'Orbit Compiler Pro', 'Ultra-high performance C runtime compiler for web microservices', 299.99, 'Developer Tools', 1, 4.9);"
                "INSERT INTO products VALUES ('prod_102', 'Kynx Security Shield', 'O(1) sharded rate limiter and DDoS mitigation engine', 149.50, 'Security', 1, 4.8);"
                "INSERT INTO products VALUES ('prod_103', 'Steel Memory Profiler', 'Zero-overhead memory arena tracker and profiler', 89.00, 'Developer Tools', 1, 4.7);"
                "INSERT INTO notes VALUES ('note_101', 'Orbit Architecture Notes', 'Steel C runtime manages thread-local arena memory without global lock contention.', 'usr_admin', '2026-07-22T01:00:00Z', 0);"
                "INSERT INTO notes VALUES ('note_102', 'Superluminal Optimizer Guide', 'IR passes execute fixed-point optimizations including CTEVAL and auto-memoization.', 'usr_dev', '2026-07-22T01:15:00Z', 0);"
                "INSERT INTO users VALUES ('usr_admin', 'admin', 'admin@orbit.dev', 'admin');"
                "INSERT INTO users VALUES ('usr_dev', 'developer', 'dev@orbit.dev', 'developer');"
                "INSERT INTO sessions VALUES ('bearer-secret-token-123', 'usr_admin', 0);";
            sqlite3_exec(orbit_db_conn, seed_sql, NULL, NULL, NULL);
        }
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

/* ── Internal: append a JSON-escaped string within [p, end). ──────────── */

static char* orbit_db_append_json_escaped(char* p, char* end, const char* s) {
    if (p >= end) return p;
    *(p++) = '"';
    for (const char* c = s ? s : ""; *c && p < end; c++) {
        unsigned char ch = (unsigned char)*c;
        if (ch == '"' || ch == '\\') {
            if (p + 2 > end) break;
            *(p++) = '\\';
            *(p++) = (char)ch;
        } else if (ch == '\n' && p + 2 <= end) {
            *(p++) = '\\';
            *(p++) = 'n';
        } else if (ch == '\r' && p + 2 <= end) {
            *(p++) = '\\';
            *(p++) = 'r';
        } else if (ch == '\t' && p + 2 <= end) {
            *(p++) = '\\';
            *(p++) = 't';
        } else if (ch < 0x20) {
            if (p + 6 > end) break;
            int w = snprintf(p, (size_t)(end - p), "\\u%04x", ch);
            if (w > 0) p += w;
        } else {
            *(p++) = (char)ch;
        }
    }
    if (p < end) *(p++) = '"';
    return p;
}

/* ── Internal: serialize a row to JSON into Arena ──────────────────── */

static size_t orbit_db_row_to_json(OrbitArena* arena, sqlite3_stmt* stmt, char* out, size_t max_len) {
    if (!out || max_len < 3) return 0;
    int cols = sqlite3_column_count(stmt);
    char* p = out;
    char* end = out + max_len - 2; /* reserve space for '}' and NUL */

    *(p++) = '{';

    for (int i = 0; i < cols && p < end; i++) {
        const char* col_name = sqlite3_column_name(stmt, i);
        const char* col_text = (const char*)sqlite3_column_text(stmt, i);

        if (i > 0 && p < end) *(p++) = ',';
        if (p >= end) break;

        p = orbit_db_append_json_escaped(p, end, col_name ? col_name : "");
        if (p + 1 >= end) break; /* need room for ':' and at least one more byte */
        *(p++) = ':';
        p = orbit_db_append_json_escaped(p, end, col_text);
    }

    if (p < end) *(p++) = '}';
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
/** @brief Extract a value for @p key from a flat JSON object: quoted string values
 *         ("key":"value") or bare values ("key":value, e.g. numbers). Returns NULL
 *         when the key is absent. Caller frees the returned copy.
 */
static char* orbit_json_get_value(const char* json, const char* key) {
    if (!json || !key) return NULL;

    /* Quoted string value: "key":"value" */
    size_t key_len = strlen(key);
    size_t q_search_len = key_len + 4; /* "key":" */
    char* q_search = (char*)malloc(q_search_len + 1);
    if (!q_search) return NULL;
    snprintf(q_search, q_search_len + 1, "\"%s\":\"", key);

    const char* start = strstr(json, q_search);
    if (start) {
        start += q_search_len;
        const char* end = strchr(start, '"');
        if (end) {
            size_t len = (size_t)(end - start);
            char* res = (char*)malloc(len + 1);
            if (res) {
                memcpy(res, start, len);
                res[len] = '\0';
            }
            free(q_search);
            return res;
        }
    }
    free(q_search);

    /* Bare value: "key":value */
    size_t b_search_len = key_len + 3; /* "key": */
    char* b_search = (char*)malloc(b_search_len + 1);
    if (!b_search) return NULL;
    snprintf(b_search, b_search_len + 1, "\"%s\":", key);

    start = strstr(json, b_search);
    if (!start) {
        free(b_search);
        return NULL;
    }
    start += b_search_len;
    const char* end = start;
    while (*end && *end != ',' && *end != '}' && *end != '\n') end++;
    size_t len = (size_t)(end - start);
    char* res = (char*)malloc(len + 1);
    if (res) {
        memcpy(res, start, len);
        res[len] = '\0';
    }
    free(b_search);
    return res;
}

bool orbit_db_add(orbit_collection col, const char* json_data) {
    KYNX_DB_QUERY_CHECK(false);
    if (!col.table_name || !json_data) return false;

    /* Resolve the table's real columns via PRAGMA so INSERT matches the typed
     * schema created by orbit_db_init instead of assuming a JSON_DATA column. */
    char pragma_sql[512];
    snprintf(pragma_sql, sizeof(pragma_sql), "PRAGMA table_info(%s);", col.table_name);

    sqlite3_stmt* col_stmt = NULL;
    if (sqlite3_prepare_v2(orbit_db_conn, pragma_sql, -1, &col_stmt, NULL) != SQLITE_OK) {
        return false;
    }

    enum { kMaxCols = 64 };
    const char* col_names[kMaxCols];
    int ncols = 0;
    while (sqlite3_step(col_stmt) == SQLITE_ROW && ncols < kMaxCols) {
        const char* name = (const char*)sqlite3_column_text(col_stmt, 1);
        if (name) {
            char* copy = (char*)malloc(strlen(name) + 1);
            if (copy) {
                strcpy(copy, name);
                col_names[ncols] = copy;
                ncols++;
            }
        }
    }
    sqlite3_finalize(col_stmt);
    if (ncols == 0) return false;

    /* "INSERT INTO <table> (c1,c2,...) VALUES (?,?,...);" */
    size_t qlen = strlen("INSERT INTO  ( ) VALUES ();") + strlen(col.table_name) + 1;
    for (int i = 0; i < ncols; i++) qlen += strlen(col_names[i]) + 2;
    char* query = (char*)malloc(qlen);
    if (!query) {
        for (int i = 0; i < ncols; i++) free((void*)col_names[i]);
        return false;
    }

    char* p = query;
    p += snprintf(p, (size_t)(query + qlen - p), "INSERT INTO %s (", col.table_name);
    for (int i = 0; i < ncols; i++) {
        if (i > 0) *(p++) = ',';
        p += snprintf(p, (size_t)(query + qlen - p), "%s", col_names[i]);
    }
    p += snprintf(p, (size_t)(query + qlen - p), ") VALUES (");
    for (int i = 0; i < ncols; i++) {
        if (i > 0) *(p++) = ',';
        *(p++) = '?';
    }
    p += snprintf(p, (size_t)(query + qlen - p), ");");

    sqlite3_stmt* stmt = NULL;
    int rc = sqlite3_prepare_v2(orbit_db_conn, query, -1, &stmt, NULL);
    bool success = false;
    if (rc == SQLITE_OK) {
        for (int i = 0; i < ncols; i++) {
            char* value = orbit_json_get_value(json_data, col_names[i]);
            sqlite3_bind_text(stmt, i + 1, value ? value : "", -1, SQLITE_TRANSIENT);
            free(value);
        }
        success = (sqlite3_step(stmt) == SQLITE_DONE);
        sqlite3_finalize(stmt);
    }

    free(query);
    for (int i = 0; i < ncols; i++) free((void*)col_names[i]);
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

orbit_string orbit_db_query_all(OrbitArena* arena, const char* table_name) {
    if (!orbit_db_valid_identifier(table_name)) return "[]";
    orbit_collection col = { table_name, NULL };
    return orbit_db_all(arena, col);
}

orbit_string orbit_db_query_where(OrbitArena* arena, const char* table_name, const char* condition) {
    if (!orbit_db_valid_identifier(table_name)) return "[]";
    orbit_collection col = { table_name, NULL };
    return orbit_db_where(arena, col, condition);
}

/** @brief Replace the first occurrence of @p needle in @p haystack with @p replacement (arena-allocated). */
static char* orbit_replace_first(OrbitArena* arena, const char* haystack, const char* needle, const char* replacement) {
    const char* pos = strstr(haystack, needle);
    if (!pos) {
        size_t len = strlen(haystack) + 1;
        char* out = (char*)orbit_alloc(arena, len);
        if (!out) return NULL;
        memcpy(out, haystack, len);
        return out;
    }
    size_t pre = (size_t)(pos - haystack);
    size_t needle_len = strlen(needle);
    size_t repl_len = strlen(replacement);
    size_t out_len = strlen(haystack) - needle_len + repl_len + 1;
    char* out = (char*)orbit_alloc(arena, out_len);
    if (!out) return NULL;
    memcpy(out, haystack, pre);
    memcpy(out + pre, replacement, repl_len);
    strcpy(out + pre + repl_len, pos + needle_len);
    return out;
}

/** @brief Parameterized WHERE query: binds @p param as an escaped SQL literal into the first `?` of @p condition. */
orbit_string orbit_db_query_where_p(OrbitArena* arena, const char* table_name, const char* condition, const char* param) {
    if (!orbit_db_valid_identifier(table_name)) return "[]";
    KYNX_DB_QUERY_CHECK("[]");
    char* escaped = sqlite3_mprintf("%Q", param);
    if (!escaped) return "[]";
    char* cond = orbit_replace_first(arena, condition, "?", escaped);
    sqlite3_free(escaped);
    if (!cond) return "[]";
    orbit_collection col = { table_name, NULL };
    return orbit_db_where(arena, col, cond);
}

orbit_string orbit_db_query_get(OrbitArena* arena, const char* table_name, const char* id) {
    if (!orbit_db_valid_identifier(table_name)) return NULL;
    orbit_collection col = { table_name, NULL };
    return orbit_db_get(arena, col, id);
}

bool orbit_db_insert(const char* table_name, const char* json_data) {
    if (!orbit_db_valid_identifier(table_name)) return false;
    orbit_collection col = { table_name, NULL };
    return orbit_db_add(col, json_data);
}

bool orbit_db_delete(const char* table_name, const char* id) {
    if (!orbit_db_valid_identifier(table_name)) return false;
    orbit_collection col = { table_name, NULL };
    return orbit_db_del(col, id);
}

#endif

