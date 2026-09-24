# Changelog

Every entry below comes from the git history - condensed to
one line per change, grouped by what it was for. Nothing here
is reconstructed from memory. (`git log --oneline` tells the
full story; this page tells the short one.)

Versioning rules: [Versioning and Compatibility](VERSIONING.md).
Current: `0.1.0` pre-release (`orbit --version` prints
`orbit 0.1.0`; services still report `0.1.0-rc.2` in `/health`).

## Unreleased (toward 0.1.0)

Content and docs track; no compiler changes:

- Language tour, tutorials (blog API, file server, deploy,
  troubleshooting), and guides (migrations, benchmarks).
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
- Zig-free bootstrap as the primary path; Zig seed tree
  removed; runtime moved to top-level `runtime/`.
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
- Benchmark suite scaffolding (compute + HTTP) across
  Go, Rust, C, C++, Node, Python.
- Native x86-64 backend experiments (lowering, encoder,
  register allocation) - still experimental.
- Repository, CI, installer, and docs foundations
  (CHANGELOG, CONTRIBUTING, status, phases).

## Tags

- `v0.1.0-rc.2`, `v0.1.0-rc.1`, `v0.1-rc.2` - release
  candidates.
- `legacy-zig-seed` - the retired Zig seed lineage,
  historical only.
