# Program start-up and the runtime archive

A program initializes and links only what it uses. This page states what "uses"
means for each piece, how the runtime archive is split, and what a second code
generator (R6) must do at program entry to stay equal to the C backend.

## Runtime modules

`runtime/` holds one module per concern. Each module is a header (`<m>.h`,
the interface) and a source (`<m>.c`, the implementation).

| Group | Modules |
|---|---|
| Core | `perf`, `types`, `console`, `crash`, `arena`, `arena_alloc`, `arena_oom`, `arena_reset`, `arena_checkpoint`, `arena_child`, `arena_stats`, `arena_global`, `arena_pool`, `collections`, `json`, `file`, `os`, `builtins`, `crypto`, `selfhost`, `energy`, `ledger` |
| Network | `http`, `kynx`, `pulse` |
| Database | `database`, `auth` |

Two builds use the same sources:

- **Unity.** `runtime.h` includes every `<m>.c` into the program's translation
  unit. `ORBIT_LINK_RUNTIME=0` and the bootstrap use it. Helpers shared between
  modules stay `static` (`ORBIT_XLINK` expands to `static`).
- **Separate.** `scripts/mklib_runtime.py` compiles each `<m>.c` on its own with
  `-DORBIT_RUNTIME_MODULE` (`ORBIT_XLINK` expands to nothing) and writes one
  archive member per module. `ld` takes a member only when a symbol it defines
  is referenced, so a program that never names Kynx does not link the Kynx
  tables, and a program with no network does not import `ws2_32`.

A module header includes the headers of the modules it names, never a `.c`.
Module state lives in the module that owns it: `perf.c` owns the performance
counters and the Kynx lease pointer, `os.c` owns `_orbit_argv`, `ledger.c` owns
the route table, `kynx.c` owns the shard table.

`runtime/orbit_api.h` stays the declaration set a program sees when it is
compiled with `-DORBIT_SEPARATE_COMPILATION`. It is a copy of the interface
and is kept in step by hand.

## Entry rules (C backend)

The generated `main` for a program without routes
(`compiler/emit/c_backend.orb`) is, in order:

1. `_orbit_argv = argv; _orbit_argc = argc;` when the IR calls `orbit_os_argc*`
   or `orbit_os_argv*`. Otherwise `(void)argc; (void)argv;`.
2. `orbit_crash_handler_install();` always.
3. `orbit_console_init();` when the IR calls `print` or `orbit_os_write_std*`.
4. `orbit_db_init(".orbit/data/app.db")` and the model DDL when the module has
   migrations or calls a database builtin.
5. `OrbitArena* arena = orbit_arena_create(131072);`
6. `int code = orbit_main(arena);`
7. `orbit_arena_destroy(arena);` and `return code;`

Removed from this `main`:

- `orbit_ledger_enable_file_dump()`. The ledger records routes, and a program
  without routes has none. The server `main` still calls it.
- `orbit_string_pool_init(2048)` and `orbit_string_pool_cleanup()`. Both are
  empty functions; per-arena pools are created on first use.

The server `main` (`compiler/emit/route_runtime.orb`) calls
`orbit_crash_handler_install()` first and `orbit_console_init()` in place of the
inline console block.

`print` of a string argument is emitted as `orbit_print_string(s)` (the string,
a newline, a flush). Printing an int or a float still uses `printf`.

## Network flags

`compiler/host/pipeline.orb` passes `-DORBIT_WITH_NET` and `-lws2_32` only when
`moduleUsesNetwork` holds: the module has a route, calls the HTTP client or a
request accessor (`orbit_http_client_fetch`, `orbit_http_param_get`,
`orbit_http_body_get`, `orbit_http_query_get`, `orbit_http_query_get_all`,
`orbit_http_header_get`, `orbit_file_upload_save`), or uses the database. A
database program links the network modules because the SQLite progress handler
lives in `kynx.c`.

## What R6 must mirror

R6's `emit_entry_wrapper` currently emits `orbit_arena_create(131072)`,
`orbit_main` and `orbit_arena_destroy`, and references `_orbit_argv` and
`_orbit_argc`. To equal the C backend and link the same members:

