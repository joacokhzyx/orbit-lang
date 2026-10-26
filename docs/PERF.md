# Orbit performance notes

Method, machine, what was changed, and what was deliberately left alone. No
adjectives. Every number in this file ships with the command that produced it,
the machine it ran on, and the spread across runs. A number without those
three things does not belong here.

## How to measure, and what a measurement has to carry

`scripts/kynx_gate.py load` is the load generator: standard library only, TCP
HTTP/1.1 keep-alive, one thread per connection, `perf_counter` latencies.
`--source-ips N` binds connections to distinct `127.0.0.x` sources, so a run
simulates N clients against per-IP admission control. Warmup always uses the
unbound address, which keeps the measurement pool's budgets intact.

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
lines) as the input translation unit.

| Flags | Wall time |
|---|---|
| `-s -O0 -Wall` | 23.8 s |
| `-s -O0` (no `-Wall`) | 4.2 s |
| `-s -O1` (no `-Wall`) | 5.6 s |
| `-s -O2` (no `-Wall`) | 10.1 s |

`-Wall` costs 5.7x on this unit and reports 89 warnings (88
`-Wint-conversion`, 1 `-Wpointer-sign`). The cost is not diagnostic printing:
the analysis that `-Wall` enables is superlinear in emitted size, so the same
flag delta on a 32 KB unit is 0.02 s. Consequences, all in place:

- the bootstrap no longer passes `-Wall`. Set `ORBIT_BOOTSTRAP_WARNINGS=1` to
  restore it when investigating.
- the strict gate is `scripts/werror_gate.py` (`-Werror` on generated C), and
  it runs on every CI push rather than being a local convention.
- `scripts/orbit_ccache.py` makes the repeated compilations of this unit a
  file copy instead of a 24 s compile.

`orbit build compiler/host/main.orb` on the same box: 35 s wall, of which the
compiler's own `cc` child is the large majority.

### Bootstrap on 8 cores (2026-10-26)

Measured on an 8-logical-core Windows box, gcc 16.2.0, `ORBIT_CCACHE=0`,
`compiler/selfhost/stage3.exe.c` (5.9 MB) as the input unit, two runs per row.
The bootstrap builds at `-O1` (`-O0` under `--low-mem`), stops its loop when the
first emission equals the canonical, and shards the compile of the compiler
unit. Each change was measured against the one before it.

| Command | Before | After |
|---|---|---|
| `fp build compiler/host/main.orb` with `ORBIT_SKIP_CC=1`, `-O0` then `-O1` fixed point | 10.3 s, 9.7 s | 2.5 s, 2.1 s |
| `build_selfhost.py --cc gcc --check-stale`, `-O0` then `-O1` | 67.1 s, 60.9 s | 68.2 s, 62.2 s |
| same, loop stops at iteration 1 | 68.2 s, 62.2 s | 42.4 s, 38.5 s |
| same, sharded compile (`ORBIT_SHARD_BUILD=0` against default) | 47.8 s, 50.1 s | 42.0 s, 40.6 s |
| `verify_seed.py --cc gcc`, `-O0` then `-O1` | 96.1 s, 95.0 s | 93.7 s, 89.4 s |
| same, sharded compile (`ORBIT_SHARD_BUILD=0` against default) | 102.7 s, 93.0 s | 79.2 s, 63.6 s |

Rows within one change share a machine state; the rows are not comparable
across changes, because other processes loaded the box differently between
sessions. The `-O1` change leaves the bootstrap itself flat, since gcc takes
longer on the unit by about what the faster emission saves. It pays on every
later compile with the fixed point.

In a scratch copy with `/* perturbed */` appended to the canonical, the same
`build_selfhost.py` command runs both iterations (62.9 s) and reports
`diverged from canonical`.

## User-build optimisation level

`orbit build` shipped `cc -s -O0`, so every user program and the runtime it
links ran unoptimized. The level is now `-O1`, and `orbit build --release`
selects `-O2`. The two are the only levels the compiler chooses, and
`ORBIT_CCFLAGS_EXTRA` is still appended last, so `ORBIT_CCFLAGS_EXTRA=-O0`
(or any other level) overrides either.

