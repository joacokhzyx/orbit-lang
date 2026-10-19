# Shard layout: how the single-TU emission splits into linkable shards

Status: the S1 emitter step is done. The compiler emits external linkage
plus a common header. No driver splits yet. This file is the contract the
build driver step implements against. Background and measurements: prototype
report (local scratch, not in repo), whose E1/E2 rule out byte-`cat`
sharding on the old emission.

## 1. Why not `cat`

Two measured blockers, both resolved by the emission change in this commit:

- Declarations cannot stay in slices: slices need a shared header, so
  `cat(shards) == canonical` byte-for-byte is impossible by construction.
- `static` crosses shards: every generated function now has external
  linkage (route/main functions always had it). The 98 `static inline`
  helpers keep internal linkage and live in the header instead.

The standing invariant is functional, not textual: the linked shards
must re-emit byte-identical C (SHA check, §5 R10c).

## 2. Artifacts and canonical order

For a program whose intermediate C is `<base>.c`:

| Artifact | Producer | Content |
|---|---|---|
| `<base>.c` | `generateC` | single TU, unchanged form, external linkage |
| `<base>.h` | `generateCHeader`, written next to the `.c` by the pipeline | §3 |
| `<base>.shard0.c` … `<base>.shard7.c` | driver (not yet) | §4, in TU order shard0 → shard7 |
| `<base>.shards.tsv` | driver | `shard\tfunc\tdefstart_line\tend_line`, 1-based, TU order |

N = 8 shards. Header guard is `ORBIT_SHARD_COMMON_H`.

## 3. Header section order (exact, as emitted)

1. `#ifndef` / `#define` guard.
2. `#define ORBIT_CUSTOM_ROUTER`, `#include "socket_compat.h"`,
   `#include "runtime.h"`, `#include <signal.h>`. No `.c` include:
   `thread_pool.c` holds definitions and is carried once by shard0 (§4 R5).
3. `extern OrbitArena* arena;`, `extern char** _orbit_argv;`,
   `extern int _orbit_argc;` (the two `main` uses. Without them the `main`
   shard would not compile), `#ifdef _WIN32` `void __main(void);`
   `#endif` (declarations. Shard0 defines the arena and `__main`).
4. Baked router flags `#define ORBIT_LOGS_ACTIVE X` /
   `#define ORBIT_KYNX_ACTIVE X` (same env read as the TU body, §4 R7).
5. Global `#define`s (top-level `val`/`const`) + the three
   `#ifndef`-guarded fallback defines.
6. `generateRouteTypeDecls` output verbatim: model/union forward
   typedefs, enums, unions, aliases, model structs with their `#define`
   constructors and `static inline` bodies.
7. `variantBlockText` verbatim when the TU has it (programs without
   routes that construct variants).
8. `functionProto` per module function, in order (external linkage).
9. Synthesized protos, in this order: model constructors
   (`static inline`, same signature fn as the definitions), variant
   helpers (only with §3.7), preamble helpers, router helpers
   (including `orbitLogFmtProto`), server helpers (routes only), `main`,
   and `orbit_main` (only when the module defines no `main`).
10. `orbitLogFmtText` wrapped in `#if ORBIT_LOGS_ACTIVE` (same guard as
    TU). It sits after every prototype it can call. Nothing else in the
    header calls it.
11. `#endif /* ORBIT_SHARD_COMMON_H */`.

For the selfhost TU this is 947 IR protos + 101 synthesized
(95 model constructors, `orbit_create_variant`, `orbit_val_eq`,
`orbit_log_request_fmt`, `orbit_color_enabled`, `orbit_handle_request`,
`main`) + `__main`, measured.

## 4. Partition rules (driver)

- R1. Parse the TU brace-aware. A definition starts at a column-0 line
  outside `#`/`}`/`/` ending with `{` (name before `(` must not be a
  control word). Its body runs to the first column-0 `}`. Column-0
  `label:`/`case` lines inside bodies are skipped. Header part is
  `[0, first_def)`. Gaps are inter-function text. Tail follows the last
  body. Reference behavior: `CAT IDENTICAL` on verbatim slices.
- R2. Gaps are dropped from shards (the header owns every declaration).
  Blank lines are dropped.
- R3. Bodies whose head starts `static inline ` are dropped from shards
  (the header owns the 98 definitions). The TU keeps them so single-TU
  builds are unchanged.
- R4. A body with enclosing `#if` guards (opener before, closer after)
  is emitted wrapped in its opener/closer lines. Precondition, asserted
  by the driver: no top-level `#else`/`#elif` in the TU (0 in the
  selfhost TU, measured). Wrap lines duplicate the header's copies.
  Coverage must show them as the only extras.
