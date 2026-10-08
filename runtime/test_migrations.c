/**
 * @file  test_migrations.c
 * @brief Runtime migration-runner tests.
 *
 * Migrations are the only thing protecting a live database from a schema
 * change, so their contract is pinned here at the C layer: an ALTER runs
 * exactly once (tracked in _orbit_migrations), a pre-existing row keeps its
 * values under a new column, a rerun is a no-op, and a bad statement fails
 * the whole migration rather than being recorded.
 *
 * Conventions follow runtime/test_file.c.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "crt_compat.h"
#include <stdint.h>

#include "runtime.h"

/* fflush after the banner, and after PASSED, because that is what makes a crash
 * attributable. On Windows stdout is fully buffered when it is a pipe, not a
 * console, so an access violation loses every buffered line and the CI log
 * shows a bare "[ORBIT RUNTIME CRASH]" with no indication of which test died --
 * which is how a crash in the migrations test was read as a crash in whichever
 * test happened to be compiled last. The line is there to name the failure. */
#define RUN_TEST(name) \
    do { \
        printf("Running test: %s... ", #name); \
        fflush(stdout); \
        name(); \
        printf("PASSED\n"); \
        fflush(stdout); \
    } while (0)

static const char* TEST_DB = "test_migrations_tmp.db";

static void fresh_db(void) {
    remove(TEST_DB);
    char wal[256];
    snprintf(wal, sizeof(wal), "%s-wal", TEST_DB);
    remove(wal);
    snprintf(wal, sizeof(wal), "%s-shm", TEST_DB);
    remove(wal);
    orbit_db_init(TEST_DB);
}

/* An ALTER TABLE ... ADD COLUMN applies, and rerunning the same set is a
 * no-op instead of a duplicate-column error: the second ALTER would fail
 * loudly if the runner were not tracking versions. */
static void test_add_column_twice_safe(void) {
    fresh_db();
    const char* migs[] = { "ALTER TABLE notes ADD COLUMN rank INTEGER" };
    assert(orbit_run_migrations(migs, 1) == true);
    assert(orbit_run_migrations(migs, 1) == true);
    orbit_db_close();
}

/* A row written under the old schema survives the migration with its
 * values, defaulting the new column. */
static void test_stale_row_upgrade(void) {
    fresh_db();
    sqlite3_exec(orbit_db_conn, "INSERT INTO products (id, name) VALUES ('p1', 'oldrow');", NULL, NULL, NULL);
    const char* migs[] = { "ALTER TABLE products ADD COLUMN rank INTEGER DEFAULT 3;" };
    assert(orbit_run_migrations(migs, 1) == true);

    /* The pre-migration row still reads, defaulting the new column. */
    sqlite3_stmt* stmt = NULL;
    assert(sqlite3_prepare_v2(orbit_db_conn, "SELECT name, rank FROM products WHERE id='p1';", -1, &stmt, NULL) == SQLITE_OK);
    assert(sqlite3_step(stmt) == SQLITE_ROW);
    assert(strcmp((const char*)sqlite3_column_text(stmt, 0), "oldrow") == 0);
    assert(sqlite3_column_int(stmt, 1) == 3);
    sqlite3_finalize(stmt);
    orbit_db_close();
}

/* A migration set recorded as applied never runs again, so new code with an
 * old database is safe to start repeatedly. */
static void test_rerun_is_noop(void) {
    fresh_db();
    const char* migs[] = { "CREATE TABLE IF NOT EXISTS tracked (id TEXT);", "INSERT INTO tracked VALUES ('x');" };
    assert(orbit_run_migrations(migs, 2) == true);
    assert(orbit_run_migrations(migs, 2) == true);
    sqlite3_stmt* stmt = NULL;
    assert(sqlite3_prepare_v2(orbit_db_conn, "SELECT COUNT(*) FROM tracked;", -1, &stmt, NULL) == SQLITE_OK);
    assert(sqlite3_step(stmt) == SQLITE_ROW);
    assert(sqlite3_column_int(stmt, 0) == 1);
    sqlite3_finalize(stmt);
    orbit_db_close();
}

/* A bad statement fails the runner rather than recording it: the next run
 * can then be fixed and retried. */
static void test_bad_migration_fails(void) {
    fresh_db();
    const char* migs[] = { "THIS IS NOT SQL;" };
    assert(orbit_run_migrations(migs, 1) == false);
    orbit_db_close();
}

int main(void) {
    printf("test_migrations\n");
    fflush(stdout); /* see RUN_TEST: a crash must name its test */
    RUN_TEST(test_add_column_twice_safe);
    RUN_TEST(test_stale_row_upgrade);
    RUN_TEST(test_rerun_is_noop);
    RUN_TEST(test_bad_migration_fails);
    return 0;
}