`-O1` is the knee. Measured on AMD Ryzen 5 2400G (4 cores / 8 threads, 7.9 GB,
gcc 16.2.0, Windows 10 19045, quiet box) by the 2026-10-15 ladder. The service
is `scratch/W1D/w1d_busy.orb`, with 4 keep-alive connections, 120 requests per
route, and 5 runs per level. The emitted unit was built at each level
(`orbit build`, p50 per route):

| route | `-O0` p50 | `-O1` p50 | `-O2` p50 |
|---|---|---|---|
| `/int` (3M-iteration loop) | 49.4 ms | 15.7 ms | 15.5 ms |
| `/list` (3M list adds) | 102.4 ms | 13.8 ms | 13.5 ms |

`-O1` takes the whole win (3.2x and 7.4x). The `-O1`-to-`-O2` gap is inside
run noise on both routes. Build wall cost, `examples/hello.orb` and
`w1d_busy.orb`, 5 rounds each: `-O0` 2.44 / 2.45 s, `-O1` 4.22 / 4.20 s
(+73 %), `-O2` 6.70 / 6.97 s (+2.5 s more). The trivial route (`/ready`) is
flat at every level: its cost is the access log and Kynx admission, not the
handler. So `-O2` is opt-in for a workload that measured a gain, not the
default, and the strict-aliasing sites `-O2` enables on generated C are why it
is opt-in rather than default.

## The self-host chain, before and after

Same box, same gcc, measured directly. "Before" is the tree at the commit
before this work, in a separate git worktree, with the compile cache disabled.
"After" is the current tree. Every number is a wall-clock median of repeated
runs of the command shown.

| Command | Before | After |
|---|---|---|
| `python scripts/build_selfhost.py --cc gcc --check-stale` | 205 s | 34 s |
| `python scripts/verify_seed.py --cc gcc` (one stress leg) | 285 s | 10 s warm, 27 s cold |
| `stress-gate` job, serial | 205 s + 8 x 285 s = 2485 s | 8 legs in parallel, ~27 s |

The stress job is the headline: it went from roughly 41 minutes of serial work
on this two-core box to about half a minute of wall clock. The eight
repetitions now run as independent CI legs instead of a `for` loop. Each leg is
cheap because the C compilation is cached, and the compiler's own redundant
`cc` no longer runs.

Where the gains came from, in order of size:

1. **The optimiser's temporary-sinking loop** was O(n^2) per call inside a
   256-round driver, and each motion rebuilt the entire instruction list. It is
   now a single O(n) sweep per round using per-function side tables, and
   motions are in-place. `sinkOne` fell from 20.3% to 1.0% of self time, and
   the pass's list traffic from about 64M reads to under 1M.
2. **`variableDefType` rescanned every instruction for every name lookup.**
   One O(n) index per function replaced it: 32.5M list reads became 40.9k. The
   index is the right structure here rather than a memo of the answer, because
   the answer is not a pure function of the instructions - `inferRegisterTypes`
   rewrites register types as it runs.
3. **`-Wall` off the bootstrap** (5.7x on the compiler unit, and 89 warnings
   become 92 after the fixed changes below, so nothing was hidden by dropping
   it).
4. **The compile cache** and the eight stress legs running in parallel.

Remaining cost: the compiler's own `cc` on the 3.9 MB unit is still
the largest single item in `orbit build`, and the fixed point has 0
`-Wint-conversion` warnings since 2026-09-26 (clean-emission, ENGINEERING.md).
The register machine's pointer/int conflation was fixed at the source, and the
suppression flags were removed. `scripts/werror_gate.py` is the guard.

## HTTP request path: what was changed

Recorded from the 0.1 cycle. Machine (AMD Ryzen 5 2400G, 4c/8t, 3.6 GHz, 8 GB,
Windows 10 19045, shared box, medians of repeats), service
`examples/health_service.orb`, route `GET /ready`, load via `night_load.py`.
The instrument that produced the per-component figures has been removed, so the
magnitudes are gone. The findings and their justification are not.

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
That gap between a component win and a user-visible win is the finding
for this cycle, and it is the reason the access log and the generated Kynx
policy path are called out below as the real costs.

## What was deliberately NOT changed

Each of these was tried or analysed and left alone. The reasoning is the
durable part.

