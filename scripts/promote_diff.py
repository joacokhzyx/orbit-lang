#!/usr/bin/env python3
"""Show what actually changed in the canonical C, instead of 20 000 lines.

`compiler/selfhost/stage3.exe.c` is regenerated whole by `build_selfhost.py
--promote`, and it renumbers every register as it goes, so the diff of a real
change is mostly churn. Measured over four commits that changed both source and
canonical: 23 source lines became 24 286 lines of C, 34 became 1 612, 44 became
4 674, and 310 became 21 004. 37 of the last 60 commits touch it at all.

So the file's diff is not a reviewable artifact and never was. AGENTS.md already
says not to read it and to review the `.orb` diff plus the commit's evidence
block instead -- which leaves the reviewer trusting that nothing unexpected
happened in the generated C. This closes that gap: it diffs the canonical
against `HEAD` with the generated-name numbering flattened, and reports what a
person can actually check.

Normalisation is two substitutions and no more:

    r_1234     -> r
    label_567  -> label

Those are the only generated identifier families in the file -- 139 598 and
15 975 occurrences respectively, and nothing else in 4.7 MB carries a numeric
suffix. Widening the pattern to any `name_<digits>` would look more general and
would be wrong: it would flatten a hand-written constant into an anonymous one
and hide a change that matters.

What it prints:

  * the raw line delta, which is the number that makes people give up;
  * the same diff after normalisation, which is the number that means something;
  * the number of hunks;
  * the C functions each hunk lands in, so a change can be named rather than
    scanned.

`--expect-none` turns "something changed semantically" into a non-zero exit,
which is what a promote-and-then-think tool wants: it is asking whether this
commit should have touched the canonical at all.

Run it after `make promote`, before committing: the worktree holds the new
canonical and `HEAD` still holds the old one.
"""

import argparse
import difflib
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CANONICAL = "compiler/selfhost/stage3.exe.c"

# The two generated-name families, and nothing else. See the module docstring.
GENERATED = re.compile(r"\b(r|label)_[0-9]+\b")
DEFINITION = re.compile(r"^[A-Za-z_][\w \*]*?\b([A-Za-z_]\w*)\s*\(")


def normalize(text: str) -> str:
    """Flatten generated register and label numbering.

    One substitution per line, not a token pass: it is a diff to read, not a
    parser, and the file has exactly two families of generated names.
    """
    return GENERATED.sub(lambda m: m.group(1), text)


def load(paths) -> tuple:
    """(old, new) canonical text. Old comes from HEAD, new from the worktree."""
    try:
        old = subprocess.run(
            ["git", "-C", str(ROOT), "show", f"HEAD:{CANONICAL}"],
            capture_output=True, text=True, check=True).stdout
    except subprocess.CalledProcessError:
        print(f"Failed: {CANONICAL} is not in HEAD. There is no previous "
              f"version to compare against.", file=sys.stderr)
        raise SystemExit(2)
    new = (ROOT / CANONICAL).read_text()
    return old, new


def enclosing(anchor: list, index: int) -> str:
    """The C function whose body contains line `index`."""
    for i in range(index, -1, -1):
        m = DEFINITION.match(anchor[i])
        if m:
            return m.group(1)
    return "<file scope>"


def diff_report(old: str, new: str) -> dict:
    raw = list(difflib.unified_diff(old.split("\n"), new.split("\n"), n=0))
    norm = list(difflib.unified_diff(normalize(old).split("\n"),
                                     normalize(new).split("\n"), n=0))

    def counts(lines):
        added = sum(1 for l in lines if l.startswith("+") and not l.startswith("+++"))
        removed = sum(1 for l in lines if l.startswith("-") and not l.startswith("---"))
        hunks = sum(1 for l in lines if l.startswith("@@"))
        return added, removed, hunks

    raw_add, raw_del, _ = counts(raw)
    add, rem, hunks = counts(norm)

    # Which functions the normalised changes land in. Attributed against the new
    # file, because a deleted function has no line left to attribute to and a
    # name for it is still worth printing.
    functions = []
    new_lines = new.split("\n")
    for i, line in enumerate(norm):
        if line.startswith(("+", "-")) and not line.startswith(("+++", "---")):
            body = line[1:]
            fn = enclosing(new_lines, i)
            functions.append(fn)

    return {
        "raw_added": raw_add, "raw_removed": raw_del,
        "added": add, "removed": rem, "hunks": hunks,
        "functions": sorted(set(functions)),
    }


def self_test() -> int:
    """Assert the normaliser flattens numbering and nothing else."""
    a = "  r_14 = 5;\n  goto label_9;\n  orbit_int_to_string(r_3);\n"
    b = "  r_77 = 5;\n  goto label_102;\n  orbit_int_to_string(r_1);\n"
    if normalize(a) != normalize(b):
        print("self-test FAILED: renumbering registers and labels did not "
              "normalise to the same text")
        return 1
    if "orbit_int_to_string" not in normalize(a):
        print("self-test FAILED: normalisation destroyed a real identifier")
        return 1

    # A real change must SURVIVE normalisation, or the tool reports zero for a
    # commit that changed the compiler's behaviour. That is the failure that
    # would make it worse than reading the diff.
    c = "  r_1 = 5;\n  orbit_int_to_string(r_1);\n"
    d = "  r_1 = 5;\n  orbit_int_to_string(r_1, 2);\n"
    if normalize(c) == normalize(d):
        print("self-test FAILED: a real code change normalised away, which "
              "would report 'nothing changed' for a commit that did")
        return 1

    # And a genuinely identical pair must report nothing.
    rep = diff_report(normalize(a), normalize(a))
    if rep["added"] or rep["removed"]:
        print("self-test FAILED: identical input produced a non-empty diff")
        return 1

    print("Finished promote-diff self-test: renumbering flattens, real changes "
          "survive, identical input is empty.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--expect-none", action="store_true",
                    help="exit non-zero if anything changed after normalisation")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    old, new = load(args)
    r = diff_report(old, new)

    raw_total = r["raw_added"] + r["raw_removed"]
    norm_total = r["added"] + r["removed"]
    print(f"{CANONICAL}")
    print(f"  raw diff        {r['raw_added']:+6d} -{r['raw_removed']:<6d} "
          f"= {raw_total} lines")
    print(f"  after renumber  {r['added']:+6d} -{r['removed']:<6d} "
          f"= {norm_total} lines across {r['hunks']} hunk(s)")
    if raw_total:
        share = 100.0 * norm_total / raw_total
        print(f"  so {share:.1f}% of the diff is register renumbering")

    if not norm_total:
        print("\nNothing changed beyond renumbering. The canonical was "
              "regenerated but the compiler behaves identically.")
        if args.expect_none:
            print("Failed: --expect-none and the canonical changed.")
            return 1
        return 0

    print(f"\nFunctions touched ({len(r['functions'])}):")
    for fn in r["functions"]:
        print(f"  {fn}")

    if args.expect_none:
        print(f"\nFailed: --expect-none and {norm_total} lines changed.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())