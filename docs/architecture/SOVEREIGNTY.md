# Compiler Sovereignty

> How Orbit bootstraps itself from committed C source with nothing but a C
> compiler and a stock `python3`.

---

## Root of trust

The trusted root is **C source code**: not a binary, and not a toolchain
shipped by anyone else.

| Artifact | Role | SHA-256 |
|---|---|---|
| `compiler/selfhost/stage3.exe.c` (4,124,475 bytes, 90,928 lines) | canonical compiler, emitted by the compiler itself | `960758367D4EF493A49A5D6F9DF46CAE5B2FA8B9FCA0DED797C37E5664109610` |
| `scripts/verify_seed.py` (`PUBLISHED_C`) | published contract, enforced by `--release` | identical to the above |

The canonical file is **committed** (explicitly un-ignored in `.gitignore`, and
marked `-text` in `.gitattributes` so no line-ending conversion can touch it).
The CI-verified compilers are gcc on `ubuntu-latest` and clang on
`windows-latest` (see `.github/workflows/ci-gate.yml`). The design goal is
that any conforming C compiler can build the canonical into a working Orbit
compiler; only gcc and clang are exercised in CI, and other compilers
(including MSVC `cl`) are not verified. The trust story is: if you can read
C, you can audit the compiler.

## The fixed point

The compiler reproduces its own C byte-for-byte:

```
canonical C ──(gcc or clang, per CI)──▶ seed ──builds──▶ compiler/main.orb ──emits──▶ the same canonical C
```

The committed C plus the byte-identity check is the contract. Replacing
it is the only supported operation, and it is explicit and reviewable.

### Why a single lineage: the Thompson/DDC trade-off

Threat model: following Ken Thompson's Reflections on Trusting Trust, a
backdoor inserted into the compiler sources, or into the C toolchain that
compiles them, reproduces itself through every bootstrap stage. Byte identity
alone cannot detect such a backdoor, because each stage inherits whatever the
previous stage embedded: a compromised compiler reproduces the compromise
exactly.

Diverse Double-Compiling (DDC) is the standard countermeasure: rebuild the
same sources with a second, independently implemented compiler and compare the
output. Agreement between two independent lineages shows the bytes are a
property of the sources rather than of one implementation's hidden state.
Orbit has no second Orbit implementation, and building and maintaining one
solely as a check would double the trusted surface along with its own
correctness burden. That is the trade-off: a single lineage keeps the
auditable surface to one readable C file, at the cost of leaving a
source-level self-reproducing backdoor outside what byte-identity can catch.

The mitigation in use is toolchain diversity at the C step, enforced by the
Scenario 3 recovery procedure below: gcc and clang, independent front ends,
optimizers, and linkers, must converge on byte-identical emitted C. Their
agreement shows the canonical bytes are determined by `compiler/*.orb`
rather than by quirks or hidden state of one C compiler. This narrows the
residual risk to the Orbit sources themselves plus a defect shared by both
toolchains; it does not defend against a self-reproducing backdoor already
present in the Orbit sources. That residual risk is accepted and managed by
keeping the canonical as readable C source, requiring each promote to move
the canonical, the 32 parity goldens, and the `.orb` sources in one
reviewable commit, and backing behavior with the parity battery and the
behavior suite.

## Glossary - canonical bootstrap terms

The terms below are defined once, here. `ARCHITECTURE.md` and `STATUS.md`
link here instead of redefining them.

- **canonical**: the committed file `compiler/selfhost/stage3.exe.c`, C
  source emitted by the compiler itself, and the root of trust.
- **seed**: the first working Orbit compiler, produced by compiling the
  canonical with the platform C compiler (gcc or clang in CI).
- **seed2**: the first compiler Orbit itself produced: the seed compiles
  `compiler/main.orb`, and that emitted C is recompiled into the `seed2`
  binary.
- **chain2**, **chain3**: successive rebuilds, each by its predecessor with
  no host toolchain involved: `seed2` builds `main.orb` and its emitted C
  becomes `chain2`; `chain2` builds `main.orb` and its emitted C becomes
  `chain3`. Every stage compiles the same source, `compiler/main.orb`.
