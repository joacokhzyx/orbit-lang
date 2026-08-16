# Benchmarks

This directory contains the Orbit benchmark suite. It measures Orbit against
Go, Rust, C, C++, Node.js, and Python across two categories: raw computation
and HTTP throughput. A standalone HTTP dispatch latency micro-benchmark
(`bench-http-dispatch`) measures the C runtime's per-request parse/dispatch
cost in isolation.

## Prerequisites

| Tool | Required for |
|------|-------------|
| `zig` master | build harness + Orbit |
| `orbit` | in `../zig-out/bin/orbit` after `zig build` |
| `hey` | HTTP load generator |
| `go` | Go benchmarks |
| `rustc` + `cargo` | Rust benchmarks |
| `clang` or `gcc` | C and C++ benchmarks |
| `node` v18+ | Node.js benchmarks |
| `python3` + `uvicorn` | Python benchmarks |

Install `hey`:
```sh
go install github.com/rakyll/hey@latest
```

Install `uvicorn`:
```sh
pip install uvicorn
```

If a tool is not found, that language is skipped and the suite continues.

## Running

```sh
cd benchmarks
zig build bench                          # full suite (compute + http + death)
zig build bench -- --suite compute      # compute only
zig build bench -- --suite http         # http throughput only
zig build bench -- --suite death        # death/stress test only
zig build bench -- --lang go,rust       # filter languages
zig build bench -- --no-color           # disable ANSI output
zig build bench-http-dispatch           # HTTP dispatch latency micro-benchmark
zig build bench-http-dispatch -- --requests=100000 --runs=10   # custom size
```

Results are written to `results/YYYY-MM-DD_HH-MM.json` and
`results/YYYY-MM-DD_HH-MM.md`.

## Methodology

### Compute benchmarks

Each language implements the same four tests in a standalone binary:

| Test | Parameter | What it measures |
|------|-----------|-----------------|
| `fib_recursive` | fib(40) | function call overhead, recursion |
| `fib_iterative` | fib(1,000,000) mod 10^9+7 | tight loop, arithmetic |
| `sieve` | primes up to 2,000,000 | memory access, cache pressure |
| `sum` | sum 1..100,000,000 | raw integer throughput |

Each test runs 3 times. The median wall-clock time is reported. Timer starts
after argument parsing and stops before result formatting — startup cost is
excluded.

Compiled languages use highest optimization:
- Go: `go build` (default)
- Rust: `rustc -C opt-level=3`
- C: `clang -O2` / `gcc -O2`
- C++: `clang++ -O2` / `g++ -O2`

### HTTP benchmarks

Each language implements a minimal HTTP/1.1 server with two endpoints:

```
GET /          → 200  "OK\n"
GET /fib?n=N   → 200  "<fib(N)>\n"  (iterative, mod 10^9+7, N capped at 10^6)
```

Cross-language ranking runs through `zig build bench-http-dynamic`
(`dynamic/run_dynamic_bench.py`). Orbit is built with `cwd=dynamic/` so the
`dynamic/orbit.atlas` config applies — it pins `logs: disabled` + `kynx: disabled`,
which compile the per-request log printf and the Kynx lease path out of the
generated router (`ORBIT_LOGS_ACTIVE 0` / `ORBIT_KYNX_ACTIVE 0`). Without that
config every worker serializes on the CRT stdout lock per request and the
benchmark measures console contention instead of the engine.

Measurement caveat: on a 2-core machine with a local client, end-to-end
throughput is client-limited. Orbit's acceptor distributes sockets 50/50 and
per-request cost is flat with more workers, but a single local client competes
with the worker threads for the same physical cores, so multi-worker scaling is
only observable with >=3 cores or a remote client.

Measurement procedure per language:
1. Start server
2. Wait for TCP bind (poll every 100 ms, timeout 10 s)
3. Warm-up: `hey -n 5000 -c 50` (discarded)
4. Benchmark: `hey -n 100000 -c 100`
5. Record: RPS, p50, p95, p99, error rate
6. Kill server
7. Wait 2 s before next language

Frameworks used:
- Go: `net/http` stdlib
- Rust: `tokio` + `hyper` (no axum/actix)
- C: raw POSIX sockets
- C++: raw POSIX sockets
- Node.js: built-in `http` module
- Python: `uvicorn` + raw ASGI (no starlette/fastapi)

### HTTP dispatch latency micro-benchmark

`bench-http-dispatch` (`benchmarks/http_dispatch_latency.zig`) measures the
per-request cost of the C runtime's HTTP parse/dispatch path —
`orbit_http_parse_request()` in `src/runtime/http.c` — with no network I/O. It
links the C runtime directly through `benchmarks/http_dispatch_latency_shim.c`
(`http.c` plus its arena/string-pool/pulse dependencies) and is always built
in ReleaseFast: latency numbers from Debug builds are not meaningful.

A fixed set of realistic HTTP/1.1 request buffers (GET/POST/PUT/DELETE, query
strings, request bodies) is dispatched repeatedly through the parse API. Each
request is first copied into a fresh scratch buffer, because the parser
NUL-terminates the buffer in place; it is then parsed and its request target
is folded into a checksum so the optimizer cannot elide the work. The arena is
reset after every request to model per-request arena reuse.

Measurement procedure:
1. Calibrate RDTSC cycles-per-ns against the boot clock (~60 ms busy-wait)
2. Warm-up: 10,000 requests (discarded)
3. 20 measured runs of 200,000 requests each; the median run time is reported
4. Per-request RDTSC samples (the same clock the runtime's `orbit_rdtsc()`
   uses, in `src/runtime/performance.h`) are collected and converted to ns for
   p50/p95/p99

Reported: requests/sec, average latency per request, p50/p95/p99 latency in
ns, and a dispatch checksum for reproducibility.

How to interpret: these numbers are a single-core, in-memory upper bound on
dispatch throughput. The full dispatch hook `orbit_handle_request()` in
`http.c` requires a connected client socket, so the micro-benchmark measures
the network-free parse/dispatch path that bounds end-to-end latency.
End-to-end HTTP latency (the `http` suite above) is always higher because it
includes the network stack, sockets, and concurrency.

### Death / stress test

Tests how long each server sustains load before first errors appear.

Procedure:
1. Start server
2. Run 5-second hey windows at 500 concurrency, loop for up to 60 seconds:
   `hey -z 5s -c 500`
3. After each window: record RPS and error rate
4. Stop when error rate exceeds 1% for two consecutive windows, or when
   server process exits
5. Record: time-to-first-error, peak RPS, final RPS, total requests served

### Fairness rules

- All servers run as single processes (no clustering, no `pm2 -i max`)
- No pre-allocated connection pools or pre-forked workers
- Each server binds a distinct port; no port reuse between runs
- System is idle during measurement (no other load generators)
- All binaries compiled fresh before each run
- Orbit is measured twice: C backend (→ C → cc) and Native backend
  (→ COFF/ELF → internal linker)

## Understanding results

Orbit is pre-release software. The purpose of this benchmark is to establish
a reproducible baseline for tracking compiler and runtime improvements over
time, not to claim performance equivalence with mature runtimes.

Orbit C Target performance is bounded by the C compiler it targets. Orbit Native
performance reflects the quality of the x86-64 code emitter, which is in
active development.
