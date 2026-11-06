#!/usr/bin/env python3
"""The corpus gates: eight checkers over the committed programs, one entry point.

Each gate keeps its own command, its own flags and its own closing line:

    suite             tests/suite/ (and `--dir`) programs, built and run; the
                      process exit code is the assertion
    negative          tests/negative/ programs must fail to compile with the
                      text their header pins
    frontend          tests/frontend/ fixtures against their `.tir` goldens
    werror            the probe programs compiled and run under `-Werror`
    parity            tests/parity/probes/ against tests/parity/golden/
    runtime_gen       runtime/gen/*.c equal to what the compiler emits
    runtime_module    `orbit build --runtime-module` to a linkable object
    fuzz_frontend     mutated probes; the compiler must not crash natively

The gate labels in `scripts/gate_registry.py` (`suite`, `suite_std`,
`suite_native`, `suite_std_native`, `runtime_module`,
`runtime_module_native`, `runtime_gen`, `negative`, `frontend`, `parity`,
`werror`, `fuzz_frontend`) do not change here, and neither do the verdict
lines other tools match on: `Finished suite: N/N`, `Finished frontend: N/N`,
`Finished negative: N/N`, `Finished parity: N/N`, `Finished werror: N/N`,
`Finished runtime_gen: N/N`, `Finished runtime_module: N/N` and the fuzz line
`Fuzzed N iterations: ...`. `scripts/alive_check.py` keeps one regex per gate
and `scripts/gate_registry.py` one row per label, so a changed line stops
proving a gate without anything failing first.

Names that collided when the eight became one file. Each was resolved at its
first occurrence below, and the resolution never merged two behaviours:

  `ROOT`        six tools computed it with `os.path.dirname` twice and two
                (`werror_gate.py`, `runtime_gen.py`) with
                `pathlib.Path(__file__).resolve().parent.parent`. Both are
                kept: `ROOT` is the string, `ROOT_PATH` the pathlib object.
  `SKIP_RC`     `test_suite.py` and `runtime_module_gate.py` both set 77; one
                definition.
  `main`        one per tool, so it is now `cmd_<gate>(args)`.
  `unescape`    `negative_gate.py` and `frontend_gate.py` both define it and
                they are NOT the same function: the frontend one also decodes
                `\\x24` to `$`. They are `neg_unescape` and `fe_unescape`.
  `PROBES`      `werror_gate.py` holds a list of probe programs, while
                `parity_selfhost.py` and `fuzz_frontend.py` hold the directory
                `tests/parity/probes`. Now `WERROR_PROBES`, `PARITY_PROBES`
                and `FUZZ_PROBES`; the last two name the same directory on
                purpose, so each section reads as it did alone.
  `self_test`   `werror_gate.py` and `runtime_gen.py` each have one:
                `self_test_werror`, `self_test_runtime_gen`, each wired to
                that subcommand's `--self-test`. No other gate in this file
                had a `--self-test` before the merge, and none gained one.
  `run`         `runtime_module_gate.py` defines `run(argv, env)` at module
                level, which is a different function from `_common.run`; it is
                `rtmod_run`, and `_common.run` stays qualified.
  `check`       `runtime_gen.py` defines `check(compiler, cc, write)`;
                `runtime_module_gate.py` defines a nested `check(name, ok,
                detail)` inside its own command. The module-level one is
                `rg_check`, the nested one stays local.
  `header`, `modules`, `generate` and the two golden/probe directories of
                `runtime_gen.py` and `parity_selfhost.py` are prefixed `rg_`
                and `PARITY_` for the same reason: in a 2,000-line file a bare
                `generate` says nothing about which gate it belongs to.

The `Usage:` block inside each section header comment still names the old
entry point (`python scripts/negative_gate.py ...`). Those paragraphs are the
prose that records why each gate exists, and they were moved verbatim. The
current spelling of every one of them is
`python scripts/corpus_gates.py <gate> [flags]`.
"""

import argparse
import hashlib
import os
import pathlib
import random
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common  # noqa: E402
import orbit_output as out  # noqa: E402

# ROOT: the string form, as test_suite.py, negative_gate.py, frontend_gate.py,
# runtime_module_gate.py, parity_selfhost.py and fuzz_frontend.py computed it.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# ROOT_PATH: the pathlib form, as werror_gate.py and runtime_gen.py computed it.
ROOT_PATH = Path(__file__).resolve().parent.parent

# A gate that cannot run on this machine (the native path without ORBIT_R6)
# exits with this code, and scripts/dev.py reports it as skipped, not passed.
SKIP_RC = 77


# ---------------------------------------------------------------------------
# ---- from scripts/test_suite.py ----
#
# Orbit test suite runner (R2.1 minimum viable).
#
# Convention: tests/suite/<name>.orb defines `fn main() -> int`; the
# process exit code is the assertion. Optional first line:
#     // expect-exit <N>     (default 0)
#
# Every test is compiled by the fixed-point compiler and executed; the
# runner fails on compile errors, wrong exit codes, or timeouts.
#
# `--backend native` builds every case with `orbit build --backend=native`, which
# runs R6 (ORBIT_R6) instead of the C compiler, and checks the same expectations.
# Without ORBIT_R6 the run is SKIPPED, not passed: it prints why and exits 77, and
# scripts/dev.py reports the gate as skipped.
#
# One further directive, for a test that pins a defect instead of a feature:
#
#     // known-failing[: <ref>]     the test is expected NOT to exit 0
#
# This is a ratchet, in the same sense as `known-defect:` in
# scripts/negative_gate.py, and for the same reason: the alternative is to
# leave a red test in the suite, which gets deleted, or to delete the test,
# which loses the only record of what is broken. It asserts the failure is
# STILL there, so a fix fails this gate instead of passing quietly; the day
# the test starts exiting 0 the runner says so and the directive has to go.
# It excuses a wrong exit code ONLY: a test that does not build still fails,
# because "it is red" must never come to mean "it does not compile".
# ---------------------------------------------------------------------------

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
    # A checkout shared with the other host can hold an archive built there.
    # Its mtime is newer than every source, so only the stamp answers it.
    want = "platform " + ("windows" if os.name == "nt" else "unix")
    try:
        with open(lib_path + ".stamp", encoding="utf-8", errors="replace") as f:
            if want not in f.read().splitlines():
                return True
    except OSError:
        return True
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


def cmd_suite(args) -> int:
    out.set_quiet(args.quiet)

    native = args.backend == "native"
    tool = "suite_native" if native else "suite"
    r6 = os.environ.get("ORBIT_R6", "")
    if native:
        if os.name != "nt":
            # `orbit build --backend=native` refuses any host that is not Windows
            # x86-64 (`hostIsWindows` in compiler/host/pipeline.orb), so pointing
            # at an r6 here cannot produce a pass: it produced three failing gates
            # until this line named the rule.
            out.say(f"Skipped {tool}: the native backend targets Windows x86-64 "
                    "only, so this host cannot run it. This is a skip, not a pass.")
            return SKIP_RC
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


