# Orbit Self-Hosting

> Orbit's compiler is written in Orbit. This document defines what that means
> concretely, and what has to hold for the arrangement to be trustworthy.
> For the operational flow and the recovery runbook, see
> [Sovereignty](SOVEREIGNTY.md).

## Why self-hosting

A compiler written in its own language is only interesting if it can build
itself from something simple enough to audit. Orbit's compiler is written in
Orbit and emits C; a C compiler, plus a stock `python3` to drive the
bootstrap, is the entire dependency list. There is no prebuilt Orbit binary
anywhere in the trust path, and no foreign toolchain whose output we have to
take on faith.

That gives the property the whole design is after: **anyone can read
`compiler/selfhost/stage3.exe.c` and check what the compiler does.** It is C,
it is committed, and it is 3.9 MB. A third party does not need to run Orbit at
all to audit it.

## The stages

The bootstrap builds the compiler through successive stages. Each stage is a
working compiler; each stage is built by the previous one; every stage compiles
the same source, `compiler/main.orb`.

```
            [canonical C, committed]
                        │
                        │  any C compiler
                        ▼
                  [seed compiler]
                        │
                        │  builds compiler/main.orb, emits C
                        ▼
                  [seed2 compiler]
                        │
                        │  builds compiler/main.orb, emits C
                        ▼
                   [chain2 compiler]
                        │
                        │  builds compiler/main.orb, emits C
                        ▼
                   [chain3 compiler]
```

- **canonical C**: the committed root of trust. Not a stage, because it is not
  produced by Orbit; it is what the first C compiler consumes.
- **seed**: the canonical C compiled by the platform's C compiler. This is the
  only artifact in the chain that Orbit did not produce.
- **seed2**: the first compiler that Orbit itself produced, from the seed.
- **chain2**, **chain3**: successive rebuilds, each by its predecessor, with no
  host toolchain involved at all.

## The fixed point

A **fixed point** is reached when a stage's emitted C is byte-identical to the
canonical C. At that point the compiler reproduces itself exactly: the bytes
are a function of the sources, not of whichever compiler happened to read them.

Two properties follow, and both are load-bearing:

1. **The contract is the C source, not the binary.** Binary bytes carry linker
   timestamps, PDB paths, section order and relocation layout, so they are a
   property of the C toolchain. `scripts/verify_seed.py` reports the binary
   comparison and does not assert on it.
2. **Every stage must hold, not just the first.** A chain can converge at
   stage one and drift afterwards. `verify_seed.py` therefore asserts the
   emitted C of `seed2`, `chain2` and `chain3` against the canonical, and
   `compiler/main.orb` is the single source every stage compiles.

## What self-hosting does not buy

Stating this plainly, because the arrangement has sharp edges:

- **It is not faster.** A compiler bootstrapped in its own language pays for
  every missing language feature. The self-build is measured in
  [docs/PERF.md](../PERF.md); the honest reading is that most of its cost is
  the C compiler invoked on a large generated translation unit, not the Orbit
  front end.
- **It is not a proof of correctness.** A self-hosting compiler can reproduce a
  bug perfectly. What self-hosting buys is auditability and a reproducibility
  contract, and those are what the parity goldens
  (`scripts/parity_selfhost.py`, 32 probes) and the behaviour suite
  (`scripts/test_suite.py`) exist to back up.
- **It does not remove the bootstrap.** There is always a first compiler, and
  it is C. Self-hosting moves the trust root from a binary to readable source;
  it does not eliminate it.

## Invariants

- `python scripts/build_selfhost.py --check-stale` exits 0 on `main`.
- `python scripts/verify_seed.py` reports 4/4.
- `python scripts/parity_selfhost.py` reports 32/32.
- The canonical C, the 32 goldens and the `.orb` sources move in one commit,
  produced by `python scripts/build_selfhost.py --promote`.
- No commit weakens the fixed point to make a gate pass.
