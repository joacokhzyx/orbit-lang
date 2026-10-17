# Contributing to Orbit

Thanks for your interest in Orbit. I'm building it to do more with less - less energy, less complexity, same speed - and I read every contribution.

This guide covers how to propose changes, open pull requests, and keep quality high across the compiler and C runtime.

---

## Code of Conduct

All contributors are expected to adhere to the [Orbit Code of Conduct](CODE_OF_CONDUCT.md). Please treat all members of the community with respect and professionalism.

---

## Development Environment Setup

### Prerequisites

To build and test Orbit locally, ensure you have the following installed:

1. **C Compiler**: GCC, Clang, or MSVC (set `ORBIT_CC` if autodetection fails).
2. **Python 3.10+** (required for the bootstrap/verification scripts).

No toolchain vendor is involved: a C compiler plus a stock `python3` are the
whole dependency list. The compiler bootstraps itself from the committed
canonical C (see [docs/architecture/SOVEREIGNTY.md](docs/architecture/SOVEREIGNTY.md)).

### Building from Source

Clone the repository and use the `make` entry point (a thin wrapper over
`scripts/dev.py`, the single authority for gates):

```bash
git clone https://github.com/joacokhzyx/orbit-lang.git
cd orbit-lang
make fp     # build the fixed-point compiler and print its version
make dev    # gates proportionate to what the working tree touched
```

`scripts/dev.py` owns `TEMP`/`TMP`, `ORBIT_CCACHE_DIR`, the fixed-point
binary and each gate's flags. Do not export those variables by hand and do
not pass `--cc`/`--compiler` by hand. Windows runners have no `make`, so
call `scripts/dev.py` directly there (`python scripts/dev.py dev`, and so
on); see `Makefile` and `AGENTS.md`.

End users who just want Orbit installed take the CI release wizard
(`Orbit-Setup-<version>.exe`, built from `installer/orbit.iss` as described
in `docs/RELEASES.md`), not a source checkout.

---

## Running Tests & Gates

The `make` targets are the single authority for verification (see `Makefile`,
`scripts/dev.py` and `AGENTS.md`). Do not invoke the scripts in `scripts/`
by hand with `--cc`/`--compiler`:

```bash
make dev    # T0+T1 default; tiers picked from git diff, erring toward more
make check  # T0..T2 unconditionally (language + static analysis)
make all    # T0..T3, including the root of trust (run before promoting)
make fp     # just the fixed-point compiler, and print its version
make list   # show what dev would run, without running it
```

A green `make dev` is not a green CI (`dev.py` prints the tiers it skipped).
A rule change or anything touching `compiler/**/*.orb` needs `make check`;
before a commit that promotes the canonical, run `make all`.

When one thing is broken and the rest is noise, use the single-gate targets
(`make doctor`, `make suite`, `make parity`, `make werror`, `make negative`,
`make report`) instead of retyping gate commands. The runtime C tests run
inside these tiers (via `scripts/runtime_c_tests.py`).

`scripts/werror_gate.py` is the strict warning gate. The bootstrap
deliberately builds without `-Wall` because it costs 5.7x on the compiler's own
multi-megabyte output unit; see [Performance notes](docs/PERF.md). Set
`ORBIT_BOOTSTRAP_WARNINGS=1` to get warnings back while hacking.

Every gate runs on a C compiler plus a stock `python3`. There is nothing to
install.

Ensure all gates pass before submitting a pull request.

---

## Coding Standards & Guidelines

Orbit follows strict architectural and diagnostic conventions, written in a
calmer voice than the projects it grew up around: direct, no hype, no
superiority.

### 1. Diagnostic Formatting & Error Messages

Diagnostics shape how Orbit feels at 3am, so they follow the brand rule: clear header, helpful body.

- **No borders or emojis**: clean text, no decorative boxes or emojis.
- **English suggestions**: write all hints and explanations in English with contractions where natural (`can't`, `doesn't`, `here's`).
- **Header states fact + fix**: `Port 3000 is already in use. Change it in X.orb and try again.` Never hide the action behind metaphor. Orbital language stays out of headers.
- **Body helps first, warms second**: add a tip with the exact next command. Example: `Tip: run `orbit ports` to see what's free. Small fix - you'll be running in seconds.` One warm line max, never cheesy, never blaming you.
- **When Orbit broke it, own it**: no humor to deflect. Say what failed, give a workaround, and note the fix in progress.
- **Verbose enough to act**: explain what happened and how to continue, rather than a cryptic code alone.
- **Consistent color styling**: red for errors, yellow for warnings, cyan for line numbers.

### 2. Code Formatting

- **Orbit Compiler Sources**: Keep `compiler/**/*.orb` consistent with the existing style; any change must converge to a new fixed point (`make promote`, reviewed with `make promote-diff`).
- **C Runtime Engine**: Keep C code in `runtime/` idiomatic, const-correct, and free of compiler warnings (`-Wall -Wextra`).
- **Documentation Comments**: Use triple-slash doc comments (`///`) for public functions, structs, and module APIs.

---

## Pull Request Process

1. **Create a Feature Branch**:
   ```bash
   git checkout -b feature/your-feature-name
   ```
2. **Commit Changes**: Write clear, descriptive commit messages.
3. **Run Verification Suite**:
   ```bash
   make check   # T0..T2; use make all before a commit that promotes the canonical
   ```
4. **Submit PR**: Open a pull request against the `main` branch with a clear description of the problem solved or feature added.

---

## License

By contributing to Orbit, you agree that your contributions will be licensed under the project's [MIT License](LICENSE).