- **Kynx repeat-hit fast path** (per-shard last-IP cache, lock-free CAS
  accounting). Measured *slower* both for the hit path and for inserts: at
  `-O0` the probe costs more than the uncontended spinlock it skips. Dropped
  without landing. This is the clearest example in the codebase of a
  plausible-sounding optimisation that loses. It is also why the compile-time
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
  runtime. Fixing them is a codegen change, not a runtime change. The
  per-line `fflush` half of the access-log item was removed in 2026-10. See
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
private counters. `orbit_arena_destroy` folds the last interval of an arena that
will never be reset again. The fold is six atomic read-modify-writes per
request (one increment for `arena_resets`, four adds, one compare-and-swap for
the peak) in place of four stores per allocation. `orbit_ledger_exit` takes the
request's arena as a third argument and publishes `arena_max_bytes` from
`orbit_arena_active_bytes(arena)` and `arena_overflow` from
`orbit_arena_overflowed(arena)`.

What that fixes is not the cost, it is the meaning. Those two ledger columns
came from `runtime/oracle.c`'s prediction table, and nothing in the generated
server ever opened a session, so they were structurally zero.
`oracle_begin_session`, `oracle_end_session` and `oracle_init` had no callers
of their own, and the module is gone.
`tests/doctor/golden/d032_arena_overflow` and its new negative
`d032_silent_without_overflow` pin the measured behaviour, and D032's row in
`docs/DOCTOR.md` now states the narrow condition under which the column can be
non-zero at all.

**The join is exact, and it is deferred by one request per worker.** The gate is
`runtime/test_arena_telemetry.c`: four threads' arenas summed independently and
compared against the aggregate delta, plus a case that proves the fast path
publishes nothing. There is one thing it cannot count, an arena that is never
reset and never destroyed -- in practice the process-wide fallback arena. Since
the arena became the first parameter of every emitted function, a route's helper
is handed the request arena like the route body itself, and generated code no
longer reaches the fallback. The callers left are C that Orbit does not emit,
the runtime helpers handed no arena and the ledger's exit dump.
What the join does change is *when* a total appears. A worker's last interval
publishes at that worker's next request, so `/_pulse`'s `alloc_mb` can trail by
up to one request per worker.
A worker that stops taking requests holds its interval until it exits. The
per-route columns in `/_ledger` are not deferred. They are written by the
request that measures them. Measured end to end (drained, 953 requests, both
arms): identical `arena_max_bytes` for `/tiny` (720), `/k8` (15104) and `/k64`
(129840), `alloc_mb` within 0.07 %, and an undrained pair whose 128 MB gap is
exactly one worker's unfolded interval.

**Cost.** Both arms were compiled from the *same* emitted C, with the shipped
line, at the level a user build defaults to.

```
gcc -s -O1 -Wall harena_service.c -o <arm>.exe -I<runtime> -DORBIT_WITH_NET -lws2_32
```

The arms differ only in `-I`: the old arm is `5dcd957`'s `runtime/` plus a
three-line shim (`(void)arena`) so the new signature links, the new arm is the
branch's. The route is `/tiny`, whose whole request footprint is 720 bytes (a
handful of allocations) against ~97 000 cycles of handler work. That is the
least other work there is to hide per-allocation bookkeeping in, so the most
sensitive configuration available. Eight alternating windows of 150 000
requests at 16 connections, unpaced, `--pre 2000`. Machine: AMD Ryzen 5 2400G
(4c/8t, 3.6 GHz, 8 GB), Windows 10 19045, gcc 16.2.0, box quiet at both ends of
the session (0 foreign compilers, 5 % CPU load). Ratio is new over old:

| instrument | median | new faster | sign test | 95 % CI |
|---|---|---|---|---|
| in-handler cycles/request (`/_pulse`, TSC 3.6 GHz) | 0.9958 | 5/8 | p = 0.73 | [0.982, 1.004] |
| whole-process CPU us/request | 0.9746 | 7/8 | p = 0.07 | [0.939, 0.989] |

