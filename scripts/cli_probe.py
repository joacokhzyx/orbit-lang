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

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SETUP = {
    "files/case.orb": "fn main() -> int {\nreturn 0\n}\n",
    "files/clean.orb": "fn main() -> int {\n    return 0\n}\n",
    "files/ws.orb": "fn main() -> int {\n    return 0   \n}\n",
    "cleandir/clean.orb": "fn main() -> int {\n    return 0\n}\n",
    "tiny.orb": "fn main() -> int {\n    return 0\n}\n",
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
]


def one(compiler, work, name, argv, exp_rc, stream, needle, absent=""):
    env = dict(os.environ)
    # Build cases need the runtime headers; the probe binary lives in a
    # temp dir, so point the inner cc at the repo runtime explicitly.
    env["ORBIT_CCFLAGS_EXTRA"] = '-I"%s"' % os.path.join(ROOT, "runtime")
    p = subprocess.run([compiler] + argv, cwd=work, capture_output=True,
                       text=True, errors="replace", env=env)
    out, err = p.stdout or "", p.stderr or ""
    if stream == "out":
        ok_stream = (not needle) or (needle in out)
    elif stream == "err":
        ok_stream = (not needle) or (needle in err)
    else:
        ok_stream = (not needle) or (needle in (out + err))
    ok_absent = (not absent) or (absent not in out and absent not in err)
    ok_json = True
    if name == "doctor-json" and p.returncode == 1:
        import json as _json
        try:
            rows = _json.loads(out)
            ok_json = (isinstance(rows, list) and len(rows) >= 1 and
                       all(set(r) == {"file", "line", "code", "severity", "message", "fix"} for r in rows))
        except Exception:
            ok_json = False
    ok = (p.returncode == exp_rc) and ok_stream and ok_absent and ok_json
    got_where = "out" if needle in out else ("err" if needle in err else "-")
    print("%-22s rc=%d(exp %d) needle@%s %s" %
          (name, p.returncode, exp_rc, got_where, "OK" if ok else "FAIL"))
    if not ok:
        print("  out: %r" % out.strip()[:200])
        print("  err: %r" % err.strip()[:200])
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
    print("RESULT: %d/%d" % (ok, len(CASES)))
    return 0 if ok == len(CASES) else 1


if __name__ == "__main__":
    raise SystemExit(main())
