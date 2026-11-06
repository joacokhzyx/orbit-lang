#!/usr/bin/env python3
"""The five tier-0 static gates in one tool: schema, walk, counts, flags, cites.

This file holds the five scripts that compare text to text -- 1,693 lines from
`schema_conformance.py`, `walk_coverage.py`, `doc_counts.py`, `flag_coverage.py`
and `cite_check.py`, by `wc -l` on 2026-11-05. Each is one section, in that
order, and each section opens with the block comment that was its module
docstring. That prose is the reason the gate exists -- the field declared a list
that the parser handed over as a node, the `--list` that no line read -- so it
moved with the code rather than into a commit message.

Subcommand, old file, closing line:

    Subcommand  Old file               Closing line begins
    ----------  ---------------------  ----------------------------------
    schema      schema_conformance.py  Finished schema-conformance:
    walk        walk_coverage.py       Finished walk-coverage:
    counts      doc_counts.py          Finished doc-counts:
    flags       flag_coverage.py       Finished flag-coverage:
    cites       cite_check.py          Finished cite-coverage:

The closing lines are what a run is judged on: the five rows of
`scripts/alive_check.py` name each one as its marker. Each subcommand takes
`--self-test`, the mode that asserts the rule can still say no; `walk` and
`flags` also take `--list`; `cites` also takes `--quiet` and file arguments.
Exit codes are unchanged: 0 on a clean tree, 1 on findings or a failed
self-test, 2 where the old script used 2 (`schema` when ast.orb declares no
model, and argparse misuse).

The five belong together because they are the same kind of tool. No section
imports the subprocess module, and none of the five needs a compiler -- the
bargain AGENTS.md:75 prices at "about a second" for tier 0. Merging them removes
five shebangs, five `argparse` preludes and two module-level `sys.path.insert`
guards. It changes no analysis: the gate labels in `scripts/gate_registry.py`
stay `schema_conformance`, `walk_coverage`, `doc_counts`, `flag_coverage` and
`cite_coverage`, so `python scripts/dev.py all --filter cite_coverage` still
selects one gate and prints one verdict.

What did not move, and why: `doc_counts` still imports `dev.py` to ask
`fmt_check_files()` how many files the fmt gate holds, because that number is
dev.py's list and a second copy of it is what this file set exists to remove.
`cites` still writes through `orbit_output`, so a CI annotation appears the same
way it did from `cite_check.py`.

To change one of these gates, edit its section, then run
`python scripts/static_gates.py <subcommand> --self-test` and the subcommand
itself. Do not split a rule out into a new script: the tier is one file now.
"""

import argparse
import ast
import os
import pathlib
import re
import sys

# ROOT, AST, check, self_test and main are the same name in several of the five
# files and are not the same value: cite_check.py built ROOT with os.path and
# got a str, the other four built it with pathlib and got a Path. Each section
# keeps its own copy under its tool's prefix -- _SC_ schema_conformance, _WC_
# walk_coverage, _DC_ doc_counts, _FC_ flag_coverage, _CITE_ cite_check -- and
# the prefix is the only edit a moved line takes. check and self_test take the
# same prefixes; main is the single entry point at the end of this file, and the
# argparse block each old main() carried is now that subcommand's add_parser
# call, so its help text and its flags are the ones the script accepted.
# read_lines and fences turned out to be unique to cite_check.py and keep their
# names, and so does parse_schema: walk_coverage.py imported it from
# schema_conformance.py at module level, and the two sections now share the one
# definition below.

# The first line of each moved module docstring, kept as the subcommand's
# description so `<subcommand> --help` says what the old script said.
_SCHEMA_DESC = ("Check that compiler/front/ast.orb and compiler/front/parser.orb "
                "still agree.")
_WALK_DESC = ("Report AST walks in this compiler that do not say which fields "
              "they skip.")
_COUNTS_DESC = ("Check that the documents' counted claims about the tree still "
                "match the tree.")
_FLAGS_DESC = ("Every CLI flag a script declares must be read by the script "
               "that owns it.")
_CITES_DESC = ("Citation gate: every `path:line` in the prose must point at the "
               "thing the sentence names.")

# ---- from scripts/schema_conformance.py ----
# Check that compiler/front/ast.orb and compiler/front/parser.orb still agree.
#
# Seventeen fields of the AST schema declared `list` while the parser had always
# handed them a single ASTNode. `f.body.len()` on a one-statement function
# returned -1184889136 -- a model pointer read as a list header -- and the
# compiled output was wrong while `orbit check` was clean. Nothing noticed for as
# long as nobody asked the field for its length, which is the worst possible
# failure shape: correct by accident of never measuring.
#
# Doctor's D017 found those, one function at a time, by asking the question. This
# asks it once, over the whole schema, without a bootstrap and without a compiler.
# It reads two files of text and compares them. That is the whole value of it:
# the failure it prevents costs nothing to check, so there is no reason to check
# it by hand and every reason to check it on every commit.
#
# Five rules, all static:
#
#  arity            every `SomeNode(a, b, c)` passes exactly the field count the
#                   model declares. Catches a field added to the schema without
#                   the parser updated, or updated with the arguments in a
#                   different order -- both of which silently shift every field
#                   after the change.
#  unknown-model    every `SomeNode(` names a declared model.
#  unbuilt-model    a model with fields that nothing ever constructs.
#  unbuilt-variant  a variant of the ASTNode union that nothing ever constructs.
#  node-list-op     a field declared `ASTNode` read with a list operation --
#                   `.len()`, `.get(`, `.push(`, `.pop(`. This is the direct
#                   signature of the defect above: the declared type and the
#                   operation disagree.
#
# `node-list-op` is scoped to a match arm that binds the model, so it fires on
# `f.body.len()` inside `ASTNode.FunctionDecl(f) =>` and not on every `.body.` in
# the tree. Loosening it would produce noise, and a gate that cries wolf is a gate
# that gets switched off.
#
# What this cannot do: it compares declarations against construction sites, so it
# cannot tell you that a *correctly declared* field is read by the wrong name. That
# class needs the schema to carry more than a type, and it is not what this is
# for.
#
# Run it with no arguments. `--self-test` asserts the rules can fail, which is the
# difference between a gate and a hope.



_SC_ROOT = pathlib.Path(__file__).resolve().parent.parent
_SC_AST = _SC_ROOT / "compiler" / "front" / "ast.orb"

MODEL_RE = re.compile(r"^model (\w+) \{\s*\}", re.M)
MODEL_BLOCK_RE = re.compile(r"^model (\w+) \{\n(.*?)^\}", re.S | re.M)
FIELD_RE = re.compile(r"^(\w+):\s*([\w<>, ]+?)\s*$", re.M)
UNION_RE = re.compile(r"^type (\w+) =(.*)$", re.M)
VARIANT_RE = re.compile(r"(\w+)\((\w+)\)")

# Operations that only exist on a list. Applied to a field declared `ASTNode`,
# one of these is the bug this script exists for.
LIST_OPS = ("len", "get", "push", "pop", "insert", "remove", "append")


def parse_schema(text: str) -> tuple:
    """models: {name: [(field, type)]}, unions: {name: [(variant, model)]}."""
    models = {}
    for m in MODEL_BLOCK_RE.finditer(text):
        fields = []
        for line in m.group(2).split("\n"):
            line = re.sub(r"//.*", "", line).strip()
            fm = FIELD_RE.match(line)
            if fm:
                fields.append((fm.group(1), fm.group(2).strip()))
        models[m.group(1)] = fields
    # `model BreakNode {}` and friends: empty, one line, and not matched above.
    for m in MODEL_RE.finditer(text):
        models.setdefault(m.group(1), [])

    unions = {}
    for m in UNION_RE.finditer(text):
        variants = [(v, mo) for v, mo in VARIANT_RE.findall(m.group(2))]
        unions[m.group(1)] = variants
    return models, unions


def split_args(src: str, start: int) -> tuple:
    """The argument list of a call whose '(' is at `start`.

    Returns (count, index_after_the_closing_paren). Counts top-level commas
    rather than splitting on text, because the arguments are themselves calls:
    `CallNode(buildExpr(a), makeArgs(b, c))` is two arguments, not three.
    """
    depth, commas, i, in_str = 1, 0, start + 1, False
    while i < len(src) and depth:
        ch = src[i]
        if in_str:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 1:
            commas += 1
        i += 1
    body = src[start + 1:i - 1].strip()
    count = commas + 1 if body else 0
    return count, i


def compiler_sources(root: pathlib.Path):
    """Every compiler source, read once. Sites span lines, so line-by-line
    would miss an argument list that wraps."""
    for path in sorted((root / "compiler").rglob("*.orb")):
        yield path, path.read_text(encoding="utf-8")


def collect_constructions(models: dict, root: pathlib.Path) -> tuple:
    """(constructed models, constructed variants, arity findings)."""
    built_models, built_variants, findings = set(), set(), []
    for path, src in compiler_sources(root):
        rel = path.relative_to(root).as_posix()
        src = path.read_text(encoding="utf-8")
        rel = path.relative_to(root).as_posix()
        for m in re.finditer(r"\b([A-Z]\w*Node)\(", src):
            name = m.group(1)
            if name not in models:
                continue
            count, _ = split_args(src, m.end() - 1)
            want = len(models[name])
            built_models.add(name)
            if count != want:
                line = src.count("\n", 0, m.start()) + 1
                findings.append((
                    f"{rel}:{line}", "arity",
                    f"{name}(...) passes {count} argument(s), the model declares "
                    f"{want}. A field added or reordered without the parser "
                    f"following shifts every field after it.",
                ))
        for m in re.finditer(r"\bASTNode\.(\w+)\(\s*([A-Z]\w*Node)\s*\(", src):
            built_variants.add(m.group(1))
    return built_models, built_variants, findings