# ---------------------------------------------------------------------------
# ---- from scripts/negative_gate.py ----
#
# Negative-compilation gate: every program here must FAIL to compile.
#
# The rest of the battery is positive -- it asserts that programs the language
# accepts still work. That is why three audit rounds in a row found defects no
# gate saw: a `union` match missing a variant, `.at()` on a list of ints, and
# `print(undeclaredThing)` all *compile clean* and then do the wrong thing at
# runtime. There was not one test in the repo asserting a type error, so a
# front end that rejects nothing at all scored a perfect run.
#
# This gate is that missing assertion. For each `tests/negative/*.orb` it runs
# `orbit check` and requires a non-zero exit plus the diagnostic named in the
# file's header.
#
# Header directives, one per case, exactly one of:
#
#     // expect-error: <substring>
#         The program must fail to compile and the diagnostic must contain
#         <substring>. Both the exit code and the text are asserted: a
#         diagnostic that improves fails the gate until the header is updated,
#         because a better message nobody reads is still an unpinned message.
#
#     // known-defect: <ref>
#         The program is one the language must reject and today does not. The
#         gate asserts the BUG is still present -- `orbit check` must still exit
#         zero. This is a ratchet, not an excuse: the moment the compiler starts
#         rejecting it the gate fails and says so, which is the moment to
#         replace `known-defect:` with `expect-error:` and record the text.
#
# A known-defect case may also pin the wrong ANSWER, which is the part that
# reaches a user: `orbit check` being clean is only half of a silent defect.
# All three of these are optional and only meaningful on a known-defect case:
#
#     // wrong-value: <expected stdout, \\n for newline>
#         Build and run the program; its stdout must still be exactly this.
#         Use it when the compiler accepts the program and then computes the
#         wrong number -- a truncated literal, an unsigned division, an out
#         of range index. `\n` separates lines.
#
#     // cc-rejects: <substring>
#         The front end must stay silent AND the C toolchain must still reject
#         the output with <substring>. This is the "check clean, C step fails"
#         shape (F-0004, F-0011), and the substring is the point: it names the
#         C symbol or C type the emitter invented. Both halves are ratchets, so
#         the case fires whether the fix lands in the front end or in codegen.
#
#     // no-diagnostic:
#         The program must still BUILD and must still DIE WITHOUT SAYING
#         ANYTHING: non-zero exit, and nothing on stdout or stderr. This is for
#         the class where the wrong answer is a crash -- `print((7) / 0)` is
#         SIGFPE, and a `wrong-value:` cannot pin a signal. Without it such a
#         case pins nothing but the front end's silence, which is the weakest
#         thing in this directory; with it, the case holds the behaviour and
#         fires when the fix arrives, because a diagnostic is a message.
#         Mechanism-neutral on purpose: a signal on POSIX, an exception status
#         on Windows, the same observable either way.
#
# A case that pins none of those still pins its class: the front end accepts
# this program, and the gate fails the day it stops.
#
# One directive is optional on an expect-error case instead:
#
#     // one-diagnostic:
#         The rejection is exactly one diagnostic line (`error[<CODE>]` in the
#         combined output). A header that pins a substring passes when the same
#         refusal prints four times, which is what a checker that re-reads a node
#         does: the text is right and the reader sees it two, three or four
#         times. Use it where the count is the thing being claimed.
#
# Usage:
#     python scripts/negative_gate.py [--compiler PATH] [--cc CC] [--list]
#                                     [--no-build] [--quiet]
#
# Exit code 0 iff every case matched its declaration.
# ---------------------------------------------------------------------------

NEGATIVE = os.path.join(ROOT, "tests", "negative")

EXPECT_ERROR = re.compile(r"^\s*//\s*expect-error:\s*(\S.*?)\s*$", re.M)
KNOWN_DEFECT = re.compile(r"^\s*//\s*known-defect:\s*(\S.*?)\s*$", re.M)
CASE_NAME = re.compile(r"^\s*//\s*case:\s*(\S.*?)\s*$", re.M)
WRONG_VALUE = re.compile(r"^\s*//\s*wrong-value:\s*(\S.*?)\s*$", re.M)
CC_REJECTS = re.compile(r"^\s*//\s*cc-rejects:\s*(\S.*?)\s*$", re.M)
NO_DIAGNOSTIC = re.compile(r"^\s*//\s*no-diagnostic:\s*$", re.M)
ONE_DIAGNOSTIC = re.compile(r"^\s*//\s*one-diagnostic:\s*$", re.M)

# One front-end diagnostic, as it appears in the combined stdout and stderr of
# `orbit check`: the code is the part a reader acts on, so a repeated line is a
# repeated refusal even when the framing differs.
DIAGNOSTIC_LINE = re.compile(r"error\[[A-Z][0-9]+\]")


def neg_unescape(literal):
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
        self.one_diagnostic = ONE_DIAGNOSTIC.search(self.source)

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
    if case.one_diagnostic and case.kind != "error":
        return ("fail", "one-diagnostic: only means anything on an expect-error: "
                "case -- a known defect is accepted, so there is no refusal to "
                "count")
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
        if case.one_diagnostic:
            found = DIAGNOSTIC_LINE.findall(combined)
            if len(found) != 1:
                return "fail", ("the same refusal printed %d times: %s\n"
                                "    header declares one-diagnostic:, so the "
                                "program is rejected by one diagnostic\n"
                                "    got:            %s"
                                % (len(found), case.rel,
                                   describe(combined, True)))
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
    # Every build writes its intermediate C to $TMP/orbit_selfhost_build.c, so a
    # shared TEMP is a race between two gates in the same job. Own it.
    env = _common.build_env(work, cc=cc)
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
    want = neg_unescape(case.wrong_value.group(1))
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


def cmd_negative(args):
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

    def run_one(case):
        # Each case owns a TEMP subdir: the intermediate C has a fixed name
        # (orbit_selfhost_build.c in $TEMP), so a shared TEMP lets one case's
        # cc read another's half-written C. Returns (case, verdict, detail)
        # for ordered reporting below; only the main thread prints.
        tmp = os.path.join(work, "n_" + re.sub(r"[^A-Za-z0-9_.-]", "_", case.name))
        os.makedirs(tmp, exist_ok=True)
        verdict, detail = run_case(args.compiler, case, args.verbose, cc, tmp)
        return (case, verdict, detail)

    with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
        results = list(pool.map(run_one, cases))
    for case, verdict, detail in results:
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
        # The command the reader is told to run has this file's own name in it,
        # so it names the entry point that exists, not the one that was merged.
        out.tip("run `python scripts/corpus_gates.py negative --compiler <orbit>` "
                "to see both texts")
    return 1 if fails else 0


# ---------------------------------------------------------------------------
# ---- from scripts/frontend_gate.py ----
#
# Gate for `orbit frontend`: the four canonical TIR expectations.
#
# `orbit frontend` had no CI coverage at all. The only thing that mentioned it
# was one usage-string case in `cli_probe.py`, so the front end could emit
# arbitrary garbage into `tests/frontend/expected/*.tir` and every gate stayed
# green. The goldens are the contract from `docs/architecture/TYPED_IR.md`:
# `orbit frontend` over a fixture, diffed against the checked-in `.tir`.
#
# There are two fixture shapes under `tests/frontend/`, and the gate runs each
# the way it is actually meant to be exercised:
#
#   emit   The fixture embeds a source string and calls
#          `compileFrontendSource("name", source)`. The inner source is
#          extracted, written to a temp file, and put through the `orbit
#          frontend` CLI. One normalisation: the CLI names the module after the
#          input path, while the harness names it with its own literal, so the
#          single `module` line is replaced by the golden's before diffing. The
#          golden's module name is separately asserted to equal the harness's
#          literal, so the normalisation cannot hide a rename in either file.
#
#   run    The fixture builds TIR through the `tir.orb` API instead of parsing,
#          so there is nothing to hand the CLI. It is built and executed and its
#          stdout is diffed against the golden. This is the in-process path the C
#          backend actually consumes, so it is worth pinning next to the CLI
#          path: the two agreeing is the useful result, the two disagreeing is
#          the finding.
#
#   empty  The fixture asserts that a diagnostic or an unresolved type SUPPRESSES
#          TIR. There is nothing to diff, so the gate asserts the suppression and
#          the message the fixture prints.
#
# One table in this file is a ratchet: KNOWN_UNBUILDABLE, the two fixtures that
# cannot be built at all because of F-0004. The gate requires them to keep
# failing, so the fix for F-0004 shows up here as a red run rather than as a
# golden nobody has ever diffed against real output.
#
# Usage:
#     python scripts/frontend_gate.py [--compiler PATH] [--cc CC] [--list]
#                                     [--emit-only] [--quiet]
#
# Exit code 0 iff every fixture matched. This gate never rewrites a golden: the
# front end is the core zone, and a wrong expectation is filed, not blessed.
# ---------------------------------------------------------------------------

