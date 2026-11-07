#!/usr/bin/env python3
"""The doctor and CLI family: four gates, one tool, four subcommands.

Usage:
    python scripts/doctor_gates.py doctor      --compiler FP [--update] [--scope-only]
    python scripts/doctor_gates.py cli-probe   --compiler FP [--work DIR] [--specimen]
    python scripts/doctor_gates.py snapshots   --compiler FP --cc CC [--work DIR] [--update] [--skip-probe]
    python scripts/doctor_gates.py dispatch
    every subcommand also takes --self-test

`doctor` is the exact-output gate for `orbit doctor` and, with --scope-only, the
clean-directories check; `cli-probe` is the CLI contract probe; `snapshots` holds
the rich and colour screens and the interrupt probe; `dispatch` checks the shape
of the compiler's one AST checker.

The four used to be four files: `scripts/doctor_gate.py`, `scripts/cli_probe.py`,
`scripts/ui_snapshots.py` and `scripts/dispatch_coverage.py`. Each is one section
below, moved as it was written, with its incident prose kept in the subcommand's
docstring. Every verdict line, exit code and flag is unchanged, because
`scripts/alive_check.py` matches the printed lines and the documents quote them;
the only thing that moved is the argv prefix.

Where a name collided across the four files it is prefixed with its tool, once,
in that section: the three root paths are `REPO` (doctor's, unchanged),
`CLI_ROOT`, `UI_ROOT` and `DISPATCH_ROOT`, and the four `main()`s are
`doctor_main`, `cli_probe_main`, `ui_main` and `dispatch_main`. Three moved names
also shadowed something this file imports, so each keeps a name of its own:
`strip_toolchain`'s parameter, `run_steps`' accumulator, `inject_repo_paths`'
list and `depth_map`'s result were all called `out`, which is orbit_output here,
and `child_env`'s temporary directory was called `scratch`, which is a
`_common` function here.
"""

import argparse
import difflib
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import orbit_output as out  # noqa: E402
from _common import build_env, resolve_cc, scratch  # noqa: E402


# ---- from scripts/doctor_gate.py ------------------------------------------
REPO = pathlib.Path(__file__).resolve().parent.parent
GOLDEN = REPO / "tests" / "doctor" / "golden"
# Color is forced off and the format is pinned: the golden is about the finding
# text, and on a terminal with color the escape codes would be part of it.
BASE_ARGS = ["--format", "text", "--color", "never"]


def read_args(case: pathlib.Path) -> list:
    """The flags for one case, as individual arguments.

    Split on whitespace: `args` is edited by hand in a review, and a whole line
    arriving as one argv entry would be an unknown flag, which is a confusing way
    to learn that a fixture has two flags on it.
    """
    args_file = case / "args"
    if not args_file.exists():
        return []
    return args_file.read_text().split()


def inject_repo_paths(args: list) -> list:
    """Point any path a case left implicit at the repository copy.

    Each case runs from a throwaway copy of its own directory, so a case that
    reads a file outside that directory -- ENGINEERING.md for the latency budget,
    which D033 enforces -- would find nothing. The fixtures must not depend on the
    runner's working directory, and the runner must not have to be run from the
    repo root to work.
    """
    # This local list was named `out`; `out` is orbit_output in this file, so a
    # local of that name would hide the printer in any line added later. It is
    # `kept` here and nowhere else changed.
    kept = []
    i = 0
    while i < len(args):
        if args[i] in ("--budget-doc",) and i + 1 < len(args):
            if args[i + 1] == "ENGINEERING.md":
                kept.append(args[i])
                kept.append(str(REPO / "ENGINEERING.md"))
                i = i + 2
                continue
        kept.append(args[i])
        i = i + 1
    return kept


def read_rc(case: pathlib.Path) -> int:
    rc_file = case / "expect_rc"
    if not rc_file.exists():
        return 1
    return int(rc_file.read_text().strip())


# Files that belong to the gate rather than to the scanned tree.
META = {"expected.txt", "args", "expect_rc", "expect_crlf", "expect_unchanged",
        "allow_stderr", "steps", "scan"}


def stage_case(case: pathlib.Path, work: str) -> None:
    """Copies the case's fixtures, and only its fixtures, into `work`."""
    for item in case.iterdir():
        if item.name in META:
            continue
        target = pathlib.Path(work) / item.name
        if item.is_dir():
            shutil.copytree(item, target)
        else:
            shutil.copy2(item, target)


def check_unchanged(case: pathlib.Path, work: str) -> str:
    """Returns a failure description, or "" when the staged tree is untouched."""
    for path in sorted(case.rglob("*.orb")):
        if path.name in META:
            continue
        staged = pathlib.Path(work) / path.relative_to(case)
        if not staged.exists():
            return f"{path.relative_to(case)}: disappeared"
        if staged.read_bytes() != path.read_bytes():
            return f"{path.relative_to(case)}: changed"
    return ""


def check_crlf(case: pathlib.Path, work: str) -> str:
    """Returns a failure description, or "" when the tree is all-CRLF."""
    for path in sorted(pathlib.Path(work).rglob("*.orb")):
        data = path.read_bytes()
        for i, byte in enumerate(data):
            if byte == 10 and (i == 0 or data[i - 1] != 13):
                rel = path.relative_to(work)
                return f"{rel}: lone LF at byte {i}; expected CRLF throughout"
    return ""


def run_steps(compiler: str, case: pathlib.Path, work: str, env: dict) -> str:
    """Runs the case's step list and returns the concatenated stdout."""
    # `stdout` rather than the old local name `out`, for the same reason as
    # inject_repo_paths: this file prints through orbit_output's `out`.
    stdout = ""
    for line in (case / "steps").read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        proc = subprocess.run(line.replace("{orbit}", compiler), shell=True,
                              capture_output=True, text=True, cwd=work, env=env)
        stdout += strip_toolchain(proc.stdout)
    return stdout


def cases_needing_c_step(case: pathlib.Path) -> bool:
    """True when this case runs --fix, and so verifies through the C step."""
    args = read_args(case)
    return "--fix" in args


def stage_compiler_with_runtime(compiler: str):
    """A compiler invocation that sits beside the runtime headers, or None.

    The emitted C includes socket_compat.h by bare name, and the C backend
    resolves that next to the COMPILER binary. CI builds the fixed point into
    RUNNER_TEMP, so it is nowhere near runtime/ and every --fix case cannot
    compile its own result.

    The earlier answer to that was to skip those cases and say so. That is what
    made this gate fail in CI: doctor_gate.py then printed no
    "Finished doctor_gate: N case(s)" line, alive_check.py saw no marker, and
    reported the gate DEAD. A skipped check reported as a passed check, caught
    by the tool that watches the other tools.

    So the cases run. This makes a directory holding a link to the binary and
    copies of the headers that the include names resolve to, and hands that
    path back. The binary is linked, not copied: it is tens of megabytes and the
    gate already rebuilds it upstream.
    """
    shim = pathlib.Path(tempfile.mkdtemp(prefix="doctor_gate_shim_"))
    try:
        link = shim / ("orbit_fixed_point" + (".exe" if os.name == "nt" else ""))
        try:
            link.symlink_to(compiler)
        except OSError:
            shutil.copy2(compiler, link)
        # compilerRuntimeDir (compiler/host/pipeline.orb:205) resolves the runtime as
        # <dir of argv[0]>/runtime and falls back to the relative "runtime", so
        # the headers have to sit in a `runtime` SUBDIRECTORY next to the binary.
        # Copying them flat next to it does not work, and does so quietly: the
        # compile fails on socket_compat.h with no hint that the directory name
        # was the difference.
        # The whole tree, not just the headers: the generated C includes
        # "socket_compat.h" AND "thread_pool.c", because the runtime's own
        # sources are compiled into the unit. Copying *.h alone gets one step
        # further and then fails on the first .c include, which looks like a
        # different problem.
        shutil.copytree(REPO / "runtime", shim / "runtime",
                        ignore=shutil.ignore_patterns("__pycache__", "*.o", "*.exe"))
        return str(link)
    except OSError as exc:
        shutil.rmtree(shim, ignore_errors=True)
        print(f"  shim failed: {exc}")
        return None


def scratch_env(parent_env=None):
    """A copy of the environment with TEMP/TMP pointing at a directory that exists.

    Both used to default to /tmp/scent, which is a directory this machine
    happens to have because of how the compiler was built here, and which does
    not exist on a CI runner. The failure mode was silent and misattributed: the
    compiler could not write its intermediate C file, so every --fix golden
    reported "the result does not compile", which reads as a broken golden rather
    than a missing directory, and the three goldens that need the C step failed
    with nothing in the message about the actual cause.

    Created here rather than assumed, and never reused, because a stale
    orbit_selfhost_build.c from a previous run is worse than no directory.
    """
    tmp = scratch()
    return build_env(tmp, parent=parent_env), tmp


# --------------------------------------------------------------------------
# --scope-only: doctor over the directories that must have no findings.
#
# The interesting thing this encodes is what it does NOT cover. A raw
# `orbit doctor <dir>` reports findings in directories that are supposed to be
# broken or that are advisory by design: D008 in fixtures that must not compile,
# the complexity and loop advisories in compiler/ and std/, and the route
# conflicts inside tests/doctor. docs/DOCTOR.md carries the measured table and
# the date it was taken.
#
# Baselining those would mean a file vouching for a state nobody wants. Naming
# the directories that must be clean says what we actually mean, and says it in
# one screen.
#
# examples/ is absent on purpose. It is a directory of independent services. It
# also used to be where a tree scan reported five services' GET /health as one
# program's conflicts; since 2026-11-01 D002 compares two routes only when one
# program's import closure reaches both files, so those services are no longer a
# finding at all. What remains there is per file. docs/DOCTOR.md documents this.
#
# This used to be scripts/doctor_scope_gate.py. It is a mode of this gate now
# because the two shared everything but the scan loop: the scratch environment,
# the compiler, and the finding-line parser. One file, one row.
# --------------------------------------------------------------------------

# Directories that must produce zero findings. Adding one here is a claim that
# the directory is clean, so it belongs in the same commit as whatever made it
# clean.
SCOPE_CLEAN_DIRS = ["compiler", "std", "tests/suite"]

# Codes that do NOT fail the scope gate even though the directories are clean.
#
# D015 is a performance observation, not a defect to fix. It fires on
# `joined = joined + tag` inside a loop, which is quadratic in the collection's
# length -- true, and correct in a five-element test whose whole purpose is to
# assert that the concatenation produces "red,blue,". A test that verifies a
# pattern cannot also be told to stop using it. It fired on real code too:
# std/string/string.orb had three quadratic loops, now fixed, and those fixes
# are worth more than the rule that found them.
#
# D017 joins it: a test whose main asserts fifteen separate behaviours IS a function
# of complexity 20, and telling it to extract sub-functions would be advice
# about the test, not the code.
#
# D021 joins them: tests/suite/call_arg_types.orb defines
# `fn takesFloat(f: float) -> int { return 1 }`. The parameter exists so the
# test can hand it a float and pin E1005 argument-type checking; the body
# deliberately ignores it, because a return value that depended on the argument
# would make `takesFloat(1.5)` and `takesFloat(2)` assert different things and
# the test would stop being about types. Removing the parameter would remove the
# coverage. The check is still true of that code, and it is not advisory
# anywhere else: compiler/ and std/ are clean under it.
#
# A code goes here only when "the code is right and the check is still true" is
# the normal case. That is not true of the other codes here, which is why this
# list has one entry.
# D021 is exempt from ONE file, not from the tree. It was listed in the plain set
# above first, which looked right and was not: the set is global, so exempting
# D021 for tests/suite/call_arg_types.orb also exempted it for compiler/, where
# it has eight true findings. A gate that cannot say "clean here, except there"
# will report clean everywhere the moment you exempt one file.
SCOPE_ADVISORY_BY_FILE = {
    "tests/suite/call_arg_types.orb": {"D021"},
    # This file pins shadowing semantics: it declares `val v` inside an
    # `if` and reads the outer one after, on purpose. D023 finds exactly
    # those two declarations and nothing else in the tree. The clobber bug
    # behind the pin is fixed (distinct C symbol per declaration); the
    # exemption stays because the pattern is still in the file by design.
    "tests/suite/scope_shadow_clobbers_outer.orb": {"D023"},
    # These construct a `result` on purpose -- one ok, one err -- and call both
    # without handling them, because building the values is what the test is for.
    # `make_failure()` really does discard its error, which is D027's exact claim;
    # the code is right for the file's purpose and the check is right about it.
    "tests/suite/result_values.orb": {"D027"},
    "tests/suite/result_try.orb": {"D027"},
}

# Codes exempt in every directory.
SCOPE_GLOBAL_ADVISORY_CODES = {"D015", "D017", "D018"}


def scope_advisory_codes_for(rel_path: str) -> set:
    """Codes that do not fail this specific file."""
    codes = set(SCOPE_GLOBAL_ADVISORY_CODES)
    codes |= SCOPE_ADVISORY_BY_FILE.get(rel_path, set())
    return codes


def scope_subdirs(rel: str) -> list:
    """The immediate subdirectories of `rel` that hold .orb source, name-ordered.

    This is the retry shape for a scan one process cannot finish: the default
    arena ceiling is three quarters of physical memory, so a 4 GB host aborts on
    `compiler` where a 16 GB one does not. What does not fit is the directory,
    not any one file in it, and `compiler/` keeps no .orb at its own top, so its
    children cover everything the parent scan would have read.
    """
    units = []
    base = REPO / rel
    for child in sorted(base.iterdir()):
        if child.is_dir() and any(child.rglob("*.orb")):
            units.append(f"{rel}/{child.name}")
    return units