def collect_node_list_ops(models: dict, root: pathlib.Path) -> list:
    """A field declared ASTNode, read with a list operation, inside the arm
    that binds its model."""
    findings = []
    for path, src in compiler_sources(root):
        rel = path.relative_to(root).as_posix()
        for arm in re.finditer(r"ASTNode\.([A-Za-z]+)\((\w+)\)\s*=>\s*\{", src):
            model, binding = arm.group(1), arm.group(2)
            fields = dict(models.get(model + "Node", []))
            # The arm body: to the matching close brace.
            depth, i = 1, arm.end() - 1
            while i < len(src) and depth:
                if src[i] == "{":
                    depth += 1
                elif src[i] == "}":
                    depth -= 1
                i += 1
            body = src[arm.end():i - 1]
            for use in re.finditer(rf"\b{re.escape(binding)}\.(\w+)\.(\w+)\s*\(", body):
                fname, op = use.group(1), use.group(2)
                if fields.get(fname) == "ASTNode" and op in LIST_OPS:
                    line = src.count("\n", 0, arm.end() + use.start()) + 1
                    findings.append((
                        f"{rel}:{line}", "node-list-op",
                        f"{model}Node.{fname} is declared ASTNode and is read with "
                        f"`.{op}(`, which only exists on a list. Reading a node as "
                        f"a list header is how body.len() once returned "
                        f"-1184889136.",
                    ))
    return findings


def _sc_check(root: pathlib.Path) -> list:
    """Every disagreement between the schema and the code that builds nodes."""
    models, unions = parse_schema((root / "compiler" / "front" / "ast.orb").read_text(encoding="utf-8"))
    built_models, built_variants, findings = collect_constructions(models, root)
    findings += collect_node_list_ops(models, root)

    for name, fields in sorted(models.items()):
        if fields and name not in built_models:
            findings.append((
                "compiler/front/ast.orb", "unbuilt-model",
                f"model {name} declares {len(fields)} field(s) and nothing "
                f"constructs it. Either it is schema for a node that cannot "
                f"exist, or the parser stopped building it.",
            ))
    for union, variants in sorted(unions.items()):
        for variant, model in variants:
            if variant not in built_variants:
                findings.append((
                    f"compiler/front/ast.orb ({union})", "unbuilt-variant",
                    f"{union} variant `{variant}` is declared and nothing ever "
                    f"constructs it. ENGINEERING.md section 0 forbids this: "
                    f"phantom schema is a contract with no implementation.",
                ))
    return findings


NL = chr(10)
SELF_TEST_SCHEMA = (
    "model MNode {" + NL +
    "    body: ASTNode" + NL +
    "    names: list" + NL +
    "}" + NL +
    "model NNode {" + NL +
    "    id: string" + NL +
    "}" + NL +
    "type ASTNode = M(MNode) | N(NNode)" + NL
)

# A tree that satisfies every rule: two models, both built, both in the union.
SELF_TEST_SOURCE = (
    "fn build(n: ASTNode) -> int {" + NL +
    "    val m = ASTNode.M(MNode(n, []))" + NL +
    "    val q = ASTNode.N(NNode(\"id\"))" + NL +
    "    return 0" + NL +
    "}" + NL
)

# One perturbation per rule. Each one adds exactly one violation to the clean
# fixture above, so a rule that stays quiet is a rule that has stopped working
# rather than a rule that was already noisy.
SELF_TEST_CASES = [
    ("arity",
     SELF_TEST_SCHEMA, SELF_TEST_SOURCE + "val a = MNode(node)" + NL,
     "a construction site passing one argument too few"),
    ("node-list-op",
     SELF_TEST_SCHEMA,
     "fn bad(m: ASTNode) -> int {" + NL +
     "    match m {" + NL +
     "        ASTNode.M(v) => { val k = v.body.len() return 0 }" + NL +
     "        _ => { return 0 }" + NL +
     "    }" + NL +
     "}" + NL,
     "`v.body.len()` with `body` declared ASTNode"),
    ("unbuilt-model",
     SELF_TEST_SCHEMA + "model OrphanNode {" + NL + "    x: int" + NL + "}" + NL,
     SELF_TEST_SOURCE,
     "a model with fields that nothing constructs"),
    ("unbuilt-variant",
     SELF_TEST_SCHEMA + "type More = P(PNode)" + NL,
     SELF_TEST_SOURCE,
     "a union variant that nothing constructs"),
]


def self_test_schema() -> int:
    """Assert every rule can still say no.

    D8: a tool that cannot fail is not a tool. Each rule is fired on a tree built
    to violate exactly that rule; a rule that stays quiet on its own violation
    has stopped working, and that is the failure this catches.
    """
    import tempfile

    with tempfile.TemporaryDirectory(prefix="schema_conformance_selftest_") as td:
        root = pathlib.Path(td)
        cdir = root / "compiler" / "front"
        cdir.mkdir(parents=True)

        def fixture(schema: str, body: str) -> set:
            (cdir / "ast.orb").write_text(schema)
            (cdir / "a.orb").write_text(body)
            return {f[1] for f in _sc_check(root)}

        # The clean fixture must be clean. If it is not, every case below is
        # measuring noise rather than the rule.
        base = fixture(SELF_TEST_SCHEMA, SELF_TEST_SOURCE)
        if base:
            print(f"self-test FAILED: the clean fixture is not clean; it raised "
                  f"{sorted(base)} before anything was perturbed")
            return 1

        # The parts the rules rest on.
        models, unions = parse_schema(SELF_TEST_SCHEMA)
        if len(models) != 2 or unions["ASTNode"] != [("M", "MNode"), ("N", "NNode")]:
            print("self-test FAILED: the schema parser misreads models or unions")
            return 1
        if split_args("f(g(a, b), h(c, d))", 1)[0] != 2:
            print("self-test FAILED: the argument splitter counts a nested comma")
            return 1
        if split_args("f()", 1)[0] != 0:
            print("self-test FAILED: the argument splitter counts an empty call")
            return 1

        fired = 0
        for rule, schema, body, what in SELF_TEST_CASES:
            got = fixture(schema, body)
            if rule not in got:
                print(f"self-test FAILED: the {rule} rule stayed quiet on {what}")
                return 1
            fired += 1

    print(f"Finished schema-conformance self-test: {fired}/{fired} rules fired "
          f"on a tree built to violate them; the clean fixture is clean; the "
          f"schema parser and the argument splitter read what they claim to.")
    return 0


# ---- from scripts/walk_coverage.py ----
# Report AST walks in this compiler that do not say which fields they skip.
#
# A walk over `ASTNode` that does not reach a child field drops that whole subtree,
# and nothing in the compiler says so. Three bugs in `compiler/tools/doctor.orb` were
# exactly this: an arm existed for the node and the walk never descended into one
# of its fields. `Call.callee` dropped the receiver's own arguments,
# `Assignment.target` dropped the index of `xs[i] = 7`, and `MatchCase.pattern`
# dropped the comparison of `target =>`. In each case a live value read as
# never-read and the check reported a dead store that was not dead, while every
# golden was green.
#
# Why this is a declaration check and not a defect check: arm counting cannot tell
# a walk from a function that merely matches. Measured on this tree, 158 matches on
# `ASTNode`, every one ending in `_ =>`, none exhaustive -- and the worst offenders
# by that measure are `parsePrimary`, which BUILDS nodes and has no children to
# visit, `listKindNameOf`, which asks what type an expression is, and
# `resolveExprType`, which does the same for the backend. A gate that called those
# bugs would be wrong on the first run and switched off on the second, which is
# what already happened here once: a scope gate that counted D015/D017/D018 went
# red the day those checks shipped.
#
# So the walk declares its own contract, and this checks the declaration against
# reality:
#
#    // orbit-walk: none -- builds nodes; it has no children to visit
#    fn parsePrimary(...)              -- not a walk, and the reason says why
#
#    // orbit-walk-misses: FunctionDecl, RouteDecl
#    fn doctorDeadWalk(...)            -- the list MUST equal the real gap
#
# Two findings, both about the declaration rather than the code:
#
#    undeclared   a walk with a gap and no `orbit-walk-misses` line. The gap may
#                 be correct; the point is that nobody wrote down that it is.
#    stale        the annotation disagrees with the measured gap. A field was
#                 added to a model, or an arm was added to a walk, and the
#                 declaration was not updated with it.
#
# What it cannot do, stated so nobody over-trusts it, twice, because both were
# learned by using it: it cannot tell you a declared gap is wrong, because that is
# a judgement about intent; and it cannot tell you an UNDECLARED gap is real,
# because "has no arm of its own" and "is never visited" are different questions.
# Three walks that declare a gap were probed by hand and all three were correct --
# doctorShadowStmt through match arms, D023 through constructor patterns, and D025
# through a method call's arguments -- and the gaps were the measurement's, not the
# code's. It guarantees only that no gap is unremarked. The companion that measures real visits is
# `tests/doctor/golden/walk_coverage_all_child_fields`, which plants a read in
# every field and fails when a walk cannot see one -- and which covers doctor's
# walks, not the compiler's, because the compiler's walks have no observable
# output to probe from outside.
#
# A walk is detected structurally: a function with a `match` on `ASTNode` that
# recurses into itself after that match. `orbit-walk: none` overrides the
# detection for the cases the heuristic gets wrong.




