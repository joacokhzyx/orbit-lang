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
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "arena.c"
#include "types.c"
#include "inline.h"
#include "crt_compat.h"

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

static int orbit_db_authorizer(void* user, int action, const char* a1, const char* a2,
                               const char* a3, const char* a4);

void orbit_db_init(const char* db_path) {
    int open_rc = sqlite3_open(db_path, &orbit_db_conn);
    /* sqlite3_open hands back a non-NULL handle even when it fails: the handle
     * exists so the caller has something to close, and it is unusable. Testing
     * `if (orbit_db_conn)` therefore let a dead connection through, and every
     * statement below ran against a database that was never opened -- which is
     * the kind of thing that shows up as an access violation somewhere else
     * entirely rather than as "the database did not open". Checking the return
     * code and leaving the handle NULL makes the `if (!orbit_db_conn) return
     * false` guards that already guard the rest of this file actually fire.
     *
     * The signature stays void: changing it would ripple into every caller and
     * into the emitted C. A NULL handle is the signal those callers check for. */
    if (open_rc != SQLITE_OK || !orbit_db_conn) {
        fprintf(stderr, "orbit: database open failed (%s): %s\n",
                db_path ? db_path : "(null path)",
                orbit_db_conn ? sqlite3_errmsg(orbit_db_conn) : "no handle");
        if (orbit_db_conn) {
            sqlite3_close(orbit_db_conn);
            orbit_db_conn = NULL;
        }
        return;
    }
    sqlite3_busy_timeout(orbit_db_conn, 5000);
    sqlite3_exec(orbit_db_conn, "PRAGMA journal_mode=WAL;", NULL, NULL, NULL);
    sqlite3_progress_handler(orbit_db_conn, 10, orbit_sqlite_progress_handler, NULL);
    /* Installed once: it is a no-op until a filtered read arms it for its own
     * thread (orbit_db_auth_table), so DDL and writes are unaffected. */
    sqlite3_set_authorizer(orbit_db_conn, orbit_db_authorizer, NULL);
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
            "INSERT INTO users VALUES ('usr_dev', 'developer', 'dev@orbit.dev', 'developer');";
        sqlite3_exec(orbit_db_conn, seed_sql, NULL, NULL, NULL);
    }
}

/** @brief Close the global SQLite connection and set the internal handle to NULL. */
void orbit_db_close(void) {
    if (orbit_db_conn) {
        sqlite3_close(orbit_db_conn);
        orbit_db_conn = NULL;
    }
}

/** @brief Execute compiler-generated schema DDL at startup (CREATE TABLE IF
 * NOT EXISTS per model). The SQL text is assembled by the compiler from
 * validated model/field identifiers, never from request input. */
bool orbit_db_exec_ddl(const char* sql) {
    char* msg = NULL;
    int rc;
    if (!sql || !*sql) return false;
    if (!orbit_db_conn) return false;
    rc = sqlite3_exec(orbit_db_conn, sql, NULL, NULL, &msg);
    if (msg) sqlite3_free(msg);
    return rc == SQLITE_OK;
}

/** @brief Execute one declared migration set (idempotent). Creates the
 * bookkeeping table on first use and runs each statement exactly once, in
 * declaration order, inside a transaction. Reruns are no-ops, so applying
 * the same program against an already-migrated database is safe. */
