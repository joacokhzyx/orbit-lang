#!/usr/bin/env python3
"""Orbit test suite runner (R2.1 minimum viable).

Convention: tests/suite/<name>.orb defines `fn main() -> int`; the
process exit code is the assertion. Optional first line:
    // expect-exit <N>     (default 0)

Every test is compiled by the fixed-point compiler and executed; the
runner fails on compile errors, wrong exit codes, or timeouts.

One further directive, for a test that pins a defect instead of a feature:

    // known-failing[: <ref>]     the test is expected NOT to exit 0

This is a ratchet, in the same sense as `known-defect:` in
scripts/negative_gate.py, and for the same reason: the alternative is to
leave a red test in the suite, which gets deleted, or to delete the test,
which loses the only record of what is broken. It asserts the failure is
STILL there, so a fix fails this gate instead of passing quietly; the day
the test starts exiting 0 the runner says so and the directive has to go.
It excuses a wrong exit code ONLY: a test that does not build still fails,
because "it is red" must never come to mean "it does not compile".
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
    ratchets = []
    exe_suffix = ".exe" if os.name == "nt" else ""
    for path in tests:
        name = os.path.splitext(os.path.basename(path))[0]
        if len(suite_dirs) > 1:
            name = os.path.basename(os.path.dirname(path)) + "/" + name
        src = open(path, encoding="utf-8").read()
        m = re.search(r"^\s*//\s*expect-exit\s+(\d+)", src, re.M)
        ratchet = re.search(r"^\s*//\s*known-failing\s*:?\s*(\S.*?)\s*$", src, re.M)
        if m and ratchet:
            failed.append(name)
            out.fail(f"Failed {name}: header declares both expect-exit and "
                     f"known-failing -- pick one")
            continue
        if ratchet:
            # A ratcheted case has no target exit code: any non-zero exit is the
            # expected outcome, and 0 is the failure.
            expected = None
        else:
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
            # stderr FIRST, and this was the bug. `orbit build` writes its
            # diagnostics to stderr -- DX-0 moved them there deliberately, so
            # that `orbit check` and `orbit build` agree -- and this runner
            # captured stderr and then printed stdout, which for a failed build
            # is empty. Every build failure in this suite reported
            # "did not build (rc=1) :: (no output)" and the actual diagnostic
            # went nowhere, on every platform. It went unnoticed because the
            # suite has had no build failure since the diagnostic move, which
            # is why it took the first Windows-only one to surface it.
            diag = (proc.stderr or "").strip() or (proc.stdout or "").strip()
            tail = "\n".join(diag.splitlines()[-8:])
            for line in tail.splitlines():
                print("  " + line, file=sys.stderr)
            payload = (tail or "(no output)").replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")[:1200]
            out.ci_error(f"[suite build {name}] rc={build_rc} :: {payload}")
            continue

        run = subprocess.run([out_exe], cwd=work, capture_output=True,
                             timeout=args.timeout)
        if expected is None:
            ref = (" " + ratchet.group(1)) if ratchet.group(1) else ""
            if run.returncode != 0:
                ok += 1
                ratchets.append(name)
                out.say(f"Testing {name} ... exit {run.returncode}, still red as "
                        f"declared (known-failing:{ref})")
            else:
                failed.append(name)
                out.fail(f"Failed {name}: known-failing but it now exits 0 -- the "
                         f"defect it was pinning is fixed, or the test asserts "
                         f"nothing. Delete the known-failing: directive and this "
                         f"becomes ordinary coverage.")
                out.ci_error(f"[suite ratchet {name}] known-failing now exits 0")
            continue
        if run.returncode == expected:
            ok += 1
            out.say(f"Testing {name} ... exit {run.returncode} as expected")
        else:
            failed.append(name)
            out.fail(f"Failed {name}: got exit {run.returncode}, want {expected}")

    total = len(tests)
    extra = ("(%d known-failing, asserted still red)" % len(ratchets)
             if ratchets else "")
    out.finish("suite", ok, total, extra=extra)
    if ratchets:
        out.say("Known-failing, asserted still red: " + ", ".join(ratchets))
        out.say("A ratchet is not a waiver: it asserts the failure is STILL there, so a "
                "fix fails this gate instead of passing quietly.")
        out.say("When one starts exiting 0, the defect is fixed -- delete the "
                "known-failing: directive and let the test be ordinary coverage.")
    if failed:
        payload = ", ".join(failed).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")[:1500]
        out.fail("Failed: " + ", ".join(failed))
        out.ci_error(f"[orbit-suite] failed: {payload}")
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
