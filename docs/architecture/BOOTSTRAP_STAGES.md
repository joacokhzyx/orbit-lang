# Bootstrap Stages and Verification

What the bootstrap actually does, stage by stage, and what has to hold for a
stage to be promotable. The supported flow needs a C compiler and a stock
`python3`; nothing else.

## The chain

A stage is a working Orbit compiler. A stage is built by the previous stage,
and both compile the same source (`compiler/main.orb`):

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

A fixed point is reached when a stage's emitted C is byte-identical to the
canonical: the compiler is now reproducing itself exactly. Because the same
property must hold at every stage and not only the first, `verify_seed.py`
asserts the emitted C of `seed2`, `chain2` **and** `chain3` against the
canonical. A chain that converges at stage one and drifts afterwards is a real
failure mode, and a gate that only compares the first stage cannot see it.

## What each stage does

1. `scripts/amalgamate.py` inlines the project-local `#include "..."` graph
   reachable from `compiler/selfhost/stage3.exe.c` into one self-contained C
   file, each inlined file wrapped in its own include guard. System includes
   are left alone.
2. A C compiler turns that amalgamation into `seed`, with `-DORBIT_WITH_EXEC`
   so the compiler can spawn its own `cc`. This is the only step that needs
   anything beyond a C compiler and Python.
3. `seed build compiler/main.orb` runs the front end (lexer, parser, resolver,
   sema, builder, optimizer, compile-time evaluation) and the C backend,
   writes one intermediate C file, and invokes `cc` on it. The intermediate
   file always has the same name, because compilers embed the source path in
   the binary and a per-stage name would break byte-comparability for
   identical code.
4. `verify_seed.py` recompiles that intermediate C itself with known-good
   flags, and compares the emitted C bytes against the canonical.

## Promotion between stages

1. **canonical -> seed**: the canonical C must compile with any conforming C
   compiler. Nothing about Orbit is involved yet.
2. **seed -> seed2**: `seed` must parse, typecheck, lower and emit C for
   `compiler/main.orb`, and that C must be byte-identical to the canonical.
3. **seed2 -> chain2 -> chain3**: each stage must rebuild the compiler without
   any host toolchain, and each stage's emitted C must equal the canonical.

## The current state

The chain converges and every stage's emitted C equals the canonical:

```
98a6db81a6326817ea72c51739a186155f2e8e44d5f19ceb0c35696861cb01a0
```

Getting here required fixing the seed's local-variable type inference:
unknown-typed values such as list elements are typed `uintptr_t`, so pointers
are not truncated through the 32-bit `orbit_int`. Before that, the seed
crashed in `resolveModuleAST` with an access violation on the canonical route
syntax and on every parse error.

## Two things that will bite you

**Do not let the intermediate C land in the working directory.** It is several
megabytes, two concurrent builds in one directory race on it, and it litters a
user's checkout. `compiler/pipeline.orb` resolves the temp directory from
`TEMP` and `TMPDIR`.

**Do not promote to "make the gate green".** A promote replaces the root of
trust. If the sources and the canonical disagree, the sources are wrong until
someone has decided they are not. See
[Sovereignty](SOVEREIGNTY.md) for the recovery runbook.

## Verifying by hand

```sh
python scripts/build_selfhost.py --cc gcc --check-stale
python scripts/verify_seed.py --cc gcc
python scripts/parity_selfhost.py --cc gcc --compiler /path/to/fixed_point
```

The first converges and checks for staleness, the second runs the chain in a
hermetic directory and asserts all four checks, the third compiles 32 probes
and compares them to the committed goldens.
