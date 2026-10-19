# Orbit Documentation

Start with the question you're trying to answer. If you're new, read [Getting Started](GETTING_STARTED.md) - it builds the compiler and runs your first program without giant dependencies.

## Start Here

| Question | Document |
|---|---|
| What is Orbit and how do I build it? | [Project README](../README.md) |
| How do I install and run my first program? | [Getting Started](GETTING_STARTED.md) |
| Which commands are available? | [Command Reference](COMMANDS.md) |
| Which platforms and tools are supported? | [Platform Support](SUPPORT.md) |
| How is Orbit versioned? | [Versioning and Compatibility](VERSIONING.md) |
| How should resource and energy use be measured? | [Resource and Energy Measurement](ENERGY.md) |
| How are releases packaged and verified? | [Release Artifacts](RELEASES.md) |
| What is implemented today? | [Project Status](STATUS.md) |
| What is planned next? | [Project Roadmap](ROADMAP.md) |
| How does the compiler pipeline work? | [Architecture Overview](ARCHITECTURE.md) |
| How do I write Orbit programs? | [Language Reference](LANGUAGE_REFERENCE.md) and [Syntax Guide](SYNTAX_GUIDE.md) |
| Where will the language lie to me? | [What Orbit does not promise about values](LANGUAGE_REFERENCE.md#what-orbit-does-not-promise-about-values) - 32-bit wrapping, `/` and `%` on a negative operand, untyped list slots, and guessed int/pointer casts |
| How do I write a library others can import? | [Writing a library](LIBRARIES.md) - the flat namespace, the `private` truth, and the `std/` install trap |
| What does the standard library provide, and what do error codes mean? | [Standard library](../std/README.md): [test/strings/hashing](LANGUAGE_REFERENCE.md#standard-library-test-strings-and-hashing), [collections/files/IO/time/logging](LANGUAGE_REFERENCE.md#standard-library-collections-files-io-time-and-logging), [crypto/bytes](LANGUAGE_REFERENCE.md#standard-library-cryptography-and-bytes); compiler codes in [Command Reference](COMMANDS.md#errors-and-exit-codes), project checks in the [doctor catalog](DOCTOR.md) |
| What can I build in 30 minutes? | [Language Tour](TOUR.md) - runnable snippets with expected outputs |
| How does memory management work? | [Arena Design](ARENA.md) |
| How are HTTP protections implemented? | [Kynx](KYNX.md) |
| What is experimental or still being researched? | [Superluminal](SUPERLUMINAL.md) |
| Something fails only on Windows? | [Windows](WINDOWS.md) - two diagnosed-and-fixed Windows gate failures, with reproductions and ruled-out lists |
| What can't Orbit do yet? | [Known Limitations](KNOWN_LIMITATIONS.md) - the known list, with workarounds. **Start with the first section**: the nineteen programs that used to compile cleanly are diagnostics now |
| What changed? | [Changelog](CHANGELOG.md) |
| What do people ask? | [FAQ](FAQ.md) - twenty questions |
| What are the engineering invariants and quality gates? | [Engineering Contract](../ENGINEERING.md) |
| How does the compiler bootstrap itself? | [Self-Hosting](architecture/SELF_HOSTING.md) |
| What is the trust and reproducibility model? | [Sovereignty](architecture/SOVEREIGNTY.md) |

## Tutorials and Guides

| Question | Document |
|---|---|
| How do I build a blog API with auth? | [Blog API tutorial](tutorials/blog-api.md) + [`examples/blog_api.orb`](../examples/blog_api.orb) |
| How do I serve files and accept uploads? | [File server tutorial](tutorials/file-server.md) + [`examples/file_server.orb`](../examples/file_server.orb) |
| How do I ship one binary? | [Deploy tutorial](tutorials/deploy-single-binary.md) |
| Something broke - now what? | [Troubleshooting](tutorials/troubleshooting.md) |
| How do schemas evolve? | [Migrations guide](guides/migrations.md) - the full story |
| How do I measure honestly? | [Performance notes](PERF.md) - what was changed, what was tried and dropped, and why |
| How big is the C Orbit emits, and what has been tried to cut it? | [Codegen Budget](CODEGEN_BUDGET.md) - emitted size and build cost per program, and the candidates that were tried and dropped |
| Which toolchain builds what, and what is tcc (not) for? | [Toolchain policy](TOOLCHAIN.md) - the two rules (tcc never produces a quoted number; the multithreaded server is always gcc) plus the per-platform matrix |

## Authority and Scope

- `README.md` is the public introduction, installation guide, and quickstart.
- `docs/STATUS.md` is the dated snapshot of current capabilities, risks, and active workstreams.
- `ENGINEERING.md` is the implementation contract and records executable quality gates.
- `docs/ROADMAP.md` describes sequencing and priorities. It does not replace an implementation contract.
- `docs/architecture/` contains architecture decisions, invariants, and historical transition records.
- `docs/LANGUAGE_REFERENCE.md` defines user-visible language behavior.
- `tests/` and `examples/` are executable evidence. When prose and executable behavior disagree, the discrepancy must be resolved before the feature is considered documented.

## Documentation Standards

Good docs here do this:

- state whether a feature is current, experimental, historical, or planned;
- include a runnable command or example when describing a workflow;
- name the verification gate;
- distinguish measured results from targets - I don't claim an improvement until it's measured;
- document limitations and platform assumptions plainly, including what didn't work;
- use stable terminology consistent with the language reference;
- write directly to you with contractions (`you can't`, `here's`), no hype, no superiority.

When changing compiler behavior, update the language reference or architecture documentation in the same change. When changing a verification workflow, update the contributor instructions and the relevant script documentation together.