def scope_scan(compiler: str, env: dict, target: str):
    """Doctor over one target, returning (usable, findings, advisory, why).

    `usable` is False when the process died instead of reporting. A doctor that
    was OOM-killed prints nothing, and reading that as clean is the worst
    failure this gate can have; doctor exits 1 when it merely has findings, so
    only a code outside {0, 1} means the run cannot be trusted.
    """
    proc = subprocess.run(
        [compiler, "doctor", target, "--color", "never"],
        capture_output=True, text=True, cwd=REPO, env=env,
    )
    if proc.returncode not in (0, 1):
        how = "was killed by a signal" if proc.returncode < 0 else "exited"
        last = proc.stderr.strip().splitlines()
        return False, [], 0, how + f" ({proc.returncode})" + (
            ": " + last[-1] if last else "")

    # A finding line reads "<file>:<line> <severity> [Dnnn] ...", with the path
    # RELATIVE TO THE SCANNED TARGET. Filtering findings on the directory prefix
    # instead matches nothing at all, which is how this gate could have passed
    # forever while checking nothing; the reliable signal is the shape: a colon,
    # digits, then a severity word.
    findings = []
    advisory = 0
    for line in proc.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        loc, severity = parts[0], parts[1]
        if severity not in ("error", "warning"):
            continue
        _, _, lineno = loc.rpartition(":")
        if not (lineno.isdigit() and "[D" in parts[2]):
            continue
        code = parts[2].split("[", 1)[1].split("]", 1)[0]
        if code in scope_advisory_codes_for(f"{target}/{loc.split(':', 1)[0]}"):
            advisory += 1
            continue
        findings.append(line)
    return True, findings, advisory, ""


def run_scope(compiler: str) -> int:
    """Doctor over the clean dirs; fail on any non-advisory finding."""
    env, _scratch = scratch_env()

    failures = []
    for d in SCOPE_CLEAN_DIRS:
        target = REPO / d
        if not target.is_dir():
            print(f"doctor_gate --scope-only: {d} does not exist; the list is stale")
            return 1
        usable, findings, advisory, why = scope_scan(compiler, env, d)
        if not usable:
            # The scan did not finish, so ask for less at a time instead of
            # asking the machine for more memory: one process per subdirectory
            # keeps the peak under a default ceiling on a small host.
            units = scope_subdirs(d)
            if not units:
                print(f"FAIL {d}: doctor {why}, and there is no subdirectory "
                      f"to retry, so its output cannot be read as 'clean'")
                failures.append(d)
                continue
            print(f"note: {d}: doctor {why}; retrying as "
                  f"{len(units)} subdirectories")
            findings, advisory = [], 0
            broken = None
            for unit in units:
                u_ok, u_f, u_a, u_why = scope_scan(compiler, env, unit)
                if not u_ok:
                    broken = unit
                    print(f"FAIL {d}: {unit} doctor {u_why}, so its output "
                          f"cannot be read as 'clean'")
                    break
                findings.extend(u_f)
                advisory += u_a
            if broken is not None:
                failures.append(d)
                continue
        if advisory:
            print(f"note: {d}: {advisory} advisory finding(s) not counted")

        if findings:
            print(f"FAIL {d}: {len(findings)} finding(s) in a directory that must be clean")
            for line in findings:
                print("  " + line)
            failures.append(d)

    if failures:
        print(f"doctor_gate --scope-only: {len(failures)} of {len(SCOPE_CLEAN_DIRS)} directory(ies) not clean")
        return 1
    print(f"Finished doctor_scope: {len(SCOPE_CLEAN_DIRS)} directories clean ({', '.join(SCOPE_CLEAN_DIRS)}).")
    return 0


def compiler_can_reach_runtime(compiler: str) -> bool:
    """Whether the C step can work for a compiler at this path.

    A case that runs --fix verifies its result by compiling it, and the emitted C
    includes "socket_compat.h" by bare name. compilerRuntimeDir resolves that
    against <dir of argv[0]>/runtime, so a compiler outside the repository cannot
    compile anything and every --fix golden fails with a confusing error about
    the user's file.

    Checked here, and reported as a broken environment rather than as 6 failing
    goldens: the two are very different things and only one of them is a bug in
    the tree.

    The predicate used to be `startswith(repo + os.sep)`, which was wrong and
    cost a confusing failure. It claims that ANY compiler inside the repository
    can reach the runtime, which is true of a binary at the repository root --
    `runtime/` sits beside it -- and false of everything deeper in the tree. A
    compiler at `.orbit/tmp/orbit-fp-...` is inside the repo, bindir is
    `<repo>/.orbit/tmp`, no runtime is beside it, and the lookup falls through to
    the relative "runtime", which for a --fix golden means the throwaway staged
    copy. Three goldens then failed with "the result does not compile", a message
    that says nothing about the cause, and the real cause was one directory level
    of this function. The predicate is now: a runtime beside the binary, or the
    binary at the repository root itself.
    """
    bindir = os.path.dirname(os.path.abspath(compiler))
    if os.path.isdir(os.path.join(bindir, "runtime")):
        return True
    return os.path.abspath(bindir) == str(REPO)


def run_case(compiler: str, case: pathlib.Path, env: dict) -> tuple:
    if (case / "steps").exists():
        # A steps case names its own commands; it does not need a scan target,
        # and the exit code it asserts is the last command's.
        with tempfile.TemporaryDirectory(prefix="doctor_gate_") as work:
            stage_case(case, work)
            # The cache is opt-in since 2026-11-06, and the case that tests it
            # has to ask: this directory is per case and thrown away with it.
            steps_env = dict(env)
            steps_env["ORBIT_DOCTOR_CACHE"] = os.path.join(work, "doctor_cache")
            combined = run_steps(compiler, case, work, steps_env)
            if (case / "expect_crlf").exists():
                bad = check_crlf(case, work)
                if bad:
                    return None, f"{case.name}: {bad}"
            if (case / "expect_unchanged").exists():
                bad = check_unchanged(case, work)
                if bad:
                    return None, f"{case.name}: steps changed the tree: {bad}"
        proc = subprocess.CompletedProcess(["steps"], 0, combined, "")
        return proc, None
    scan_file = case / "scan"
    if not scan_file.exists():
        return None, f"{case.name}: missing scan"
    rel = scan_file.read_text().strip()
    if not rel:
        return None, f"{case.name}: empty scan"
    cmd = [compiler, "doctor", rel] + BASE_ARGS + inject_repo_paths(read_args(case))
    with tempfile.TemporaryDirectory(prefix="doctor_gate_") as work:
        stage_case(case, work)
        # cwd is the staged copy so the paths doctor prints -- and therefore the
        # goldens -- stay relative and identical on every machine.
        proc = subprocess.run(cmd, capture_output=True, text=True, cwd=work, env=env)
        proc.stdout = strip_toolchain(proc.stdout)
        if (case / "expect_crlf").exists():
            bad = check_crlf(case, work)
            if bad:
                return None, f"{case.name}: {bad}"
        if (case / "expect_unchanged").exists():
            bad = check_unchanged(case, work)
            if bad:
                return None, f"{case.name}: --dry-run changed the tree: {bad}"
    return proc, None


def strip_toolchain(text: str) -> str:
    """Drops the compiler probe line.

    It names the host C compiler and its version, so it is machine-specific by
    construction; a golden containing one would fail on every machine but this
    one. It is a probe, not a finding, and the gate is about findings.
    """
    return "".join(
        line + "\n"
        for line in text.splitlines()
        if not line.startswith("toolchain:")
    )


def doctor_main(args, ap) -> int:
    """Exact-output gate for `orbit doctor`.

    The point of this gate is that a check which changes how it phrases itself is
    a BREAKING change, not a cosmetic one. `cli-probe` proves the command runs and
    exits right; this proves the words it prints are the words we agreed to print,
    character for character. A new check can only be added here by adding its
    golden, which is the moment someone has to decide what it is supposed to say.

    Each case in tests/doctor/golden/ is a directory holding:

      scan          the path, relative to the case, that doctor is pointed at
      *.orb         the fixtures that scan refers to
      expected.txt  the exact stdout of `doctor <scan> --format text --color never`
      args          optional extra flags, one per line
      expect_rc     optional expected exit code (default 1: the case has findings)
      expect_crlf   optional; asserts every LF in the fixtures is part of a CRLF
      expect_unchanged  optional; asserts --dry-run really wrote nothing
      allow_stderr  optional; permits stderr, for cases whose finding IS a
                    compiler diagnostic printed by the compiler
      steps         optional; shell commands run INSTEAD of one doctor run, one per
                    line, with {orbit} replaced by the compiler. expected.txt is
                    their concatenated stdout. This is the only way to test a cache:
                    a cache bug is by definition invisible to a single run, because
                    the wrong answer is the one already on disk.

    Each case runs against a throwaway COPY of its own directory. That is what lets
    a case pass --fix or --dry-run and still mean the same thing tomorrow: the
    fixtures in git are the pristine "before" state, and a fix case that mutated
    them would silently become a no-op case the second time it ran.

    `--update` rewrites every expected.txt from a live run. Deliberately: it is the
    only way a golden changes, and it must be reviewed as a diff.

    `--scope-only` is the second gate in this section: doctor over the directories
    that must have no findings, described with the SCOPE constants above.
    """
    if not args.compiler:
        # Same wording argparse used when the flag was declared `required=True`,
        # which it cannot be here: `--self-test` runs this subcommand with no
        # compiler at all.
        ap.error("the following arguments are required: --compiler")
    compiler = os.path.abspath(args.compiler)
    if not os.path.exists(compiler):
        print(f"doctor_gate: no compiler at {compiler}")
        return 1

    if args.scope_only:
        return run_scope(compiler)

    if not GOLDEN.is_dir():
        print(f"doctor_gate: no goldens at {GOLDEN}")
        return 1

    cases = sorted(p for p in GOLDEN.iterdir() if p.is_dir())
    if not cases:
        print("doctor_gate: no cases found")
        return 1

    needs_c = [c for c in cases if cases_needing_c_step(c)]
    if needs_c and not compiler_can_reach_runtime(compiler):
        compiler = stage_compiler_with_runtime(compiler)
        if compiler is None:
            print(f"doctor_gate: {len(needs_c)} case(s) verify through the C step and "
                  f"{args.compiler} cannot resolve the runtime headers, and the shim "
                  f"could not be built either.")
            return 1

    failures = []

    def run_one(case):
        # Each case owns a TEMP dir: run_case already stages its own CWD
        # copy, but --fix cases verify through the C step and every build
        # writes orbit_selfhost_build.c to $TEMP, so a shared TEMP lets one
        # case's cc read another's half-written C. Returns (case, proc, err)
        # for ordered reporting below; only the main thread prints.
        env, _scratch = scratch_env()
        proc, err = run_case(compiler, case, env)
        return (case, proc, err)

    with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
        results = list(pool.map(run_one, cases))
    for case, proc, err in results:
        if err:
            failures.append((case.name, err, ""))
            continue
        expected = (case / "expected.txt")
        if args.update:
            expected.write_text(proc.stdout)
            print(f"updated {expected.relative_to(REPO)}")
            continue
        if not expected.exists():
            failures.append((case.name, f"no expected.txt (run with --update)", ""))
            continue
        want = expected.read_text()
        if proc.stdout != want:
            failures.append((case.name, want, proc.stdout))
        if proc.returncode != read_rc(case):
            failures.append(
                (case.name, f"exit {read_rc(case)}", f"exit {proc.returncode}")
            )
        # A D008 case points doctor at a file that does not compile, and the
        # compiler prints its own diagnostic while doctor is looking. That
        # output is the evidence behind the finding, not noise from doctor, so
        # such a case opts in with allow_stderr.
        if proc.stderr.strip() and not (case / "allow_stderr").exists():
            failures.append((case.name, "no stderr", proc.stderr.strip()[:400]))

    if args.update:
        print(f"doctor_gate: updated {len(cases)} golden(s)")
        return 0

    for name, want, got in failures:
        print(f"FAIL {name}")
        # Say WHICH assertion failed and where the two texts diverge, before
        # dumping either. A CI log that shows 1200 characters of "expected" and
        # then truncates answers no question; the first differing line answers
        # it. When the assertion is not a text comparison ("exit 1", "no stderr")
        # there is nothing to point at and the dump stands on its own.
        if want and got and "\n" in want and "\n" in got:
            wl, gl = want.splitlines(), got.splitlines()
            for n in range(max(len(wl), len(gl))):
                a = wl[n] if n < len(wl) else "<missing>"
                b = gl[n] if n < len(gl) else "<missing>"
                if a != b:
                    print(f"  first difference at output line {n + 1}:")
                    print(f"    expected: {a[:200]}")
                    print(f"    actual:   {b[:200]}")
                    break
        print("  expected: " + want.replace("\n", "\n  ")[:1200])
        print("  actual:   " + got.replace("\n", "\n  ")[:1200])
    if failures:
        print(f"doctor_gate: {len(failures)} failure(s) in {len(cases)} case(s)")
        return 1
    print(f"Finished doctor_gate: {len(cases)} case(s) matched their goldens.")
    return 0