**Neither instrument resolves this change.** The cycles instrument straddles
1.0, and it is the primary one -- it is what `/_pulse` publishes. The CPU
instrument's numerator is `GetProcessTimes`', quantised to 15.6 ms, which is
about 0.1 us/request at this `n`. More to the point, its session-to-session
spread is larger than any effect here. Two earlier sessions of the same pair --
both provisional, a compiler was up at one end -- put the same ratio at 1.047
and 0.980, 7 % apart and on both sides of 1.0. A metric that moves that much
between sessions of one change cannot certify a 3 % one. What the mechanism
gives is the ceiling: four stores times a handful of allocations is tens of
stores per request against ~97 000 cycles, below the ~1-2 % this harness
resolves. So the result is that the bookkeeping change is
invisible at this resolution, and neither a win nor a loss may be claimed from
these runs. The fold's own cost is six atomic read-modify-writes, and its
contention exposure is per request on a line eight workers share rather than per
allocation on the same line. If that ever matters it will show up under load,
which the harness's concurrent-client knob can raise (one Python client leaves
eight workers well short of saturated).

## Follow-up (2026-10): the access log's per-line flush

The access-log item above was re-measured and half of it is gone. The run was on
a quiet box (`examples/health_service.orb`, `/ready`, 60 000 requests at 16 conns
unpaced, before/after arms x logs on/off, 6 windows per arm, medians, TSC
3.6 GHz). The emitted log path cost +113 421 cycles ~ +31.5 us per request
inside the handler. Most of it bought nothing. A `fflush(stdout)` per line is a
`WriteFile` syscall with the msvcrt FILE lock held across it, which
eight workers then contend on, and `orbit_color_enabled` paid two `getenv`
calls per request. The probe is memoized (the environment cannot change under
a running server) and the worker loop flushes once per pass under
`#if ORBIT_LOGS_ACTIVE`. Log cost: +113 421 -> +50 555 cycles, ~31.5 -> 14.0
us per request (55 % recovered). Whole-process CPU 29.5 -> 25.4 us per
request -- the difference is blocked syscall and lock time that moved outside
the handler, not CPU that came back. Emitted log bytes are identical. A hard
crash can lose at most the lines of the last pass. The remaining half is the
line's own construction, dominated by the msvcrt `printf` format walk.

## Kynx route-limit live gate

`scripts/kynx_gate.py route-limit` runs three phases against a live server and
is the gate that checks the admission-control path:

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
starts. The server is started by the caller instead.

### The bug this gate caught

The manual response-header fast path (change 3 above) omitted the CRLF after
`Content-Type` whenever extra headers were present, so a 429 went out as
`Content-Type: text/plainRetry-After: 1` with the remaining headers spilling
into the body. The `snprintf` fallback had it right. Unit tests covered header
*storage* and never the *wire bytes*, so the whole suite was green while the
response was malformed.

Both header paths now mirror the fallback, and the gate asserts the status, the
`Retry-After` header and the exact body on the wire. The general lesson is the
one worth keeping: a fast path that is only verified through the same
abstraction as the slow path is unverified.

## Follow-up (2026-10): the arena's hot retention is the request's footprint

`orbit_arena_reset` decommitted every page past a fixed 256 KB watermark, so a
request whose footprint exceeded it paid one `MEM_DECOMMIT` plus a re-commit and
a re-fault of the whole footprint on every request. The 64 MB reservation could
not help: reset throws the committed pages away before the next request can grow
back into them. The watermark is now the footprint the previous request actually
used (`cursor - base`, still on that request's end when reset runs), clamped to
[`ORBIT_ARENA_HOT_RETENTION_LIMIT`, `ORBIT_ARENA_HOT_RETENTION_CEILING`] =
[256 KB, 4 MB]. A request under the floor gets exactly the reset it got before:
the floor is unchanged and the ceiling is what bounds the change.

**Machine.** AMD Ryzen 5 2400G, 4c/8t, 3.6 GHz, Windows 10 19045. The end-to-end
numbers were taken while two other research sessions were running `gcc` bursts on
the same box, so each is a *paired* median over alternating arms, de-biased for
which arm ran first. The de-biasing factor is `sqrt(rA/rB)`, where rA and rB are
the paired ratios with that arm first and with it second. What the de-biasing
cannot remove is measurable, and is measured: see the control.

**Mechanism, cycle counters.** `arenaprobe reset`, one emitted C against the two
runtimes, cycle cost of one `alloc+reset` per request:

| footprint | shipped | this change |
|---|---|---|
| 720 B | 283 | 285 |
| 15 104 B | 1 934 | 1 537 |
| 260 928 B (1 200 B *under* the floor) | 32 906 | 24 972 |
| 2 095 984 B | **5 950 647** | **209 991** |
| 67 109 888 B | 204 786 518 | 204 483 690 |

The 2 MB footprint falls by 96.5 %, and the first reset there shows the whole
mechanism: `committed 2097152 -> 262144` shipped, `2097152 -> 2097152` here.
Every row at or under the floor is unchanged within the probe's own spread (the
two middle rows disagree by 20-25 % run to run while `committed` is identical on
both arms), and so is the 64 MB row. A footprint past the 64 MB reservation takes
the overflow path, which resets *into* a fresh segment, and that is not what this
change touches.

