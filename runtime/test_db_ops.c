/**
 * @file  test_db_ops.c
 * @brief Runtime database-operation tests: update/count/where-v/miss.
 *
 * Pins the SQL-complete surface at the C layer: partial update writes only
 * present keys and never the id, count answers without fetching rows,
 * multi-param WHERE binds in order, ordered scans honor validated columns,
 * the placeholder contract (count match, no statement chaining) holds, and a find/first that matches
 * nothing answers "" so `== ""` is the miss check instead of a segfault.
 * Conventions follow runtime/test_migrations.c.
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

/* Values containing quotes and backslashes must survive the JSON round trip:
 * the old first-quote cut stored `a \` for `a "b" \ c`. */
static void test_escaped_values(void) {
    fresh_db();
    assert(orbit_db_insert("items", "{\"id\":\"a\",\"name\":\"a \\\"b\\\" \\\\ c\",\"qty\":3}"));
    assert(orbit_db_update("items", "a", "{\"name\":\"a \\\"b\\\" \\\\ c\"}"));
    OrbitArena* arena = orbit_arena_create(131072);
    orbit_string row = orbit_db_query_get(arena, "items", "a");
    assert(row != NULL);
    assert(strstr(row, "\"name\":\"a \\\"b\\\" \\\\ c\"") != NULL);
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

/* Whole-table ordering by a validated column, both directions; anything
 * that is not an identifier answers "[]" instead of reaching the query. */
static void test_order(void) {
    fresh_db();
    assert(orbit_db_insert("items", "{\"id\":\"a\",\"name\":\"hammer\",\"qty\":3}"));
    assert(orbit_db_insert("items", "{\"id\":\"b\",\"name\":\"nail\",\"qty\":7}"));
    assert(orbit_db_insert("items", "{\"id\":\"c\",\"name\":\"saw\",\"qty\":1}"));
    OrbitArena* arena = orbit_arena_create(131072);
    orbit_string asc = orbit_db_query_order(arena, "items", "qty");
    assert(asc != NULL);
    assert(strstr(asc, "\"id\":\"c\"") < strstr(asc, "\"id\":\"a\""));
    assert(strstr(asc, "\"id\":\"a\"") < strstr(asc, "\"id\":\"b\""));
    orbit_string desc = orbit_db_query_order_desc(arena, "items", "qty");
    assert(desc != NULL);
    assert(strstr(desc, "\"id\":\"b\"") < strstr(desc, "\"id\":\"a\""));
    assert(strstr(desc, "\"id\":\"a\"") < strstr(desc, "\"id\":\"c\""));
    assert(strcmp(orbit_db_query_order(arena, "items", "qty; DROP TABLE items;"), "[]") == 0);
    assert(strcmp(orbit_db_query_order_desc(arena, "items", "qty DESC, id"), "[]") == 0);
    assert(strcmp(orbit_db_query_order(arena, "no such table!", "qty"), "[]") == 0);
    assert(orbit_db_count_all(arena, "items") == 3);
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

/* A find or first that matches nothing answers "", never NULL: NULL used
 * to travel into `==` and segfault the server on the first miss. A found
 * row always starts with '{', so "" is unambiguous. */
static void test_find_first_miss_is_empty(void) {
    fresh_db();
    OrbitArena* arena = orbit_arena_create(131072);
    assert(strcmp(orbit_db_query_get(arena, "items", "ghost"), "") == 0);
    assert(strcmp(orbit_db_query_first(arena, "items"), "") == 0);
    assert(orbit_db_insert("items", "{\"id\":\"a\",\"name\":\"hammer\",\"qty\":3}"));
    orbit_string row = orbit_db_query_get(arena, "items", "a");
    assert(row != NULL && row[0] == '{');
    assert(strcmp(orbit_db_query_get(arena, "items", "ghost"), "") == 0);
    orbit_string first = orbit_db_query_first(arena, "items");
    assert(first != NULL && first[0] == '{');
    /* Invalid identifiers and NULL fragments answer the empty value, never
     * NULL: every read wrapper agrees, so `== ""` cannot segfault. */
    assert(strcmp(orbit_db_query_get(arena, "no such table!", "a"), "") == 0);
    assert(strcmp(orbit_db_query_first(arena, "no such table!"), "") == 0);
    assert(strcmp(orbit_db_query_where(arena, "items", NULL), "[]") == 0);
    orbit_arena_destroy(arena);
    orbit_db_close();
}

/* A failed prepare (dropped table) is an empty answer, not NULL: user code
 * cannot distinguish NULL, so a fault must not surface as one. */
static void test_find_prepare_failure_is_empty(void) {
    fresh_db();
    assert(orbit_db_insert("items", "{\"id\":\"a\",\"name\":\"hammer\",\"qty\":3}"));
    assert(orbit_db_exec_ddl("DROP TABLE items;"));
    OrbitArena* arena = orbit_arena_create(131072);
    assert(strcmp(orbit_db_query_get(arena, "items", "a"), "") == 0);
    assert(strcmp(orbit_db_query_first(arena, "items"), "") == 0);
    orbit_arena_destroy(arena);
    orbit_db_close();
}

/* Values are data. Each hostile string below is bound to a `?`, so it can
 * only be compared against the column; none of them changes the statement.
 * The control row proves the hostile value did not widen the match and the
 * table survived. */
static void test_injection_values_are_data(void) {
    fresh_db();
    assert(orbit_db_insert("items", "{\"id\":\"a\",\"name\":\"hammer\",\"qty\":3}"));
    assert(orbit_db_insert("items", "{\"id\":\"b\",\"name\":\"nail\",\"qty\":7}"));
    OrbitArena* arena = orbit_arena_create(131072);
    const char* evil[] = {
        "' OR 1=1 --",
        "1=1; DROP TABLE items",
        "x'; DELETE FROM items; --",
        "\" OR \"\"=\"",
        "%",
    };
    for (size_t i = 0; i < sizeof(evil) / sizeof(evil[0]); i++) {
        assert(strcmp(orbit_db_query_where_p(arena, "items", "name = ?", evil[i]), "[]") == 0);
        assert(strcmp(orbit_db_query_where_v(arena, "items", "name = ? AND qty = ?", 2, evil[i], "3"), "[]") == 0);
        assert(orbit_db_count_v(arena, "items", "name = ?", 1, evil[i]) == 0);
    }
    assert(orbit_db_count_all(arena, "items") == 2);
    /* The same text stored as a value round-trips: it is compared as bytes. */
    assert(orbit_db_insert("items", "{\"id\":\"c\",\"name\":\"' OR 1=1 --\",\"qty\":1}"));
    orbit_string hit = orbit_db_query_where_p(arena, "items", "name = ?", "' OR 1=1 --");
    assert(strstr(hit, "\"id\":\"c\"") != NULL);
    assert(strstr(hit, "\"id\":\"a\"") == NULL);
    assert(orbit_db_count_all(arena, "items") == 3);
    orbit_arena_destroy(arena);
    orbit_db_close();
}

/* The fragment is code, so it is held to a boolean expression over the
 * model's own columns. Every refusal answers "[]" (and a line on stderr),
 * and the table is intact afterwards. */
static void test_injection_fragments_are_refused(void) {
    fresh_db();
    assert(orbit_db_insert("items", "{\"id\":\"a\",\"name\":\"hammer\",\"qty\":3}"));
    OrbitArena* arena = orbit_arena_create(131072);
    const char* bad[] = {
        "1=1; DROP TABLE items",
        "name = 'hammer'",
        "name = \"hammer\"",
        "1=1 --",
        "1=1 /* x */",
        "qty = 3 UNION SELECT * FROM sqlite_master",
        "id IN (SELECT name FROM sqlite_master)",
        "ghost_column = 1",
        "qty = ?1",
        "qty = :x",
        "",
    };
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
        assert(strcmp(orbit_db_query_where(arena, "items", bad[i]), "[]") == 0);
        assert(orbit_db_count_v(arena, "items", bad[i], 0) == 0 || bad[i][0] == '\0');
    }
    /* A table name is an identifier, never SQL. */
    assert(strcmp(orbit_db_query_where(arena, "items; DROP TABLE items", "qty = 3"), "[]") == 0);
    assert(strcmp(orbit_db_query_where(arena, "items WHERE 1=1 --", "qty = 3"), "[]") == 0);
    assert(orbit_db_count_all(arena, "items") == 1);
    /* Controls: admissible fragments still match. */
    assert(strstr(orbit_db_query_where(arena, "items", "qty >= 3"), "\"id\":\"a\"") != NULL);
    assert(strstr(orbit_db_query_where_v(arena, "items", "name LIKE ?", 1, "h%"), "\"id\":\"a\"") != NULL);
    assert(orbit_db_count_v(arena, "items", "qty >= ?", 1, "3") == 1);
    orbit_arena_destroy(arena);
    orbit_db_close();
}

int main(void) {
    printf("db_ops tests\n");
    fflush(stdout);
    RUN_TEST(test_update_partial);
    RUN_TEST(test_escaped_values);
    RUN_TEST(test_update_missing_is_false);
    RUN_TEST(test_where_two_params);
    RUN_TEST(test_where_contract);
    RUN_TEST(test_injection_values_are_data);
    RUN_TEST(test_injection_fragments_are_refused);
    RUN_TEST(test_count);
    RUN_TEST(test_order);
    RUN_TEST(test_index_migration);
    RUN_TEST(test_find_first_miss_is_empty);
    RUN_TEST(test_find_prepare_failure_is_empty);
    printf("PASSED all db_ops tests\n");
    fflush(stdout);
    remove(TEST_DB);
    return 0;
}