bool orbit_run_migrations(const char* const* migrations, int count) {
    if (!orbit_db_conn) return false;
    int rc = sqlite3_exec(orbit_db_conn,
        "CREATE TABLE IF NOT EXISTS _orbit_migrations (version INTEGER PRIMARY KEY);",
        NULL, NULL, NULL);
    if (rc != SQLITE_OK) return false;
    for (int i = 0; i < count; i++) {
        sqlite3_stmt* stmt = NULL;
        int done = 0;
        if (sqlite3_prepare_v2(orbit_db_conn, "SELECT 1 FROM _orbit_migrations WHERE version = ?", -1, &stmt, NULL) != SQLITE_OK) {
            return false;
        }
        sqlite3_bind_int(stmt, 1, i);
        if (sqlite3_step(stmt) == SQLITE_ROW) done = 1;
        sqlite3_finalize(stmt);
        if (done) continue;
        if (!migrations[i] || !*migrations[i]) return false;
        char* msg = NULL;
        rc = sqlite3_exec(orbit_db_conn, "BEGIN;", NULL, NULL, NULL);
        if (rc != SQLITE_OK) return false;
        rc = sqlite3_exec(orbit_db_conn, migrations[i], NULL, NULL, &msg);
        if (rc == SQLITE_OK) {
            sqlite3_stmt* ins = NULL;
            sqlite3_prepare_v2(orbit_db_conn, "INSERT INTO _orbit_migrations (version) VALUES (?);", -1, &ins, NULL);
            sqlite3_bind_int(ins, 1, i);
            sqlite3_step(ins);
            sqlite3_finalize(ins);
            rc = sqlite3_exec(orbit_db_conn, "COMMIT;", NULL, NULL, NULL);
        } else {
            sqlite3_exec(orbit_db_conn, "ROLLBACK;", NULL, NULL, NULL);
        }
        if (msg) sqlite3_free(msg);
        if (rc != SQLITE_OK) return false;
    }
    return true;
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

/** @brief Fetch a single row from @p col by @p id and return it as a JSON object string, or "" if not found. */
orbit_string orbit_db_get(OrbitArena* arena, orbit_collection col, const char* id) {
    KYNX_DB_QUERY_CHECK("");
    const char* fmt = "SELECT * FROM %s WHERE id = ?;";
    size_t query_len = strlen(fmt) + strlen(col.table_name) + 16;
    char* query = (char*)orbit_alloc(arena, query_len);
    if (!query) return NULL;
    snprintf(query, query_len, "SELECT * FROM %s WHERE id = ?;", col.table_name);

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(orbit_db_conn, query, -1, &stmt, NULL) != SQLITE_OK)
        return "";

    sqlite3_bind_text(stmt, 1, id, -1, SQLITE_STATIC);

    /* A miss is the empty string, not NULL: Orbit strings have no null, and
     * a NULL here used to travel into `==` and segfault the server on the
     * first find of a missing key. where() already answers "[]" on empty;
     * this is the same contract for one row. A failed prepare answers ""
     * too: user code cannot distinguish NULL, so NULL is never a usable
     * fault signal here. Only OOM (with a custom handler installed) can
     * still surface NULL, and that path aborts loudly by default. */
    orbit_string result = "";
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

/* ── Filtered reads: the WHERE fragment contract ───────────────────────
 *
 * Model.where(cond, p...) and Model.count(cond, p...) take a SQL fragment
 * with `?` placeholders. Values reach SQLite only through sqlite3_bind_text;
 * no value is ever pasted into the statement text. The table name is a
 * validated identifier. The fragment itself is code, so it is held to a
 * boolean expression over the model's own columns:
 *   - no quote characters (' " ` [): a literal is a value and goes in a `?`;
 *     this also closes SQLite's fallback that reads an unknown "name" as a
 *     string, so an unknown column is an error and never a constant;
 *   - no ';' and no comment opener (-- and slash-star);
 *   - anonymous placeholders only, and exactly as many as there are params;
 *   - the prepared statement must be one read-only statement, and an
 *     authorizer limits it to SELECT, the model's own table and functions
 *     (no other table, no sqlite_master, no recursive CTE).
 * A fragment that breaks the contract is refused with a line on stderr and
 * answers "[]", the same value as an empty result. */
static __thread const char* orbit_db_auth_table = NULL;

static int orbit_db_authorizer(void* user, int action, const char* a1, const char* a2,
                               const char* a3, const char* a4) {
    (void)user; (void)a2; (void)a3; (void)a4;
    const char* table = orbit_db_auth_table;
    if (!table) return SQLITE_OK;
    switch (action) {
    case SQLITE_SELECT:
    case SQLITE_FUNCTION:
        return SQLITE_OK;
    case SQLITE_READ:
        return (a1 && sqlite3_stricmp(a1, table) == 0) ? SQLITE_OK : SQLITE_DENY;
    default:
        return SQLITE_DENY;
    }
}

static void orbit_db_refuse(const char* table, const char* why) {
    fprintf(stderr, "orbit: db: query on '%s' refused: %s\n", table ? table : "(null)", why);
}

/** @brief NULL when @p cond is an admissible fragment, else the reason. */
static const char* orbit_db_fragment_reason(const char* cond) {
    if (!cond || !*cond) return "empty condition";
    for (const char* c = cond; *c; c++) {
        switch (*c) {
        case '\'': case '"': case '`': case '[':
            return "quote characters are not allowed in a condition; pass the value as a ? parameter";
        case ';':
            return "';' is not allowed in a condition";
        case '-':
            if (c[1] == '-') return "comments are not allowed in a condition";
            break;
        case '/':
            if (c[1] == '*') return "comments are not allowed in a condition";
            break;
        default:
            break;
        }
    }
    return NULL;
}

/** @brief Prepare "<select> FROM <table> [WHERE <cond>]" and bind @p params.
 *         Returns NULL after writing the reason to stderr when anything in
 *         the contract above fails. The caller finalizes the statement. */
static sqlite3_stmt* orbit_db_prepare_bound(OrbitArena* arena, const char* select,
                                            const char* table, const char* cond,
                                            int nparams, const char* const* params) {
    if (!orbit_db_valid_identifier(table)) {
        orbit_db_refuse(table, "table name is not an identifier");
        return NULL;
    }
    if (cond) {
        const char* why = orbit_db_fragment_reason(cond);
        if (why) { orbit_db_refuse(table, why); return NULL; }
    }
    size_t query_len = strlen(select) + strlen(table) + (cond ? strlen(cond) : 0) + 16;
    char* query = (char*)orbit_alloc(arena, query_len);
    if (!query) return NULL;
    if (cond) snprintf(query, query_len, "%s FROM %s WHERE %s", select, table, cond);
    else snprintf(query, query_len, "%s FROM %s", select, table);

    sqlite3_stmt* stmt = NULL;
    const char* tail = NULL;
    orbit_db_auth_table = table;
    int rc = sqlite3_prepare_v2(orbit_db_conn, query, -1, &stmt, &tail);
    orbit_db_auth_table = NULL;
    if (rc != SQLITE_OK || !stmt) {
        orbit_db_refuse(table, rc == SQLITE_AUTH ? "condition reads something other than this table"
                                                  : sqlite3_errmsg(orbit_db_conn));
        if (stmt) sqlite3_finalize(stmt);
        return NULL;
    }
    while (tail && (*tail == ' ' || *tail == '\t' || *tail == '\r' || *tail == '\n')) tail++;
    const char* why = NULL;
    if (tail && *tail) why = "more than one statement";
    else if (!sqlite3_stmt_readonly(stmt)) why = "statement is not read-only";
    else if (sqlite3_bind_parameter_count(stmt) != nparams) why = "placeholder count does not match the parameter count";
    else {
        for (int i = 1; i <= nparams; i++) {
            if (sqlite3_bind_parameter_name(stmt, i)) { why = "only anonymous ? placeholders are allowed"; break; }
        }
    }
    if (why) {
        orbit_db_refuse(table, why);
        sqlite3_finalize(stmt);
        return NULL;
    }
    for (int i = 0; i < nparams; i++) {
        const char* v = params && params[i] ? params[i] : "";
        sqlite3_bind_text(stmt, i + 1, v, -1, SQLITE_TRANSIENT);
    }
    return stmt;
}

/** @brief Rows of @p table matching @p condition, bound with @p params, as a JSON array ("[]" on refusal). */
static orbit_string orbit_db_where_bound(OrbitArena* arena, const char* table, const char* condition,
                                         int nparams, const char* const* params) {
    KYNX_DB_QUERY_CHECK("[]");
    sqlite3_stmt* stmt = orbit_db_prepare_bound(arena, "SELECT *", table, condition, nparams, params);
    if (!stmt) return "[]";

    size_t buf_cap = 8192;
    char* buf = (char*)orbit_alloc(arena, buf_cap);
    if (!buf) { sqlite3_finalize(stmt); return "[]"; }

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

/** @brief Rows of @p col matching @p condition (a fragment with no placeholders; see the contract above). */
orbit_string orbit_db_where(OrbitArena* arena, orbit_collection col, const char* condition) {
    return orbit_db_where_bound(arena, col.table_name, condition, 0, NULL);
}

/** @brief Fetch the first row from @p col and return it as a JSON object string, or "" if the table is empty. */
orbit_string orbit_db_first(OrbitArena* arena, orbit_collection col) {
    KYNX_DB_QUERY_CHECK("");
    size_t query_len = strlen("SELECT * FROM  LIMIT 1;") + strlen(col.table_name) + 1;
    char* query = (char*)orbit_alloc(arena, query_len);
    if (!query) return NULL;
    snprintf(query, query_len, "SELECT * FROM %s LIMIT 1;", col.table_name);

    sqlite3_stmt* stmt;
    if (sqlite3_prepare_v2(orbit_db_conn, query, -1, &stmt, NULL) != SQLITE_OK)
        return "";

    /* Same miss contract as orbit_db_get: "" so `== ""` is the miss check. */
    orbit_string result = "";
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



/** @brief Insert a JSON document into @p col; uses malloc for the query buffer since no arena is available at insert time. */
/** @brief Extract a value for @p key from a flat JSON object: quoted string values
 *         ("key":"value") are escape-decoded, bare values ("key":value, e.g.
 *         numbers) are copied verbatim. Returns NULL when the key is absent.
 *         Caller frees the returned copy.
 */
static char* orbit_json_get_value(const char* json, const char* key) {
    if (!json || !key) return NULL;

    size_t key_len = strlen(key);
    char* pat = (char*)malloc(key_len + 3);
    if (!pat) return NULL;
    snprintf(pat, key_len + 3, "\"%s\"", key);
    const char* pos = strstr(json, pat);
    free(pat);
    if (!pos) return NULL;
    pos += key_len + 2;
    while (*pos == ' ' || *pos == '\t' || *pos == '\r' || *pos == '\n') pos++;
    if (*pos != ':') return NULL;
    pos++;
    while (*pos == ' ' || *pos == '\t' || *pos == '\r' || *pos == '\n') pos++;
    if (*pos == '"') {
        /* Direct decode, not orbit_json_parse: no arena exists at insert time
         * (see the doc comment above) and only the value is wanted. The scan
         * skips escaped bytes so an inner quote cannot cut the value short,
         * and the copy decodes the escapes a JSON writer produces
         * (" \\ / b f n r t). Anything else keeps its backslash, so no value
         * is ever truncated and a \uXXXX or bad escape stays verbatim. */
        pos++;
        const char* end = pos;
        while (*end && *end != '"') end += (*end == '\\' && end[1]) ? 2 : 1;
        if (*end != '"') return NULL;
        char* res = (char*)malloc((size_t)(end - pos) + 1);
        if (!res) return NULL;
        char* out = res;
        for (const char* r = pos; r < end; r++) {
            if (*r == '\\' && r + 1 < end) {
                r++;
                switch (*r) {
                case '"': *(out++) = '"'; break;
                case '\\': *(out++) = '\\'; break;
                case '/': *(out++) = '/'; break;
                case 'b': *(out++) = '\b'; break;
                case 'f': *(out++) = '\f'; break;
                case 'n': *(out++) = '\n'; break;
                case 'r': *(out++) = '\r'; break;
                case 't': *(out++) = '\t'; break;
                default: *(out++) = '\\'; *(out++) = *r; break;
                }
            } else {
                *(out++) = *r;
            }
        }
        *out = '\0';
        return res;
    }
    const char* end = pos;
    while (*end && *end != ',' && *end != '}' && *end != ']' && *end != '\n') end++;
    const char* trim = end;
    while (trim > pos && (trim[-1] == ' ' || trim[-1] == '\t' || trim[-1] == '\r')) trim--;
    size_t len = (size_t)(trim - pos);
    char* res = (char*)malloc(len + 1);
    if (res) {
        memcpy(res, pos, len);
        res[len] = '\0';
    }
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
                memcpy(copy, name, strlen(name) + 1);
                col_names[ncols] = copy;
                ncols++;
            }
        }
    }
    sqlite3_finalize(col_stmt);
    if (ncols == 0) return false;

    /* "INSERT INTO <table> (c1,c2,...) VALUES (?,?,...);" */
    size_t qlen = strlen("INSERT INTO ") + strlen(col.table_name)
        + strlen(" () VALUES ();") + 1;
    for (int i = 0; i < ncols; i++) qlen += strlen(col_names[i]) + 4;
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

/** @brief Update the row with the given @p id in @p col from a JSON document.

Only keys present in @p json_data are written (partial update); the `id`
column itself is never overwritten, so a payload without `id` cannot wipe
the key. Returns true iff a row actually changed. */
bool orbit_db_set(orbit_collection col, const char* id, const char* json_data) {
    KYNX_DB_QUERY_CHECK(false);
    if (!col.table_name || !id || !json_data) return false;
    if (!orbit_db_valid_identifier(col.table_name)) return false;

    /* Same column walk as orbit_db_add: the schema is the table's, not the
     * payload's. Absent keys are skipped (not blanked); only `id` is key. */
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
        if (name && strcmp(name, "id") != 0) {
            char* value = orbit_json_get_value(json_data, name);
            if (value) {
                char* copy = (char*)malloc(strlen(name) + 1);
                if (copy) {
                    memcpy(copy, name, strlen(name) + 1);
                    col_names[ncols] = copy;
                    ncols++;
                }
                free(value);
            }
        }
    }
    sqlite3_finalize(col_stmt);
    if (ncols == 0) return false;

    /* "UPDATE <table> SET c1=?,c2=? WHERE id = ?;" */
    size_t qlen = strlen("UPDATE  SET  WHERE id = ?;") + strlen(col.table_name) + 1;
    for (int i = 0; i < ncols; i++) qlen += strlen(col_names[i]) + 4;
    char* query = (char*)malloc(qlen);
    if (!query) {
        for (int i = 0; i < ncols; i++) free((void*)col_names[i]);
        return false;
    }

    char* p = query;
    p += snprintf(p, (size_t)(query + qlen - p), "UPDATE %s SET ", col.table_name);
    for (int i = 0; i < ncols; i++) {
        if (i > 0) *(p++) = ',';
        p += snprintf(p, (size_t)(query + qlen - p), "%s=?", col_names[i]);
    }
    p += snprintf(p, (size_t)(query + qlen - p), " WHERE id = ?;");

    sqlite3_stmt* stmt = NULL;
    bool success = false;
    if (sqlite3_prepare_v2(orbit_db_conn, query, -1, &stmt, NULL) == SQLITE_OK) {
        for (int i = 0; i < ncols; i++) {
            char* value = orbit_json_get_value(json_data, col_names[i]);
            sqlite3_bind_text(stmt, i + 1, value ? value : "", -1, SQLITE_TRANSIENT);
            free(value);
        }
        sqlite3_bind_text(stmt, ncols + 1, id, -1, SQLITE_STATIC);
        success = (sqlite3_step(stmt) == SQLITE_DONE)
            && (sqlite3_changes(orbit_db_conn) > 0);
        sqlite3_finalize(stmt);
    }

    free(query);
    for (int i = 0; i < ncols; i++) free((void*)col_names[i]);
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
    /* DONE alone is not enough: deleting zero rows still steps DONE. */
    bool success = (sqlite3_step(stmt) == SQLITE_DONE)
        && (sqlite3_changes(orbit_db_conn) > 0);
    sqlite3_finalize(stmt);
    free(query);
    return success;
}