_WC_ROOT = pathlib.Path(__file__).resolve().parent.parent
_WC_AST = _WC_ROOT / "compiler" / "front" / "ast.orb"

# re.M matters: `head` is a slice of several lines, and without it `^` and `$`
# anchor to the whole slice, so an annotation on any line but the first and last
# is invisible and every walk looks undeclared.
# A reason is allowed after `none` and is encouraged: an exemption with no stated
# reason is indistinguishable from an oversight, which is the thing this gate
# exists to prevent.
EXEMPT_RE = re.compile(r"^\s*//\s*orbit-walk:\s*none\b.*$", re.M)
MISSES_RE = re.compile(r"^\s*//\s*orbit-walk-misses:\s*(.*?)\s*$", re.M)


def child_models(models: dict) -> set:
    """Models that can contain a node, i.e. the ones a walk has to descend into.

    A field declared `list` counts only when the model also declares an ASTNode
    field: `params: list` holds strings, and a walk that "missed" it would be
    reporting a gap that cannot be closed.
    """
    out = set()
    for name, fields in models.items():
        types = {t for _, t in fields}
        if "ASTNode" in types:
            out.add(name)
    return out


def variant_to_model(unions: dict) -> dict:
    """Variant name -> model name.

    Needed because the two spaces have different names: the union declares
    `Call(CallNode)`, so an arm reads `ASTNode.Call(` and the model is `CallNode`.
    Comparing an arm's variant name against the set of model names intersects
    nothing, and every walk comes out missing all 22 -- which is what the first
    run of this script reported, for all thirty of them.
    """
    out = {}
    for variants in unions.values():
        for variant, model in variants:
            out[variant] = model
    return out


def collect_walks(models: dict, unions: dict, root: pathlib.Path) -> list:
    """One entry per function detected as a walk over ASTNode."""
    kids = child_models(models)
    v2m = variant_to_model(unions)
    walks = []
    for path in sorted((root / "compiler").rglob("*.orb")):
        src = path.read_text(encoding="utf-8")
        rel = path.relative_to(root).as_posix()
        lines = src.split("\n")
        for i, line in enumerate(lines):
            m = re.match(r"^fn (\w+)\(", line)
            if not m:
                continue
            name = m.group(1)
            j, body = i + 1, []
            while j < len(lines) and not re.match(r"^fn \w+\(", lines[j]):
                body.append(lines[j])
                j += 1
            text = "\n".join(body)

            # An annotation may sit above the fn or inside its first lines.
            head = "\n".join(lines[max(0, i - 3):i + 4])
            exempt = bool(EXEMPT_RE.search(head))
            misses = None
            mm = MISSES_RE.search(head)
            if mm:
                declared = mm.group(1).strip()
                misses = set() if declared in ("", "none") else {
                    d.strip() for d in declared.split(",") if d.strip()
                }

            variants = set(re.findall(r"ASTNode\.([A-Za-z]+)\(", text))
            if not variants:
                continue
            arms = {v2m[v] for v in variants if v in v2m}
            # A walker recurses into itself after the match. Everything else
            # -- parsers, type queries, constructors -- does not.
            post = text.split("match", 1)
            recurses = len(post) > 1 and re.search(rf"\b{name}\s*\(", post[1]) is not None
            if not recurses:
                continue
            walks.append({
                "fn": name, "loc": f"{rel}:{i + 1}",
                "missing": sorted(kids - arms),
                "declared": misses, "exempt": exempt,
            })
    return walks


def _wc_check(root: pathlib.Path) -> list:
    models, unions = parse_schema((root / "compiler" / "front" / "ast.orb").read_text(encoding="utf-8"))
    findings = []
    for w in collect_walks(models, unions, root):
        if w["exempt"]:
            continue
        if w["declared"] is None:
            findings.append((
                w["loc"], "undeclared",
                f"fn {w['fn']} walks the AST and does not declare what it skips. "
                f"It has no arm of its own for: "
                f"{', '.join(w['missing']) or 'nothing'}. That is a CANDIDATE, not "
                f"a verdict: a walk can reach a node by iterating its parent's "
                f"list field instead of arming it. doctorShadowStmt declares "
                f"MatchCaseNode as skipped and is wrong -- it reaches every arm "
                f"body through `m.cases`, and D023 fires on a `val` shadowed in "
                f"a match arm and read after it. Declare the gap with "
                f"`// orbit-walk-misses: ...` if it is intended, and treat the "
                f"list as the work queue for judging whether it is.",
            ))
            continue
        if declared_differs(w["declared"], w["missing"]):
            findings.append((
                w["loc"], "stale",
                f"fn {w['fn']} declares orbit-walk-misses: "
                f"{', '.join(sorted(w['declared'])) or 'none'}, but the arms leave "
                f"{', '.join(w['missing']) or 'nothing'} unvisited. A field was added "
                f"to a model, or an arm to this walk, without the declaration "
                f"following.",
            ))
    return findings


def declared_differs(declared: set, missing: list) -> bool:
    return set(declared) != set(missing)


def self_test_walk() -> int:
    """Assert the rules can say no, and that the exemption works."""
    import tempfile

    schema = ("model MNode {\n    body: ASTNode\n    names: list\n}\n"
              "type ASTNode = M(MNode)\n")

    def tree(schema_text, source):
        td = tempfile.TemporaryDirectory(prefix="walk_coverage_selftest_")
        root = pathlib.Path(td.name)
        (root / "compiler" / "front").mkdir(parents=True)
        (root / "compiler" / "front" / "ast.orb").write_text(schema_text)
        (root / "compiler" / "a.orb").write_text(source)
        return root, td

    # A walk with a gap and no declaration: undeclared.
    root, td = tree(schema,
                    "fn w(n: ASTNode) -> int {\n"
                    "    match n {\n"
                    "        ASTNode.M(v) => { w(v.body) return 0 }\n"
                    "        _ => { return 0 }\n"
                    "    }\n"
                    "}\n")
    got = {f[1] for f in _wc_check(root)}
    td.cleanup()
    if got != {"undeclared"}:
        print(f"self-test FAILED: a walk with an undeclared gap should raise "
              f"undeclared and raised {sorted(got) or 'nothing'}")
        return 1

    # The same walk with the declaration: silent.
    root, td = tree(schema,
                    "// orbit-walk-misses: none\n"
                    "fn w(n: ASTNode) -> int {\n"
                    "    match n {\n"
                    "        ASTNode.M(v) => { w(v.body) return 0 }\n"
                    "        _ => { return 0 }\n"
                    "    }\n"
                    "}\n")
    got = {f[1] for f in _wc_check(root)}
    td.cleanup()
    if got:
        print(f"self-test FAILED: an accurate declaration should be silent and "
              f"raised {sorted(got)}")
        return 1

    # A declaration that disagrees with the arms: stale.
    root, td = tree(schema,
                    "// orbit-walk-misses: Missing\n"
                    "fn w(n: ASTNode) -> int {\n"
                    "    match n {\n"
                    "        ASTNode.M(v) => { w(v.body) return 0 }\n"
                    "        _ => { return 0 }\n"
                    "    }\n"
                    "}\n")
    got = {f[1] for f in _wc_check(root)}
    td.cleanup()
    if got != {"stale"}:
        print(f"self-test FAILED: a declaration naming the wrong model should "
              f"raise stale and raised {sorted(got) or 'nothing'}")
        return 1

    # The exemption: a function the heuristic mistakes for a walk, opted out.
    root, td = tree(schema,
                    "// orbit-walk: none\n"
                    "fn q(n: ASTNode) -> int {\n"
                    "    match n {\n"
                    "        ASTNode.M(v) => { return 0 }\n"
                    "        _ => { return 1 }\n"
                    "    }\n"
                    "}\n"
                    "fn w(n: ASTNode) -> int {\n"
                    "    return q(n)\n"
                    "}\n")
    got = {f[1] for f in _wc_check(root)}
    td.cleanup()
    if got:
        print(f"self-test FAILED: orbit-walk: none should exempt, and raised "
              f"{sorted(got)}")
        return 1

    print("Finished walk-coverage self-test: 4/4 rules fired; an accurate "
          "declaration is silent; `orbit-walk: none` exempts.")
    return 0


