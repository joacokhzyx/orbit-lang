# Changelog

Every entry below comes from the git history - condensed to
one line per change, grouped by what it was for. Nothing here
is reconstructed from memory. (`git log --oneline` tells the
full story; this page tells the short one.)

Versioning rules: [Versioning and Compatibility](VERSIONING.md).
Current: `0.1.0` pre-release (`orbit --version` prints
`orbit 0.1.0-rc.2`, and the startup banner says `Orbit 0.1.0`).

## Unreleased (toward 0.1.0)

Language:

- **A program may name its symbols after any C or runtime name.** The C backend
  emits every function, route handler, model, union, enum, constant and variant
  constructor as `o_<name>`, so `fn remainder`, `fn printf` or `model FILE` no
  longer meet `<math.h>`, `<stdio.h>` or the runtime. The libc list, the C type
  list, the `orbit_` prefix refusal and the generated runtime-name table are
  gone. Only a function named like a runtime function the compiler calls itself
  (`orbit_string_slice` for `text.slice(a, b)`) is still refused. Pinned by
  `tests/suite/c_names_user_defined.orb` and `tests/negative/n89_compiler_called_runtime_name.orb`.
- **`int` is 64 bits.** `orbit_int` is `int64_t`, so an `int` runs from
  -9223372036854775808 to 9223372036854775807 and wraps modulo 2^64. Literals
  up to 9223372036854775807 are accepted, and `-9223372036854775808` is the
  spelling of the minimum. The runtime follows: `orbit_int_to_string`,
  `orbit_string_to_int` (now `strtoll`, which saturates instead of being
  undefined), JSON integers (`json: integer out of int64 range`), SQLite
  counts (`sqlite3_column_int64`) and the clocks (`orbit_clock_ns` and
  `orbit_wall_seconds` no longer wrap at 2^31 or 2038). Shifts take a count
  masked to six bits, and `>>` stays arithmetic. Pinned by
  `tests/suite/int_wrap_64.orb` (which replaces `int_wrap_32.orb`) and
  `tests/suite/bitwise_operators.orb`.