**End to end.** `GET /k1m`, a 2 MB footprint, `ORBIT_WORKERS=1`, 4 connections,
600 requests per run, 11 alternating pairs in each order. Ratios are
second arm / first arm:

| order | pairs agreeing | p50 ratio (median) | rps ratio (median) |
|---|---|---|---|
| shipped first | 11/11 | 0.479 [0.253, 0.890] | 2.007 [1.151, 3.955] |
| this change first | 11/11 | 2.089 [1.802, 2.365] | 0.438 [0.313, 0.666] |

Both orders agree on the sign in every pair. De-biased, the change is **p50
-52 % and rps +114 %** on that route.

**The control, and what it says about the measurement.** `GET /k128` has a
260 928 B footprint, 1 200 B under the floor, so this change cannot reach it:
`keep_size` is the same value on both arms and the probe shows `committed
262144 -> 262144` either way. Measured anyway, it de-biases to +7.5 % rps. That is
the resolution floor of the paired estimator on this box, and it is an order of
magnitude below the effect above, which is the point of running it.

**What it costs.** It is a retention, so it is bounded rather than free, and the
bound is the reason the ceiling exists. Measured with one worker (`curl`, a fresh
connection per request, working-set delta).

| sequence | shipped | this change |
|---|---|---|
| large, large (`/k1m` twice) | +2.12 MB | +2.12 MB |
| large then small (`/k1m`, `/k128`) | +0.38 MB | +2.12 MB |
| small, small (`/k128` twice) | +0.38 MB | +0.37 MB |

On a uniform workload the two policies are identical at rest, because reset runs
*before* a request: a worker that has just served one holds that footprint until
the next arrives under either policy. The cost is in the transition. After a large
request, the small request's reset drops the shipped retention to 256 KB and
leaves this one holding the previous footprint (+2.12 MB against +0.38 MB here).
The resting set can be the previous request's footprint rather than 256 KB
until the next request arrives. That extra is per worker and capped by
`ORBIT_ARENA_HOT_RETENTION_CEILING`, i.e. `workers * 4 MB` worst case. With eight
workers on one 2 MB route -- no transition -- the working set rose +16.3 MB in
**both** arms. That is the figure the research note that proposed this change
reported as +14.1 MB *for this change*. Measured side by side, both arms rise the
same +16.3 MB, and the third row above is where that cost actually appears.

**What it is not.** Retaining pages keeps their bytes, so code that reads a
retained page before writing it now reads the previous request's data instead of
a fresh zero page. The request-serving runtime was audited for that: all 100
`orbit_alloc` call sites either zero the block (`collections.c` map buckets,
`http.c` `OrbitRequest`, `kynx.c` lease) or write it fully before reading it. The
pages under the floor were already unzeroed before this change, so this widens an
existing rule rather than introducing one. `docs/ARENA.md` does not promise zeroed
memory and now says so where it used to pin the constant.

## Follow-up (2026-10): the C cache keyed everything except the headers

`scripts/orbit_ccache.py` keyed a compilation on its argv, its `sources` and the
destination basename. `sources` is the caller's statement of what the compilation
reads, and for the emitted C that statement was incomplete. The emitted C is
compiled with `-I <runtime dir>` and `#include`s the runtime headers, and no
caller listed them. The key therefore survived a header edit and handed back the
artifact the *previous* header produced -- a stale binary, built from truth the
tree no longer contains, reported as a green build. That is the one failure mode
a content cache must not have. It is also why the key now walks the trees its
include flags name, and refuses rather than skips a tree too large to walk: a
missed cache costs one compile, a wrong key ships the wrong artifact.

