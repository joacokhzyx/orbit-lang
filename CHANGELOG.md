# Changelog

All notable changes to Orbit are documented here.  
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Added
- **OSS quality pass**: file-level doc-comment headers (`//!` / `/** */`) across all source files.
- **ARCHITECTURE.md**: full compiler + runtime pipeline diagram.
- **README.md**: expanded with quick-start, repo layout, and build instructions.

### Removed
- Stale binary / debug artifacts (`*.pdb`, `orbit.exe`, `orbit.db`, `repomix-output.xml`).
- Scratch conversion scripts (`convert_icon.py`, etc.) from `scratch/`.

---

## [0.4.0] — 2026-07-12  *(Photon · Terminal · Kynx integration)*

### Added
- **Orbit Photon**: incremental build cache keyed by xxHash of source text.  
  Cache hits skip lexing → codegen and print `[cached]` timing.
- **Orbit Terminal**: ANSI/Unicode-aware compiler output system.  
  Detects `NO_COLOR`, `COLORTERM`, `TERM` and Windows VT support automatically.  
  Graceful fallback to ASCII box-drawing when Unicode is unsupported.
- **Orbit Kynx — Computational Leases**: per-route CPU-cycle and I/O budgets.  
  Routes exceeding their lease are rejected with HTTP 429.  
  Siege mode detects request floods and enters adaptive rate-limiting.
- **Kynx integration in codegen**: `c_backend.zig` now emits lease create/check/release
  calls around every generated route handler.
- **Kynx budget enforcement in HTTP layer**: `orbit_send_response` rejects oversized
  responses before writing to the socket.

### Changed
- `main.zig`: full rewrite as `CompilationSession` + `CompilationProfiler`.
  Flags: `--timings`, `--timings=json`, `--verbose`, `--color`, `--unicode`,
  `--cache/--no-cache`, `--watch`, `--jobs=N`.

---

## [0.3.0] — 2026-06-28  *(Arena v2 — Epoch-based virtual-memory allocator)*

### Added
- **Orbit Arena v2**: replaced bump-allocator-with-chained-blocks with a
  virtual-memory epoch engine (`src/runtime/arena.c`).
  - Reserves large virtual address windows upfront; commits pages on demand.
  - Epoch counter enables O(1) bulk-free of an entire request's allocations.
  - `orbit_arena_epoch_begin` / `orbit_arena_epoch_end` demarcate per-request lifetimes.
  - `arena_pool.c`: thread-local pool of arena instances for concurrency.
- **Orbit Pulse**: high-resolution performance counters, RDTSC-based latency
  histograms, and per-route P50/P95/P99 reporting (`src/runtime/pulse.c`).

### Changed
- HTTP server uses arena pool: one arena per request, returned to pool on completion.
- String pool interning moved to epoch-aware allocation.

---

## [0.2.0] — 2026-04-06  *(Core hardening)*

### Added
- C backend: default return values for non-void generated functions.
- End-to-end compilation validated with `test.orb` and `test_phase2.orb`.

### Changed
- `STATUS.md` established as the single source of technical state.
- CI scripts updated for Windows, Linux, macOS matrix.

### Removed
- Contradictory status documents.

---

## [0.1.0] — 2026-03-15  *(Initial release)*

### Added
- Orbit lexer, parser, semantic analyser, IR builder/optimizer, C code generator.
- Built-in SQLite integration.
- HTTP router with `get`, `post`, `put`, `delete` syntax.
- `rescue` error recovery expressions.
- `orbit.atlas` project configuration.
- Windows installer (Inno Setup) and Linux/macOS shell installer.
