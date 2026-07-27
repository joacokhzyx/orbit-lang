#include "runtime.h"


int main(int argc, char** argv) {
    OrbitArena global_arena = orbit_arena_create(64 * 1024 * 1024);
    OrbitArena* arena = &global_arena;
    orbit_main();
    return 0;
}