**The falsifier, both trees, one instrument** (`scratch/ccache/key_probe.py`: an
emitted translation unit that `#include`s a header from `-I runtime`, then that
header changes from `ORBIT_PROBE 0` to `ORBIT_PROBE 1`):

| tree | key before the edit | key after | control: edit a file in `sources` |
|---|---|---|---|
| shipped | `c2359f32…` | `c2359f32…` identical | key changes |
| this change | `7e5a9dbe…` | `141f126e…` | key changes |

The control is what makes the first row a finding instead of a probe that cannot
fail. `orbit_ccache.py self-test` is those assertions as a gate: a `-I` header
edited, a header *appearing* under `-I`, a `-include` file edited, and two
negative controls (identical inputs give an identical key; a leftover output does
not enter the key). It caught a wrong assumption while it was being written --
that the separated, fused and quoted spellings of `-I` would key alike. They do
not and should not (the key is over the argv). What the test now asserts is what
matters, that each spelling still walks the tree it points at, quoted because
`pipeline.orb` emits `-I"<dir>"`.

**Machine.** AMD Ryzen 5 2400G, 4c/8t, 3.6 GHz, Windows 10 Pro 19045, gcc 16.2.0.
The box was otherwise idle (4 % load), so these are plain interleaved arms rather
than the paired estimator the arena entry needed.

**What it buys.** `runtime_c_tests.py` compiles 20 programs whose C and headers do
not change between runs, and now compiles them through the cache. Both arms are
the same tree and the same gate. `ORBIT_CCACHE=0` is the shipped behaviour, since
the shipped gate called `gcc` directly and this is that same call with the cache
disabled. `ORBIT_CCACHE_DIR` pointed at a scratch directory:

```bash
ORBIT_CCACHE=1 python scripts/runtime_c_tests.py   # cached
ORBIT_CCACHE=0 python scripts/runtime_c_tests.py   # as shipped
```

| arm | five runs (s) | median | spread |
|---|---|---|---|
| uncached | 18.72, 19.56, 18.48, 18.47, 19.73 | 18.72 s | 1.26 s |
| cached | 13.56, 12.92, 12.90, 11.56, 13.74 | **12.92 s** | 2.17 s |

Five alternating pairs with the arms in both orders, no overlap between the arms
(the cached maximum is under the uncached minimum), **-5.80 s, ratio 0.690**. The
first cached run is cold and took 19.11 s. It fills the cache and is not part of
the median. Every arm in both orders reported `Finished runtime-c: 20/20 pass`,
which is the correctness half: the cached binaries run.

**What it costs.** The key re-reads both include trees per compilation, 8.5 MB
(`runtime/` 49 files, `runtime/vendor` 4 including the vendored `.dll`/`.lib`).
That is measured at **67.4 ms** per compilation, about 1.3 s of the 12.92 s
above, or 22 % of the saving left on the table deliberately. Narrowing the walk
to header suffixes, or memoising a tree digest on a stat-based staleness signal,
would recover it. Both trade a sound key for a fast one, and the wrong key is
the one failure this cache exists to not have. That is a separate, measurable
change.

## Follow-up (2026-10): the cache's liveness probe was a race

`orbit_ccache.enabled()` proved that the cache directory was usable by writing a
file called `.writable` and deleting it. That is a correct answer to the question
"can this process write here" and a wrong answer to "can this process cache",
because the name was shared. With two callers probing at once, one removes the
name the other is midway through removing -- or, on Windows, removes it while the
other still holds the file open. The loser gets `OSError` and reports no cache
for the rest of its life. Nothing fails. It just silently stops caching, and the
callers that overlap are exactly the ones under a time budget.

The probe is now named after the caller (pid plus a nonce). The probe only has to
prove that *this* process can create and delete a file here, which is a private
question, so it gets a private name.

**The falsifier, both trees, one instrument** (`scratch/ccache/enabled_race.py`:
16 real processes probing one `ORBIT_CCACHE_DIR` at once, 20 rounds. The old tree
is a directory holding the old file, not a memory):

| tree | probes that found a usable cache |
|---|---|
| shipped, shared `.writable` | 308/320 — 12 compilations silently uncached |
| this change, per-caller probe | **320/320** |

