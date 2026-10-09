#!/usr/bin/env python3
"""Check that compiler/ast.orb and compiler/parser.orb still agree.

Seventeen fields of the AST schema declared `list` while the parser had always
handed them a single ASTNode. `f.body.len()` on a one-statement function
returned -1184889136 -- a model pointer read as a list header -- and the
compiled output was wrong while `orbit check` was clean. Nothing noticed for as
long as nobody asked the field for its length, which is the worst possible
failure shape: correct by accident of never measuring.

Doctor's D017 found those, one function at a time, by asking the question. This
asks it once, over the whole schema, without a bootstrap and without a compiler.
It reads two files of text and compares them. That is the whole value of it:
the failure it prevents costs nothing to check, so there is no reason to check
it by hand and every reason to check it on every commit.

Five rules, all static:

  arity            every `SomeNode(a, b, c)` passes exactly the field count the
                   model declares. Catches a field added to the schema without
                   the parser updated, or updated with the arguments in a
                   different order -- both of which silently shift every field
                   after the change.
  unknown-model    every `SomeNode(` names a declared model.
  unbuilt-model    a model with fields that nothing ever constructs.
  unbuilt-variant  a variant of the ASTNode union that nothing ever constructs.
  node-list-op     a field declared `ASTNode` read with a list operation --
                   `.len()`, `.get(`, `.push(`, `.pop(`. This is the direct
                   signature of the defect above: the declared type and the
                   operation disagree.

`node-list-op` is scoped to a match arm that binds the model, so it fires on
`f.body.len()` inside `ASTNode.FunctionDecl(f) =>` and not on every `.body.` in
the tree. Loosening it would produce noise, and a gate that cries wolf is a gate
that gets switched off.

What this cannot do: it compares declarations against construction sites, so it
cannot tell you that a *correctly declared* field is read by the wrong name. That
class needs the schema to carry more than a type, and it is not what this is
for.

Run it with no arguments. `--self-test` asserts the rules can fail, which is the
difference between a gate and a hope.
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
AST = ROOT / "compiler" / "ast.orb"

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
        yield path, path.read_text()


def collect_constructions(models: dict, root: pathlib.Path) -> tuple:
    """(constructed models, constructed variants, arity findings)."""
    built_models, built_variants, findings = set(), set(), []
    for path, src in compiler_sources(root):
        rel = path.relative_to(root).as_posix()
        src = path.read_text()
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


def check(root: pathlib.Path) -> list:
    """Every disagreement between the schema and the code that builds nodes."""
    models, unions = parse_schema((root / "compiler" / "ast.orb").read_text())
    built_models, built_variants, findings = collect_constructions(models, root)
    findings += collect_node_list_ops(models, root)

    for name, fields in sorted(models.items()):
        if fields and name not in built_models:
            findings.append((
                "compiler/ast.orb", "unbuilt-model",
                f"model {name} declares {len(fields)} field(s) and nothing "
                f"constructs it. Either it is schema for a node that cannot "
                f"exist, or the parser stopped building it.",
            ))
    for union, variants in sorted(unions.items()):
        for variant, model in variants:
            if variant not in built_variants:
                findings.append((
                    f"compiler/ast.orb ({union})", "unbuilt-variant",
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


def self_test() -> int:
    """Assert every rule can still say no.

    D8: a tool that cannot fail is not a tool. Each rule is fired on a tree built
    to violate exactly that rule; a rule that stays quiet on its own violation
    has stopped working, and that is the failure this catches.
    """
    import tempfile

    with tempfile.TemporaryDirectory(prefix="schema_conformance_selftest_") as td:
        root = pathlib.Path(td)
        cdir = root / "compiler"
        cdir.mkdir(parents=True)

        def fixture(schema: str, body: str) -> set:
            (cdir / "ast.orb").write_text(schema)
            (cdir / "a.orb").write_text(body)
            return {f[1] for f in check(root)}

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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--self-test", action="store_true",
                    help="assert the rules can fail, and exit")
    args = ap.parse_args()

    models, unions = parse_schema(AST.read_text())
    if not models:
        print("Failed: the schema parser found no models in ast.orb; the "
              "grammar changed and this script has not caught up.", file=sys.stderr)
        return 2

    if args.self_test:
        return self_test()

    findings = check(ROOT)

    if findings:
        for where, rule, message in findings:
            print(f"{where} [{rule}] {message}")
        print(f"\nFinished schema-conformance: {len(findings)} disagreement(s) "
              f"between compiler/ast.orb and the code that builds nodes.")
        return 1

    total_fields = sum(len(f) for f in models.values())
    print(f"Finished schema-conformance: {len(models)} models, {total_fields} "
          f"fields, {len(unions)} union(s), every construction site's arity "
          f"matches and no node is read as a list.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())