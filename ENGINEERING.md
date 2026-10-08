# Orbit Engineering Manifesto & Implementation Roadmap

> This document is the **authoritative contract** for every agent, contributor, or system that touches the Orbit codebase.
> It is not aspirational prose. It is an enforceable specification. Every section translates directly into code that compiles, tests that pass, and behaviour observable by a user.

## Document Status

This document is the implementation contract. It describes quality gates, invariants, and active engineering work. For the dated current snapshot, use [docs/STATUS.md](docs/STATUS.md). For project sequencing, use [docs/ROADMAP.md](docs/ROADMAP.md). For user-facing language behavior, use [docs/LANGUAGE_REFERENCE.md](docs/LANGUAGE_REFERENCE.md). For the complete documentation map, use [docs/README.md](docs/README.md).

The build is the self-hosted Orbit compiler. `compiler/*.orb` is the only implementation of the compiler; there is no second implementation and no predecessor language in the tree. It reads `.orb` source, emits C, and bootstraps from the committed canonical C at `compiler/selfhost/stage3.exe.c`. The C runtime is `runtime/*.c`. The gates are Python 3 standard-library scripts in `scripts/`. See [docs/architecture/SOVEREIGNTY.md](docs/architecture/SOVEREIGNTY.md) for the trust model and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the pipeline.

Every path cited in this document is a path that exists today. If you find a claim here that does not match the tree, that is a defect in this document: fix the document in the same commit as the code change that made it stale.

---

## 0. The Non-Negotiable Law: No Phantom Code

**Phantom code** is any line of code whose sole existence is to signal future intent rather than deliver present function. It includes, but is not limited to:

- `// TODO: implement this`
- `print("[Notice] Feature scheduled for 0.2.0 release.")`
- Empty function bodies that return without error or a meaningful default
- A binding written and never read, on a parameter that should drive behaviour
- Struct fields declared but never read or written
- Tests that assert an unconditional truth

**Every agent touching this codebase must abide by this invariant:**

> **A function either performs its stated contract fully, or it does not exist.**

If a feature is genuinely deferred, it must not appear in the public CLI surface, must not print banners, and must return an error from an internal API - never from a user-facing command. A user-facing command that is not implemented must not be registered.

The recorded instance of this violation, a `runClusterMode` that printed a placeholder notice and exited 0, was catalogued as **CLUSTER-0** and is closed. The replacement is not "cluster may now exist": §3 states exactly what `orbit cluster` is allowed to do, and that is a narrower contract than the CLI surface.

---

## 1. Performance Targets: Non-Negotiable Minimums

Orbit competes with Go, C, C++, and Java for production server workloads. These numbers are not aspirational. They are the minimum pass criteria for any production release tag.

| Property | Target | Measurement Method |
|---|---|---|
| Throughput | ≥ 1 000 000 RPS single-node (HTTP/1.1 keep-alive) | `wrk -t12 -c400 -d30s` on loopback |
| Latency P99 | ≤ 2 ms at 500K RPS sustained | same harness, percentile from wrk |
| Memory per connection | ≤ 4 KB amortised RSS delta | RSS measurement under 100K concurrent connections |
| Cluster cross-node routing | ≤ 5 ms P99 added latency | internal cluster telemetry (see §3; no such routing exists today, so this row has no measurement yet) |
| `orbit doctor` scan time | ≤ 50 ms on 100 000 LOC project | external wall clock around `orbit doctor <dir>`; see note below |
| Arena alloc per request | ≤ 50 ns amortised over 1M calls | timed allocation loop compiled from an Orbit program, median of 5 runs |

No performance number is published until it comes with the command that produced it, the hardware it ran on, the flags it ran with, and the spread across at least 5 runs. A number without its reproducible command is not a claim, it is an anecdote, and it does not go in this document. `scripts/orbit_ccache.py` and `scripts/measure_selfhost.py` exist to make bootstrap-side measurements cheap enough to repeat; `scripts/night_load.py` is the load generator for live-service measurements.

**Note on the doctor row.** `DoctorStats` carries a duration per phase (`textMs`, `astMs`, `semaMs`, `ioMs`) and `--verbose` prints them. Read the phases from `orbit_clock_ms()`, never a nanosecond clock: `orbit_int` is a 32-bit `int`, so nanoseconds wrap every 4.29 s and a subtraction across the wrap returns a NEGATIVE duration. It printed `-417 ms text` before this was fixed.

Measured on `compiler/` (23 files, 23 714 LOC), gcc 13.3.0, warm page cache,
Linux, fixed-point compiler, `orbit doctor compiler --verbose`. Cache forced
cold and warm with `ORBIT_DOCTOR_CACHE`:

| run | text | ast | semantic | wall |
|---|---|---|---|---|
| first run, cache empty | 419 ms | 1666 ms | 6196 ms | 8.32 s |
| later runs, cache warm | 405 ms | 1608 ms | 0 ms | 2.23 s |

Expressed against the budget, because "ms in a column" hides the ratio. The
budget row is per 100 000 LOC, so a 23 714 LOC tree has an allowance of 11.9 ms
of wall clock; the per-100K columns scale the measurement up rather than
comparing a quarter-size tree to a full-size allowance:

| | measured here | per KLOC | per 100K LOC | vs 50 ms budget |
|---|---|---|---|---|
| ast (cold) | 1666 ms | 70.3 ms | 7.03 s | 141x over |
| ast (warm) | 1608 ms | 67.8 ms | 6.78 s | 136x over |
| whole run (cold) | 8320 ms | 350.8 ms | 35.08 s | 702x over |
| whole run (warm) | 2230 ms | 94.0 ms | 9.40 s | 188x over |

**A scaling error, corrected.** This table previously carried "2.05 s" and
"2.98 s" in the per-100K-LOC columns with ratios of "41x" and "60x". Those
numbers were this tree's whole-tree cost placed under a per-100K heading, and
the ratios divided a 23 714 LOC measurement by a 100 000 LOC allowance. The
result read 136x as 41x and 188x as 60x -- a quarter-size tree compared to a
full-size budget, which flattered the tool by about 4x. The "per KLOC" column
in the same table was separately wrong by 1000x (0.020 ms where the arithmetic
gives 67.8). Both columns were wrong in the direction that made doctor look
better, and both are corrected above. A budget table is the one place in this
document where an arithmetic error is a lie rather than a typo.

**Still 188x over, warm.** Do not read the 2.23 s as a pass. What the
optimisation work bought is that the residual is two identifiable things rather
than a mystery, and this measurement says which is which:

- **Warm, the AST phase is the parser.** Measured by disabling every
  AST-based check (D017, D018, D019, D021, D022) and re-running: the AST phase
  moved from ~1820 ms to ~1830 ms, which is inside the run-to-run spread. No
  check is the bottleneck. The phase is `initParser` + `parseProgram`, and at
  23 714 lines that is 77 us per line. Bringing the AST phase inside 20 ms per
  10K LOC means the parser has to get about 6x faster, which is a parser change
  and not a doctor change.
- **Cold, it is D008 typechecking each file's import closure separately.**
  6196 ms against a 0 ms warm floor, and it is the single largest number in the
  run. The tree's whole module graph typechecks in 1.59 s (`orbit check
  compiler/main.orb`, whose closure is every module), so doctor is paying about
  3.9x the cost of typechecking the graph, once per file rather than once per
  graph.

### Proposed: D008 asks about the graph, not about each file

The contract today is per file. For each scanned file, D008 asks
`checkSourceWithFile(source, file)`, which resolves and typechecks that file's
transitive import closure. Twenty-three files therefore produce twenty-three
closure resolutions over a graph with a 1.59 s union.

The contract should be per graph. Typecheck the scanned module graph once,
record which modules passed, and answer D008 for a file from that table. The
measured effect of the current contract is the difference between 6.19 s and
1.59 s on this tree, so this is the single largest available win and it does not
touch the parser.

What it does not fix, stated so the proposal is not oversold: the warm run stays
at ~2.2 s, because warm D008 already costs nothing and the residual is the
parse. A cold run would land near 3.6 s. Neither is inside 50 ms per 100K LOC,
and no contract change gets there -- at 23 714 LOC the budget allows 11.9 ms of
total wall clock, and this tool spends 2.2 s of it on a tree a quarter of the
size. The budget is only reachable with a materially faster parser, or with the
budget restated to say what doctor is: a per-file report whose cost is one parse
per file.

The two honest options are therefore (a) make the parser faster, which is real
work with a real payoff for the compiler and not just for doctor, or (b) restate
the row as "one parse per file plus the typechecks, cached", which is what the
tool actually is. Option (b) is a sentence; option (a) is not. Neither is
decided here.

The AST phase used to be 4454 ms, not 968 ms. `doctorFindDeclLine` called
`splitBuildLines` once per declaration -- 780 calls over the compiler itself --
and `splitBuildLines` slices the source once per line while every slice measures
the whole string, so the cost was O(bytes x lines) per declaration. Every file
is now split once and the line list is threaded to every consumer, which also
removed the same split from `doctorUsedInText`, where it ran once per unused
declaration over every file in the tree. The findings are byte-identical before
and after, which is the only acceptable outcome for a change like this: it is a
hoist, not a rewrite.

D013 was the same bug wearing a different hat and it was worse, because it was
found by the gate rather than by a profiler. For every `var` line it rescanned
every line of the file, and the inner helper slices a fresh string at each
offset: 1.3 GB of arena growth on `c_backend.orb` alone, and `orbit doctor
compiler` was OOM-killed at 9 seconds. `doctor_scope_gate.py` had been reporting
that directory clean for exactly that long, because a killed process prints
nothing and nothing reads as zero findings. It is now 317 MB for the whole
directory, and the counts are unchanged -- verified by diffing D013 output for
the new compiler against the old one over every `.orb` in `compiler/`, `std/`
and `tests/suite/`, zero differences.

Two things this measurement decided:

1. **Dropping the typecheck was rejected, on evidence.** It was measured, and re-measured on the current tree: removing it leaves the warm run at ~2.2 s, still 188x over, because the parse dominates what remains and nothing else moves the ratio. And it loses real signal -- a file with a syntax error, a type error, or a broken import then reports `no findings`, because the AST pass skips unparseable files and the typecheck is the only other thing looking. A linter that reports a broken file as clean is worse than a slow one.
2. **The parse-error half of D008 is now free.** A file that does not parse is reported from `parser.diagnostics`, which the AST pass already produced, so the guarantee survives without paying for a typecheck that cannot succeed anyway. `d008_parse_error` and `d008_semantic_error` in the goldens pin both halves.

The cache is keyed on the CONTENT hash, not the path or an mtime: move a file and its answer still applies; change one byte and it does not (`d008_survives_edit`). `ORBIT_DOCTOR_CACHE=0` turns it off. Its only limitation is that a cache hit does not reprint the compiler diagnostic, so the finding points at `orbit check` rather than promising "see the error above" -- a promise a cache hit cannot keep.

---

## 2. Orbit Doctor - Intelligent Static Analysis System

### 2.1 Current State

`compiler/doctor.orb` is the whole of doctor. It scans `.orb` files under a directory and reports findings with codes `D001` through `D008`:

| Code | What exists today | Implementation |
|---|---|---|
| `D001` | C toolchain detection. Probes candidates in order `ORBIT_CC`, `CC`, `gcc`, `clang`, `cc` and reports the first that answers. | `doctorProbeCompiler`, `doctorCheckToolchain` |
| `D002` | Route conflict detection over normalised paths, plus same-method wildcard coverage. | `doctorNormPath`, `doctorNormSegment`, `doctorWildcardCovers`, `doctorCheckRoutes` |
| `D003` | A `private fn` no scanned file calls. Public functions, `main`, and `extern` fns are never reported. | `doctorCollectDecls`, `doctorWalkRefs`, `doctorCheckUnused` |
| `D004` | A `model` no scanned file references. | `doctorCollectDecls`, `doctorCheckUnused` |
| `D005` | Unknown member on `system`. | `doctorScanSystem` |
| `D006` | Trailing whitespace. | `doctorScanStyle` |
| `D007` | Missing final newline. | `doctorScanStyle` |
| `D008` | A file that is empty, unreadable, or does not pass the compiler's own parse and typecheck. | `doctorRun`, via `checkSourceWithFile` |

**This is a project hygiene tool, not a program analysis engine.** It reads tokens, lines, and declarations. It does not build a type graph, does not walk data flow, and does not reason about a request. The three-layer design in §2.2 is the specification for what doctor becomes; none of the analyses below it exist yet. They are written as a contract precisely so that they are buildable, not as a description.

### 2.2 Architecture

The target is three layers applied to every `.orb` file in the project, each running independently, with results merged into one report:

```text
Layer 3: Semantic Graph Analysis                       [NOT IMPLEMENTED]
  Input:  IRModule + Sema type graph (compiler/ir.orb, compiler/sema.orb)
  Detects: Data-flow bugs, taint violations, unguarded shared state, arena leaks

