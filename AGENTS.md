# AGENTS.md

Orbit is a self-hosted language compiler; the checkers, codegen and runtime are in `compiler/` (Orbit sources) and `runtime/` (C). If a gate's claim conflicts with this file, trust the gate.

## Build the compiler

```bash
# fresh entry point; produces a compiler binary compiling .orb -> C -> native
python3 scripts/build_selfhost.py --cc gcc --out /tmp/fp
chmod +x /tmp/fp
```

`scripts/verify_seed.py --cc gcc --emit-fixed-point /tmp/fixed_point` builds the hermetic fixed-point compiler from the committed canonical `compiler/selfhost/stage3.exe.c`. Use that binary for every gate. Set `ORBIT_CCACHE_DIR` to a scratch dir (cached .o make bootstraps cheap), otherwise a runnable fp disappears when /tmp is cleaned.

## Verification gates (all local, all required)

`scripts/dev.py` is the entry point. It owns `TEMP`/`TMP`, `ORBIT_CCACHE_DIR`, the fixed-point binary and its freshness stamp, and each gate's flags -- all four used to be tribal knowledge. Do not export those variables by hand and do not pass `--cc`/`--compiler` by hand.

```bash
make dev      # gates proportionate to what the working tree touched (default)
make check    # T0..T2 unconditionally
make all      # T0..T3, including the root of trust
make fp       # just the fixed-point compiler, and print its version
make list     # show what dev would run, without running it
```

`dev` reads `git diff --name-only` and picks a tier, erring toward running more: `tests/`, `compiler/`, `std/` or `runtime/` implies T2, `scripts/` or `examples/` implies T1, `docs/` implies nothing beyond fmt. An edit to a test needs the suite, so `tests/` is T2 rather than T1. **A green `make dev` is not a green CI**, and `dev.py` prints the tiers it skipped. For a rule change or anything touching `compiler/*.orb`, that is `make check`; before a commit that promotes the canonical, `make all`.

Note that `make all` covers the Python gates only. CI additionally runs the runtime C tests, the Kynx live gate, `routes_probe.py`, the census, `diff_fuzz.py` and the gate self-tests, and still carries its own inline copy of the sequence -- see DX-1 in `ENGINEERING.md` §7.

Useful when something breaks:

```bash
python scripts/doctor_gate.py --compiler "$(make -s fp >/dev/null && echo /tmp/orbit-fp-*)"
```

If you need the raw commands, they are listed with their rationale in `ENGINEERING.md` §8. Do not copy them from there; that is the drift this script exists to end.

## Replace-the-world rule

The committed canonical is `compiler/selfhost/stage3.exe.c`, and `scripts/verify_seed.py` asserts it reproduces itself. Never hand-edit it or any golden. After changing compiler sources:

```bash
python3 scripts/build_selfhost.py --cc gcc --promote      # rewrites canonical C + PUBLISHED_C
python3 scripts/verify_seed.py --cc gcc --emit-fixed-point /tmp/fp # sanity
python3 scripts/parity_selfhost.py --cc gcc --compiler /tmp/fp --update   # ONLY if the diff is intended
```

Commit canonical + refreshed goldens + sources + `scripts/verify_seed.py` (PUBLISHED_C) together.

## Non-obvious constraints

- Cross-file names in compiler sources are closed: `route_runtime.orb` cannot name `IRValue`/`IRGlobal`/`IRGlobal` from `ir.orb`, and callers in `c_backend.orb` can call `route_runtime.orb`'s public fns but not vice versa. Types/IR helpers live where the module closure sees them.
- `parseTypeName` is the one place that parses types: let it widen a grammar (e.g. `list<T>`) there, not ad-hoc readers. It also recurses so `map<k, list<v>>` works.
- String slicing is `orbit_string_slice(s, start, end)` — end is exclusive/indexed. Every "off-by-one in slice" we've had came from reading the third arg as a length.
- `listKinds` in the builder is a name-keyed FLAT registry: two functions both with a param named `l` collide. It is restored per scope via `listKindMarks`; do not bypass `recordListKind`.
- `var` or `const` at file scope is an error (E1007). Top-level `val NAME = <int|bool lit>` is a global `#define`; it is emitted by `generateRoutePreamble`, not by route_runtime.
- Test files the C gates do not like: `tests/negative/*.orb` are intentionally broken; every case pins `// expect-error: <substring>` (or `// known-defect: F-000N`), and the gate asserts the pinned text. Do not fmt them.
- New files under `tests/suite/` MUST be `fmt`-clean: CI runs `fmt --check` on the directory and fails the whole job on one unformatted file (bit us twice).
- `diff_fuzz.py` disagreements limit to runtime reference vs orbit canonical; C changes that alter generated text only change hashes in `tests/parity/golden/*` — regenerate with `--update` deliberately.

## Style / workflow

- Preserve existing shapes: 4-space, no `var` vs `val` concessions; comments explain why code is like this, not what the code says. No new comments unless they say something the code cannot.
- Changes to the emitted C need the "diff the whole prelude/program" eldritch check: track one program byte-for-byte; only expected fragments (one register renumber, one removed line) should differ.
- `gh` is the source of truth for CI state: `gh run list --limit 3; gh run view <id> --log` for the failing step's name. The failing step name is the finding; the step text is often as enough.
- Register-name number shifts (`r_N`) in emitted C are benign renumbering; hash goldens will still flip, which is one probe, not a proof.