// ─── JSON Helpers ────────────────────────────────────────────────────────────



orbit_string orbit_db_query_all(OrbitArena* arena, const char* table_name) {
    if (!orbit_db_valid_identifier(table_name)) return "[]";
    orbit_collection col = { table_name, NULL };
    uint64_t t0 = orbit_ledger_db_begin();
    orbit_string r = orbit_db_all(arena, col);
    orbit_ledger_db_end(t0);
    return r;
}

/** @brief Ordered full scan of @p col by @p col_name (@p desc selects DESC).
 *
 * The direction is fixed by the calling verb, never a string, and both
 * names are validated identifiers before use, so no user text reaches the
 * query. Answers "[]" on any failure, like every other read. Ordering is
 * whole-table only: filtered ordering does not exist yet. */
static orbit_string orbit_db_order(OrbitArena* arena, orbit_collection col, const char* col_name, int desc) {
    KYNX_DB_QUERY_CHECK("[]");
    size_t query_len = strlen("SELECT * FROM  ORDER BY  ;") + strlen(col.table_name) + strlen(col_name) + 8;
    char* query = (char*)orbit_alloc(arena, query_len);
    if (!query) return "[]";
    snprintf(query, query_len, "SELECT * FROM %s ORDER BY %s %s;", col.table_name, col_name, desc ? "DESC" : "ASC");

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

/** @brief Whole-table scan of @p table_name ordered by @p col_name ascending. */
orbit_string orbit_db_query_order(OrbitArena* arena, const char* table_name, const char* col_name) {
    if (!orbit_db_valid_identifier(table_name)) return "[]";
    if (!orbit_db_valid_identifier(col_name)) return "[]";
    orbit_collection col = { table_name, NULL };
    uint64_t t0 = orbit_ledger_db_begin();
    orbit_string r = orbit_db_order(arena, col, col_name, 0);
    orbit_ledger_db_end(t0);
    return r;
}

/** @brief Whole-table scan of @p table_name ordered by @p col_name descending. */
orbit_string orbit_db_query_order_desc(OrbitArena* arena, const char* table_name, const char* col_name) {
    if (!orbit_db_valid_identifier(table_name)) return "[]";
    if (!orbit_db_valid_identifier(col_name)) return "[]";
    orbit_collection col = { table_name, NULL };
    uint64_t t0 = orbit_ledger_db_begin();
    orbit_string r = orbit_db_order(arena, col, col_name, 1);
    orbit_ledger_db_end(t0);
    return r;
}

orbit_string orbit_db_query_where(OrbitArena* arena, const char* table_name, const char* condition) {
    if (!orbit_db_valid_identifier(table_name)) return "[]";
    if (!condition) return "[]";
    uint64_t t0 = orbit_ledger_db_begin();
    orbit_string r = orbit_db_where_bound(arena, table_name, condition, 0, NULL);
    orbit_ledger_db_end(t0);
    return r;
}

/** @brief Parameterized WHERE with N params: each param is bound, in order,
 *         to the '?' placeholders of @p condition. */
orbit_string orbit_db_query_where_v(OrbitArena* arena, const char* table_name, const char* condition, int nparams, ...) {
    if (!orbit_db_valid_identifier(table_name)) return "[]";
    if (!condition || !*condition) return "[]";
    if (nparams < 0) return "[]";
    KYNX_DB_QUERY_CHECK("[]");
    const char** params = NULL;
    if (nparams > 0) {
        params = (const char**)orbit_alloc(arena, (size_t)nparams * sizeof(char*));
        if (!params) return "[]";
        va_list ap;
        va_start(ap, nparams);
        for (int i = 0; i < nparams; i++) {
            params[i] = va_arg(ap, const char*);
        }
        va_end(ap);
    }
    uint64_t t0 = orbit_ledger_db_begin();
    orbit_string r = orbit_db_where_bound(arena, table_name, condition, nparams, params);
    orbit_ledger_db_end(t0);
    return r;
}

/** @brief COUNT(*) over @p table_name. */
orbit_int orbit_db_count_all(OrbitArena* arena, const char* table_name) {
    (void)arena;
    if (!orbit_db_valid_identifier(table_name)) return 0;
    KYNX_DB_QUERY_CHECK(0);
    size_t query_len = strlen("SELECT COUNT(*) FROM ;") + strlen(table_name) + 1;
    char* query = (char*)malloc(query_len);
    if (!query) return 0;
    snprintf(query, query_len, "SELECT COUNT(*) FROM %s;", table_name);
    sqlite3_stmt* stmt = NULL;
    orbit_int result = 0;
    if (sqlite3_prepare_v2(orbit_db_conn, query, -1, &stmt, NULL) == SQLITE_OK) {
        orbit_perf_stats.db_queries++;
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            result = (orbit_int)sqlite3_column_int64(stmt, 0);
        }
        sqlite3_finalize(stmt);
    }
    free(query);
    uint64_t t0 = orbit_ledger_db_begin();
    orbit_ledger_db_end(t0);
    return result;
}

