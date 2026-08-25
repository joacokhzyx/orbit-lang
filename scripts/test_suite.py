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

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUITE = os.path.join(ROOT, "tests", "suite")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--compiler", required=True)
    ap.add_argument("--cc", default=None)
    ap.add_argument("--timeout", type=int, default=60)
    args = ap.parse_args()

    tests = sorted(f for f in os.listdir(SUITE) if f.endswith(".orb"))
    if not tests:
        print("[suite] FAIL: no tests found")
        return 1

    work = tempfile.mkdtemp(prefix="orbit_suite_")
    env = dict(os.environ)
    noop_cc = "cmd /c exit 0" if os.name == "nt" else "true"
    if args.cc:
        env.update({"ORBIT_CC": args.cc, "CC": args.cc})
    else:
        env.update({"ORBIT_CC": noop_cc, "CC": noop_cc})

    ok = 0
    failed = []
    exe_suffix = ".exe" if os.name == "nt" else ""
    for tf in tests:
        name = tf[:-4]
        path = os.path.join(SUITE, tf)
        src = open(path, encoding="utf-8").read()
        m = re.search(r"^\s*//\s*expect-exit\s+(\d+)", src, re.M)
        expected = int(m.group(1)) if m else 0

        out_exe = os.path.join(work, name + exe_suffix)
        try:
            proc = subprocess.run(
                [args.compiler, "build", path, "-o", out_exe],
                cwd=ROOT, env=env, capture_output=True, text=True,
                errors="replace", timeout=args.timeout,
            )
            build_rc = proc.returncode
        except subprocess.TimeoutExpired:
            failed.append(name)
            print(f"[suite] TIMEOUT(build) {name}")
            continue
        if build_rc != 0:
            failed.append(name)
            print(f"[suite] BUILD-FAIL {name}")
            tail = "\n".join((proc.stdout or "").strip().splitlines()[-8:])
            if tail:
                print("   " + tail.replace("\n", "\n   "))
            payload = (tail or "(no output)").replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")[:1200]
            print(f"::error::[suite build {name}] rc={build_rc} :: {payload}")
            continue

        run = subprocess.run([out_exe], cwd=work, capture_output=True,
                             timeout=args.timeout)
        if run.returncode == expected:
            ok += 1
            print(f"[suite] OK       {name:<24} exit={run.returncode}")
        else:
            failed.append(name)
            print(f"[suite] WRONG-EXIT {name:<22} got={run.returncode} want={expected}")

    total = len(tests)
    print(f"\n[suite] RESULT: {ok}/{total}")
    if failed:
        payload = ", ".join(failed).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")[:1500]
        print(f"::error::[orbit-suite] failed: {payload}")
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
