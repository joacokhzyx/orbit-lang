# Orbit Professional Benchmarks

Professional benchmark harness for Orbit runtime stress validation before full self-hosting.

## Current Benchmark Scope

- Primary chain validated today: `Zig > C > Orbit`
- Self-hosting chain (`Zig > C > Orbit > Orbit`) is tracked as a separate milestone
- Baseline target app: `benchmarks/targets/http_benchmark.orb`
- Baseline scenario: `benchmarks/scenarios/professional-baseline.json`

## What This Harness Produces

- Per-language run artifacts (`Rust`, `C++`, `Go`) in JSON
- Unified CSV summary
- Stress point estimate by configured failure criteria

## Stress Definition

A concurrency point is marked as stressed when either condition is true:

- `error_rate_pct` > `max_error_rate_pct`
- `latency_ms_p99` > `max_p99_ms`

Default thresholds are in `benchmarks/scenarios/professional-baseline.json`.

## Usage

From `orbit-binary`:

```powershell
powershell -ExecutionPolicy Bypass -File benchmarks/scripts/run_professional_benchmarks.ps1
```

Optional custom scenario:

```powershell
powershell -ExecutionPolicy Bypass -File benchmarks/scripts/run_professional_benchmarks.ps1 -ScenarioPath benchmarks/scenarios/professional-baseline.json
```

## Notes About Isolation

- This host currently has `Rust` and `Zig` available.
- `Go` is required for Go runner execution.
- `g++` is not required because C++ runner is compiled with `zig c++`.
- For full lab-grade isolation, run on a dedicated machine and keep power/network profile fixed.

## Output Layout

Results are written to:

- `benchmarks/results/<timestamp>/rust-c<concurrency>.json`
- `benchmarks/results/<timestamp>/cpp-c<concurrency>.json`
- `benchmarks/results/<timestamp>/go-c<concurrency>.json` (if Go available)
- `benchmarks/results/<timestamp>/summary.csv`