# ---- from scripts/cli_probe.py --------------------------------------------
CLI_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SPECIMEN = """\
--- suite -----------------------------------------------
Testing arith ... exit 0 as expected
Failed notes_write: got exit 1, want 0
Finished suite: 20/21 pass

--- parity ----------------------------------------------
Checking r1_route_only ... match (C)
Failed r12_route_err: mismatch (line 2: expected 'kind=DIAG' got 'kind=C')
Finished parity: 30/31 match goldens

--- cli-probe -------------------------------------------
Probing build-quiet ... ok
Failed check-missing: rc=0 (want 1)
Finished cli-probe: 34/35 pass

--- verify / bootstrap ----------------------------------
Running build seed from canonical C ...
Verified seed C fixed point (seed C == canonical C) ... ok
Finished bootstrap: converged (matches canonical).

--- load / gates ----------------------------------------
Loading 127.0.0.1:4102 /health x2 (source ips: 0) ...
  completed=200 ok_2xx=200 transport_errors=0 error_rate=0.000% elapsed=20.03s
Phase B passed: ok=5 denied=20 retry_after='1' elapsed=0.21s
Finished kynx gate: PASS

--- orbit build, C step fails ---------------------------
orbit build: couldn't finish the C step - this one is on me, not your code.
  Your program translated cleanly; the C compiler rejected my output:
  <build>:35703:12: error: assignment to integer from pointer without a cast
  ... 34 more lines (full log: <tmp>/orbit_build.cc.log)
  Tip: run `orbit check app.orb` first - if that passes, file an issue
  with the .orb file and I'll read it.
"""

# Stand-ins for r6. The native backend must refuse both before it hands
# either a program: one never answers `--version` (a stale r6 waits for
# input), the other answers with an IR protocol this compiler does not emit.
# Each host runs a script it can execute: cmd.exe runs a .cmd, a POSIX kernel
# runs a shebang, so setup_dir makes the POSIX pair executable.
R6_SILENT = "r6_silent.cmd" if os.name == "nt" else "r6_silent.sh"
R6_OTHER = "r6_other.cmd" if os.name == "nt" else "r6_other.sh"

SETUP = {
    "files/case.orb": "fn main() -> int {\nreturn 0\n}\n",
    "files/clean.orb": "fn main() -> int {\n    return 0\n}\n",
    "files/ws.orb": "fn main() -> int {\n    return 0   \n}\n",
    "cleandir/clean.orb": "fn main() -> int {\n    return 0\n}\n",
    "tiny.orb": "fn main() -> int {\n    return 0\n}\n",
    # A program that reads its own stdin. `orbit run` hands the child the
    # parent's stream, so the probe can feed a line and see it printed: this is
    # the gate on the two reads a language server is built from.
    "stdin_echo.orb": "extern fn orbit_stdin_read_line() -> string\n\nfn main() -> int {\n    val line = orbit_stdin_read_line()\n    print(line)\n    return 0\n}\n",
    # `orbit run` with a path that names a directory: cmd.exe reads a quoted
    # forward-slash path as a command named after its first segment, so the
    # child never started and the error named the directory instead.
    "sub/tiny.orb": "fn main() -> int {\n    print(\"ran from a subdir\")\n    return 0\n}\n",
    # Resolved through ORBIT_STD_DIR: the compiler binary lives outside the
    # tree and the working directory carries no std/.
    "stdimport/probe.orb": "import \"std/string/string.orb\"\n\nfn main() -> int {\n    return 0\n}\n",
    # Two independent services in one directory: the same route in each is two
    # programs' routes, not one program's duplicate.
    "services/health_a.orb": "route GET \"/health\" {\n    return ok { status: \"a\" }\n}\n\nfn main() -> int {\n    return 0\n}\n",
    "services/health_b.orb": "route GET \"/health\" {\n    return ok { status: \"b\" }\n}\n\nfn main() -> int {\n    return 0\n}\n",
    # One program across two files: the import edge makes the duplicate real.
    "mergesvc/lib.orb": "route GET \"/items\" {\n    return ok { status: \"lib\" }\n}\n",
    "mergesvc/app.orb": "import \"lib.orb\"\n\nroute GET \"/items\" {\n    return ok { status: \"app\" }\n}\n\nfn main() -> int {\n    return 0\n}\n",
    # `orbit migrate` runs the migration block without serving.
    "mig/app.orb": "migrations \"CREATE TABLE IF NOT EXISTS mig_probe (x INTEGER)\"\nmigrations down \"DROP TABLE IF EXISTS mig_probe\"\n\nfn main() -> int {\n    return 0\n}\n",
    # A dot-directory is tool state, not source: the unparseable file inside
    # .orbit must not be scanned, which is what keeps `doctor .` finite.
    "state/ok.orb": "fn main() -> int {\n    return 0\n}\n",
    # A broken imported file: the refusal has to name the file that does not
    # parse, not the name the importer asked for. The frontend reads imports to
    # type calls across them, so a swallowed parse error used to arrive as
    # `unknown identifier helper` one file away from its cause.
    "attrbroken/lib.orb": "fn helper() -> int {\n    return 1 +\n}\n",
    "attrbroken/use.orb": "import \"lib.orb\"\n\nfn main() -> int {\n    return helper()\n}\n",
    # A directory git already ignores is not source: doctor must not scan it.
    "skiproot/.gitignore": "generated/\n",
    "skiproot/ok.orb": "fn main() -> int {\n    return 0\n}\n",
    "skiproot/generated/bad.orb": "this is not orbit source\n",
    # The positive control: an un-ignored broken file is still reported.
    "keeproot/.gitignore": "elsewhere/\n",
    "keeproot/broken.orb": "this is not orbit source\n",
    # A .gitignore inside a subdirectory applies to that subtree, which is how a
    # real tree names its scratch. `nestdeep` is the same layout with the nested
    # file missing, so a scanner that reads only the root's .gitignore passes the
    # control and fails the case -- the pair is what makes the fixture prove
    # something.
    "nestroot/.gitignore": "elsewhere/\n",
    "nestroot/sub/.gitignore": "hidden/\n",
    "nestroot/sub/kept.orb": "fn main() -> int {\n    return 0\n}\n",
    "nestroot/sub/hidden/bad.orb": "this is not orbit source\n",
    "nestdeep/.gitignore": "elsewhere/\n",
    "nestdeep/sub/kept.orb": "fn main() -> int {\n    return 0\n}\n",
    "nestdeep/sub/hidden/bad.orb": "this is not orbit source\n",
    # A leading slash anchors a rule to the directory that wrote it: `/only/`
    # hides the root's `only/`, and the directory of that name below `keep/` is
    # still scanned. Reading `/only/` as `only/` at every depth hides both and
    # the scan answers "no findings", which is what this case fails on.
    "anchroot/.gitignore": "/only/\n",
    "anchroot/only/bad.orb": "this is not orbit source\n",
    "anchroot/keep/only/bad.orb": "this is not orbit source\n",
    "state/.orbit/generated.orb": "this is not orbit source\n",
    # Two functions nothing reaches: `orphan` is never called and `orphan_helper`
    # is called only by it. `build --verbose` counts them as dropped.
    "prune/orphans.orb": "fn leaf() -> int {\n    return 1\n}\n\nfn used() -> int {\n    return leaf()\n}\n\nfn orphan() -> int {\n    return 2\n}\n\nfn orphan_helper() -> int {\n    return orphan()\n}\n\nfn main() -> int {\n    return used()\n}\n",
    # `inc` is reached only through a function value, which is not a call.
    "prune/fn_value.orb": "fn inc(x: int) -> int {\n    return x + 1\n}\n\nfn main() -> int {\n    val f = inc\n    return f(1)\n}\n",
    # Unparseable on purpose: `orbit fmt` must refuse it and leave it alone.
    "fmt/broken.orb": "fn main() -> int {\n    val =\n}\n",
    # Parseable but badly formatted: `orbit fmt` must rewrite it.
    "fmt/messy.orb": "fn main( )->int{return 0}\n",
    # Whitespace only: no tokens, so normalising to empty is correct.
    "fmt/blank.orb": "   \n\n  \n",
    # A program that fails `orbit check`. Diagnostics go to stderr and never to
    # stdout, so a script reading stdout sees only real output and artifacts
    # (see stderr-diagnostics).
    "reserved/read.orb": "fn main() -> int {\n    return missing_name\n}\n",
    # A function named after a C library symbol. The backend emits every user
    # symbol under the `o_` prefix, so this builds like any other program.
    "reserved/safe.orb": "fn read(text: string) -> int {\n    return text.len()\n}\n\nfn main() -> int {\n    return read(\"hi\")\n}\n",
    # The runtime's `orbit_` prefix and a C type name as a model: both are
    # ordinary user names now.
    "reserved/prefix.orb": "fn orbit_my_helper(x: int) -> int {\n    return x + 1\n}\n\nfn main() -> int {\n    return orbit_my_helper(1)\n}\n",
    "reserved/model_c_type.orb": "model FILE {\n    x: int\n}\n\nfn main() -> int {\n    val f = FILE(1)\n    return f.x\n}\n",
    # `extern fn` is how the compiler itself reaches the runtime, so the
    # prefix reservation must not fire on declarations. Check-only: there is
    # no such C symbol to link against.
    "reserved/extern_prefix.orb": "extern fn orbit_absent_symbol(x: int) -> int\n\nfn main() -> int {\n    return 0\n}\n",
}

if os.name == "nt":
    SETUP[R6_SILENT] = "@echo off\r\nping -n 40 127.0.0.1 >nul\r\n"
    SETUP[R6_OTHER] = "@echo off\r\necho r6 9.9.9 ir-protocol 99\r\n"
else:
    SETUP[R6_SILENT] = "#!/bin/sh\nsleep 40\n"
    SETUP[R6_OTHER] = "#!/bin/sh\necho 'r6 9.9.9 ir-protocol 99'\n"