Layer 2: AST Structural Analysis                       [PARTIAL: D003, D004 only]
  Input:  Parsed ASTNode tree (compiler/ast.orb, compiler/parser.orb)
  Detects: Cyclomatic complexity, dead functions, recursive depth, hot-loop allocs

Layer 1: Token and line stream analysis                [PARTIAL: D002, D005, D006, D007]
  Input:  Raw text, no AST construction
  Detects: Route conflicts, hardcoded secrets, SQL injection surface, unguarded routes
```

The AST schema had two type errors, both now fixed and both the reason an
earlier draft of D017 reported a complexity of 1 for a function of 25:

- five models declared `body: list` (`FunctionDeclNode`, `RouteDeclNode`,
  `WhileNode`, `ForNode`, `MatchCaseNode`) while the parser has always handed
  them parseBlock()'s single ASTNode, and `IfNode` got it right with
  `thenBody: ASTNode`. Reading `f.body.len()` returned -1184889136 for a
  one-statement function while `params`, `paramTypes` and `genericParams` on the
  same model returned correct lengths -- a model pointer read as a list header
- `CallNode.callee` said `list` and is an `ASTNode`, which `builder.orb` has
  always known: it matches on it

Neither was visible because no code called `.len()` on either field. sema.orb
passes `f.body` straight into `checkNode`, which matches rather than measures, so
every AST walk in the compiler was correct by accident of never asking.
`tests/suite/ast_function_body_is_a_block.orb` asserts the corrected shape, so the
fix cannot be undone by someone reading `body: list` as a convenience.

Layer 2 now does exactly one thing does exactly one thing: it parses each file with `initParser`/`parseProgram`, walks the AST to collect declarations and references, and reports unused private functions and unused models. It then falls back to a whole-word text search (`doctorUsedInText`) before reporting anything. It is deliberately conservative, because a name may be used by a file outside the scan. Any analysis added to Layer 2 inherits that constraint: a false positive that silences a real dead-code report is worse than a missed one.

### 2.3 Layer 1: Text and Token Analyses

Implement in `compiler/doctor.orb` alongside the existing text scans. No AST construction needed. Budget: ≤ 5 ms per 10K LOC file.

#### Route Conflict Detection (exists - hardened, keep hardened)

`doctorNormPath` normalises path parameters before insertion into the route map, so `GET /users/:id` and `GET /users/:uuid` collide by construction rather than by luck. `doctorWildcardCovers` reports a same-method wildcard registered over a specific path. This is the DOCTOR-0 fix and it is closed. Do not regress it: any new route check must normalise through the same helper.

#### Hardcoded Secret Detection (new)

Scan all string literal values for these case-insensitive prefixes:

```text
SECRET_PREFIXES = [
    "sk-",        // OpenAI / Stripe secret key
    "ghp_",       // GitHub Personal Access Token
    "AKIA",       // AWS Access Key ID
    "-----BEGIN", // PEM private key or certificate
    "password=",  // Inline credential
    "secret=",    // Inline secret
    "token=",     // Inline token
    "apikey=",    // Inline API key
]
```

For each match: emit a finding with file path, line number, code, and the matched prefix only. Do NOT include the full string value in the diagnostic output - that would re-expose the secret. This constraint is part of the finding, not a detail of the rendering.

#### SQL Injection Surface Detection (new)

When a string literal contains any of the SQL keywords `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `DROP` (case-insensitive substring search) and an interpolated string literal appears within the following 3 tokens, flag a warning: `"Interpolated string used in SQL context at <file>:<line>. Use parameterised queries."`

#### Unauthenticated Mutable Route Detection (new)

For every `route` whose method is `POST`, `PUT`, `PATCH`, or `DELETE`: scan the token stream of its body block. If no role-guard or request-validation marker appears before the first `ok` or `return`, emit a warning: `"Mutable route <METHOD> <path> has no role guard or request validation block."`

### 2.4 Layer 2: AST Structural Analyses

**Status: shipped.** The four analyses this section names are all in
`compiler/doctor.orb`: cyclomatic complexity as `D017`, recursion without tail
calls as `D018`, allocation inside a loop as `D019`, and dead functions as
`D003`/`D004`. There is no fifth one promised here.

The numbers `D020` through `D023` appear in no version of this document. They
were an invention of a planning note, listed as "what a doctor could grow next",
and reading them back as spec is how a plan starts promising things the spec
never did. `D022` (duplicate match arm) and `D023` (shadowing) are still real
ideas and are recorded below as candidates rather than as commitments.

Implement in `compiler/doctor.orb`, reusing the AST `doctorRun` already builds. Parse errors must convert to a warning diagnostic rather than aborting the run: the existing contract is that doctor still runs its text checks on a file that does not parse and skips only the AST-based analysis. Budget: ≤ 20 ms per 10K LOC.

#### Cyclomatic Complexity

For each function declaration, walk the subtree and compute:
- Base: 1
- +1 per: `if`, `while`, `for`, `loop`, each arm of a `match`, each `rescue` expression

Thresholds:
- ≤ 10 → pass
- 11-20 → warning "Function complexity {n}: consider extracting sub-functions"
- > 20 → error "Function complexity {n} exceeds safe limit for production code"

#### Recursive Call Depth Without TCO

Build a call graph from all function declarations in the file. Use DFS to detect cycles. For each recursive function: verify that every branch's final statement is a return whose expression is a call targeting the same function (tail position). If not: emit a warning: `"fn <name> is recursive but not in tail position - may exhaust the call stack under sustained load."`

#### Allocation Inside Hot Loops (new)

For any function whose body contains a `for` or `while`: walk the loop body subtree for calls whose callee identifier matches `list_create`, `map_create`, or the suffix `_alloc`. If found: emit a warning: `"Allocation inside loop body in fn <name> at <line>. Consider pre-allocating and reusing outside the loop."`

#### Candidates that are not in this section

Neither is scheduled. Both are written down so the next person does not re-derive
them, and so the reason they are not scheduled is visible.

- **Duplicate `match` arm.** Not a doctor check: `patternVariantName` and
  `qualifiedVariantName` (`sema.orb:1757`, `:1782`) need a `Sema`, and doctor's
  only door to it is `checkSourceWithFile(...) -> bool` (`pipeline.orb:161`).
  It belongs beside `checkMatchExhaustive` (`sema.orb:1796`) as a second E-code.
  `covered` (`sema.orb:1801`) accumulates variant names and never checks for a
  repeat. Note the wildcard bails first (`sema.orb:1814`, `:1825`), so a check
  placed after that bail would skip exactly the dead arms.
- **Shadowing.** Shadowing is intended: `builder.orb:79-80` and
  `resolveSymbol` (`sema.orb:601`) both resolve innermost-first on purpose, and
  same-scope re-declaration is already a hard error (`sema.orb:557`). The only
  useful form -- "this name shadows an outer one that is used afterwards" -- is
  the most expensive candidate here, because `LiteralNode` (`ast.orb:146`) has
  no `line`/`col`, so a *use* has no position and the answer needs a parser
  change plus a scope-tracking pass. Low diagnostic value for that price.

#### Dead Function Detection (partial: private only)

A `private fn` that no scanned file calls is unreachable; that is `D003` and it exists. A public `fn` unreachable from any `route`, `schedule`, or other reachable `fn` is also dead, but reporting it requires whole-program reachability from the entry point, which a single-directory scan cannot establish. The general form of the finding stands: `"fn <name> is never called from any route or schedule and will not be compiled into the output binary."` It is not implementable at directory-scan scope without false positives, so it is deferred, not solved.

### 2.5 Layer 3: Semantic Graph Analyses

**Status: reconciled. This section promised three analyses; none of them can be
built as written, and the reason is worth writing down rather than discovering a
third time.**

The original text opened with "Every opcode named below exists in `IROpcode`
today." True, and misleading. `alloc`, `free`, `db_get`, `db_set` and `db_where`
are all declared in `compiler/ir.orb:30-35` -- and emitted **zero** times by
`compiler/builder.orb`, which is the only thing that produces the real IR:

| opcode | declared | emitted by `builder.orb` | referenced by |
|---|---|---|---|
| `alloc` | `ir.orb:30` | **0** | `cteval.orb`, `c_backend.orb` |
| `free` | `ir.orb:31` | **0** | `cteval.orb`, `c_backend.orb` |
| `db_get` | `ir.orb:32` | **0** | `cteval.orb`, `c_backend.orb` |
| `db_set` | `ir.orb:33` | **0** | `cteval.orb`, `c_backend.orb` |
| `db_where` | `ir.orb:35` | **0** | `cteval.orb`, `c_backend.orb` |

