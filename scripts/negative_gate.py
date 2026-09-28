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

A known-defect case may also pin the wrong ANSWER, which is the part that
reaches a user: `orbit check` being clean is only half of a silent defect.
All three of these are optional and only meaningful on a known-defect case:

    // wrong-value: <expected stdout, \\n for newline>
        Build and run the program; its stdout must still be exactly this.
        Use it when the compiler accepts the program and then computes the
        wrong number -- a truncated literal, an unsigned division, an out of
        range index. `\n` separates lines.

    // cc-rejects: <substring>
        The front end must stay silent AND the C toolchain must still reject
        the output with <substring>. This is the "check clean, C step fails"
        shape (F-0004, F-0011), and the substring is the point: it names the
        C symbol or C type the emitter invented. Both halves are ratchets, so
        the case fires whether the fix lands in the front end or in codegen.

    // no-diagnostic:
        The program must still BUILD and must still DIE WITHOUT SAYING
        ANYTHING: non-zero exit, and nothing on stdout or stderr. This is for
        the class where the wrong answer is a crash -- `print((7) / 0)` is
        SIGFPE, and a `wrong-value:` cannot pin a signal. Without it such a
        case pins nothing but the front end's silence, which is the weakest
        thing in this directory; with it, the case holds the behaviour and
        fires when the fix arrives, because a diagnostic is a message.
        Mechanism-neutral on purpose: a signal on POSIX, an exception status
        on Windows, the same observable either way.

A case that pins none of those still pins its class: the front end accepts
this program, and the gate fails the day it stops.

Usage:
    python scripts/negative_gate.py [--compiler PATH] [--cc CC] [--list]
                                    [--no-build] [--quiet]

Exit code 0 iff every case matched its declaration.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NEGATIVE = os.path.join(ROOT, "tests", "negative")

EXPECT_ERROR = re.compile(r"^\s*//\s*expect-error:\s*(\S.*?)\s*$", re.M)
KNOWN_DEFECT = re.compile(r"^\s*//\s*known-defect:\s*(\S.*?)\s*$", re.M)
CASE_NAME = re.compile(r"^\s*//\s*case:\s*(\S.*?)\s*$", re.M)
WRONG_VALUE = re.compile(r"^\s*//\s*wrong-value:\s*(\S.*?)\s*$", re.M)
CC_REJECTS = re.compile(r"^\s*//\s*cc-rejects:\s*(\S.*?)\s*$", re.M)
NO_DIAGNOSTIC = re.compile(r"^\s*//\s*no-diagnostic:\s*$", re.M)


def unescape(literal):
    """Decode the escapes a header comment can carry."""
    out_chars = []
    i = 0
    while i < len(literal):
        c = literal[i]
        if c == "\\" and i + 1 < len(literal):
            nxt = literal[i + 1]
            out_chars.append({"n": "\n", "t": "\t", "r": "\r",
                              "\\": "\\", '"': '"'}.get(nxt, c + nxt))
            i += 2
            continue
        out_chars.append(c)
        i += 1
    return "".join(out_chars)


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
        self.wrong_value = WRONG_VALUE.search(self.source)
        self.cc_rejects = CC_REJECTS.search(self.source)
        self.no_diagnostic = NO_DIAGNOSTIC.search(self.source)

    @property
    def kind(self):
        if self.expect_error and self.known_defect:
            return "both"
        if self.expect_error:
            return "error"
        if self.known_defect:
            return "defect"
        return "undeclared"

    @property
    def pins_an_answer(self):
        """True when the case also pins what the program computes, not just
        that the front end lets it through."""
        return bool(self.wrong_value or self.cc_rejects or self.no_diagnostic)

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


