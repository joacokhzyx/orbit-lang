# Orbit performance notes

Method, machine, what was changed, and what was deliberately left alone. No
adjectives. Every number in this file ships with the command that produced it,
the machine it ran on, and the spread across runs; a number without those
three things does not belong here.

## How to measure, and what a measurement has to carry

`scripts/kynx_gate.py load` is the load generator: standard library only, TCP
HTTP/1.1 keep-alive, one thread per connection, `perf_counter` latencies.
`--source-ips N` binds connections to distinct `127.0.0.x` sources so a run
simulates N clients against per-IP admission control; warmup always uses the
unbound address, keeping the measurement pool's budgets intact.

`scripts/measure_selfhost.py` samples wall time, peak RSS and output size per
bootstrap phase. `scripts/orbit_ccache.py` is the content-addressed C compile
cache the gates share.

A published result must record: the exact command, the CPU model and core
count, the C compiler and its version, the optimisation flags, and the spread
over at least 5 runs. Comparisons that hide the runs that went badly are
advertising, not engineering.

Measurements that were taken on a machine or with an instrument that no longer
exists are recorded below as *findings* with their reasoning intact and their
magnitudes removed. Re-measure before quoting a figure.

## Compiler self-build cost

Measured on 2026-09-25 on AMD EPYC 7763 (2 cores available to the container,
7.9 GB RAM), gcc 13.3.0, `compiler/selfhost/stage3.exe.c` (3.9 MB, 86,549
lines) as the input translation unit:

| Flags | Wall time |
|---|---|
| `-s -O0 -Wall` | 23.8 s |
| `-s -O0` (no `-Wall`) | 4.2 s |
| `-s -O1` (no `-Wall`) | 5.6 s |
| `-s -O2` (no `-Wall`) | 10.1 s |

`-Wall` costs 5.7x on this unit and surfaces 89 warnings (88
`-Wint-conversion`, 1 `-Wpointer-sign`). The cost is not diagnostic printing:
the analysis that `-Wall` enables is superlinear in emitted size, so the same
flag delta on a 32 KB unit is 0.02 s. Consequences, all in place:

- the bootstrap no longer passes `-Wall`; set `ORBIT_BOOTSTRAP_WARNINGS=1` to
  restore it when investigating;
- the strict gate is `scripts/werror_gate.py` (`-Werror` on generated C), and
  it runs on every CI push rather than being a local convention;
- `scripts/orbit_ccache.py` makes the repeated compilations of this unit a
  file copy instead of a 24 s compile.

`orbit build compiler/main.orb` on the same box: 35 s wall, of which the
compiler's own `cc` child is the large majority.

## User-build optimisation level

`orbit build` shipped `cc -s -O0`, so every user program and the runtime it
links ran unoptimized. The level is now `-O1`, and `orbit build --release`
selects `-O2`; the two are the only levels the compiler chooses, and
`ORBIT_CCFLAGS_EXTRA` is still appended last, so `ORBIT_CCFLAGS_EXTRA=-O0`
(or any other level) overrides either.

`-O1` is the knee. Measured on AMD Ryzen 5 2400G (4 cores / 8 threads, 7.9 GB,
gcc 16.2.0, Windows 10 19045, quiet box) by the 2026-10-15 ladder, service
`scratch/W1D/w1d_busy.orb`, 4 keep-alive connections, 120 requests per route,
5 runs per level, emitted unit built at each level (`orbit build`, p50 per
route):

| route | `-O0` p50 | `-O1` p50 | `-O2` p50 |
|---|---|---|---|
| `/int` (3M-iteration loop) | 49.4 ms | 15.7 ms | 15.5 ms |
| `/list` (3M list adds) | 102.4 ms | 13.8 ms | 13.5 ms |

`-O1` takes the whole win (3.2x and 7.4x); the `-O1`-to-`-O2` gap is inside
run noise on both routes. Build wall cost, `examples/hello.orb` and
`w1d_busy.orb`, 5 rounds each: `-O0` 2.44 / 2.45 s, `-O1` 4.22 / 4.20 s
(+73 %), `-O2` 6.70 / 6.97 s (+2.5 s more). The trivial route (`/ready`) is
flat at every level: its cost is the access log and Kynx admission, not the
handler. So `-O2` is opt-in for a workload that measured a gain, not the
default, and the `-O2` strict-aliasing surface on generated C is why it is
opt-in rather than default.

## The self-host chain, before and after