/** @brief COUNT(*) over @p table_name with an optional parameterized filter
 *         (same placeholder contract as where_v; "" counts every row). */
orbit_int orbit_db_count_v(OrbitArena* arena, const char* table_name, const char* condition, int nparams, ...) {
    if (!orbit_db_valid_identifier(table_name)) return 0;
    if (!condition) return 0;
    if (nparams < 0) return 0;
    KYNX_DB_QUERY_CHECK(0);
    const char** params = NULL;
    if (*condition && nparams > 0) {
        params = (const char**)orbit_alloc(arena, (size_t)nparams * sizeof(char*));
        if (!params) return 0;
        va_list ap;
        va_start(ap, nparams);
        for (int i = 0; i < nparams; i++) {
            params[i] = va_arg(ap, const char*);
        }
        va_end(ap);
    }
    sqlite3_stmt* stmt = orbit_db_prepare_bound(arena, "SELECT COUNT(*)", table_name,
                                                *condition ? condition : NULL,
                                                *condition ? nparams : 0, params);
    orbit_int result = 0;
    if (stmt) {
        orbit_perf_stats.db_queries++;
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            result = (orbit_int)sqlite3_column_int64(stmt, 0);
        }
        sqlite3_finalize(stmt);
    }
    uint64_t t0 = orbit_ledger_db_begin();
    orbit_ledger_db_end(t0);
    return result;
}
orbit_string orbit_db_query_where_p(OrbitArena* arena, const char* table_name, const char* condition, const char* param) {
    if (!orbit_db_valid_identifier(table_name)) return "[]";
    if (!condition || !*condition) return "[]";
    const char* params[1] = { param };
    uint64_t t0 = orbit_ledger_db_begin();
    orbit_string r = orbit_db_where_bound(arena, table_name, condition, 1, params);
    orbit_ledger_db_end(t0);
    return r;
}

