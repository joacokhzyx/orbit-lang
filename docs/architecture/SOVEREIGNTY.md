# Compiler Sovereignty (SOVER-1)

> How Orbit bootstraps itself from committed C source with nothing but a C
> compiler and a stock `python3`.

---

## Root of trust

The trusted root is **C source code**: not a binary, and not a toolchain
shipped by anyone else.

| Artifact | Role | SHA-256 |
|---|---|---|
| `compiler/selfhost/stage3.exe.c` (3,928,804 bytes, 86,549 lines) | canonical compiler, emitted by the compiler itself | `98A6DB81A6326817EA72C51739A186155F2E8E44D5F19CEB0C35696861CB01A0` |
| `scripts/verify_seed.py` (`PUBLISHED_C`) | published contract, enforced by `--release` | identical to the above |

The canonical file is **committed** (explicitly un-ignored in `.gitignore`, and
marked `-text` in `.gitattributes` so no line-ending conversion can touch it).
Any conforming C compiler turns it into a working Orbit compiler. That is the
whole trust story: if you can read C, you can audit the compiler.

## The fixed point

The compiler reproduces its own C byte-for-byte:

```
canonical C ──(any cc)──▶ seed ──builds──▶ compiler/main.orb ──emits──▶ the same canonical C
```

There is no second lineage to cross-check against, and that is deliberate. A
second implementation of the compiler would be a second thing that can be
wrong; the committed C plus the byte-identity check is the contract. Replacing
it is the only supported operation, and it is explicit and reviewable.

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

C compiler resolution is the same everywhere: `ORBIT_CC` then `CC` then
`gcc` / `clang` / `cc` / `cl`. `compiler/pipeline.orb` resolves `ORBIT_CC`,
then `CC`, then the POSIX `cc` convention.

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
  build must keep working with whatever C compiler the contributor has.
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

- [Bootstrap Stages](BOOTSTRAP_STAGES.md) - what each stage is and what
  promotion between stages requires.
- [Self Hosting](SELF_HOSTING.md) - why the compiler is written in its own
  language.
- `docs/PERF.md` - the measured cost of the self-build, with the commands.
