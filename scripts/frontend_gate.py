#!/usr/bin/env python3
"""Gate for `orbit frontend`: the four canonical TIR expectations.

`orbit frontend` had no CI coverage at all. The only thing that mentioned it
was one usage-string case in `cli_probe.py`, so the front end could emit
arbitrary garbage into `tests/frontend/expected/*.tir` and every gate stayed
green. The goldens are the contract from `docs/architecture/TYPED_IR.md`:
`orbit frontend` over a fixture, diffed against the checked-in `.tir`.

There are two fixture shapes under `tests/frontend/`, and the gate runs each
the way it is actually meant to be exercised:

  emit   The fixture embeds a source string and calls
         `compileFrontendSource("name", source)`. The inner source is
         extracted, written to a temp file, and put through the `orbit
         frontend` CLI. One normalisation: the CLI names the module after the
         input path, while the harness names it with its own literal, so the
         single `module` line is replaced by the golden's before diffing. The
         golden's module name is separately asserted to equal the harness's
         literal, so the normalisation cannot hide a rename in either file.

  run    The fixture builds TIR through the `tir.orb` API instead of parsing,
         so there is nothing to hand the CLI. It is built and executed and its
         stdout is diffed against the golden. This is the in-process path the C
         backend actually consumes, so it is worth pinning next to the CLI
         path: the two agreeing is the useful result, the two disagreeing is
         the finding.

  empty  The fixture asserts that a diagnostic or an unresolved type SUPPRESSES
         TIR. There is nothing to diff, so the gate asserts the suppression and
         the message the fixture prints.

One table in this file is a ratchet: KNOWN_UNBUILDABLE, the two fixtures that
cannot be built at all because of F-0004. The gate requires them to keep
failing, so the fix for F-0004 shows up here as a red run rather than as a
golden nobody has ever diffed against real output.

Usage:
    python scripts/frontend_gate.py [--compiler PATH] [--cc CC] [--list]
                                    [--emit-only] [--quiet]

Exit code 0 iff every fixture matched. This gate never rewrites a golden: the
front end is the core zone, and a wrong expectation is filed, not blessed.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRONTEND = os.path.join(ROOT, "tests", "frontend")
EXPECTED = os.path.join(FRONTEND, "expected")

# `val source = "<literal>"` in a fixture that pipes a string through
# compileFrontendSource. Only the escapes Orbit's own string syntax has.
SOURCE_LITERAL = re.compile(r'val\s+source\s*=\s*"((?:[^"\\]|\\.)*)"')
MODULE_LITERAL = re.compile(r'compileFrontendSource\(\s*"((?:[^"\\]|\\.)*)"\s*,')

# Fixtures with no golden, because the contract they pin is the ABSENCE of
# output. Named here rather than in a header comment so the gate owns the whole
# expectation in one place; tests/frontend/ is not this gate's to edit.
EMPTY_EXPECTATIONS = {
    "syntax_error.orb": "syntax diagnostic suppressed TIR",
    "unresolved_type.orb": "unresolved type suppressed TIR",
}


def unescape(literal):
    """Decode an Orbit string literal body, without the surrounding quotes."""
    out_chars = []
    i = 0
    while i < len(literal):
        c = literal[i]
        if c == "\\" and i + 1 < len(literal):
            nxt = literal[i + 1]
            out_chars.append({"n": "\n", "t": "\t", "r": "\r",
                              "\\": "\\", '"': '"'}.get(nxt, "\\" + nxt))
            i += 2
            continue
        out_chars.append(c)
        i += 1
    return "".join(out_chars)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def module_line(text):
    for line in text.splitlines():
        if line.startswith("module "):
            return line
    return None


def diff_lines(expected, actual):
    """A short unified-ish diff; empty string when equal."""
    exp = expected.replace("\r\n", "\n").splitlines()
    act = actual.replace("\r\n", "\n").splitlines()
    if exp == act:
        return ""
    import difflib
    return "\n".join(list(difflib.unified_diff(
        exp, act, "expected", "actual", lineterm="", n=1))[:40])


def classify(path, source):
    name = os.path.basename(path)
    if name in EMPTY_EXPECTATIONS:
        return "empty", None
    golden_path = os.path.join(EXPECTED, os.path.splitext(name)[0] + ".tir")
    if not os.path.isfile(golden_path):
        return "unknown", None
    if SOURCE_LITERAL.search(source) and MODULE_LITERAL.search(source):
        return "emit", golden_path
    return "run", golden_path


def run_emit(compiler, work, name, source, golden_path):
    """Put the embedded source through `orbit frontend` and diff the TIR."""
    body = SOURCE_LITERAL.search(source).group(1)
    module = unescape(MODULE_LITERAL.search(source).group(1))
    golden = read(golden_path)

    want_module = module_line(golden)
    if want_module != "module " + module:
        return False, ("golden names module %r but the fixture compiles %r -- "
                       "rename one or the other; do not let the gate normalise "
                       "a disagreement away" % (want_module, "module " + module))

    inner = os.path.join(work, os.path.splitext(name)[0] + ".orb")
    with open(inner, "w", encoding="utf-8", newline="\n") as f:
        f.write(unescape(body) + "\n")
    produced = os.path.join(work, os.path.splitext(name)[0] + ".tir")
    p = subprocess.run([compiler, "frontend", inner, "-o", produced],
                       capture_output=True, text=True, errors="replace")
    if p.returncode != 0 or not os.path.isfile(produced):
        return False, ("orbit frontend exited %d: %s"
                       % (p.returncode, (p.stdout + p.stderr).strip()))
    actual = read(produced)
    # The only normalisation: the module name is the input path on the CLI and
    # the harness literal in the golden. Asserted equal above, so this line
    # cannot launder a difference in any other line of the output.
    actual = actual.replace(module_line(actual), want_module, 1)
    d = diff_lines(golden, actual)
    if d:
        return False, "TIR differs from the golden:\n" + d
    return True, "TIR matches %s" % os.path.relpath(golden_path, ROOT).replace("\\", "/")


def run_run(compiler, cc, work, name, golden_path):
    """Build the harness and diff its stdout against the golden."""
    exe = os.path.join(work, os.path.splitext(name)[0] + (".exe" if os.name == "nt" else ""))
    env = dict(os.environ)
    env["ORBIT_CC"] = cc
    env["CC"] = cc
    env["TEMP"] = work
    env["TMP"] = work
    rel = os.path.relpath(os.path.join(FRONTEND, name), ROOT).replace("\\", "/")
    p = subprocess.run([compiler, "build", rel, "-o", exe], cwd=ROOT, env=env,
                       capture_output=True, text=True, errors="replace")
    if p.returncode != 0:
        tail = "\n".join(((p.stdout or "") + (p.stderr or "")).strip().splitlines()[-6:])
        return False, "did not build:\n    " + tail
    r = subprocess.run([exe], cwd=work, capture_output=True, text=True,
                       errors="replace", timeout=60)
    # `print` appends a newline to a TIR text that already ends in one, so the
    # trailing blank line is an artefact of the fixture, not of the emitter.
    d = diff_lines(read(golden_path).rstrip("\n"), (r.stdout or "").rstrip("\n"))
    if d:
        return False, "harness stdout differs from the golden:\n" + d
    return True, "in-process TIR matches the golden"


def run_empty(compiler, cc, work, name, needle):
    """The contract is that TIR is suppressed and the fixture says so."""
    exe = os.path.join(work, os.path.splitext(name)[0] + (".exe" if os.name == "nt" else ""))
    env = dict(os.environ)
    env["ORBIT_CC"] = cc
    env["CC"] = cc
    env["TEMP"] = work
    env["TMP"] = work
    rel = os.path.relpath(os.path.join(FRONTEND, name), ROOT).replace("\\", "/")
    p = subprocess.run([compiler, "build", rel, "-o", exe], cwd=ROOT, env=env,
                       capture_output=True, text=True, errors="replace")
    if p.returncode != 0:
        tail = "\n".join(((p.stdout or "") + (p.stderr or "")).strip().splitlines()[-6:])
        return False, ("the fixture does not build, so its contract cannot be "
                       "checked at all:\n    " + tail)
    r = subprocess.run([exe], cwd=work, capture_output=True, text=True,
                       errors="replace", timeout=60)
    so = r.stdout or ""
    if needle not in so:
        return False, ("expected %r on stdout, got %r -- TIR is no longer "
                       "suppressed for this input" % (needle, so.strip()))
    return True, "TIR suppressed as required"


# Fixtures that cannot be built at all today, so their .tir contract cannot be
# checked in either direction. Asserting "still broken" is the point: the gate
# fails the day one of them starts building, at which point someone has to move
# it out of this table and check the golden against real output.
#
# Why they cannot build: importing the front end pulls parser.orb and
# lexer.orb, which call orbit_os_write_stderr_selfhost (declared in extern.orb)
# and parseIntSelfhost (defined in builder.orb) without importing either. The
# front end therefore emits C naming a function that was never declared, and
# the C compiler rejects it. `orbit check` is clean throughout, which is the
# whole failure mode this project keeps meeting. See F-0004 on the board.
KNOWN_UNBUILDABLE = {
    "syntax_error.orb": "parser.orb/lexer.orb use extern.orb + builder.orb without importing them (F-0004)",
    "unresolved_type.orb": "parser.orb/lexer.orb use extern.orb + builder.orb without importing them (F-0004)",
}


def assert_still_broken(compiler, cc, work, name, why):
    """A fixture on the known-unbuildable list must still fail to build.

    When it starts building, that is good news and a gate failure: the
    contract it claims to assert has never actually been checked.
    """
    env = dict(os.environ)
    env["ORBIT_CC"] = cc
    env["CC"] = cc
    env["TEMP"] = work
    env["TMP"] = work
    rel = os.path.relpath(os.path.join(FRONTEND, name), ROOT).replace("\\", "/")
    exe = os.path.join(work, "probe_unbuildable")
    p = subprocess.run([compiler, "build", rel, "-o", exe], cwd=ROOT, env=env,
                       capture_output=True, text=True, errors="replace")
    if p.returncode != 0:
        return True, "known-unbuildable, as expected (%s)" % why
    return False, ("this fixture builds now, so remove it from "
                   "KNOWN_UNBUILDABLE and check %s against real output" % name)


def main():
    ap = argparse.ArgumentParser(
        description="Diff `orbit frontend` output against tests/frontend/expected/")
    ap.add_argument("--compiler", default=os.path.join(ROOT, "orbit.exe"))
    ap.add_argument("--cc", default="gcc",
                    help="C compiler for the fixtures that must be built and run")
    ap.add_argument("--list", action="store_true",
                    help="print the fixture -> expectation table and exit")
    ap.add_argument("--emit-only", action="store_true",
                    help="skip the fixtures that need building (no C toolchain)")
    out.add_quiet(ap)
    args = ap.parse_args()
    out.set_quiet(args.quiet)

    if not os.path.isdir(FRONTEND):
        out.fail("Failed frontend: no such directory " + FRONTEND)
        return 1
    names = sorted(f for f in os.listdir(FRONTEND) if f.endswith(".orb"))
    if not names:
        out.fail("Failed frontend: no fixtures in " + FRONTEND)
        return 1

    if args.list:
        for name in names:
            kind, _ = classify(os.path.join(FRONTEND, name), read(os.path.join(FRONTEND, name)))
            print("%-28s %s" % (name, kind))
        return 0

    work = tempfile.mkdtemp(prefix="orbit_frontend_")
    ok = 0
    total = 0
    fails = []
    for name in names:
        path = os.path.join(FRONTEND, name)
        kind, golden_path = classify(path, read(path))
        if kind == "unknown":
            fails.append(name)
            out.fail("Failed %s: no expectation -- add a .tir golden or list the "
                     "fixture in EMPTY_EXPECTATIONS" % name)
            total += 1
            continue
        if kind in ("run", "empty") and args.emit_only:
            out.say("Skipping %s ... needs building (--emit-only)" % name)
            continue
        total += 1
        if name in KNOWN_UNBUILDABLE:
            # Ratchet, not waiver: the gate now requires this fixture to stay
            # broken, and tells whoever fixes it what to do next.
            good, detail = assert_still_broken(args.compiler, args.cc, work, name,
                                               KNOWN_UNBUILDABLE[name])
            if good:
                ok += 1
            else:
                fails.append(name)
                out.ci_error("[frontend %s] %s" % (name, out.scrub_ci(detail)))
            out.say("Checking tests/frontend/%s ... %s" % (name, detail))
            continue
        if kind == "emit":
            good, detail = run_emit(args.compiler, work, name, read(path), golden_path)
        elif kind == "run":
            good, detail = run_run(args.compiler, args.cc, work, name, golden_path)
        else:
            good, detail = run_empty(args.compiler, args.cc, work, name,
                                     EMPTY_EXPECTATIONS[name])
        if good:
            ok += 1
            out.say("Checking tests/frontend/%s ... %s" % (name, detail))
        else:
            fails.append(name)
            out.fail("Failed tests/frontend/%s: %s" % (name, detail))
            out.ci_error("[frontend %s] %s" % (name, out.scrub_ci(detail)))

    if KNOWN_UNBUILDABLE:
        out.say("Known-unbuildable fixtures, asserted still broken: %s"
                % ", ".join(sorted(KNOWN_UNBUILDABLE)))
        out.say("A ratchet is not a waiver: a known-unbuildable fixture is asserted to "
                "STAY broken, so the F-0004 fix fails this gate instead of passing "
                "quietly. When one starts building, that is the good news -- move it out "
                "of KNOWN_UNBUILDABLE and check its .tir against real output, because "
                "until then its golden has never been checked in either direction.")
    out.finish("frontend", ok, total)
    if fails:
        out.tip("the front end is the core zone: file the difference, do not "
                "re-record the golden")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