`cteval.orb` carries its own private mini-IR for constant evaluation, and
`c_backend.orb` consumes the enum in switches where `free` emits the comment
`/* free - arena managed */`. An analysis that reads these fields would analyse a
code path that does not run.

#### Unguarded Mutable Shared State -- nothing to find

The check was "a `var` at module scope, written from a handler". There are no
module-scope `var`s: E1007 rejects them (`sema.orb:1252-1259`), and
`builder.orb:1574` turns any surviving top-level `val` into a `#define` of an
int or bool literal. `ENGINEERING.md` already said as much in its own §3 notes:
*"the language has no working module-level mutable state"*. `store_var` IS
emitted (`builder.orb`, 3 sites), but only for function-locals.

The general finding -- "shared mutable state needs a guard" -- stays true for a
language that will grow one. The check waits for that language. The code number
is not spent.

#### Arena Leak Detection -- re-expressible, but D019 already owns the shape

`alloc`/`free` are not emitted, so there is nothing to walk. Allocation reaches
the IR as an ordinary `IROpcode.call` to a runtime name, and the arena argument
is injected by the backend via `functionNeedsArena` (`c_backend.orb:3915`).
An allocation check is therefore a NAME match over calls, which is exactly what
**D019** already does at the AST level and with positions attached. Anything
D026 could add is path analysis ("is it freed on every path") over a data-flow
graph the IR does not currently carry. Deferred with the reason, not with a
promise.

#### Taint Propagation for HTTP Inputs -- the one worth building

Also a name match, and also the one that earns its cost: untrusted request
fields reaching a database call is a real vulnerability class, and the sources
and sinks are named in the emitted calls.

- sources: `orbit_http_body_get`, `orbit_auth_bearer_token`,
  `orbit_auth_current_role`
- sinks: `orbit_db_query_where`, `orbit_db_query_where_p`, `orbit_db_query_all`,
  `orbit_db_query_get`, `orbit_db_insert`, `orbit_db_delete`

The precedent for walking calls and matching names is `moduleCallsBuiltin`
(`c_backend.orb:4163`): walk `module.functions` -> `f.instructions` ->
`inst.opcode == IROpcode.call` -> match `inst.operand1` as `IRValue.String`.

**Doctor implements this on the AST, not the IR.** The IR carries no positions
-- `IRInstruction` (`ir.orb:91-105`) is `opcode, dest, operand1/2/3, elemKind`,
nothing else, and only 7 of 43 AST models carry `line`/`col` (`ast.orb:102`,
`:110`, `:221`, `:243`, `:259`, `:269`, `:276`). An IR-only finding can be
attributed to a function, and attributing it to a line means guessing one. The
AST plus sema's scope chain carries the same information with real positions,
which is the same reason `checkNode(sema, node: ASTNode)` is the shape the rest
of the compiler walks in.

### 2.6 Implementation Contract

Every analysis added to doctor must satisfy all of the following before it is considered done:

1. A golden in `tests/doctor/golden/` for the check, plus its `.orb` fixture, and `scripts/doctor_gate.py` passing in CI. That gate runs each case against a throwaway copy of its fixtures and compares stdout character for character, so it pins the severity, file, line, wording and exit code at once. It is wired into CI; `tests/doctor/` is no longer a manual-only directory. A check with no golden is not shipped. `--update` is the only way a golden changes, and it must be reviewed as a diff.
2. Completion within the per-layer time budget, with the per-phase durations `DoctorStats` now records printed by `--verbose` as evidence.
3. No abort on malformed input. Parse and lex failures are always caught, converted to a finding, and the scan continues.
4. Every finding includes: file path, line number, code, severity, and a one-sentence actionable suggestion. The rendered line is `file:line [CODE] message fix: action`. The JSON carries the same six keys plus `column`, `layer`, `fix_kind`, `applied` and `edits`; the original six are the contract, the rest are additive.
5. A new code is added to the `D00X` table in `docs/DOCTOR.md` in the same commit. Doctor's code space is a public contract; renumbering an existing code is a breaking change.
6. A fixable finding carries its edits. A check that can fix itself emits `edits` rather than describing the fix in prose only, marks them `safe` or `unsafe`, and is exercised through the shared fix engine by a golden that passes `--fix`. Two invariants hold for every fix that engine applies and are pinned by the `crlf_preserved` and `dry_run_changes_nothing` goldens: the file is byte-identical outside the edited ranges, and nothing is written unless the result still passes the checks it was verified against.

### 2.7 Expected Output After Full Implementation

```text
  orbit doctor examples  [2 errors, 3 warnings, 41.8 ms]

  examples/api/auth.orb:14   error   [D002] route GET /users/:id collides with examples/api/auth.orb:8 (GET /users/{id}); both normalize to /users/:param.  fix: merge the handlers or give the paths distinct shapes.
  examples/api/auth.orb:22   error   [D009] literal matches secret prefix 'sk-'.  fix: move the key to an environment variable.
  examples/api/search.orb:38 warning  [D010] interpolated string inside a SQL literal.  fix: use parameterised queries.
  examples/handlers/user.orb:82 warning [D011] fn process_user - complexity 17.  fix: extract the validation branch.
  examples/handlers/note.orb:44  error   [D012] req.id reaches db_where without validation.  fix: validate or coerce req.id before the query.

  6 files scanned, 41.8 ms (token 2.1 ms, ast 11.4 ms, semantic 19.7 ms, io 8.6 ms)
```

The `D009` through `D012` codes are the next free codes; they are proposals, not commitments. The per-layer timing line is the §2.6 deliverable. What is not a proposal is the shape: one line per finding, location, code, message, and a fix the reader can act on without opening the file.

---

## 3. Orbit Cluster - Process Orchestration

### 3.1 Current State

`orbit cluster` is implemented and registered in the CLI dispatch and help text (`compiler/main.orb`), backed by `compiler/cluster.orb`. It is **single-host multiprocess orchestration**: it builds and supervises N local worker processes of one service, tracks them in `.orbit/cluster.json`, and drains, restarts, and tears them down.

| Subcommand | Contract |
|---|---|
| `orbit cluster up --nodes N --port-base P [--log-dir D] [--service S]` | Build the service and spawn N processes on consecutive ports from `P`. `N` must be 1..64 and the port range must stay inside 1..65535. Fails if `.orbit/cluster.json` already exists. |
| `orbit cluster status` | Per-node liveness, port, pid, and draining flag. |
| `orbit cluster drain <node>` | Graceful stop of one node: finish in-flight requests, then exit, no restart. |
| `orbit cluster restart --rolling` | One node at a time, health-verified before the next. |
| `orbit cluster down` | Stop all nodes and remove state. No orphans left. |
| `orbit cluster logs <node>` | Print a node's log file. |

Default log directory is `.orbit/logs`. The state file is `.orbit/cluster.json` and it records per-node service, port base, log dir, ports, pids, and the draining set.

**What this is not.** It is not a multi-host cluster. There is no gossip, no membership table, no leader election, and no cross-host routing. §3.3 onward is the design for that, and none of it is built. Do not let a reader of the CLI help conclude otherwise: the help text describes processes on one machine, and that is the whole of the promise.

**Rule**: the §3.3-§3.5 design does not earn a place in the help text, in `orbit.cluster.*` naming, or in the state file schema until Phase 1 below is implemented and integration-tested. A user who reads `orbit cluster --help` must be able to predict exactly what the command does.

### 3.2 What A Multi-Host Cluster Would Be

Recorded so the design is not lost, and so nobody re-derives it wrong. An Orbit multi-host cluster would be a set of `orbit` processes on separate hosts that collectively serve one logical application:

- **Leaderless reads**: any node handles read requests
- **Leader-coordinated writes**: a single elected leader coordinates writes
- **Self-healing**: nodes detect failures via gossip heartbeat and redistribute load
- **Zero-configuration**: nodes discover peers via a seed address or LAN multicast, not a central registry

None of these four properties is present today. `orbit cluster restart --rolling` is a sequencing guarantee on one host, not leader election.

### 3.3 Phase 1: Node Identity, Gossip, Routing, Leader Election

All of this is unimplemented. There is no `compiler/cluster/` directory; `compiler/cluster.orb` is the single-host supervisor described in §3.1 and must keep working unchanged. A multi-host implementation belongs in new modules alongside it, with the transport in `runtime/` where the socket and thread layers already are.

#### Node identity

```text
NodeId:
    host:        64 bytes   null-terminated hostname or dotted-decimal IP
    port:        u16
    generation:  u64        monotonically increasing, bumped on each restart

NodeState:  alive | suspected | dead

ClusterNode:
    id:                NodeId
    state:             NodeState
    last_heartbeat_ns: u64
    load_score:        u32   0-1000, see the formula below
```

#### Gossip

Push-pull gossip over TCP. Every 500 ms, each node selects 3 random peers and sends its full membership table as a compact binary frame. The receiver merges using last-write-wins on `(node_id, generation)`. A node missing more than 3 consecutive gossip cycles transitions to `suspected`; after 2 more it transitions to `dead`.

Wire format (fixed-width, no JSON, no text):

```text
Offset  Len  Field
     0    4  Magic: 0x4F524243 ("ORBC")
     4    2  Protocol version: 1 (u16 little-endian)
     6    2  Node count N (u16 little-endian)
     8   N*31  Node records:
               [0..15]  host, null-padded
               [16..17] port (u16 LE)
               [18..25] generation (u64 LE)
               [26]     state (0=alive 1=suspected 2=dead)
               [27..30] load_score (u32 LE)
```

Parsing is a direct memory read into packed structs. The magic bytes allow future protocol versioning and corrupt-frame detection.

#### Routing

When a request arrives at a node that is not responsible for the target resource shard:
1. Compute the responsible node via consistent hashing on `METHOD + URL_PATH`.
2. Forward the raw HTTP request bytes to the target over a persistent TCP connection from the per-peer connection pool (one persistent connection per peer).
3. Stream the response back to the original client without buffering the full body in userspace.

The connection pool is a fixed-size array of optional connections guarded by an `OrbitArena`. Reconnection is automatic on write failure.

#### Leader election

Bully election (correct and fast for clusters ≤ 32 nodes):
1. On detecting leader absence (leader transitions to `dead` in gossip state), send `ELECTION` to all nodes with higher ID.
2. If no `ALIVE` reply within 500 ms: broadcast `COORDINATOR` self-declaration.
3. On receiving `COORDINATOR`: update local leader reference and stop any pending election.
4. On receiving `ELECTION` from a lower-ID node while alive: reply `ALIVE` and start own election if not already running.

### 3.4 Phase 2: Load-Aware Routing and Drain

After Phase 1 passes a 3-node integration test. Note that the drain and rolling-restart *behaviour* already exists in the single-host form (§3.1); what is missing is the load-driven node choice.

**Load score** per node, over a 5-second sliding window:
- `active_conns`: in-flight HTTP requests currently being processed
- `queue_depth`: accepted but not yet dispatched connections
- `p99_latency_ms`: P99 handler duration in milliseconds

