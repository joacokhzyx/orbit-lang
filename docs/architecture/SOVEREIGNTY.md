# Compiler Sovereignty (SOVER-1)

> How Orbit bootstraps itself without any Zig dependency.

---

## Root of trust

The trusted root is **C source code**, not a binary and not a foreign toolchain:

| Artifact | Role | Hash (SHA-256) |
|---|---|---|
| `compiler/selfhost/stage3.exe.c` | Canonical compiler, emitted by the compiler itself | `B48471559DFCA58B71ECDBE4B64D9AA020833AFE508AE288958BD8D0D8E47E5B` |
| `scripts/verify_seed.py` (`PUBLISHED_C`) | Published contract enforced by `--release` | same |

The canonical file is **committed** (un-ignored in `.gitignore`). Any conforming
C compiler can compile it into a working Orbit compiler.

## Fixed point

The compiler reproduces its own C byte-for-byte:

```
canonical C ──(any cc)──▶ seed.exe ──builds──▶ compiler/main.orb ──emits──▶ same canonical C
```

Cross-validation (2026-08-22): the self-host chain output and the legacy Zig
lineage output are byte-identical at this hash. The Zig lineage is therefore
redundant and kept only as a deprecated cross-check.

## Zig-free workflows

```sh
# Rebuild + verify the compiler from the committed canonical (no Zig).
# Fails when sources diverge from the canonical (CI mode).
python scripts/build_selfhost.py --cc gcc --check-stale

# After an INTENTIONAL compiler change: converge and promote a new canonical.
python scripts/build_selfhost.py --promote        # updates PUBLISHED_C too

# Hermetic verification (amalgamate -> seed -> chain -> binary fixed point).
python scripts/verify_seed.py --cc gcc

# Install without Zig.
scripts/install.sh          # or scripts/install.ps1 on Windows
```

C compiler resolution everywhere: `ORBIT_CC` → `CC` → `gcc` → `clang` → `cc`
(`pipeline.orb` resolves `ORBIT_CC` → `CC` → POSIX `cc`).

## Status of the Zig tree

`src/` remains only as:

1. A **legacy seed lineage** (`verify_seed.py --bootstrap`) for cross-checking.
2. Host of the old test suite until parity tests are ported into Orbit
   (CI runs them as a **non-blocking** `legacy-zig-tests` job).

Neither is required to build, verify, release, or install the compiler.

## Rules for contributors

- Never break the fixed point silently: if `compiler/*.orb` changes,
  run `python scripts/build_selfhost.py --promote` and commit both together.
- Never introduce a hard dependency on a specific toolchain vendor.
- The reproducibility contract is the C source hash, cross-platform;
  binary hashes stay informational (PE timestamps are zeroed before compare).