- **promote**: `python scripts/build_selfhost.py --promote`, the only
  operation that replaces the canonical, after an intentional compiler
  change. It also updates `PUBLISHED_C` and requires the refreshed parity
  goldens; canonical, goldens, and `.orb` sources move in one commit.
- **PUBLISHED_C**: the published hash contract in `scripts/verify_seed.py`,
  enforced by `--release` against a self-hosted rebuild.
- **amalgamate**: `scripts/amalgamate.py`, a mechanical step that inlines
  the include graph from the canonical into one self-contained C
  file (system includes left alone) so the seed compiles from a single
  translation unit. It changes packaging, not semantics; see the trust
  boundary below for where it fits.

## Trust boundary: what is trusted vs verified

```text
[TRUSTED] canonical C source (committed, reviewable)
    |  amalgamate: inline project includes -> single translation unit
    |  (mechanical packaging; system includes untouched)
    v
[TRUSTED for one step] platform C compiler translates the amalgamation -> seed
    |  (the only artifact Orbit did not produce)
    v
[VERIFIED] seed compiles compiler/main.orb -> emitted C byte-equals canonical
    v
[VERIFIED] emitted C recompiled -> seed2 -> emits canonical (check 2)
    v
[VERIFIED] seed2 output recompiled -> chain2 -> emits canonical (check 3)
    v
[VERIFIED] chain2 output recompiled -> chain3 -> emits canonical (check 4)
    |  checks 3-4 exist because a chain can converge at stage one and drift after
    v
[INFORMATIONAL ONLY] binary byte-equality of seed2/chain2/chain3
    (toolchain-specific: timestamps, PDB paths, section order; reported, not asserted)
```

Trusted: the canonical C source, the one-step translation by the platform C
compiler, and the Python drivers that sequence the chain. Verified: every
emitted-C equality (the four `verify_seed.py` checks; the C-source hash is
the cross-platform contract). Amalgamation sits between the two: a mechanical
include-inlining with no semantic content, covered downstream by the same
emitted-C comparisons.

## Workflows

```sh
# Rebuild the compiler from the committed canonical and check the sources
# still converge to it. Fails when the sources have moved on: CI mode.
python scripts/build_selfhost.py --cc gcc --check-stale

# After an INTENTIONAL compiler change: converge and promote a new canonical.
# This is the ONLY way to replace the root of trust, and it also updates
# PUBLISHED_C. Commit the canonical, the goldens and the .orb sources together.
python scripts/build_selfhost.py --promote

# Hermetic verification: amalgamate -> seed -> seed2 -> chain2 -> chain3, and
# assert the emitted C of every stage equals the canonical.
python scripts/verify_seed.py --cc gcc

# Install the fixed-point compiler and put it on PATH.
scripts/install.sh          # or scripts/install.ps1 on Windows
```

The build resolves the C compiler as `ORBIT_CC`, then `CC`, then the POSIX
`cc` convention. `compiler/pipeline.orb` is the only place that decides it.

### What the gates actually assert

`scripts/verify_seed.py` checks four things and reports each one:

1. the seed builds;
2. the C the seed emits for `compiler/main.orb` equals the canonical;
3. the C emitted by **chain2** equals the canonical;
4. the C emitted by **chain3** equals the canonical.

Checks 3 and 4 exist because a chain can fix a point at stage one and drift
afterwards, and a gate that only compares the first stage cannot see that.

The byte-identity of the three *binaries* is reported but not asserted. It is
toolchain-specific: linkers embed timestamps, PDB paths, section order and
relocations, so binary bytes are a property of the C compiler and the linker,
not of the language. Set `ORBIT_CCACHE=0` to force the comparison when you
want it, and read the result as informational.

## Speeding the gates up without weakening them

The bootstrap recompiles the same multi-megabyte C unit dozens of times per
gate. `scripts/orbit_ccache.py` makes that a file copy: it is
content-addressed on the compiler identity, its version, the exact flags, and
the SHA-256 of every input, so a stale entry can only ever cause a miss and
never a wrong artifact. When the cache serves one of the three contract
binaries, the binary comparison is reported as not evaluated rather than as a
pass, because a cache hit would make it a tautology. The C comparisons are
unaffected, and they are the contract.

