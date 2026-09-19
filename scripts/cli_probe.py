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

CASES = [
    # (name, argv, exp_rc, stream, needle)
    # stream: "out" (stdout), "err" (stderr), "any"; needle "" skips match.
    ("help", ["--help"], 0, "out", "Usage:"),
    ("help-short", ["-h"], 0, "out", "Usage:"),
    ("version", ["--version"], 0, "out", "orbit 0.1.0-rc.2"),
    ("unknown-cmd", ["frobnicate"], 2, "err", "Usage:"),
    ("unknown-flag", ["--badflag"], 2, "err", "Usage:"),
    ("build-noarg", ["build"], 2, "err", "Usage:"),
    ("build-missing", ["build", "nope.orb"], 1, "err", "orbit build:"),
    ("build-missing-plain", ["nope.orb"], 1, "err", "orbit build:"),
    ("check-noarg", ["check"], 2, "err", "Usage:"),
    ("check-missing", ["check", "nope.orb"], 1, "err", "orbit check:"),
    ("run-noarg", ["run"], 2, "err", "Usage:"),
    ("run-missing", ["run", "nope.orb"], 1, "err", "orbit run:"),
    ("fmt-noarg", ["fmt"], 2, "err", "Usage:"),
    ("fmt-help", ["fmt", "--help"], 0, "out", "Usage:"),
    ("fmt-missing", ["fmt", "nope.orb"], 1, "err", "orbit fmt:"),
    ("doctor-help", ["doctor", "--help"], 0, "out", "Usage:"),
    ("doctor-badflag", ["doctor", "--bogus"], 2, "err", "Usage:"),
    ("cluster-noarg", ["cluster"], 2, "err", "Usage:"),
    ("cluster-help", ["cluster", "--help"], 0, "out", "Usage:"),
    ("cluster-bogus", ["cluster", "bogus"], 2, "err", "unknown command"),
    ("cluster-status-nostate", ["cluster", "status"], 1, "out", "no state file"),
    ("frontend-noarg", ["frontend"], 2, "err", "Usage:"),
]


def one(compiler, work, name, argv, exp_rc, stream, needle):
    p = subprocess.run([compiler] + argv, cwd=work, capture_output=True,
                       text=True, errors="replace")
    out, err = p.stdout or "", p.stderr or ""
    # Native stderr bypasses capture on some runtimes; PowerShell-style
    # launchers may also merge. Accept the needle on either stream but
    # require it on the expected one when that stream is non-empty.
    if stream == "out":
        ok_stream = needle in out
    elif stream == "err":
        ok_stream = needle in err
    else:
        ok_stream = needle in (out + err)
    ok = (p.returncode == exp_rc) and (not needle or ok_stream)
    got_where = "out" if needle in out else ("err" if needle in err else "-")
    print("%-22s rc=%d(exp %d) needle@%s %s" %
          (name, p.returncode, exp_rc, got_where, "OK" if ok else "FAIL"))
    if not ok:
        print("  out: %r" % out.strip()[:160])
        print("  err: %r" % err.strip()[:160])
    return ok


def main():
    ap = argparse.ArgumentParser(description="Probe the orbit CLI contract")
    ap.add_argument("--compiler", required=True)
    ap.add_argument("--work", default=None)
    args = ap.parse_args()
    work = os.path.abspath(args.work) if args.work else tempfile.mkdtemp(prefix="orbit_cli_")
    os.makedirs(work, exist_ok=True)
    ok = 0
    for name, argv, exp_rc, stream, needle in CASES:
        if one(args.compiler, work, name, argv, exp_rc, stream, needle):
            ok += 1
    print("RESULT: %d/%d" % (ok, len(CASES)))
    return 0 if ok == len(CASES) else 1


if __name__ == "__main__":
    raise SystemExit(main())
