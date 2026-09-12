# Orbit Documentation

Start with the question you're trying to answer. If you're new, read [Getting Started](GETTING_STARTED.md) — it builds the compiler and runs your first program without giant dependencies.

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
| What should we build next? | [Project Roadmap](ROADMAP.md) |
| What are the engineering invariants and quality gates? | [Engineering Contract](../ENGINEERING.md) |
| How does the compiler bootstrap itself? | [Self-Hosting](architecture/SELF_HOSTING.md) |
| What is the trust and reproducibility model? | [Sovereignty](architecture/SOVEREIGNTY.md) |
| How does the compiler pipeline work? | [Architecture Overview](ARCHITECTURE.md) |
| How do I write Orbit programs? | [Language Reference](LANGUAGE_REFERENCE.md) and [Syntax Guide](SYNTAX_GUIDE.md) |
| What can I build in 30 minutes? | [Language Tour](TOUR.md) — runnable snippets with expected outputs |
| How does memory management work? | [Arena Design](ARENA.md) and [Orbit Arena](architecture/ORBIT_ARENA.md) |
| How are HTTP protections implemented? | [Kynx](KYNX.md) |
| What is experimental or still being researched? | [Superluminal](SUPERLUMINAL.md) |
| What can't Orbit do yet? | [Known Limitations](KNOWN_LIMITATIONS.md) — the honest list, with workarounds |
| What changed? | [Changelog](CHANGELOG.md) and [0.1.0 Release Notes](RELEASE_NOTES_0_1_0.md) |
| What do people ask? | [FAQ](FAQ.md) — twenty honest questions |

## Tutorials and Guides

| Question | Document |
|---|---|
| How do I build a blog API with auth? | [Blog API tutorial](tutorials/blog-api.md) + [`examples/blog_api.orb`](../examples/blog_api.orb) |
| How do I serve files and accept uploads? | [File server tutorial](tutorials/file-server.md) + [`examples/file_server.orb`](../examples/file_server.orb) |
| How do I ship one binary? | [Deploy tutorial](tutorials/deploy-single-binary.md) |
| Something broke — now what? | [Troubleshooting](tutorials/troubleshooting.md) |
| How do schemas evolve? | [Migrations guide](guides/migrations.md) — the honest story |
| How do I measure honestly? | [Benchmark methodology](guides/benchmark-methodology.md) |

## Authority and Scope

- `README.md` is the public introduction, installation guide, and quickstart.
- `docs/STATUS.md` is the dated snapshot of current capabilities, risks, and active workstreams.
- `ENGINEERING.md` is the implementation contract and records executable quality gates.
- `docs/ROADMAP.md` describes sequencing and priorities; it does not replace an implementation contract.
- `docs/architecture/` contains architecture decisions, invariants, and historical transition records.
- `docs/LANGUAGE_REFERENCE.md` defines user-visible language behavior.
- `tests/` and `examples/` are executable evidence. When prose and executable behavior disagree, the discrepancy must be resolved before the feature is considered documented.

## Documentation Standards

Good docs here do this:

- state whether a feature is current, experimental, historical, or planned;
- include a runnable command or example when describing a workflow;
- name the verification gate;
- distinguish measured results from targets — I don't claim an improvement until it's measured;
- document limitations and platform assumptions plainly, including what didn't work;
- use stable terminology consistent with the language reference;
- write directly to you with contractions (`you can't`, `here's`), no hype, no superiority.

When changing compiler behavior, update the language reference or architecture documentation in the same change. When changing a verification workflow, update the contributor instructions and the relevant script documentation together.
