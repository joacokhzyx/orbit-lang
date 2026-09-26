# Resource and Energy Measurement

Orbit tries to use less CPU time, less memory, and less energy to run software.
This document defines how to measure that. No improvement is claimed until it
has been reproduced under the same conditions.

## What to Measure

A useful evaluation records both service output and resource cost:

| Metric | Meaning |
|---|---|
| Requests per second | Completed requests during a defined workload window |
| CPU time per request | Processor time consumed for one completed request |
| Memory per connection | Additional resident memory attributable to a connection or active request |
| P50/P95/P99 latency | Distribution of request completion time |
| Energy per request | Energy consumed to complete one request, when hardware or a trusted power interface is available |
| Idle and background power | Power consumed by the service when it is waiting or serving no workload |

Throughput alone is not enough. A system that serves more requests while using
proportionally more power has not shown lower energy per request.

## Required Test Record

Every published comparison records:

- source revision and compiler version;
- operating system and kernel version;
- CPU model, core count, frequency policy, and power mode;
- memory capacity and relevant background processes;
- C compiler and optimization flags;
- runtime configuration, worker count, logging, database, and network settings;
- request payload, connection count, duration, warm-up period, and client location;
- number of repetitions, median, spread, and discarded runs;
- power measurement device or operating-system power interface, if used.

The compared implementations must receive the same workload and equivalent
functional requirements. Results from different machines or different request
behaviour are not efficiency comparisons.

## Recommended Evaluation Order

1. Establish functional equivalence and confirm that every implementation
   returns the expected response.
2. Warm up the service until compilation, caches, and connection setup no
   longer dominate the measurement.
3. Measure latency and throughput at several concurrency levels.
4. Measure CPU time and resident memory for the same runs.
5. Measure energy only after the workload and resource measurements are
   stable.
6. Repeat the complete run and publish raw results alongside summaries.

## Interpreting Results

Report at least:

```text
energy per request = total joules / completed requests
CPU time per request = total CPU seconds / completed requests
```

When direct energy measurement is unavailable, report CPU time, memory, and
throughput as resource proxies and label them as proxies. Do not convert CPU
time into energy using a universal factor; processor power depends on hardware,
frequency, utilization, and system state.

A useful comparison reports both absolute and normalized results, for example:

- requests per second at a fixed concurrency;
- joules per 1,000 completed requests;
- peak and steady-state resident memory;
- P99 latency at the same throughput target.

## Repository practice

The instruments that live in this repository are the load generator and the
bootstrap measurement tool, both standard library only so that a measurement
never depends on a package install:

| Tool | Used for |
|---|---|
| `scripts/night_load.py` | keep-alive HTTP load with latency percentiles and per-source-IP control |
| `scripts/measure_selfhost.py` | per-phase wall time, peak RSS and output size of the self-host bootstrap |
| `scripts/demo-ledger-server.c` | a loopback fixture that exercises the cost ledger and the energy sampler |
| `runtime/pulse.c` | the `/_pulse` and `/_pulse/data` telemetry surface |

A report adds the machine and configuration record required above and does not
place unqualified performance claims in the project README.

Energy efficiency stays a target until a repeatable set of runs shows evidence
across representative workloads and supported platforms, including the runs
where the numbers are bad. Those get published too.

## What Orbit meters today

The cost ledger (`/_ledger`, `/_ledger/data`, loopback only) records per-route
requests, mean ms, and DB share from existing cycle counters, plus energy
columns backed by the sampler in `runtime/energy.c`:

| Platform | `energy_source` | `joules_total` / `joules_per_req` | `avg_cycles` |
|---|---|---|---|
| Linux with readable powercap sensor | `rapl-estimate` | route share of attributable package joules (ESTIMATE) | handler cycles, as before |
| Windows, macOS, or Linux without a sensor | `cpu-proxy` | always `0` (never synthesized) | labeled CPU proxy, not energy |

The HTML table has Energy and Source columns. Without a sensor the Energy cell
reads "— (cpu proxy: N cycles/req)" and the in-table note says cycle counters
are a proxy, never converted to joules. With a sensor it reads "X J/req
(est.)" and the note says the split is estimated. The JSON carries the same
`energy_source` per route and at top level, plus an `energy_note`.

## Sampler design (Linux RAPL/powercap)

