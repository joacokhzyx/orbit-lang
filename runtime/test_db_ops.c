/**
 * @file  test_db_ops.c
 * @brief Runtime database-operation tests: update/count/where-v.
 *
 * Pins the SQL-complete surface at the C layer: partial update writes only
 * present keys and never the id, count answers without fetching rows,
 * multi-param WHERE binds in order, and the placeholder contract (count
 * match, no statement chaining) holds. Conventions follow
 * runtime/test_migrations.c.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "crt_compat.h"
#include <stdint.h>

#include "runtime.h"

#define RUN_TEST(name) \
    do { \
        printf("Running test: %s... ", #name); \
        fflush(stdout); \
        name(); \
        printf("PASSED\n"); \
        fflush(stdout); \
    } while (0)

static const char* TEST_DB = "test_db_ops_tmp.db";

static void fresh_db(void) {
    remove(TEST_DB);
    char wal[256];
    snprintf(wal, sizeof(wal), "%s-wal", TEST_DB);
    remove(wal);
    snprintf(wal, sizeof(wal), "%s-shm", TEST_DB);
    remove(wal);
    orbit_db_init(TEST_DB);
    assert(orbit_db_exec_ddl("CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY, name TEXT, qty INTEGER);"));
    assert(orbit_db_exec_ddl("DELETE FROM items;"));
}

/* Partial update: present keys are written, absent keys keep their values,
 * and the id column is never overwritten even when the payload has no id. */
static void test_update_partial(void) {
    fresh_db();
    assert(orbit_db_insert("items", "{\"id\":\"a\",\"name\":\"hammer\",\"qty\":3}"));
    assert(orbit_db_update("items", "a", "{\"qty\":9}"));
    OrbitArena* arena = orbit_arena_create(131072);
    orbit_string row = orbit_db_query_get(arena, "items", "a");
    assert(row != NULL);
    assert(strstr(row, "hammer") != NULL);
    assert(strstr(row, "\"qty\":\"9\"") != NULL);
    assert(strstr(row, "\"id\":\"a\"") != NULL);
    orbit_arena_destroy(arena);
    orbit_db_close();
}

/* Updating a missing row, or a payload with no usable fields, is false --
 * same honesty contract as create/delete. */
static void test_update_missing_is_false(void) {
    fresh_db();
    assert(orbit_db_insert("items", "{\"id\":\"a\",\"name\":\"hammer\",\"qty\":3}"));
    assert(orbit_db_update("items", "ghost", "{\"qty\":1}") == false);
    assert(orbit_db_update("items", "a", "{\"nope\":1}") == false);
    assert(orbit_db_update("items", "a", "{}") == false);
    orbit_db_close();
}

/* Two placeholders bind in order; a '?' inside a param value is data, not
 * a third placeholder. */
static void test_where_two_params(void) {
    fresh_db();
    assert(orbit_db_insert("items", "{\"id\":\"a\",\"name\":\"hammer\",\"qty\":3}"));
    assert(orbit_db_insert("items", "{\"id\":\"b\",\"name\":\"nail\",\"qty\":3}"));
    assert(orbit_db_insert("items", "{\"id\":\"c\",\"name\":\"saw\",\"qty\":7}"));
    OrbitArena* arena = orbit_arena_create(131072);
    orbit_string rows = orbit_db_query_where_v(arena, "items", "qty = ? AND name = ?", 2, "3", "nail");
    assert(rows != NULL);
    assert(strstr(rows, "\"id\":\"b\"") != NULL);
    assert(strstr(rows, "\"id\":\"a\"") == NULL);
    assert(strstr(rows, "\"id\":\"c\"") == NULL);
    orbit_string q = orbit_db_query_where_v(arena, "items", "name = ?", 1, "a?b");
    assert(q != NULL && strcmp(q, "[]") == 0);
    orbit_arena_destroy(arena);
    orbit_db_close();
}

/* Placeholder/param count mismatch and statement chaining answer empty,
 * never half-bound. */
static void test_where_contract(void) {
    fresh_db();
    assert(orbit_db_insert("items", "{\"id\":\"a\",\"name\":\"hammer\",\"qty\":3}"));
    OrbitArena* arena = orbit_arena_create(131072);
    assert(strcmp(orbit_db_query_where_v(arena, "items", "qty = ? AND name = ?", 1, "3"), "[]") == 0);
    assert(strcmp(orbit_db_query_where_v(arena, "items", "qty = ?; DELETE FROM items;", 1, "3"), "[]") == 0);
    /* The table survived the chaining attempt. */
    assert(orbit_db_count_all(arena, "items") == 1);
    orbit_arena_destroy(arena);
    orbit_db_close();
}

/* COUNT(*) without fetching: whole table and filtered, including zero. */
static void test_count(void) {
    fresh_db();
    OrbitArena* arena = orbit_arena_create(131072);
    assert(orbit_db_count_all(arena, "items") == 0);
    assert(orbit_db_insert("items", "{\"id\":\"a\",\"name\":\"hammer\",\"qty\":3}"));
    assert(orbit_db_insert("items", "{\"id\":\"b\",\"name\":\"nail\",\"qty\":3}"));
    assert(orbit_db_count_all(arena, "items") == 2);
    assert(orbit_db_count_v(arena, "items", "", 0) == 2);
    assert(orbit_db_count_v(arena, "items", "qty = ?", 1, "3") == 2);
    assert(orbit_db_count_v(arena, "items", "qty = ? AND name = ?", 2, "3", "nail") == 1);
    assert(orbit_db_count_v(arena, "items", "qty = ?", 1, "99") == 0);
    orbit_arena_destroy(arena);
    orbit_db_close();
}

/* Indexes ride the migrations runner (forward DDL), and queries keep
 * working with one in place. */
static void test_index_migration(void) {
    fresh_db();
    const char* migs[] = { "CREATE INDEX IF NOT EXISTS ix_items_qty ON items(qty)" };
    assert(orbit_run_migrations(migs, 1) == true);
    assert(orbit_db_insert("items", "{\"id\":\"a\",\"name\":\"hammer\",\"qty\":3}"));
    OrbitArena* arena = orbit_arena_create(131072);
    assert(orbit_db_count_v(arena, "items", "qty = ?", 1, "3") == 1);
    orbit_arena_destroy(arena);
    orbit_db_close();
}

int main(void) {
    printf("db_ops tests\n");
    fflush(stdout);
    RUN_TEST(test_update_partial);
    RUN_TEST(test_update_missing_is_false);
    RUN_TEST(test_where_two_params);
    RUN_TEST(test_where_contract);
    RUN_TEST(test_count);
    RUN_TEST(test_index_migration);
    printf("PASSED all db_ops tests\n");
    fflush(stdout);
    remove(TEST_DB);
    return 0;
}
