#include <stdio.h>
#include "sqlite3.h"

/* sqlite .lib->.dll wrapper exercise: open :memory:, create, insert via
 * bind, select via step/column, close. Links against sqlite3.def, runs
 * against sqlite3.dll copied beside the exe. */
int main(void) {
    sqlite3 *db = 0;
    sqlite3_stmt *st = 0;
    int rc, fails = 0;

    rc = sqlite3_open(":memory:", &db);
    if (rc != SQLITE_OK || !db) { printf("FAIL open %d\n", rc); return 1; }
    sqlite3_busy_timeout(db, 1000);
    rc = sqlite3_exec(db, "CREATE TABLE t(a INTEGER, b TEXT);", 0, 0, 0);
    if (rc != SQLITE_OK) { printf("FAIL create %s\n", sqlite3_errmsg(db)); return 1; }
    rc = sqlite3_prepare_v2(db, "INSERT INTO t(a,b) VALUES(?,?);", -1, &st, 0);
    if (rc != SQLITE_OK) { printf("FAIL prepare %s\n", sqlite3_errmsg(db)); return 1; }
    sqlite3_bind_int(st, 1, 41);
    sqlite3_bind_text(st, 2, "orbit", -1, SQLITE_TRANSIENT);
    rc = sqlite3_step(st);
    if (rc != SQLITE_DONE) { printf("FAIL step %d\n", rc); return 1; }
    sqlite3_finalize(st); st = 0;
    if (sqlite3_changes(db) != 1) { printf("FAIL changes\n"); return 1; }

    rc = sqlite3_prepare_v2(db, "SELECT a, b FROM t;", -1, &st, 0);
    if (rc != SQLITE_OK) { printf("FAIL select prepare\n"); return 1; }
    rc = sqlite3_step(st);
    if (rc != SQLITE_ROW) { printf("FAIL select step\n"); return 1; }
    if (sqlite3_column_int(st, 0) != 41) { printf("FAIL column_int\n"); return 1; }
    {
        const unsigned char *txt = sqlite3_column_text(st, 0 + 1);
        int i = 0; const char *want = "orbit";
        while (want[i] && txt[i] == (unsigned char)want[i]) i++;
        if (want[i] != 0 || txt[i] != 0) { printf("FAIL column_text\n"); return 1; }
    }
    if (sqlite3_column_count(st) != 2) { printf("FAIL column_count\n"); return 1; }
    if (!sqlite3_column_name(st, 0)) { printf("FAIL column_name\n"); return 1; }
    sqlite3_finalize(st);
    {
        char *m = sqlite3_mprintf("id=%d", 7);
        if (!m) { printf("FAIL mprintf\n"); return 1; }
        sqlite3_free(m);
    }
    sqlite3_progress_handler(db, 1000, 0, 0);
    sqlite3_close(db);
    if (fails == 0) printf("TCC-SHIM-SQLITE-PASS\n");
    return fails;
}
