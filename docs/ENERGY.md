# Resource and Energy Measurement

Orbit tries to use less CPU time, less memory, and less energy to run software. This document defines how to measure that. I don't claim an improvement until it's been reproduced under the same conditions.

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

Throughput alone isn't enough. A system that serves more requests but uses proportionally more power hasn't shown lower energy per request.

## Required Test Record

Every published comparison should record:

- source revision and compiler version;
- operating system and kernel version;
- CPU model, core count, frequency policy, and power mode;
- memory capacity and relevant background processes;
- C compiler and optimization flags;
- runtime configuration, worker count, logging, database, and network settings;
- request payload, connection count, duration, warm-up period, and client location;
- number of repetitions, median, spread, and discarded runs;
- power measurement device or operating-system power interface, if used.

The compared implementations must receive the same workload and equivalent functional requirements. Results from different machines or different request behavior are not direct efficiency comparisons.

## Recommended Evaluation Order

1. Establish functional equivalence and confirm that every implementation returns the expected response.
2. Warm up the service until compilation, caches, and connection setup no longer dominate the measurement.
3. Measure latency and throughput at several concurrency levels.
4. Measure CPU time and resident memory for the same runs.
5. Measure energy only after the workload and resource measurements are stable.
6. Repeat the complete run and publish raw results alongside summaries.

## Interpreting Results

Report at least:

```text
energy per request = total joules / completed requests
CPU time per request = total CPU seconds / completed requests
```

When direct energy measurement is unavailable, report CPU time, memory, and throughput as resource proxies and label them as proxies. Do not convert CPU time into energy using a universal factor; processor power depends on hardware, frequency, utilization, and system state.

A useful comparison reports both absolute and normalized results, for example:

- requests per second at a fixed concurrency;
- joules per 1,000 completed requests;
- peak and steady-state resident memory;
- P99 latency at the same throughput target.

## Repository Practice

Benchmark implementations live under `benchmarks/`. The benchmark README defines how to run the existing workloads. Future reports should add the machine and configuration record required above and shouldn't place unqualified performance claims in the project README.

Energy efficiency stays a target until a repeatable suite shows evidence across representative workloads and supported platforms - including runs where numbers are bad. I publish those too.

## What Orbit meters today

The cost ledger (`/_ledger`, `/_ledger/data`, loopback only) records per-route
requests, mean ms, and DB share from existing cycle counters, plus energy
columns backed by the sampler in `runtime/energy.c`:

| Platform | `energy_source` | `joules_total` / `joules_per_req` | `avg_cycles` |
|---|---|---|---|
| Linux with readable powercap sensor | `rapl-estimate` | route share of attributable package joules (ESTIMATE) | handler cycles, as before |
| Windows, macOS, or Linux without a sensor | `cpu-proxy` | always `0` (never synthesized) | labeled CPU proxy, not energy |

The HTML table has Energy and Source columns. Without a sensor the Energy
cell reads "— (cpu proxy: N cycles/req)" and the in-table note says cycle
counters are a proxy, never converted to joules. With a sensor it reads
"X J/req (est.)" and the note says the split is estimated. The JSON carries
the same `energy_source` per route and top level, plus an `energy_note`.

## Sampler design (Linux RAPL/powercap)

- At server start (`orbit_http_init`) the sampler probes
  `/sys/class/powercap/intel-rapl:0/energy_uj` (then `:0:0`, then the nested
  `intel-rapl/intel-rapl:0` layout) and reads the sibling
  `max_energy_range_uj` for counter-wrap handling. When no file reads, there
  is no thread and every joule accessor returns `0`.
- With a sensor, one background thread reads `energy_uj` at 1 Hz (it blocks
  in `nanosleep` between reads; no busy loop) and accumulates package
  microjoules with atomic adds. `orbit_http_cleanup` stops and joins it, so
  the sampler lives exactly as long as the server. Both calls are idempotent.
- Idle baseline: the first 5 samples form the baseline only when no request
  completed in that window; `idle_watts` is their mean power. When requests
  arrived first, the box was never observed idle, so the sampler reports
  gross energy (no subtraction) instead of subtracting load as "idle".
- Attribution (ESTIMATE): `attributable = total - idle_watts * uptime`,
  clamped at zero; each route gets `attributable * route_cycles /
  total_cycles`. Energy is not proportional to cycles under turbo, idle, or
  IO wait, so per-route joules are an engineering estimate, documented as
  such wherever they appear.