FRONTEND = os.path.join(ROOT, "tests", "frontend")
EXPECTED = os.path.join(FRONTEND, "expected")

# `val source = "<literal>"` in a fixture that pipes a string through
# compileFrontendSource. Only the escapes Orbit's own string syntax has.
SOURCE_LITERAL = re.compile(r'val\s+source\s*=\s*"((?:[^"\\]|\\.)*)"')
MODULE_LITERAL = re.compile(r'compileFrontendSource\(\s*"((?:[^"\\]|\\.)*)"\s*,')
# An emit fixture may bring one sibling file: its `val importedSource = "..."`
# carries the text, and the first `import "..."` of the embedded source names
# where to write it. The frontend reads imports from disk, so a fixture that
# claims something about a call across the boundary has to put the imported
# file where the compiler will find it.
IMPORTED_SOURCE_LITERAL = re.compile(r'val\s+importedSource\s*=\s*"((?:[^"\\]|\\.)*)"')
IMPORT_STMT = re.compile(r'^\s*import\s+"([^"]+)"', re.M)

# Fixtures with no golden, because the contract they pin is the ABSENCE of
# output. Named here rather than in a header comment so the gate owns the whole
# expectation in one place; tests/frontend/ is not this gate's to edit.
EMPTY_EXPECTATIONS = {
    "syntax_error.orb": "syntax diagnostic suppressed TIR",
    "unresolved_type.orb": "unresolved type suppressed TIR",
    # A callee the program does not declare stays an unknown identifier. The
    # reader of types consults the program's own declarations now, and an empty
    # answer must not overwrite "unknown" -- that silenced E2001 corpus-wide.
    "undeclared_callee.orb": "undeclared callee suppressed TIR",
    # A `for` over a value that is not a range needs the item's element type,
    # which this pass does not keep. Emitting `unknown` instead would suppress
    # the same TIR and raise the count the ratchet holds.
    "list_iteration.orb": "list iteration stays a give-up",
    # The query-helper rule reads the member name off a model this program declares.
    # An undeclared receiver has no table to answer from, so it keeps its E2001 and
    # the file prints nothing -- the control for the helper rule in this directory.
    "undeclared_model_helper.orb": "an undeclared receiver keeps its E2001",
    # An `if` in value position joins the arms on one name only when both branches
    # answer the same type. Two types are not one value, so the pass gives up and
    # the file prints nothing.
    "if_value_branch_types.orb": "branches that disagree stay a give-up",
    # An arm that binds a payload on a variant that declares none: the name would
    # hold no value, so the pass refuses rather than print TIR for it.
    "variant_match_bindless.orb": "a bindless arm is refused",
    # The read of a field declared as a type parameter answers the argument the
    # instance writes. A generic literal writes none, so `b.v` under
    # `val b = Box { v: 3 }` has no type to print and the file stays suppressed.
    "generic_literal_field_read.orb": "a generic literal names no argument",
    # A field whose type names a model declared in ANOTHER file. The table is
    # the program's own text, so the name has no answer and the read keeps its
    # E2004; the fixture prints only when the refusal names that code, so an
    # input that stopped reaching the member-read rule cannot pass here.
    "crossfile_field.orb": "cross-file model field suppressed TIR",
}


# `$` followed by `{` is interpolated by whichever lexer reads the text, so a
# fixture cannot embed a source containing an interpolation hole: the fixture's
# own literal would swallow it. The four characters backslash-x-2-4 are decoded
# here, in the test plumbing and not as a language escape, so the pair reaches
# the embedded source.
DOLLAR_ESCAPE = chr(92) + "x24"


def fe_unescape(literal):
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
    return "".join(out_chars).replace(DOLLAR_ESCAPE, "$")


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
    module = fe_unescape(MODULE_LITERAL.search(source).group(1))
    golden = read(golden_path)

    want_module = module_line(golden)
    if want_module != "module " + module:
        return False, ("golden names module %r but the fixture compiles %r -- "
                       "rename one or the other; do not let the gate normalise "
                       "a disagreement away" % (want_module, "module " + module))

    inner = os.path.join(work, os.path.splitext(name)[0] + ".orb")
    with open(inner, "w", encoding="utf-8", newline="\n") as f:
        f.write(fe_unescape(body) + "\n")
    imported = IMPORTED_SOURCE_LITERAL.search(source)
    if imported is not None:
        stmt = IMPORT_STMT.search(fe_unescape(body))
        if stmt is None:
            return False, ("the fixture carries importedSource but its source "
                           "imports no file to write it to")
        dest = os.path.join(work, *stmt.group(1).split("/"))
        parent = os.path.dirname(dest)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(dest, "w", encoding="utf-8", newline="\n") as f:
            f.write(fe_unescape(imported.group(1)) + "\n")
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
    env = _common.build_env(work, cc=cc)
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
    env = _common.build_env(work, cc=cc)
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


# F-0004 is fixed: parser.orb reached parseIntSelfhost through builder.orb,
# which a program using the front end does not import, and neither imported
# extern.orb for orbit_os_write_stderr_selfhost. parseIntSelfhost now lives in
# compiler/front/literal.orb, a leaf module both callers import, so the emitted C
# declares what it uses. The ratchet that asserted these two stayed broken has
# been removed -- it would now fire on every run, which is the point at which a
# ratchet has done its job.
KNOWN_UNBUILDABLE = {}


def assert_still_broken(compiler, cc, work, name, why):
    """A fixture on the known-unbuildable list must still fail to build.

    When it starts building, that is good news and a gate failure: the
    contract it claims to assert has never actually been checked.
    """
    env = _common.build_env(work, cc=cc)
    rel = os.path.relpath(os.path.join(FRONTEND, name), ROOT).replace("\\", "/")
    exe = os.path.join(work, "probe_unbuildable")
    p = subprocess.run([compiler, "build", rel, "-o", exe], cwd=ROOT, env=env,
                       capture_output=True, text=True, errors="replace")
    if p.returncode != 0:
        return True, "known-unbuildable, as expected (%s)" % why
    return False, ("this fixture builds now, so remove it from "
                   "KNOWN_UNBUILDABLE and check %s against real output" % name)


def cmd_frontend(args):
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
    tasks = []
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
        tasks.append((name, kind, golden_path))

    def run_one(task):
        # Each fixture owns a work subdir: builds share the fixed
        # intermediate-C name via $TEMP, so a shared dir lets one fixture's
        # cc read another's half-written C. Only the main thread prints.
        name, kind, golden_path = task
        unit = os.path.join(work, "u_" + name.replace(".", "_"))
        os.makedirs(unit, exist_ok=True)
        if name in KNOWN_UNBUILDABLE:
            # Ratchet, not waiver: the gate now requires this fixture to stay
            # broken, and tells whoever fixes it what to do next.
            return (name, "ratchet") + assert_still_broken(
                args.compiler, args.cc, unit, name, KNOWN_UNBUILDABLE[name])
        if kind == "emit":
            return (name, "check") + run_emit(
                args.compiler, unit, name, read(os.path.join(FRONTEND, name)),
                golden_path)
        if kind == "run":
            return (name, "check") + run_run(
                args.compiler, args.cc, unit, name, golden_path)
        return (name, "check") + run_empty(
            args.compiler, args.cc, unit, name, EMPTY_EXPECTATIONS[name])

    with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
        results = list(pool.map(run_one, tasks))
    for name, kind, good, detail in results:
        if kind == "ratchet":
            if good:
                ok += 1
            else:
                fails.append(name)
                out.ci_error("[frontend %s] %s" % (name, out.scrub_ci(detail)))
            out.say("Checking tests/frontend/%s ... %s" % (name, detail))
        elif good:
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