The bootstrap also builds the compiler without `-Wall`: on the 3.9 MB unit
that flag is a 5.7x penalty and surfaces 89 warnings, because the analysis it
enables is superlinear in emitted size. The strict warning gate is
`scripts/werror_gate.py`, which runs `-Werror` over generated C in CI. Set
`ORBIT_BOOTSTRAP_WARNINGS=1` to get `-Wall` back locally.

## Rules for contributors

- **Never break the fixed point silently.** If `compiler/*.orb` changes, run
  `python scripts/build_selfhost.py --promote` and commit the canonical, the
  32 parity goldens and the sources in the same commit.
- **Never introduce a hard dependency on a specific toolchain vendor.** The
  build must keep working with the CI matrix compilers (gcc on Ubuntu,
  clang on Windows).
- **The reproducibility contract is the C source hash**, cross-platform.
  Binary hashes stay informational.
- **Never regenerate the canonical as a side effect of an unrelated change.**
  A promote is a deliberate act with a reviewable diff.

## Disaster recovery runbook

**Scenario 1 - the canonical C is corrupted or lost.**

1. `git checkout main -- compiler/selfhost/stage3.exe.c`, or take
   `dist/orbit_bootstrap.c` from the latest release (it is the amalgamation
   whose entry file is the canonical).
2. Validate: `python scripts/build_selfhost.py --cc <cc> --check-stale`.
3. If the sources also moved past the restored canonical, converge forward:
   `--promote`, then refresh the goldens.

**Scenario 2 - the fixed point is broken by a bad commit.**

1. Find the last green commit, or bisect:
   `git bisect run python scripts/build_selfhost.py --cc gcc --check-stale`.
2. Revert, or fix forward: repair `compiler/*.orb`, then `--promote` plus a
   goldens refresh in one commit.

**Scenario 3 - total loss of trust in the chain (suspected poisoning).**

1. Rebuild against a known-good tag: `git checkout <last-green-tag>`, then
   repeat Scenario 1.
2. Get two independent toolchains to agree on the converged bytes. `--cc gcc`
   and `--cc clang` must produce the same canonical, because the canonical is
   supposed to be a property of the sources and not of the compiler that reads
   them.
3. Only once two toolchains agree, re-publish. The promote flow updates
   `PUBLISHED_C`, and `verify_seed.py --release` pins the new contract.

Invariants that must hold afterwards:

- `build_selfhost.py --check-stale` exits 0 on `main`.
- `verify_seed.py` reports 4/4.
- `parity_selfhost.py` reports 32/32 against the committed goldens.
- CI is green on ubuntu/gcc and windows/clang, and all eight stress legs pass.

## Related

- [Self Hosting](SELF_HOSTING.md) - why the compiler is written in its own
  language.
- `docs/PERF.md` - the measured cost of the self-build, with the commands.

## Appendix: stages in detail

Terms are defined in the Glossary above; this section records only the
mechanical per-stage notes. A stage is a working Orbit compiler built by the
previous stage, and every stage compiles the same source
(`compiler/main.orb`):

```
seed    (canonical C, compiled by cc)
  │  builds main.orb, emits C
  ▼
seed2   (compiled from the emitted C, by cc)
  │  builds main.orb, emits C
  ▼
chain2
  │  builds main.orb, emits C
  ▼
chain3
```

Per stage: `amalgamate.py` inlines the `#include "..."` graph from the
canonical into one self-contained C file (system includes left alone); a C
compiler turns it into `seed` with `-DORBIT_WITH_EXEC` so the compiler can
spawn its own `cc` (the only step needing more than a C compiler and
Python); each stage builds `main.orb`, writes one intermediate C file of a
fixed name (`compilers embed the source path in the binary, so a per-stage
name would break byte-comparability`), and `verify_seed.py` recompiles that
C itself with known-good flags.

Promotion between stages: canonical -> seed needs any conforming C
compiler; seed -> seed2 must emit C byte-identical to the canonical;
seed2 -> chain2 -> chain3 must rebuild without any host toolchain, each
emitting the canonical. **Do not let the intermediate C land in the working
directory** (megabytes, racy under concurrent builds) and **do not promote
to make a gate green** (a promote replaces the root of trust).
