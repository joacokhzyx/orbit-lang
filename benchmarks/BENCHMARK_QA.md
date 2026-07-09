# Benchmark Discovery Q&A (Professional Pre Self-Hosting)

This Q&A is used before running official Orbit benchmarks.
Fill answers in the "Team Answer" column and keep this file versioned.

## Core Architecture Questions

| # | Question | Why It Matters | Recommended Answer (Current Stage) | Team Answer |
|---|---|---|---|---|
| 1 | What chain are we benchmarking today? `Zig > C > Orbit` or `Zig > C > Orbit > Orbit`? | Defines what is being measured and avoids misleading claims. | **Today:** `Zig > C > Orbit` (Orbit app compiled through C backend and linked by Zig). | |
| 2 | When do we benchmark `Zig > C > Orbit > Orbit`? | Separates pre-self-hosting from self-hosting maturity. | Start only when compiler bootstrap in Orbit is stable and release-gated. | |
| 3 | What is the canonical benchmark target app? | Prevents incomparable runs. | `benchmarks/targets/http_benchmark.orb` + frozen route set. | |
| 4 | What is the SLO to define “stress point”? | Converts raw numbers to pass/fail gates. | Stress point when `error_rate > 1%` or `p99 > 250ms`. | |
| 5 | Which OS/CPU is release baseline? | Performance is hardware dependent. | Pin one baseline host and keep CPU/memory metadata in report. | |

## Environment Isolation Questions

| # | Question | Why It Matters | Recommended Answer (Current Stage) | Team Answer |
|---|---|---|---|---|
| 6 | Are benchmark hosts dedicated and free of background jobs? | Noise invalidates latency tails. | Yes, isolate host and close non-essential processes. | |
| 7 | Is CPU frequency scaling fixed (or documented)? | Turbo/thermal drift changes results. | Lock power plan and capture CPU governor/power profile. | |
| 8 | Is network loopback used for micro-benchmarking? | Removes external network variability. | Yes, localhost for runtime stress characterization. | |
| 9 | Are warmup and cooldown stages mandatory? | Reduces JIT/cache cold-start bias. | Yes, warmup `8s`, measurement `20s` minimum. | |
| 10 | Is every run repeated at least 3 times? | Single run is statistically weak. | Yes, 3-5 repetitions per language/concurrency point. | |

## Tooling Questions (Rust/C++/Go Attack Clients)

| # | Question | Why It Matters | Recommended Answer (Current Stage) | Team Answer |
|---|---|---|---|---|
| 11 | Do all clients use same request pattern and timeout? | Fair cross-language comparison. | Same URL, method, timeout, concurrency ramp for all clients. | |
| 12 | Are keep-alive semantics consistent? | Keep-alive can dominate throughput. | Start with `Connection: close`; add keep-alive phase later. | |
| 13 | Is payload shape fixed and versioned? | Prevents endpoint drift. | Fixed `GET /health` for baseline; add payload tiers separately. | |
| 14 | Are client toolchain versions recorded? | Reproducibility and auditability. | Record compiler/runtime versions per run. | |
| 15 | Are failed runs preserved for debugging? | Avoids survivorship bias. | Yes, save raw JSON for pass and fail runs. | |

## Metrics & Reporting Questions

| # | Question | Why It Matters | Recommended Answer (Current Stage) | Team Answer |
|---|---|---|---|---|
| 16 | Which metrics are mandatory? | Standardization. | requests, success, errors, error_rate, RPS, p50, p90, p99, max latency. | |
| 17 | Do we publish confidence intervals? | Prevents overconfidence in tiny deltas. | Yes, with repeated runs and per-point spread. | |
| 18 | Is stress point reported per language and globally? | Enables practical capacity planning. | Yes, per client language and consolidated Orbit ceiling. | |
| 19 | Is baseline compared against previous commit? | Detects regressions. | Yes, compare to last accepted benchmark baseline. | |
| 20 | Is report signed with commit SHA + date? | Traceability. | Mandatory in every benchmark report. | |

## Governance Questions

| # | Question | Why It Matters | Recommended Answer (Current Stage) | Team Answer |
|---|---|---|---|---|
| 21 | Who approves benchmark scenario changes? | Protects historical comparability. | Compiler lead + runtime lead approval. | |
| 22 | What blocks release if benchmark regresses? | Enforces quality gate. | If stress point drops >10% or p99 worsens >20%, block release. | |
| 23 | Are benchmark scripts versioned with Orbit core? | Keeps tooling aligned with runtime evolution. | Yes, under `benchmarks/` in orbit-binary. | |
| 24 | What is the cadence? | Sustained quality. | Weekly baseline + pre-release mandatory run. | |
| 25 | Is self-hosting benchmark tracked as separate milestone? | Avoids conflating compiler/runtime stages. | Yes, independent KPI board for `Orbit > Orbit` bootstrap maturity. | |