def run_case(compiler, case, verbose=False, cc=None, work=None):
    """Return (verdict, detail). verdict is 'pass', 'fail' or 'skip'."""
    if case.kind == "undeclared":
        return "fail", "header declares neither expect-error: nor known-defect:"
    if case.kind == "both":
        return "fail", "header declares both expect-error: and known-defect:"
    if case.pins_an_answer and case.kind != "defect":
        return ("fail", "wrong-value:/cc-rejects:/no-diagnostic: only mean "
                "anything on a known-defect: case -- on an expect-error: case "
                "the compiler rejects the program, so there is no answer left "
                "to pin")
    if sum(bool(p) for p in (case.wrong_value, case.cc_rejects,
                             case.no_diagnostic)) > 1:
        return ("fail", "the header pins more than one answer "
                "(wrong-value:/cc-rejects:/no-diagnostic:); pick the one that "
                "describes what the program actually does")
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
    if cc is None:
        return "pass", ("still accepted (known defect %s; its wrong-value/cc-rejects "
                        "line was not checked -- no C toolchain)" % ref)
    if case.cc_rejects:
        return pin_cc_rejects(compiler, case, cc, work, ref, verbose)
    if case.no_diagnostic:
        return pin_no_diagnostic(compiler, case, cc, work, ref, verbose)
    if case.wrong_value:
        return pin_wrong_value(compiler, case, cc, work, ref, verbose)
    return "pass", "still accepted (known defect %s)" % ref


def build_program(compiler, case, cc, work):
    """Build one case. Returns (ok, output, exe_path)."""
    exe = os.path.join(work, case.name + (".exe" if os.name == "nt" else ""))
    env = dict(os.environ)
    env["ORBIT_CC"] = cc
    env["CC"] = cc
    # Every build writes its intermediate C to $TMP/orbit_selfhost_build.c, so a
    # shared TEMP is a race between two gates in the same job. Own it.
    env["TEMP"] = work
    env["TMP"] = work
    p = subprocess.run([compiler, "build", case.rel, "-o", exe], cwd=ROOT,
                       env=env, capture_output=True, text=True, errors="replace")
    return p.returncode == 0, (p.stdout or "") + (p.stderr or ""), exe


def pin_cc_rejects(compiler, case, cc, work, ref, verbose):
    """The front end stays silent AND the C step still says no, with this text."""
    needle = case.cc_rejects.group(1)
    ok, output, _ = build_program(compiler, case, cc, work)
    if ok:
        return "fail", ("known defect %s: the program BUILDS now, so the C step no "
                        "longer rejects it. If the front end rejects it too, drop "
                        "known-defect:/cc-rejects: and declare expect-error: with the "
                        "diagnostic it prints." % ref)
    if needle not in output:
        return "fail", ("known defect %s: the C step still rejects this program but "
                        "the reason moved.\n    header wants: %s\n    got:            %s"
                        % (ref, needle, describe(output, True)))
    return "pass", ("still accepted by check, still rejected by the C step: %s"
                    % needle)


def pin_no_diagnostic(compiler, case, cc, work, ref, verbose):
    """The program still builds and still dies without saying anything.

    A `wrong-value:` cannot pin a signal, and a case that pins only "check is
    clean" lets the class rot. So this asserts the observable instead: the build
    succeeds, the exit is non-zero, and neither stream carries a message. It
    fails in both directions that matter -- a fix that starts explaining itself
    (a diagnostic IS a message) and a regression that starts printing a number.
    """
    ok, output, exe = build_program(compiler, case, cc, work)
    if not ok:
        tail = "\n    ".join((output or "").strip().splitlines()[-4:] or ["(no output)"])
        return "fail", ("known defect %s: the program does not build, so the "
                        "no-diagnostic pin cannot be checked.\n    %s" % (ref, tail))
    try:
        r = subprocess.run([exe], cwd=work, capture_output=True, text=True,
                           errors="replace", timeout=60)
    except subprocess.TimeoutExpired:
        return ("fail", "known defect %s: the program timed out; it was pinned as "
                "dying, and a hang is a third thing again" % ref)
    said = " ".join(x for x in ((r.stdout or "").strip(),
                                (r.stderr or "").strip()) if x)
    if r.returncode == 0:
        return ("fail", "known defect %s: the program now EXITS 0. It was pinned "
                "as dying without a diagnostic, so this is a fix: drop the "
                "no-diagnostic: line and move the program to tests/suite/ where "
                "a clean exit is the expectation." % ref)
    if said:
        return ("fail", "known defect %s: the program now SAYS something (%r). It "
                "was pinned as dying silently, so a diagnostic has arrived and "
                "that is the fix: drop the no-diagnostic: line, and if the front "
                "end now rejects it too, re-declare the case as expect-error: "
                "with the diagnostic it prints." % (ref, said[:200]))
    how = ("on a signal" if r.returncode < 0
           else "exit %d%s" % (r.returncode, " (an OS status, not a signal)"
                               if os.name == "nt" else ""))
    return "pass", "still accepted by check, still dies with no message (%s)" % how