CASES = [
    # (name, argv, exp_rc, stream, needle, absent)
    # stream: "out" (stdout), "err" (stderr), "any"; needle "" skips match.
    # absent: text that must NOT appear on either stream ("" skips), or scoped
    #   to one stream as "out:<text>" / "err:<text>".
    ("help", ["--help"], 0, "out", "Usage:", ""),
    # The native backend refuses an r6 before it hands it a program, on either
    # host: these two cases are the same contract with a host-native stand-in.
    ("native-r6-no-answer", ["build", "tiny.orb", "-o", "t.exe", "--backend=native"], 1, "err",
     "did not answer `--version`", "",
     {"ORBIT_R6": "./" + R6_SILENT}),
    ("native-r6-wrong-protocol", ["build", "tiny.orb", "-o", "t.exe", "--backend=native"], 1, "err",
     "ir-protocol 99", "",
     {"ORBIT_R6": "./" + R6_OTHER}),
    # The stdin contract: `orbit run` inherits stdio and the runtime reads a
    # line from it. The needle is the line the probe writes into the pipe.
    ("run-stdin", ["run", "stdin_echo.orb"], 0, "out", "hello from the pipe", "", None,
     "hello from the pipe\n"),
    ("help-short", ["-h"], 0, "out", "Usage:", ""),
    ("version", ["--version"], 0, "out", "orbit 0.1.0", ""),
    ("unknown-cmd", ["frobnicate"], 2, "err", "Usage:", ""),
    ("unknown-flag", ["--badflag"], 2, "err", "Usage:", ""),
    ("build-noarg", ["build"], 2, "err", "Usage:", ""),
    ("build-missing", ["build", "nope.orb"], 1, "err", "orbit build:", ""),
    ("build-missing-plain", ["nope.orb"], 1, "err", "orbit build:", ""),
    ("build-quiet", ["build", "--quiet", "tiny.orb", "-o", "tq.exe"], 0, "out", "", "wrote "),
    # The runtime headers are found through ORBIT_RUNTIME_DIR when neither the
    # compiler's directory nor the working directory carries them. A named
    # directory with no headers is refused before cc runs, so the message names
    # the variable instead of a missing C include.
    ("runtime-dir-named", ["build", "--backend=c", "tiny.orb", "-o", "rt.exe"], 0, "out", "", "",
     {"ORBIT_RUNTIME_DIR": os.path.join(CLI_ROOT, "runtime")}),
    ("runtime-dir-missing", ["build", "--backend=c", "tiny.orb", "-o", "rm.exe"], 1, "err",
     "holds no runtime headers", "this one is on me",
     {"ORBIT_RUNTIME_DIR": "missing_runtime"}),
    ("build-verbose", ["build", "--verbose", "tiny.orb", "-o", "tv.exe"], 0, "out", "wrote ", ""),
    ("build-prune-drops-orphans", ["build", "--verbose", "prune/orphans.orb", "-o", "po.exe"], 0, "out", "prune: 2 unreachable functions dropped", ""),
    ("build-prune-keeps-called", ["build", "--verbose", "tiny.orb", "-o", "pt.exe"], 0, "out", "prune: 0 unreachable functions dropped", ""),
    ("build-prune-keeps-fn-value", ["build", "--verbose", "prune/fn_value.orb", "-o", "pv.exe"], 0, "out", "prune: 0 unreachable functions dropped", ""),
    ("check-noarg", ["check"], 2, "err", "Usage:", ""),
    ("check-missing", ["check", "nope.orb"], 1, "err", "orbit check:", ""),
    ("check-quiet", ["check", "--quiet", "tiny.orb"], 0, "out", "", "Checked"),
    ("check-std-dir-named", ["check", "stdimport/probe.orb"], 0, "out", "no errors", "",
     {"ORBIT_STD_DIR": CLI_ROOT}),
    ("check-verbose", ["check", "--verbose", "tiny.orb"], 0, "out", "check tiny.orb", ""),
    ("run-noarg", ["run"], 2, "err", "Usage:", ""),
    ("run-missing", ["run", "nope.orb"], 1, "err", "orbit run:", ""),
    ("run-subdir", ["run", "--backend=c", "sub/tiny.orb"], 0, "out", "ran from a subdir", ""),
    ("migrate-noarg", ["migrate"], 2, "err", "Usage:", ""),
    ("migrate-help", ["migrate", "--help"], 0, "out", "Usage:", ""),
    ("migrate-missing", ["migrate", "nope.orb"], 1, "err", "orbit migrate:", ""),
    # The child links SQLite's import library, and the DLL lives in the vendor
    # directory; PATH carries it so the case does not depend on where the
    # compiler under test sits.
    ("migrate-applies", ["migrate", "mig/app.orb"], 0, "out", "migrations applied", "",
     {"PATH": os.path.join(CLI_ROOT, "runtime", "vendor", "win-x64") + os.pathsep + os.environ.get("PATH", "")}),
    # `print` lowers in the TIR path now (tests/frontend/print_pipeline.orb),
    # so the command emits TIR for a program that uses it.
    ("frontend-print", ["frontend", "sub/tiny.orb", "-o", "tiny.tir"], 0, "out", "",
     "diagnostics contain errors"),
    ("fmt-noarg", ["fmt"], 2, "err", "Usage:", ""),
    ("fmt-help", ["fmt", "--help"], 0, "out", "Usage:", ""),
    ("fmt-missing", ["fmt", "nope.orb"], 1, "err", "orbit fmt:", ""),
    ("fmt-quiet", ["fmt", "--quiet", "files/case.orb"], 0, "out", "", "Formatted"),
    ("fmt-check-verbose", ["fmt", "--check", "files", "--verbose"], 1, "out", "scanned", ""),
    ("fmt-check-quiet", ["fmt", "--check", "files", "--quiet"], 1, "out", "", "files/ws.orb"),
    ("doctor-help", ["doctor", "--help"], 0, "out", "Usage:", ""),
    ("doctor-badflag", ["doctor", "--bogus"], 2, "err", "Usage:", ""),
    ("doctor-quiet-clean", ["doctor", "--quiet", "cleandir"], 0, "out", "", "no findings"),
    # D002 is scoped to a program: two independent services may both serve
    # GET /health, and one program that imports a route file may not.
    ("doctor-separate-programs", ["doctor", "--color", "never", "services"], 0, "out", "", "D002"),
    ("doctor-one-program", ["doctor", "--color", "never", "mergesvc"], 1, "out", "duplicate route GET /items", ""),
    ("doctor-skips-tool-state", ["doctor", "--color", "never", "state"], 0, "out", "no findings", "D008"),
    ("doctor-skips-gitignored", ["doctor", "--color", "never", "skiproot"], 0, "out", "no findings", "D008"),
    ("doctor-reads-unignored", ["doctor", "--color", "never", "keeproot"], 1, "out", "D008", ""),
    ("doctor-nested-gitignore", ["doctor", "--color", "never", "nestroot"], 0, "out", "no findings", "D008"),
    ("doctor-nested-unignored", ["doctor", "--color", "never", "nestdeep"], 1, "out", "D008", ""),
    ("doctor-anchor-not-deep", ["doctor", "--color", "never", "anchroot"], 1, "out", "D008", ""),
    ("doctor-verbose", ["doctor", "--verbose", "cleandir"], 0, "out", "scanned", ""),
    ("doctor-json", ["doctor", "--format", "json", "files"], 1, "out", '"code"', ""),
    ("doctor-format-bad", ["doctor", "--format", "xml", "files"], 2, "err", "Usage:", ""),
    ("doctor-color-always", ["doctor", "--color", "always", "files"], 1, "out", "\x1b[", ""),
    ("doctor-color-never", ["doctor", "--color", "never", "files"], 1, "out", "warning [D006]", "\x1b["),
    ("doctor-color-bad", ["doctor", "--color", "maybe", "files"], 2, "err", "Usage:", ""),
    ("build-color-always", ["build", "--color", "always", "tiny.orb", "-o", "tc.exe"], 0, "out", "\x1b[", ""),
    ("build-color-never", ["build", "--color", "never", "tiny.orb", "-o", "tn.exe"], 0, "out", "wrote ", "\x1b["),
    ("check-color-always", ["check", "--color", "always", "reserved/read.orb"], 1, "err", "\x1b[31m", ""),
    ("check-color-never", ["check", "--color", "never", "reserved/read.orb"], 1, "err", "missing_name", "\x1b["),
    ("cluster-noarg", ["cluster"], 2, "err", "Usage:", ""),
    ("cluster-help", ["cluster", "--help"], 0, "out", "Usage:", ""),
    ("cluster-bogus", ["cluster", "bogus"], 2, "err", "unknown command", ""),
    ("cluster-status-nostate", ["cluster", "status"], 1, "out", "no state file", ""),
    ("frontend-import-error-names-the-file", ["frontend", "attrbroken/use.orb"], 1, "err",
     "imported file", "unknown identifier helper"),
    ("frontend-noarg", ["frontend"], 2, "err", "Usage:", ""),
    # A function named after a C library symbol is an ordinary name: the
    # backend emits it as `o_read`, so neither check nor build refuses it.
    ("c-name-user-fn-check", ["check", "reserved/safe.orb"], 0, "out",
     "no errors", "Semantic error"),
    ("c-name-user-fn-builds", ["build", "--quiet", "reserved/safe.orb", "-o", "s.exe"], 0, "out",
     "", "Semantic error"),
    # stderr-diagnostics: stdout must stay clean when a check fails, so anything reading only
    # stdout cannot mistake a failed check for a successful one.
    ("check-failure-keeps-stdout-clean", ["check", "reserved/read.orb"], 1, "out",
     "", "out:Semantic error"),
    ("orbit-prefix-allowed", ["check", "reserved/prefix.orb"], 0, "out",
     "no errors", "Semantic error"),
    ("c-type-model-allowed", ["check", "reserved/model_c_type.orb"], 0, "out",
     "no errors", "Semantic error"),
    ("extern-prefix-allowed", ["check", "reserved/extern_prefix.orb"], 0, "out",
     "no errors", "Semantic error"),
    # A C toolchain that is not installed is the one build failure the compiler
    # may diagnose itself, and it has to keep saying so: the wording is what
    # tells the user to set ORBIT_CC instead of filing a bug.
    ("cc-absent-names-the-toolchain",
     ["build", "tiny.orb", "-o", "x.exe"], 1, "err", "was not found", "",
     {"ORBIT_CC": "orbit-no-such-c-compiler"}),
    # Bare `orbit` with no args prints the short help plus next steps on
    # stdout and exits 0, instead of the build usage on stderr.
    ("bare-noarg", [], 0, "out", "Usage:", ""),
    # `orbit start` builds into .orbit/ and runs: help exits 0, a missing
    # input is an operational error (exit 1), and with no file it looks for
    # main.orb, which the empty probe dir does not have.
    ("start-help", ["start", "--help"], 0, "out", "Usage:", ""),
    ("start-missing", ["start", "nope.orb"], 1, "err", "orbit start:", ""),
    ("start-no-main", ["start"], 1, "err", "orbit start:", ""),
    ("start-badflag", ["start", "--bogus"], 2, "err", "Usage:", ""),
    ("dev-help", ["dev", "--help"], 0, "out", "Usage:", ""),
    ("dev-missing", ["dev", "nope.orb"], 1, "err", "orbit dev:", ""),
    # `orbit stop` ends the service recorded in .orbit/start.pid and is
    # idempotent: with no record the probe dir has nothing to stop, exit 0.
    ("stop-help", ["stop", "--help"], 0, "out", "Usage:", ""),
    ("stop-no-server", ["stop"], 0, "out", "no server running", ""),
    ("stop-badflag", ["stop", "--bogus"], 2, "err", "Usage:", ""),
]