orbit_string orbit_db_query_get(OrbitArena* arena, const char* table_name, const char* id) {
    if (!orbit_db_valid_identifier(table_name)) return "";
    orbit_collection col = { table_name, NULL };
    uint64_t t0 = orbit_ledger_db_begin();
    orbit_string r = orbit_db_get(arena, col, id);
    orbit_ledger_db_end(t0);
    return r;
}

orbit_string orbit_db_query_first(OrbitArena* arena, const char* table_name) {
    if (!orbit_db_valid_identifier(table_name)) return "";
    orbit_collection col = { table_name, NULL };
    uint64_t t0 = orbit_ledger_db_begin();
    orbit_string r = orbit_db_first(arena, col);
    orbit_ledger_db_end(t0);
    return r;
}

bool orbit_db_insert(const char* table_name, const char* json_data) {
    if (!orbit_db_valid_identifier(table_name)) return false;
    orbit_collection col = { table_name, NULL };
    uint64_t t0 = orbit_ledger_db_begin();
    bool r = orbit_db_add(col, json_data);
    orbit_ledger_db_end(t0);
    return r;
}

bool orbit_db_delete(const char* table_name, const char* id) {
    if (!orbit_db_valid_identifier(table_name)) return false;
    orbit_collection col = { table_name, NULL };
    uint64_t t0 = orbit_ledger_db_begin();
    bool r = orbit_db_del(col, id);
    orbit_ledger_db_end(t0);
    return r;
}

bool orbit_db_update(const char* table_name, const char* id, const char* json_data) {
    if (!orbit_db_valid_identifier(table_name)) return false;
    orbit_collection col = { table_name, NULL };
    uint64_t t0 = orbit_ledger_db_begin();
    bool r = orbit_db_set(col, id, json_data);
    orbit_ledger_db_end(t0);
    return r;
}

#endif

