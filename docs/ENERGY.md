# Resource and Energy Measurement

Orbit's mission includes reducing the CPU time, memory, and energy required to operate software. This document defines how that goal should be measured. It does not claim an improvement until a comparison has been reproduced under the same conditions.

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

Throughput alone is insufficient. A system that serves more requests but consumes proportionally more power has not demonstrated lower energy per request.

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

Benchmark implementations live under `benchmarks/`. The benchmark README defines how to run the existing workloads. Future reports should add the machine and configuration record required above and should not place unqualified performance claims in the project README.

Energy efficiency remains a project target until a repeatable measurement suite produces evidence across representative workloads and supported platforms.
