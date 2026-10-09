#!/usr/bin/env python3
"""Report AST walks in this compiler that do not say which fields they skip.

A walk over `ASTNode` that does not reach a child field drops that whole subtree,
and nothing in the compiler says so. Three bugs in `compiler/doctor.orb` were
exactly this: an arm existed for the node and the walk never descended into one
of its fields. `Call.callee` dropped the receiver's own arguments,
`Assignment.target` dropped the index of `xs[i] = 7`, and `MatchCase.pattern`
dropped the comparison of `target =>`. In each case a live value read as
never-read and the check reported a dead store that was not dead, while every
golden was green.

Why this is a declaration check and not a defect check: arm counting cannot tell
a walk from a function that merely matches. Measured on this tree, 158 matches on
`ASTNode`, every one ending in `_ =>`, none exhaustive -- and the worst offenders
by that measure are `parsePrimary`, which BUILDS nodes and has no children to
visit, `listKindNameOf`, which asks what type an expression is, and
`resolveExprType`, which does the same for the backend. A gate that called those
bugs would be wrong on the first run and switched off on the second, which is
what already happened here once: a scope gate that counted D015/D017/D018 went
red the day those checks shipped.

So the walk declares its own contract, and this checks the declaration against
reality:

    // orbit-walk: none -- builds nodes; it has no children to visit
    fn parsePrimary(...)              -- not a walk, and the reason says why

    // orbit-walk-misses: FunctionDecl, RouteDecl
    fn doctorDeadWalk(...)            -- the list MUST equal the real gap

Two findings, both about the declaration rather than the code:

    undeclared   a walk with a gap and no `orbit-walk-misses` line. The gap may
                 be correct; the point is that nobody wrote down that it is.
    stale        the annotation disagrees with the measured gap. A field was
                 added to a model, or an arm was added to a walk, and the
                 declaration was not updated with it.

What it cannot do, stated so nobody over-trusts it, twice, because both were
learned by using it: it cannot tell you a declared gap is wrong, because that is
a judgement about intent; and it cannot tell you an UNDECLARED gap is real,
because "has no arm of its own" and "is never visited" are different questions.
Three walks that declare a gap were probed by hand and all three were correct --
doctorShadowStmt through match arms, D023 through constructor patterns, and D025
through a method call's arguments -- and the gaps were the measurement's, not the
code's. It guarantees only that no gap is unremarked. The companion that measures real visits is
`tests/doctor/golden/walk_coverage_all_child_fields`, which plants a read in
every field and fails when a walk cannot see one -- and which covers doctor's
walks, not the compiler's, because the compiler's walks have no observable
output to probe from outside.

A walk is detected structurally: a function with a `match` on `ASTNode` that
recurses into itself after that match. `orbit-walk: none` overrides the
detection for the cases the heuristic gets wrong.
"""

import argparse
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from schema_conformance import parse_schema  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
AST = ROOT / "compiler" / "ast.orb"

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
        src = path.read_text()
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


def check(root: pathlib.Path) -> list:
    models, unions = parse_schema((root / "compiler" / "ast.orb").read_text())
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


def self_test() -> int:
    """Assert the rules can say no, and that the exemption works."""
    import tempfile

    schema = ("model MNode {\n    body: ASTNode\n    names: list\n}\n"
              "type ASTNode = M(MNode)\n")

    def tree(schema_text, source):
        td = tempfile.TemporaryDirectory(prefix="walk_coverage_selftest_")
        root = pathlib.Path(td.name)
        (root / "compiler").mkdir(parents=True)
        (root / "compiler" / "ast.orb").write_text(schema_text)
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
    got = {f[1] for f in check(root)}
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
    got = {f[1] for f in check(root)}
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
    got = {f[1] for f in check(root)}
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
    got = {f[1] for f in check(root)}
    td.cleanup()
    if got:
        print(f"self-test FAILED: orbit-walk: none should exempt, and raised "
              f"{sorted(got)}")
        return 1

    print("Finished walk-coverage self-test: 4/4 rules fired; an accurate "
          "declaration is silent; `orbit-walk: none` exempts.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--list", action="store_true",
                    help="print each walk and its measured gap, unannotated")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    models, unions = parse_schema(AST.read_text())

    if args.list:
        walks = collect_walks(models, unions, ROOT)
        for w in sorted(walks, key=lambda x: -len(x["missing"])):
            tag = "exempt" if w["exempt"] else (
                "declared" if w["declared"] is not None else "UNDECLARED")
            print(f"{w['loc']:<44} {w['fn']:<28} {tag:<11} "
                  f"misses {', '.join(w['missing']) or '-'}")
        print(f"\n{len(walks)} walk(s) detected.")
        return 0

    findings = check(ROOT)
    if findings:
        for where, rule, message in findings:
            print(f"{where} [{rule}] {message}")
        print(f"\nFinished walk-coverage: {len(findings)} walk(s) whose skipped "
              f"fields are undeclared or stale.")
        return 1

    print("Finished walk-coverage: every detected walk declares the fields it "
          "skips, and every declaration matches.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())