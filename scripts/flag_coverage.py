#!/usr/bin/env python3
"""Every CLI flag a script declares must be read by the script that owns it.

A flag declared with `add_argument("--x")` and never read is a promise the tool
cannot keep, and it fails in the one way this repo treats as the worst kind: the
run succeeds. Nothing crashes, nothing warns, and the only trace is that what the
caller asked for did not happen. `--list` in `alive_check.py` was declared at
argparse, named in the tool's own usage line, and read by nothing, so the mode it
promised never existed -- and the tool whose entire job is noticing a script that
does nothing could not notice itself doing nothing. `--cc` in `doctor_gate.py` is
the same defect with a shorter life: no caller passes it and no line reads it, so
it never did anything for anyone, ever.

Both are the same claim/unrecomputed pair its siblings exist for, one level out:
`schema_conformance.py` checks the AST against the code that builds it,
`walk_coverage.py` a walk against the fields it says it skips, `doc_counts.py` a
document's number against the tree. This one checks a flag's promise against the
code that reads it.

Owner. The flag belongs to the file that binds a namespace from
`parse_args()`/`parse_known_args()`: that is the file whose `--help` writes the
promise. A module that only adds arguments for someone else to parse --
`_common.add_common_args`, which most scripts call, and `orbit_output.add_quiet`
-- is not audited, because there the reader is the caller by construction.

Read. `ns.<dest>`, `getattr(ns, "<dest>")` and `vars(ns)["<dest>"]` all count.
Anything the reader cannot see statically -- the namespace handed to a helper,
`ns.__dict__` -- has to say so with `# flag-ok: <reason>` on the declaration or
the line above it, which is the shape `walk_coverage.py` uses for a walk that
legitimately skips a field. An undeclared silence is the finding.

Scope: the top-level `scripts/*.py`, the same set alive_check.py's D8 coverage
holds to one row per file. `--self-test` asserts that the rule can say no, that
it stays quiet on a helper and on an exemption, and that the real tree passes.
"""

import argparse
import ast
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"

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


def check():
    """(findings, owners) over the real scripts/."""
    findings = []
    owners = 0
    for path in sorted(SCRIPTS.glob("*.py")):
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


def self_test() -> int:
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
    findings, owners = check()
    if findings:
        for where, spelling, line, message in findings:
            print("%s:%d %s %s" % (where, line, spelling, message))
        print("self-test FAILED: the real tree has %d unread flag(s)" % len(findings))
        return 1
    if owners < 20:
        print("self-test FAILED: only %d file(s) in scripts/ parse arguments, "
              "so the tree audit is not reading the tree" % owners)
        return 1

    print("Finished flag-coverage self-test: the rule reports an unread flag, "
          "stays quiet on a reader, an exemption and a helper module, and "
          "%d file(s) in scripts/ parse arguments with nothing unread."
          % owners)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--self-test", action="store_true",
                    help="assert the rule can fail, and exit")
    ap.add_argument("--list", action="store_true",
                    help="print every declared flag and whether it is read")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    if args.list:
        for path in sorted(SCRIPTS.glob("*.py")):
            source = path.read_text(encoding="utf-8")
            tree = ast.parse(source, filename=path.name)
            read = read_dests(tree, namespaces(tree))
            for dest, spelling, line in declared(tree):
                state = "read" if dest in read else (
                    "exempt" if exempted(source.splitlines(), line) else "UNREAD")
                print("%-28s %-24s %-7s args.%s"
                      % (path.name, spelling, state, dest))
        return 0

    findings, owners = check()
    if findings:
        for where, spelling, line, message in findings:
            print("%s:%d %s %s" % (where, line, spelling, message))
        print("Finished flag-coverage: %d declared flag(s) nothing reads."
              % len(findings))
        return 1

    print("Finished flag-coverage: every flag declared by a script in scripts/ "
          "is read by the script that owns it, across %d owner(s)." % owners)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