# The not-found wording is not unique to a missing toolchain: clang reports a
# missing include as `'<header>' file not found`, so substring-matching the
# compiler's output turned a wrong -I path into "your C compiler was not
# found" and hid the real error behind a fix that could not help. Only clang
# phrases it that way -- gcc says "No such file or directory" -- so the case is
# skipped where clang is absent rather than asserted against the wrong wording.
#
# The probe runs in an empty work directory, so the runtime include path does
# not resolve there and the C step fails on socket_compat.h for any compiler.
TOOLCHAIN_CASES = [
    ("cc-include-failure-is-not-a-missing-toolchain",
     ["build", "tiny.orb", "-o", "y.exe"], 1, "err",
     "the C compiler rejected my output", "was not found",
     {"ORBIT_CC": "clang", "ORBIT_CCFLAGS_EXTRA": ""}),
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


# Which runtime link the C step chooses when ORBIT_LINK_RUNTIME is not set.
# Each case stages its own `runtime/` (a copy of the repo's .c and .h files) and
# `.orbit/lib/` beside it, with a stub archive and the stamp mklib_runtime.py
# would write, and reads the cc line from `build --verbose`. The C compiler is a
# no-op, so no archive is ever linked.
#   name, how the stage differs from a fresh archive, ORBIT_LINK_RUNTIME,
#   needle that must be on stdout, text that must not be.
LINK_FLAG = "-DORBIT_SEPARATE_COMPILATION"
LINK_CASES = [
    ("link-default-fresh-archive", "fresh", None, LINK_FLAG, ""),
    ("link-default-stale-archive", "stale", None, "does not match", LINK_FLAG),
    # A partial checkout shared between Windows and a POSIX host: the archive
    # was built for the other one, so it must fall to the unity build rather
    # than hand MinGW objects to the host linker.
    ("link-default-other-platform", "other-platform", None, "does not match", LINK_FLAG),
    ("link-default-unstamped-archive", "unstamped", None, "", LINK_FLAG),
    ("link-default-no-archive", "missing", None, "", LINK_FLAG),
    ("link-zero-forces-unity", "fresh", "0", "", LINK_FLAG),
    ("link-one-forces-link", "missing", "1", LINK_FLAG, ""),
]


def link_default_cases(compiler, work):
    """The runtime link the C step picks by default. Returns (ok, total)."""
    import mklib_runtime
    noop_cc = "cmd /c exit 0" if os.name == "nt" else "true"
    ok = 0
    for name, stage_kind, mode, needle, absent in LINK_CASES:
        stage = os.path.join(work, "case_" + name)
        os.makedirs(stage, exist_ok=True)
        setup_dir(stage)
        stage_runtime = os.path.join(stage, "runtime")
        os.makedirs(stage_runtime, exist_ok=True)
        for item in os.listdir(os.path.join(CLI_ROOT, "runtime")):
            if item.endswith((".c", ".h")) and not item.startswith("test_"):
                shutil.copy(os.path.join(CLI_ROOT, "runtime", item), stage_runtime)
        shutil.copytree(os.path.join(CLI_ROOT, "runtime", "gen"),
                        os.path.join(stage_runtime, "gen"), dirs_exist_ok=True)
        if stage_kind != "missing":
            lib_dir = os.path.join(stage, ".orbit", "lib")
            os.makedirs(lib_dir, exist_ok=True)
            archive = os.path.join(lib_dir, "libruntime_net.a")
            with open(archive, "wb") as f:
                f.write(b"!<arch>\n")
            if stage_kind != "unstamped":
                stamp_text = mklib_runtime.runtime_stamp(stage_runtime)
                if stage_kind == "other-platform":
                    here = mklib_runtime.platform_tag()
                    other = "unix" if here == "windows" else "windows"
                    stamp_text = stamp_text.replace(
                        "platform " + here, "platform " + other)
                with open(archive + ".stamp", "wb") as f:
                    f.write(stamp_text.encode("utf-8"))
            if stage_kind == "stale":
                with open(os.path.join(stage_runtime, "arena.c"), "ab") as f:
                    f.write(b"\n")
        env = dict(os.environ)
        for var in ("ORBIT_LINK_RUNTIME", "ORBIT_RUNTIME_LIB",
                    "ORBIT_CCFLAGS_EXTRA"):
            env.pop(var, None)
        env.update({"ORBIT_CC": noop_cc, "CC": noop_cc, "TEMP": stage,
                    "TMP": stage, "ORBIT_SKIP_WINDRES": "1"})
        if mode is not None:
            env["ORBIT_LINK_RUNTIME"] = mode
        p = subprocess.run([compiler, "build", "--verbose", "tiny.orb",
                            "-o", "t.exe"], cwd=stage, capture_output=True,
                           text=True, errors="replace", env=env)
        good = (p.returncode == 0 and needle in p.stdout and
                (not absent or absent not in p.stdout))
        if good:
            out.say(f"Probing {name} ... ok")
            ok += 1
        else:
            out.fail(f"Failed {name}: rc={p.returncode}")
            print("  out: %r" % p.stdout.strip()[:300], file=sys.stderr)
            print("  err: %r" % p.stderr.strip()[:200], file=sys.stderr)
    return (ok, len(LINK_CASES))


def setup_dir(work):
    """Write the probe fixtures into one (per-case) stage directory."""
    for rel, content in SETUP.items():
        dest = os.path.join(work, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        if os.name != "nt" and rel in (R6_SILENT, R6_OTHER):
            os.chmod(dest, 0o755)


def invariants(compiler, work):
    """Post-conditions on files the tool touched. Returns (ok, total)."""
    jobs = list(range(len(INVARIANTS)))

    def run_one(idx):
        # Each invariant owns a staged dir: fmt rewrites its input in place,
        # so a shared work dir lets one case format another's fixture, and
        # each build writes orbit_selfhost_build.c to TEMP. Returns
        # (name, ok, so, se, problems) for ordered reporting below; only the
        # main thread prints.
        name, argv, rel, exp_rc, needle, outcome = INVARIANTS[idx]
        stage = os.path.join(work, "inv_" + name.replace("/", "_"))
        os.makedirs(stage, exist_ok=True)
        setup_dir(stage)
        ok, so, se, problems = check_invariant(compiler, stage, name, argv, rel,
                                               exp_rc, needle, outcome)
        return (name, ok, so, se, problems)

    with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
        results = list(pool.map(run_one, jobs))
    ok = 0
    for name, good, so, se, problems in results:
        if good:
            out.say("Probing %s ... ok" % name)
            ok += 1
        else:
            out.fail("Failed %s: %s" % (name, problems))
            if so.strip():
                print("  out: %r" % so.strip()[:200], file=sys.stderr)
            if se.strip():
                print("  err: %r" % se.strip()[:200], file=sys.stderr)
    return ok, len(INVARIANTS)


def check_invariant(compiler, work, name, argv, rel, exp_rc, needle, outcome):
    """One file post-condition. Returns (ok, stdout, stderr, problems)."""
    env = dict(os.environ)
    env["ORBIT_RUNTIME_DIR"] = os.path.join(CLI_ROOT, "runtime")
    env["TEMP"] = work
    env["TMP"] = work
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
        return (False, so, se, "; ".join(problems))
    return (True, so, se, "")


def one(compiler, work, name, argv, exp_rc, stream, needle, absent="", env_extra=None):
    ok, so, se, rc = probe(compiler, work, name, argv, exp_rc, stream, needle,
                           absent, env_extra)
    if ok:
        out.say(f"Probing {name} ... ok")
    else:
        out.fail(f"Failed {name}: rc={rc} (want {exp_rc})")
        if so.strip():
            print("  out: %r" % so.strip()[:200], file=sys.stderr)
        if se.strip():
            print("  err: %r" % se.strip()[:200], file=sys.stderr)
    return ok


def probe(compiler, work, name, argv, exp_rc, stream, needle, absent="",
          env_extra=None, stdin_text=""):
    """One CLI case. Returns (ok, stdout, stderr); no printing.

    Each caller hands this its own stage dir as `work`: builds write
    orbit_selfhost_build.c to TEMP, so a shared TEMP lets one case's cc read
    another's half-written C, and several cases build outputs (-o *.exe)
    that must not share a cwd while another case mutates it.
    """
    env = dict(os.environ)
    # Build cases need the runtime headers; the probe binary lives in a
    # temp directory, so name the repo runtime explicitly.
    env["ORBIT_RUNTIME_DIR"] = os.path.join(CLI_ROOT, "runtime")
    env["TEMP"] = work
    env["TMP"] = work
    env.update(env_extra or {})
    p = subprocess.run([compiler] + argv, cwd=work, capture_output=True,
                       text=True, errors="replace", env=env,
                       input=stdin_text if stdin_text else None)
    so, se = p.stdout or "", p.stderr or ""
    if stream == "out":
        ok_stream = (not needle) or (needle in so)
    elif stream == "err":
        ok_stream = (not needle) or (needle in se)
    else:
        ok_stream = (not needle) or (needle in (so + se))
    # `absent` is scoped to one stream when written "out:<text>" / "err:<text>";
    # bare text means it must not appear on either. This is what lets a case
    # assert that stdout stays clean while the same text is on stderr.
    if absent.startswith("out:"):
        ok_absent = absent[4:] not in so
    elif absent.startswith("err:"):
        ok_absent = absent[4:] not in se
    else:
        ok_absent = (not absent) or (absent not in so and absent not in se)
    ok_json = True
    if name == "doctor-json" and p.returncode == 1:
        import json as _json
        # The original six keys are a contract an editor may already depend on,
        # so they are required to be PRESENT rather than to be the whole object:
        # the newer keys are additive and a consumer that breaks on them is the
        # thing this assertion exists to catch.
        base_keys = {"file", "line", "code", "severity", "message", "fix"}
        added_keys = {"column", "layer", "fix_kind", "applied", "edits"}
        try:
            rows = _json.loads(so)
            ok_json = (isinstance(rows, list) and len(rows) >= 1 and
                       all(base_keys <= set(r) for r in rows) and
                       all(added_keys <= set(r) for r in rows) and
                       all(isinstance(r["column"], int) and
                           isinstance(r["edits"], list) and
                           isinstance(r["applied"], str) for r in rows))
        except Exception:
            ok_json = False
    ok = (p.returncode == exp_rc) and ok_stream and ok_absent and ok_json
    return (ok, so, se, p.returncode)


def cli_probe_main(args, ap) -> int:
    """CLI contract probe: exit codes and streams per COMMANDS.md.

    Exits 0 iff every case matches its expectation. Cases run in an empty
    work directory so ambient state (.orbit/, repo files) cannot leak in.
    Expected table derives from docs/COMMANDS.md plus the CLI-1 decisions:
    unknown top-level command -> usage on stderr, exit 2; operational
    errors go to stderr with an `orbit <cmd>:` prefix; --help exits 0.

    --specimen prints the static output-grammar specimen (one section per
    tool) so tone can be reviewed without running a bootstrap. Nothing
    there executes a gate.
    """
    if args.specimen:
        print(SPECIMEN, end="")
        return 0
    if not args.compiler:
        ap.error("--compiler is required unless --specimen is given")
    work = os.path.abspath(args.work) if args.work else tempfile.mkdtemp(prefix="orbit_cli_")
    os.makedirs(work, exist_ok=True)

    def run_one(case):
        # Each case owns a staged dir: fmt/build cases read and write files
        # by relative path, so a shared work dir lets one case see another's
        # outputs, and each build writes orbit_selfhost_build.c to TEMP.
        # Returns (name, exp_rc, ok, so, se, rc) for ordered reporting below;
        # only the main thread prints.
        name, argv, exp_rc, stream, needle = case[:5]
        absent = case[5] if len(case) > 5 else ""
        env_extra = case[6] if len(case) > 6 else None
        stdin_text = case[7] if len(case) > 7 else ""
        stage = os.path.join(work, "case_" + name.replace("/", "_"))
        os.makedirs(stage, exist_ok=True)
        setup_dir(stage)
        ok, so, se, rc = probe(args.compiler, stage, name, argv, exp_rc,
                               stream, needle, absent, env_extra, stdin_text)
        return (name, exp_rc, ok, so, se, rc)

    def report(name, exp_rc, ok, so, se, rc):
        if ok:
            out.say(f"Probing {name} ... ok")
        else:
            out.fail(f"Failed {name}: rc={rc} (want {exp_rc})")
            if so.strip():
                print("  out: %r" % so.strip()[:200], file=sys.stderr)
            if se.strip():
                print("  err: %r" % se.strip()[:200], file=sys.stderr)
        return ok

    ok = 0
    total = len(CASES)
    with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
        results = list(pool.map(run_one, CASES))
    for name, exp_rc, good, so, se, rc in results:
        if report(name, exp_rc, good, so, se, rc):
            ok += 1
    if shutil.which("clang"):
        with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
            tc_results = list(pool.map(run_one, TOOLCHAIN_CASES))
        for name, exp_rc, good, so, se, rc in tc_results:
            if report(name, exp_rc, good, so, se, rc):
                ok += 1
            total += 1
    else:
        out.say("Skipping clang toolchain cases: clang is not installed")
    inv_ok, inv_total = invariants(args.compiler, work)
    ok += inv_ok
    total += inv_total
    link_ok, link_total = link_default_cases(args.compiler, work)
    ok += link_ok
    total += link_total
    out.finish("cli-probe", ok, total)
    return 0 if ok == total else 1


# ---- from scripts/ui_snapshots.py -----------------------------------------
UI_ROOT = pathlib.Path(__file__).resolve().parent.parent
SNAPSHOTS = UI_ROOT / "tests" / "ui"

FIXTURES = {
    "hello.orb": 'fn main() {\n    print("hello")\n}\n',
    "sema_error.orb": 'fn main() {\n    val x: int = "s"\n    print("hi")\n}\n',
    "parse_error.orb": 'fn main() {\n    val total = 1 + * 2\n}\n',
    "unformatted.orb": 'fn main() {\nprint("hi")\n}\n',
    "scan/messy.orb": 'fn main() {\n    print("hi")   \n}\n',
    "scan/clean.orb": 'fn main() {\n    print("hi")\n}\n',
}

# name, argv, expected exit, fixture files to copy into a fresh directory first
SCREENS = [
    ("build", ["build", "hello.orb", "-o", "hello.exe", "--backend=c"], 0),
    ("run", ["run", "." + os.sep + "hello.orb", "--backend=c"], 0),
    ("build-sema-error", ["build", "sema_error.orb", "-o", "x.exe", "--backend=c"], 1),
    ("build-parse-error", ["build", "parse_error.orb", "-o", "x.exe", "--backend=c"], 1),
    ("check", ["check", "hello.orb"], 0),
    ("check-error", ["check", "sema_error.orb"], 1),
    ("doctor", ["doctor", "scan"], 1),
    ("fmt", ["fmt", "unformatted.orb"], 0),
    ("fmt-check", ["fmt", "--check", "scan"], 1),
    ("help", ["--help"], 0),
    ("bare", [], 0),
    ("version", ["--version"], 0),
]

TIERS = [("rich", {"ORBIT_UI": "rich", "COLORTERM": "truecolor"}),
         ("color", {"ORBIT_UI": "color"})]

# Variables that would change a tier or a color between machines.
SCRUB = ("NO_COLOR", "CI", "GITHUB_ACTIONS", "WT_SESSION", "TERM_PROGRAM", "COLORTERM",
         "ORBIT_UI", "ORBIT_UI_MOTION", "ORBIT_COLOR", "ORBIT_BACKEND", "ORBIT_SKIP_CC")

ESC = r"(?:\x1b\[[0-9;]*m)"
MASKS = [
    # Stage bars: the filled share follows the timings.
    (re.compile("%s*[▰▱](?:%s*[▰▱])*" % (ESC, ESC)), "<bar>"),
    (re.compile(r"\[(?:%s|[#\-])+\]" % ESC), "[<bar>]"),
    # The probe line names a compiler of the machine.
    (re.compile(r"^toolchain: found .*$", re.M), "toolchain: found <cc>"),
    # Times and sizes, with the padding that right-aligns them.
    (re.compile(r" *(?<![0-9.])\d+(?:\.\d+)?(?= (?:ms|KB)\b)"), " N"),
    # The banner names the version; cli-probe pins that string exactly. This
    # gate is about the layout, so a version bump must not rewrite six goldens.
    (re.compile(r"orbit \d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?"), "orbit N"),
]


def normalize(text: str, scratch_dir: str) -> str:
    text = text.replace("\r\n", "\n")
    for spelling in (scratch_dir, scratch_dir.replace("\\", "/")):
        text = text.replace(spelling, ".")
    text = text.replace("\\", "/")
    # `orbit run` names the child with the host's executable suffix. The screen
    # is about the layout, so the goldens are stored without it.
    text = text.replace(".orb.run.exe", ".orb.run")
    # Windows names a relative path as ".\scan\x.orb" and Linux as "scan/x.orb".
    # The goldens are stored in the POSIX spelling.
    text = text.replace("./scan/", "scan/")
    for pattern, repl in MASKS:
        text = pattern.sub(repl, text)
    return "\n".join(settle_card_padding(line) for line in text.split("\n"))


# A card row pads to its border, so a time of two digits leaves one space fewer
# than a time of one. After masking, the run before the border on such a row is
# one space.
MASKED_NUMBER = re.compile(r" N (?:ms|KB)")
BORDER_TAIL = re.compile(r" {2,}((?:\x1b\[[0-9;]*m)*[│|](?:\x1b\[[0-9;]*m)*)$")


def settle_card_padding(line: str) -> str:
    if MASKED_NUMBER.search(line):
        return BORDER_TAIL.sub(r" \1", line)
    return line


def child_env(extra: dict, cc: str, work: pathlib.Path) -> dict:
    env = dict(os.environ)
    for key in SCRUB:
        env.pop(key, None)
    # The compiler writes its intermediate C to a fixed name under TEMP, so a
    # build running beside this one (the lane gates) would overwrite it.
    # This directory was named `scratch` in ui_snapshots.py; `_common.scratch`
    # is imported here, so the local keeps a name of its own.
    tmp_dir = work / "tmp"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    env["TEMP"] = env["TMP"] = str(tmp_dir)
    env.update({"TERM": "xterm-256color", "ORBIT_UI_MOTION": "0", "ORBIT_BACKEND": "c",
                "ORBIT_LINK_RUNTIME": "0", "ORBIT_CCACHE": "0", "ORBIT_CC": cc})
    env.update(extra)
    return env


def stage_dir(work: pathlib.Path, name: str) -> pathlib.Path:
    d = work / name
    if d.exists():
        shutil.rmtree(d)
    d.mkdir(parents=True)
    for rel, text in FIXTURES.items():
        target = d / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8", newline="\n")
    # The compiler resolves the runtime relative to a directory it does not ship in.
    runtime = d / "runtime"
    runtime.mkdir()
    for src in (UI_ROOT / "runtime").iterdir():
        if src.is_file() and src.suffix in (".c", ".h"):
            shutil.copyfile(src, runtime / src.name)
    # The unity build includes the C generated from runtime/orb/*.orb.
    shutil.copytree(UI_ROOT / "runtime" / "gen", runtime / "gen")
    return d


def run_screen(compiler: str, cc: str, work: pathlib.Path, name: str, argv: list, tier_env: dict):
    d = stage_dir(work, name)
    proc = subprocess.run([compiler] + argv, cwd=str(d), env=child_env(tier_env, cc, work),
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
    return proc.returncode, normalize(proc.stdout.decode("utf-8", errors="replace"), str(d))


def show(text: str) -> None:
    """Print captured output on any console, escapes and non-ASCII made visible."""
    sys.stdout.write(text.replace(chr(27), "\\e").encode("ascii", "backslashreplace").decode("ascii"))
    sys.stdout.flush()


def check_snapshots(args, work: pathlib.Path) -> tuple:
    ok = 0
    total = 0
    SNAPSHOTS.mkdir(parents=True, exist_ok=True)
    for name, argv, want_rc in SCREENS:
        for tier_name, tier_env in TIERS:
            total += 1
            label = "%s.%s" % (name, tier_name)
            rc, text = run_screen(args.compiler, args.cc, work, name, argv, tier_env)
            path = SNAPSHOTS / (label + ".txt")
            if rc != want_rc:
                out.fail("Failed %s: exit %d, want %d" % (label, rc, want_rc))
                show(text)
                continue
            if args.update:
                path.write_text(text, encoding="utf-8", newline="\n")
                out.say("Wrote %s" % path.relative_to(UI_ROOT).as_posix())
                ok += 1
                continue
            if not path.exists():
                out.fail("Failed %s: no snapshot at %s" % (label, path.relative_to(UI_ROOT).as_posix()))
                # The command in this tip moved with the file: it used to name
                # scripts/ui_snapshots.py, which no longer exists.
                out.tip("run scripts/doctor_gates.py snapshots --update and read the file before committing it")
                continue
            want = path.read_text(encoding="utf-8")
            if want == text:
                out.say("Checking %s ... match" % label)
                ok += 1
                continue
            out.fail("Failed %s: output differs from %s" % (label, path.relative_to(UI_ROOT).as_posix()))
            diff = difflib.unified_diff(want.splitlines(), text.splitlines(), "snapshot", "output", lineterm="", n=1)
            for line in list(diff)[:24]:
                show(line + "\n")
    return ok, total


def read_until(needle: bytes, sink: bytearray, deadline: float) -> bool:
    while time.monotonic() < deadline:
        if needle in bytes(sink):
            return True
        time.sleep(0.05)
    return needle in bytes(sink)


def probe_interrupt(args, work: pathlib.Path) -> tuple:
    """Break an animated build and read what the terminal would have been told."""
    d = stage_dir(work, "probe")
    env = child_env({"ORBIT_UI": "rich", "ORBIT_UI_MOTION": "force", "COLORTERM": "truecolor",
                     "ORBIT_SKIP_CC": "1"}, args.cc, work)
    flags = 0
    if os.name == "nt":
        flags = subprocess.CREATE_NEW_PROCESS_GROUP
    src = str(UI_ROOT / "compiler" / "host" / "main.orb")
    proc = subprocess.Popen([args.compiler, "build", src, "-o", str(d / "probe.exe")], cwd=str(UI_ROOT),
                            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, creationflags=flags)
    seen = bytearray()

    def pump():
        while True:
            chunk = proc.stderr.read(512)
            if not chunk:
                return
            seen.extend(chunk)

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    if not read_until(b"\x1b[?25l", seen, time.monotonic() + 20):
        proc.kill()
        out.fail("Failed interrupt-probe: no frame was painted (cursor-hide not seen)")
        return 0, 1
    time.sleep(0.6)
    try:
        if os.name == "nt":
            os.kill(proc.pid, signal.CTRL_BREAK_EVENT)
        else:
            proc.send_signal(signal.SIGINT)
    except OSError as exc:
        proc.kill()
        out.say("Interrupt-probe skipped: no console to send a break to (%s)" % exc)
        return 0, 0
    try:
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
        out.fail("Failed interrupt-probe: the build did not stop after the break")
        return 0, 1
    reader.join(timeout=5)
    tail = bytes(seen)
    restore = b"\x1b[?25h\x1b[0m"
    if not tail.endswith(restore):
        out.fail("Failed interrupt-probe: stream ends with %r, want %r" % (tail[-24:], restore))
        return 0, 1
    if tail.count(b"\x1b[?25l") != 1:
        out.fail("Failed interrupt-probe: cursor-hide written %d times" % tail.count(b"\x1b[?25l"))
        return 0, 1
    out.say("Checking interrupt-probe ... cursor shown and styles reset after a break")
    return 1, 1


def ui_main(args, ap) -> int:
    """Snapshots of the compiler's rich and color screens, and the interrupt probe.

    Each screen runs twice, with ORBIT_UI=rich ORBIT_UI_MOTION=0 (truecolor) and
    with ORBIT_UI=color, in a scratch directory. Output is stdout and stderr in one
    stream, CRLF folded to LF. Escape sequences stay, so a changed color is a
    changed snapshot. Digits that belong to a time or a size and the cells of a
    stage bar vary from run to run and are masked. The result is compared with
    tests/ui/<screen>.<tier>.txt. --update rewrites those files.

    The probe starts an animated build, sends it a console break and requires the
    stream to end with cursor-show then reset (docs/CLI_UI.md). It needs a console
    to send the break to and reports "probe skipped" when the platform offers none.
    """
    if not args.compiler:
        # Declared optional for the same reason doctor declares it optional:
        # --self-test must be able to run this subcommand with no binary.
        ap.error("the following arguments are required: --compiler")
    args.cc = resolve_cc(args.cc)
    args.compiler = str(pathlib.Path(args.compiler).resolve())
    work = pathlib.Path(args.work) if args.work else pathlib.Path(tempfile.mkdtemp(prefix="orbit_ui_"))
    work.mkdir(parents=True, exist_ok=True)
    ok, total = check_snapshots(args, work)
    if not args.skip_probe and not args.update:
        pok, ptotal = probe_interrupt(args, work)
        ok += pok
        total += ptotal
    out.finish("ui-snapshots", ok, total)
    return 0 if ok == total else 1


# ---- from scripts/dispatch_coverage.py ------------------------------------
DISPATCH_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AST = os.path.join(DISPATCH_ROOT, "compiler", "front", "ast.orb")
SEMA = os.path.join(DISPATCH_ROOT, "compiler", "front", "sema.orb")


def dispatch_fail(problems):
    # Prefixed because `fail` is too general a name to share a file with three
    # other gates; the printed lines are unchanged.
    for p in problems:
        print("  %s" % p, file=sys.stderr)
    print("FAILED dispatch-coverage: %d problem(s)" % len(problems), file=sys.stderr)
    return 1


def depth_map(text):
    """Depth of braces at each character offset."""
    res = []
    d = 0
    for ch in text:
        if ch == "{":
            res.append(d)
            d += 1
        elif ch == "}":
            d -= 1
            res.append(d)
        else:
            res.append(d)
    return res


def fn_span(text, signature):
    """Start, end and body-open-brace of a top-level fn."""
    i = text.index(signature)
    j = text.index("{", i)
    d = 0
    k = j
    while True:
        if text[k] == "{":
            d += 1
        elif text[k] == "}":
            d -= 1
            if d == 0:
                return i, k + 1, j
        k += 1
    raise ValueError("unterminated %s" % signature)


def match_arms(text, offset=0):
    """Arms of the outermost match, keyed by variant name.

    A nested `match` inside an arm has arms of its own, and taking those for
    the outer match is how a refactor once moved the body of
    `ASTNode.Call(innerCall)` on top of the top-level `Call`. The outermost arms
    are the ones at the shallowest depth, so that is what this selects.
    """
    dm = depth_map(text)
    found = []
    for m in re.finditer(r"ASTNode\.(\w+)(\([^)]*\))?\s*=>\s*\{", text):
        found.append((dm[m.end() - 1], m))
    if not found:
        return {}, None
    base = min(d for d, _ in found)
    arms = {}
    for depth, m in found:
        if depth != base or m.group(1) in arms:
            continue
        d = 0
        k = m.end() - 1
        while True:
            if text[k] == "{":
                d += 1
            elif text[k] == "}":
                d -= 1
                if d == 0:
                    break
            k += 1
        arms[m.group(1)] = (m.start(), m.end(), k + 1)
    return arms, base


def variants(ast_text):
    m = re.search(r"(?m)^type ASTNode = (.*)$", ast_text)
    if not m:
        raise ValueError("no `type ASTNode` in ast.orb")
    return [v.split("(")[0].strip() for v in m.group(1).split("|")]


def dispatch_main() -> int:
    """Coverage: every ASTNode variant has an arm in the one checker (D9).

    The incident this exists for: sema.orb had two functions that both walked the
    AST -- `checkNode` dispatched to the check* family, `inferType` returned a
    type -- and they overlapped on 13 of 42 arms. Eleven callers reached only one of
    them. A check added to `checkNode` therefore did not run for every program that
    contained the node, and nothing said so. It cost three hours to find out, and
    the wrong version of the check reported a line number of 25515 for a four-line
    file.

    The two are now one function. That fixes the instance and removes the
    invitation, but only for as long as nobody adds a third walker or forgets an
    arm. This checks the shape:

      1. every variant of `type ASTNode` has an arm in checkNode's match;
      2. every arm of that match returns on every path, so the declared
         `-> string` is not a promise the body breaks;
      3. the old `inferType` is gone, so there is no second place to add a check
         to by accident.

    (1) is the invariant. A new ASTNode variant with no arm is not a compile error
    today -- it falls to the `_` arm and returns "" -- and that is precisely how a
    check silently stops running. (2) is what a missing `return` looks like from
    the outside: a segfault in the checker, with no line number. (3) is the cheap
    one, and it is the one that would have caught this before it was written.

    Exits 0 when the shape holds, 1 when it does not.
    """
    with open(AST) as f:
        ast_text = f.read()
    with open(SEMA) as f:
        sema_text = f.read()

    problems = []

    # 3. the second walker is gone
    if re.search(r"(?m)^fn inferType\(", sema_text):
        problems.append(
            "compiler/front/sema.orb still defines inferType. There is one checker, "
            "checkNode; a second walker is how a check ends up running for "
            "some programs and not others."
        )
    leftover = re.findall(r"inferType\(sema,", sema_text)
    if leftover:
        problems.append(
            "compiler/front/sema.orb still calls inferType in %d place(s)."
            % len(leftover)
        )

    sig = "fn checkNode(sema: Sema, node: ASTNode) -> string {"
    if sig not in sema_text:
        problems.append(
            "checkNode is not declared as `-> string`. The merged checker has "
            "to return the type it infers, or the whole point is lost."
        )
        return dispatch_fail(problems)

    start, end, _ = fn_span(sema_text, sig)
    body = sema_text[start:end]
    arms, _ = match_arms(body)

    # 1. every variant has an arm
    vs = variants(ast_text)
    missing = [v for v in vs if v not in arms]
    if missing:
        problems.append(
            "ASTNode variants with no arm in checkNode: %s. An unhandled "
            "variant falls to the `_` arm and returns \"\", which is how a "
            "check silently stops running." % ", ".join(missing)
        )

    # 2. every arm returns
    silent = []
    for name, (_, b, e) in sorted(arms.items()):
        if "return" not in body[b:e]:
            silent.append(name)
    if silent:
        problems.append(
            "checkNode arms with no return: %s. checkNode declares -> string, "
            "so a path that falls off the end reads an unset return value -- a "
            "segfault in the checker, with no line number." % ", ".join(silent)
        )

    # the `_` fallback has to answer too
    if not re.search(r"_\s*=>\s*\{[^}]*\breturn\b", body):
        problems.append(
            "checkNode's `_` fallback does not return. Every path out of a "
            "-> string function has to produce a string."
        )

    if problems:
        return dispatch_fail(problems)

    print("dispatch-coverage: %d ASTNode variants, %d arms, all returning" % (len(vs), len(arms)))
    print("  one checker: inferType is gone and nothing calls it")
    print("Finished dispatch-coverage: OK")
    return 0


# ---- self-tests, one per subcommand ---------------------------------------
def self_test_doctor() -> int:
    """The doctor harness, checked with a stub instead of a compiler.

    What has to stay able to fail is the machinery around the goldens, not the
    findings: staging copies the fixtures and skips the gate's own files, the
    toolchain probe line is dropped so a golden is portable, `expect_rc` defaults
    to 1, and the two tree assertions fire when a case mutates what it scanned.
    A golden comparison that could not report a one-character difference would
    pass every case in the directory forever, so it is asserted both ways.
    """
    fails = 0
    total = 0

    def check(label, ok):
        nonlocal fails, total
        total += 1
        if ok:
            out.say("  ok    %s" % label)
        else:
            out.fail("  BROKEN %s" % label)
            fails += 1

    def write_stub(work, lines, rc, mutate=None):
        """A compiler that prints `lines` and exits `rc`, optionally mutating.

        The canned text sits in a file the stub cats, because cmd.exe's `echo`
        pads and trims trailing spaces and the point of the stub is a byte-exact
        stdout. `mutate` is a path relative to the working directory, which for
        run_case is the staged copy: that is what a --fix case that changed the
        tree it scanned looks like to expect_unchanged.
        """
        canned = pathlib.Path(work) / "canned.txt"
        canned.write_text("".join(l + "\n" for l in lines),
                          encoding="utf-8", newline="\n")
        step = ('type "%~dp0canned.txt"' if os.name == "nt"
                else 'cat "$(dirname "$0")/canned.txt"')
        if mutate:
            step = ("echo mutated>> \"%s\"" % mutate if os.name == "nt"
                    else "echo mutated >> '%s'" % mutate)
        if os.name == "nt":
            stub = pathlib.Path(work) / "stub.cmd"
            body = "@echo off\r\n%s\r\nexit /b %d\r\n" % (step, rc)
        else:
            stub = pathlib.Path(work) / "stub.sh"
            body = "#!/bin/sh\n%s\nexit %d\n" % (step, rc)
        stub.write_text(body, encoding="utf-8",
                        newline="\r\n" if os.name == "nt" else "\n")
        if os.name != "nt":
            os.chmod(stub, 0o755)
        return str(stub)

    def make_case(root, name, files):
        case = root / name
        case.mkdir(parents=True, exist_ok=True)
        for rel, text in files.items():
            target = case / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8", newline="\n")
        return case

    with tempfile.TemporaryDirectory(prefix="doctor_selftest_") as td:
        work = pathlib.Path(td)
        env, _s = scratch_env()

        check("strip_toolchain drops only the probe line",
              strip_toolchain("toolchain: gcc 15.2\nf.orb:1 warning [D006] x\n")
              == "f.orb:1 warning [D006] x\n")
        check("a finding that merely mentions toolchain survives",
              "x.orb:2 error [D001] toolchain is named here\n"
              == strip_toolchain("x.orb:2 error [D001] toolchain is named here\n"))
        check("a line beginning with the probe word is dropped",
              strip_toolchain("toolchain: found cc\n") == "")

        case = make_case(work / "cases", "d099_args", {
            "scan": "s\n", "args": "--fix --verbose\n", "expect_rc": "0\n",
            "s/x.orb": "fn main() -> int {\n    return 0\n}\n",
        })
        check("args split into separate flags, not one line",
              read_args(case) == ["--fix", "--verbose"])
        check("a case with no args file has none", read_args(work / "cases") == [])
        check("expect_rc is read", read_rc(case) == 0)
        check("the default exit code is the finding exit",
              read_rc(work / "cases" / "no_such_case") == 1)
        check("--fix means the C step", cases_needing_c_step(case) is True)

        staged = work / "staged"
        staged.mkdir()
        stage_case(case, str(staged))
        check("staging copies the fixture", (staged / "s" / "x.orb").is_file())
        leaked = [m for m in META if (staged / m).exists()]
        check("staging skips the gate's own files", leaked == [])

        check("an untouched tree passes check_unchanged",
              check_unchanged(case, str(staged)) == "")
        (staged / "s" / "x.orb").write_text("mutated", encoding="utf-8")
        check("a mutated fixture is reported",
              "changed" in check_unchanged(case, str(staged)))
        (staged / "s" / "x.orb").unlink()
        check("a disappeared fixture is reported",
              "disappeared" in check_unchanged(case, str(staged)))

        crlf_case = make_case(work / "cases", "d098_crlf", {
            "scan": "s\n", "s/lf.orb": "fn main() -> int {\n}\n",
        })
        lf_work = work / "lf"
        lf_work.mkdir()
        stage_case(crlf_case, str(lf_work))
        check("a lone LF is reported by name and byte offset",
              "lone LF at byte" in check_crlf(crlf_case, str(lf_work)))
        crlf_work = work / "crlf"
        crlf_work.mkdir()
        (crlf_work / "ok.orb").write_bytes(b"fn main() -> int {\r\n}\r\n")
        check("CRLF throughout is silent", check_crlf(crlf_case, str(crlf_work)) == "")

        check("the implicit ENGINEERING.md is pointed at the repo",
              inject_repo_paths(["--budget-doc", "ENGINEERING.md"])
              == ["--budget-doc", str(REPO / "ENGINEERING.md")])
        check("any other value is left alone",
              inject_repo_paths(["--budget-doc", "other.md"])
              == ["--budget-doc", "other.md"])

        check("D015 is advisory in every file",
              "D015" in scope_advisory_codes_for("compiler/front/sema.orb"))
        check("D021 is advisory only in the file that pins argument types",
              "D021" not in scope_advisory_codes_for("compiler/front/sema.orb")
              and "D021" in scope_advisory_codes_for(
                  "tests/suite/call_arg_types.orb"))

        check("a compiler with no runtime beside it cannot do the C step",
              compiler_can_reach_runtime(str(work / "orbit.exe")) is False)
        beside = work / "beside"
        (beside / "runtime").mkdir(parents=True)
        check("a compiler with a runtime beside it can",
              compiler_can_reach_runtime(str(beside / "orbit.exe")) is True)
        check("a compiler at the repository root can",
              compiler_can_reach_runtime(str(REPO / "orbit.exe")) is True)

        # The harness end to end against a stub: the golden bargain, both ways.
        stub = write_stub(work, ["toolchain: stub cc 0.0",
                                 "x.orb:1 warning [D006] canned finding"], 1)
        golden_case = make_case(work / "cases", "d097_stub", {
            "scan": "s\n",
            "expected.txt": "x.orb:1 warning [D006] canned finding\n",
            "s/x.orb": "fn main() -> int {\n    return 0\n}\n",
        })
        proc, err = run_case(stub, golden_case, env)
        check("the stub case runs and stages its copy",
              err is None and proc is not None)
        check("a matching golden compares equal",
              proc is not None and proc.stdout
              == (golden_case / "expected.txt").read_text(encoding="utf-8"))
        check("the stub's exit is the default expect_rc",
              proc is not None and proc.returncode == read_rc(golden_case))
        drifted = make_case(work / "cases", "d096_drift", {
            "scan": "s\n",
            "expected.txt": "x.orb:1 warning [D006] canned findingX\n",
            "s/x.orb": "fn main() -> int {\n    return 0\n}\n",
        })
        proc2, _e2 = run_case(stub, drifted, env)
        check("a one-character golden drift is a mismatch, not a pass",
              proc2 is not None and proc2.stdout
              != (drifted / "expected.txt").read_text(encoding="utf-8"))

        mut_case = make_case(work / "cases", "d095_mutate", {
            "scan": "s\n", "expect_unchanged": "\n", "args": "--fix\n",
            "expected.txt": "x.orb:1 warning [D006] canned finding\n",
            "s/x.orb": "fn main() -> int {\n    return 0\n}\n",
        })
        # The stub appends to the fixture inside its own working directory,
        # which run_case sets to the staged copy: that is what a --fix case
        # that mutated the tree it scanned looks like to expect_unchanged.
        mut_rel = "s\\x.orb" if os.name == "nt" else "s/x.orb"
        mut_stub = write_stub(work, [], 1, mutate=mut_rel)
        _p3, err3 = run_case(mut_stub, mut_case, env)
        check("a case that changes the tree fails expect_unchanged",
              err3 is not None and "changed the tree" in err3)

        _p4, err4 = run_case(stub, make_case(work / "cases", "d094_noscan", {
            "expected.txt": "",
        }), env)
        check("a case with no scan is named, not silently skipped",
              err4 is not None and "missing scan" in err4)
        _p5, err5 = run_case(stub, make_case(work / "cases", "d093_emptyscan", {
            "scan": "\n",
        }), env)
        check("an empty scan is named", err5 is not None and "empty scan" in err5)

        steps_case = make_case(work / "cases", "d092_steps", {
            "steps": "{orbit} doctor s\n",
            "s/x.orb": "fn main() -> int {\n    return 0\n}\n",
        })
        step_stub = write_stub(work, ["toolchain: stub cc 0.0",
                                      "x.orb:2 warning [D006] step line"], 1)
        # `steps` runs the line through a shell, so the stub path is quoted
        # there rather than spawned directly, exactly as a golden quotes it.
        proc6, err6 = run_case('"%s"' % step_stub, steps_case, env)
        check("a steps case concatenates the step stdout",
              err6 is None and proc6 is not None
              and proc6.stdout == "x.orb:2 warning [D006] step line\n")

        bad = work / "bad"
        bad.mkdir(exist_ok=True)
        bs = write_stub(bad, ["x"], 3)
        usable, found, adv, why = scope_scan(bs, env, "compiler")
        check("a run that exits outside {0, 1} is unusable, not clean",
              usable is False and "exited (3)" in why and found == [])
        check("an unusable run counts no advisories", adv == 0)
        units = scope_subdirs("compiler")
        check("a subdirectory list only names dirs that hold source",
              bool(units) and all(u.startswith("compiler/") for u in units))

    out.finish("doctor_gate self-test", total - fails, total)
    return 1 if fails else 0


def self_test_cli_probe() -> int:
    """The CLI contract's own reading, driven with python in place of the compiler.

    The probe compares an exit code and a needle per stream, and those are the
    three things that can rot silently: a matcher that always answers ok, a
    needle checked against the wrong stream, and an `absent` that does not look
    at stdout would each turn 50 cases into 50 passes. So the cases below run the
    real matcher against a stub whose stream the test controls.
    """
    fails = 0
    total = 0

    def check(label, ok):
        nonlocal fails, total
        total += 1
        if ok:
            out.say("  ok    %s" % label)
        else:
            out.fail("  BROKEN %s" % label)
            fails += 1

    def stub(src):
        """The `-c` half of the child's argv; `probe` prepends the interpreter."""
        return ["-c", src]

    with tempfile.TemporaryDirectory(prefix="cli_probe_selftest_") as td:
        work = os.path.join(td, "w")
        os.makedirs(work, exist_ok=True)
        setup_dir(work)
        py = sys.executable

        ok, _so, _se, _rc = probe(py, work, "help",
                                  stub("print('Usage: orbit')"),
                                  0, "out", "Usage:")
        check("a matching exit code and needle passes", ok)
        ok, _so, _se, _rc = probe(py, work, "help",
                                  stub("print('Usage: orbit')"),
                                  1, "out", "Usage:")
        check("a wrong exit code is a failure", not ok)
        ok, _so, _se, _rc = probe(py, work, "help",
                                  stub("print('nothing of the sort')"),
                                  0, "out", "Usage:")
        check("a needle that is not there is a failure", not ok)
        ok, _so, _se, _rc = probe(py, work, "help",
                                  stub("import sys\nprint('Usage: orbit', file=sys.stderr)"),
                                  0, "out", "Usage:")
        check("a needle on stderr is not read as stdout", not ok)
        ok, _so, _se, _rc = probe(py, work, "check",
                                  stub("import sys\nprint('Usage: orbit', file=sys.stderr)"),
                                  0, "err", "Usage:")
        check("the same needle passes on the stream it is expected on", ok)
        ok, _so, _se, _rc = probe(py, work, "check",
                                  stub("import sys\nprint('on stdout')\n"
                                       "print('Semantic error', file=sys.stderr)"),
                                  0, "out", "", "out:Semantic error")
        check("an stdout-scoped absence passes when stdout is clean", ok)
        ok, _so, _se, _rc = probe(py, work, "check",
                                  stub("print('Semantic error')"),
                                  0, "out", "", "out:Semantic error")
        check("the same absence fails when the text is on stdout", not ok)
        ok, _so, _se, _rc = probe(py, work, "check",
                                  stub("import sys\nprint('Semantic error')\n"
                                       "print('Semantic error', file=sys.stderr)"),
                                  0, "out", "", "Semantic error")
        check("a bare absence covers both streams", not ok)
        ok, _so, _se, _rc = probe(py, work, "anything",
                                  stub("import sys\nprint('x', file=sys.stderr)\nsys.exit(2)"),
                                  2, "any", "x")
        check("stream \"any\" reads either", ok)

        good = ('import json,sys\n'
                'sys.stdout.write(json.dumps([{"file":"a.orb","line":1,"column":2,'
                '"code":"D006","severity":"warning","message":"m","fix":"f",'
                '"layer":"l","fix_kind":"k","applied":"n","edits":[]}]))\nsys.exit(1)\n')
        ok, _so, _se, _rc = probe(py, work, "doctor-json", stub(good), 1, "out", '"code"')
        check("the json contract passes on a row with every key", ok)
        ok, _so, _se, _rc = probe(py, work, "doctor-json",
                                  stub(good.replace('"column":2,', '')),
                                  1, "out", '"code"')
        check("a json row missing an added key fails", not ok)
        not_json = 'import sys\nsys.stdout.write("[not json")\nsys.exit(1)\n'
        ok, _so, _se, _rc = probe(py, work, "doctor-json", stub(not_json),
                                  1, "out", '"code"')
        check("json that does not parse fails rather than passing", not ok)
        ok, _so, _se, _rc = probe(py, work, "doctor-other", stub(not_json),
                                  1, "out", "")
        check("a case other than doctor-json skips the json assertion", ok)

        check("setup_dir writes every fixture the table names",
              all(os.path.isfile(os.path.join(work, rel)) for rel in SETUP))

        clean, _so, _se, problems = check_invariant(
            py, work, "fmt-no-clobber-parse-error",
            stub("import sys\nsys.stderr.write('orbit fmt: parse error\\n')\nsys.exit(1)"),
            "fmt/broken.orb", 1, "", "unchanged")
        check("a file left byte-identical passes the unchanged invariant", clean)
        emptied, _so, _se, problems = check_invariant(
            py, work, "fmt-no-clobber-parse-error",
            stub("open('fmt/broken.orb','w').close()\nsys.exit(1)"),
            "fmt/broken.orb", 1, "", "unchanged")
        check("a truncated file is reported as FILE EMPTIED",
              emptied is False and "FILE EMPTIED" in problems)
        rewritten, _so, _se, problems = check_invariant(
            py, work, "fmt-no-clobber-formats-ok",
            stub("open('fmt/messy.orb','w').write('fn main() -> int {\\n    return 0\\n}\\n')"),
            "fmt/messy.orb", 0, "", "rewritten")
        check("a rewritten file passes the rewritten invariant", rewritten)
        same, _so, _se, problems = check_invariant(
            py, work, "fmt-no-clobber-formats-ok", stub("pass"),
            "fmt/messy.orb", 0, "", "rewritten")
        check("a formatter that did nothing is reported",
              same is False and "unchanged but should have been formatted" in problems)
        notblank, _so, _se, problems = check_invariant(
            py, work, "fmt-blank-normalises-to-empty", stub("pass"),
            "fmt/blank.orb", 0, "", "emptied")
        check("a file with content fails the emptied invariant",
              notblank is False and "normalised to empty" in problems)

        check("one() reports the pass it just measured",
              one(py, work, "stub-case", ["-c", "print('ok line')"],
                  0, "out", "ok line") is True)

    check("the specimen carries every section alive_check pins",
          all(h in SPECIMEN for h in ("--- suite ", "--- parity ", "--- cli-probe ",
                                      "--- verify / bootstrap ",
                                      "--- load / gates ",
                                      "--- orbit build, C step fails ")))
    check("the link table is the seven cases its comment counts",
          len(LINK_CASES) == 7 and LINK_FLAG.startswith("-D"))
    check("the toolchain case is the misreporting probe, not a build case",
          len(TOOLCHAIN_CASES) == 1
          and TOOLCHAIN_CASES[0][5] == "was not found")

    out.finish("cli-probe self-test", total - fails, total)
    return 1 if fails else 0


def self_test_snapshots() -> int:
    """The mask layer, checked on text instead of on a build.

    The gate compares bytes after masking, so a mask that stopped firing puts a
    machine-dependent line into six goldens, and a mask that fires too widely
    makes a real change invisible. Both directions are asserted: two runs whose
    timings differ normalise to one text, and a changed escape code does not.
    """
    fails = 0
    total = 0

    def check(label, ok):
        nonlocal fails, total
        total += 1
        if ok:
            out.say("  ok    %s" % label)
        else:
            out.fail("  BROKEN %s" % label)
            fails += 1

    with tempfile.TemporaryDirectory(prefix="ui_selftest_") as td:
        work = pathlib.Path(td)

        slow = "Building\n  resolve    214 ms   [▰▰▱▱▱]\ntoolchain: found gcc 15.2 (x86_64)\n"
        fast = "Building\n  resolve     97 ms   [▰▰▰▱▱]\ntoolchain: found clang 18.1 (x86_64)\n"
        a = normalize(slow, str(work))
        b = normalize(fast, str(work))
        check("a run-to-run timing and bar difference normalises away", a == b)
        check("the toolchain probe is masked, not dropped",
              "toolchain: found <cc>" in a)
        check("the masked time keeps its unit", "N ms" in a)
        check("a changed word is not masked away",
              normalize(slow.replace("resolve", "resolve2"), str(work)) != a)
        check("an escape code survives the masks",
              normalize("x\n", str(work)) != normalize("\x1b[31mx\n", str(work)))
        check("CRLF is folded to LF",
              normalize("a\r\nb\r\n", str(work)) == "a\nb\n")
        check("both spellings of the scratch path become a dot",
              normalize("read %s/x.orb and %s\n" % (str(work),
                                                    str(work).replace("\\", "/")),
                        str(work)) == "read ./x.orb and .\n")
        check("a child name loses the host executable suffix",
              normalize("spawn app.orb.run.exe\n", str(work))
              == "spawn app.orb.run\n")
        check("a Windows relative path is stored in the POSIX spelling",
              normalize(".\\scan\\x.orb\n", str(work)) == "scan/x.orb\n")
        check("the banner version is masked so a bump rewrites no golden",
              normalize("orbit 0.1.0-beta.2\n", str(work)) == "orbit N\n")
        check("a progress bar of cells is masked",
              normalize("[#####-]\n", str(work)) == "[<bar>]\n")
        check("a masked number settles to one space before the border",
              normalize("  resolve      12 ms     \x1b[36m│\x1b[0m", str(work))
              == "  resolve N ms \x1b[36m│\x1b[0m")

        env = child_env({"ORBIT_UI": "rich"}, "gcc", work)
        check("the tier variable asked for survives", env["ORBIT_UI"] == "rich")
        check("motion is pinned off so the frame is stable",
              env["ORBIT_UI_MOTION"] == "0")
        check("the cc is handed to the child under the name it reads",
              env["ORBIT_CC"] == "gcc")
        check("TEMP points inside the work dir, not the system temp",
              env["TEMP"] == str(work / "tmp"))
        os.environ["NO_COLOR"] = "1"
        os.environ["TERM_PROGRAM"] = "iTerm.app"
        try:
            scrubbed = child_env({}, "gcc", work)
            check("the scrub list really removes the ambient values",
                  "NO_COLOR" not in scrubbed and "TERM_PROGRAM" not in scrubbed)
        finally:
            del os.environ["NO_COLOR"]
            del os.environ["TERM_PROGRAM"]

        d = stage_dir(work, "probe")
        check("the fixtures are staged", (d / "hello.orb").is_file()
              and (d / "scan" / "messy.orb").is_file())
        check("the runtime sits beside the staged tree",
              (d / "runtime" / "gen").is_dir())
        (d / "hello.orb").write_text("mutated", encoding="utf-8")
        again = stage_dir(work, "probe")
        check("staging again replaces a mutated tree rather than reusing it",
              (again / "hello.orb").read_text(encoding="utf-8")
              == 'fn main() {\n    print("hello")\n}\n')

        check("every screen has a tier pair to write and no space in its name",
              len(TIERS) == 2 and all(" " not in n for n, _a, _r in SCREENS))

        sink = bytearray(b"prefix \x1b[?25l suffix")
        check("read_until finds a needle already in the sink",
              read_until(b"\x1b[?25l", sink, time.monotonic() + 5) is True)
        check("read_until gives up in bounded time on a needle never sent",
              read_until(b"\x1b[?25h", sink, time.monotonic() + 0.2) is False)

    out.finish("ui-snapshots self-test", total - fails, total)
    return 1 if fails else 0


def self_test_dispatch() -> int:
    """The dispatch checker's own reading, on synthetic source and on the tree.

    (1) is the invariant this file exists for, so the self-test has to prove the
    arm reader is not blind: a nested `match` must not be taken for the outer one
    (the refactor that moved `ASTNode.Call(innerCall)` onto the top-level `Call`),
    an arm with no `return` must show up as silent, and a variant with no arm must
    show up as missing. Then the real files are read with the same helpers,
    because a checker whose own fixture rots is a checker that passes.
    """
    fails = 0
    total = 0

    def check(label, ok):
        nonlocal fails, total
        total += 1
        if ok:
            out.say("  ok    %s" % label)
        else:
            out.fail("  BROKEN %s" % label)
            fails += 1

    ast_text = "type ASTNode = Lit(int) | Ident(name) | Call(fn, args)\n"
    check("variants are read by name",
          variants(ast_text) == ["Lit", "Ident", "Call"])
    try:
        variants("model Other {\n    x: int\n}\n")
        check("a file with no ASTNode type raises rather than naming nothing",
              False)
    except ValueError:
        check("a file with no ASTNode type raises rather than naming nothing",
              True)

    sig = "fn checkNode(sema: Sema, node: ASTNode) -> string {"
    outer = (sig + "\n"
             "  match node {\n"
             "    ASTNode.Lit(v) => {\n        return \"int\"\n    }\n"
             "    ASTNode.Ident(n) => {\n"
             "        match n.kind {\n"
             "            ASTNode.Call(inner) => {\n                1\n            }\n"
             "        }\n        return \"string\"\n    }\n"
             "    ASTNode.Call(f, a) => {\n        drop\n    }\n"
             "    _ => {\n        return \"\"\n    }\n"
             "  }\n"
             "  return \"\"\n}\n")
    start, end, _open = fn_span(outer, sig)
    check("fn_span covers the whole function",
          outer[start:end].startswith("fn checkNode")
          and outer[start:end].endswith("}"))
    body = outer[start:end]
    arms, base = match_arms(body)
    # `_` is not keyed by name, because the regex reads `ASTNode.<Variant>` and
    # the fallback arm is bare `_`; the gate checks it with its own regex below.
    check("a nested match's arms are not taken for the outer match",
          set(arms) == {"Lit", "Ident", "Call"} and base is not None)
    check("no variant of the fixture is missing an arm",
          [v for v in variants(ast_text) if v not in arms] == [])
    check("a variant added to the schema with no arm here is reported",
          "Loop" in variants(ast_text.rstrip("\n") + " | Loop(x)")
          and "Loop" not in arms)
    silent = [n for n, (_, b, e) in sorted(arms.items()) if "return" not in body[b:e]]
    check("the arm that falls off the end is named", silent == ["Call"])
    check("a returning arm is not reported silent", "Lit" not in silent)
    check("the `_` fallback is found by the regex the gate uses",
          bool(re.search(r"_\s*=>\s*\{[^}]*\breturn\b", body)))
    check("a second walker is found when it is there",
          re.search(r"(?m)^fn inferType\(", "fn inferType(s: Sema) -> string {\n")
          is not None)
    check("no second walker in the fixture",
          re.search(r"(?m)^fn inferType\(", outer) is None)
    check("a stale inferType call is counted",
          len(re.findall(r"inferType\(sema,", "  inferType(sema, n)\n")) == 1)

    with open(AST) as f:
        real_ast = f.read()
    with open(SEMA) as f:
        real_sema = f.read()
    check("the tree still declares checkNode as `-> string`", sig in real_sema)
    r_start, r_end, _ = fn_span(real_sema, sig)
    r_body = real_sema[r_start:r_end]
    r_arms, _ = match_arms(r_body)
    r_vs = variants(real_ast)
    check("the helpers read the real tree: no variant without an arm",
          [v for v in r_vs if v not in r_arms] == [])
    check("the helpers read the real tree: no arm without a return",
          [n for n, (_, b, e) in r_arms.items()
           if "return" not in r_body[b:e]] == [])
    check("the helpers read the real tree: one checker, no inferType",
          re.search(r"(?m)^fn inferType\(", real_sema) is None
          and not re.findall(r"inferType\(sema,", real_sema))

    out.finish("dispatch-coverage self-test", total - fails, total)
    return 1 if fails else 0


# ---- the tool: one subcommand per gate ------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(
        description="The doctor, CLI-contract, UI-snapshot and dispatch gates.")
    sub = ap.add_subparsers(dest="cmd", required=True,
                            metavar="{doctor,cli-probe,snapshots,dispatch}")

    p_doctor = sub.add_parser(
        "doctor", help="orbit doctor's exact output against tests/doctor/golden/, "
                      "or the clean-directories scope check with --scope-only")
    # Optional at the parser, required by doctor_main: argparse's own message
    # for a missing `required=True` flag is the one doctor_main prints, so the
    # exit 2 and the text are unchanged, and `--self-test` still works alone.
    p_doctor.add_argument("--compiler", default=None)
    p_doctor.add_argument("--update", action="store_true")
    p_doctor.add_argument("--scope-only", action="store_true",
                          help="only the clean-directories check over compiler, std "
                               "and tests/suite (was scripts/doctor_scope_gate.py)")
    p_doctor.add_argument("--self-test", action="store_true",
                          help="prove the golden harness can still fail, with a "
                               "stub compiler and no build")

    p_cli = sub.add_parser("cli-probe", help="the orbit CLI contract")
    p_cli.add_argument("--compiler", default=None)
    p_cli.add_argument("--work", default=None,
                       help="scratch directory for this run")
    p_cli.add_argument("--specimen", action="store_true",
                       help="print the static output-grammar specimen and exit")
    p_cli.add_argument("--self-test", action="store_true",
                       help="prove the stream and exit-code matcher can still "
                            "fail, with python in place of the compiler")

    p_ui = sub.add_parser(
        "snapshots", help="the rich and colour screens against tests/ui, plus the "
                         "interrupt probe")
    p_ui.add_argument("--compiler", default=None,
                      help="path to the orbit binary under test")
    p_ui.add_argument("--cc", default=None, help="C compiler for the build screens")
    p_ui.add_argument("--work", default=None, help="scratch directory")
    p_ui.add_argument("--update", action="store_true",
                      help="rewrite tests/ui/*.txt from the current output")
    p_ui.add_argument("--skip-probe", action="store_true",
                      help="do not run the interrupt probe")
    p_ui.add_argument("--self-test", action="store_true",
                      help="prove the mask layer can still fail, on text and "
                           "with no build")

    p_dispatch = sub.add_parser(
        "dispatch", help="every ASTNode variant has an arm in checkNode, and every "
                         "arm returns")
    p_dispatch.add_argument("--self-test", action="store_true",
                            help="prove the arm reader can still fail, on "
                                 "synthetic source")

    args = ap.parse_args()
    if args.self_test:
        # A self-test replaces the gate instead of running it as well: each one
        # asserts the checker can say no without a compiler, so it costs seconds
        # where the gate costs minutes.
        return {"doctor": self_test_doctor,
                "cli-probe": self_test_cli_probe,
                "snapshots": self_test_snapshots,
                "dispatch": self_test_dispatch}[args.cmd]()
    if args.cmd == "doctor":
        return doctor_main(args, p_doctor)
    if args.cmd == "cli-probe":
        return cli_probe_main(args, p_cli)
    if args.cmd == "snapshots":
        return ui_main(args, p_ui)
    return dispatch_main()


if __name__ == "__main__":
    sys.exit(main())