## Baseline files and compare bands

`scripts/bench-energy.py` implements the `ledger --save` workflow:

```sh
python scripts/bench-energy.py save --url http://127.0.0.1:3000/_ledger/data \
    --out baseline.json --rounds 5 --interval 1.0
python scripts/bench-energy.py compare --baseline baseline.json \
    --url http://127.0.0.1:3000/_ledger/data --tolerance 0.10
```

`save` samples the ledger `--rounds` times, records the median, standard
deviation, and variance of `avg_ms`, `avg_cycles`, and `joules_per_req` per
route, and attaches a machine record (OS, CPU, RAM, compiler, git revision,
power-sensor path or its absence). `compare` checks each current median
against `baseline * (1 + tolerance) + floor` (10% default; floors cover
near-zero baselines) and exits 1 on breach. Joule fields are compared only
when both sides are metered; proxy builds compare `avg_cycles` instead and
say so. Exit codes follow the repo convention: 0 ok, 1 clean failure or
breach, 2 usage.

## Ledger overhead gate

`scripts/bench-ledger-overhead.c` plus `bench-energy.py overhead` compile the
same request-parse loop with and without `ORBIT_NO_LEDGER` (which compiles
the enter/exit hooks to no-ops) and report the absolute per-request delta.
The change under test adds no hot-path instructions - the delta measured is
the pre-existing enter/exit cost - and the gate holds when that delta stays
under 1000 ns/req (under 2% of any request slower than 50 us). Parse-relative
shares are reported as a noisy upper bound only: the 350 ns parse micro-loop
jitters run to run, so it is not the gate denominator. A breach means the
ledger change reverts; the numbers below are the current evidence.

## Observed on the reference Windows box (2026-09-12)

Machine: Windows 10 Pro 19045, AMD Ryzen 5 2400G (4 cores / 8 threads, up to
3.6 GHz), 8 GB RAM, gcc 16.2.0, Python 3.13.11. Power sensor: absent, so
everything below is proxy. RAPL was not live-tested here; the Linux plan is
next.

- Idle: `GET /_ledger/data` before load returned one route with `req 0`,
  `joules_total 0.0`, `energy_source cpu-proxy`. Idle watts are not
  measurable on this box; the sampler reports absence instead of a number.
- Per-request proxy (`scripts/demo-ledger-server.c`, keep-alive, 200 warm-up
  + 2000 timed requests): client-observed median 0.125 ms, p95 0.179 ms, max
  0.552 ms. Ledger after load: `GET /hello` req 2199, `avg_cycles` 450
  (prints `avg_ms` 0.00 on the 2.5 GHz basis); `GET /_ledger/data` render
  `avg_cycles` 114084 (~0.04 ms). Request counts matched the driver exactly
  (2199 served, 2199 recorded); 2 connection resets in 2200 requests came
  from the fixture's own 1000-request keep-alive cap, not from ledger code.
- Overhead: ledger enter/exit delta +21 to +52 ns/req (75–190 cycles) across
  runs; `bench-energy.py overhead` verdict HOLD (+42.8 ns < 1000 ns budget).
  That is about 0.03% of the measured 125 us end-to-end median. The
  `ORBIT_NO_LEDGER` control build compiled and ran clean with a negative
  delta, confirming noise dominates at this scale.

## Linux RAPL test plan (not yet run live)

1. On a Linux box with `/sys/class/powercap/intel-rapl:0/energy_uj`
   readable, build the demo server (`cc -O2 -DORBIT_WITH_NET -I .`) and run
   it; confirm startup logs the sensor path via `orbit_energy_sensor_path_str()`.
2. Idle 10 s with no traffic, fetch `/_ledger/data`, confirm
   `energy_source rapl-estimate` and note `idle_watts` behavior.
3. Drive a fixed load (e.g. 2000 keep-alive requests), confirm per-route
   `joules_total` sums to approximately the attributable joules and
   `joules_per_req` is stable across repeats within the compare bands.
4. `save` a baseline, re-run, `compare` - expect HOLD; then kill -9 the
   server mid-load and confirm no sampler thread outlives the process
   (thread is joined on the normal path; abnormal death is OS-reaped).
5. Report the machine record and raw ledger JSON alongside any claim.