- **Division and remainder by zero are a checked trap.** `x / 0` and `x % 0`
  with a divisor that is only known at run time, and `INT_MIN / -1` and
  `INT_MIN % -1`, used to be undefined C (SIGFPE, exit 136, nothing on either
  stream). They now print `orbit: division by zero at <file>:<line>` or
  `orbit: integer overflow in division at <file>:<line>` to stderr and exit 2,
  the status of an out-of-range list index. A constant divisor other than `0`
  and `-1` is emitted as the bare operator and costs nothing. Float division
  keeps IEEE semantics. The IR carries the line as `line` on `div` and `mod`
  and the file as the module's `sourceName`
  ([IR spec 1.5](IR_SPEC.md#15-checked-div-and-mod)). Pinned by
  `tests/suite/division_by_zero.orb`, `remainder_by_zero.orb`,
  `division_int_min_overflow.orb`, `remainder_int_min_overflow.orb` and the
  control `division_checked_values.orb`.
- **An object field read is lowered from the read's declared type.** The getter
  for `o.field` was chosen by scanning the setters in the function the read is
  in (`objectFieldGetter`), so an object built in *another* function
  (`val o = make(); val c: int = o.count`) and a key no literal ever wrote both
  fell back to `orbit_object_get_raw`, which hands back the field's
  `const char*`: a float read came back as its pointer bits and the program
  answered the wrong value while `orbit check` was clean. The builder now
  records the declared type's kind on the read's own instruction
  (`IRInstruction.fieldKind`, alongside `elemKind`) and the backend consults it
  **only when the setter scan answers raw**, so every read the scan already
  pinned keeps its getter and `tests/suite/object_literals.orb` emits
  byte-identical C. Pinned by `tests/suite/object_literal_cross_function.orb`
  and `object_literal_missing_key.orb`; the residuals (an undeclared
  cross-function read, a chained `o.deep.x`) are recorded in
  [Known Limitations](KNOWN_LIMITATIONS.md).
- **A `port` declaration names the port the server binds.** The checker now
  validates the value - an integer literal 1..65535, anything else is the
  new E1008 - and the emitted server binds it; `argv[1]` still overrides at
  run time. Before, the declaration passed `orbit check` with any value at
  all (`port "8080"`, `port 0`, `port nonexistent_fn()`) and the server
  bound 3000 regardless. `orbit start` and `orbit dev` report the declared
  port, and the emitted C is byte-identical for programs that declare none.
  Pinned by `tests/negative/n81`-`n83`, `tests/suite/port_declaration.orb`,
  and a live declared-port plus argv-override probe in
  `scripts/kynx_gate.py`, which is red on the compiler before this change.
- **Bitwise and shift operators**: `&`, `|`, `^`, `<<`, `>>` and `~`, the
  last gap in the arithmetic. Int-only, like the checker says: a non-int
  operand is the uncoded `Semantic error:` `bitwise '&' takes two ints, not
  'string' and 'string'` (pinned by `tests/negative/n79` and `n80`). Values
  were 32-bit two's-complement when written and are 64-bit since `int` is
  (`~0` is `-1`, `-8 >> 1` is `-4`), shift counts are masked to six bits
  (`1 << 65` is `2`, never C's undefined shift), and the precedence is C's grouping (`&` binds looser than `==`,
  so the suite test writes `(12 & 10) != 8` with the parens it needs). `&`
  stays the pointer sigil in type position and `>>` still closes
  `list<list<int>>`; `orbit fmt` tells the two spellings of `&` apart the
  way it already did for unary minus. Pinned by
  `tests/suite/bitwise_operators.orb`, documented under
  [LANGUAGE_REFERENCE](LANGUAGE_REFERENCE.md#bitwise-and-shift-operators).
  The constant folder does not fold the new operators yet. The quarantined
  `std/sys/bytes/bitwise.orb` has since returned (2026-10-18): the operators
  were the missing feature, so what was left was a syntax slip and a test,
  and `tests/std/test_bitwise.orb` now covers the same vectors.
- **Object literals**: `return ok { status: "UP", uptime_seconds: ... }`. A
  real value, not a JSON string builder: read a field off it, nest one in
  another, pass it to a function. Backed by a new `OrbitObject` in
  `runtime/json.c` - an insertion-ordered record carrying its own type tag -
  because a generated struct per literal could not be named in a signature and
  its field lookups would collide with the module-wide model field table.
  Key order is source order, so response bodies and the parity goldens stay
  deterministic, and every string inside is escaped on the way out. Fields may
  be string, int, float, bool or object; a list or map is a compile error
  rather than a stored pointer. Pinned by `tests/suite/object_literals.orb`.
  Not yet: reading a field of an object a function returned, and reading back a
  dashed quoted key.
- **Integer literals**: `0x` hexadecimal (`0xFF`, `0xff`, `0xAbCdEf`) and `_` as a
  digit separator (`1_000_000`). Neither existed: `0xFF` lexed as the integer
  `0` with `xFF` dropped, and `1_000_000` lexed as `1`. Both compiled clean, ran,
  and printed a plausible wrong number, which is the worst failure mode there
  is — a bitmask or a port constant that is silently not the one written.
  Pinned by `tests/suite/integer_literals.orb`.
- A `${...}` hole can hold a string literal again (`${show("}")}`). An ordinary
  string scan stopped at the first quote it met, so the literal ended inside the
  hole; the scanner now steps over the hole while looking for the closing quote.
- A model in a `${...}` hole is now a compile error naming the model. A call
  whose callee names a model is that model's construction and had the type
  `unknown`, which is interpolatable, so `${m}` printed as nothing at all.
- A `model` with a field named `a` failed to build: the generated constructor
  was `orbit_model_M_create(OrbitArena* a, orbit_int a)`, so the arena parameter
  and the field parameter collided. The parameter is now `arena_`.
- The constant folder no longer folds a function that branches or calls
  anything. With integer literals now reaching it as values rather than as
  text, it started evaluating `fact` by walking its instructions and returned
  5 for `fact(5)`. Only straight-line pure bodies fold, which is provably
  sound.
- **String interpolation**: `${…}` inside a string, ordinary or triple-quoted,
  is substituted. Together with raw strings this is what lets a JSON body carry
  real values without escaping: `ok 200 """{"count":${n}}"""`. A hole may hold a
  string, int, float or bool; a model, list, map or `result` is a compile error
  rather than a guess. Braces nest and quotes are tracked, so `${ok("}")}` is
  not read as a hole that ended early. Pinned by
  `tests/suite/interpolation.orb`, documented under
  [LANGUAGE_REFERENCE](LANGUAGE_REFERENCE.md#interpolation).
- `TokType.InterpStringLiteral` was already in the token enum with no producer
  and no consumer, so `${...}` was documented but never built. It is built now.
- `LANGUAGE_REFERENCE.md` claimed object literals (`{ name: "api" }`) and
  field access (`${service.name}`) worked. Neither has ever compiled; the
  section now says so and points at models and raw strings instead.
- `"text: " + 1.5` produced C that the C compiler rejected: a pass that
  propagates `float` through arithmetic also claimed the destination of an
  `add`, and `add` is also string concatenation. A float no longer spreads
  through a concatenation.
- **Raw string literals**, triple-quoted like Python: `"""{"status":"ok"}"""`.
  No escapes are processed, so a JSON body no longer needs every quote doubled
  and a multi-line body can be written the way it is served. The first `"""`
  closes the literal, so a single quote inside is ordinary content; the only
  thing that cannot appear inside is a literal `"""`. Documented in
  [LANGUAGE_REFERENCE](LANGUAGE_REFERENCE.md#strings), pinned by
  `tests/suite/raw_string_literals.orb`.
- `orbit fmt` no longer aborts on a directory, and a C keyword used as a
  function name (`fn inline()`) now compiles: the call site spells the renamed
  symbol the definition uses.
- **A `result` can be bound to a `val` and passed as an argument.** `result` is
  a struct in C and the register machinery carries values as `uintptr_t`, so a
  local holding one was hoisted as that integer slot and the store became the C
  error `aggregate value used where an integer was expected` - `orbit check`
  passed and only the C step failed. Every call the frontend type table does not
  know, which is every call to a user function, was treated as untypable, and
  that verdict discarded the register type the builder had already taken from
  the callee's return type. The type now stands. Pinned by
  `tests/suite/result_binding.orb`.
- A response body the compiler cannot type no longer reaches C as a bare
  register. `ok 200 1 + true` satisfies `checkCompatibility("string",
  "unknown")`, and `orbit_response_json` then took an `orbit_int` where a
  `const char*` belongs: `check` passed, `build` succeeded, and the first
  request segfaulted. A body the backend has settled on as a scalar is now
  converted with the runtime helper for that type, the same one an interpolated
  value uses. A body it has settled on as a string, a pointer, or still unknown
  is passed untouched, so nothing that already worked changed. Pinned by the
  `response_body_unknown_type` probe in `scripts/werror_gate.py`, which the
  pre-fix output fails on `-Werror=int-conversion`.
- A missing C toolchain is no longer confused with a C compiler that rejected
  our output. The test for "the compiler is not installed" was a substring
  search for `not found` over the compiler's own diagnostics, and clang reports
  a missing include as `'socket_compat.h' file not found` - so a build outside
  the repository, where the runtime include path does not resolve, was told to
  set `ORBIT_CC` for a compiler that was installed and working. The wording is
  now matched together with the compiler's own name on the same line, which is
  what a shell prints and no compiler diagnostic does. The genuine case is
  unaffected, wrappers and all. Pinned by `cc-include-failure-is-not-a-missing-
  toolchain` and `cc-absent-names-the-toolchain` in `scripts/cli_probe.py`.

Runtime and generated code:

- **`orbit build` drops functions no entry point reaches.** An import put every
  library function into the C. `compiler/ir/prune.orb` now keeps what `main`, a
  route or an extern reaches. `examples/std_crypto_demo.orb` emits 108 229 ->
  55 756 bytes of C with 32 functions dropped. `build --verbose` prints
  `prune: N unreachable functions dropped`; `--emit-ir` runs before the pass.
  See [Architecture](ARCHITECTURE.md).
- **`orbit build` links the prebuilt runtime archive by default.** The C step
  recompiled the whole runtime unity on every build unless
  `ORBIT_LINK_RUNTIME=1` was set. It now links `libruntime_net.a` when the
  program needs no database and the archive sits beside the runtime directory
  (`lib/` or `.orbit/lib/`) with a `.stamp` that matches the runtime sources;
  otherwise it builds the unity as before, without a message.
  `examples/hello.orb`: 3.4 s to 1.3 s (best of 3, gcc 16.2.0, `ORBIT_CCACHE=0`).
  `ORBIT_LINK_RUNTIME=0` forces the unity build, `=1` forces the link for programs
  without a database and fails on a missing archive, and `ORBIT_RUNTIME_LIB` names the archive.
  `scripts/mklib_runtime.py` writes the stamp, and `scripts/dev.py` and
  `_common.disposable_test_env` default the variable to `0` so no gate changes
  what it builds; `make all` sets `1` for the `suite` and `suite_std` gates. See [Architecture](ARCHITECTURE.md#linking-the-runtime).
- **The Windows wizard and the Linux bundle ship the runtime archive.** The
  release workflow builds `lib/libruntime_net.a` and its `.stamp` with
  `scripts/mklib_runtime.py --cc gcc` from the tagged checkout and places `lib/`
  beside `runtime/` in `Orbit-Setup-<version>.exe` and in
  `orbit-linux-x86_64.tar.gz`, so an installed compiler takes the archive link
  above. The stamp holds the digests of the shipped `runtime/` sources. An
  install without `lib/` builds the unity as before. The Linux job builds
  `examples/hello.orb` from the extracted bundle and requires
  `libruntime_net.a` in the `--verbose` output. On a layout with the wizard's
  files, `orbit build` of `hello.orb` from an unrelated directory took 1.2 s
  linked and 3.0 s after `lib/` was deleted (gcc 16.2.0). The bare binary and
  `scripts/install.*` place no `runtime/`, so they stay on the unity build.
- **User builds are compiled at `-O1`, and `orbit build --release` selects
  `-O2`.** `orbit build` shipped `cc -s -O0`, so every user program and the
  runtime it links ran unoptimized; the flag was never revisited after codegen
  worked. `-O1` is the measured knee: on the scratch service's CPU-bound routes
  (`w1d_busy.orb`, 4 keep-alive connections, 120 requests per route, 5
  alternating runs per level) p50 goes 49.18 -> 15.15 ms on `/int` and
  97.62 -> 13.35 ms on `/list` (3.25x / 7.31x), for +1.9 s of build wall time
  (`examples/hello.orb` 2.36 -> 4.29 s). `-O1` to `-O2` is inside the run spread
  on both routes while costing a further +2.5 s, so `-O2` is opt-in and the
  `-O2` strict-aliasing surface on generated C stays off by default. The
  emitted C is byte-identical at every level (the level is a `cc` flag only),
  so nothing under `tests/parity` moves, and `ORBIT_CCFLAGS_EXTRA` is still
  appended last so it still overrides the level. The bootstrap is untouched:
  `build_selfhost.py` and `verify_seed.py` pinned `-O0` in `SUPPRESS_FLAGS` (since 2026-10-26: `-O1`, `-O0` under `--low-mem`). The
  new default exposed one latent test defect, fixed in the same landing:
  `tests/std/time_ns`'s pure arithmetic loop was folded away by gcc at `-O1`
  and `-O2` (exit 6); its workload now writes through a real list, an effect the
  optimiser cannot see past.
- **The per-request access log is buffered.** The emitted log path paid a
  `fflush(stdout)` per line - a `WriteFile` syscall with the msvcrt FILE lock
  held across it, contended by the eight workers - plus two `getenv` calls
  per request in `orbit_color_enabled`. The probe is memoized (the
  environment cannot change under a running server) and the worker loop
  flushes once per pass under `#if ORBIT_LOGS_ACTIVE`. Measured on
  `examples/health_service.orb` (60 000 requests at 16 conns unpaced,
  before/after x logs on/off, 6 windows per arm): log cost 113 421 -> 50 555
  cycles in-handler (~31.5 -> 14.0 us per logged request, 55 % recovered);
  whole-process CPU 29.5 -> 25.4 us per request. Emitted log bytes are
  identical; a hard crash can lose at most the lines of the last pass. The
  remaining half is the line's own construction, dominated by the `printf`
  format walk.

Content and docs track; no compiler changes:

- Language tour, tutorials (blog API, file server, deploy,
  troubleshooting), and the migrations guide.
- FAQ, known-limitations page, release notes, site copy pack.
- `orbit_full_expansion.orb` rewritten in supported 0.1.0
  syntax (the old file used unparsed planned syntax).
- New runnable examples: `blog_api.orb`, `file_server.orb`.
- Removed 7 unimportable std stubs/shadows (`list`, `map`,
  `terminal`, `FileStream`, `Shimmer`, `Env`, `HttpParser`):
  duplicates of builtins, hardcoded fakes, or unparseable as
  written. Survivors documented under the Wave 0 std contract.
- Honesty notes on `sqlite_notes.orb` (bearer routes,
  `:id` routes, writes) and `catalog_service.orb` (writes).
- ARENA.md and ARCHITECTURE.md now describe the memory system the code
  actually has. Both presented `runtime/arena_pool.c`'s 16-arena pool as the
  mechanism serving requests; the generated server uses it only for startup
  scratch work (`compiler/emit/route_runtime.orb:566`, `:585-587`) while each worker
  owns a private 128 KB arena (`:368-369`), resets it per request (`:485`) and
  destroys it at loop end (`:521`). ARENA.md also described string interning as
  FNV-1a hash lookups over `OrbitStringNode` buckets; `runtime/string_pool.c`
  has neither - it is a flat array scanned with `memcmp` ("Lookups are O(n)
  over the pool") - and the FNV-1a plus open addressing in this runtime belongs
  to `Map<K,V>` (`runtime/collections.c:461`). The same edit records what the
  Arena Oracle is today: its O(1) TLS fast path is live in `runtime/arena.c:327`,
  but nothing in the generated server opens or closes a session and no C test
  exercises it.

## 0.1.0-rc.2 cycle (September 2026)

Developer commands and runtime hardening:

- `orbit run`, `orbit check`, `--help`/`--version` (`feat(dx)`).
- Token-based `orbit fmt` with check mode.
- `orbit doctor`: read-only project checks (D001–D008) with
  optional whitespace fixes.
- Single-host `orbit cluster` v1: up, status, drain, rolling
  restart, down, logs.
- Real `system.*` telemetry builtins (uptime, pid, workers,
  request totals, mean latency).
- Automatic per-route cost ledger (`/_ledger`, `/_ledger/data`).
- Graceful shutdown with drain; honest startup errors.
- Server output flushing so file logs stay live.
- Result `try` propagation and `catch` handlers.
- Docs: brand-voice pass, roadmap and operating guides.

## August 2026 - stabilization

- Behavior suite grown to 13+ programs; suite gate blocking
  in CI again.
- Kynx 0.1: real identity admission, honest Bloom filter
  (negative cache, never authority).
- Runtime fixes: slowloris timeouts, exec opt-in, seed
  credential removed, chunked-encoding 501, strict
  single-placeholder queries, SQL identifier whitelist.
- Parser: nesting limit (E0130), guaranteed forward progress.
- Bootstrap from the committed canonical C as the only path; the
  alternate seed tree removed; runtime moved to top-level `runtime/`.
- 25-probe parity battery versioned; self-host stability
  gate; fixed-point verification; release workflow for the
  fixed-point compiler (Windows + Linux).
- Sovereignty runbook and disaster-recovery docs.

## July 2026 and earlier - bootstrap

- Self-hosted compiler pipeline (lexer → parser → sema →
  IR → C backend) reaching fixed-point convergence.
- C bootstrap amalgamation and seed verification.
- HTTP runtime, arena allocation, SQLite integration,
  JWT/crypto groundwork.
- `orbit fmt`, `orbit doctor`, and an `orbit init` sketch (later removed;
  0.1.0 has no `init` subcommand) first
  implementations; VS Code extension and syntax grammar.
- Native x86-64 backend experiments (lowering, encoder,
  register allocation) - still experimental.
- Repository, CI, installer, and docs foundations
  (CHANGELOG, CONTRIBUTING, status, phases).

## Tags

- `v0.1.0-rc.2`, `v0.1.0-rc.1`, `v0.1-rc.2` - release
  candidates.
- `legacy-seed` - the retired alternate seed lineage,
  historical only.