- At server start (`orbit_http_init`) the sampler probes
  `/sys/class/powercap/intel-rapl:0/energy_uj` (then `:0:0`, then the nested
  `intel-rapl/intel-rapl:0` layout) and reads the sibling
  `max_energy_range_uj` for counter-wrap handling. When no file reads, there is
  no thread and every joule accessor returns `0`.
- With a sensor, one background thread reads `energy_uj` at 1 Hz (it blocks in
  `nanosleep` between reads; no busy loop) and accumulates package microjoules
  with atomic adds. `orbit_http_cleanup` stops and joins it, so the sampler
  lives exactly as long as the server. Both calls are idempotent.
- Idle baseline: the first 5 samples form the baseline only when no request
  completed in that window; `idle_watts` is their mean power. When requests
  arrived first, the box was never observed idle, so the sampler reports gross
  energy (no subtraction) instead of subtracting load as "idle".
- Attribution (ESTIMATE): `attributable = total - idle_watts * uptime`, clamped
  at zero; each route gets `attributable * route_cycles / total_cycles`. Energy
  is not proportional to cycles under turbo, idle, or IO wait, so per-route
  joules are an engineering estimate, documented as such wherever they appear.

## Ledger overhead

The ledger's per-request enter and exit hooks must stay cheap, because they run
on every request. `ORBIT_NO_LEDGER` compiles them to no-ops, so the cost of the
ledger is measurable by difference: build the same request-parse loop twice,
once with the hooks and once without, and report the absolute per-request
delta. The budget is 1000 ns per request, which is under 2% of any request
slower than 50 us. A breach means the ledger change reverts.

A change under test that adds no hot-path instructions will still show a
non-zero delta, because the delta measures the pre-existing enter and exit
cost. Read it as "the ledger costs this much", not as "this change costs this
much". Parse-relative shares are a noisy upper bound only: a small parse loop
jitters run to run, so it is not a valid denominator.

## Findings from the reference Windows box (2026-09-12)

Machine: Windows 10 Pro 19045, AMD Ryzen 5 2400G (4 cores / 8 threads, up to
3.6 GHz), 8 GB RAM, gcc 16.2.0, Python 3.13.11. Power sensor absent, so
everything here was a proxy. RAPL has not been exercised live; the Linux plan
is below. The instrument that produced the original figures has been removed
from the repository, so the magnitudes are gone and the findings are kept.

- **Absence is reported, not guessed.** With no sensor, the ledger reports
  `energy_source cpu-proxy` and `joules_total 0.0`, and idle watts are
  reported as absent rather than as a number. Joule figures are never
  synthesised from cycle counts on a platform with no meter.
- **The ledger counts every request.** Driving `scripts/demo-ledger-server.c`
  with keep-alive traffic, the ledger's per-route request count matched the
  driver's count exactly, with no drift over thousands of requests. The few
  connection resets observed came from the fixture's own keep-alive cap, not
  from ledger code.
- **Ledger overhead is small but not free.** The measured enter/exit delta sat
  in the tens of nanoseconds per request, comfortably inside the 1000 ns
  budget and a vanishing fraction of the end-to-end request time. The
  `ORBIT_NO_LEDGER` control build showed a negative delta, which confirms that
  at this scale noise dominates: treat the figure as an order of magnitude,
  and re-measure on a quiet machine before quoting it.
- **Ledger rendering is not free either.** Fetching the ledger's own data
  endpoint costs orders of magnitude more cycles than a served request, which
  is expected and is why the dashboard is not on any measured path.

## Linux RAPL test plan (not yet run live)

1. On a Linux box with `/sys/class/powercap/intel-rapl:0/energy_uj` readable,
   build the demo server (`cc -O2 -DORBIT_WITH_NET -I runtime`) and run it;
   confirm startup logs the sensor path via `orbit_energy_sensor_path_str()`.
2. Idle 10 s with no traffic, fetch `/_ledger/data`, confirm `energy_source
   rapl-estimate` and note `idle_watts` behavior.
3. Drive a fixed load (for example 2000 keep-alive requests) with
   `scripts/night_load.py`, confirm per-route `joules_total` sums to
   approximately the attributable joules, and confirm `joules_per_req` is
   stable across repeats.
4. Re-run the whole measurement and confirm the per-route figures stay inside
   the spread of the first run; then `kill -9` the server mid-load and confirm
   no sampler thread outlives the process (the thread is joined on the normal
   path; abnormal death is OS-reaped).
5. Report the machine record and the raw ledger JSON alongside any claim.
