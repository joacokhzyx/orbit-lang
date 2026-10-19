# Kynx 0.1 - Admission Control

Kynx is Orbit's in-process admission-control and computational-budget layer.
This document describes measured behavior of what's in `runtime/kynx.c` and wired into every generated server (`compiler/emit/route_runtime.orb`). If behavior and prose disagree, behavior wins and I fix the prose.

---

## What Kynx actually does today

1. **Real client identity.** Every accepted connection resolves its peer via
   `getpeername()` inside the request handler; the IP string feeds the gate.
   There are no anonymous requests under Kynx.
2. **Admission gate on the hot path.** `orbit_kynx_check_route(ip, method, path)`
   runs before any route lease is created (unannotated paths fall back to the
   global `orbit_kynx_check`). Denied clients receive `429 Too Many Requests`
   plus `Retry-After`, a log line, and connection close.
3. **Per-IP sliding enforcement.** Each shard entry tracks a request window
   (`window_ms`) against `rate_limit`; violations raise the suspicion score;
   reaching `ban_threshold` bans the IP for 5 minutes.
4. **Pressure state machine.** Active-lease count selects budgets:
   STABLE / SHAPED / GUARDED / SIEGE (see table below) with hysteresis.
5. **Computational leases.** Every route handler acquires a lease carrying
   deadline / arena cap / DB-query & step budgets; `lease_check_limits`
   enforces response-size and deadline at response time; SQLite progress
   handler spends steps cooperatively. The arena cap is enforced in the
   allocator, and a request that asks for more than the cap is answered at the
   request boundary rather than ending the process (see [Request
   boundary](#request-boundary)).

## Honest design notes

- **Bloom filter = write-only ban index, never authority.** Bans are recorded with
  k=4 double-derived hashes (set on ban, cleared on unban), but nothing reads
  the filter on the hot path: every request must still be counted in the
  authoritative sharded table (otherwise new IPs could never reach the ban
  threshold), so a negative-cache fast path would skip mandatory bookkeeping
  (see the NOTE at `orbit_kynx_check` in `runtime/kynx.c`). The sharded-table
  lookup is the single decision point; the Bloom is maintained as a hook for
  future tooling, not as a gate.
- **Clock:** monotonic nanoseconds (`QPC` / `clock_gettime`), immune to wall jumps.
- **Shards:** 1024 shards x 64 fixed slots, spinlock-guarded; oldest-eviction
  under saturation (telemetry counts saturations).

## Admission states

| State | Active leases | Deadline | Arena cap | DB budget | Action |
|---|---|---|---|---|---|
| STABLE | 0..32 | 500 ms | 16 MB | 10 q / 100K steps | standard |
| SHAPED | 33..128 | 250 ms | 16 MB | 10 q / 50K steps | throttled |
| GUARDED | 129..512 | 100 ms | 2 MB | 3 q / 10K steps | restricted |
| SIEGE | >512 | 50 ms (critical only) | 512 KB | 2 q / 5K steps | non-critical routes rejected |

Thresholds are fractions of `OrbitKynxConfig.pool_size` (SHAPED above pool/16,
GUARDED above pool/4, SIEGE above pool; release at 3/4 of each entry level);
the table shows pool 512 (the server default).
Transitions recomputed on lease create/destroy; upward thresholds >32/>128/>512,
downward <=24/<=96/<=384. `/health`, `/auth`, `/` keep an emergency budget in SIEGE.

## Configuration

```c
OrbitKynxConfig cfg = {
    .pool_size       = ...,  /* shard slot capacity          */
    .rate_limit      = ...,  /* tokens refilled per window   */
    .window_ms       = ...,  /* refill period in ms          */
    .burst           = ...,  /* bucket capacity (0 = rate)   */
    .ban_threshold   = ...,  /* suspicion score to auto-ban  */
    .score_increment = ...,  /* per violation window         */
    .score_decay     = ...,  /* per clean window             */
    .ban_duration_s  = ...,  /* ban lifetime, seconds (0 = 300) */
    .enabled         = 1,
};
orbit_kynx_init(cfg);
```

Every `orbit build` service starts from the same generated defaults
(`compiler/emit/route_runtime.orb`): pool 512, rate 50 per 1000 ms window,
burst 50, ban threshold 200, increment 10, decay 1, ban 300 s. A
per-route `limit` annotation overrides rate/window/burst for that route
only; the global gate keeps the defaults above.

## Runtime API

```c
void             orbit_kynx_init(OrbitKynxConfig config);
bool             orbit_kynx_check(const char* ip_str);
bool             orbit_kynx_check_route(const char* ip_str, const char* method, const char* path);
void             orbit_kynx_register_route_limit(const char* method, const char* path, int rate, int window_ms, int burst);
int              orbit_kynx_last_retry_ms(void);
OrbitKynxLease*  orbit_kynx_lease_create_for_route(const char* path,
                                                   const char* method,
                                                   OrbitArena* arena);
bool             orbit_kynx_lease_check_limits(size_t additional_response_bytes);
void             orbit_kynx_lease_abandon(void);
void             orbit_kynx_lease_destroy(OrbitKynxLease* lease);
double           orbit_kynx_lease_joules(const OrbitKynxLease* lease);
uint64_t         orbit_kynx_lease_cycles(const OrbitKynxLease* lease);
bool             orbit_kynx_is_siege_mode(void);
int              orbit_kynx_get_suspicion(const char* ip_str);
uint64_t         orbit_kynx_get_total_checks(void);
uint64_t         orbit_kynx_get_total_blocked(void);
```

## Request boundary

The arena cap is the one budget a request can exceed on its own, and exceeding
it is answered rather than fatal. `orbit_alloc`'s OOM handler formats the
refusal from the numbers it still has -- the arena, its usage, and the lease's
-- and lands back in the generated router, which abandons the request's lease
with `orbit_kynx_lease_abandon()` so the answer has room in the same arena, then
creates and sends:

```
503 request refused: 18311 bytes refused; arena ... holds 16770848 of 67108864 bytes in 1833 allocations; lease holds 16770112 of 16777216 bytes
```

The boundary lives in the emitted router and not in a helper, because a helper
that called `setjmp` and returned would hand the handler a frame that is already
gone: measured while this was written, the caller's `setjmp` then returns
garbage instead of `1`. The router declares the `jmp_buf`, `orbit_request_oom_arm()`
records where to land, and `orbit_request_oom_disarm()` closes the span once the
request is dispatched. `orbit_request_oom_install()` runs once per worker.

An unarmed exhaustion still aborts -- `orbit_alloc`'s default handler prints the
arena line and exits 3 -- and so does a refusal where the reservation itself is
gone, since an exhausted arena has no room to answer with. That case belongs to
the reservation, not to this boundary.

Before/after and the fixture are in `ENGINEERING.md` §7 row `kynx-lease-abort`;
`python scripts/kynx_gate.py live` and `runtime/test_kynx.c` (T15) pin it.

## Verifying it yourself

```sh
python scripts/build_selfhost.py --cc gcc --out orbit_fp
./orbit_fp build examples/catalog_service.orb -o srv && ./srv # port 3000
python scripts/kynx_gate.py burst                            # burst -> expect 429s
```

`scripts/kynx_gate.py burst` hammers a running server past its configured
`rate_limit` and asserts that Kynx answers 429 once the window budget is spent.
It is manual-only (needs a live server on a chosen port): the same burst
behavior is covered automatically by `scripts/kynx_gate.py route-limit`,
which runs in CI (see `.github/workflows/ci-gate.yml`).

## Per-route limits

Annotated routes carry their own token bucket keyed by (client IP, route):

```orbit
route GET "/heavy" limit 100/min burst 20 { ... }
```

Syntax and units are defined in `docs/LANGUAGE_REFERENCE.md`:
`limit <rate>[/unit]` with optional `burst`; `min` is 60000 ms, `sec`
and `s` are 1000 ms, `ms` is 1 ms, and an omitted unit means a 1000 ms
window. `burst` defaults to `rate` when omitted or zero.

Codegen (`compiler/emit/c_backend.orb` `generateC`,
`compiler/emit/route_runtime.orb` `serverMainText(hasKynxLimits)`): when at
least one route is annotated with rate `> 0`, the compiler emits
`orbit_kynx_register_limits()`, which issues one
`orbit_kynx_register_route_limit(method, path, rate, window_ms, burst)`
call per annotated route. Generated `main` calls it once, right after
`orbit_kynx_init`. Enforcement is a single admission-gate call in
`orbit_handle_request`:
`orbit_kynx_check_route(kynx_ip, req->method, req->path)`, one token per
request; the route handler body does not check again.

Runtime (`runtime/kynx.c`): at most 32 route limits are kept; a 33rd
registration is dropped and counted in `kynx_route_limit_drops`, and
re-registering the same method+path pair is ignored as idempotent. The
method must
match exactly; the path matches `:param` and `{name}` segments (one
segment each) plus a trailing `*`, and compares literally otherwise.
Buckets (1024 slots across 16 lock shards) are per (IP, route) and
separate from the global IP
table; when a shard is full, the oldest entry is evicted. A route deny answers `429`
with `Retry-After` only - it never raises the suspicion score or bans
(see `runtime/test_kynx.c` T10, which asserts suspicion stays 0).
Paths without an annotation fall back to the global gate; an annotated
route that passes its own bucket still passes through the global gate.

## Built-in `/search` lease budget (intentional sample)

`orbit_kynx_lease_create_for_route` carries one hardcoded override: a
route literally named `/search` gets a 250 ms deadline, a 192 KB arena
cap, a 1 MB response cap, and a 4-query / 50K-step DB budget
(`runtime/kynx.c`). No example service uses that path today, so the
override is inert in practice. It stays as a visible sample of what
per-route lease budgets look like until routes can declare their own
budgets; removing it changes no shipped behavior.

## Per-lease energy attribution

Each `OrbitKynxLease` (`runtime/performance.h`) ends with four
attribution fields: `start_cycles` (`orbit_rdtsc()` at creation),
`start_total_cycles` (completed-request cycles at creation),
`start_joules` (attributable package joules at creation), and `joules`
(the attributed ESTIMATE, set at destroy).

`orbit_kynx_lease_create_for_route` snapshots all three baselines and
zeroes `joules`. `orbit_kynx_lease_destroy` sets `joules` to the
package-joule delta over the lease lifetime times the lease's share of
completed-request cycles in that window (own cycles included, so a lone
request gets share 1), clamped to `[0, delta]`. Without a power sensor
every joules accessor reads exactly `0.0` and `orbit_energy_source()`
reports `"cpu-proxy"` - cycles stay a proxy and are never converted to
joules. With a sensor the source is `"rapl-estimate"`.

Read it with `orbit_kynx_lease_joules(lease)` (`0.0` for `NULL`) and
`orbit_kynx_lease_cycles(lease)` (live `orbit_rdtsc()` delta since
creation, `0` for `NULL`). `runtime/test_kynx.c` T11 pins the
sensor-less behavior: `joules` reads exactly `0.0` before and after
destroy.