# ---------------------------------------------------------------------------
# ---- from scripts/parity_selfhost.py ----
#
# Self-host stability gate.
#
# The contract is stability against committed goldens:
#
#     every probe compiled by the fixed-point self-host compiler must produce
#     exactly the recorded outcome (generated-C hash or normalized diagnostics).
#
# There is no second implementation to compare against, so the goldens are the
# contract rather than a cross-check. An intentional compiler change requires an
# explicit golden refresh (`--update`) committed in the same commit as the
# canonical C, the sources and PUBLISHED_C.
#
# Probe outcomes:
#   exit == 0  -> golden records the SHA-256 of the generated C
#   exit != 0  -> golden records the normalized compiler diagnostics
#
# Fast path for composed runs (`make all`): when the environment variable
# ORBIT_PARITY_SKIP_CC=1 is set (dev.py sets it in the `all` composition),
# each probe runs with ORBIT_SKIP_CC=1, so the compiler emits the intermediate
# C and stops without invoking gcc, and this gate hashes that C directly. The
# recorded outcomes are unchanged: kind=C goldens store only the SHA-256 of the
# emitted C (never the build log), and every kind=DIAG golden fails in the
# frontend, before the C step, so skipping cc cannot move them. The "this C
# compiles" witness this skips is covered in the same composition by werror_gate
# (generated C under -Werror) and the suite/std gates, which build and run
# programs through the full pipeline with gcc. Without that variable the gate
# behaves exactly as before (standalone still compiles each probe with gcc).
#
# Usage:
#     python scripts/parity_selfhost.py --compiler PATH [--cc CC] [--update]
#                                       [--goldens DIR] [--work DIR]
#
# Exit code 0 iff every probe matches its golden.
# ---------------------------------------------------------------------------

PARITY_PROBES = os.path.join(ROOT, "tests", "parity", "probes")
PARITY_GOLDENS = os.path.join(ROOT, "tests", "parity", "golden")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def normalize_diag(text: str) -> str:
    """Make diagnostics machine-independent: LF endings and forward slashes."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = text.replace("\\", "/")
    # Wall-clock is not a diagnostic: `Failed to compile ... in 3 ms` pins
    # the machine's mood, not the compiler's answer, and turns this gate
    # into a lottery (e2/e5 flip 0/1 ms between runs on a clean tree).
    text = re.sub(r"in \d+ ms", "in N ms", text)
    return text


def scrub_work_paths(text: str, work: str) -> str:
    """Replace the run's work/temp directories with <TMP> (longest first)."""
    needles = []
    for raw in (work, os.path.dirname(work), tempfile.gettempdir()):
        if raw:
            needles.append(raw)
            needles.append(raw.replace("\\", "/"))
    for n in sorted(set(needles), key=len, reverse=True):
        if n:
            text = text.replace(n, "<TMP>")
    return text


def probe_outcome(compiler: str, probe_path: str, name: str, work: str, cc: str):
    tmp = os.path.join(work, name)
    if os.path.isdir(tmp):
        shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp, exist_ok=True)
    env = dict(os.environ)
    env.update({"TEMP": tmp, "TMP": tmp, "ORBIT_CC": cc, "CC": cc})
    # Composed runs (`make all`) set ORBIT_PARITY_SKIP_CC=1 via dev.py: emit
    # the C and hash it directly instead of paying for 25 gcc links. The hash
    # is over the emitted C only, so the goldens cannot tell the difference;
    # DIAG probes fail before the C step and never reach cc either way.
    if os.environ.get("ORBIT_PARITY_SKIP_CC") == "1":
        env["ORBIT_SKIP_CC"] = "1"
    rel_probe = os.path.relpath(probe_path, ROOT)
    proc = subprocess.run(
        [compiler, "build", rel_probe, "-o", os.path.join(tmp, name + ".exe")],
        cwd=ROOT, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        errors="replace",
    )
    inter_c = os.path.join(tmp, "orbit_selfhost_build.c")
    if proc.returncode == 0 and os.path.isfile(inter_c):
        with open(inter_c, "rb") as f:
            return proc.returncode, "C", sha256_bytes(f.read())
    return proc.returncode, "DIAG", scrub_work_paths(normalize_diag(proc.stdout or ""), work)


def cmd_parity(args) -> int:
    out.set_quiet(args.quiet)

    probes = sorted(f for f in os.listdir(PARITY_PROBES) if f.endswith(".orb"))
    if not probes:
        out.fail("Failed parity: no probes found")
        return 1

    work = args.work or tempfile.mkdtemp(prefix="orbit_parity_")
    os.makedirs(args.goldens, exist_ok=True)

    ok = 0
    failed = []
    outcomes = {}
    if not args.update:
        # Probes are independent: each builds in its own work/<name> dir, so
        # they run in a pool and report in probe order. (A noop cc is NOT how:
        # the pipeline resolves ORBIT_CC as a path, so a multi-token noop
        # fails with "was not found" and every C golden goes red. Measured.)
        def run_one(pf):
            name = pf[:-4]
            rc, kind, payload = probe_outcome(
                args.compiler, os.path.join(PARITY_PROBES, pf), name, work,
                args.cc or "")
            return (name, rc, kind, payload)
        with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
            for name, rc, kind, payload in pool.map(run_one, probes):
                outcomes[name] = (rc, kind, payload)
    for pf in probes:
        name = pf[:-4]
        probe_path = os.path.join(PARITY_PROBES, pf)
        if args.update:
            rc, kind, payload = probe_outcome(args.compiler, probe_path, name, work, args.cc or "")
        else:
            rc, kind, payload = outcomes[name]
        golden_path = os.path.join(args.goldens, name + ".txt")
        golden = f"exit={rc}\nkind={kind}\n{payload}"

        if args.update:
            with open(golden_path, "w", encoding="utf-8", newline="\n") as f:
                f.write(golden)
            out.say(f"Updated golden for {name} ({kind})")
            ok += 1
            continue

        if not os.path.isfile(golden_path):
            failed.append(name)
            out.fail(f"Failed {name}: no golden recorded")
            out.tip("run with --update to record it, then commit the golden")
            continue
        with open(golden_path, "r", encoding="utf-8", newline="") as f:
            expected = f.read().replace("\r\n", "\n")
        if expected == golden:
            ok += 1
            out.say(f"Checking {name} ... match ({kind})")
        else:
            failed.append(name)
            exp_lines = expected.split("\n")
            got_lines = golden.split("\n")
            detail = ""
            for i in range(min(len(exp_lines), len(got_lines))):
                if exp_lines[i] != got_lines[i]:
                    detail = f"(line {i+1}: expected '{exp_lines[i][:40]}' got '{got_lines[i][:40]}')"
                    break
            out.fail(f"Failed {name}: mismatch {detail}")
            payload = f"golden={expected[:200]!r} got={golden[:200]!r}"
            out.ci_error(f"[parity {name}] {out.scrub_ci(payload, 3800)}")

    total = len(probes)
    out.finish("parity", ok, total, "match goldens" if not failed else "")
    if failed:
        out.fail("Failed: " + ", ".join(failed))
    if failed and not args.update:
        # One consolidated annotation: survives even if per-probe commands
        # are dropped, and carries the expected/got payloads verbatim.
        parts = []
        for pf in probes:
            name = pf[:-4]
            if name in failed:
                gp = os.path.join(args.goldens, name + ".txt")
                exp = open(gp, encoding="utf-8", newline="").read() if os.path.isfile(gp) else "<missing>"
                rc, kind, payload = outcomes[name]
                parts.append(f"{name}: rc={rc} kind={kind} | GOLDEN={exp[:150]!r} | GOT={payload[:150]!r}")
        blob = " || ".join(parts)
        out.ci_error(f"[parity diffs] {out.scrub_ci(blob, 3500)}")
    if args.update:
        out.say("Goldens refreshed; commit them together with the compiler change.")
        return 0
    return 0 if not failed else 1


def parity_guarded(args) -> int:
    """`parity_selfhost.py` printed its own traceback and a CI annotation on
    crash, and then re-raised; nothing in the goldens says whether a probe
    mismatch or a Python defect broke the run, so that distinction is kept.
    """
    try:
        return cmd_parity(args)
    except Exception:
        import traceback
        tb = traceback.format_exc()[-2500:]
        print(tb, file=sys.stderr)
        out.ci_error("[parity crash] " + out.scrub_ci(tb, 2500))
        raise


