#!/usr/bin/env python3
"""Coverage: every ASTNode variant has an arm in the one checker (D9).

The incident this exists for: sema.orb had two functions that both walked the
AST -- `checkNode` dispatched to the check* family, `inferType` returned a
type -- and they overlapped on 13 of 42 arms. Eleven callers reached only one of
them. A check added to `checkNode` therefore did not run for every program that
contained the node, and nothing said so. It cost three hours to find out, and
the wrong version of the check reported a line number of 25515 for a four-line
file.

The two are now one function. That fixes the instance and removes the
invitation, but only for as long as nobody adds a third walker or forgets an
arm. This checks the shape:

  1. every variant of `type ASTNode` has an arm in checkNode's match;
  2. every arm of that match returns on every path, so the declared
     `-> string` is not a promise the body breaks;
  3. the old `inferType` is gone, so there is no second place to add a check
     to by accident.

(1) is the invariant. A new ASTNode variant with no arm is not a compile error
today -- it falls to the `_` arm and returns "" -- and that is precisely how a
check silently stops running. (2) is what a missing `return` looks like from
the outside: a segfault in the checker, with no line number. (3) is the cheap
one, and it is the one that would have caught this before it was written.

Exits 0 when the shape holds, 1 when it does not.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AST = os.path.join(ROOT, "compiler", "ast.orb")
SEMA = os.path.join(ROOT, "compiler", "sema.orb")


def fail(problems):
    for p in problems:
        print("  %s" % p, file=sys.stderr)
    print("FAILED dispatch-coverage: %d problem(s)" % len(problems), file=sys.stderr)
    return 1


def depth_map(text):
    """Depth of braces at each character offset."""
    out = []
    d = 0
    for ch in text:
        if ch == "{":
            out.append(d)
            d += 1
        elif ch == "}":
            d -= 1
            out.append(d)
        else:
            out.append(d)
    return out


def fn_span(text, signature):
    """Start, end and body-open-brace of a top-level fn."""
    i = text.index(signature)
    j = text.index("{", i)
    d = 0
    k = j
    while True:
        if text[k] == "{":
            d += 1
        elif text[k] == "}":
            d -= 1
            if d == 0:
                return i, k + 1, j
        k += 1
    raise ValueError("unterminated %s" % signature)


def match_arms(text, offset=0):
    """Arms of the outermost match, keyed by variant name.

    A nested `match` inside an arm has arms of its own, and taking those for
    the outer match is how a refactor once moved the body of
    `ASTNode.Call(innerCall)` on top of the top-level `Call`. The outermost arms
    are the ones at the shallowest depth, so that is what this selects.
    """
    dm = depth_map(text)
    found = []
    for m in re.finditer(r"ASTNode\.(\w+)(\([^)]*\))?\s*=>\s*\{", text):
        found.append((dm[m.end() - 1], m))
    if not found:
        return {}, None
    base = min(d for d, _ in found)
    arms = {}
    for depth, m in found:
        if depth != base or m.group(1) in arms:
            continue
        d = 0
        k = m.end() - 1
        while True:
            if text[k] == "{":
                d += 1
            elif text[k] == "}":
                d -= 1
                if d == 0:
                    break
            k += 1
        arms[m.group(1)] = (m.start(), m.end(), k + 1)
    return arms, base


def variants(ast_text):
    m = re.search(r"(?m)^type ASTNode = (.*)$", ast_text)
    if not m:
        raise ValueError("no `type ASTNode` in ast.orb")
    return [v.split("(")[0].strip() for v in m.group(1).split("|")]


def main():
    with open(AST) as f:
        ast_text = f.read()
    with open(SEMA) as f:
        sema_text = f.read()

    problems = []

    # 3. the second walker is gone
    if re.search(r"(?m)^fn inferType\(", sema_text):
        problems.append(
            "compiler/sema.orb still defines inferType. There is one checker, "
            "checkNode; a second walker is how a check ends up running for "
            "some programs and not others."
        )
    leftover = re.findall(r"inferType\(sema,", sema_text)
    if leftover:
        problems.append(
            "compiler/sema.orb still calls inferType in %d place(s)."
            % len(leftover)
        )

    sig = "fn checkNode(sema: Sema, node: ASTNode) -> string {"
    if sig not in sema_text:
        problems.append(
            "checkNode is not declared as `-> string`. The merged checker has "
            "to return the type it infers, or the whole point is lost."
        )
        return fail(problems)

    start, end, _ = fn_span(sema_text, sig)
    body = sema_text[start:end]
    arms, _ = match_arms(body)

    # 1. every variant has an arm
    vs = variants(ast_text)
    missing = [v for v in vs if v not in arms]
    if missing:
        problems.append(
            "ASTNode variants with no arm in checkNode: %s. An unhandled "
            "variant falls to the `_` arm and returns \"\", which is how a "
            "check silently stops running." % ", ".join(missing)
        )

    # 2. every arm returns
    silent = []
    for name, (_, b, e) in sorted(arms.items()):
        if "return" not in body[b:e]:
            silent.append(name)
    if silent:
        problems.append(
            "checkNode arms with no return: %s. checkNode declares -> string, "
            "so a path that falls off the end reads an unset return value -- a "
            "segfault in the checker, with no line number." % ", ".join(silent)
        )

    # the `_` fallback has to answer too
    if not re.search(r"_\s*=>\s*\{[^}]*\breturn\b", body):
        problems.append(
            "checkNode's `_` fallback does not return. Every path out of a "
            "-> string function has to produce a string."
        )

    if problems:
        return fail(problems)

    print("dispatch-coverage: %d ASTNode variants, %d arms, all returning" % (len(vs), len(arms)))
    print("  one checker: inferType is gone and nothing calls it")
    print("Finished dispatch-coverage: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