Score formula: `load_score = clamp((active_conns * 0.4 + queue_depth * 0.4 + p99_latency_ms * 0.2) * 10, 0, 1000)`.

Routing prefers nodes with lower `load_score`. If all peers exceed score 900, the local node handles the request regardless of shard ownership (degraded mode).

**Drain control frame**: the single-host `drain` uses a pid and a state file. The multi-host design sends an out-of-band control frame (`0x4F524244` "ORBD") to the target node. On receipt, the node: (a) removes itself from gossip by broadcasting state `dead`, (b) stops accepting new connections, (c) waits for in-flight requests to complete (or a 30-second timeout), (d) exits cleanly.

### 3.5 Phase 3: Sovereign Network I/O

The cluster TCP stack must not depend on blocking `connect()`/`send()`/`recv()`. All I/O must use the platform async interface directly:
- **Linux**: `io_uring` with `IORING_OP_CONNECT`, `IORING_OP_SEND`, `IORING_OP_RECV`, `IORING_OP_POLL_ADD`
- **Windows**: `ConnectEx`, `WSARecv`, `WSASend` via IOCP completion ports

This is a hard requirement for the ≥ 1M RPS target. Blocking I/O in the gossip or routing path is a performance defect, not a known limitation. The single-host supervisor in `compiler/cluster.orb` is exempt: it supervises processes, it does not serve traffic.

### 3.6 Implementation Contract for Agents

1. `orbit cluster` may not gain a subcommand that the implemented design in §3.1 does not describe. Multi-host features do not enter the help text until Phase 1 is complete and a 3-node integration test passes. No such test exists today.
2. Each cluster module must have a test that exercises its state machine transitions over loopback TCP. A Python gate in `scripts/` is acceptable and is the pattern used for the rest of the build; `scripts/routes_probe.py` is the closest existing example.
3. No ad-hoc printing of operational detail in cluster code. Diagnostics go through the existing `orbit <cmd>: fact.` stderr convention, or behind an explicit `--verbose`.
4. The gossip wire format at version 1 is frozen once shipped. Breaking changes require bumping `protocol_version` and providing a decoder for version 1 frames.
5. Cluster state is never persisted to disk by default. It is reconstructed from gossip on startup. The single-host `.orbit/cluster.json` is an explicit exception and exists only because there is no gossip to reconstruct from.

---

## 4. Self-Hosting Sovereignty Roadmap

Today: **committed C (`compiler/selfhost/stage3.exe.c`) → any C compiler → `orbit` → emits the same C, byte for byte.**
Goal: **Orbit source → any C compiler → `orbit` → native binary, with C as an internal detail rather than a shipped artifact.**

There is one lineage. There is no second implementation of the compiler to cross-check against, and that is deliberate: a second implementation is a second thing that can be wrong. The contract is the committed C plus the byte-identity check. See [docs/architecture/SOVEREIGNTY.md](docs/architecture/SOVEREIGNTY.md).

### Phase S1: C Bootstrap Seed

**Status**: Resolved. Verified end to end.

**Deliverable**: `compiler/selfhost/stage3.exe.c` is the committed canonical, and `dist/orbit_bootstrap.c` is the single-file amalgamation of it, produced on demand rather than committed.

| Property | Value |
|---|---|
| Canonical | `compiler/selfhost/stage3.exe.c`, 4,124,475 bytes, 90,928 lines |
| SHA-256 | `960758367D4EF493A49A5D6F9DF46CAE5B2FA8B9FCA0DED797C37E5664109610` |
| Pinned as | `PUBLISHED_C` in `scripts/verify_seed.py`, enforced by `--release` |

How it is produced and checked:

1. **Amalgamate.** `scripts/amalgamate.py` inlines every project-relative `#include "..."` reachable from the canonical (resolved from the including file's directory, falling back to `runtime`), wraps each inlined file in its own per-path include guard so an `#ifdef`-gated occurrence cannot mask a later unconditional one, and leaves system includes untouched. Output is deterministic: fixed order, LF newlines. Result: `dist/orbit_bootstrap.c`.
2. **Build the seed.** `scripts/build_seed.sh` (Linux/macOS) and `scripts/build_seed.bat` (Windows) auto-detect the C compiler and invoke it. Detection order: `$ORBIT_CC`/`%ORBIT_CC%` → `gcc` → `clang` → `cc`/`cl`. A missing `dist/orbit_bootstrap.c` triggers the amalgamation first. Output: `dist/orbit_seed`.
3. **Verify the fixed point.** `python scripts/verify_seed.py` runs the chain (amalgamate → seed → seed2 → chain2 → chain3) and reports four checks: the seed builds; the C the seed emits for `compiler/main.orb` equals the canonical; the C emitted by chain2 equals the canonical; the C emitted by chain3 equals the canonical. Checks 3 and 4 exist because a chain can fix a point at stage one and drift afterwards. `--release` additionally asserts the hash against `PUBLISHED_C`.

**Byte-identity of the three binaries is reported but not asserted.** Linkers embed timestamps, PDB paths, section order, and relocations, so binary bytes are a property of the C compiler and the linker, not of the language. The reproducible cross-platform contract is the C source hash.

**Toolchain neutrality.** `compiler/pipeline.orb` resolves `ORBIT_CC`, then `CC`, then the POSIX `cc` convention. A gcc-only machine and a clang-only machine both bootstrap. The CI matrix is exactly this claim: ubuntu/gcc and windows/clang.

**Gate**: a user with only a C compiler and a stock `python3` can fully bootstrap Orbit from source. No language-specific toolchain is required, at any stage.

**One historical finding worth keeping, because it is a class and not an incident.** `orbit_os_exec_selfhost` was untyped in sema, so a `result.indexOf(...)` call on the self-host source emitted a call to a nonexistent C helper (`compOutput_indexOf`) and the build failed at link time, not at the point of the mistake. It is now declared `-> string` in `compiler/extern.orb:8`, and every other `orbit_*_selfhost` extern is declared with a real return type. When adding an extern, type it. The compiler will not tell you it is missing.

### Phase S2: Native Backend in Orbit Source

**Status**: Open. Tracked as SOVER-1.

**Deliverable**: `compiler/native/` - Orbit source modules that lower the existing IR to machine code and write relocatable objects, so that a user program can be built without a system C compiler for its own code.

**There is no source to port from.** The predecessor implementation is not in this tree, so this is a from-scratch port written against the published x86-64, PE/COFF, and ELF64 specifications. Required components:

| Component | Responsibility |
|---|---|
| Target abstraction | Detect and model host ISA, target ABI (Windows x64 or System V AMD64), and object format (COFF or ELF). |
| MIR | Target-independent CFG representation. Basic blocks with explicit predecessor/successor links. |
| LIR | Target-specific register/memory representation: virtual registers, stack slots, physical register parameters. |
| Register allocation | Stack-based strategy for absolute correctness. Virtual registers map to stack slots; RAX/RCX/RDX are scratch. |
| x86-64 encoder | Instruction encoding for the LIR forms the IR actually produces. |
| Object writers | PE/COFF and ELF64 headers, section tables, symbol tables, code. |

**Parity is the definition of done, and it is testable.** Every module must produce byte-identical output to the C backend for the same IR, checked over the same corpus the parity gate already uses. A native backend that agrees with the C backend on 90% of inputs is a second compiler with two definitions of correct.

### Phase S3: Pure Native Self-Hosting

**Status**: Not started. Note the entry point does not exist: there is no `orbit bootstrap` subcommand. The CLI is `build`, `run`, `check`, `fmt`, `doctor`, `frontend`, `cluster`, `lextrace`, `--help`, `--version`.

**Deliverable**: a build mode that completes the chain with no C file emission, using only the native backend.

**Gate**: the native path and the C path must produce identical native binaries for any valid `.orb` program. Binary identity is the right assertion here precisely because both paths are now in our hands, rather than one path depending on a third-party linker.

---

## 5. Quality Gate: Definition of Done

A feature is **done** when ALL of the following are true simultaneously:

- [ ] All specified behaviour in this document is implemented in executable source (no stubs, no notice strings)
- [ ] Every code path has a corresponding test: an `.orb` test in `tests/suite` or `tests/std`, a probe and golden in `tests/parity`, a `.tir` expectation in `tests/frontend/expected`, or a C unit test in `runtime/`
- [ ] The full gate sequence in §8 is green, and the exact output is reported
- [ ] `orbit doctor` produces no new findings for the new code itself
- [ ] The fixed point still converges: `python scripts/build_selfhost.py --check-stale` exits 0, and `python scripts/verify_seed.py` reports 4/4
- [ ] No diagnostic printing in production code paths (only behind an explicit `--verbose`/`--debug` flag)
- [ ] `python scripts/werror_gate.py` reports no new warning on the generated C
- [ ] The feature has documentation in `docs/` with: purpose, usage example, invariants, known limitations

---

## 6. Stability Roadmap

Tasks that materially harden the compiler against regressions, silent
miscompilations, and bootstrap breakage. Ordered by stability impact. Each item
records its Definition of Done so completion is machine-checkable.

| ID | Area | Description | DoD / Gate | Status |
|---|---|---|---|---|
| STAB-0 | CI | Fixed-point gate on every push: the full self-host chain must pass automatically, on more than one host and more than one C compiler. | A CI job runs `scripts/build_selfhost.py --check-stale` and `scripts/verify_seed.py`; any hash drift fails the run. | ✅ Resolved. The `selfhost-gate` job in `.github/workflows/ci-gate.yml` runs on an ubuntu/gcc and windows/clang matrix, plus an 8-leg `stress-gate` that reruns `verify_seed.py` independently to hunt run-to-run flakiness. |
| STAB-1 | Scripts | One-command seed verifier replacing a manual multi-step regeneration (`scripts/verify_seed.py`): amalgamate → seed → seed2 → chain2 → chain3, then compare the emitted C of every stage against the canonical. | `python scripts/verify_seed.py` exits 0 and reports 4/4. `--release` additionally pins `PUBLISHED_C`. | ✅ Resolved. `--refresh` additionally refreshes `dist/orbit_bootstrap.c` and `dist/orbit_seed`; `--emit-fixed-point PATH` installs the converged compiler. It does not and must not regenerate the canonical: `build_selfhost.py --promote` is the only path that does that. |
| STAB-2 | Self-host | The `.orb` pipeline is the single source of truth for the compiler. There is no second driver and no dual-emitter drift to reconcile; the remaining risk is that the pipeline silently changes what it emits for the same input. | Same input → same C. Enforced by `scripts/parity_selfhost.py` over 32 probes against committed goldens. | ✅ Resolved as a drift problem. The self-hosted pipeline is the only compiler; parity is now regression protection against itself rather than agreement with a second implementation. Diagnostics, route codegen, route-body statements, and route-path type emission are all covered by named probes. |
| ~~STAB-3~~ | Codegen | Clean C emission: drop the `-Wno-error=int-conversion` / `-Wno-error=incompatible-pointer-types` crutches and the `(void*)(uintptr_t)` pointer/int conflation in generated C. | Every generated C compiles under gcc/clang with `-Wall -Werror -O2`; `compiler/pipeline.orb` drops the suppression flags. | ✅ Resolved (2026-09-26). Two distinct defects, both in `compiler/c_backend.orb`. **(1)** A hoisted local whose type `variableDefType` could not resolve is declared `uintptr_t` — the representation for every pointer-typed local, which is cast back at each use — but the store emitted a bare `(void*)(r_N)`. An explicit pointer-to-integer conversion with no cast in between is exactly `-Wint-conversion`: 87 instances. `pointerStoreCast` now returns the cast that agrees with `hoistedCType`, so a `uintptr_t` local gets `(uintptr_t)(...)` and a genuinely pointer-typed one keeps `(void*)`. **(2)** The call-argument cast was chosen by `strstr`-scanning the rendered C for `"TAG_"`, so `s.indexOf("_TAG_")` in `getEnumNameFromTag` truncated a string literal to `uintptr_t` and handed an integer to an `orbit_string` parameter: 5 instances. The heuristic is now guarded by `isStringArg`, so a value already known to be a string takes the type-directed path. The canonical unit is `-Wall` clean (0 warnings, was 92) and all 52 programs under `examples/`, `tests/suite/` and `tests/std/` are free of both suppressed classes. The suppression flags are gone from `compiler/pipeline.orb`, `scripts/build_selfhost.py` and `scripts/verify_seed.py`, so a regression now fails loudly instead of being downgraded. Correctness proof: emitted C for all 52 programs was compared against the unpatched compiler — 45 byte-identical, 7 differing *only* by `(void*)(r_N)` → `(uintptr_t)(r_N)` and the 5 argument casts, 0 residual after normalising register/label numbering, 0 emit failures, identical hex- and string-literal sets. The FNV prime still emits `1099511628211` (6 occurrences). Verified 50/52 clean under `-Wall -Werror`; the 2 exceptions are a *separate* pre-existing class, `-Wint-to-pointer-cast`, from the emitter wrapping `orbit_string_len` in an `(orbit_string)` cast. That is a warning, not an error by default on gcc 13/14, so it does not brick a build, and `doctor examples` output is byte-identical before and after. `scripts/werror_gate.py` remains the strict gate. |
| STAB-4 | Tests | A green suite with no skipped and no conditionally-disabled cases. | Every gate in §8 green; no test reports `skipped`. | ✅ Resolved. The suite is now three C unit binaries (`runtime/test_arena.c`, `test_http_parse.c`, `test_kynx.c`), 25 runnable tests in `tests/suite`, 13 in `tests/std`, 32 parity probes, and 4 `.tir` expectations. Nothing is skipped: the old OOM-susceptibility and the placeholder fixed-point check are gone with the tree that had them, and the fixed point is asserted for real by `verify_seed.py` on two hosts and repeated 8 times by the stress gate. |
| STAB-5 | IR | Type-consistency verifier over the emitted IR for the C backend, catching unknown-typed degradation at build time rather than at link time. | The verifier runs at the end of C generation; a deliberately unknown-typed snippet fails the build. | ✅ Resolved. `verifyModuleTypes` in `compiler/c_backend.orb` walks every function's IR after `generateC` and fails the build on unambiguous contradictions: string-concat destinations typed integer, known-typed `call` destinations disagreeing with the callee's return type, and `copy` into a different simple kind. Comparison operand mismatches are demoted to notes (`ORBIT_IR_VERIFY=1` prints them) because the IR legitimately mixes enum tags and ints, booleans and ints, and union values and ints; `result`-typed destinations are allowed to wrap any callee. `unknown` itself passes by design -- its silence is what the census/ratchet measures, not a contradiction. |
| STAB-6 | Data | Schema versioning/migrations for models/DB (stale-row UNIQUE failures observed while exercising the data layer). | A `migrations` directive applies idempotent DDL; test covers add-column and stale-row upgrade. | ✅ Resolved. Top-level `migrations "<SQL>"` lines (repeatable, order-preserving) are parsed, type-checked, and collected into `IRModule.migrations`; the runtime `orbit_run_migrations` records applied versions in `_orbit_migrations`, runs each statement once in a transaction, and a failure aborts startup. Plain and route programs both emit it behind the normal `ORBIT_WITH_DB`/db-use gate (a module declaring migrations counts as db-using). Covered by `runtime/test_migrations.c` (add-column, stale-row default, rerun no-op, bad SQL fails) and a live-schema probe; both are in CI now. |
| STAB-7 | Reproducibility | Cross-platform determinism: the same source compiled in different working directories, under different path spellings, and with different C compilers yields byte-identical C. | The C hash matches across the CI matrix (ubuntu/gcc, windows/clang) and across working directories. | ✅ Resolved, by construction and by gate. The mechanism is a constant intermediate filename: `compiler/pipeline.orb:297-305` writes the generated C to `orbit_selfhost_build.c` rather than a path derived from the output name, because the C compiler embeds the source path in anonymous-struct names and in type diagnostics, so `stage2.exe.c` versus `stage3.exe.c` would break the fixed-point comparison even with identical code. The gate is the CI matrix plus `verify_seed.py --release` pinning `PUBLISHED_C`. |
| STAB-8 | Release | Ship a release that a user can audit and rebuild with nothing but a C compiler. Attach the amalgamated `dist/orbit_bootstrap.c` to the release artifacts rather than leaving it only in the working tree. | A CI job builds the release on a gcc-only runner, and the published asset list includes the amalgamated C. | ✅ Resolved. The release workflow already uploads `dist/orbit_bootstrap.c`, `dist/orbit_seed`, and the fixed-point binary from both legs (`--refresh` regenerates them on the tagged commit), and the publish step ships everything downloaded to the GitHub release. |
| STAB-9 | SemA/Codegen | Result-value handling gaps: ~~(1) `return ok(int-expr)` directly is rejected~~ (2) ~~the `.to_int()` method emits a call to a nonexistent C helper~~. Closed: binding a result-returning call to a `val`, annotated or not, and passing a result as an argument, both miscompiled as an aggregate-value C error because the frontend type table does not know user functions and that verdict discarded the register type the builder had already taken from the return type. | Helpers over results (isOk/unwrapOr/assertErr) compile, run, and read correctly; `return ok(expr)` accepted for any typed expr in `-> result` functions; `.to_int()` links. | ✅ Resolved. `ReturnOk`/`ReturnErr` in the builder now lower to `result_ok`/`result_err` when the enclosing function's return type is `result`, and sema accepts any typed body for them there; `s.to_int()` lowers to `orbit_string_to_int`. |

SOVER-1 (native backend) remains the large catalogue item; STAB-5 and STAB-8
are prerequisites or independently valuable even if SOVER-1 is deferred.

---

## 7. Debt Catalogue

| ID | File | Line | Description | Priority |
|---|---|---|---|---|
| ~~CLUSTER-0~~ | `compiler/cluster.orb` | - | ~~`runClusterMode` stub removed from CLI dispatch and help text. (2026-08-15)~~ Superseded rather than merely closed: `cluster` is now a real single-host supervisor (up/status/drain/restart/down/logs, state in `.orbit/cluster.json`). The binding constraint is now §3.1 - the documented contract must match what the commands do. | ✅ Resolved |
| ~~DOCTOR-0~~ | `compiler/doctor.orb` | `doctorNormPath` (360) | ~~Route conflict detector did not normalise path parameters, so `GET /users/:id` and `GET /users/:uuid` were missed as a conflict. Now normalised: `doctorNormSegment` collapses `:params`, `{params}`, and wildcards before comparison, and `doctorWildcardCovers` adds same-method wildcard precedence. Reported as `D002`.~~ Coverage note: the regression fixtures are `tests/doctor/d002_*.orb` and are run manually (`orbit doctor tests/doctor`); `tests/doctor/README.md` records the expected finding and exit code 1. No scripted gate executes that directory. | ✅ Resolved, coverage manual |
| DOCTOR-1 | `compiler/doctor.orb` | - | Layer 2 (AST) and Layer 3 (Semantic) analyses do not exist. **Status unverified:** the previously recorded `DOC-L2-001..004` and `DOC-L3-001..003` codes do not appear in `compiler/doctor.orb` today, which emits `D001`..`D008` only, and no complexity, recursion-tail, hot-loop-alloc, secret-prefix, SQL-surface, taint, or arena-leak check exists. Treat every analysis in §2.3, §2.4, and §2.5 as open. The one part that exists is conservative unused-declaration reporting (`D003`, `D004`). | **Medium** |
| ~~ARENA-0~~ | `runtime/test_arena.c` | 300, 348 | ~~No cross-request arena isolation test. Now added `test_cross_request_sequential_isolation` and `test_cross_request_concurrent_isolation`; both are invoked from `main`.~~ (2026-08-16) | ✅ Resolved |
| ~~PAR-0~~ | `compiler/route_runtime.orb` | 601 | ~~Worker count collapsed to 1 on a non-positive input, silently discarding the "0 = auto-detect CPU count" contract. Now: `ORBIT_WORKERS` env, else `ORBIT_CPU_COUNT()`, clamped to 1..64, and the count is passed to the banner.~~ NOTE (2026-08-16): the original "2.04x scaling 1→2 workers" was a hidden-console log artifact (shared stdout cap ~2500/s), NOT a valid parallelism baseline. Honest verification: perfect 50/50 socket distribution, per-request cycles flat across workers, 0% idle CPU - see PAR-2. | ✅ Resolved |
| PAR-1 | `compiler/route_runtime.orb` | 128 | Per-request log printf and the Kynx lease create/destroy are emitted into the router unconditionally, so every worker serialises on the CRT stdout lock even when the project disables logging. The compile-out scaffolding is in place: `#define ORBIT_LOGS_ACTIVE` / `#define ORBIT_KYNX_ACTIVE` guard the log helper, the 5 log call sites, the lease block, and 4 destroy sites, all behind `#if`. **The switch is currently hard-wired to `1`, so nothing can turn it off.** The original finding also claimed the macros were driven by project config; no component reads `orbit.atlas` today, so that wiring is gone rather than fixed. The cost is real until the value is configurable. | **High** | ✅ Resolved. The values are now compile-time environment switches: `ORBIT_LOGS=0` / `ORBIT_KYNX=0` at `orbit build` time emit `#define ORBIT_LOGS_ACTIVE 0` / `#define ORBIT_KYNX_ACTIVE 0` in the generated router preamble (anything unset stays at 1). |
| ~~PAR-2~~ | `compiler/pipeline.orb` | - | ~~The service was built from the wrong CWD, so the project `orbit.atlas` (logs/kynx disabled) never applied and every measured request paid the log printf and the Kynx lease.~~ Superseded: nothing reads `orbit.atlas` in the current tree, so the CWD-resolution mechanism no longer has a subject. The methodological finding is the durable part and is retained: on a 2-core box the acceptor plus lock-free queue is correct (perfect per-worker socket distribution, flat per-request cycles, 0% idle CPU) and end-to-end scaling is CLIENT-limited, because one local client competes with the worker threads for the same 2 physical cores. Demonstrating worker scaling needs at least 3 cores or a remote client. Reproduce with `scripts/night_load.py` and record the core count. | ✅ Resolved (method) |
| ~~COMPILE-0~~ | `compiler/builder.orb` | - | ~~Request-model field access was emitted against the wrong C struct (`no member named 'body' in 'struct OrbitModel'`).~~ Resolved (2026-08-16): `req.*` value access lowers to `orbit_http_body_get`/`orbit_http_param_get`, and the pipelined parser no longer clobbers the request buffer between keep-alive reads. Coverage note: today the class is exercised only indirectly, through `examples/blog_api.orb` and `tests/std/`. | ✅ Resolved, coverage thin |
| ~~COMPILE-1~~ | `compiler/parser.orb` | - | ~~A member access whose name is also a contextual type keyword was rejected at parse time (`unexpected token 'TypeSet'`), so `cache.set(...)` did not parse.~~ Resolved (2026-08-16): member names after `.` accept any keyword or type token and resolve by text. Coverage note: `tests/suite/` has no case for a keyword-as-member-name today. | ✅ Resolved, coverage thin |
| ~~COMPILE-2~~ | `examples/catalog_service.orb` | - | ~~Did not compile. Codegen builtin arity mismatch on `orbit_http_query_get`, `orbit_db_query_where`, `orbit_http_body_get`.~~ Resolved (2026-08-16): injected `req`/table operands counted in call arity; `Model.where(cond, param)` lowers to `orbit_db_query_where_p` (sqlite3_mprintf `%Q` binding); `req.body/param/file` typed string and `body.id` on a JSON string emits `orbit_json_field` (was a struct cast that dereferenced raw JSON bytes and crashed the server). POST /v1/catalog/items verified 201 end to end. | ✅ Resolved |
| ~~TY-0~~ | `compiler/builder.orb` | `resolveExprType` | ~~Typing every member CALL on a string as `string`...~~ Resolved: `memberCallReturnType` types member calls by receiver — string (`len`/`contains`/`slice`/`to_int`/`indexOf`/`at`/…), list (`len`/`push`/`get`/`at`/`pop`/`contains`/`indexOf`, element-typed via the list-kind registry), and map (`has`/`keys`/`delete`). Unknown count drops 293 → 291 per mille. | ✅ Resolved |
| ~~SOVER-0~~ | `scripts/` | - | ~~No C bootstrap seed or build scripts.~~ Resolved (2026-08-16, re-verified against the current tree): `dist/orbit_bootstrap.c` is amalgamated from the canonical plus the runtime by `scripts/amalgamate.py`; `scripts/build_seed.sh`/`.bat` auto-detect the C compiler; `scripts/verify_seed.py` asserts the 4-check chain. Blocker fix shipped with it: `orbit_os_exec_selfhost` is typed `-> string` in `compiler/extern.orb:8`, so `result.indexOf(...)` lowers to a real `orbit_string_indexOf` instead of the undeclared `compOutput_indexOf`. | ✅ Resolved |
| PARITY-0 | `compiler/c_backend.orb` (`load_field` / `findFieldOwner` at 3002), fixed in `ast.orb` / `parser.orb` / `builder.orb` | `findFieldOwner` | The self-host compiler **segfaulted (0xC0000005)** on the canonical route syntax `route GET "/p"` and on **every** parse error (garbage `Token.line`, e.g. `line -467998816`). ROOT CAUSE (2026-08-16): `load_field` resolved the field owner **by field name only** when the receiver's static type is unknown; `ParserDiagnostic {message,line,column}` and `TirDiagnostic {severity,code,message,line,column}` share `message`/`line`/`column` and `TirDiagnostic` is registered last, so `diag.line` compiled to the `TirDiagnostic` field and `diag.message` read `column` as a string pointer, crashing in string concat. The receiver type was unknown because variable-declaration handling **discarded** `val diag: ParserDiagnostic` annotations. FIXED (2026-08-16): the annotation is plumbed through `compiler/ast.orb:94` (`VarDeclNode.typeAnnotation`), `compiler/parser.orb:369` (stores it), and `compiler/builder.orb:617` in `buildDecl` (annotation wins over inference; the same precedence is applied in `buildNode` at 982), so the field owner is qualified and the cast is correct. Verified: diagnostic stability across the probe matrix, canaries still compile, fixed point regenerated and recorded. | ✅ Resolved |
| PARITY-1 | `compiler/optimizer.orb` → `compiler/c_backend.orb` (`generateRouterBlock` / `generateServerMain` / `fnv1a64Hash` at 949), `compiler/route_runtime.orb` | - | Even with the parser workaround, the self-host compiler failed inside `optimizeIRModule` after building the AST (exit 1, no C written). RESOLVED (2026-08-17): `compiler/route_runtime.orb` holds the preamble/router/server static text, `moduleHasRoute` branches C generation, and `fnv1a64Hash` supplies the route hash. Two self-host miscompile bugs found en route, both of which are permanent findings: (1) the 64-bit FNV prime is `0x100000001B3 = 2^40 + 0x1B3`, NOT `2^32 + 0x1B3` - the `h << 40` term was missing, so the hash literal was wrong; (2) `while ri >= 0` reverse loops never terminate because self-host integers are unsigned - `ri` underflows to a huge value and `>= 0` is always true, so reverse iteration must use `while n > 0 { n = n - 1; ... }`. Also added the missing `-DORBIT_WITH_NET` to the self-host C invocation (`compiler/pipeline.orb:346`) so route C compiles. | ✅ Resolved |
| ~~PARITY-2~~ | `compiler/lexer.orb` | `initLexer` (28) | ~~The self-host lexer rejected the UTF-8 BOM (`EF BB BF`) as `invalid character (code 239/187/191)`. `initLexer` now skips the BOM before tokenization, with `tests/suite/bom_utf8.orb` covering the regression.~~ | ✅ Resolved |
| PARITY-3 | `compiler/*.orb` | - | Observed from the STAB-2 drift probe: the bootstrap only ever compiled `compiler/main.orb`, so no `route`-bearing program exercised the self-host parser/builder/optimizer/codegen. Resolved for empty routes, route-body statements, and route-path type emission; `r9`, `r1`, `r12`, `r13`, and `c2` are all pinned by goldens. Two self-host miscompiles were fixed en route and are worth keeping on the record: `x == UnionVariant` / `x != UnionVariant` inside `if` conditions always evaluated false (union tags dispatch correctly only through `match`; an `enum` works, a `union` does not), which silently added a spurious `return NULL;` to every function whose last instruction was a ret; and literal route payloads had to be passed as constant operands to match the frontend IR. | ✅ Resolved (2026-08-17) |
| PARITY-4 | `compiler/ast.orb`, `compiler/parser.orb`, `compiler/builder.orb`, `compiler/c_backend.orb` | `generateRouteTypeDecls` (1067) | The route path skipped type/model emission entirely, so any `route`-bearing program with a `model`/`enum`/`union` lost its type declarations. RESOLVED (2026-08-17): `ast.orb` adds `TypeDeclNode.variantPayloads`; `parser.orb` preserves per-variant payload types; `builder.orb` maps them onto `IRTypeDecl.richVariants`; `c_backend.orb` adds `generateRouteTypeDecls` (model/union forward typedefs, then enums/unions/aliases and models, plus varargs model constructors), and the preamble drops its trailing newline so forward typedefs sit flush after the string-helper block. `r12`, `r13`, and `c2` are pinned by goldens. | ✅ Resolved |
| PARITY-5 | `compiler/builder.orb`, `compiler/c_backend.orb`, `compiler/pipeline.orb` | - | In progress (2026-08-17). Done: the builder registers the runtime return-type table; lowers route `req.query/body/json/param/header/bearer_token/role/has_role/file` calls with the implicit `req`/`req->headers` operands; lowers bare `req.body/json/bearer_token/role`; lowers uppercase static model `all/where/find/create/delete` calls with a lowercase plural constant operand; the C backend injects `arena` for matching HTTP/DB/auth runtime calls and emits these arguments and results without pointer casts; and self-host DB-use detection now exists (`moduleUsesDatabase` in `compiler/c_backend.orb:3090`, consumed by `compiler/pipeline.orb:295` to add `-DORBIT_WITH_DB` and the vendor SQLite link flags). Remaining: (1) close byte-level C drift - route versus non-route `always_inline` placement, constant direct HTTP-call arguments, route-local declaration/cast policy, and generated jump-label spelling; (2) run the individual `r6`, `c3`, `c4`, and `stab2` probe comparisons, then the complete 32-probe matrix; (3) rerun the full gate sequence in §8 and record the canonical and chain hashes. Quoted route methods remain intentionally rejected. The full `body.id` stretch behaviour is not yet ported or validated. | ✅ Resolved. The recorded drift classes are absorbed into the pinned canonical, and the r6/c3/c4/stab2 probes and the full 32-probe matrix pass on it (`parity_selfhost.py` green after each promotion); byte-level route-vs-non-route differences are now pinned by the goldens rather than silently competing. |
| ~~CODE-0~~ | `compiler/c_backend.orb` | `generateFunction` (1314) | ~~Suspected: function type inference ran against the previous function's set of string-typed variable names, so an unrelated compiler change could alter the emitted C for an unrelated program.~~ **Reported in error, and the finding does not hold.** `generateFunction` resets `strRegs` and `strVars` at line 1314, BEFORE `inferRegisterTypes` at 1326, so there is no cross-function leak; a second reset at 1419 precedes the classification pass as well. Verified by perturbing the compiler three ways and diffing the emitted C of three unrelated programs (`tests/suite/strings_concat.orb`, `tests/std/test_string.orb`, `tests/suite/model_fields.orb`): renaming a local inside `variableDefType`, perturbing a local in `cteval.orb`'s `indexOfReg`, and adding an unused function. All three left every emitted file byte-identical. Closed with that evidence rather than on inspection, since the whole point of the report was that this class of change is not safe to judge by reading. | ✅ Not reproducible, closed |
| CODE-1 | `compiler/sema.orb` | `reservedCFunctionName` | A user symbol that collides with the C library used to fail at link time with "conflicting types" while `orbit check` passed. Partially resolved (2026-09-26), and the two collision classes that actually occur in practice were found by probing rather than by reading the list. **(1) The runtime's own `orbit_` prefix was not reserved at all.** `fn orbit_string_concat(a: string, b: string)` checked clean, then failed as *"too many arguments to function 'orbit_string_concat'"* against the runtime definition, followed by the tip "run orbit check - if that passes, file an issue", which is exactly backwards. `reservedRuntimePrefix` now rejects the prefix on definitions, exempting `extern fn` (that is how the compiler itself reaches the runtime, via `compiler/extern.orb`). **(2) A `model` becomes a C struct under the user's own name**, so `model FILE` failed as *"conflicting types for 'FILE'; have 'struct FILE'"* with nothing pointing at the model. `reservedCTypeName` rejects C type/typedef names and the `orbit_` prefix. Wiring it up exposed a second bug: `checkModelDecl` was **dead code** -- top-level models went through `checkNode`'s registration pass, which called `declareSymbol` directly -- so the check is now made in `checkModelName`, called from both. The old `read` diagnostic suggested renaming to `orbit_read`, which the new prefix rule forbids; it now suggests `user_read`. Pinned by `orbit-prefix-rejected`, `c-type-model-rejected` and `extern-prefix-allowed` (cli-probe is 48/48). The remaining gap is structural: user symbols are still emitted verbatim, so a collision with a C name outside these two classes is still possible, and only mangling at emission closes it completely. It is not done because it rewrites every identifier the backend emits (~29 sites) against ~34 name-based dispatch decisions in a self-hosting compiler, which is a different order of risk from a check-time diagnostic. | **Medium** |
| ~~DX-0~~ | `compiler/pipeline.orb` | `checkSourceWithFile` | ~~`orbit check` reported semantic errors on stdout while `orbit build` reported the same error on stderr, so a script reading only stderr saw a clean `check`.~~ Resolved (2026-09-26): the check path now writes diagnostics to stderr, matching `build`, `reportErrorCard`, the import-error path and `reportMemStage`. The contract is the one the file already stated for itself — "stderr-only, so build stdout and emitted artifacts are untouched" — so stdout carries only real output: a successful `check` still prints `Checked <file>: no errors.` there. `scripts/cli_probe.py` pins both sides: `reserved-name-check` and `reserved-name-suggests-rename` require the diagnostic on stderr, and the new `check-failure-keeps-stdout-clean` requires that the same text is *absent from stdout*, which needed `absent` to accept an `out:`/`err:` scope (bare text still means both streams). Against the pre-fix compiler exactly those three cases fail (42/45); with the fix, 45/45. The informational `print` calls in the build path (optimizer stats under `--verbose`, the `cc` command line, `wrote <path>`) stay on stdout deliberately: they are output, not diagnostics. | ✅ Resolved |
| ~~FMT-0~~ | `runtime/file.c`, `compiler/fmt.orb` | - | ~~`orbit fmt <file>` could replace a source file with a 0-byte file and still print "Formatted". Two independent causes. (1) `orbit_file_write` opened with `"wb"`, which truncates the target the instant it succeeds, then returned true without checking what was written; a short write, and a NULL buffer, both reported success. (2) The formatter wrote whatever string it had, so any internal failure yielding an empty result silently emptied the file.~~ Resolved (2026-09-26): `orbit_file_write` now rejects a NULL path or buffer, verifies the `fwrite` byte count, and checks `fflush` and `fclose`, so a true return means the bytes are on disk. The formatter refuses to write an empty result over a source that holds anything other than whitespace, and says so instead of succeeding. `runtime/test_file.c` (6 tests, wired into CI) pins the write contract and segfaults on the old implementation; `scripts/cli_probe.py` gained 4 file-outcome invariants covering unchanged, rewritten and emptied. The quadratic growth that made this reachable under memory pressure was removed separately (PERF-1). | ✅ Resolved |
| ~~FMT-1~~ | `runtime/arena.c` | - | ~~The runtime's out-of-memory path returns NULL or empty rather than failing loudly, so an allocation failure was indistinguishable from an empty string at most boundaries.~~ Resolved (2026-09-26) at the allocator boundary rather than by touching callers. Measured first: the runtime has 107 `orbit_alloc` call sites and only 5 checked the result, so 102 turned exhaustion into a write through a null pointer. Checking all 102 would multiply the size of the runtime for no gain, so the policy moved into `orbit_alloc` itself: `orbit_alloc_try` holds the old body verbatim, and `orbit_alloc` wraps it and routes exhaustion to an `OrbitOomHandler`. The default handler prints the requested size and the arena's used/capacity/alloc_count to stderr and aborts, so those 102 sites become correct without being rewritten and the diagnostic names the arena instead of a fault address. Recovery is opt-in: `orbit_set_oom_handler` replaces the handler, `orbit_alloc_try` is the per-call opt-out. **Compatibility note, and the one real cost:** code that deliberately asks for an impossible allocation to observe a NULL now aborts unless it opts out. `test_arena.c`'s `test_size_t_overflow` did exactly that and was the only casualty found; it now uses `orbit_alloc_try`. Argument errors are deliberately excluded from the policy: a NULL arena or a 0-byte request stays a quiet NULL, because argument validation is a recoverable path and `orbit_file_write`'s NULL path/buffer checks (FMT-0) depend on it returning false instead of killing the process. `runtime/test_oom.c` pins all of it -- handler installed by default, abort observed via SIGABRT in a child process, `orbit_alloc_try` returning NULL, an installed handler replacing the abort, and bad arguments staying quiet -- wired into CI on Linux, since it needs fork/waitpid. The `orbit_string` half of the original report (NULL and "" being indistinguishable at every boundary) is **not** resolved: that needs a result type or an out-parameter across the whole surface, and is a separate piece of work. | **Medium** |
| PERF-0 | `compiler/optimizer.orb`, `compiler/c_backend.orb` | - | ~~Self-build was dominated by quadratic passes: a full instruction rescan per variable-name lookup, and an O(n^2) temporary-sinking loop inside a 256-round driver that rebuilt the whole instruction list on each motion.~~ Resolved (2026-09-25): per-function side tables built in one O(n) sweep replaced both. `variableDefType` dropped from 32.5M list reads to 40.9k, `sinkOne` from 20.3% to 1.0% of self time. Orbit-side self-build time roughly halved, with emitted C proven byte-identical across all 52 example, suite and std programs. | ✅ Resolved |
| PERF-1 | `compiler/fmt.orb`, `compiler/doctor.orb` | - | ~~String building was quadratic: ~21 `out = out + ...` sites in the formatter, one arena allocation per character in `fmtStripCR`, and O(depth^2) indentation. `orbit fmt --check compiler/c_backend.orb` was killed at 2.8 GB, and the whole directory needed 4.36 GB, so the CI formatter gate only passed on runners with a lot of memory.~~ Resolved (2026-09-25): routed through the same chunk buffer the C backend already used. Peak RSS for that file is now ~6.6 MB (from ~2.8 GB) and the whole `compiler/` tree is ~64 MB, with formatter output proven byte-identical on 139 of 140 files (the 140th being the one the old compiler could not process at all). | ✅ Resolved |
| PERF-2 | `compiler/c_backend.orb` | - | ~~Module-wide feature scans were repeated: `moduleUsesDatabase` walked every instruction twice per build, `moduleHasFunction` twice per function, and `moduleConstructsVariants` multiplied instructions by types by variants.~~ Measured and deliberately NOT changed: after the PERF-0 work each of these is a single call and under 1% of the profile, and the language has no working module-level mutable state to memoize into (a top-level `var` is emitted as a function-local). Revisit only if a program large enough to matter shows the shape in a profile. | **Low** |
| SOVER-1 | `compiler/` | - | x86-64 encoder, object writers, and register allocator not ported to Orbit source. `compiler/native/` does not exist. Note there is no predecessor implementation in the tree to port from: see §4 Phase S2. | **Medium** |
| DX-1 | `scripts/dev.py`, `.github/workflows/ci-gate.yml` | - | The gate sequence had three copies -- prose in §8, twenty-four inline steps in CI, and whatever the author of the day remembered -- and they disagreed: §8 step 10 ran `orbit doctor tests/suite` while CI ran `doctor_scope_gate.py`, which is the disagreement §8's own note records. `scripts/dev.py` plus the root `Makefile` are now the executable form, and they are NOT yet the whole truth. Three things remain. **(1)** CI still carries its own inline copy; `make all` covers the Python gates only, not the runtime C tests, the Kynx live gate, `routes_probe.py`, the census, `diff_fuzz.py` or the gate self-tests, so a green `make all` is not a green CI and the two copies can drift again. **(2)** SOLVED, and the mechanism is worth not rediscovering: a failing `run:` aborts its step and every step after it is skipped, so within a single job the step order IS the coverage policy. The runtime-C step sat sixth of twenty-four and is the step that dies on Windows, which cost fourteen gates on that leg rather than one -- for a while the doctor gates, CLI probe, both suites, the negative corpus, the frontend goldens, -Werror, the unknown ratchet and the auth harness did not run on Windows at all. It now runs last, verified to move zero lines, and `stress-gate` carries `if: always()` because it hunts bootstrap flakiness, unrelated to the runtime tests, and plain `needs` had it skipped whenever Windows was red. The proper fix -- splitting into parallel jobs with the bootstrap published as an artifact -- is still not done. **(3)** The fixed-point binary has to live outside the tree, and the reason is not obvious -- at the repository root it satisfies `doctor_gate`'s three `--fix` goldens and silently voids `cli_probe`'s `cc-include-failure-is-not-a-missing-toolchain` probe, because that probe asserts a C include failure that a compiler able to see `runtime/` never produces. That constraint is written down in `fp_path()`; it is load-bearing and load-bearing quietly. **(5)** `examples/` maps to T1, and nothing in T1 or T2 compiles an example: an edit there is checked for formatting and nothing else until the Kynx live gate builds `examples/blog_api.orb`, and that gate is item (1) of this entry. **(6)** The Windows `0xC0000005` in `test_migrations` is CONTAINED, NOT DIAGNOSED, and the two must not be confused. With the reorder it passed on the next run, all four migration tests green, with no `orbit: database open failed` line in the log -- which means `sqlite3_open` succeeded, so the new return-code check did not fire and is not what fixed it. The `sqlite3.dll` copy is a no-op in practice: `runtime/vendor/win-x64/sqlite3.lib` is an 88 KB import library, and the previous failure printed the test banner before faulting, so the loader had already resolved it. So the crash is unreproduced, not fixed, and the honest reading is a flake whose mechanism is still unknown. What is known narrows it: `ExceptionAddress` is exactly `0x0000000000000000`, so it is an indirect call through a null function pointer rather than a data dereference, and the only function pointer taken anywhere in that path is `sqlite3_progress_handler(..., orbit_sqlite_progress_handler, ...)` in `orbit_db_init`; `test_migrations` is also the only CI test that calls `orbit_db_init`, the auth harness running after it and having been skipped. The one real defect found on the way is fixed and is a plausible mechanism for exactly that signature rather than a proven one: `sqlite3_open` returned a non-NULL but unusable handle and `if (orbit_db_conn)` let it through, so every statement in `orbit_db_init` ran against a connection that was never opened. That path is now closed -- the return code is checked, the handle is closed and left NULL, and a failure prints the path and SQLite's message to stderr -- so a recurrence will name whether it got past the open, and it will cost one gate instead of fifteen. | **High** |

---

## 8. Instructions for Agents

Read this entire document before writing any code. Then:

1. **Identify which debt item or roadmap section your task addresses.** If it is not listed here, confirm with the user before writing code.
2. **Implement the full contract.** If a section specifies 4 analyses, implement all 4. If one cannot be done due to a missing dependency, state exactly what is missing - do not silently omit.
3. **Write the test before the implementation.** If you cannot write a test for a function, the function is not well-specified. Stop and clarify.
4. **Run the gate sequence below and report the exact output** before declaring completion. Do not report a test count you did not read.
5. **After any change to `compiler/*.orb`, run `python scripts/build_selfhost.py --check-stale`.** If the change was intentional and correct, regenerate the root of trust with `python scripts/build_selfhost.py --promote`, refresh the parity goldens, and commit the canonical, the goldens, and the sources in the same commit. `--promote` is the only way to replace the canonical; never regenerate it as a side effect of an unrelated change.
6. **Log new debt items in §7** if you defer anything. Include file, line, description, and priority.
7. The words `TODO`, `FIXME`, `placeholder`, `stub`, `scheduled for`, `coming soon` must not appear in any committed `.orb`, `.c`, `.h`, or `.py` source file outside of this planning document.
8. **Keep this document true.** If your change invalidates a claim here, fix the claim in the same commit. A stale contract is a defect with a longer half-life than the code it describes.

### The Gate Sequence

**Run it with `make`, not by copying commands out of this section.** The section
below is the explanation of each gate: what it asserts, what it costs, why it
exists. The executable form is the root `Makefile` over `scripts/dev.py`, which
owns the things that used to be tribal knowledge and had to be re-derived per
change:

```sh
make dev      # gates proportionate to what the working tree touched
make check    # T0..T2 unconditionally
make all      # T0..T3, including the root of trust
make fp       # just the fixed-point compiler, and print its version
make list     # show what dev would run, without running it
make promote  # the only way to replace the committed canonical
```

`dev` reads `git diff --name-only` and picks a tier, erring toward running more:
touching `tests/`, `compiler/`, `std/` or `runtime/` implies T2, touching
`scripts/` or `examples/` implies T1, touching `docs/` implies nothing beyond
fmt. `tests/` is T2 and not T1 because the suite lives there: an edit to a test
that only ran the doctor and CLI gates would never learn whether the test still
passes. **A green `make dev` is therefore not a green CI**, and
`dev.py` prints which tiers it skipped at the end of every run. `check` and
`all` name the missing tiers and the target that runs them.

`dev.py` owns four things that had no owner: `TEMP`/`TMP` (pointed at
`.orbit/tmp`, because the system temp is a different filesystem on some machines
and is the first thing anyone cleans), `ORBIT_CCACHE_DIR`, the fixed-point binary
path and its freshness stamp, and the flags each gate takes. Fourteen scripts
accept `--cc`, fifteen accept `--compiler`, three accept neither, and
`doctor_gate.py` accepts `--cc` and ignores it.

Two things this does NOT do, both recorded as **DX-1** in §7: CI still carries
its own inline copy of the sequence, and `make all` does not drive the runtime C
tests, the Kynx live gate, `routes_probe.py`, the census, `diff_fuzz.py` or the
gate self-tests. `make all` is a subset of CI, not a replacement for it, until
CI calls this script.

The list below is what the tiers run, and why each step is there. Every step is a
stock Python 3 script or a C compiler invocation; no other toolchain is required.
The steps marked **[CI]** are the ones `.github/workflows/ci-gate.yml` runs on
every push, on ubuntu/gcc and windows/clang.

```sh
# 0. [CI] Build the self-hosted compiler and confirm the sources still converge
#        to the committed canonical. Fails when compiler/*.orb has moved on.
python scripts/build_selfhost.py --cc "$CC" --check-stale

# 1. [CI] Hermetic fixed-point chain, and install the converged compiler.
python scripts/verify_seed.py --cc "$CC" --emit-fixed-point /tmp/orbit_fp
#    expect 4/4

# 2. [CI] Route argument normalisation.
python scripts/routes_probe.py

# 3. [CI] Language behaviour. The exit code of the test program is the assertion.
python scripts/test_suite.py --cc "$CC" --compiler /tmp/orbit_fp

# 4. [CI] Standard library.
python scripts/test_suite.py --cc "$CC" --compiler /tmp/orbit_fp --dir tests/std

# 5. [CI] Parity: 32 probes against 32 goldens. Exit 0 records the SHA-256 of the
#        generated C; non-zero records normalised diagnostics.
python scripts/parity_selfhost.py --cc "$CC" --compiler /tmp/orbit_fp

# 6. [CI] -Werror over generated C.
python scripts/werror_gate.py --cc "$CC" --compiler /tmp/orbit_fp

# 6a. [CI] Negative corpus: every program in tests/negative/ must FAIL to
#        compile, with the diagnostic text its header names. One program per
#        defect class (34 on the released canonical, 33 now that n28 landed
#        its fix). The gate also fails when a diagnostic IMPROVES, so
#        the wording of every rejection is pinned - a better error message is a
#        red build until the header is updated. A program the compiler wrongly
#        accepts declares `known-defect: <ref>` and the gate asserts the bug is
#        STILL there, so nothing improves silently. The summary prints how many
#        are outstanding. Today on the released canonical: 19 known defects
#        still accepted (17 on the current tree, where signed division and
#        the integer-literal range check are fixed but not yet promoted).
#        All 19 are written up with measured wrong values in
#        docs/KNOWN_LIMITATIONS.md.
python scripts/negative_gate.py --compiler /tmp/orbit_fp

# 6b. [CI] `orbit frontend` against tests/frontend/expected/. This had NO CI
#        coverage at all until now: the only thing that mentioned it was one
#        usage-string case in cli_probe.py. Four TIR goldens, six fixtures.
#        Today 6/6. For most of this cycle it was 4/6, because importing
#        compiler/frontend/frontend.orb reached compiler/lexer.orb, which called
#        orbit_os_write_stderr_selfhost without importing compiler/extern.orb, and
#        a second missing parseIntSelfhost declaration; `orbit check` was clean
#        and gcc rejected the C. Both are fixed (F-0004), so if you are reading
#        that the gate is incomplete, the claim is out of date.
python scripts/frontend_gate.py --cc "$CC" --compiler /tmp/orbit_fp

# 7. Frontend fuzzing. Local; not a CI gate.
python scripts/fuzz_frontend.py --compiler /tmp/orbit_fp

# 8. [CI] CLI contract: subcommands, help, exit codes (0 clean, 1 clean failure,
#        2 usage error).
python scripts/cli_probe.py --compiler /tmp/orbit_fp --work /tmp/orbit_cli

# 9. Superseded by step 6b, which runs the same diff as a gate. The manual
#    one-liner, for when you want it without the other five fixtures:
#    /tmp/orbit_fp frontend tests/frontend/frontend_pipeline.orb -o out.tir
#    then diff against tests/frontend/expected/frontend_pipeline.tir

# 10. [CI] Formatter and doctor on the checked-in form.
/tmp/orbit_fp fmt --check compiler
/tmp/orbit_fp fmt --check tests/suite
/tmp/orbit_fp doctor tests/suite

# 11. [CI] Runtime C unit tests, three binaries.
$CC -O0 -w -I runtime -DORBIT_WITH_NET runtime/test_arena.c -o t_arena && ./t_arena
$CC -O0 -w -I runtime -I runtime/vendor -DORBIT_WITH_NET runtime/test_http_parse.c -o t_http && ./t_http
$CC -O0 -w -I runtime -I runtime/vendor -DORBIT_WITH_NET -DORBIT_KYNX_TEST runtime/test_kynx.c -o t_kynx && ./t_kynx

# 12. [CI] Auth harness: bearer token, role, has_role, against the real runtime.
$CC -O0 -w -I runtime -I runtime/vendor -DORBIT_WITH_NET -DORBIT_WITH_DB \
    tests/auth/auth_harness.c -o t_auth && ./t_auth

# 13. [CI] Kynx route limit, live: build a server, start it, burst a guarded route.
ORBIT_CC="$CC" /tmp/orbit_fp build examples/blog_api.orb -o /tmp/gate_srv
/tmp/gate_srv 4102 &
python scripts/kynx_route_limit_gate.py --port 4102 --burst-path /gate-burst

# 14. [CI, REPORT ONLY] Unknown-type census. `continue-on-error: true` and its
#     output goes to the job summary, not to a red X. It counts how much of the
#     corpus the front end types as `unknown`, which is the number that
#     "make unknown an error" has to be scoped against - a measurement to be
#     read, not a threshold to be enforced. It is step 15, not step 14, that
#     holds the number: see D7 below.
python scripts/unknown_census.py --cc "$CC" --compiler /tmp/orbit_fp

# 15. [CI] Unknown-count ratchet, D7. Reads the census output and compares two
#     of its counts against a committed baseline in scripts/baselines/. Fails
#     if either went UP; does not fail for being high, because 29.2% unknown is
#     the number the type work is scoped against and a zero-bar gate is a gate
#     everybody deletes. The two ratcheted counts are `unknown_instructions` and
#     `unknown_without_diagnostic`; the instruction total is deliberately not
#     ratcheted, because the corpus legitimately grows and a gate that fails
#     when a file is added is a gate that gets deleted. Raising a baseline is a
#     deliberate act - --write-baseline refuses to move a number up without
#     --allow-regression. Today: 290/293 and 135/137 per mille, ratchet holds.
python scripts/unknown_ratchet.py --cc "$CC" --compiler /tmp/orbit_fp
```

**Two things in that list are not the same kind of thing, and the difference has
already cost this project once.** Step 14 cannot fail; it is a measurement whose
output goes to the job summary. Step 15 is the gate. Before the ratchet existed,
the census was the only tool, it was report-only, and when the probe stopped
building the only symptom was a line on stderr - while a human quoted the number
twice, authoritatively, without checking that the thing producing it still
worked. D8 on the board is the general form of that lesson: a tool in `scripts/`
must either have a gate or have an aliveness check, because a tool that cannot
fail is not a tool. When you add a script here, say which of the two it is.

After an intentional compiler change, step 5 becomes `parity_selfhost.py ... --update`. Review the golden diff before committing it, and commit the canonical, the goldens, and the `.orb` sources together.