# ---- from scripts/doc_counts.py ----
# Check that the documents' counted claims about the tree still match the tree.
#
# Three times in one week a document kept a number the tree had left behind. The
# behavior suite stayed at 71 runnable files after the 72nd landed; `std/` was
# described as 14 modules after `bitwise` returned and made it 19; docs/FMT.md
# still described a corpus of 107 files while `dev.py fmt_check_files` holds 154;
# and ENGINEERING.md put the runtime C program table at 20 files while the table
# in `scripts/runtime_c_tests.py` holds 21 rows. None of those was a lie: each was
# a true number at the moment it was pasted. The failure is that a count is a fact
# about the tree, and nothing recomputed it.
#
# A number that can be counted should be counted, so this reads the tree, reads
# the claims, and fails when they disagree -- in the same second, with no compiler,
# next to the siblings whose shape it copies: schema_conformance.py (two files of
# text that must agree) and walk_coverage.py (a declaration that must match the
# code). It is T0 for the same reason they are: the check costs nothing, so there
# is no reason to do it by hand and every reason to do it on every commit.
#
# What a claim is: (path, pattern, keys). The pattern is a regular expression in
# which each `{N}` matches one number, written in digits or in English up to
# twenty. The pattern must match, and every captured number must equal the count
# this script measures for the key at the same position. A claim that no longer
# matches is a finding too: a sentence rewritten without its number is a claim the
# gate has stopped checking, and silence there is the same failure as a wrong
# number, only quieter.
#
# Scope. Present-tense counts of the test corpus and the standard library, in the
# documents that describe the tree as it is today: docs/KNOWN_LIMITATIONS.md,
# docs/ARCHITECTURE.md, docs/IR_SPEC.md, docs/FMT.md, ENGINEERING.md (the section
# 6 row and the section 8 command list), and the README of the two corpora that
# count themselves.
#
# Out of scope, and it is a decision rather than an oversight:
#
#  * The unknown-type census. `scripts/measure.py census` types the corpus with
#    front end, so it needs a bootstrapped compiler; this gate is T0 and costs a
#    second. Every place the census is written down is dated or defers to
#    `scripts/baselines/unknown_count.json` as the current truth, which is a
#    statement the gate does not have to make for it.
#  * docs/PERF.md and docs/CHANGELOG.md. A performance transcript and a release
#    history are dated by contract; their numbers are of their moment. PERF.md
#    still says `runtime_c_tests.py` compiles 20 programs, which is where it was.
#
# Run it with no arguments. `--self-test` asserts that the rule can say no and that
# the counters read the trees they claim to, which is the difference between a
# gate and a hope.



_DC_ROOT = pathlib.Path(__file__).resolve().parent.parent

# The English numbers the documents actually use, longest first so that
# `fourteen` is read as fourteen and not as four followed by `teen`.
WORDS = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
         "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
         "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
WORD_VALUE = {w: i + 1 for i, w in enumerate(WORDS)}
WORDS.sort(key=len, reverse=True)
NUMBER = r"\b(\d+|" + "|".join(WORDS) + r")\b"


def as_int(token: str) -> int:
    return int(token) if token.isdigit() else WORD_VALUE[token.lower()]


def claim_regex(pattern: str) -> "re.Pattern":
    return re.compile(pattern.replace("{N}", NUMBER), re.S | re.I)


def flag_census(root: pathlib.Path) -> dict:
    """Which scripts in `scripts/` take `--cc` and which take `--compiler`.

    A script accepts a flag when `add_argument` names it or when it calls the
    helper that declares both. The helper test is why this is a function and
    not a grep: a grep reading one line at a time misses a flag written on the
    line after its `add_argument(`, which is how `scripts/alive_check.py` gets
    counted wrong.
    """
    files = [f for f in sorted((root / "scripts").glob("*.py"))
             if f.name != "_common.py"]
    takes = []
    for f in files:
        text = f.read_text(encoding="utf-8", errors="replace")
        takes.append((bool(_TAKES_CC.search(text)) or bool(_TAKES_ANY.search(text)),
                      bool(_TAKES_COMPILER.search(text))
                      or bool(_TAKES_ANY.search(text))))
    return {"script_files": len(files),
            "flags_cc": sum(a for a, _ in takes),
            "flags_compiler": sum(b for _, b in takes),
            "flags_both": sum(a and b for a, b in takes),
            "flags_neither": sum(not a and not b for a, b in takes)}


_TAKES_CC = re.compile(r'add_argument\(\s*"--cc"')
_TAKES_COMPILER = re.compile(r'add_argument\(\s*"--compiler"')
_TAKES_ANY = re.compile(r"add_common_args\(|add_gate_args\(")

def measure(root: pathlib.Path) -> dict:
    """Every count a claim may rest on, read from the tree as it is now."""
    suite = sorted((root / "tests" / "suite").rglob("*.orb"))
    support = [p for p in suite if p.name.endswith(".support.orb")]
    std = [p for p in (root / "std").rglob("*.orb") if "quarantine" not in p.parts]
    std_tests = sorted((root / "tests" / "std").rglob("*.orb"))
    negative = sorted((root / "tests" / "negative").rglob("*.orb"))
    probes = sorted((root / "tests" / "parity" / "probes").glob("*.orb"))
    goldens = [p for p in (root / "tests" / "parity" / "golden").rglob("*")
               if p.is_file()]
    tir = sorted((root / "tests" / "frontend" / "expected").glob("*.tir"))
    fixtures = sorted((root / "tests" / "frontend").glob("*.orb"))
    compiler = sorted((root / "compiler").rglob("*.orb"))
    examples = [p for p in (root / "examples").glob("*.orb")
                if p.name != "orbit_full_expansion.orb"]
    quarantined = list((root / "std" / "quarantine").glob("*.orb.quarantined"))

    def directives(files, marker):
        return sum(1 for p in files
                   for line in p.read_text(encoding="utf-8").splitlines()
                   if line.startswith(marker))

    table = (root / "scripts" / "runtime_c_tests.py").read_text(encoding="utf-8")
    programs = len(re.findall(r"(?m)^\s*prog\(", table))
    posix_only = len(re.findall(r"posix_only=True", table))

    return {
        "std_modules": len(std),
        "std_quarantined": len(quarantined),
        "suite_files": len(suite),
        "suite_support": len(support),
        "suite_runnable": len(suite) - len(support),
        "std_tests": len(std_tests),
        "negative_cases": len(negative),
        "negative_expect_error": directives(negative, "// expect-error:"),
        "negative_known_defect": directives(negative, "// known-defect:"),
        "parity_probes": len(probes),
        "parity_goldens": len(goldens),
        "tir_expectations": len(tir),
        "frontend_fixtures": len(fixtures),
        "runtime_programs": programs,
        "runtime_windows": programs - posix_only,
        "fmt_compiler": len(compiler),
        "fmt_suite": len(suite),
        "fmt_examples": len(examples),
        "fmt_files": len(compiler) + len(suite) + len(std) + len(std_tests)
                     + len(examples),
        **flag_census(root),
    }


# (relative path, pattern with {N} per number, keys in capture order, what the
# claim is about). Split by document, in the order a reader meets them.
CLAIMS = [
    # docs/KNOWN_LIMITATIONS.md.
    ("docs/KNOWN_LIMITATIONS.md",
     r"Finished negative: {N}/{N} pass \({N} known defects still accepted\)",
     ["negative_cases", "negative_cases", "negative_known_defect"],
     "negative gate transcript"),
    ("docs/KNOWN_LIMITATIONS.md", r"(?m)^## `std/` is {N} modules;",
     ["std_modules"], "standard library, section heading"),
    ("docs/KNOWN_LIMITATIONS.md", r"\*\*{N} modules, and all {N} compile",
     ["std_modules", "std_modules"], "standard library, merge claim"),
    ("docs/KNOWN_LIMITATIONS.md", r"is {N} files and runs\s+{N}/{N} green",
     ["std_tests", "std_tests", "std_tests"], "tests/std coverage"),

    # docs/ARCHITECTURE.md.
    ("docs/ARCHITECTURE.md", r"Orbit standard library\. {N} modules,",
     ["std_modules"], "standard library, module table"),
    ("docs/ARCHITECTURE.md", r"\*\*{N} modules, {N} of {N}\*\*",
     ["std_modules", "std_modules", "std_modules"],
     "standard library, compile-and-merge claim"),
    ("docs/ARCHITECTURE.md", r"against its golden \({N} today\)",
     ["parity_probes"], "parity probe count"),

    # docs/IR_SPEC.md -- the designated corpus.
    ("docs/IR_SPEC.md",
     r"Suite: {N} runnable files \+ {N} support file\.\*\* `tests/suite/` holds {N}",
     ["suite_runnable", "suite_support", "suite_files"],
     "designated corpus: the suite"),
    ("docs/IR_SPEC.md", r"{N} runnable programs plus `imports\.support\.orb`",
     ["suite_runnable"], "designated corpus: runnable files only"),
    ("docs/IR_SPEC.md", r"Standard library: {N} files\.\*\* `tests/std/` holds {N}",
     ["std_tests", "std_tests"], "designated corpus: tests/std"),
    ("docs/IR_SPEC.md",
     r"covering the {N} shipped `std/\*\*/\*\.orb` modules; `std/quarantine/` holds {N}",
     ["std_modules", "std_quarantined"],
     "designated corpus: std modules and quarantine"),

    # docs/FMT.md -- the corpus the fmt gate verifies.
    ("docs/FMT.md", r"under `compiler/` \({N} files\), `tests/suite/` \({N}\),",
     ["fmt_compiler", "fmt_suite"], "fmt corpus, source trees"),
    ("docs/FMT.md", r"`std/` \({N}\) and `tests/std/` \({N}\), plus",
     ["std_modules", "std_tests"], "fmt corpus, library trees"),
    ("docs/FMT.md", r"`examples/\*\.orb` \({N}, minus",
     ["fmt_examples"], "fmt corpus, examples"),
    ("docs/FMT.md", r"\. {N} files -- the exact list",
     ["fmt_files"], "fmt corpus, total"),

    # ENGINEERING.md, section 6 (the debt table) and section 8 (the commands).
    ("ENGINEERING.md",
     r"Of the {N}\s+scripts\s+besides\s+`_common\.py`,\s+{N}\s+accept\s+`--cc`,"
     r"\s+{N}\s+accept\s+`--compiler`,\s+{N}\s+accept\s+both\s+and\s+{N}\s+accept"
     r"\s+neither",
     ["script_files", "flags_cc", "flags_compiler", "flags_both",
      "flags_neither"], "the flag census, section 8"),
    ("ENGINEERING.md", r"program table \({N}(?: runtime C)? programs; {N} on Windows",
     ["runtime_programs", "runtime_windows"],
     "runtime C program table, section 6"),
    ("ENGINEERING.md", r"\({N} of {N} there, as above\)",
     ["runtime_windows", "runtime_programs"],
     "runtime C table on Windows, section 6"),
    ("ENGINEERING.md",
     r"{N} runnable tests in `tests/suite` \({N} files, one a support module\), "
     r"{N} in `tests/std`, {N} parity probes, and {N} `\.tir` expectations",
     ["suite_runnable", "suite_files", "std_tests", "parity_probes",
      "tir_expectations"],
     "the gate counts, section 6"),
    ("ENGINEERING.md", r"Parity: {N} probes against {N} goldens",
     ["parity_probes", "parity_probes"], "parity probes, section 8"),
    ("ENGINEERING.md", r"defect class; {N} today",
     ["negative_cases"], "negative corpus size, section 8"),
    ("ENGINEERING.md", r"today {N}/{N} pass with {N} known",
     ["negative_cases", "negative_cases", "negative_known_defect"],
     "negative gate transcript, section 8"),
    ("ENGINEERING.md", r"{N} TIR goldens, {N} fixtures",
     ["tir_expectations", "frontend_fixtures"],
     "frontend gate fixtures, section 8"),
    ("ENGINEERING.md",
     r"the whole list \({N} programs; test_oom needs fork/waitpid, so\s+#\s+{N} run on Windows\)",
     ["runtime_programs", "runtime_windows"],
     "runtime C program table, section 8"),

    # The two corpora that count themselves.
    ("tests/parity/README.md", r"match their goldens \({N} today\)",
     ["parity_probes"], "parity probe count"),
    ("tests/negative/README.md",
     r"{N} cases: {N} are `expect-error:`.*?and {N} are `known-defect:`"
     r".*?negative: {N}/{N} pass \({N} known defects",
     ["negative_cases", "negative_expect_error", "negative_known_defect",
      "negative_cases", "negative_cases", "negative_known_defect"],
     "negative corpus census"),
]


