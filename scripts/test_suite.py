#!/usr/bin/env python3
"""Orbit test suite runner (R2.1 minimum viable).

Convention: tests/suite/<name>.orb defines `fn main() -> int`; the
process exit code is the assertion. Optional first line:
    // expect-exit <N>     (default 0)

Every test is compiled by the fixed-point compiler and executed; the
runner fails on compile errors, wrong exit codes, or timeouts.
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
SUITE = os.path.join(ROOT, "tests", "suite")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--compiler", required=True)
    ap.add_argument("--cc", default=None)
    ap.add_argument("--timeout", type=int, default=60)
    ap.add_argument("--dir", action="append", default=None,
                    help="suite directory to run (repeatable; default: tests/suite)")
    out.add_quiet(ap)
    args = ap.parse_args()
    out.set_quiet(args.quiet)

    suite_dirs = args.dir or [SUITE]
    tests = []
    for suite_dir in suite_dirs:
        if not os.path.isdir(suite_dir):
            out.fail(f"Failed suite: no such directory {suite_dir}")
            return 1
        for f in sorted(os.listdir(suite_dir)):
            if f.endswith(".orb") and not f.endswith(".support.orb"):
                tests.append(os.path.join(suite_dir, f))
    if not tests:
        out.fail("Failed suite: no tests found")
        return 1

    work = tempfile.mkdtemp(prefix="orbit_suite_")
    if os.name == "nt":
        # DB tests link sqlite3.dll at runtime; the vendor dir must be
        # visible to every built exe (same trick CI uses for auth_harness).
        vendordll = os.path.join(ROOT, "runtime", "vendor", "win-x64")
        os.environ["PATH"] = vendordll + os.pathsep + os.environ.get("PATH", "")
    env = dict(os.environ)
    noop_cc = "cmd /c exit 0" if os.name == "nt" else "true"
    if args.cc:
        env.update({"ORBIT_CC": args.cc, "CC": args.cc})
    else:
        env.update({"ORBIT_CC": noop_cc, "CC": noop_cc})

    ok = 0
    failed = []
    exe_suffix = ".exe" if os.name == "nt" else ""
    for path in tests:
        name = os.path.splitext(os.path.basename(path))[0]
        if len(suite_dirs) > 1:
            name = os.path.basename(os.path.dirname(path)) + "/" + name
        src = open(path, encoding="utf-8").read()
        m = re.search(r"^\s*//\s*expect-exit\s+(\d+)", src, re.M)
        expected = int(m.group(1)) if m else 0

        out_exe = os.path.join(work, name.replace("/", "_") + exe_suffix)
        try:
            proc = subprocess.run(
                [args.compiler, "build", path, "-o", out_exe],
                cwd=ROOT, env=env, capture_output=True, text=True,
                errors="replace", timeout=args.timeout,
            )
            build_rc = proc.returncode
        except subprocess.TimeoutExpired:
            failed.append(name)
            out.fail(f"Failed {name}: timed out building")
            continue
        if build_rc != 0:
            failed.append(name)
            out.fail(f"Failed {name}: did not build (rc={build_rc})")
            tail = "\n".join((proc.stdout or "").strip().splitlines()[-8:])
            for line in tail.splitlines():
                print("  " + line, file=sys.stderr)
            payload = (tail or "(no output)").replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")[:1200]
            out.ci_error(f"[suite build {name}] rc={build_rc} :: {payload}")
            continue

        run = subprocess.run([out_exe], cwd=work, capture_output=True,
                             timeout=args.timeout)
        if run.returncode == expected:
            ok += 1
            out.say(f"Testing {name} ... exit {run.returncode} as expected")
        else:
            failed.append(name)
            out.fail(f"Failed {name}: got exit {run.returncode}, want {expected}")

    total = len(tests)
    out.finish("suite", ok, total)
    if failed:
        payload = ", ".join(failed).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")[:1500]
        out.fail("Failed: " + ", ".join(failed))
        out.ci_error(f"[orbit-suite] failed: {payload}")
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
