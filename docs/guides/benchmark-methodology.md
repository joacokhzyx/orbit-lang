# Guide: Benchmark Methodology

Measure honestly or don't publish numbers. This guide gives the
reproducible commands for Orbit's current benchmarks, the record
you must keep with every result, and the traps I actually hit
while testing for these docs.

## Rules (non-negotiable)

1. Same workload, same machine, same config - or it's not a
   comparison.
2. Report the median of repeated runs plus the spread. One run
   is an anecdote.
3. Warm up first. My services answer in ~0.1 ms warm and take
   ~1.7 s on a cold first boot (DB create + seed). Mixing the
   two is the easiest way to lie by accident.
4. Throughput alone isn't efficiency. Report CPU time and
   memory next to requests per second.
5. On Windows, report CPU time and memory as proxies and stop
   there. Never convert CPU time to joules with a universal
   factor - processor power depends on hardware, frequency,
   and load. Joules need RAPL on Linux or a meter.
6. Publish bad numbers too. A comparison without the runs that
   went badly is advertising.

## Required record with every result

- Orbit revision + compiler version (`orbit --version`),
  C compiler and flags.
- OS + kernel, CPU model, cores, frequency policy, power mode,
  RAM, background load.
- Service file, worker count, logging on/off, DB or not.
- Workload: payload bytes, connections, duration, warm-up,
  client location (localhost vs network).
- Repetitions, median, spread, discarded runs.
- Power interface, if any (RAPL package reading, wall meter).

Template: "On [machine], Orbit [version] served [N] req/s at
[concurrency] with [payload], median of [R] runs, spread [S].
CPU [C] ms/req, RSS [M] MB. Method: [commands]. Still
measuring energy."

## Reproducible commands

Build the service (Windows shown; swap the exe name on Linux):

```powershell
.\orbit.exe build examples\health_service.orb -o bench_health.exe
.\bench_health.exe 8080
```

Warm it up, then load it. `hey` is the documented load tool
(see Platform Support); install once with
`go install github.com/rakyll/hey@latest`:

```sh
hey -z 30s -c 50 http://127.0.0.1:8080/health
```

CPU + memory on Windows (sample while `hey` runs):

```powershell
Get-Counter '\Process(bench_health)\% Processor Time','\Process(bench_health)\Working Set - Private'
```

CPU + memory on Linux (UNTESTED in this track):

```sh
/usr/bin/time -v ./bench_health 8080 &
pidstat -p <pid> 1
```

Energy on Linux with RAPL (UNTESTED in this track - needs a
machine with the sensor and read access):

```sh
cat /sys/class/powercap/intel-rapl:0/energy_uj   # before and after; delta / requests
```

No RAPL, no meter, no joules. Report "energy: not measured;
CPU time X ms/req as proxy" and move on.

## Read the built-in counters first

Before reaching for external tools, check what the service
already measures:

```sh
curl http://127.0.0.1:8080/metrics
curl http://127.0.0.1:8080/_ledger/data
```

Real output from testing (3 requests in):

```text
{"metrics":{"http_requests_total":3,"latency_avg_us":358,"active_workers":8}}
{"routes":[{"method":"GET","path":"/v1/catalog","req":1,"avg_ms":0.51,"db_share":91}, …]}
```

`latency_avg_us` is a mean over a coarse clock - useful for
smoke checks, not for claims. There is no p50/p99 in 0.1.0.

## Traps I hit

- **Cold vs warm.** First boot seeds the DB (~1.7 s). Start
  the timer after warm-up, always.
- **Two servers, one port.** On Windows the second bind
  doesn't fail loudly. Verify with `netstat` that one process
  owns the port before measuring, or you're load-balancing by
  accident.
- **curl `000` on POST.** A stray `000` line can precede the
  real status on Windows POSTs. Count statuses from the server
  log or the final line, not the first.
- **Benchmark harness needs Zig.** `benchmarks/` builds with
  `zig build bench` and skips languages whose toolchains are
  missing. That's the cross-language suite; the commands above
  are the single-service minimum.

Full metric definitions and the evaluation order live in
[Resource and Energy Measurement](../ENERGY.md). Numbers
without that record don't go in the README.
