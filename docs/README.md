# Orbit documentation

Ten pages. Each answers one kind of question, and the first table is the
whole map: if a page is not there, it does not exist for the reader.

## The pages

| Question | Page | What it decides |
|---|---|---|
| What is Orbit, and how do I run a service? | [`../README.md`](../README.md) | The short answer and the five-minute start |
| How do I install it and run a first program? | [`GETTING_STARTED.md`](GETTING_STARTED.md) | Prerequisites, build, first compile, first server, a thirty-minute tour |
| How do I write Orbit? | [`LANGUAGE_REFERENCE.md`](LANGUAGE_REFERENCE.md) | Syntax, semantics, imports, memory, diagnostics, formatting |
| Which commands exist? | [`COMMANDS.md`](COMMANDS.md) | Every command, backends, terminal output, doctor checks, errors |
| How does the compiler work? | [`ARCHITECTURE.md`](ARCHITECTURE.md) | Pipeline, runtime modules, start-up, threads, request path, file index |
| What does the IR look like? | [`IR_SPEC.md`](IR_SPEC.md) | The IRv1 document the compiler emits and R6 consumes |
| How do the HTTP protections work? | [`ADMISSION.md`](ADMISSION.md) | Admission, leases, route limits, request boundaries |
| How does `orbit cluster` work? | [`CLUSTER.md`](CLUSTER.md) | Single-host process orchestration |
| Which platforms, versions and limits apply? | [`SUPPORTED.md`](SUPPORTED.md) | Platforms, toolchain, compatibility, what is not supported yet, FAQ |
| What changed? | [`CHANGELOG.md`](CHANGELOG.md) | Release history |
| How do I contribute? | [`../CONTRIBUTING.md`](../CONTRIBUTING.md) | Branch flow, gates, commits, release process |

## Tutorials

Runnable programs with the output they print, kept next to the reference
rather than inside it.

| Question | Page |
|---|---|
| How do I build a blog API? | [`tutorials/blog-api.md`](tutorials/blog-api.md) |
| How do I serve files and uploads? | [`tutorials/file-server.md`](tutorials/file-server.md) |
| How do I ship one binary? | [`tutorials/deploy-single-binary.md`](tutorials/deploy-single-binary.md) |
| Something broke; now what? | [`tutorials/troubleshooting.md`](tutorials/troubleshooting.md) |
| How do schemas evolve? | [`guides/migrations.md`](guides/migrations.md) |

## Evidence

`internals/` holds the measurements a claim in the pages above rests on. A
reader looking for what a program relies on does not need these; a reader
checking a number does.

| Page | What it measures |
|---|---|
| [`internals/PERF.md`](internals/PERF.md) | Build and run cost, the method and the machine |
| [`internals/CODEGEN_BUDGET.md`](internals/CODEGEN_BUDGET.md) | Emitted C size and build cost per program |
| [`internals/ENERGY.md`](internals/ENERGY.md) | CPU, memory and energy accounting |
| [`internals/OPTIMIZER_EXPERIMENTS.md`](internals/OPTIMIZER_EXPERIMENTS.md) | Experimental program transformations |
| [`internals/ARENA.md`](internals/ARENA.md) | The arena allocator's layout and mechanics |
| [`internals/SHARDING.md`](internals/SHARDING.md) | How the single translation unit splits into linkable shards |
| [`internals/SELF_HOSTING.md`](internals/SELF_HOSTING.md) | Why and how the compiler compiles itself |
| [`internals/SOVEREIGNTY.md`](internals/SOVEREIGNTY.md) | The root of trust, the fixed point and recovery |
| [`internals/LIMITATIONS_LOG.md`](internals/LIMITATIONS_LOG.md) | The dated record behind `SUPPORTED.md`, command by command |
| [`internals/DEFECTS.md`](internals/DEFECTS.md) | Defect and finding index, with the measurement that closed each one |

## Authority

When prose and executable behaviour disagree, the gate and the tree win. This
table names the document that decides each topic.

| Topic | Normative document |
|---|---|
| Language behaviour | `LANGUAGE_REFERENCE.md` |
| IR text and semantics | `IR_SPEC.md` |
| Commands and their output | `COMMANDS.md` |
| Platforms, versions and limits | `SUPPORTED.md` |
| Gates, invariants and debt | `../ENGINEERING.md` |
| Branches, review and releases | `../CONTRIBUTING.md` |
| Test corpora | `tests/*/README.md` and the runner output |

New material goes into an existing page before a new one is created. A new
page needs a row here in the same commit.
