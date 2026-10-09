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

**If a gate fails only on windows-latest, read [docs/WINDOWS.md](docs/WINDOWS.md) first.** It has the two open Windows gates, how to reproduce them, what has already been ruled out, and what is NOT open -- the `0xC0000005` in `test_migrations` is fixed and the runtime C tests are green on both platforms. Those two failures are recorded as DX-1(7) in `ENGINEERING.md` §7 and they are not diagnosed.

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

**Do not read the canonical's diff, read `make promote-diff` instead.** It is regenerated whole, so it renumbers registers and a two-line change to `doctor.orb` shows up as tens of thousands of changed lines. Measured: 37 of the last 60 commits touch it, and the source-to-artifact ratio in four of them is 23 -> 24 286, 34 -> 1 612, 44 -> 4 674 and 310 -> 21 004.

After `make promote` and before committing, run it. It diffs the canonical against `HEAD` with `r_N` and `label_N` flattened to `r` and `label` -- the only two generated-name families in 4.7 MB -- and reports the raw line count, the count after flattening, the hunks, and the functions they land in. On the commit that removed the phantom `ParamNode`, that is 24 342 lines raw against **40** after flattening, in 9 hunks across 3 functions. The same flattening is applied by hand in the STAB-3 entry of `ENGINEERING.md`, which is where the technique came from.

So review the `.orb` diff, the commit's evidence block, and `make promote-diff` -- three things, all readable. Treat the canonical itself as the mechanical artifact it is and check only its hash.

## Enforced, not remembered

These are gates. Do not perform them by hand and do not write them out as a habit:

- `fmt --check` runs over the whole `compiler/` and `tests/suite/` directories, not the files you touched. Stricter than necessary is free; looser than CI costs a red.
- `tests/negative/*.orb` must FAIL to compile with the text their header pins. A `known-defect:` asserts the bug is STILL there, so a fix makes the gate red until you re-declare the case as `expect-error:` with the diagnostic you measured, never from memory. See `tests/negative/README.md`.
- `alive_check` (D8) requires every file in `scripts/` to be able to fail. A new script with no row there is the same class of thing as a gate nobody reads.
- `unknown_ratchet` fails only when the number goes UP. Raising a baseline is a deliberate act and `--write-baseline` refuses to move it up without `--allow-regression`.
- `schema_conformance.py` and `walk_coverage.py` run in T0, cost about a second, and need no compiler. They check `compiler/ast.orb` against the code that builds nodes, and require every AST walk to declare the fields it skips.

## Working with other agents

**One writer of the root of trust at a time.** `compiler/selfhost/stage3.exe.c` and `PUBLISHED_C` in `scripts/verify_seed.py` are one logical file in two copies, and the canonical must reproduce itself bit for bit. Two concurrent promotes produce a canonical that half the tree does not describe, and `verify_seed` reports it as "sources moved on" without saying whose. This is not a merge conflict: the merge is clean and the result is wrong. 37 of the last 60 commits touch the canonical, so this is not a rare path. Before promoting, check who had it last:

```bash
git log -1 --format='%h %ad %s' --date=short -- compiler/selfhost/stage3.exe.c
```

If that is within the hour, it is not yours yet. Ask.

What may run in parallel, and why:

| Zone | Parallel | Reason |
|---|---|---|
| `compiler/*.orb`, promoting | **no** | the canonical is global |
| `compiler/*.orb`, not promoting | yes, in separate worktrees | `verify_seed` only judges what is committed; nothing looks at an uncommitted tree |
| `tests/suite/<new>.orb`, `tests/negative/<new>.orb` | yes | additive; the shared thing is a count a gate reads |
| `tests/doctor/golden/d0NN_*` for different checks | yes | the real collision is an existing check's `expected.txt` |
| `runtime/*.c` | yes, carefully | the CI step compiles them by filename, so a shared `-D` is a shared change |
| `docs/*.md` | yes, different files | |
| `scripts/*.py` | yes, with one condition | a new script arrives with its `alive_check` row in the same commit |
| `ENGINEERING.md` §7/§8, `AGENTS.md` | **no** | they are contracts; two agents editing the debt table step on each other |

