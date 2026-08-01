#include "runtime.h"

void orbit_main(void);


int main(int argc, char** argv) {
    OrbitArena* arena = orbit_arena_create(64 * 1024 * 1024);
    orbit_main();
    return 0;
}