# ---------------------------------------------------------------------------
# ---- from scripts/werror_gate.py ----
#
# Gate: every probe program must compile AND run clean under -Werror.
#
# Covers expression-shaped, IO-shaped, server-shaped (route table only),
# db-shaped (SQLite, skipped if unavailable), and builtin-heavy probes.
# Usage: python scripts/werror_gate.py [--compiler PATH] [--cc gcc] [--list]
# ---------------------------------------------------------------------------

WERROR_PROBES = [
    ("arith", "fn main() -> int {\n    return (6 * 7) + 1 - 1\n}", 42),
    ("string_eq", 'fn main() -> int {\n    val a = "orbit"\n    val b = "orb" + "it"\n    if a == b {\n        return 5\n    }\n    return 6\n}', 5),
    ("while_loop", "fn main() -> int {\n    var i = 0\n    while i < 5 {\n        i = i + 1\n    }\n    return i\n}", 5),
    ("try_ok", "fn make_success() -> result {\n    val value: result = ok(41)\n    return value\n}\nfn main() -> int {\n    val r: result = make_success()\n    val v: int = try r catch {\n        return 2\n    }\n    if v != 41 { return 3 }\n    return 1\n}", 1),
    ("try_catch", 'fn make_failure() -> result {\n    val value: result = err("invalid input", 7)\n    return value\n}\nfn read_failure() -> int {\n    val value: int = try make_failure() catch {\n        return 7\n    }\n    return value\n}\nfn main() -> int {\n    return read_failure()\n}', 7),
    ("string_ops", 'fn main() -> int {\n    val s = "ab" + "cd"\n    return s.len()\n}', 4),
    ("http_routes", 'fn helper() -> int {\n    return 5\n}\nroute GET "/p" {\n    val n = helper()\n    val s = "n=" + n\n    return ok 200 s\n}\nfn main() -> int {\n    return 0\n}', "serve",
     ("-DORBIT_WITH_NET",)),
    ("bool_logic", "fn main() -> int {\n    if 1 < 2 && 2 < 3 {\n        return 5\n    }\n    return 6\n}", 5),
    ("model_ctor", "model Rect {\n    width: int\n    height: int\n}\nfn main() -> int {\n    val r = Rect(3, 4)\n    return r.width + r.height\n}", 7),
    # A nested object literal is the only construct that reaches
    # orbit_object_set_object: the setter is chosen by the value register's
    # type, and "object" is only the type of a field whose value is itself a
    # literal. The cast chain in c_backend.orb had an arm each for int, float
    # and bool and fell through to (const char*) for everything after them, so
    # this one line handed a const char* to an OrbitObject* parameter. Every
    # other probe here is a model, a route or an arithmetic expression, so
    # the clean-emission gate never reached it and the language suite was the only red thing --
    # on the toolchains that promote the warning, and only on those.
    ("object_literal_nested", 'fn main() -> int {\n    val o = { deep: { deeper: 7 } }\n    return o.deep.deeper\n}', 7),
    # A response body reaches orbit_response_json as a `const char*`. Sema can
    # only reject a body whose type it can prove, so an expression inferring as
    # `unknown` used to arrive as a bare register and hand an int to a pointer
    # parameter -- the int-to-pointer conversion this gate exists to catch, and
    # a segfault on the first request. A mismatched arithmetic expression is the
    # shape no type rule can pin down, which is why the fix converts by the
    # register type the backend settled on instead of by what sema guessed.
    ("response_body_unknown_type", "fn body() -> response {\n    return ok 200 1 + true\n}\nfn main() -> int {\n    body()\n    return 0\n}", 0,
     ("-DORBIT_WITH_NET",)),
]


def tail_with_head(text, limit=1200):
    r"""Keep the head of a compiler's output, not the tail.

    This gate existed for five consecutive CI runs to report a failure whose
    cause was invisible in its own output. clang puts the diagnostic on the
    FIRST line -- "'getenv': This function or variable may be unsafe" -- and
    then four lines of note: chain showing which macro in which MSVC header
    expanded it. Keeping the last 600 characters kept the notes and threw away
    the sentence naming the function, so the log said

        Failed arith [WERROR-FAIL]: ...icrosoft Visual Studio\...vcruntime.h:358

    which is the middle of a filename. A gate that cannot show its own
    diagnostic is a gate that cannot be acted on, and the whole run went red
    five times over a cause nobody could read.

    So: the head is kept, because that is where the answer is, and the tail is
    kept too when the output is long enough that the head alone would lose the
    summary.
    """
    if len(text) <= limit:
        return text
    head = text[:limit - 200]
    tail = text[-200:]
    return head + "\n... [%d characters elided] ...\n" % (len(text) - limit) + tail


def run_probe(compiler, cc, name, src, expect, extra_flags=()):
    with tempfile.TemporaryDirectory(prefix="werror_") as td:
        td = Path(td)
        (td / "main.orb").write_text(src)
        env = dict(os.environ)
        env.update({"TEMP": str(td), "TMP": str(td)})
        p1 = subprocess.run([str(compiler), "build", str(td / "main.orb"),
                             "-o", str(td / "app.exe")], env=env,
                            capture_output=True, text=True, errors="replace")
        if p1.returncode != 0:
            return (name, "ORBIT-FAIL", tail_with_head(p1.stdout + p1.stderr, 900))
        c_file = td / "orbit_selfhost_build.c"
        if not c_file.exists():
            return (name, "NO-C", "orbit build left no orbit_selfhost_build.c in TEMP")
        exe = td / "app_checked.exe"
        link_flags = ["-lws2_32"] if os.name == "nt" else []
        # No -s here. It is a link-time strip for a binary this gate builds,
        # runs and throws away, so it bought nothing, and it is not portable:
        # gcc and clang-on-Linux accept it, but clang's Windows/MSVC driver
        # rejects it outright, which under -Werror surfaced as
        # "argument unused during compilation: '-s'" and failed all 9 probes.
        p2 = subprocess.run([cc, "-O0", "-Werror", "-I", str(ROOT_PATH / "runtime")]
                            + list(extra_flags) + [str(c_file)] + link_flags + [
                             "-o", str(exe)], capture_output=True, text=True, errors="replace",
                            cwd=str(ROOT_PATH))
        if p2.returncode != 0:
            return (name, "WERROR-FAIL", tail_with_head(p2.stdout + p2.stderr, 1400))
        try:
            # 3s, not 15: what this proves is "the server did not die on
            # startup" (the STAB case), and a binary that survives 3s linked
            # gives the same signal as one that survives 15s.
            p3 = subprocess.run([str(exe)], capture_output=True, text=True, errors="replace",
                                timeout=3)
        except subprocess.TimeoutExpired:
            if expect == "serve":
                return (name, "OK", "server kept running past 3s, -Werror compile clean")
            return (name, "EXIT-FAIL", "timed out after 3s")
        if p3.returncode != expect:
            return (name, "EXIT-FAIL", f"exit={p3.returncode} want={expect}")
        return (name, "OK", f"exit={p3.returncode}")


