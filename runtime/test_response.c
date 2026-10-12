/* Response convenience wrappers: status, content type and body.
 *
 * orbit_response_json/error/html are one-line wrappers over
 * orbit_response_create; the only contract is the Content-Type each sets.
 * A wrapper that set the wrong type would serve bytes the client refuses to
 * render, so each type is asserted here, not trusted from the name.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

#include "runtime.h"

int main(void) {
    OrbitArena* arena = orbit_arena_create(65536);
    assert(arena != NULL);

    OrbitResponse* html = orbit_response_html(arena, 200, "<h1>hi</h1>");
    assert(html != NULL);
    assert(html->status == 200);
    assert(strcmp(html->content_type, "text/html") == 0);
    assert(strcmp(html->body, "<h1>hi</h1>") == 0);

    OrbitResponse* json = orbit_response_json(arena, 201, "{\"a\":1}");
    assert(json != NULL);
    assert(json->status == 201);
    assert(strcmp(json->content_type, "application/json") == 0);

    OrbitResponse* err = orbit_response_error(arena, 404, "nope");
    assert(err != NULL);
    assert(err->status == 404);
    assert(strcmp(err->content_type, "text/plain") == 0);

    OrbitResponse* empty = orbit_response_html(arena, 200, NULL);
    assert(empty != NULL);
    assert(empty->body_len == 0);

    printf("PASS test_response\n");
    return 0;
}