Same box, same gcc, measured directly. "Before" is the tree at the commit
before this work, in a separate git worktree, with the compile cache disabled;
"after" is the current tree. Every number is a wall-clock median of repeated
runs of the command shown.

| Command | Before | After |
|---|---|---|
| `python scripts/build_selfhost.py --cc gcc --check-stale` | 205 s | 34 s |
| `python scripts/verify_seed.py --cc gcc` (one stress leg) | 285 s | 10 s warm, 27 s cold |
| `stress-gate` job, serial | 205 s + 8 x 285 s = 2485 s | 8 legs in parallel, ~27 s |

The stress job is the headline: it went from roughly 41 minutes of serial work
on this two-core box to about half a minute of wall clock, because the eight
repetitions now run as independent CI legs instead of a `for` loop, and each
leg is cheap because the C compilation is cached and the compiler's own
redundant `cc` no longer runs.

Where the gains came from, in order of size:

1. **The optimiser's temporary-sinking loop** was O(n^2) per call inside a
   256-round driver, and each motion rebuilt the entire instruction list. It is
   now a single O(n) sweep per round using per-function side tables, and
   motions are in-place. `sinkOne` fell from 20.3% to 1.0% of self time, and
   the pass's list traffic from about 64M reads to under 1M.
2. **`variableDefType` rescanned every instruction for every name lookup.**
   One O(n) index per function replaced it: 32.5M list reads became 40.9k. The
   index is the right shape here rather than a memo of the answer, because the
   answer is not a pure function of the instructions - `inferRegisterTypes`
   rewrites register types as it runs.
3. **`-Wall` off the bootstrap** (5.7x on the compiler unit, and 89 warnings
   become 92 after the fixed changes below, so nothing was hidden by dropping
   it).
4. **The compile cache** and the eight stress legs running in parallel.

Remaining cost, honestly: the compiler's own `cc` on the 3.9 MB unit is still
the largest single item in `orbit build`, and the fixed point has 0
`-Wint-conversion` warnings since 2026-09-26 (clean-emission, ENGINEERING.md): the
register machine's pointer/int conflation was fixed at the source, and the
suppression flags were removed. `scripts/werror_gate.py` is the guard.

## HTTP request path: what was changed

Recorded from the 0.1 cycle. Machine (AMD Ryzen 5 2400G, 4c/8t, 3.6 GHz, 8 GB,
Windows 10 19045, shared box, medians of repeats), service
`examples/health_service.orb`, route `GET /ready`, load via `night_load.py`.
The instrument that produced the per-component figures has been removed, so the
magnitudes are gone; the findings and their justification are not.

Three changes landed, each isolated and each re-checked against the arena,
HTTP-parse and header-byte-identity gates:

1. `runtime/http.c`: single-pass header scan with a manual Content-Length
   parse, replacing two line walks plus `strtoll`.