def pin_wrong_value(compiler, case, cc, work, ref, verbose):
    """The front end stays silent AND the program still computes the wrong answer."""
    want = unescape(case.wrong_value.group(1))
    ok, output, exe = build_program(compiler, case, cc, work)
    if not ok:
        tail = "\n    ".join((output or "").strip().splitlines()[-4:] or ["(no output)"])
        return "fail", ("known defect %s: the program does not build, so the pinned "
                        "wrong value %r cannot be checked.\n    %s"
                        % (ref, want, tail))
    try:
        r = subprocess.run([exe], cwd=work, capture_output=True, text=True,
                           errors="replace", timeout=60)
    except subprocess.TimeoutExpired:
        return "fail", ("known defect %s: the program timed out; it was pinned at %r"
                        % (ref, want))
    got = (r.stdout or "").strip()
    if got != want:
        extra = (" (and it exited %d%s)" % (r.returncode,
                                            ", on a signal" if r.returncode < 0 else "")
                 if r.returncode != 0 else "")
        return "fail", ("known defect %s: the wrong value MOVED%s.\n"
                        "    header wants: %r\n    got:            %r\n"
                        "    If that is the fix, delete the wrong-value: line and let "
                        "the case become a positive test; if it is a regression, this "
                        "is the number to fix." % (ref, extra, want, got))
    return "pass", "still accepted by check, still wrong: %s" % want.replace("\n", " / ")


def main():
    ap = argparse.ArgumentParser(
        description="Require every tests/negative program to fail to compile")
    ap.add_argument("--compiler", default=os.path.join(ROOT, "orbit.exe"))
    ap.add_argument("--cc", default=os.environ.get("ORBIT_CC")
                               or os.environ.get("CC") or "cc",
                    help="C toolchain for the cases that pin a wrong answer")
    ap.add_argument("--no-build", action="store_true",
                    help="skip the wrong-value/cc-rejects assertions (no C toolchain)")
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
            pins = []
            if c.wrong_value:
                pins.append("wrong-value")
            if c.cc_rejects:
                pins.append("cc-rejects")
            if c.no_diagnostic:
                pins.append("no-diagnostic")
            print("%-42s %-8s %-22s %s"
                  % (c.rel, c.kind, "+".join(pins) or "-", c.name))
        return 0

    want_answer = [c for c in cases if c.pins_an_answer]
    cc = None
    if not args.no_build:
        if shutil.which(args.cc) or os.path.isfile(args.cc):
            cc = args.cc
        elif want_answer:
            out.tip("%d case(s) pin a wrong answer and need a C toolchain; none "
                    "found at %r, so those assertions are skipped" % (len(want_answer),
                                                                     args.cc))

    work = tempfile.mkdtemp(prefix="orbit_negative_")
    ok = 0
    fails = []
    defects = []
    unpinned = 0
    for case in cases:
        verdict, detail = run_case(args.compiler, case, args.verbose, cc, work)
        if verdict == "pass":
            ok += 1
            if case.kind == "defect":
                defects.append(case.name)
                if case.pins_an_answer and cc is None:
                    unpinned += 1
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
        if unpinned:
            out.say("  (%d of those had their wrong-value/cc-rejects line skipped)"
                    % unpinned)
        # The three lines a red run should not require reading this file for.
        out.say("A ratchet is not a waiver: a known-defect case asserts the bug is "
                "STILL there, so a fix fails this gate instead of passing quietly.")
        out.say("When one fires, the fix is real -- re-declare that case as "
                "expect-error: with the diagnostic it now prints, and drop its "
                "wrong-value:/cc-rejects: line, or move it to the value it now gives.")
    if fails:
        out.tip("run `python scripts/negative_gate.py --compiler <orbit>` to see both texts")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