- R5. Shard0 prologue, in order: `#include "<base>.h"`,
  `#include "thread_pool.c"`,
  `#ifdef _WIN32` `void __main(void) {}` `#endif`, then the named
  preamble-helper bodies (`orbit_color_enabled`, plus for route programs
  `orbit_print_kynx_gradient`, `orbit_render_server_banner`,
  `orbit_worker_loop`, `orbit_ctrl_handler`/`orbit_term_handler`,
  `orbit_kynx_register_limits`), then its balanced body group.
  Every other shard starts with `#include "<base>.h"` only.
- R6. Tail goes to the last shard (empty for the selfhost TU, measured).
- R7. Remaining external-linkage bodies are dealt in TU order,
  greedily balanced by body-line count across the 8 shards. Measured
  selfhost split: 18461/18540/20083/19935/18544/18476/18575/14985 body
  lines. The router block (`orbit_log_request_fmt` wrapped,
  `orbit_handle_request` wrapped) lands whole in shard7. The VARIANTS
  inline body never reaches a shard (R3).
- R8. Shard compile flags equal the TU flags plus
  `-DORBIT_SEPARATE_COMPILATION`, `-I runtime`, one `gcc -c` per shard
  in parallel. Link all objects against `libruntime_net.a`
  (`scripts/mklib_runtime.py`, net variant, no DB) plus `-lws2_32` on
  Windows. DB programs stay on the unity build (the lib errors on
  `ORBIT_WITH_DB` by design).
- R9. `ORBIT_WITH_NET` is a `-D` flag, never baked: shards inherit the
  TU's flag set. `ORBIT_LOGS_ACTIVE`/`ORBIT_KYNX_ACTIVE` are baked
  defines, present identically in header (§3.4) and router body.
- R10. Verification, in order. (a) Partition `CAT IDENTICAL` on verbatim
  slices. (b) Coverage: every TU line lands in exactly one shard or the
  header, modulo R2/R3/R5/R8 prologues and R4 wrap lines (`missing=0`,
  extras all guard-wrap). (c) The link succeeds and the linked binary
  re-emits the canonical SHA.

## 5. Region handling (stateful `#if` resolved)

| Region | TU form | Shard treatment |
|---|---|---|
| `AST_VARIANTS_DEFINED` (`#ifndef` + self-`#define` + typedef + 1 inline body + macros + `#endif`) | stateful: defines the macro it tests | header owns the whole block verbatim (§3.7); no shard contains or re-tests it. Resolved by ownership. |
| `ORBIT_WITH_NET` (`#ifdef` … `orbit_log_request_fmt` + `orbit_handle_request` + dispatch … `#endif`) | spans bodies | R4 wrap (2 bodies). Liveness comes from the inherited `-D` flag (R9). |
| `ORBIT_LOGS_ACTIVE` / `ORBIT_KYNX_ACTIVE` (`#if`/`#define`) | values baked at emission | header carries the same baked values (§3.4); re-tests agree. |

## 6. Known limits (stop conditions for the driver lane)

- Route programs: `thread_pool.c` types are visible only in the shard
  that includes it. Until the runtime step splits its declarations,
  every body referencing worker symbols must share shard0 with the
  include. The driver stops with the referencing-body list otherwise.
  Selfhost (no routes) needs none of it. The include still rides shard0
  for uniformity.
- N is fixed at 8. Rebalancing is the driver's call with R10 as gate.
- Locality holds at emission (touch one `.orb` → +6 lines in the TU,
  0.004%, measured): the typical rebuild recompiles the 1–2 shards the
  new bodies land in plus link.

## 7. This lane's measurements

- Emission acceptance: 9 probe programs (plain, model, route, dispatch,
  auth) emit byte-identical C old-vs-new except the mechanical
  `static `-prefix drops (2 lines plain, 14 route, 0 insertions).
- Partition acceptance on the new TU: `CAT IDENTICAL`, 1048 functions
  (98 static inline), wrap set = the same 2 NET bodies as the prototype,
  coverage `missing=0`.
- Gates: `make all` 20/20 green when this work landed. The T3 wiring
  (`shard_split` emits the
  TU with the fp and splits it into the bundle; `verify_seed
  --shards-dir/--manifest` re-splits the canonical, checks partition
  coverage and the PUBLISHED_C equality) reports 1048 bodies, 98
  header-owned, missing=0 extra=0.
- Reuse: the driver records `<base>.header.json` {tu_sha256, header_sha256}
  for every successful split. A later run whose canonical still hashes
  to `tu_sha256` splits the canonical with the stored header and skips the
  ~9 s re-emission (11 s → 1.5 s). The shards themselves are rewritten from
  the canonical every run and re-checked by R10a/b and by verify_seed.
- Warm budget: `make all` 117.9 s wall (gate sum 146 s) on 8 cores. The
  background step (a 20 s soak and 50 process spawns joined at their plan
  slot, 28 s hidden) and `alive_check`'s census pair were pooled. The same
  tree measured 157 s before this work, and 130 s on a pass with ~1 core of
  unrelated load on the box.