Use `git worktree` for two agents editing `compiler/*.orb` at once. The merge point is a commit, which is where `verify_seed` has something to say again. Without it, whichever agent promotes deletes the other's working binary.

## The read-only reviewer

A reviewer edits nothing. It edits its answer, and the answer obliges the author to redo the work.

It reads the diff of the sources (`.orb`, `.c`, `.py`), the goldens the commit added or moved, and the commit body including its evidence block -- if a gate count in the body differs from what the gate prints, that is the finding.

It runs `make check`. It does not promote and does not `--update` a golden: a reviewer that promotes has made the change and is no longer a second pair of eyes.

Three questions:

1. Does it fire in the case the golden claims? A new check needs a positive AND a negative golden in the same commit; one positive proves only that it can shout.
2. Is it silent on the negative?
3. Does it survive `fmt` and the battery?

A NO to any of the three means redo, with no argument about whether the case "should" fire -- that is exactly the question. If the reviewer finds a defect in a different file, it does not fix it; it writes it up as separate work. If it cannot run the gates, it says so and does not sign.

## When to stop and hand back

Stop and ask rather than push on, when:

- **A ratchet turns green.** That is good news: you fixed something recorded as broken. Re-declare the header with the diagnostic you measured and move the program to `tests/suite/` if it is no longer a defect.
- **`ENGINEERING.md` §7 says something your change contradicts.** The debt table is the contract. Update it in the same commit, or ask first. Do not leave it lying to keep your diff smaller.
- **`verify_seed` fails after your `--promote`.** The sources do not converge to the canonical. Do not hand-edit the canonical to make it pass.
- **A gate you did not run comes back red.** `gh run list --limit 3`, then `gh run view <id> --log`, and the STEP NAME is the finding. If it is not yours, do not fix it.
- **You are about to do "one more thing" in the same place.** Every class of bug found here is the same loop: fixing A revealed B, fixing B revealed C. One commit is one defect. When you want to open the second, stop.

## Non-obvious constraints

- Cross-file names in compiler sources are closed: `route_runtime.orb` cannot name `IRValue`/`IRGlobal`/`IRGlobal` from `ir.orb`, and callers in `c_backend.orb` can call `route_runtime.orb`'s public fns but not vice versa. Types/IR helpers live where the module closure sees them. Widening that is not a style change, it is a change to what can be called from where, and the compiler compiles itself under the same rule.
- `parseTypeName` is the one place that parses types: let it widen a grammar (e.g. `list<T>`) there, not ad-hoc readers. It also recurses so `map<k, list<v>>` works.
- String slicing is `orbit_string_slice(s, start, end)` — end is exclusive/indexed. Every "off-by-one in slice" we've had came from reading the third arg as a length.
- `listKinds` in the builder is a name-keyed FLAT registry: two functions both with a param named `l` collide. It is restored per scope via `listKindMarks`; do not bypass `recordListKind`.
- `var` or `const` at file scope is an error (E1007), because a module-level `var` would be shared mutable state and the language has none that works. Top-level `val NAME = <int|bool lit>` is a global `#define`; it is emitted by `generateRoutePreamble`, not by route_runtime.
- Test files the C gates do not like: `tests/negative/*.orb` are intentionally broken; every case pins `// expect-error: <substring>` (or `// known-defect: F-000N`), and the gate asserts the pinned text. Do not fmt them.
- New files under `tests/suite/` MUST be `fmt`-clean: CI runs `fmt --check` on the directory and fails the whole job on one unformatted file (bit us twice).
- `diff_fuzz.py` disagreements limit to runtime reference vs orbit canonical; C changes that alter generated text only change hashes in `tests/parity/golden/*` — regenerate with `--update` deliberately.

## Style / workflow

- Preserve existing shapes: 4-space, no `var` vs `val` concessions; comments explain why code is like this, not what the code says. No new comments unless they say something the code cannot.
- Changes to the emitted C need the "diff the whole prelude/program" eldritch check: track one program byte-for-byte; only expected fragments (one register renumber, one removed line) should differ.
- `gh` is the source of truth for CI state: `gh run list --limit 3; gh run view <id> --log` for the failing step's name. The failing step name is the finding; the step text is often as enough.
- Register-name number shifts (`r_N`) in emitted C are benign renumbering; hash goldens will still flip, which is one probe, not a proof.
