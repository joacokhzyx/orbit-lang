#!/usr/bin/env python3
"""Citation gate: every `path:line` in the prose must point at the thing the sentence names.

`scripts/doc_counts.py` re-computes counted claims from the tree. Nothing did the
same for the other kind of claim in these documents -- a location. Measured on
2026-11-03: 168 of 222 citations in the nine files below did not open at the
construct their sentence named. The causes are all ordinary -- `runtime/arena.c`
was split into nine members and the cites kept pointing past its 175 lines,
`compiler/emit/c_backend.orb` roughly doubled, `compiler/selfhost/pipeline.orb`
became `compiler/host/pipeline.orb`, and every commit that inserts a line moves
each cite after it.

Four rules, one per verdict:

  MISSING   the path is not a file in the repository.
  RANGE     the line number is not a line of that file (or a range runs off it).
  BLANK     the cited line is empty or whitespace.
  SYMBOL    the sentence names one backticked identifier and that identifier
            appears neither on the cited line nor within SYMBOL_WINDOW lines of it.

A citation with no identifier nearby is checked by RANGE and BLANK only; the gate
never invents a claim the sentence did not make. Fenced code blocks are skipped:
they show program text, and an illustrative path inside one is not a claim about
this tree.

Usage:
    python scripts/cite_check.py [--quiet] [--self-test] [FILE ...]

Exit 0 iff every citation in scope passes. With no FILE it reads the documents
listed in TARGETS.
"""

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

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


def check_cite(root, target, rel_line, lines, doc_index, col, path, start, end):
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
    return findings


def _self_test():
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
        doc.write_text("```\nsee `src/absent.c:1`\n```\n", encoding="utf-8")
        if scan(str(root), "DOC.md"):
            print("self-test FAILED: a fenced example was read as a claim")
            return 1
    print("Finished cite-coverage self-test: 6 properties hold")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("targets", nargs="*", help="documents to read (default: TARGETS)")
    ap.add_argument("--quiet", action="store_true", help="print only the closing line")
    ap.add_argument("--self-test", action="store_true", help="check the gate can fail")
    args = ap.parse_args()

    if args.self_test:
        return _self_test()

    targets = args.targets or list(TARGETS)
    total, failing, docs = 0, [], 0
    for target in targets:
        path = os.path.join(ROOT, target)
        if os.path.isfile(path):
            with open(path, encoding="utf-8", errors="replace") as f:
                text = "\n".join(f.read().splitlines())
            total_here = len([m for m in CITE.finditer(text)
                              if not m.group(0).startswith("http")])
            total += total_here
        found = scan(ROOT, target)
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


if __name__ == "__main__":
    sys.exit(main())
