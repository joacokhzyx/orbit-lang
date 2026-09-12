# Orbit HTTP perf notes (night-speed crew)

Method, machine, numbers, and what was not improved. No adjectives;
everything below was measured on this box or is labeled otherwise.

## Method

- Load generator: `scripts/night_load.py` (stdlib only, TCP HTTP/1.1
  keep-alive, per-connection threads, `perf_counter` latencies).
  `--source-ips N` binds connections to distinct `127.0.0.x` sources so
  runs simulate N clients against per-IP admission control. Warmup uses
  the unbound address, keeping the measurement pool's budgets intact.
- Service: `examples/health_service.orb`, route `GET /ready` (static
  JSON), built with the newest prebuilt orbit in `%TEMP%`
  (`orbit_fp9.exe`, 2026-09-12; note: `%TEMP%/repo` does not exist on
  this box, so the newest `orbit*.exe` in `%TEMP%` itself was used).
  `orbit build` compiles the generated C with `gcc -O0 -DORBIT_WITH_NET`
  and `-I runtime` resolved from the build working directory, so service
  rebuilds pick up `runtime/*.c` edits with no bootstrap needed.
- Dispatch micro-bench: single-TU program including the runtime exactly
  like a generated service, same `-O0` flags, wall clock via QPC plus
  RDTSC. 200k iterations per component (40k for the Kynx hit path, which
  must stay under the 50/window limit). Before/after pairs run bracketed
  (A-B-A-B) because this box is shared with other crews' load.
- Correctness gates per fix: `runtime/test_arena.c` (27 tests),
  `runtime/test_http_parse.c`, a 20-case header edge table run against
  old and new parsers, and a 300-case byte-identity check of emitted
  responses vs the old `snprintf` shape.

## Machine

AMD Ryzen 5 2400G (4 cores / 8 threads, 3.6 GHz), 8 GB RAM,
Windows 10 Pro build 19045. Shared box: expect run-to-run noise;
medians of repeats are reported.

## Baseline (pristine tree, prebuilt binary)

Service RSS is 7.4-7.7 MB in every run below.

| Workload | RPS | p50 | p99 | Errors |
|---|---|---|---|---|
| A saturation: 8 conns, 12 s, single IP | 4633 | 0.096 ms | 0.728 ms | 100% (all 429: Kynx bans one IP after ~70 reqs, each 429 closes the connection) |
| B4 healthy: 4 conns, 4 IPs, 240 reqs (x3) | 4751 / 4802 / 4854 | ~0.77 ms | ~1.04 ms | 0% (240/240 200s) |
| B1 latency: 1 conn, 60 reqs | 3998 | 0.210 ms | 0.324 ms | 0% |

Top-5 hot spots on the 200 path (micro-bench, pristine):

| # | Component | Cost | Fixable in this lane? |
|---|---|---|---|
| 1 | `orbit_send_response` total (loopback send syscalls) | ~13-16 us, noisy | Only the header-build slice (~0.44 us snprintf) |
| 2 | Per-request access-log `printf+fflush` (generated code) | ~4.4-5.3 us | No (compiler codegen; needs atlas-honoring logs-off) |
| 3 | Header parse (`orbit_http_parse_request_ex`) | ~0.48-0.53 us | Yes (fix 1 below) |
| 4 | Kynx gate hit (parse+hash+bloom+QPC+lock+scan) | ~0.11-0.13 us | Attempted, dropped (see below) |
| 5 | Arena alloc (~3-4 per request, 4 atomic RMWs each) | ~0.044 us | Yes (fix 2 below) |

(QPC itself is ~0.036 us and fires 3-4x per request; string-intern
hits are ~0.024 us but that path is idle for static routes.)

## Fixes (each: micro gain measured, end-to-end no regression)

1. `runtime/http.c` — single-pass header scan with manual
   Content-Length parse (was: two line walks plus `strtoll`).
   Micro T1 490.8 -> 367.7 ns/op avg (**-25%**, A-B-A-B).
2. `runtime/arena.c` — plain-counter telemetry on the alloc fast path
   (was: four atomic RMWs per alloc; slow paths keep exact atomics;
   same race-tolerant class as the existing min/max updates).
   Micro T2 38.8 -> 12.6 ns/op avg (**-68%**). 5000-alloc counter
   check reads back exact single-threaded.
3. `runtime/http.c` — manual response header build (was: `snprintf`
   per request; single-send combining and `(int)` length truncation
   unchanged, pathological inputs keep the bounded `snprintf` fallback).
   Micro T9 538.9 -> 129.3 ns/op avg (**-76%**).

Final micro table, pristine -> final (same bench, back-to-back):
T1 527.6 -> 352.7 ns/op (-33%); T2 44.0 -> 12.2 (-72%);
T9 639.8 -> 159.1 (-75%); T3b/T5/T6/T7/T8 flat (untouched paths).

End-to-end, pristine -> final (same tool and method):
B4 median RPS 4802 -> 4954 (ranges overlap: 4751-4854 vs 4801-5019);
B1 p50 0.210 -> 0.214 ms; workload A still 100% 429 with the same
thresholds (RPS 4633 -> 4465, within noise). RSS unchanged (7.4-7.7 MB).
Plain reading: the three fixes remove ~0.5 us of CPU per request, which
is not resolvable inside an ~770 us RTT dominated by loopback, the
Python client, worker `select`, and the per-request access log. No
end-to-end regression anywhere; component gains are real and isolated.

## What was NOT improved (tried or analyzed, left alone)

- Kynx repeat-hit fast path (per-shard last-IP cache, lock-free CAS
  accounting): micro T3b went 125 -> 154 ns/op (**+23%**) and inserts
  457 -> 704 ns/op (**+54%**) — at `-O0` the probe costs more than the
  uncontended spinlock it skips. Dropped without committing; `kynx.c`
  is byte-identical to pristine.
- String-pool short-circuit: interning does not run on the static-route
  request path (no `orbit_string_intern` in the dispatch/handler flow),
  so any change there measures zero on every instrument. Untouched.
- DB pragma/sync policy: `database.c` is not compiled into this service
  (`orbit build` passes only `-DORBIT_WITH_NET` for it), so no pragma
  change is measurable here. Deferred to a DB-backed service bench.
- Access-log `printf+fflush` (~4.6 us/req) and the `strstr` header-end
  scan bounds (REVIEW crew T2 box): out of this lane, left for the
  compiler crew (atlas-honoring `logs: disabled`) and REVIEW.

## Coordinator verification (exact commands)

From a clean checkout of this branch (no push/merge done by this crew):

```
orbit_fp9.exe build examples/health_service.orb -o svc.exe
python scripts/night_load.py --port <P> --path /ready --connections 4 \
  --requests 240 --source-ips 4 --warmup 2        # healthy path
python scripts/night_load.py --port <P> --path /ready --connections 8 \
  --duration 12 --warmup 1                        # saturation path
```

(Run each service fresh per measurement; Kynx ban state is in-memory.
Micro-bench sources live outside the repo by lane rule; the recorded
binaries were built with `gcc -O0 -w -DORBIT_WITH_NET -I runtime`.)

## Risks / deferred

- End-to-end numbers on this shared box carry visible noise; the table
  above uses medians and overlapping ranges are called out, not hidden.
- Fast-path arena counters are approximate under contention (documented
  in code); single-threaded accumulation verified exact.
- The `runtime/*.c`-only lane cannot touch the two largest costs
  (access log, Kynx policy/getpeername in generated code); those need
  the compiler lane.
