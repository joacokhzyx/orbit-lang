#!/usr/bin/env python3
"""CLI contract probe: exit codes and streams per COMMANDS.md.

Usage:
    python scripts/cli_probe.py --compiler <orbit-binary> [--work DIR]

Exits 0 iff every case matches its expectation. Cases run in an empty
work directory so ambient state (.orbit/, repo files) cannot leak in.
Expected table derives from docs/COMMANDS.md plus the CLI-1 decisions:
unknown top-level command -> usage on stderr, exit 2; operational
errors go to stderr with an `orbit <cmd>:` prefix; --help exits 0.
"""

import argparse
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SETUP = {
    "files/case.orb": "fn main() -> int {\nreturn 0\n}\n",
    "files/clean.orb": "fn main() -> int {\n    return 0\n}\n",
    "files/ws.orb": "fn main() -> int {\n    return 0   \n}\n",
    "cleandir/clean.orb": "fn main() -> int {\n    return 0\n}\n",
    "tiny.orb": "fn main() -> int {\n    return 0\n}\n",
    # Unparseable on purpose: `orbit fmt` must refuse it and leave it alone.
    "fmt/broken.orb": "fn main() -> int {\n    val =\n}\n",
    # Parseable but badly formatted: `orbit fmt` must rewrite it.
    "fmt/messy.orb": "fn main( )->int{return 0}\n",
    # Whitespace only: no tokens, so normalising to empty is correct.
    "fmt/blank.orb": "   \n\n  \n",
    # A function named after a C library symbol. `orbit check` reports this on
    # stdout and `orbit build` on stderr, which is the current behaviour; the
    # inconsistency is recorded as a debt row rather than changed here.
    "reserved/read.orb": "fn read(text: string) -> int {\n    return text.len()\n}\n\nfn main() -> int {\n    return read(\"hi\")\n}\n",
    # The same program with a safe name, which must still build.
    "reserved/safe.orb": "fn orbit_read(text: string) -> int {\n    return text.len()\n}\n\nfn main() -> int {\n    return orbit_read(\"hi\")\n}\n",
}

