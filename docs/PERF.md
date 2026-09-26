# Orbit performance notes

Method, machine, what was changed, and what was deliberately left alone. No
adjectives. Every number in this file ships with the command that produced it,
the machine it ran on, and the spread across runs; a number without those
three things does not belong here.

## How to measure, and what a measurement has to carry

`scripts/night_load.py` is the load generator: standard library only, TCP
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
the largest single item in `orbit build`, and the fixed point now has 92
`-Wint-conversion` warnings, all of one kind: the register machine represents
a value as an integer, so unpacking a result (`OrbitResult.value` is `void*`)
emits an integer-from-pointer conversion. That is tracked as STAB-3 and its
root cause is understood; it is not fixed.

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
- **Per-request access `printf`+`fflush` in generated code**, and the Kynx
  policy and address lookups in generated code. These are the two largest
  per-request costs and they live in the compiler's output, not in the
  runtime; fixing them is a codegen change, not a runtime change.

## Kynx route-limit live gate

`scripts/kynx_route_limit_gate.py` runs three phases against a live server and
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
gate runs `night_load.py` with `--warmup 0`, because the standard warmup floods
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
