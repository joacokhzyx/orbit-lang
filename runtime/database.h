/* Interface of runtime/database.c (generated split; edit by hand from here). */
#ifndef ORBIT_RT_DATABASE_H
#define ORBIT_RT_DATABASE_H

#include "module_prelude.h"

#include "types.h"
#include "arena.h"

#include <sqlite3.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "arena.h"
#include "types.h"
#include "inline.h"
#include "crt_compat.h"
extern sqlite3* orbit_db_conn;

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
ORBIT_XLINK int orbit_sqlite_progress_handler(void* param);
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
void orbit_db_init(const char* db_path);
void orbit_db_close(void);
bool orbit_db_exec_ddl(const char* sql);
bool orbit_run_migrations(const char* const* migrations, int count);
orbit_string orbit_db_get(OrbitArena* arena, orbit_collection col, const char* id);
orbit_string orbit_db_all(OrbitArena* arena, orbit_collection col);
orbit_string orbit_db_where(OrbitArena* arena, orbit_collection col, const char* condition);
orbit_string orbit_db_first(OrbitArena* arena, orbit_collection col);
bool orbit_db_add(orbit_collection col, const char* json_data);
bool orbit_db_set(orbit_collection col, const char* id, const char* json_data);
bool orbit_db_del(orbit_collection col, const char* id);
orbit_string orbit_db_query_all(OrbitArena* arena, const char* table_name);
orbit_string orbit_db_query_order(OrbitArena* arena, const char* table_name, const char* col_name);
orbit_string orbit_db_query_order_desc(OrbitArena* arena, const char* table_name, const char* col_name);
orbit_string orbit_db_query_where(OrbitArena* arena, const char* table_name, const char* condition);
orbit_string orbit_db_query_where_v(OrbitArena* arena, const char* table_name, const char* condition, int nparams, ...);
orbit_int orbit_db_count_all(OrbitArena* arena, const char* table_name);
orbit_int orbit_db_count_v(OrbitArena* arena, const char* table_name, const char* condition, int nparams, ...);
orbit_string orbit_db_query_where_p(OrbitArena* arena, const char* table_name, const char* condition, const char* param);
orbit_string orbit_db_query_get(OrbitArena* arena, const char* table_name, const char* id);
orbit_string orbit_db_query_first(OrbitArena* arena, const char* table_name);
bool orbit_db_insert(const char* table_name, const char* json_data);
bool orbit_db_delete(const char* table_name, const char* id);
bool orbit_db_update(const char* table_name, const char* id, const char* json_data);

#endif