2. `runtime/arena.c`: plain-counter telemetry on the allocation fast path,
   replacing four atomic read-modify-writes per allocation. Slow paths keep
   exact atomics, so this stays in the same race-tolerant class as the
   existing min/max updates. Single-threaded accumulation is exact.
   *(Superseded: the fast path now writes no global at all, and
   `orbit_arena_reset` folds the arena's own counters into the process totals
   once per request. Fewer shared writes than either form, and exact instead
   of race-tolerant. See "Arena telemetry is a fold, and the ledger's memory
   columns are measured" below.)*
3. `runtime/http.c`: manual response-header build, replacing a per-request
   `snprintf`. Single-send behaviour and the `(int)` length truncation are
   unchanged, and pathological inputs keep the bounded `snprintf` fallback.

Component gains were real and isolated. End to end they were not resolvable:
the per-request work removed here is small next to an ~770 us loopback round
trip dominated by the client, worker `select`, and the per-request access log.
There was no end-to-end regression in any run, and service RSS did not move.
That gap between a component win and a user-visible win is the honest headline
for this cycle, and it is the reason the access log and the generated Kynx
policy path are called out below as the real costs.

## What was deliberately NOT changed

Each of these was tried or analysed and left alone. The reasoning is the
durable part.

- **Kynx repeat-hit fast path** (per-shard last-IP cache, lock-free CAS
  accounting). Measured *slower* both for the hit path and for inserts: at
  `-O0` the probe costs more than the uncontended spinlock it skips. Dropped
  without landing. This is the clearest example in the codebase of a
  plausible-sounding optimisation that loses, and it is why the compile-time
  waves in `docs/SUPERLUMINAL.md` are allowed to report a ship decision of
  "not shipped" when a change measures inside its own comparison band.
- **String-pool short-circuit.** Interning does not run on the static-route
  request path, so no change there can show up in a static-route measurement.
  Untouched rather than "optimised" against an instrument that cannot see it.
- **DB pragma and sync policy.** Not compiled into a net-only service, so
  nothing here is measurable against it. Deferred to a database-backed
  service rather than guessed at.
- **Per-request access `printf` in generated code**, and the Kynx
  policy and address lookups in generated code. These are the two largest
  per-request costs and they live in the compiler's output, not in the
  runtime; fixing them is a codegen change, not a runtime change. The
  per-line `fflush` half of the access-log item was removed in 2026-10; see
  the follow-up below.

## Arena telemetry is a fold, and the ledger's memory columns are measured

Item 2 above moved arena telemetry from atomics to plain stores. What replaced
those stores is this: the allocation fast path now writes **no global at all**,
and the arena's own counters are joined into the process totals once per
request.

**What changed.** `OrbitArena` accumulates `alloc_count`, `requested_bytes`,
`aligned_bytes` and its `peak_used` privately (`runtime/arena.c`), and the fast
path updates them with plain arithmetic on the arena it has already
dereferenced. `orbit_arena_reset` -- which the emitted loop calls before every
request -- folds that interval into `orbit_perf_stats`, then re-bases the
private counters; `orbit_arena_destroy` folds the last interval of an arena that
will never be reset again. The fold is six atomic read-modify-writes per
request (one increment for `arena_resets`, four adds, one compare-and-swap for
the peak) in place of four stores per allocation. `orbit_ledger_exit` takes the
request's arena as a third argument and publishes `arena_max_bytes` from
`orbit_arena_active_bytes(arena)` and `arena_overflow` from
`orbit_arena_overflowed(arena)`.

What that fixes is not the cost, it is the meaning: those two ledger columns
came from `runtime/oracle.c`'s prediction table, and nothing in the generated
server ever opened a session (`oracle_begin_session`, `oracle_end_session` and
`oracle_init` had no callers of their own, and the module is gone), so they were
structurally zero.
`tests/doctor/golden/d032_arena_overflow` and its new negative
`d032_silent_without_overflow` pin the measured behaviour, and D032's row in
`docs/DOCTOR.md` now states the narrow condition under which the column can be
non-zero at all.

**The join is exact; it is deferred by one request per worker.** The gate is
`runtime/test_arena_telemetry.c`: four threads' arenas summed independently and
compared against the aggregate delta, plus a case that proves the fast path
publishes nothing. There is one thing it cannot count, an arena that is never
reset and never destroyed -- in practice the process-wide fallback arena, from
which nothing on the request path allocates. What the join does change is *when*
a total appears: a worker's last interval publishes at that worker's next
request, so `/_pulse`'s `alloc_mb` can trail by up to one request per worker,
and a worker that stops taking requests holds its interval until it exits. The
per-route columns in `/_ledger` are not deferred; they are written by the
request that measures them. Measured end to end (drained, 953 requests, both
arms): identical `arena_max_bytes` for `/tiny` (720), `/k8` (15104) and `/k64`
(129840), `alloc_mb` within 0.07 %, and an undrained pair whose 128 MB gap is
exactly one worker's unfolded interval.

**Cost.** Both arms were compiled from the *same* emitted C, with the shipped
line, at the level a user build defaults to:

```
gcc -s -O1 -Wall harena_service.c -o <arm>.exe -I<runtime> -DORBIT_WITH_NET -lws2_32
```

The arms differ only in `-I`: the old arm is `5dcd957`'s `runtime/` plus a
three-line shim (`(void)arena`) so the new signature links, the new arm is the
branch's. The route is `/tiny`, whose whole request footprint is 720 bytes (a
handful of allocations) against ~97 000 cycles of handler work: the least other
work there is to hide per-allocation bookkeeping in, so the most sensitive
configuration available. Eight alternating windows of 150 000 requests at 16
connections, unpaced, `--pre 2000`, on AMD Ryzen 5 2400G (4c/8t, 3.6 GHz, 8 GB),
Windows 10 19045, gcc 16.2.0, box quiet at both ends of the session (0 foreign
compilers, 5 % CPU load). Ratio is new over old:

| instrument | median | new faster | sign test | 95 % CI |
|---|---|---|---|---|
| in-handler cycles/request (`/_pulse`, TSC 3.6 GHz) | 0.9958 | 5/8 | p = 0.73 | [0.982, 1.004] |
| whole-process CPU us/request | 0.9746 | 7/8 | p = 0.07 | [0.939, 0.989] |

**The honest reading is that neither instrument resolves this change.** The
cycles instrument straddles 1.0, and it is the primary one -- it is what
`/_pulse` publishes. The CPU instrument's numerator is `GetProcessTimes`',
quantised to 15.6 ms, which is about 0.1 us/request at this `n`; more to the
point, its session-to-session spread is larger than any effect here. Two earlier
sessions of the same pair -- both provisional, a compiler was up at one end --
put the same ratio at 1.047 and 0.980, 7 % apart and on both sides of 1.0. A
metric that moves that much between sessions of one change cannot certify a 3 %
one. What the mechanism gives is the ceiling: four stores times a handful of
allocations is tens of stores per request against ~97 000 cycles, below the
~1-2 % this harness resolves. So the result is that the bookkeeping change is
invisible at this resolution, and neither a win nor a loss may be claimed from
these runs. The fold's own cost is six atomic read-modify-writes, and its
contention exposure is per request on a line eight workers share rather than per
allocation on the same line; if that ever matters it will show up under load,
which the harness's concurrent-client knob can raise (one Python client leaves
eight workers well short of saturated).

## Follow-up (2026-10): the access log's per-line flush

The access-log item above was re-measured and half of it is gone. On a quiet
box (`examples/health_service.orb`, `/ready`, 60 000 requests at 16 conns
unpaced, before/after arms x logs on/off, 6 windows per arm, medians, TSC
3.6 GHz), the emitted log path cost +113 421 cycles ~ +31.5 us per request
inside the handler, and most of it bought nothing: a `fflush(stdout)` per
line is a `WriteFile` syscall with the msvcrt FILE lock held across it, which
eight workers then contend on, and `orbit_color_enabled` paid two `getenv`
calls per request. The probe is memoized (the environment cannot change under
a running server) and the worker loop flushes once per pass under
`#if ORBIT_LOGS_ACTIVE`. Log cost: +113 421 -> +50 555 cycles, ~31.5 -> 14.0
us per request (55 % recovered); whole-process CPU 29.5 -> 25.4 us per
request -- the difference is blocked syscall and lock time that moved outside
the handler, not CPU that came back. Emitted log bytes are identical; a hard
crash can lose at most the lines of the last pass. The remaining half is the
line's own construction, dominated by the msvcrt `printf` format walk.

## Kynx route-limit live gate

`scripts/kynx_gate.py route-limit` runs three phases against a live server and
is the gate that keeps the admission-control path honest:

| Phase | Expectation |
|---|---|
| A healthy: paced requests on the lightly limited route | every request 2xx, zero errors |
| B burst: 25 rapid sequential GETs on the small bucket | some 200s, at least one 429 carrying `Retry-After`, byte-exact 429 body |
| C no-ban: 5 GETs two seconds after the burst | all 200; a ban would 429 for five minutes |

Phase B deliberately targets the 5-token bucket rather than the 20-token one.
Twenty-five sequential fresh-connection GETs take a fraction of a second
locally, which sits close to the 20-token bucket's refill budget, so on a
loaded runner the burst can outlast the budget and the phase reports zero
denies. Against the 5-token bucket it would have to span seconds to do that,
and the phase logs its elapsed time, so a failure points at the runner rather
than at the timing. Phase B is isolated to the route bucket by construction:
25 requests sit well under the global burst, so any 429 is route-level. The
gate runs `kynx_gate.py load` with `--warmup 0`, because the standard warmup floods
the shared loopback budgets and trips the 429 path before the measurement
starts; the server is started by the caller instead.

### The bug this gate caught

The manual response-header fast path (change 3 above) omitted the CRLF after
`Content-Type` whenever extra headers were present, so a 429 went out as
`Content-Type: text/plainRetry-After: 1` with the remaining headers spilling
into the body. The `snprintf` fallback had it right. Unit tests covered header
*storage* and never the *wire bytes*, so the whole suite was green while the
response was malformed.

Both shapes now mirror the fallback, and the gate asserts the status, the
`Retry-After` header and the exact body on the wire. The general lesson is the
one worth keeping: a fast path that is only verified through the same
abstraction as the slow path is unverified.
