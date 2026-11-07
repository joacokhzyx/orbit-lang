# Orbit documentation

Start with the question you are trying to answer. The first table is the
complete map; the second names the document that decides each topic.

## Start here

| Question | Document | Answer in one line |
|---|---|---|
| What is Orbit, and how do I run a service? | [`../README.md`](../README.md) | A statically typed language for services, with a five-minute start |
| How do I install it and run a first program? | [`GETTING_STARTED.md`](GETTING_STARTED.md) | Prerequisites, build, first compile and first server |
| Which commands exist? | [`COMMANDS.md`](COMMANDS.md) | User commands, backends, errors, exit codes |
| How do I write Orbit? | [`LANGUAGE_REFERENCE.md`](LANGUAGE_REFERENCE.md) | The user-visible language, with limits stated |
| What is missing or surprising? | [`KNOWN_LIMITATIONS.md`](KNOWN_LIMITATIONS.md) | The measured limits, with workarounds |
| How does the compiler work? | [`ARCHITECTURE.md`](ARCHITECTURE.md) | Pipeline, runtime, modules and corpora |
| How do the HTTP protections work? | [`ADMISSION.md`](ADMISSION.md) | Admission, limits and request handling |
| What is experimental? | [`internals/OPTIMIZER_EXPERIMENTS.md`](internals/OPTIMIZER_EXPERIMENTS.md) | Compiler research, with no plan attached |
| How does `orbit cluster` work? | [`CLUSTER.md`](CLUSTER.md) | Single-host process orchestration |
| How is the compiler bootstrapped? | [`internals/SELF_HOSTING.md`](internals/SELF_HOSTING.md) | Why and how the compiler compiles itself |
| What is trusted in the bootstrap? | [`internals/SOVEREIGNTY.md`](internals/SOVEREIGNTY.md) | Root of trust, fixed point, recovery |
| How fast does it build and run? | [`internals/PERF.md`](internals/PERF.md) | Method and measured performance |
| How do I measure resource use? | [`internals/ENERGY.md`](internals/ENERGY.md) | CPU, memory, energy method and the ledger |
| How large is the generated C? | [`internals/CODEGEN_BUDGET.md`](internals/CODEGEN_BUDGET.md) | Emitted size and build cost per program |
| What changed? | [`CHANGELOG.md`](CHANGELOG.md) | Release history |
| What do people ask? | [`FAQ.md`](FAQ.md) | Twenty questions, answered plainly |
| How do I report a vulnerability? | [`../SECURITY.md`](../SECURITY.md) | Private disclosure and response |
| How do I work as an agent here? | [`../AGENTS.md`](../AGENTS.md) | Gates, zones, review and stop rules |
| What is the engineering contract? | [`../ENGINEERING.md`](../ENGINEERING.md) | Invariants, debt rows and gate commands |
| How do I build a blog API? | [`tutorials/blog-api.md`](tutorials/blog-api.md) | Runnable example with expected output |
| How do I serve files and uploads? | [`tutorials/file-server.md`](tutorials/file-server.md) | Runnable example with scope stated |
| How do I ship one binary? | [`tutorials/deploy-single-binary.md`](tutorials/deploy-single-binary.md) | Windows and Linux deployment, plus one-box clustering |
| Something broke; now what? | [`tutorials/troubleshooting.md`](tutorials/troubleshooting.md) | Ports, silent exits and slow first boots |
| How do schemas evolve? | [`guides/migrations.md`](guides/migrations.md) | Forward migrations and what is missing |
| How is the self-host split into shards? | [`internals/SHARDING.md`](internals/SHARDING.md) | The shard contract and its measurements |

## Authority

When prose and executable behaviour disagree, the gate and the tree win. This
table names the document that decides each topic.

| Topic | Normative document | What it decides |
|---|---|---|
| Language behaviour | `LANGUAGE_REFERENCE.md` | What a program means, and what is not promised |
| IR text and semantics | `IR_SPEC.md` | The IRv1 document the compiler emits |
| Gates and invariants | `ENGINEERING.md` §7 and §8, `scripts/dev.py` | What a change must not contradict, and how it is checked |
| Test corpora | `tests/*/README.md` and the runner output | What each gate measures |
| Documentation map | this file | Which page answers which question |

A document that is not in the first table does not exist for the reader. New
content goes into an existing row before a new file is created.