1. Reference `_orbit_argv` and `_orbit_argc` only when the module calls
   `orbit_os_argc*` or `orbit_os_argv*`. An unconditional reference links
   `os.o` and, through it, `collections.o` and `advapi32`.
2. Call `orbit_crash_handler_install()` first. Before this change the crash
   diagnostic came from a constructor inside the one-object archive; the
   constructor is gone.
3. Call `orbit_console_init()` when the module calls `print` or
   `orbit_os_write_std*`.
4. Lower `print` of a string to `orbit_print_string(s)`. A `printf` call links
   `__mingw_pformat` (about 30 KB of `.text`).
5. Link `ws2_32` only for a module that uses the network, by the rule above.
6. The DB archive (`libruntime_net_db.a`) must be built with the per-module
   recipe: compile `database.c` and `auth.c` with `-DORBIT_RUNTIME_MODULE
   -DORBIT_WITH_DB -DORBIT_WITH_NET` and add them to the members of
   `mklib_runtime.py`. R6's `scripts/build-runtime-db.py` builds the archive
   from a single translation unit and must change to this.

## Crash handler

The crash diagnostic printed `[ORBIT RUNTIME CRASH] ExceptionCode ... at
address ...` from a constructor placed in every translation unit that included
`runtime.h`. A constructor links its object into every program, so it forced
the whole one-object archive. The diagnostic is kept (it names the exception on
a console that would otherwise show nothing) as module `crash`, installed by an
explicit call from `main`. The unity build keeps the constructor for hand-written
C and the runtime tests, which have no generated `main`.

## Measured

`hello.orb` (`print("hello")`), C backend linked against the archive, no version
resource, `gcc 16.2.0 -O1 -s`, section sizes from `objdump -h`:

| | `.text` | `.rdata` | `.bss` | DLLs besides the CRT |
|---|---|---|---|---|
| One-object archive (`bf38b38`) | 116 352 | 21 592 | 4 892 672 | ADVAPI32, WS2_32 |
| Per-module archive (`cc6b167`) | 13 072 | 3 064 | 8 736 | none |
| Arena split in members | 7 904 | 2 776 | 8 704 | none |
| `int main(void){return 0;}` | 6 400 | 2 488 | 384 | none |

The members linked for `hello` are `arena`, `perf`, `console` and `crash`.
`hello` is 1 504 bytes of `.text` above the 6 400 of the MinGW start-up code.
At `cc6b167` `arena.o` alone was 6 016 bytes of it.

## Arena members

`arena.c` was one member, so a program that created and destroyed one arena
linked checkpoints, child arenas, telemetry, the out-of-memory handler and the
overflow path. `size` on the `.o` files, `.text` bytes:

| Member | `.text` | Defines |
|---|---|---|
| `arena` | 1 144 | `orbit_arena_create`, `orbit_arena_destroy` |
| `arena_alloc` | 3 016 | `orbit_alloc`, `orbit_alloc_try`, `orbit_arena_strdup`, the aborting default |
| `arena_oom` | 856 | `orbit_set_oom_handler`, `orbit_get_oom_handler`, `orbit_request_oom_*` |
| `arena_reset` | 588 | `orbit_arena_reset` |
| `arena_checkpoint` | 224 | `orbit_arena_checkpoint`, `orbit_arena_rewind` |
| `arena_child` | 232 | `orbit_arena_create_child`, `orbit_arena_promote` |
| `arena_stats` | 288 | `orbit_arena_used` and the other telemetry accessors |
| `arena_global` | 180 | `orbit_arena_get_global` |

`arena_internal.h` and `arena_vm.h` are not members. The aborting default
reports through one `WriteFile` (`write` outside Windows) instead of
`fputs`/`fflush(stderr)`, and ends the line in CR LF on Windows as the text-mode
stream did. The per-arena string pool is torn down by inline functions in
`string_pool.h`, so `string_pool.o` is no longer linked. `string_pool.c` is built only in the
unity build, where the tests call `orbit_string_intern`. The object held only
those two functions and the two empty `orbit_string_pool_init`/`_cleanup` stubs, which no
generated program calls and are removed.
