# Changelog

Every entry below comes from the git history - condensed to
one line per change, grouped by what it was for. Nothing here
is reconstructed from memory. (`git log --oneline` tells the
full story; this page tells the short one.)

Versioning rules: [Versioning and Compatibility](VERSIONING.md).
Current: `0.1.0` pre-release (`orbit --version` prints
`orbit 0.1.0`; services still report `0.1.0-rc.2` in `/health`).

## Unreleased (toward 0.1.0)

Language:

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
- `orbit fmt`, `orbit doctor`, and `orbit init` first
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