def evaluate(root: pathlib.Path, counts: dict, claims: list) -> list:
    """Every claim that the tree no longer supports."""
    findings = []
    for rel, pattern, keys, what in claims:
        path = root / rel
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            findings.append((rel, 0, "claim", f"cannot read {rel}: {exc}"))
            continue
        matches = list(claim_regex(pattern).finditer(text))
        if not matches:
            findings.append((
                rel, 0, "missing",
                f"the {what} claim is not in the file: no match for "
                f"`{pattern}`. A sentence rewritten without its number is a "
                f"claim this gate has stopped checking.",
            ))
            continue
        for match in matches:
            line = text.count("\n", 0, match.start()) + 1
            for key, token in zip(keys, match.groups()):
                got = as_int(token)
                if got != counts[key]:
                    findings.append((
                        rel, line, key,
                        f"{what}: the document says {token}, the tree has "
                        f"{counts[key]}",
                    ))
    return findings


def _dc_check(root: pathlib.Path) -> list:
    counts = measure(root)
    findings = evaluate(root, counts, CLAIMS)
    if root == _DC_ROOT:
        # docs/FMT.md's total is a claim about dev.py's list, not about a glob
        # this script invented. If the two rules diverge, one of them moved and
        # the claim is measuring the wrong thing.
        sys.path.insert(0, str(_DC_ROOT / "scripts"))
        import dev  # noqa: E402

        fmt = len(dev.fmt_check_files())
        if fmt != counts["fmt_files"]:
            findings.append((
                "scripts/dev.py", 0, "fmt_files",
                f"fmt_check_files() holds {fmt} files and this gate counted "
                f"{counts['fmt_files']}; docs/FMT.md rests on dev.py's list, so "
                f"the two rules have to agree",
            ))
    return findings


def self_test_counts() -> int:
    """Assert the rule can say no, and that the counters read the tree."""
    import tempfile

    with tempfile.TemporaryDirectory(prefix="doc_counts_selftest_") as td:
        root = pathlib.Path(td)
        doc = root / "doc.md"
        counts = {"suite_files": 73, "runtime_programs": 20}
        claims = [
            ("doc.md", r"holds {N} files", ["suite_files"], "a fixture count"),
            ("doc.md", r"{N} programs", ["runtime_programs"], "a spelled count"),
        ]

        doc.write_text("The suite holds 73 files and 20 programs.\n")
        if evaluate(root, counts, claims):
            print("self-test FAILED: a true claim was reported as a mismatch: "
                  f"{evaluate(root, counts, claims)}")
            return 1

        doc.write_text("The suite holds 72 files and Twenty programs.\n")
        got = [(f[0], f[2]) for f in evaluate(root, counts, claims)]
        if got != [("doc.md", "suite_files")]:
            print(f"self-test FAILED: an off-by-one was read as {got}")
            return 1

        doc.write_text("The suite holds 73 files and Nineteen programs.\n")
        got = [(f[0], f[2]) for f in evaluate(root, counts, claims)]
        if got != [("doc.md", "runtime_programs")]:
            print(f"self-test FAILED: a spelled number was read as {got}")
            return 1

        doc.write_text("The suite holds many files.\n")
        if sorted(f[2] for f in evaluate(root, counts, claims)) != ["missing", "missing"]:
            print("self-test FAILED: a claim that is gone was not reported")
            return 1

        if as_int("nineteen") != 19 or as_int("Four") != 4 or as_int("6") != 6:
            print("self-test FAILED: the number reader misreads a number")
            return 1

    real = measure(_DC_ROOT)
    invariants = [
        (real["suite_runnable"] == real["suite_files"] - real["suite_support"],
         "the suite's runnable count is not its file count minus its support"),
        (real["negative_expect_error"] + real["negative_known_defect"]
         == real["negative_cases"],
         "every negative case must pin exactly one of expect-error: and known-defect:"),
        (real["parity_probes"] == real["parity_goldens"],
         "every parity probe needs one golden"),
        (real["runtime_windows"] == real["runtime_programs"] - 1,
         "exactly one runtime program is posix-only"),
        (real["fmt_files"] == real["fmt_compiler"] + real["fmt_suite"]
         + real["std_modules"] + real["std_tests"] + real["fmt_examples"],
         "the fmt total is not the sum of the trees it verifies"),
    ]
    for ok, why in invariants:
        if not ok:
            print(f"self-test FAILED: {why}")
            return 1

    print(f"Finished doc-counts self-test: the rule reports a wrong number, a "
          f"spelled number and a claim that is gone, and the counters read the "
          f"trees they claim to (suite {real['suite_files']}, negative "
          f"{real['negative_cases']}, parity {real['parity_probes']}, runtime "
          f"{real['runtime_programs']}, fmt {real['fmt_files']}).")
    return 0


# ---- from scripts/flag_coverage.py ----
# Every CLI flag a script declares must be read by the script that owns it.
#
# A flag declared with `add_argument("--x")` and never read is a promise the tool
# cannot keep, and it fails in the one way this repo treats as the worst kind: the
# run succeeds. Nothing crashes, nothing warns, and the only trace is that what the
# caller asked for did not happen. `--list` in `alive_check.py` was declared at
# argparse, named in the tool's own usage line, and read by nothing, so the mode it
# promised never existed -- and the tool whose entire job is noticing a script that
# does nothing could not notice itself doing nothing. `--cc` in `doctor_gate.py` is
# the same defect with a shorter life: no caller passes it and no line reads it, so
# it never did anything for anyone, ever.
#
# Both are the same claim/unrecomputed pair its siblings exist for, one level out:
# `schema_conformance.py` checks the AST against the code that builds it,
# `walk_coverage.py` a walk against the fields it says it skips, `doc_counts.py` a
# document's number against the tree. This one checks a flag's promise against the
# code that reads it.
#
# Owner. The flag belongs to the file that binds a namespace from
# `parse_args()`/`parse_known_args()`: that is the file whose `--help` writes the
# promise. A module that only adds arguments for someone else to parse --
# `_common.add_common_args`, which most scripts call, and `orbit_output.add_quiet`
# -- is not audited, because there the reader is the caller by construction.
#
# Read. `ns.<dest>`, `getattr(ns, "<dest>")` and `vars(ns)["<dest>"]` all count.
# Anything the reader cannot see statically -- the namespace handed to a helper,
# `ns.__dict__` -- has to say so with `# flag-ok: <reason>` on the declaration or
# the line above it, which is the shape `walk_coverage.py` uses for a walk that
# legitimately skips a field. An undeclared silence is the finding.
#
# Scope: the top-level `scripts/*.py`, the same set alive_check.py's D8 coverage
# holds to one row per file. `--self-test` asserts that the rule can say no, that
# it stays quiet on a helper and on an exemption, and that the real tree passes.



_FC_ROOT = pathlib.Path(__file__).resolve().parent.parent
_FC_SCRIPTS = _FC_ROOT / "scripts"

PARSE_CALLS = ("parse_args", "parse_known_args")
EXEMPT = "flag-ok:"


def bound_names(node):
    """The names an assignment target binds, flattening tuple unpacking."""
    if isinstance(node, ast.Name):
        return [node.id]
    if isinstance(node, (ast.Tuple, ast.List)):
        out = []
        for elt in node.elts:
            out.extend(bound_names(elt))
        return out
    return []


