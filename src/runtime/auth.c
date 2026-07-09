#ifndef ORBIT_AUTH_H
#define ORBIT_AUTH_H

#include <time.h>
#include <string.h>
#include <stdbool.h>
/* Depende (ya incluidos antes por runtime.h) de:
   types.c    -> orbit_string (== const char*)
   arena.c    -> orbit_alloc / orbit_arena_strdup / OrbitArena
   database.c -> orbit_db_conn (sqlite3*, static, misma TU) + sqlite3.h  */

static bool orbit_auth_ci_prefix(const char* s, const char* prefix) {
    while (*prefix) {
        char a = *s, b = *prefix;
        if (a >= 'A' && a <= 'Z') a += 32;
        if (b >= 'A' && b <= 'Z') b += 32;
        if (a != b) return false;
        s++; prefix++;
    }
    return true;
}

void orbit_auth_init(void) {
    if (!orbit_db_conn) return;
    const char* schema =
        "CREATE TABLE IF NOT EXISTS users ("
        "  id   TEXT PRIMARY KEY,"
        "  role TEXT NOT NULL DEFAULT 'user'"
        ");"
        "CREATE TABLE IF NOT EXISTS sessions ("
        "  token      TEXT PRIMARY KEY,"
        "  user_id    TEXT NOT NULL,"
        "  expires_at INTEGER NOT NULL DEFAULT 0" 
        ");"
        "CREATE INDEX IF NOT EXISTS idx_sessions_token ON sessions(token);";
    sqlite3_exec(orbit_db_conn, schema, NULL, NULL, NULL);
}

orbit_string orbit_auth_bearer_token(OrbitArena* arena, const char* raw) {
    if (!raw) return NULL;

    const char* body_sep = strstr(raw, "\r\n\r\n");
    const char* limit = body_sep ? body_sep : raw + strlen(raw);

    const char* line = raw;
    while (line < limit) {
        if (orbit_auth_ci_prefix(line, "authorization:")) {
            const char* v = line + strlen("authorization:");
            while (v < limit && (*v == ' ' || *v == '\t')) v++;
            if (orbit_auth_ci_prefix(v, "bearer ")) v += strlen("bearer ");
            while (v < limit && (*v == ' ' || *v == '\t')) v++;
            const char* e = v;
            while (e < limit && *e != '\r' && *e != '\n' && *e != ' ') e++;
            size_t len = (size_t)(e - v);
            char* out = (char*)orbit_alloc(arena, len + 1);
            if (!out) return NULL;
            memcpy(out, v, len);
            out[len] = '\0';
            return out;
        }
        const char* nl = strchr(line, '\n');
        if (!nl || nl >= limit) break;
        line = nl + 1;
    }
    return NULL;
}

orbit_string orbit_auth_role(OrbitArena* arena, const char* token) {
    if (!orbit_db_conn || !token || !*token) return orbit_arena_strdup(arena, "");

    const char* sql =
        "SELECT u.role FROM sessions s "
        "JOIN users u ON u.id = s.user_id "
        "WHERE s.token = ?1 AND (s.expires_at = 0 OR s.expires_at > ?2) "
        "LIMIT 1;";

    sqlite3_stmt* stmt = NULL;
    if (sqlite3_prepare_v2(orbit_db_conn, sql, -1, &stmt, NULL) != SQLITE_OK)
        return orbit_arena_strdup(arena, "");

    sqlite3_bind_text(stmt, 1, token, -1, SQLITE_STATIC);
    sqlite3_bind_int64(stmt, 2, (sqlite3_int64)time(NULL));

    orbit_string role = orbit_arena_strdup(arena, "");
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        const char* r = (const char*)sqlite3_column_text(stmt, 0);
        if (r) role = orbit_arena_strdup(arena, r);
    }
    sqlite3_finalize(stmt);
    return role;
}

bool orbit_auth_has_role(OrbitArena* arena, const char* raw, const char* required) {
    orbit_string tok = orbit_auth_bearer_token(arena, raw);
    if (!tok || !*tok) return false;
    orbit_string role = orbit_auth_role(arena, tok);
    if (!role || !*role) return false;
    if (!required || !*required) return true; 
    return strcmp(role, required) == 0;
}

orbit_string orbit_auth_current_role(OrbitArena* arena, const char* raw) {
    orbit_string tok = orbit_auth_bearer_token(arena, raw);
    if (!tok) return orbit_arena_strdup(arena, "");
    return orbit_auth_role(arena, tok);
}

#endif