CASES = [
    # (name, argv, exp_rc, stream, needle, absent)
    # stream: "out" (stdout), "err" (stderr), "any"; needle "" skips match.
    # absent: text that must NOT appear on either stream ("" skips).
    ("help", ["--help"], 0, "out", "Usage:", ""),
    ("help-short", ["-h"], 0, "out", "Usage:", ""),
    ("version", ["--version"], 0, "out", "orbit 0.1.0-rc.2", ""),
    ("unknown-cmd", ["frobnicate"], 2, "err", "Usage:", ""),
    ("unknown-flag", ["--badflag"], 2, "err", "Usage:", ""),
    ("build-noarg", ["build"], 2, "err", "Usage:", ""),
    ("build-missing", ["build", "nope.orb"], 1, "err", "orbit build:", ""),
    ("build-missing-plain", ["nope.orb"], 1, "err", "orbit build:", ""),
    ("build-quiet", ["build", "--quiet", "tiny.orb", "-o", "tq.exe"], 0, "out", "", "wrote "),
    ("build-verbose", ["build", "--verbose", "tiny.orb", "-o", "tv.exe"], 0, "out", "wrote ", ""),
    ("check-noarg", ["check"], 2, "err", "Usage:", ""),
    ("check-missing", ["check", "nope.orb"], 1, "err", "orbit check:", ""),
    ("check-quiet", ["check", "--quiet", "tiny.orb"], 0, "out", "", "Checked"),
    ("check-verbose", ["check", "--verbose", "tiny.orb"], 0, "out", "check tiny.orb", ""),
    ("run-noarg", ["run"], 2, "err", "Usage:", ""),
    ("run-missing", ["run", "nope.orb"], 1, "err", "orbit run:", ""),
    ("fmt-noarg", ["fmt"], 2, "err", "Usage:", ""),
    ("fmt-help", ["fmt", "--help"], 0, "out", "Usage:", ""),
    ("fmt-missing", ["fmt", "nope.orb"], 1, "err", "orbit fmt:", ""),
    ("fmt-quiet", ["fmt", "--quiet", "files/case.orb"], 0, "out", "", "Formatted"),
    ("fmt-check-verbose", ["fmt", "--check", "files", "--verbose"], 1, "out", "scanned", ""),
    ("fmt-check-quiet", ["fmt", "--check", "files", "--quiet"], 1, "out", "", "files/ws.orb"),
    ("doctor-help", ["doctor", "--help"], 0, "out", "Usage:", ""),
    ("doctor-badflag", ["doctor", "--bogus"], 2, "err", "Usage:", ""),
    ("doctor-quiet-clean", ["doctor", "--quiet", "cleandir"], 0, "out", "", "no findings"),
    ("doctor-verbose", ["doctor", "--verbose", "cleandir"], 0, "out", "scanned", ""),
    ("doctor-json", ["doctor", "--format", "json", "files"], 1, "out", '"code"', ""),
    ("doctor-format-bad", ["doctor", "--format", "xml", "files"], 2, "err", "Usage:", ""),
    ("doctor-color-always", ["doctor", "--color", "always", "files"], 1, "out", "\x1b[", ""),
    ("doctor-color-never", ["doctor", "--color", "never", "files"], 1, "out", "warning [D006]", "\x1b["),
    ("doctor-color-bad", ["doctor", "--color", "maybe", "files"], 2, "err", "Usage:", ""),
    ("cluster-noarg", ["cluster"], 2, "err", "Usage:", ""),
    ("cluster-help", ["cluster", "--help"], 0, "out", "Usage:", ""),
    ("cluster-bogus", ["cluster", "bogus"], 2, "err", "unknown command", ""),
    ("cluster-status-nostate", ["cluster", "status"], 1, "out", "no state file", ""),
    ("frontend-noarg", ["frontend"], 2, "err", "Usage:", ""),
    # A function name that collides with a C library symbol must be refused by
    # the front end, with a diagnostic that names the collision and suggests a
    # rename. Previously this reached the C toolchain as "conflicting types for
    # 'read'" or a link error, with nothing in the Orbit output explaining it.
    ("reserved-name-check", ["check", "reserved/read.orb"], 1, "out",
     "C library function name", ""),
    ("reserved-name-build", ["build", "reserved/read.orb", "-o", "r.exe"], 1, "err",
     "C library function name", ""),
    ("reserved-name-suggests-rename", ["check", "reserved/read.orb"], 1, "out",
     "orbit_read", ""),
    ("reserved-name-safe-still-builds", ["build", "--quiet", "reserved/safe.orb", "-o", "s.exe"], 0, "out", "", "Semantic error"),
]

# Invariants that are about the tool's effect on disk rather than its exit
# code. These run after the CASES table because each one needs a post-condition
# on a file, not just a stream check.
#
# fmt-no-clobber-* guard the worst failure mode in the CLI: `orbit fmt` opening
# its input for writing truncates it before anything can fail, so any internal
# error after that point used to leave a 0-byte source file behind a success
# message. The contract is that a file is either rewritten completely or left
# byte-identical.
#
# outcome is one of:
#   "unchanged"  the file must be byte-identical afterwards
#   "rewritten"  the file must change, and must not end up empty
#   "emptied"    the file must become empty, which is only correct for a source
#                that holds no tokens at all
INVARIANTS = [
    ("fmt-no-clobber-parse-error",
     ["fmt", "fmt/broken.orb"], "fmt/broken.orb", 1, "left unchanged", "unchanged"),
    ("fmt-no-clobber-parse-error-quiet",
     ["fmt", "--quiet", "fmt/broken.orb"], "fmt/broken.orb", 1, "", "unchanged"),
    ("fmt-no-clobber-formats-ok",
     ["fmt", "fmt/messy.orb"], "fmt/messy.orb", 0, "Formatted", "rewritten"),
    # A whitespace-only file normalising to an empty file is intended, not data
    # loss: it has no tokens. Pinned so the distinction in fmtSourceIsBlank
    # cannot be quietly inverted.
    ("fmt-blank-normalises-to-empty",
     ["fmt", "fmt/blank.orb"], "fmt/blank.orb", 0, "Formatted", "emptied"),
]


