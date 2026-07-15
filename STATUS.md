# Orbit status — 0.1.0-rc.2

This document describes what is supported in this release candidate. “Supported”
means the feature is intended for use through `orbit` and the C backend; it does
not mean that the language has reached a stable 1.0 compatibility guarantee.

## Supported compilation path

| Area | Status | Notes |
| --- | --- | --- |
| `orbit` | Supported | Public compiler command and default backend. |
| C generation and system linking | Supported | Requires a working C toolchain provided by Zig. |
| Windows x86-64 | Supported target | Built and tested by the current bootstrap workflow. |
| Linux x86-64 | Supported target | ELF output is part of the supported C-backend path. |
| HTTP routes and runtime | Available | Route handlers, response helpers, and Kynx runtime protection are included. |
| SQLite runtime | Available | SQLite is bundled through the runtime; validate schemas and migrations in your service. |
| Self-hosting bootstrap | Available | Stage verification is provided by `orbit bootstrap`. |

## Early or unsupported

| Area | Status | Notes |
| --- | --- | --- |
| Native x86-64 backend | **Very early — unsupported** | It may reject valid programs, lack features, or emit incorrect binaries. It is intentionally not advertised in the CLI. |
| Direct internal linker | **Very early — unsupported** | Not a deployment option for this release. |
| Non-x86-64 targets | Unsupported | No compatibility commitment. |
| Stable language/API compatibility | Not yet available | Syntax, standard library and generated output may change before 1.0. |

## Deployment guidance

Use `orbit build` in CI, retain the generated binary as the deployment artifact,
and run application tests against the same target operating system and C toolchain
used in production. Pin this release candidate in automation rather than tracking
the default branch.

Kynx protection is enabled by default. It can be disabled with `--no-kynx` only
when the operational consequences are understood and explicitly accepted.