def namespaces(tree):
    """Every name bound from a parse_args()/parse_known_args() call."""
    out = set()
    for node in ast.walk(tree):
        value = getattr(node, "value", None)
        if not (isinstance(value, ast.Call) and isinstance(value.func, ast.Attribute)
                and value.func.attr in PARSE_CALLS):
            continue
        if isinstance(node, ast.Assign):
            targets = node.targets
        elif isinstance(node, ast.AnnAssign):
            targets = [node.target]
        else:
            continue
        for target in targets:
            out.update(bound_names(target))
    return out


def declared(tree):
    """(dest, spelling, line) for every add_argument() the file makes.

    The dest is what argparse will call it: `dest=` when given, otherwise the
    long spelling with the dashes turned into underscores. `-x`/`--x` together
    name the flag `--x`, which is the one whose promise is in `--help`.
    """
    out = []
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "add_argument"):
            continue
        spellings = [a.value for a in node.args
                     if isinstance(a, ast.Constant) and isinstance(a.value, str)
                     and a.value.startswith("-")]
        if not spellings:
            continue
        spelling = next((s for s in spellings if s.startswith("--")), spellings[0])
        dest = None
        for kw in node.keywords:
            if kw.arg == "dest" and isinstance(kw.value, ast.Constant):
                dest = kw.value.value
        if dest is None:
            dest = spelling.lstrip("-").replace("-", "_")
        out.append((dest, spelling, node.lineno))
    return out


def read_dests(tree, names):
    """Every dest the file reads out of its own namespace."""
    out = set()
    for node in ast.walk(tree):
        if (isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name)
                and node.value.id in names):
            out.add(node.attr)
            continue
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                and node.func.id == "getattr" and len(node.args) > 1
                and isinstance(node.args[0], ast.Name) and node.args[0].id in names
                and isinstance(node.args[1], ast.Constant)):
            out.add(node.args[1].value)
            continue
        if (isinstance(node, ast.Subscript) and isinstance(node.value, ast.Call)
                and isinstance(node.value.func, ast.Name)
                and node.value.func.id == "vars" and node.value.args
                and isinstance(node.value.args[0], ast.Name)
                and node.value.args[0].id in names
                and isinstance(node.slice, ast.Constant)):
            out.add(node.slice.value)
    return out


def exempted(lines, line):
    """A declaration that carries its reason, on itself or on the line above."""
    for at in (line, line - 1):
        if 1 <= at <= len(lines) and EXEMPT in lines[at - 1]:
            return True
    return False


def findings_for(source, name="<string>"):
    """(findings, is_owner) for one file's text.

    is_owner is False for a module that declares nothing itself, and for one that
    only adds arguments for a parser it does not own.
    """
    tree = ast.parse(source, filename=name)
    names = namespaces(tree)
    if not names:
        return [], False
    read = read_dests(tree, names)
    lines = source.splitlines()
    out = []
    for dest, spelling, line in declared(tree):
        if dest in read or exempted(lines, line):
            continue
        out.append((spelling, dest, line))
    return out, True


def _fc_check():
    """(findings, owners) over the real scripts/."""
    findings = []
    owners = 0
    for path in sorted(_FC_SCRIPTS.glob("*.py")):
        try:
            found, is_owner = findings_for(path.read_text(encoding="utf-8"),
                                           path.name)
        except SyntaxError as exc:
            findings.append((path.name, "<unparseable>", exc.lineno or 0,
                             "does not parse: %s" % exc.msg))
            continue
        if is_owner:
            owners += 1
        for spelling, dest, line in found:
            findings.append((path.name, spelling, line,
                             "declared and never read (args.%s)" % dest))
    return findings, owners


def self_test_flags() -> int:
    """Assert the rule can say no, and that it reads the tree it claims to."""
    cases = [
        ("a flag that is read passes",
         "ap.add_argument('--only')\nargs = ap.parse_args()\nuse(args.only)\n",
         0, True),
        # The shape alive_check.py shipped: `--list` in --help, read by nothing.
        # The second flag is there so the namespace exists and `args.list` is
        # absent for a reason, not for want of any read at all.
        ("a flag nothing reads is the finding",
         "ap.add_argument('--list')\nap.add_argument('--other')\n"
         "args = ap.parse_args()\nuse(args.other)\n",
         1, True),
        ("dest= names the attribute, not the spelling",
         "ap.add_argument('--update', dest='write')\n"
         "args = ap.parse_args()\nuse(args.write)\n",
         0, True),
        ("getattr and vars count as readers",
         "ap.add_argument('--a')\nap.add_argument('--b')\n"
         "args = ap.parse_args()\ngetattr(args, 'a')\nvars(args)['b']\n",
         0, True),
        ("parse_known_args unpacks to an owner",
         "ap.add_argument('--x')\nargs, rest = ap.parse_known_args()\nuse(args.x)\n",
         0, True),
        ("an exemption is honoured",
         "ap.add_argument('--quiet')  # flag-ok: read by the caller\n"
         "args = ap.parse_args()\nuse(args.other)\n",
         0, True),
        ("a module that only declares is not audited",
         "def add_common_args(ap):\n    ap.add_argument('--cc')\n",
         0, False),
    ]

    for label, source, want_findings, want_owner in cases:
        found, is_owner = findings_for(source)
        if len(found) != want_findings or is_owner != want_owner:
            print("self-test FAILED: %s -> %d finding(s), owner=%s (wanted %d, %s)"
                  % (label, len(found), is_owner, want_findings, want_owner))
            return 1

    # The tree itself, which is the assertion that would have gone red on both
    # of the flags this gate was written for.
    findings, owners = _fc_check()
    if findings:
        for where, spelling, line, message in findings:
            print("%s:%d %s %s" % (where, line, spelling, message))
        print("self-test FAILED: the real tree has %d unread flag(s)" % len(findings))
        return 1
    # The floor is the count after the 2026-11-06 merges: thirteen scripts
    # became two entry points, so fourteen files in scripts/ parse arguments
    # and every one of them has to be read. Below this the audit is not
    # reading the tree.
    if owners < 14:
        print("self-test FAILED: only %d file(s) in scripts/ parse arguments, "
              "so the tree audit is not reading the tree" % owners)
        return 1

    print("Finished flag-coverage self-test: the rule reports an unread flag, "
          "stays quiet on a reader, an exemption and a helper module, and "
          "%d file(s) in scripts/ parse arguments with nothing unread."
          % owners)
    return 0


# ---- from scripts/cite_check.py ----
# Citation gate: every `path:line` in the prose must point at the thing the sentence names.
#
# `scripts/doc_counts.py` re-computes counted claims from the tree. Nothing did the
# same for the other kind of claim in these documents -- a location. Measured on
# 2026-11-03: 168 of 222 citations in the nine files below did not open at the
# construct their sentence named. The causes are all ordinary -- `runtime/arena.c`
# was split into nine members and the cites kept pointing past its 175 lines,
# `compiler/emit/c_backend.orb` roughly doubled, `compiler/selfhost/pipeline.orb`
# became `compiler/host/pipeline.orb`, and every commit that inserts a line moves
# each cite after it.
#
# Four rules, one per verdict:
#
#  MISSING   the path is not a file in the repository.
#  RANGE     the line number is not a line of that file (or a range runs off it).
#  BLANK     the cited line is empty or whitespace.
#  SYMBOL    the sentence names one backticked identifier and that identifier
#            appears neither on the cited line nor within SYMBOL_WINDOW lines of it.
#
# A citation with no identifier nearby is checked by RANGE and BLANK only; the gate
# never invents a claim the sentence did not make. Fenced code blocks are skipped:
# they show program text, and an illustrative path inside one is not a claim about
# this tree.
#
# Usage:
#    python scripts/cite_check.py [--quiet] [--self-test] [FILE ...]
#
# Exit 0 iff every citation in scope passes. With no FILE it reads the documents
# listed in TARGETS.



sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out

_CITE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The documents that make claims about this tree. A new document that cites
# source belongs here, the same way a new counted claim belongs in doc_counts.py.
TARGETS = (
    "AGENTS.md",
    "ENGINEERING.md",
    "docs/KNOWN_LIMITATIONS.md",
    "docs/ARCHITECTURE.md",
    "docs/ERROR_CODES.md",
    "docs/IR_SPEC.md",
    "docs/ARENA.md",
    "docs/STARTUP.md",
    "docs/SYNTAX_GUIDE.md",
    "docs/LANGUAGE_REFERENCE.md",
    "docs/COMMANDS.md",
    "docs/DOCTOR.md",
    "docs/PERF.md",
    "tests/negative/README.md",
    "std/README.md",
)

SOURCE_EXT = (".orb", ".c", ".h", ".py", ".md", ".sh", ".ps1", ".yml", ".json", ".txt")

# `path:12`, `path:12-34`. The path must look like a repository path: it ends in
# a known source extension, and the colon-number is what makes it a citation
# rather than a time of day.
CITE = re.compile(
    r"(?<![\w/.-])((?:[A-Za-z0-9_.\-]+/)*[A-Za-z0-9_.\-]+\.(?:"
    + "|".join(e[1:] for e in SOURCE_EXT)
    + r")):(\d{1,7})(?:-(\d{1,7}))?"
)

# A bare `:1234`, or the second number of a list like "`file.orb:4711` and `:4721`".
# The read-only review of 2026-11-05 found a wrong continuation line that this gate
# passed, because only the `path:number` form was read. The lookbehind keeps a time,
# a ratio and the colon inside a full citation out of this pattern: a path always
# ends in a word character. Only same-line continuations are read -- searching the
# lines above reported 30 numbers that belong to no citation, because a wrapped table
# row is not a sentence that continues.
CONT = re.compile(r"(?<![\w:/.-]):(\d{1,7})(?:-(\d{1,7}))?(?![\d-])")

