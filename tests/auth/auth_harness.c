#include "src/runtime/runtime.h"
#include <stdio.h>

int main(void) {
    orbit_db_init(":memory:");
    orbit_auth_init();

    sqlite3_exec(orbit_db_conn, "INSERT INTO users(id,role) VALUES('u1','admin');", NULL,NULL,NULL);
    sqlite3_exec(orbit_db_conn, "INSERT INTO users(id,role) VALUES('u2','user');",  NULL,NULL,NULL);
    sqlite3_exec(orbit_db_conn, "INSERT INTO sessions(token,user_id,expires_at) VALUES('tok_admin','u1',0);",   NULL,NULL,NULL);
    sqlite3_exec(orbit_db_conn, "INSERT INTO sessions(token,user_id,expires_at) VALUES('tok_user','u2',0);",    NULL,NULL,NULL);
    sqlite3_exec(orbit_db_conn, "INSERT INTO sessions(token,user_id,expires_at) VALUES('tok_expired','u1',1);", NULL,NULL,NULL); /* expira en 1970 */

    OrbitArena* a = orbit_arena_create(65536);

    printf("[1] role(tok_admin)   = '%s'  (esperado: admin)\n",   orbit_auth_role(a, "tok_admin"));
    printf("[2] role(tok_user)    = '%s'  (esperado: user)\n",    orbit_auth_role(a, "tok_user"));
    printf("[3] role(tok_expired) = '%s'  (esperado: <vacio>)\n", orbit_auth_role(a, "tok_expired"));
    printf("[4] role(desconocido) = '%s'  (esperado: <vacio>)\n", orbit_auth_role(a, "nope"));

    const char* raw = "GET /admin HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer tok_admin\r\n\r\n";
    printf("[5] bearer_token      = '%s'  (esperado: tok_admin)\n", orbit_auth_bearer_token(a, raw));
    printf("[6] has_role(admin)   = %d    (esperado: 1)\n",         orbit_auth_has_role(a, raw, "admin"));
    printf("[7] has_role(user)    = %d    (esperado: 0)\n",         orbit_auth_has_role(a, raw, "user"));

    const char* raw_noauth = "GET /admin HTTP/1.1\r\nHost: x\r\n\r\n";
    printf("[8] has_role sin auth = %d    (esperado: 0)\n",         orbit_auth_has_role(a, raw_noauth, "admin"));
    return 0;
}