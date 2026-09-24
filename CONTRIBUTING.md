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

No Zig or any other toolchain vendor is involved: the compiler bootstraps
itself from the committed canonical C (see [docs/architecture/SOVEREIGNTY.md](docs/architecture/SOVEREIGNTY.md)).

### Building from Source

Clone the repository and build the fixed-point self-hosted compiler:

```bash
git clone https://github.com/joacokhzyx/orbit-lang.git
cd orbit
python scripts/build_selfhost.py --out orbit.exe
```

Or run the full installer (`scripts/install.ps1` / `scripts/install.sh`).

---

## Running Tests & Gates

Orbit's correctness contract is enforced by three Zig-free gates:

```bash
CC=gcc   # or clang / cc
python scripts/build_selfhost.py --cc "$CC" --check-stale     # canonical is fresh
python scripts/verify_seed.py --cc "$CC"                      # hermetic fixed point
python scripts/parity_selfhost.py --cc "$CC" \
       --compiler /tmp/orbit_fp                               # 25-probe goldens
```

For the parity gate, first emit the fixed-point compiler with
`python scripts/verify_seed.py --cc "$CC" --emit-fixed-point /tmp/orbit_fp`.

Ensure all gates pass before submitting a pull request.

### Running Marketing & Stress Benchmarks

To execute the multi-language stress and performance benchmark suite:

```bash
python benchmarks/marketing_suite/run_marketing_bench.py
```

---

## Coding Standards & Guidelines

Orbit follows strict architectural and diagnostic conventions modeled after `ziglang/zig` and `rust-lang/rust`, written in a calmer voice: direct, no hype, no superiority.

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

- **Orbit Compiler Sources**: Keep `compiler/*.orb` consistent with the existing style; any change must converge to a new fixed point (`build_selfhost.py --promote`).
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
   python scripts/build_selfhost.py --cc "$CC" --check-stale
   python scripts/verify_seed.py --cc "$CC"
   ```
4. **Submit PR**: Open a pull request against the `main` branch with a clear description of the problem solved or feature added.

---

## License

By contributing to Orbit, you agree that your contributions will be licensed under the project's [MIT License](LICENSE).