`orbit_ccache.py self-test` carries the same assertion as a gate: 80 concurrent
probes from one process must all report a usable cache, and 16 probes must take
16 distinct names. The second is what the first one measures. Asserting only the
outcome would pass on a fix that worked by luck of scheduling.

**Machine.** The same box and toolchain as the entry above.

**What it buys.** No timing is claimed here. This fix is what lets the cache be
used by a *parallel* gate at all, and the gate it was found for -- the suite's
eight-way compile -- carries its own measurement in the entry that wires it. A
probe that reports "no cache" 3.75 % of the time is a cache whose speedup is
30 % smaller and whose cost is a mystery.

## Follow-up (2026-10): the compiler's inner compile now goes through that cache

`scripts/orbit_ccache.py` was wired into `build_selfhost.py` and
`verify_seed.py` only. The compiler forks its own C compiler for every program
it builds (`compiler/host/pipeline.orb`), and that inner compile was uncached.
Every gate that builds a disposable binary recompiled the same emitted C from a
fresh temporary directory, with the same flags, once per test per run.
`scripts/cc_cached.py` is a `cc` wrapper that puts that invocation through the
cache. It needs no compiler change because the compiler already documents
`ORBIT_CC` as a wrapper with arguments and splices the string into its own cc
line.

It is wired in one place, `_common.disposable_test_env`, and only when the
caller **names** the driver -- the `cc=` argument every compiling gate passes.
Without that argument the toolchain is whatever the ambient environment says.
The one caller that relies on it (`test_suite.py`, which passes a no-op
compiler to run without compiling at all) would pay an interpreter start and a
key computation per test for a cache that can never hit. `ORBIT_CC` becomes
`<python> <shim>`, `ORBIT_CC_REAL` and `CC` keep the real driver, and
`ORBIT_CCACHE=0` leaves the environment exactly where it was. `_common`'s
self-test asserts that, and it is a gate, because an escape hatch that only
disables caching but still wraps is not an escape hatch.

**Machine.** AMD Ryzen 5 2400G, 4c/8t, 3.6 GHz, Windows 10 Pro 19045, gcc
16.2.0. The box was **not** idle. A second session ran an 8-hour watcher that
compiles with the same fixed-point binary. `dev.py` re-copies that binary
into `%TEMP%` on every run, so a running image cannot be overwritten -- 6 of the
15 samples below needed a retry on that file lock. Both arms ran under the same
contention, in alternating order, and each round carries its own control.

**What it buys.** `dev.py` owns `TEMP`, the cache directory, the fixed-point
binary and each gate's flags, and target `all` selects the link step for these
two gates, so the measurement is the composition `make all` runs. Arm A is
`ORBIT_CCACHE=0` (the shipped behaviour), arm B is the default. Five rounds,
orders A+B+B and B+A+B alternating, so A-B is read in both directions:

```bash
python scripts/dev.py all --filter suite --cc gcc        # arm B (cache on)
set ORBIT_CCACHE=0 && python scripts/dev.py all --filter suite --cc gcc   # arm A
```

| gate | arm A (no cache) | arm B (warm cache) | A-B |
|---|---|---|---|
| `suite` (71 tests) | 29, 31, 31, 31, 29 -> **31 s** | 8, 10, 7, 6, 6, 6, 7, 10, 6, 7 -> **7 s** | **-24 s** |
| `suite_std` (22 tests) | 17, 16, 16, 16, 16 -> **16 s** | ten runs, 11-12 -> **12 s** | **-4 s** |
| both gates, wall | 46.7, 48.0, 48.5, 47.9, 46.5 -> **47.9 s** | ten runs -> **20.0 s** | **-27.9 s** |

Per round the `suite` difference is +20, +24, +25, +22, +22 s -- the same sign
in all five. The control is the pair of identical B arms inside each round:
2, 1, 0, 3, 1 s, max **3 s**. The effect is 7.5x the instrument's floor, which
is the only reason a number taken under that contention is written down here.

The hits are counted, not assumed: the ten arm-B runs added **0** cache entries
(361 before and after. The ~710 inner compiles were served from keys computed in
earlier runs, which is also what shows the key does not depend on the temporary
directory the C is emitted into). Every run in both arms reported
`Finished suite: 71/71 pass` and `22/22 pass`.