def self_test_werror():
    """The gate's own reporting, checked.

    This gate went red five times in a row on Windows without anybody being
    able to read why, because it kept the tail of clang's output and clang
    writes the diagnostic on the first line. A gate that cannot show its own
    failure is a gate that cannot be acted on, so the truncation is now a
    function with a test, and the test is the thing that would have caught it
    in the first run instead of the fifth.
    """
    fails = 0

    def check(label, ok):
        nonlocal fails
        if ok:
            out.say(f"  ok    {label}")
        else:
            out.fail(f"  BROKEN {label}")
            fails += 1

    # The exact shape that hid the cause: a one-line diagnostic, then notes.
    diagnostic = "'getenv': This function or variable may be unsafe. Consider using _dupenv_s instead.\n"
    notes = ("C:\\...\\vcruntime.h:358:55: note: expanded from macro '_CRT_INSECURE_DEPRECATE'\n"
             "  358 | #define _CRT_INSECURE_DEPRECATE(_Replacement) _CRT_DEPRECATE_TEXT(\n"
             "1 error generated.\n")
    noise = notes + ("filler line about something unrelated\n" * 200)

    got = tail_with_head(diagnostic + noise, 1400)
    check("the diagnostic line survives truncation", diagnostic.strip() in got)
    check("the summary survives too", "1 error generated" in got)
    check("the middle is elided rather than silently dropped",
          "elided" in got)

    # Short output must come back untouched, or the elision marker would show
    # up on every probe that passes.
    short = "one line\n"
    check("short output is returned unchanged", tail_with_head(short, 1400) == short)

    # The old behaviour is the bug, so assert it is gone rather than only
    # asserting the new behaviour is present.
    old = (diagnostic + noise)[-600:]
    check("the tail-only behaviour this replaced would have lost it",
          diagnostic.strip() not in old)

    # And a null/empty input must not explode: a probe that produced no output
    # is a real case, not a hypothetical one.
    check("empty input does not raise", tail_with_head("", 1400) == "")

    out.finish("werror gate self-test", 6 - fails, 6)
    return 1 if fails else 0


def cmd_werror(args):
    if args.self_test:
        return self_test_werror()
    if args.list:
        for probe in WERROR_PROBES:
            print(probe[0])
        return 0
    fails = 0
    # Probes are independent (each owns its TemporaryDirectory, including its
    # TEMP/TMP), so they run in a pool and report in PROBES order.
    def run_one(probe):
        name, src, expect = probe[0], probe[1], probe[2]
        flags = probe[3] if len(probe) > 3 else ()
        return run_probe(args.compiler, args.cc, name, src, expect, flags)
    with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
        results = list(pool.map(run_one, WERROR_PROBES))
    for name, status, detail in results:
        if status == "OK":
            out.say(f"Checking {name} ... ok ({detail})")
        else:
            out.fail(f"Failed {name} [{status}]: {detail}")
            fails += 1
    out.finish("werror", len(WERROR_PROBES) - fails, len(WERROR_PROBES))
    return 1 if fails else 0


# ---------------------------------------------------------------------------
# ---- from scripts/runtime_gen.py ----
#
# Keep runtime/gen/<name>.c equal to what the compiler emits for runtime/orb/<name>.orb.
#
# The runtime is built before the compiler that is built against it, so it
# cannot need the compiler: the C of each Orbit runtime module is committed in
# runtime/gen and is what the seed build, the unity build, Linux and the default
# archive compile. This script regenerates each file with the fixed point
# (`orbit build --runtime-module`, ORBIT_SKIP_CC=1, the C backend) and compares
# bytes.
#
#   --compiler PATH   the fixed point (dev.py passes it).
#   --write           rewrite the files that differ instead of failing.
#   --self-test       a changed generated file and an unlisted one must both be
#                     reported (D8).
#
# Usage:
#     python scripts/runtime_gen.py --compiler PATH
#     python scripts/runtime_gen.py --compiler PATH --write
#
# The header this function writes is part of the committed bytes of
# runtime/gen/*.c, so it still names `scripts/runtime_gen.py`. Renaming the
# generator means rewriting every generated file, which is a compiler run and a
# separate decision from this merge.
# ---------------------------------------------------------------------------

RG_ORB = ROOT_PATH / "runtime" / "orb"
RG_GEN = ROOT_PATH / "runtime" / "gen"


def rg_header(name):
    return (
        "/* Generated from runtime/orb/%s.orb by scripts/runtime_gen.py. Do not edit.\n"
        " * Regenerate with `python scripts/dev.py promote`; the runtime_gen gate\n"
        " * fails on any byte that differs from what the compiler emits. */\n" % name
    )


def rg_modules():
    return sorted(p.stem for p in RG_ORB.glob("*.orb"))


def rg_generate(compiler, name, cc):
    """The bytes runtime/gen/<name>.c must hold, or (None, diagnostic)."""
    work = pathlib.Path(tempfile.mkdtemp(prefix="orbit_rtgen_"))
    try:
        env = _common.build_env(work, cc=cc)
        env["ORBIT_SKIP_CC"] = "1"
        env["ORBIT_BACKEND"] = "c"
        env["ORBIT_CCACHE"] = "0"
        src = os.path.join("runtime", "orb", name + ".orb")
        proc = subprocess.run(
            [compiler, "build", "--runtime-module", src,
             "-o", str(work / (name + ".o")), "--quiet"],
            cwd=str(ROOT_PATH), env=env, capture_output=True, text=True,
            errors="replace", timeout=300)
        emitted = work / "orbit_selfhost_build.c"
        if not emitted.is_file():
            return None, (proc.stdout or "") + (proc.stderr or "")
        body = emitted.read_bytes().decode("utf-8").replace("\r\n", "\n")
        return (rg_header(name) + body).encode("utf-8"), ""
    finally:
        shutil.rmtree(work, ignore_errors=True)


def rg_check(compiler, cc, write):
    names = rg_modules()
    results = []
    RG_GEN.mkdir(parents=True, exist_ok=True)
    for name in names:
        want, why = rg_generate(compiler, name, cc)
        path = RG_GEN / (name + ".c")
        if want is None:
            out.fail("  FAIL %s: the compiler emitted no C\n    %s" % (name, why.strip()))
            results.append(False)
            continue
        have = path.read_bytes() if path.is_file() else None
        if have == want:
            out.say("  ok   runtime/gen/%s.c" % name)
            results.append(True)
        elif write:
            path.write_bytes(want)
            out.say("  wrote runtime/gen/%s.c (%d bytes)" % (name, len(want)))
            results.append(True)
        else:
            out.fail("  FAIL runtime/gen/%s.c differs from the compiler's output; "
                     "run `python scripts/dev.py promote`" % name)
            results.append(False)
    for path in sorted(RG_GEN.glob("*.c")):
        if path.stem not in names:
            if write:
                path.unlink()
                out.say("  removed runtime/gen/%s" % path.name)
            else:
                out.fail("  FAIL runtime/gen/%s has no runtime/orb/%s.orb" % (path.name, path.stem))
                results.append(False)
    n, total = sum(results), len(results)
    if n == total:
        out.say("Finished runtime_gen: %d/%d pass" % (n, total))
        return 0
    out.fail("Failed runtime_gen: %d/%d pass" % (n, total))
    return 1


def self_test_runtime_gen(compiler, cc):
    names = rg_modules()
    if not names:
        print("self-test FAILED: runtime/orb holds no module")
        return 1
    want, _ = rg_generate(compiler, names[0], cc)
    if want is None or not want.startswith(rg_header(names[0]).encode()):
        print("self-test FAILED: the generated file lacks its header")
        return 1
    if rg_generate(compiler, names[0], cc)[0] != want:
        print("self-test FAILED: two runs emitted different bytes")
        return 1
    if want + b" " == want:
        print("self-test FAILED: byte comparison is blind")
        return 1
    out.finish("runtime_gen self-test", 2, 2,
               extra="header present and output byte-deterministic")
    return 0


def cmd_runtime_gen(args) -> int:
    out.set_quiet(args.quiet)
    if not args.compiler:
        print("Failed runtime_gen: --compiler is required", file=sys.stderr)
        return 2
    compiler = os.path.abspath(args.compiler)
    cc = _common.resolve_cc(args.cc)
    if args.self_test:
        return self_test_runtime_gen(compiler, cc)
    return rg_check(compiler, cc, args.write)


