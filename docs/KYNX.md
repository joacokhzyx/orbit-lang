# Kynx 2.0 — Sovereign Admission Control

Kynx is Orbit's in-process admission-control and computational-budget layer.
This document describes **measured behavior** of the implementation shipped in
`runtime/kynx.c` and wired into every generated server (`compiler/route_runtime.orb`).

---

## What Kynx actually does today

1. **Real client identity.** Every accepted connection resolves its peer via
   `getpeername()` inside the request handler; the IP string feeds the gate.
   There are no anonymous requests under Kynx.
2. **Admission gate on the hot path.** `orbit_kynx_check(ip)` runs before any
   route lease is created. Denied clients receive `429 Too Many Requests`,
   a log line, and connection close.
3. **Per-IP sliding enforcement.** Each shard entry tracks a request window
   (`window_ms`) against `rate_limit`; violations raise the suspicion score;
   reaching `ban_threshold` bans the IP for 5 minutes.
4. **Pressure state machine.** Active-lease count selects budgets:
   STABLE / SHAPED / GUARDED / SIEGE (see table below) with hysteresis.
5. **Computational leases.** Every route handler acquires a lease carrying
   deadline / arena cap / DB-query & step budgets; `lease_check_limits`
   enforces response-size and deadline at response time; SQLite progress
   handler spends steps cooperatively.

## Honest design notes

- **Bloom filter = negative cache, never authority.** Bans are recorded with
  k=4 double-derived hashes; *any clear bit* proves "never banned" at O(1).
  All-set only marks an IP *suspect*; the authoritative sharded table decides.
  Innocent hash collisions therefore cannot be blocked (fixes the historical
  single-bit false-positive lockout).
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

Transitions recomputed on lease create/destroy; upward thresholds >32/>128/>512,
downward <=24/<=96/<=384. `/health`, `/auth`, `/` keep an emergency budget in SIEGE.

## Configuration

```c
OrbitKynxConfig cfg = {
    .pool_size       = ...,  /* shard slot capacity          */
    .rate_limit      = ...,  /* requests per window per IP   */
    .window_ms       = ...,  /* sliding window length        */
    .ban_threshold   = ...,  /* suspicion score to auto-ban  */
    .score_increment = ...,  /* per violation                */
    .score_decay     = ...,  /* per clean window             */
    .enabled         = 1,
};
orbit_kynx_init(cfg);
```

## Runtime API

```c
void             orbit_kynx_init(OrbitKynxConfig config);
bool             orbit_kynx_check(const char* ip_str);
OrbitKynxLease*  orbit_kynx_lease_create_for_route(const char* path,
                                                   const char* method,
                                                   OrbitArena* arena);
bool             orbit_kynx_lease_check_limits(size_t additional_response_bytes);
void             orbit_kynx_lease_destroy(OrbitKynxLease* lease);
bool             orbit_kynx_is_siege_mode(void);
```

## Verifying it yourself

```sh
python scripts/build_selfhost.py --cc gcc --out orbit_fp      # Zig-free build
./orbit_fp build examples/catalog_service.orb -o srv && ./srv # port 3000
python scripts/kynx_burst_probe.py                            # burst -> expect 429s
```

`scripts/kynx_burst_probe.py` hammers a running server past its configured
`rate_limit` and asserts that Kynx answers 429 once the window budget is spent.
