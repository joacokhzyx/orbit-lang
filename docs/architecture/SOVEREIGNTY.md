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

The Zig seed tree (`src/`, `build.zig`) was **removed** after the W2 parity
gate froze its validated behavior into committed goldens. It remains available:

1. As the git tag **`legacy-zig-seed`** (full tree + history).
2. For optional cross-checks, check out that tag, build it, and run
   `python scripts/verify_seed.py --bootstrap` against this tree.

Neither is required to build, verify, release, or install the compiler.

## Rules for contributors

- Never break the fixed point silently: if `compiler/*.orb` changes,
  run `python scripts/build_selfhost.py --promote` and commit both together.
- Never introduce a hard dependency on a specific toolchain vendor.
- The reproducibility contract is the C source hash, cross-platform;
  binary hashes stay informational (PE timestamps are zeroed before compare).

## Disaster recovery runbook

Scenario 1 — canonical C corrupted or lost (`stage3.exe.c` broken/missing):

1. `git checkout main -- compiler/selfhost/stage3.exe.c` (restore from history), OR
   download `orbit_bootstrap.c` from the latest GitHub Release and re-split it
   (it is the amalgamation; the canonical is its entry file).
2. Validate: `python scripts/build_selfhost.py --cc <cc> --check-stale`
3. If sources also moved past the restored canonical: converge forward instead
   — `python scripts/build_selfhost.py --promote`, then parity refresh.

Scenario 2 — fixed point broken by a bad commit:

1. Identify the last green commit: CI history or
   `git bisect run python scripts/build_selfhost.py --cc gcc --check-stale`.
2. Either revert the offending commit, or fix forward:
   repair `compiler/*.orb`, then `--promote` + goldens refresh in ONE commit.

Scenario 3 — total loss of trust in the chain (suspected seed poisoning):

1. Rebuild from scratch against a known-good tag:
   `git checkout <last-green-tag>` then repeat Scenario 1 step 2.
2. Cross-check two independent toolchains agree on the converged hash:
   `--cc gcc` and `--cc clang` must produce identical canonical bytes.
3. Only after 2+ toolchains agree, re-publish: update `PUBLISHED_C`
   (the promote flow does it) and cut a release so `verify_seed.py --release`
   pins the new contract.

Invariants that must always hold afterwards:

- `build_selfhost.py --check-stale` exits 0 on main.
- `parity_selfhost.py` reports N/N against committed goldens.
- CI (ubuntu-gcc / windows-clang / stress) is green.