One inner compile, same box, unity build (`tests/suite/arith.orb`, 5 interleaved
runs, scratch probe): plain **3244 ms** -> hit **236 ms**, ratio 0.07. A cold
wrapper run took 3216 ms, so the wrapper's own cost -- one interpreter start
plus the key, which re-reads the 8.5 MB `-I runtime` tree -- is not measurable
above a 3.2 s compile's spread. On a *miss* the wrapper costs the hashing and
nothing else.

**The whole gate suite.** In the `all` composition only two gates can be
touched at all, because `test_suite.py` and `dual_judge.py` are the only callers
of `disposable_test_env` that name a driver. A whole `make all` at HEAD and
twice with the change, same box, same contention:

| | HEAD | with the change |
|---|---|---|
| `all`, gate sum | 174 s | 170 s, 162 s |
| `all`, wall | 131 s | 126 s, 121 s |
| `suite` | 26 s | 8 s, 7 s |
| `suite_std` | 15 s | 13 s, 12 s |
| the 19 gates it cannot reach | 133 s | 149 s, 143 s |
| result | 21/21 | 21/21, 21/21 |

The last two rows need reading with care. The sum of the gates the wrapper cannot
reach is *higher* in both runs with the change, which points at a busier box
rather than at a change. Both runs happened later than the HEAD one, the
second session was still compiling through all of them, and eight of those gates
moved by about a second in both. Nine others (`runtime_c`, `shard_split`,
`verify_seed`, `dispatch`, `parity`, `check_stale`, ...) did not move at all.
`werror` is the one worth naming: 16 s at HEAD, 20 s in both runs with the
change, so it was measured on its own. With the wrapper it took 20 s and 17 s,
without it 19 s, and it added **0** cache entries, so its compilations either hit
or never reach the wrapper. What the aggregate does establish is the thing it is
good for: `all` stays green with the wrapper wired into it, 21 gates then and 23
today, three runs.

A cold cache is the one run that pays without gaining: the hashing is charged
and no entry is reused. On this box that charge is inside the spread of the
compiles it wraps. A wrapper run against an empty cache took 3216 ms against a
plain 3244 ms on the same file, and the entries it fills are what every run
after it reuses. Measured 2026-10-17 on the two gates the wrapper reaches,
adjacent runs in one tree with the cache directory emptied between them.
`suite` took 33 s and `suite_std` 17 s cold, filling 186 entries, 51.8 s wall.
Warm, they took 7 s and 11 s, 19.4 s wall. The cold pair is that plain cost and
not a worse one: the pre-wrapper baseline for `suite` on this box is 26-31 s. So
a compiler change costs one plain run in front of runs that are 4x faster for as
long as the emitted C stays put. `ORBIT_CCACHE=0` is the switch that makes a
run neither pay the charge nor take the gain. CI restores `ORBIT_CCACHE_DIR` at
`$GITHUB_WORKSPACE/.ccache` through `actions/cache`, keyed on the canonical.
CI's warm runs reuse these entries the same way they already reuse the
bootstrap's, and a push that changes `stage3.exe.c` starts it cold again.

**What it costs.** The key cannot see headers reached through the toolchain's
own default search paths. In this repository the emitted C is compiled with
`-I <runtime dir>` and includes only headers from there, which are hashed. The
hole is in the wrapper's general contract, and it is declared in its docstring
rather than left for someone to discover.

One trap worth writing down, because it cost a build to find: the value of
`ORBIT_CC` is spliced into a **shell line**, so it has to be a command line. The
first version quoted the interpreter, and on Windows every gate failed with the
compiler reporting `[ERROR: process exited with code 1]` and `El nombre de
archivo, el nombre de directorio o la sintaxis de la etiqueta del volumen no
son correctos`. That error was cmd.exe reading the first token as a program
named `"C:\...\python.exe"`. Unquoted, the same wiring is fine.

**Correctness.** The cache never invents an artifact: it stores what the real
compiler produced for byte-identical inputs and copies it back. Asserted on a
real suite test through the real wiring. Sha256 of the plain build, the
cache-filling build and the cache hit are the same (`b8b81cff...`). The hit
replaces the deleted artifact and adds no entry, and the built program's exit
status and output are identical in both arms.


