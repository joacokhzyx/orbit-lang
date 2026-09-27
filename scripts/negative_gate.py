#!/usr/bin/env python3
"""Negative-compilation gate: every program here must FAIL to compile.

The rest of the battery is positive -- it asserts that programs the language
accepts still work. That is why three audit rounds in a row found defects no
gate saw: a `union` match missing a variant, `.at()` on a list of ints, and
`print(undeclaredThing)` all *compile clean* and then do the wrong thing at
runtime. There was not one test in the repo asserting a type error, so a
front end that rejects nothing at all scored a perfect run.

This gate is that missing assertion. For each `tests/negative/*.orb` it runs
`orbit check` and requires a non-zero exit plus the diagnostic named in the
file's header.

Header directives, one per case, exactly one of:

    // expect-error: <substring>
        The program must fail to compile and the diagnostic must contain
        <substring>. Both the exit code and the text are asserted: a
        diagnostic that improves fails the gate until the header is updated,
        because a better message nobody reads is still an unpinned message.

    // known-defect: <ref>
        The program is one the language must reject and today does not. The
        gate asserts the BUG is still present -- `orbit check` must still exit
        zero. This is a ratchet, not an excuse: the moment the compiler starts
        rejecting it the gate fails and says so, which is the moment to
        replace `known-defect:` with `expect-error:` and record the text.

Usage:
    python scripts/negative_gate.py [--compiler PATH] [--list] [--quiet]

Exit code 0 iff every case matched its declaration.
"""

import argparse
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NEGATIVE = os.path.join(ROOT, "tests", "negative")

EXPECT_ERROR = re.compile(r"^\s*//\s*expect-error:\s*(\S.*?)\s*$", re.M)
KNOWN_DEFECT = re.compile(r"^\s*//\s*known-defect:\s*(\S.*?)\s*$", re.M)
CASE_NAME = re.compile(r"^\s*//\s*case:\s*(\S.*?)\s*$", re.M)


class Case:
    """One declared case, as read from the .orb header."""

    def __init__(self, path):
        self.path = path
        self.name = os.path.splitext(os.path.basename(path))[0]
        self.rel = os.path.relpath(path, ROOT).replace("\\", "/")
        with open(path, encoding="utf-8") as f:
            self.source = f.read()
        m = CASE_NAME.search(self.source)
        if m:
            self.name = m.group(1)
        self.expect_error = EXPECT_ERROR.search(self.source)
        self.known_defect = KNOWN_DEFECT.search(self.source)

    @property
    def kind(self):
        if self.expect_error and self.known_defect:
            return "both"
        if self.expect_error:
            return "error"
        if self.known_defect:
            return "defect"
        return "undeclared"

    def __str__(self):
        return self.name


def load_cases():
    if not os.path.isdir(NEGATIVE):
        out.fail("Failed negative: no such directory " + NEGATIVE)
        return None
    paths = sorted(os.path.join(NEGATIVE, f) for f in os.listdir(NEGATIVE)
                   if f.endswith(".orb"))
    if not paths:
        out.fail("Failed negative: no cases in " + NEGATIVE)
        return None
    return [Case(p) for p in paths]


def describe(actual, verbose=False):
    """One-line form of a check result, for a failure message."""
    lines = [ln for ln in (actual or "").splitlines() if ln.strip()]
    if not lines:
        return "(no diagnostic)"
    if verbose:
        return " / ".join(ln.strip() for ln in lines)
    return lines[-1].strip()


def run_case(compiler, case, verbose=False):
    """Return (verdict, detail). verdict is 'pass' or 'fail'."""
    if case.kind == "undeclared":
        return "fail", "header declares neither expect-error: nor known-defect:"
    if case.kind == "both":
        return "fail", "header declares both expect-error: and known-defect:"
    p = subprocess.run([compiler, "check", case.rel], cwd=ROOT,
                       capture_output=True, text=True, errors="replace")
    combined = (p.stdout or "") + (p.stderr or "")
    rejected = p.returncode != 0

    if case.kind == "error":
        needle = case.expect_error.group(1)
        if not rejected:
            return "fail", ("expected rejection, got exit 0 and stdout %r -- "
                            "the header promises the diagnostic %r"
                            % (describe(p.stdout), needle))
        if needle not in combined:
            return "fail", ("diagnostic changed.\n    header wants: %s\n"
                            "    got:            %s"
                            % (needle, describe(combined, True)))
        return "pass", describe(combined, verbose)

    # known-defect: assert the bug is still there.
    ref = case.known_defect.group(1)
    if rejected:
        return "fail", ("known defect %s looks FIXED: orbit check now rejects it "
                        "with %r. Replace known-defect: with expect-error: and "
                        "record that diagnostic." % (ref, describe(combined, True)))
    return "pass", "still accepted (known defect %s)" % ref


def main():
    ap = argparse.ArgumentParser(
        description="Require every tests/negative program to fail to compile")
    ap.add_argument("--compiler", default=os.path.join(ROOT, "orbit.exe"))
    ap.add_argument("--list", action="store_true",
                    help="print one line per declared case and exit")
    ap.add_argument("--verbose", action="store_true",
                    help="also print the diagnostic each case produced")
    out.add_quiet(ap)
    args = ap.parse_args()
    out.set_quiet(args.quiet)

    cases = load_cases()
    if cases is None:
        return 1
    if args.list:
        for c in cases:
            print("%-34s %-8s %s" % (c.rel, c.kind, c.name))
        return 0

    ok = 0
    fails = []
    defects = []
    for case in cases:
        verdict, detail = run_case(args.compiler, case, args.verbose)
        if verdict == "pass":
            ok += 1
            if case.kind == "defect":
                defects.append(case.name)
            out.say("Checking %s ... %s" % (case.rel, detail))
        else:
            fails.append(case.name)
            out.fail("Failed %s: %s" % (case.rel, detail))
            out.ci_error("[negative %s] %s" % (case.name,
                                               out.scrub_ci(detail)))

    total = len(cases)
    out.finish("negative", ok, total,
               extra="(%d known defect%s still accepted)"
                     % (len(defects), "" if len(defects) == 1 else "s"))
    if defects:
        out.say("Known defects accepted by the compiler today: " + ", ".join(defects))
    if fails:
        out.tip("run `python scripts/negative_gate.py --compiler <orbit>` to see both texts")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
