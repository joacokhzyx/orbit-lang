#!/usr/bin/env python3
"""Orbit test suite runner (R2.1 minimum viable).

Convention: tests/suite/<name>.orb defines `fn main() -> int`; the
process exit code is the assertion. Optional first line:
    // expect-exit <N>     (default 0)

Every test is compiled by the fixed-point compiler and executed; the
runner fails on compile errors, wrong exit codes, or timeouts.

`--backend native` builds every case with `orbit build --backend=native`, which
runs R6 (ORBIT_R6) instead of the C compiler, and checks the same expectations.
Without ORBIT_R6 the run is SKIPPED, not passed: it prints why and exits 77, and
scripts/dev.py reports the gate as skipped.

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
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out
import _common

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_RC = 77
SUITE = os.path.join(ROOT, "tests", "suite")


def archive_is_stale(lib_path):
    """True when the runtime archive is older than any runtime source.

    The archive is built on demand into the ignored `.orbit/`, so nothing
    notices it predating a runtime change: the emitted TU links against it
    anyway, and every program in the lane fails with an undefined reference to
    a symbol that IS in the sources, reported as the C compiler rejecting
    output it did not reject. A missing archive is not this case; the caller
    builds that one.
    """
    if not os.path.exists(lib_path):
        return False
    lib_mtime = os.path.getmtime(lib_path)
    for dirpath, _, names in os.walk(os.path.join(ROOT, "runtime")):
        for name in names:
            if not name.endswith((".c", ".h")):
                continue
            try:
                if os.path.getmtime(os.path.join(dirpath, name)) > lib_mtime:
                    return True
            except OSError:
                return True
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--compiler", required=True)
    ap.add_argument("--cc", default=None)
    ap.add_argument("--timeout", type=int, default=60)
    ap.add_argument("--backend", choices=("c", "native"), default="c",
                    help="code generator under test (native needs ORBIT_R6)")
    ap.add_argument("--dir", action="append", default=None,
                    help="suite directory to run (repeatable; default: tests/suite)")
    out.add_quiet(ap)
    args = ap.parse_args()
    out.set_quiet(args.quiet)

    native = args.backend == "native"
    tool = "suite_native" if native else "suite"
    r6 = os.environ.get("ORBIT_R6", "")
    if native:
        if not r6:
            out.say(f"Skipped {tool}: ORBIT_R6 is not set. Point it at r6.exe "
                    "(and R6_RUNTIME_DIR at its runtime archives) to run the "
                    "native backend. This is a skip, not a pass.")
            return SKIP_RC
        if not os.path.isfile(r6):
            out.fail(f"Failed {tool}: ORBIT_R6 names {r6}, which is not a file")
            return 1

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
    # Disposable binaries: skip the Windows brand stamp and -Wall, add -pipe
    # on gcc (see _common.disposable_test_env for why and for the escape
    # hatches). The strict warning gate is werror_gate.py (-Werror on the
    # emitted C) and never sees these flags.
    env = _common.disposable_test_env(env, cc=args.cc)
    if native:
        # An R6 build tree keeps its archives in runtime-win64 beside r6.exe;
        # an explicit R6_RUNTIME_DIR or ORBIT_R6_RUNTIME always wins.
        beside = os.path.join(os.path.dirname(os.path.abspath(r6)), "runtime-win64")
        if (not env.get("R6_RUNTIME_DIR") and not env.get("ORBIT_R6_RUNTIME")
                and os.path.isdir(beside)):
            env["R6_RUNTIME_DIR"] = beside
        # A gate that runs natively must not be rescued by the C compiler.
        env["ORBIT_CC"] = env["CC"] = "orbit-native-gate-has-no-c-compiler"

    # Separate-compilation lane (ORBIT_LINK_RUNTIME=1): the compiler links each
    # TU against .orbit/lib/libruntime_net.a instead of recompiling the unity.
    # dev.py sets this env only in the `all` composition (same pattern as
    # ORBIT_PARITY_SKIP_CC for parity); standalone runs stay on unity. Ensure
    # the archive exists here so a missing lib fails fast with the builder's
    # own diagnostic instead of one cc failure per test. DB programs ignore
    # the env inside the compiler and stay unity by design (the net lib has
    # no DB symbols).
    if env.get("ORBIT_LINK_RUNTIME") == "1" and not native:
        lib_path = os.path.join(ROOT, ".orbit", "lib", "libruntime_net.a")
        if archive_is_stale(lib_path):
            out.say(f"  link lane: {lib_path} is older than runtime/, "
                    "rebuilding it ...")
            try:
                os.remove(lib_path)
            except OSError as exc:
                out.fail(f"Failed suite: cannot replace the stale {lib_path} "
                         f"({exc})")
                return 1
        if not os.path.exists(lib_path):
            cc_for_lib = args.cc or env.get("ORBIT_CC") or env.get("CC") or "gcc"
            out.say(f"  link lane: building {lib_path} ...")
            proc = subprocess.run(
                [sys.executable, os.path.join(ROOT, "scripts", "mklib_runtime.py"),
                 "--cc", cc_for_lib, "--compiler", os.path.abspath(args.compiler)],
                cwd=ROOT, env=dict(os.environ),
                capture_output=True, text=True, errors="replace", timeout=300,
            )
            sys.stdout.write(proc.stdout or "")
            sys.stderr.write(proc.stderr or "")
            if proc.returncode != 0 or not os.path.exists(lib_path):
                out.fail(f"Failed suite: ORBIT_LINK_RUNTIME=1 but {lib_path} is "
                         f"missing or stale and mklib_runtime.py did not produce "
                         f"it (rc={proc.returncode})")
                return 1

    ok = 0
    failed = []
    ratchets = []
    # `// native-known-failing: <why>` pins a defect of the native lane only:
    # the case must still fail to build there, and a build that succeeds fails
    # the gate so the directive is deleted. The C lane ignores it.
    native_red = {}
    exe_suffix = ".exe" if os.name == "nt" else ""

    plans = []
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
        plans.append((path, name, expected, ratchet.group(1) if ratchet else None))
        nk = re.search(r"^\s*//\s*native-known-failing\s*:?\s*(\S.*?)\s*$", src, re.M)
        if nk and native:
            native_red[name] = nk.group(1)

    def run_one(plan):
        # Each case owns a TEMP subdir: the intermediate C has a fixed name
        # (orbit_selfhost_build.c in $TEMP), so a shared TEMP lets one case's
        # cc read another's half-written C. Exes keep unique names in the
        # shared work dir. Returns (name, kind, *payload) for ordered
        # reporting below; only the main thread prints.
        path, name, expected, ratchet_ref = plan
        case_env = dict(env)
        tmp = os.path.join(work, "t_" + name.replace("/", "_"))
        os.makedirs(tmp, exist_ok=True)
        case_env.update({"TEMP": tmp, "TMP": tmp})
        out_exe = os.path.join(work, name.replace("/", "_") + exe_suffix)
        try:
            proc = subprocess.run(
                [args.compiler, "build", path, "-o", out_exe]
                + (["--backend=native"] if native else []),
                cwd=ROOT, env=case_env, capture_output=True, text=True,
                errors="replace", timeout=args.timeout,
            )
            build_rc = proc.returncode
        except subprocess.TimeoutExpired:
            return (name, "timeout-build")
        if build_rc != 0:
            # stderr FIRST, and this was the bug. `orbit build` writes its
            # diagnostics to stderr -- stderr-diagnostics moved them there deliberately, so
            # that `orbit check` and `orbit build` agree -- and this runner
            # captured stderr and then printed stdout, which for a failed build
            # is empty. Every build failure in this suite reported
            # "did not build (rc=1) :: (no output)" and the actual diagnostic
            # went nowhere, on every platform. It went unnoticed because the
            # suite has had no build failure since the diagnostic move, which
            # is why it took the first Windows-only one to surface it.
            diag = (proc.stderr or "").strip() or (proc.stdout or "").strip()
            tail = "\r\n".join(diag.splitlines()[-8:])
            return (name, "nobuild", tail, build_rc)
        run = subprocess.run([out_exe], cwd=work, capture_output=True,
                             timeout=args.timeout)
        if expected is None:
            ref = (" " + ratchet_ref) if ratchet_ref else ""
            if run.returncode != 0:
                return (name, "ratchet-red", run.returncode, ref)
            return (name, "ratchet-fixed")
        if run.returncode == expected:
            return (name, "ok", run.returncode)
        return (name, "wrong-exit", run.returncode, expected)

    with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
        results = list(pool.map(run_one, plans))
    for name, kind, *rest in results:
        if kind == "timeout-build":
            failed.append(name)
            out.fail(f"Failed {name}: timed out building")
        elif kind == "nobuild" and name in native_red:
            ok += 1
            ratchets.append(name)
            out.say(f"Testing {name} ... did not build natively, still red as "
                    f"declared (native-known-failing: {native_red[name]})")
        elif kind == "nobuild":
            tail, build_rc = rest
            failed.append(name)
            out.fail(f"Failed {name}: did not build (rc={build_rc})")
            for line in tail.splitlines():
                print("  " + line, file=sys.stderr)
            payload = (tail or "(no output)").replace("%", "%25").replace("\r", "%0D").replace("\r\n", "%0A")[:1200]
            out.ci_error(f"[suite build {name}] rc={build_rc} :: {payload}")
        elif kind == "ratchet-red":
            rc, ref = rest
            ok += 1
            ratchets.append(name)
            out.say(f"Testing {name} ... exit {rc}, still red as "
                    f"declared (known-failing:{ref})")
        elif kind == "ratchet-fixed":
            failed.append(name)
            out.fail(f"Failed {name}: known-failing but it now exits 0 -- the "
                     f"defect it was pinning is fixed, or the test asserts "
                     f"nothing. Delete the known-failing: directive and this "
                     f"becomes ordinary coverage.")
            out.ci_error(f"[suite ratchet {name}] known-failing now exits 0")
        elif name in native_red:
            failed.append(name)
            out.fail(f"Failed {name}: native-known-failing but it now builds -- "
                     f"delete the native-known-failing: directive")
        elif kind == "ok":
            ok += 1
            out.say(f"Testing {name} ... exit {rest[0]} as expected")
        elif kind == "wrong-exit":
            failed.append(name)
            out.fail(f"Failed {name}: got exit {rest[0]}, want {rest[1]}")

    total = len(tests)
    extra = ("(%d known-failing, asserted still red)" % len(ratchets)
             if ratchets else "")
    out.finish(tool, ok, total, extra=extra)
    if ratchets:
        out.say("Known-failing, asserted still red: " + ", ".join(ratchets))
        out.say("A ratchet is not a waiver: it asserts the failure is STILL there, so a "
                "fix fails this gate instead of passing quietly.")
        out.say("When one starts exiting 0, the defect is fixed -- delete the "
                "known-failing: directive and let the test be ordinary coverage.")
    if failed:
        payload = ", ".join(failed).replace("%", "%25").replace("\r", "%0D").replace("\r\n", "%0A")[:1500]
        out.fail("Failed: " + ", ".join(failed))
        out.ci_error(f"[orbit-suite] failed: {payload}")
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