# ---------------------------------------------------------------------------
# ---- from scripts/runtime_module_gate.py ----
#
# Runtime-module gate: `orbit build --runtime-module` makes a linkable object.
#
# A runtime module is an Orbit file with no `main` whose `export fn` functions
# keep their C names (docs/IR_SPEC.md). This gate builds tests/runtime_module/
# upper.orb to an object, links tests/runtime_module/main.orb against it through
# its `extern fn` declarations, runs the program and compares its stdout with
# tests/runtime_module/expected.txt.
#
#   --backend c       the object comes from the C backend.
#   --backend native  the object comes from R6 (`r6 build --object`); needs
#                     ORBIT_R6, else the run is SKIPPED with exit 77. Any host
#                     that is not Windows x86-64 is SKIPPED for the same reason:
#                     the compiler refuses --backend=native there.
#
# The program is always built by the C backend: R6 does not link foreign
# objects. arena.orb (an RtArena parameter) is built on both lanes. A file with a `main` must be refused by `--runtime-module`, which
# keeps the gate able to fail on the mode check as well as on the output.
#
# Usage:
#     python scripts/runtime_module_gate.py --compiler PATH [--cc CC]
#                                           [--backend c|native]
# ---------------------------------------------------------------------------

RTMOD_CASES = os.path.join(ROOT, "tests", "runtime_module")


def rtmod_run(argv, env):
    p = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True,
                       text=True, errors="replace", timeout=300)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def cmd_runtime_module(args) -> int:
    out.set_quiet(args.quiet)

    tool = "runtime_module_native" if args.backend == "native" else "runtime_module"
    r6 = os.environ.get("ORBIT_R6", "")
    if args.backend == "native":
        if os.name != "nt":
            # `orbit build --runtime-module --backend=native` is refused off
            # Windows x86-64 by the same guard the suites hit
            # (`hostIsWindows` in compiler/host/pipeline.orb), so an ORBIT_R6
            # here buys a failure, not a lane.
            out.say(f"Skipped {tool}: the native backend targets Windows x86-64 "
                    "only, so this host cannot run it. This is a skip, not a pass.")
            return SKIP_RC
        if not r6:
            out.say(f"Skipped {tool}: ORBIT_R6 is not set. Point it at r6.exe "
                    "with ir-protocol 3 to run this lane.")
            return SKIP_RC
        if not os.path.isfile(r6):
            out.fail(f"Failed {tool}: ORBIT_R6 names {r6}, which is not a file")
            return 1

    compiler = os.path.abspath(args.compiler)
    cc = _common.resolve_cc(args.cc)
    work = str(_common.scratch("orbit_rtmod_"))
    exe = os.path.join(work, "probe.exe" if os.name == "nt" else "probe")
    obj = os.path.join(work, "upper.o")
    header = os.path.join(RTMOD_CASES, "probe.h").replace("\\", "/")
    rel = lambda name: os.path.relpath(os.path.join(RTMOD_CASES, name), ROOT)

    env = _common.build_env(work, cc=cc)
    env["ORBIT_CCACHE"] = "0"
    results = []

    def check(name, ok, detail=""):
        results.append(ok)
        if ok:
            out.say(f"  ok   {name}")
        else:
            out.fail(f"  FAIL {name}\n    {detail}")

    obj_env = dict(env, ORBIT_BACKEND=args.backend)
    code, text = rtmod_run([compiler, "build", "--runtime-module", rel("upper.orb"),
                      "-o", obj, "--quiet"], obj_env)
    check("object builds", code == 0 and os.path.isfile(obj), text.strip())
    mem_obj = os.path.join(work, "memory.o")
    code, text = rtmod_run([compiler, "build", "--runtime-module", rel("memory.orb"),
                      "-o", mem_obj, "--quiet"], obj_env)
    check("memory object builds", code == 0 and os.path.isfile(mem_obj), text.strip())
    if results[-1] and results[-2]:
        main_env = dict(env, ORBIT_BACKEND="c", ORBIT_LINK_RUNTIME="0",
                        ORBIT_CCFLAGS_EXTRA='-include "%s" "%s" "%s"' % (
                            header, obj.replace("\\", "/"), mem_obj.replace("\\", "/")))
        code, text = rtmod_run([compiler, "build", rel("main.orb"), "-o", exe,
                          "--quiet"], main_env)
        check("program links the object", code == 0, text.strip())
        if results[-1]:
            p = subprocess.run([exe], cwd=work, capture_output=True, text=True,
                               errors="replace", timeout=60)
            with open(os.path.join(RTMOD_CASES, "expected.txt"), encoding="utf-8") as f:
                want = f.read()
            got = (p.stdout or "").replace("\r\n", "\n")
            check("program output", p.returncode == 0 and got == want,
                  f"exit {p.returncode}, stdout {got!r}, wanted {want!r}")

    arena_obj = os.path.join(work, "arena.o")
    code, text = rtmod_run([compiler, "build", "--runtime-module", rel("arena.orb"),
                      "-o", arena_obj, "--quiet"], obj_env)
    check("RtArena export builds", code == 0 and os.path.isfile(arena_obj),
          text.strip())

    code, text = rtmod_run([compiler, "check", "--runtime-module", rel("main.orb")], env)
    check("a file with main is refused", code != 0 and "no entry point" in text,
          f"exit {code}: {text.strip()}")

    n, total = sum(results), len(results)
    line = f"Finished {tool}: {n}/{total} pass"
    if n == total:
        out.say(line)
        return 0
    out.fail(line.replace("Finished", "Failed"))
    return 1


# ---------------------------------------------------------------------------
# ---- from scripts/fuzz_frontend.py ----
#
# Frontend fuzzer (R1.2): the compiler must never crash natively.
#
# Contract: for ANY input file, `orbit build` exits 0 (accepted), 1
# (clean diagnostics) or 2 (clean usage rejection). Any other exit code
# (native crash, access violation, stack overflow) is a bug; the
# offending input is saved.
#
# Mutations over the probe corpus: truncation, byte flips, deep nesting,
# quote injection, identifier soup, NUL bytes.
#
# Usage:
#     python scripts/fuzz_frontend.py --compiler PATH [--iterations N] [--seed S]
# Exit 0 iff no crash found.
# ---------------------------------------------------------------------------

# The same directory PARITY_PROBES names: the fuzz corpus is the parity probes.
FUZZ_PROBES = os.path.join(ROOT, "tests", "parity", "probes")
CRASH_DIR = os.path.join(ROOT, ".orbit", "fuzz_crashes")

DEEP_TOKENS = ["(", "{", "[", "match x { ", "if a { ", "while b { ", "\"", "$"]
# Valid-language splices: exercise parser combinations the byte-level
# mutations never produce (semantic mutation).
SEMANTIC_TOKENS = [
    "fn ", "return ", "route GET \"/p\" { }", "\"s\"", "val x = ", "var y = ",
    "match z { _ => {} }", "} else { ", "; ", "@auth ", "&T", "-> int ", "42 ",
    "3.14 ", "true", "NULL", "for i in [1] { ", "model M { f: int } ",
]


def mutate(src: bytes, rng: random.Random) -> bytes:
    kind = rng.randrange(7)
    if kind == 6:
        return mutate_semantic(src, rng)
    if kind == 0:  # truncate
        return src[: rng.randrange(0, max(1, len(src)))]
    if kind == 1:  # byte flips
        b = bytearray(src)
        for _ in range(rng.randrange(1, 8)):
            if b:
                b[rng.randrange(len(b))] = rng.randrange(256)
        return bytes(b)
    if kind == 2:  # deep nesting prefix
        tok = rng.choice(DEEP_TOKENS)
        depth = rng.randrange(50, 4000)
        return (tok * depth).encode() + src
    if kind == 3:  # quote injection
        return src + b'"' * rng.randrange(1, 200)
    if kind == 4:  # identifier soup
        junk = "".join(rng.choice("abcXYZ_09") for _ in range(rng.randrange(5, 60))).encode()
        i = rng.randrange(0, max(1, len(src)))
        return src[:i] + junk + src[i:]
    # 5: NUL / control bytes injection
    i = rng.randrange(0, max(1, len(src)))
    return src[:i] + bytes([0]) * rng.randrange(1, 20) + src[i:]
    # 6 handled above via early dispatch below


def mutate_semantic(src: bytes, rng: random.Random) -> bytes:
    text = src.decode("utf-8", errors="replace")
    tok = rng.choice(SEMANTIC_TOKENS)
    i = rng.randrange(0, max(1, len(text)))
    return (text[:i] + tok + text[i:]).encode("utf-8", errors="replace")