def invariants(compiler, work):
    """Post-conditions on files the tool touched. Returns (ok, total)."""
    env = dict(os.environ)
    env["ORBIT_CCFLAGS_EXTRA"] = '-I"%s"' % os.path.join(ROOT, "runtime")
    ok = 0
    for name, argv, rel, exp_rc, needle, outcome in INVARIANTS:
        target = os.path.join(work, rel)
        with open(target, "rb") as f:
            before = f.read()
        p = subprocess.run([compiler] + argv, cwd=work, capture_output=True,
                           text=True, errors="replace", env=env)
        so, se = p.stdout or "", p.stderr or ""
        combined = so + se
        with open(target, "rb") as f:
            after = f.read()
        problems = []
        if p.returncode != exp_rc:
            problems.append("rc=%s (want %s)" % (p.returncode, exp_rc))
        if needle and needle not in combined:
            problems.append("missing %r" % needle)
        if outcome == "unchanged" and after != before:
            if after == b"" and before != b"":
                problems.append("FILE EMPTIED (was %d bytes)" % len(before))
            else:
                problems.append("file changed but should not have")
        elif outcome == "rewritten":
            if after == b"" and before != b"":
                problems.append("FILE EMPTIED (was %d bytes)" % len(before))
            elif after == before:
                problems.append("file unchanged but should have been formatted")
        elif outcome == "emptied" and after != b"":
            problems.append("file should have normalised to empty, got %d bytes" % len(after))
        if problems:
            out.fail("Failed %s: %s" % (name, "; ".join(problems)))
            if so.strip():
                print("  out: %r" % so.strip()[:200], file=sys.stderr)
            if se.strip():
                print("  err: %r" % se.strip()[:200], file=sys.stderr)
        else:
            out.say("Probing %s ... ok" % name)
            ok += 1
    return ok, len(INVARIANTS)


def one(compiler, work, name, argv, exp_rc, stream, needle, absent=""):
    env = dict(os.environ)
    # Build cases need the runtime headers; the probe binary lives in a
    # temp dir, so point the inner cc at the repo runtime explicitly.
    env["ORBIT_CCFLAGS_EXTRA"] = '-I"%s"' % os.path.join(ROOT, "runtime")
    p = subprocess.run([compiler] + argv, cwd=work, capture_output=True,
                       text=True, errors="replace", env=env)
    so, se = p.stdout or "", p.stderr or ""
    if stream == "out":
        ok_stream = (not needle) or (needle in so)
    elif stream == "err":
        ok_stream = (not needle) or (needle in se)
    else:
        ok_stream = (not needle) or (needle in (so + se))
    ok_absent = (not absent) or (absent not in so and absent not in se)
    ok_json = True
    if name == "doctor-json" and p.returncode == 1:
        import json as _json
        try:
            rows = _json.loads(so)
            ok_json = (isinstance(rows, list) and len(rows) >= 1 and
                       all(set(r) == {"file", "line", "code", "severity", "message", "fix"} for r in rows))
        except Exception:
            ok_json = False
    ok = (p.returncode == exp_rc) and ok_stream and ok_absent and ok_json
    if ok:
        out.say(f"Probing {name} ... ok")
    else:
        out.fail(f"Failed {name}: rc={p.returncode} (want {exp_rc})")
        if so.strip():
            print("  out: %r" % so.strip()[:200], file=sys.stderr)
        if se.strip():
            print("  err: %r" % se.strip()[:200], file=sys.stderr)
    return ok


def main():
    ap = argparse.ArgumentParser(description="Probe the orbit CLI contract")
    ap.add_argument("--compiler", required=True)
    ap.add_argument("--work", default=None)
    args = ap.parse_args()
    work = os.path.abspath(args.work) if args.work else tempfile.mkdtemp(prefix="orbit_cli_")
    os.makedirs(work, exist_ok=True)
    for rel, content in SETUP.items():
        dest = os.path.join(work, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
    ok = 0
    for case in CASES:
        name, argv, exp_rc, stream, needle = case[:5]
        absent = case[5] if len(case) > 5 else ""
        if one(args.compiler, work, name, argv, exp_rc, stream, needle, absent):
            ok += 1
    inv_ok, inv_total = invariants(args.compiler, work)
    ok += inv_ok
    total = len(CASES) + inv_total
    out.finish("cli-probe", ok, total)
    return 0 if ok == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