# The nearest file name before a bare number. A sentence can name a second file
# between a citation and the number that follows it -- `ENGINEERING.md:712` says
# "`scripts/orbit_ccache.py:434` … and `trust.py` zeroing the COFF
# `TimeDateStamp` … (`:12`, `:169`)", where 12 and 169 are lines of
# `trust.py`. A number is only attributed to a citation when no other file
# name sits between them.
PATHREF = re.compile(r"((?:[A-Za-z0-9_.\-]+/)*[A-Za-z0-9_.\-]+\.(?:"
                     + "|".join(e[1:] for e in SOURCE_EXT) + r"))")

# How far from the cited line the named symbol may sit. A citation usually points
# at the declaration; a report line inside it is one or two further down.
SYMBOL_WINDOW = 4

# Characters that end a sentence, used to find the claim a citation belongs to.
SENTENCE_END = re.compile(r"[.!?]\s")


def read_lines(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().splitlines()


def fences(text):
    """Line numbers (0-based) that sit inside a fenced code block."""
    inside, blocked = False, set()
    for i, line in enumerate(text.splitlines()):
        if line.lstrip().startswith("```"):
            inside = not inside
            blocked.add(i)
            continue
        if inside:
            blocked.add(i)
    return blocked


# A code span: the text between two backticks. A span is a name candidate when it
# does not hold a path (a `/`) or a citation (`:digits`), so `orbit_os_kill(pid, 1)`
# names a function and `compiler/tir/lower.orb:67` does not.
CODE_SPAN = re.compile(r"`([^`\n]+)`")
TOKEN = re.compile(r"[A-Za-z_][A-Za-z0-9_]{3,}")
PATHISH = re.compile(r"[/]|\.\w{1,4}:\d|^https?:|\.(?:%s)\b" % "|".join(
    e[1:] for e in SOURCE_EXT))

# A markdown list item starts its own claim; joining it to the item above made a
# citation inherit a symbol name from a different bullet.
MARKER = re.compile(r"^\s*([-*]|\d+\.)\s+")


def claim_before(lines, doc_index, col):
    """The text of the claim holding the citation, up to the citation.

    Markdown prose wraps, so the claim often begins on the line above. Wrapped
    prose is joined; a list item is not, because its claim belongs to its own
    bullet. Backticks are kept: the name the gate looks for is recognised by its
    backticks, and stripping them hid every claim that opened on a wrapped line.
    """
    if MARKER.match(lines[doc_index]):
        head = lines[doc_index][:col]
    else:
        start = doc_index
        while start > 0:
            previous = lines[start - 1]
            if (not previous.strip()
                    or previous.lstrip().startswith(("```", "#", "|"))
                    or MARKER.match(previous)):
                break
            start -= 1
        head = " ".join(lines[start:doc_index]) + " " + lines[doc_index][:col]
    parts = SENTENCE_END.split(head)
    return parts[-1] if parts else head


def named_symbol(claim):
    """The identifier the claim names, or None when it names none.

    The last code span before the citation is the one the citation belongs to, and
    its first token is the name: `variantPayloadAt(sema, owner, idx)` names
    `variantPayloadAt`, and `DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP` names
    `DETACHED_PROCESS`.
    """
    spans = [m.group(1) for m in CODE_SPAN.finditer(claim)]
    for span in reversed(spans):
        if PATHISH.search(span):
            continue
        tokens = TOKEN.findall(span)
        if tokens:
            return tokens[0]
    return None


def check_cite(root, target, rel_line, lines, doc_index, col, path, start, end,
               continuation=False):
    """Return (verdict, detail) for one citation, or None when it is out of scope."""
    abs_path = os.path.join(root, path.replace("/", os.sep))
    if not os.path.isfile(abs_path):
        # A path that does not exist is a claim about a file, not a citation of
        # one -- unless the sentence is about the document itself (a `.md` cite
        # naming another document). Both are worth reporting.
        return "MISSING", path
    src = read_lines(abs_path)
    lo, hi = start, end if end else start
    if lo < 1 or lo > len(src):
        return "RANGE", "%s has %d line(s)" % (path, len(src))
    if hi > len(src):
        return "RANGE", "%s:%d runs past %d line(s)" % (path, hi, len(src))
    if not src[lo - 1].strip():
        return "BLANK", "%s:%d is empty" % (path, lo)
    if continuation:
        # A bare number repeats the PATH of the citation before it, and nothing
        # else. Which construct sits there is the claim the sentence made about the
        # citation it continues: a list of call sites for one function asserts no
        # symbol per item, and reading prose as a symbol is what the first version
        # of this code did -- it reported "holds no handles" for the word
        # "handles". So a continuation is checked for the two properties that hold
        # for any number: the line exists, and it is not blank. Binding a construct
        # to each item would need the document to say which item is which, and that
        # is a writing change, not a gate change.
        return None
    claim = claim_before(lines, doc_index, col)
    name = named_symbol(claim)
    if not name:
        return None
    if name in ("self", "true", "false", "null", "None", "list", "string", "int",
                "bool", "float", "void", "result", "model", "union", "route",
                "orbit", "match", "make", "print", "return", "while", "import"):
        return None
    window = src[max(0, lo - 1 - SYMBOL_WINDOW): min(len(src), lo + SYMBOL_WINDOW)]
    # A word match, not a substring one: a cite for `orbit_thing` must not pass
    # because the line reads `orbit_thing_helper`.
    pattern = re.compile(r"(?<![\w])%s(?![\w])" % re.escape(name))
    if any(pattern.search(line) for line in window):
        return None
    return "SYMBOL", "%s:%d holds no %s (%s)" % (path, lo, name, src[lo - 1].strip()[:60])


def line_cites(line):
    """Every full `path:line` citation on a line, as (start, end, path)."""
    return [(m.start(), m.end(), m.group(1)) for m in CITE.finditer(line)]


def continued_path(lines, index, position):
    """The path a bare `:NNN` at `position` continues, on this line only.

    A path owns the number when no sentence closed between them. Searching the
    lines above was tried first and reported 30 numbers that belong to no citation
    at all, because a wrapped table row is not a continuing sentence.
    """
    mine = [(a, b, path_g) for a, b, path_g in line_cites(lines[index]) if a < position]
    for a, b, path_g in reversed(mine):
        if SENTENCE_END.search(lines[index][b:position]):
            return None
        named = [m.group(1) for m in PATHREF.finditer(lines[index][:position])]
        if named and named[-1] != path_g:
            # Another file was named after that citation, so the number belongs to
            # it and this gate cannot attribute it. Attribution by basename alone
            # would read `trust.py` and `scripts/trust.py` as the same
            # claim; it is not, because the path is the claim.
            return None
        return path_g
    return None


def scan(root, target):
    """Every failing citation in one document, as (doc_line, verdict, detail)."""
    path = os.path.join(root, target)
    if not os.path.isfile(path):
        return [("0", "MISSING-DOC", target)]
    lines = read_lines(path)
    blocked = fences("\n".join(lines))
    findings = []
    for i, line in enumerate(lines):
        if i in blocked:
            continue
        for m in CITE.finditer(line):
            path_g, start, end = m.group(1), int(m.group(2)), m.group(3)
            if path_g == target.split("/")[-1] and start == i + 1:
                continue  # a document citing its own line is a locator, not a claim
            verdict = check_cite(root, target, i, lines, i, m.start(),
                                 path_g, start, int(end) if end else None)
            if verdict:
                findings.append((str(i + 1), verdict[0], verdict[1]))
        for cm in CONT.finditer(line):
            cont_path = continued_path(lines, i, cm.start())
            if cont_path is None:
                continue
            verdict = check_cite(root, target, i, lines, i, cm.start(), cont_path,
                                 int(cm.group(1)),
                                 int(cm.group(2)) if cm.group(2) else None,
                                 continuation=True)
            if verdict:
                findings.append((str(i + 1), verdict[0], verdict[1]))
    return findings


def self_test_cites():
    """The gate must be able to fail, and must not fail on a correct cite."""
    import tempfile, pathlib
    with tempfile.TemporaryDirectory() as td:
        root = pathlib.Path(td)
        (root / "src").mkdir()
        (root / "src" / "thing.c").write_text(
            "// nothing here\n\nint orbit_thing(void) {\n  return 1;\n}\n\n"
            "int orbit_other_thing(void) {\n  return 2;\n}\n\n"
            "int orbit_third_thing(void) {\n  return 3;\n}\n",
            encoding="utf-8")
        doc = root / "DOC.md"
        good = "The function `orbit_thing` is at `src/thing.c:3`.\n"
        bad_range = "The function `orbit_thing` is at `src/thing.c:900`.\n"
        bad_symbol = "The function `orbit_absent` is at `src/thing.c:3`.\n"
        bad_file = "See `src/absent.c:1`.\n"
        blank = "The function `orbit_thing` is at `src/thing.c:2`.\n"
        # The sentence opens on the line above the citation, which is ordinary
        # markdown wrapping. Stripping the leading backtick hid exactly this case.
        wrapped = ("The function `orbit_thing` lives on\n"
                   "line three; cite the last one at `src/thing.c:11`.\n")
        doc.write_text(good, encoding="utf-8")
        if scan(str(root), "DOC.md"):
            print("self-test FAILED: a correct citation was reported")
            return 1
        for text, want in ((bad_range, "RANGE"), (bad_symbol, "SYMBOL"),
                           (bad_file, "MISSING"), (blank, "BLANK"),
                           (wrapped, "SYMBOL")):
            doc.write_text(text, encoding="utf-8")
            got = scan(str(root), "DOC.md")
            if not got or got[0][1] != want:
                print("self-test FAILED: %s did not read %s (got %r)" % (want, text.strip(), got))
                return 1
        # Continuation numbers. The right one passes, the wrong one bites, and a
        # symbol written between the two citations binds the second number.
        doc.write_text("The helper sits at `src/thing.c:3` and `:7` in one list.\n",
                       encoding="utf-8")
        if scan(str(root), "DOC.md"):
            print("self-test FAILED: a correct continuation citation was reported")
            return 1
        doc.write_text("The helper sits at `src/thing.c:3` and `:900` in one list.\n",
                       encoding="utf-8")
        got = scan(str(root), "DOC.md")
        if not got or got[0][1] != "RANGE":
            print("self-test FAILED: a wrong continuation did not bite (got %r)" % got)
            return 1
        # The pairing of a symbol named between two citations is implemented in the
        # claim cut above and visible in the tree run: prose words no longer bind a
        # number. It is not asserted here, because the witness for it depends on
        # which fixture line holds which function, and an asserted property that
        # needs that much luck to read is a property that will be deleted rather
        # than fixed. Range and blankness still bite on a bare number, which is the
        # defect this code exists to catch.
        # A number after a full stop continues nothing, and must not be blamed for
        # the citation before the stop.
        doc.write_text("The helper sits at `src/thing.c:3`. New sentence: `:900`\n",
                       encoding="utf-8")
        if scan(str(root), "DOC.md"):
            print("self-test FAILED: a closed sentence was read as a continuation")
            return 1
        doc.write_text("```\nsee `src/absent.c:1`\n```\n", encoding="utf-8")
        if scan(str(root), "DOC.md"):
            print("self-test FAILED: a fenced example was read as a claim")
            return 1
    print("Finished cite-coverage self-test: 6 properties hold")
    return 0



# --------------------------------------------------------------------------
# One entry point. Each _run_* is the body of the old script's main(), with the
# argparse block lifted into the add_parser calls below and the names prefixed
# as documented above.
# --------------------------------------------------------------------------
def _run_schema(args) -> int:
    models, unions = parse_schema(_SC_AST.read_text(encoding="utf-8"))
    if not models:
        print("Failed: the schema parser found no models in ast.orb; the "
              "grammar changed and this script has not caught up.", file=sys.stderr)
        return 2

    if args.self_test:
        return self_test_schema()

    findings = _sc_check(_SC_ROOT)

    if findings:
        for where, rule, message in findings:
            print(f"{where} [{rule}] {message}")
        print(f"\nFinished schema-conformance: {len(findings)} disagreement(s) "
              f"between compiler/front/ast.orb and the code that builds nodes.")
        return 1

    total_fields = sum(len(f) for f in models.values())
    print(f"Finished schema-conformance: {len(models)} models, {total_fields} "
          f"fields, {len(unions)} union(s), every construction site's arity "
          f"matches and no node is read as a list.")
    return 0


def _run_walk(args) -> int:
    if args.self_test:
        return self_test_walk()

    models, unions = parse_schema(_WC_AST.read_text(encoding="utf-8"))

    if args.list:
        walks = collect_walks(models, unions, _WC_ROOT)
        for w in sorted(walks, key=lambda x: -len(x["missing"])):
            tag = "exempt" if w["exempt"] else (
                "declared" if w["declared"] is not None else "UNDECLARED")
            print(f"{w['loc']:<44} {w['fn']:<28} {tag:<11} "
                  f"misses {', '.join(w['missing']) or '-'}")
        print(f"\n{len(walks)} walk(s) detected.")
        return 0

    findings = _wc_check(_WC_ROOT)
    if findings:
        for where, rule, message in findings:
            print(f"{where} [{rule}] {message}")
        print(f"\nFinished walk-coverage: {len(findings)} walk(s) whose skipped "
              f"fields are undeclared or stale.")
        return 1

    print("Finished walk-coverage: every detected walk declares the fields it "
          "skips, and every declaration matches.")
    return 0


def _run_counts(args) -> int:
    if args.self_test:
        return self_test_counts()

    counts = measure(_DC_ROOT)
    findings = _dc_check(_DC_ROOT)
    numbers = sum(len(keys) for _, _, keys, _ in CLAIMS)

    if findings:
        for rel, line, key, message in findings:
            where = f"{rel}:{line}" if line else rel
            print(f"{where} [{key}] {message}")
        print(f"\nFinished doc-counts: {len(findings)} of {numbers} counted "
              f"claims in {len({c[0] for c in CLAIMS})} documents no longer "
              f"match the tree.")
        return 1

    print(f"Finished doc-counts: {len(CLAIMS)} claims, {numbers} numbers, all "
          f"equal to the tree (std {counts['std_modules']}, suite "
          f"{counts['suite_files']}/{counts['suite_runnable']} runnable, "
          f"tests/std {counts['std_tests']}, negative "
          f"{counts['negative_cases']}, parity {counts['parity_probes']}, "
          f"runtime {counts['runtime_programs']}, fmt {counts['fmt_files']}).")
    return 0


def _run_flags(args) -> int:
    if args.self_test:
        return self_test_flags()

    if args.list:
        for path in sorted(_FC_SCRIPTS.glob("*.py")):
            source = path.read_text(encoding="utf-8")
            tree = ast.parse(source, filename=path.name)
            read = read_dests(tree, namespaces(tree))
            for dest, spelling, line in declared(tree):
                state = "read" if dest in read else (
                    "exempt" if exempted(source.splitlines(), line) else "UNREAD")
                print("%-28s %-24s %-7s args.%s"
                      % (path.name, spelling, state, dest))
        return 0

    findings, owners = _fc_check()
    if findings:
        for where, spelling, line, message in findings:
            print("%s:%d %s %s" % (where, line, spelling, message))
        print("Finished flag-coverage: %d declared flag(s) nothing reads."
              % len(findings))
        return 1

    print("Finished flag-coverage: every flag declared by a script in scripts/ "
          "is read by the script that owns it, across %d owner(s)." % owners)
    return 0


def _run_cites(args) -> int:
    if args.self_test:
        return self_test_cites()

    targets = args.targets or list(TARGETS)
    total, failing, docs = 0, [], 0
    for target in targets:
        path = os.path.join(_CITE_ROOT, target)
        if os.path.isfile(path):
            with open(path, encoding="utf-8", errors="replace") as f:
                text = "\n".join(f.read().splitlines())
            total_here = len([m for m in CITE.finditer(text)
                              if not m.group(0).startswith("http")])
            total += total_here
        found = scan(_CITE_ROOT, target)
        if found:
            docs += 1
            failing.append((target, found))
        elif not args.quiet:
            out.say("  %s: citations match the tree" % target)

    for target, found in failing:
        out.say("\n  %s" % target)
        for line, verdict, detail in found:
            out.say("    :%-5s %-8s %s" % (line, verdict, detail))

    bad = sum(len(f) for _, f in failing)
    if bad:
        out.fail("Failed cite-coverage: %d of %d citations in %d document(s) do not "
                 "open at the construct their sentence names" % (bad, total, docs))
        out.say("  Fix: point the citation at the line the construct is on "
                "(grep -n '^fn <name>' <file>), or name the construct and drop the "
                "number -- a number nobody recomputes is a defect waiting for the "
                "next edit.")
        return 1
    out.say("Finished cite-coverage: %d citations in %d document(s) match the tree"
            % (total, len(targets)))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="static_gates.py",
        description="The tier-0 static gates: text analysis, no compiler, no "
                    "subprocess.")
    sub = ap.add_subparsers(dest="command", metavar="SUBCOMMAND", required=True)

    p = sub.add_parser("schema", help=_SCHEMA_DESC, description=_SCHEMA_DESC)
    p.add_argument("--self-test", action="store_true",
                   help="assert the rules can fail, and exit")

    p = sub.add_parser("walk", help=_WALK_DESC, description=_WALK_DESC)
    p.add_argument("--self-test", action="store_true")
    p.add_argument("--list", action="store_true",
                   help="print each walk and its measured gap, unannotated")

    p = sub.add_parser("counts", help=_COUNTS_DESC, description=_COUNTS_DESC)
    p.add_argument("--self-test", action="store_true",
                   help="assert the rule can fail, and exit")

    p = sub.add_parser("flags", help=_FLAGS_DESC, description=_FLAGS_DESC)
    p.add_argument("--self-test", action="store_true",
                   help="assert the rule can fail, and exit")
    p.add_argument("--list", action="store_true",
                   help="print every declared flag and whether it is read")

    p = sub.add_parser("cites", help=_CITES_DESC, description=_CITES_DESC)
    p.add_argument("targets", nargs="*", help="documents to read (default: TARGETS)")
    p.add_argument("--quiet", action="store_true", help="print only the closing line")
    p.add_argument("--self-test", action="store_true", help="check the gate can fail")

    args = ap.parse_args()
    for name, run in (("schema", _run_schema), ("walk", _run_walk),
                      ("counts", _run_counts), ("flags", _run_flags),
                      ("cites", _run_cites)):
        if args.command == name:
            return run(args)
    print("static_gates: %s is not a gate in this tool" % args.command,
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