def cmd_fuzz_frontend(args) -> int:
    rng = random.Random(args.seed)
    corpus = []
    for f in sorted(os.listdir(FUZZ_PROBES)):
        if f.endswith(".orb"):
            corpus.append(open(os.path.join(FUZZ_PROBES, f), "rb").read())
    if not corpus:
        out.fail("Failed fuzz: empty corpus (no .orb probes found)")
        return 1

    work = tempfile.mkdtemp(prefix="orbit_fuzz_")
    os.makedirs(CRASH_DIR, exist_ok=True)
    # All 300 mutations are generated up front, sequentially: random.Random is
    # not thread-safe and the seed must replay the same corpus order. Only the
    # subprocess runs below go to the pool; coverage (iters) is unchanged.
    payloads = [mutate(rng.choice(corpus), rng) for _ in range(args.iterations)]

    def run_one(job):
        # Each iteration owns a TEMP subdir: the intermediate C has a fixed
        # name (orbit_selfhost_build.c in $TEMP), so a shared TEMP lets one
        # case's cc read another's half-written C. Returns (i, rc, src) for
        # ordered reporting below; only the main thread prints/saves crashes.
        i, src = job
        tmp = os.path.join(work, f"fuzz_{i}")
        os.makedirs(tmp, exist_ok=True)
        inp = os.path.join(tmp, f"case_{i}.orb")
        with open(inp, "wb") as fh:
            fh.write(src)
        env = dict(os.environ)
        noop_cc = "cmd /c exit 0" if os.name == "nt" else "true"
        env.update({"TEMP": tmp, "TMP": tmp, "ORBIT_CC": noop_cc, "CC": noop_cc})
        try:
            proc = subprocess.run(
                [args.compiler, "build", inp, "-o", os.path.join(tmp, f"out_{i}.bin")],
                cwd=ROOT, env=env, capture_output=True, timeout=120,
            )
            rc = proc.returncode
        except subprocess.TimeoutExpired:
            rc = -999
        return (i, rc, inp)

    crashes = 0
    clean_rejects = 0
    accepted = 0
    with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
        results = list(pool.map(run_one, enumerate(payloads)))
    for i, rc, inp in results:
        if rc == 0:
            accepted += 1
        elif rc == 1 or rc == 2:
            clean_rejects += 1
        else:
            crashes += 1
            safe = os.path.join(CRASH_DIR, f"crash_rc{rc}_case{i}.orb")
            shutil.copyfile(inp, safe)
            out.fail(f"Failed: crash rc={rc}, saved {safe}")
    out.say(f"Fuzzed {args.iterations} iterations: "
            f"accepted={accepted} clean-reject={clean_rejects} crashes={crashes}")
    out.say(f"work dir: {work}")
    out.finish("fuzz", args.iterations - crashes, args.iterations)
    return 1 if crashes else 0


# ---------------------------------------------------------------------------
# One entry point. Each subcommand declares exactly the flags its own script
# declared before the merge, with the same default and the same meaning, so a
# caller's command line changes only its prefix. `--quiet` is on the six that
# had it (`werror` and `fuzz_frontend` never accepted it), and `--self-test` is
# on the two that had one.
# ---------------------------------------------------------------------------
def _add_suite_args(sp):
    sp.add_argument("--compiler", required=True)
    sp.add_argument("--cc", default=None)
    sp.add_argument("--timeout", type=int, default=60)
    sp.add_argument("--backend", choices=("c", "native"), default="c",
                    help="code generator under test (native needs ORBIT_R6)")
    sp.add_argument("--dir", action="append", default=None,
                    help="suite directory to run (repeatable; default: tests/suite)")
    out.add_quiet(sp)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="The corpus gates: eight checkers over the committed "
                    "programs, one entry point.",
        epilog="Each subcommand takes the flags its own gate had before the "
               "merge; run `%(prog)s <gate> --help`.")
    gates = ap.add_subparsers(dest="gate", metavar="GATE", required=True)

    sp = gates.add_parser(
        "suite", help="build and run every suite program; the exit code is "
                      "the assertion")
    _add_suite_args(sp)

    sp = gates.add_parser(
        "negative", help="tests/negative/ programs must fail to compile with "
                         "the text their header pins",
        description="Require every tests/negative program to fail to compile")
    sp.add_argument("--compiler", default=os.path.join(ROOT, "orbit.exe"))
    sp.add_argument("--cc", default=os.environ.get("ORBIT_CC")
                               or os.environ.get("CC") or "cc",
                    help="C toolchain for the cases that pin a wrong answer")
    sp.add_argument("--no-build", action="store_true",
                    help="skip the wrong-value/cc-rejects assertions (no C toolchain)")
    sp.add_argument("--list", action="store_true",
                    help="print one line per declared case and exit")
    sp.add_argument("--verbose", action="store_true",
                    help="also print the diagnostic each case produced")
    out.add_quiet(sp)

    sp = gates.add_parser(
        "frontend", help="tests/frontend/ fixtures against their .tir goldens",
        description="Diff `orbit frontend` output against tests/frontend/expected/")
    sp.add_argument("--compiler", default=os.path.join(ROOT, "orbit.exe"))
    sp.add_argument("--cc", default="gcc",
                    help="C compiler for the fixtures that must be built and run")
    sp.add_argument("--list", action="store_true",
                    help="print the fixture -> expectation table and exit")
    sp.add_argument("--emit-only", action="store_true",
                    help="skip the fixtures that need building (no C toolchain)")
    out.add_quiet(sp)

    sp = gates.add_parser(
        "werror", help="the probe programs compiled and run under -Werror")
    sp.add_argument("--compiler", default=str(ROOT_PATH / "orbit.exe"))
    sp.add_argument("--cc", default="gcc")
    sp.add_argument("--list", action="store_true")
    sp.add_argument("--self-test", action="store_true")

    sp = gates.add_parser(
        "parity", help="tests/parity/probes/ against tests/parity/golden/",
        description="Self-host stability gate vs goldens")
    sp.add_argument("--compiler", required=True, help="fixed-point orbit compiler executable")
    sp.add_argument("--cc", default=None, help="C compiler passed via ORBIT_CC/CC")
    sp.add_argument("--update", action="store_true", help="regenerate goldens instead of comparing")
    sp.add_argument("--goldens", default=PARITY_GOLDENS, help="golden directory")
    sp.add_argument("--work", default=None, help="work directory (default: temp)")
    out.add_quiet(sp)

    sp = gates.add_parser(
        "runtime_gen", help="runtime/gen/*.c equal to what the compiler emits",
        description="Keep runtime/gen/<name>.c equal to what the compiler "
                    "emits for runtime/orb/<name>.orb.")
    _common.add_common_args(sp)
    sp.add_argument("--write", action="store_true")
    sp.add_argument("--self-test", action="store_true")
    out.add_quiet(sp)

    sp = gates.add_parser(
        "runtime_module", help="orbit build --runtime-module makes a "
                               "linkable object")
    sp.add_argument("--compiler", required=True)
    sp.add_argument("--cc", default=None)
    sp.add_argument("--backend", choices=("c", "native"), default="c")
    out.add_quiet(sp)

    sp = gates.add_parser(
        "fuzz_frontend", help="mutated probes; the compiler must not crash")
    sp.add_argument("--compiler", required=True)
    sp.add_argument("--iterations", type=int, default=300)
    sp.add_argument("--seed", type=int, default=1337)

    args = ap.parse_args()
    commands = {
        "suite": cmd_suite,
        "negative": cmd_negative,
        "frontend": cmd_frontend,
        "werror": cmd_werror,
        "parity": parity_guarded,
        "runtime_gen": cmd_runtime_gen,
        "runtime_module": cmd_runtime_module,
        "fuzz_frontend": cmd_fuzz_frontend,
    }
    return commands[args.gate](args)


if __name__ == "__main__":
    raise SystemExit(main())
