#include "runtime.h"
#include <stdio.h>
#include <string.h>

/* Auth unit gate: bearer extraction, role lookup with expiry, has_role.
 * Seeds through the public orbit_db_exec_ddl helper (never statics).
 * Returns nonzero on any mismatch so CI can gate on it. */

static int fails = 0;

static void check_str(const char* tag, const char* got, const char* want) {
    int ok = got && want && strcmp(got, want) == 0;
    printf("[%s] got='%s' want='%s' %s\n", tag, got ? got : "(null)",
           want, ok ? "OK" : "FAIL");
    if (!ok) fails++;
}

static void check_int(const char* tag, int got, int want) {
    int ok = (got == want);
    printf("[%s] got=%d want=%d %s\n", tag, got, want, ok ? "OK" : "FAIL");
    if (!ok) fails++;
}

int main(void) {
    orbit_db_init(":memory:");
    orbit_auth_init();

    if (!orbit_db_exec_ddl("INSERT INTO users(id,username,email,role_name) VALUES('u1','admin','admin@orbit.dev','admin');")) {
        printf("[seed] users u1 FAIL\n");
        fails++;
    }
    if (!orbit_db_exec_ddl("INSERT INTO users(id,username,email,role_name) VALUES('u2','developer','dev@orbit.dev','developer');")) {
        printf("[seed] users u2 FAIL\n");
        fails++;
    }
    orbit_db_exec_ddl("INSERT INTO sessions(token,user_id,expires_at) VALUES('tok_admin','u1',0);");
    orbit_db_exec_ddl("INSERT INTO sessions(token,user_id,expires_at) VALUES('tok_user','u2',0);");
    orbit_db_exec_ddl("INSERT INTO sessions(token,user_id,expires_at) VALUES('tok_expired','u1',1);");

    OrbitArena* a = orbit_arena_create(65536);

    check_str("role-admin", orbit_auth_role(a, "tok_admin"), "admin");
    check_str("role-user", orbit_auth_role(a, "tok_user"), "developer");
    check_str("role-expired", orbit_auth_role(a, "tok_expired"), "");
    check_str("role-unknown", orbit_auth_role(a, "nope"), "");

    const char* raw = "GET /admin HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer tok_admin\r\n\r\n";
    check_str("bearer", orbit_auth_bearer_token(a, raw), "tok_admin");
    check_int("has-admin", orbit_auth_has_role(a, raw, "admin"), 1);
    check_int("has-user", orbit_auth_has_role(a, raw, "developer"), 0);

    const char* raw_noauth = "GET /admin HTTP/1.1\r\nHost: x\r\n\r\n";
    check_str("bearer-missing", orbit_auth_bearer_token(a, raw_noauth), "");
    check_int("has-noauth", orbit_auth_has_role(a, raw_noauth, "admin"), 0);

    /* Hardening: NULL inputs never fault the worker. */
    check_str("bearer-null", orbit_auth_bearer_token(a, NULL), "");
    check_int("has-null", orbit_auth_has_role(a, NULL, "admin"), 0);
    check_str("role-null", orbit_auth_role(a, NULL), "");

    orbit_arena_destroy(a);
    orbit_db_close();
    printf("auth harness: %s (%d failures)\n", fails ? "FAILED" : "PASSED", fails);
    return fails ? 1 : 0;
}
